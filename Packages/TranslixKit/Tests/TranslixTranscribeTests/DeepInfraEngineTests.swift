import Foundation
import Testing
import TranslixModel
import TranslixTestSupport

@testable import TranslixTranscribe

@Suite("DeepInfraEngine", .serialized)
struct DeepInfraEngineTests {
    private func engine(
        key: String? = "di-test-key",
        model: String = DeepInfraEngine.defaultModel,
        requestTimeout: TimeInterval = DeepInfraEngine.defaultRequestTimeout,
        maxAttempts: Int = RemoteRetry.maxAttempts,
        respond: @escaping @Sendable (URLRequest) -> (Int, Data)
    ) -> DeepInfraEngine {
        engine(
            key: key, model: model, requestTimeout: requestTimeout, maxAttempts: maxAttempts
        ) { request in
            let (status, data) = respond(request)
            return .response(status, data)
        }
    }

    /// The full form, for the tests that need the transport to fail rather than answer.
    ///
    /// The delay is always zero here. The real ladder is twelve seconds, which is the right
    /// thing to make a person wait through once and the wrong thing to make a test suite wait
    /// through on every run.
    private func engine(
        key: String? = "di-test-key",
        model: String = DeepInfraEngine.defaultModel,
        requestTimeout: TimeInterval = DeepInfraEngine.defaultRequestTimeout,
        maxAttempts: Int = RemoteRetry.maxAttempts,
        outcome: @escaping @Sendable (URLRequest) -> DeepInfraStubOutcome
    ) -> DeepInfraEngine {
        DeepInfraStubTransport.handler = outcome
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeepInfraStubTransport.self]
        return DeepInfraEngine(
            apiKey: { key },
            model: model,
            session: URLSession(configuration: configuration),
            requestTimeout: requestTimeout,
            maxAttempts: maxAttempts,
            retryDelay: { _ in .zero }
        )
    }

    private func audioFile() throws -> URL {
        let url = URL(filePath: NSTemporaryDirectory())
            .appending(path: "di-\(UUID().uuidString).m4a")
        try Data("pretend audio".utf8).write(to: url)
        return url
    }

    private static let success = Data("""
    {
      "text": "hola a todos",
      "segments": [{"start": 0.0, "end": 2.0, "text": "hola a todos"}],
      "words": [
        {"start": 0.0, "end": 0.4, "text": "hola"},
        {"start": 0.5, "end": 0.7, "text": "a"},
        {"start": 0.8, "end": 2.0, "text": "todos"}
      ],
      "language": "es"
    }
    """.utf8)

    // MARK: - Availability

    @Test("with a key the engine is ready and has nothing to download")
    func readyWithKey() async {
        let sut = engine { _ in (200, Self.success) }

        #expect(await sut.availability(for: .automatic) == .ready)
        #expect(await sut.availability(for: .fixed("es-CL")) == .ready)
    }

    @Test("without a key it says which key is missing")
    func unsupportedWithoutKey() async {
        let sut = engine(key: nil) { _ in (200, Self.success) }

        let availability = await sut.availability(for: .automatic)
        guard case let .unsupported(reason) = availability else {
            Issue.record("expected unsupported, got \(availability)")
            return
        }
        #expect(reason.contains("DeepInfra"))
        #expect(reason.contains("clave"))
    }

    // MARK: - The request

    @Test("the audio is posted to the configured model with the token")
    func postsAudioWithToken() async throws {
        let seen = Locked<URLRequest?>(nil)
        let sut = engine { request in
            seen.withValue { $0 = request }
            return (200, Self.success)
        }

        _ = try await sut.transcribe(
            trackFile: try audioFile(), track: .system, language: .fixed("es-CL")
        ) { _ in }

        let request = try #require(seen.value)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString.hasSuffix("/v1/inference/openai/whisper-large-v3") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "bearer di-test-key")
        #expect(
            request.value(forHTTPHeaderField: "Content-Type")?.contains("multipart/form-data") == true
        )
    }

    @Test("the multipart body carries the audio and asks for word timings")
    func bodyCarriesAudioAndWordChunks() async throws {
        let seen = Locked<Data?>(nil)
        let sut = engine { request in
            seen.withValue { $0 = request.deepInfraBodyData }
            return (200, Self.success)
        }

        _ = try await sut.transcribe(
            trackFile: try audioFile(), track: .mic, language: .fixed("es-CL")
        ) { _ in }

        let body = try #require(seen.value)
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains("name=\"audio\""))
        #expect(text.contains("pretend audio"))
        // Word timings are what let the local diarizer cut a segment where the voice changes.
        #expect(text.contains("name=\"chunk_level\""))
        #expect(text.contains("word"))
    }

    @Test("a fixed language travels as its bare code, automatic names none")
    func languageIsSentBare() async throws {
        let seen = Locked<Data?>(nil)
        let sut = engine { request in
            seen.withValue { $0 = request.deepInfraBodyData }
            return (200, Self.success)
        }

        _ = try await sut.transcribe(
            trackFile: try audioFile(), track: .mic, language: .fixed("es-CL")
        ) { _ in }
        #expect(String(decoding: try #require(seen.value), as: UTF8.self).contains("name=\"language\""))

        _ = try await sut.transcribe(
            trackFile: try audioFile(), track: .mic, language: .automatic
        ) { _ in }
        // Naming a language would defeat the detection the session asked for.
        #expect(!String(decoding: try #require(seen.value), as: UTF8.self).contains("name=\"language\""))
    }

    // MARK: - The result

    @Test("segments come back with words and no speakers")
    func mapsThroughTheMapper() async throws {
        let sut = engine { _ in (200, Self.success) }

        let result = try await sut.transcribe(
            trackFile: try audioFile(), track: .system, language: .fixed("es")
        ) { _ in }

        #expect(result.segments.count == 1)
        #expect(result.segments[0].words.count == 3)
        #expect(result.segments[0].speakerID == nil)
    }

    @Test("this engine brings no speakers, so the local diarizer must still run")
    func doesNotSeparateSpeakers() async throws {
        // The flag the planner reads. Getting it wrong would skip diarization and leave every
        // line of a meeting unattributed.
        let sut = engine { _ in (200, Self.success) }

        #expect(sut.separatesSpeakers == false)

        let result = try await sut.transcribe(
            trackFile: try audioFile(), track: .system, language: .fixed("es")
        ) { _ in }
        #expect(result.turns.isEmpty)
    }

    @Test("automatic reports the language Whisper detected, a fixed one reports nothing")
    func reportsDetectedLanguage() async throws {
        let sut = engine { _ in (200, Self.success) }

        let detected = try await sut.transcribe(
            trackFile: try audioFile(), track: .mic, language: .automatic
        ) { _ in }
        #expect(detected.detectedLanguage == "es")

        let fixed = try await sut.transcribe(
            trackFile: try audioFile(), track: .mic, language: .fixed("es-CL")
        ) { _ in }
        // Echoing back an instruction as a discovery is the bug EngineTranscription exists
        // to prevent.
        #expect(fixed.detectedLanguage == nil)
    }

    // MARK: - Failures

    @Test("a rejected token names the key rather than a status code")
    func unauthorizedNamesTheKey() async throws {
        let sut = engine { _ in (401, Data(#"{"detail":"unauthorized"}"#.utf8)) }

        do {
            _ = try await sut.transcribe(
                trackFile: try audioFile(), track: .mic, language: .fixed("es")
            ) { _ in }
            Issue.record("expected the rejected token to throw")
        } catch let TranscriptionError.modelUnavailable(message) {
            #expect(message.contains("clave"))
        }
    }

    @Test("a server error surfaces DeepInfra's own explanation")
    func serverErrorSurfacesDetail() async throws {
        let sut = engine { _ in (500, Data(#"{"detail":"model overloaded"}"#.utf8)) }

        do {
            _ = try await sut.transcribe(
                trackFile: try audioFile(), track: .mic, language: .fixed("es")
            ) { _ in }
            Issue.record("expected the server error to throw")
        } catch let TranscriptionError.engineFailed(message) {
            #expect(message.contains("model overloaded"))
        }
    }

    @Test("no key means nothing is sent at all")
    func missingKeyNeverCalls() async throws {
        let called = Locked(false)
        let sut = engine(key: nil) { _ in
            called.withValue { $0 = true }
            return (200, Self.success)
        }

        await #expect(throws: (any Error).self) {
            _ = try await sut.transcribe(
                trackFile: try self.audioFile(), track: .mic, language: .fixed("es")
            ) { _ in }
        }
        #expect(!called.value)
    }

    // MARK: - Retry

    @Test("a server that goes quiet once is asked again")
    func transientTimeoutIsRetried() async throws {
        let calls = Locked(0)
        let sut = engine { _ in
            let call = calls.withValue { $0 += 1; return $0 }
            // The exact failure that lost a twenty-four-minute session: the audio went out,
            // and nothing came back.
            return call == 1 ? .failure(URLError(.timedOut)) : .response(200, Self.success)
        }

        let result = try await sut.transcribe(
            trackFile: try audioFile(), track: .mic, language: .fixed("es")
        ) { _ in }

        #expect(calls.value == 2)
        #expect(!result.segments.isEmpty)
    }

    @Test("a server that stays quiet is given up on, and the message says the audio arrived")
    func persistentSilenceGivesUp() async throws {
        let calls = Locked(0)
        let sut = engine(maxAttempts: 3) { _ in
            calls.withValue { $0 += 1 }
            return .failure(URLError(.timedOut))
        }

        do {
            _ = try await sut.transcribe(
                trackFile: try audioFile(), track: .mic, language: .fixed("es")
            ) { _ in }
            Issue.record("expected the silent server to throw")
        } catch let TranscriptionError.engineFailed(message) {
            #expect(message.contains("DeepInfra"))
            #expect(message.contains("3 intentos"))
        }

        #expect(calls.value == 3)
    }

    @Test("the message separates a silent server from a cut upload")
    func messageNamesWhetherTheAudioArrived() {
        // Tested on the renderer rather than through the transport: a URLProtocol stub never
        // emits didSendBodyData, so the upload delegate never sees a body go out and the
        // distinction cannot be provoked from that side. It is worth testing anyway — it is
        // the difference between "their handler never finished" and "our connection broke",
        // which is the first thing anyone reading the failure needs to know.
        let arrived = DeepInfraEngine.error(for: RemoteRetry.Exhausted(
            failure: .transport(URLError(.timedOut), bodyFullySent: true),
            attempts: 3,
            elapsed: .seconds(240)
        ))
        #expect(arrived.localizedDescription.contains("recibió el audio"))
        #expect(arrived.localizedDescription.contains("240 s"))

        let cut = DeepInfraEngine.error(for: RemoteRetry.Exhausted(
            failure: .transport(URLError(.networkConnectionLost), bodyFullySent: false),
            attempts: 2,
            elapsed: .seconds(12)
        ))
        #expect(cut.localizedDescription.contains("Se cortó la conexión"))

        let offline = DeepInfraEngine.error(for: RemoteRetry.Exhausted(
            failure: .transport(URLError(.notConnectedToInternet), bodyFullySent: false),
            attempts: 3,
            elapsed: .seconds(1)
        ))
        #expect(offline.localizedDescription.contains("conexión a internet"))

        let tooBig = DeepInfraEngine.error(for: RemoteRetry.Exhausted(
            failure: .status(413, detail: "payload too large"), attempts: 1, elapsed: .seconds(3)
        ))
        #expect(tooBig.localizedDescription.contains("bloques más cortos"))
    }

    @Test("a rejected key is tried exactly once")
    func rejectedKeyIsNotRetried() async throws {
        let calls = Locked(0)
        let sut = engine { _ in
            calls.withValue { $0 += 1 }
            return (401, Data(#"{"detail":"unauthorized"}"#.utf8))
        }

        await #expect(throws: (any Error).self) {
            _ = try await sut.transcribe(
                trackFile: try self.audioFile(), track: .mic, language: .fixed("es")
            ) { _ in }
        }

        // Three uploads of audio they have already refused would be three bills for the same
        // answer. This is the assertion that catches an over-eager retry policy.
        #expect(calls.value == 1)
    }

    @Test("a busy server is asked again, a bad request is not")
    func retriesRateLimitsButNotBadRequests() async throws {
        let busy = Locked(0)
        let busySut = engine(maxAttempts: 3) { _ in
            busy.withValue { $0 += 1 }
            return (429, Data(#"{"detail":"slow down"}"#.utf8))
        }
        await #expect(throws: (any Error).self) {
            _ = try await busySut.transcribe(
                trackFile: try self.audioFile(), track: .mic, language: .fixed("es")
            ) { _ in }
        }
        #expect(busy.value == 3)

        let bad = Locked(0)
        let badSut = engine(maxAttempts: 3) { _ in
            bad.withValue { $0 += 1 }
            return (400, Data(#"{"detail":"malformed"}"#.utf8))
        }
        await #expect(throws: (any Error).self) {
            _ = try await badSut.transcribe(
                trackFile: try self.audioFile(), track: .mic, language: .fixed("es")
            ) { _ in }
        }
        #expect(bad.value == 1)
    }

    @Test("each request carries a timeout proportionate to one batch")
    func requestTimeoutIsProportionate() async throws {
        let seen = Locked<TimeInterval?>(nil)
        let sut = engine { request in
            seen.withValue { $0 = request.timeoutInterval }
            return (200, Self.success)
        }

        _ = try await sut.transcribe(
            trackFile: try audioFile(), track: .mic, language: .fixed("es")
        ) { _ in }

        // Four minutes, not the fifteen a whole track used to get. Nothing asserted this
        // before, which is how the fifteen went unexamined until it cost a session.
        #expect(seen.value == 240)
        #expect(DeepInfraEngine.defaultMaxUploadSeconds == 600)
    }

    @Test("cancelling reads as cancellation, not as a failed transcription")
    func cancellationIsNotAFailure() async throws {
        let sut = engine { _ in .failure(URLError(.cancelled)) }

        // URLSession reports a cancelled task as URLError(.cancelled). Read as a failure, it
        // marks the session failed instead of putting it back the way it was.
        await #expect(throws: CancellationError.self) {
            _ = try await sut.transcribe(
                trackFile: try self.audioFile(), track: .mic, language: .fixed("es")
            ) { _ in }
        }
    }

    // MARK: - Registry

    @Test("the registry offers DeepInfra and reports it takes no disk")
    func registryOffersDeepInfra() async {
        let registry = TranscriptionEngineRegistry(deepInfraKey: { "di-test-key" })

        #expect(registry.availableEngineIDs.contains(.deepInfra))

        let status = await registry.status(for: .deepInfra, language: .automatic)
        #expect(status.availability == .ready)
        #expect(status.installedBytes == nil)
        #expect(!status.canRemove)
    }

    @Test("engine ids stay stable, because results are filed under them")
    func engineIDIsStable() {
        #expect(EngineID.deepInfra.rawValue == "deepinfra")
    }
}

// MARK: - Transport double

/// What the stub does with one request: answer it, or fail the way the network would.
///
/// Failing matters as much as answering. The worst thing this engine has done was provoked
/// by a server that accepted an upload and then sent nothing, and until the double could
/// reproduce that, no test could say what the engine does about it.
enum DeepInfraStubOutcome {
    case response(Int, Data)
    case failure(URLError)
}

private final class DeepInfraStubTransport: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> DeepInfraStubOutcome)?

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        switch handler(request) {
        case let .response(status, data):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension URLRequest {
    /// `URLProtocol` hands the body over as a stream, so `httpBody` is nil by the time a stub
    /// sees it. This reads whichever of the two is actually populated.
    var deepInfraBodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }

        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
