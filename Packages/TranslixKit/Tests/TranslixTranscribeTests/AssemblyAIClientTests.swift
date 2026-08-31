import Foundation
import Testing
import TranslixTestSupport

@testable import TranslixTranscribe

/// The network client, against a stubbed transport. No live calls: a suite that spends money
/// and needs a key is a suite nobody runs.
@Suite("AssemblyAIClient", .serialized)
struct AssemblyAIClientTests {
    private func client(
        key: String? = "aai-test-key",
        respond: @escaping @Sendable (URLRequest) -> (Int, Data)
    ) -> AssemblyAIClient {
        StubTransport.handler = respond
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubTransport.self]
        return AssemblyAIClient(
            apiKey: { key },
            session: URLSession(configuration: configuration),
            pollInterval: .milliseconds(1)
        )
    }

    /// A tiny fake audio file to upload.
    private func audioFile() throws -> URL {
        let url = URL(filePath: NSTemporaryDirectory())
            .appending(path: "aai-test-\(UUID().uuidString).m4a")
        try Data("not really audio".utf8).write(to: url)
        return url
    }

    private static let uploadResponse = Data(
        #"{"upload_url": "https://cdn.assemblyai.com/upload/x1"}"#.utf8
    )

    private static func job(_ status: String, error: String? = nil) -> Data {
        let extra = error.map { #", "error": "\#($0)""# } ?? ""
        return Data(#"{"id": "j1", "status": "\#(status)"\#(extra)}"#.utf8)
    }

    /// Routes the three endpoints the client speaks, recording what it saw.
    private static func route(
        polls: Locked<Int>,
        completeAfter: Int = 1,
        sawUpload: Locked<URLRequest?>? = nil,
        sawCreate: Locked<Data?>? = nil
    ) -> @Sendable (URLRequest) -> (Int, Data) {
        { request in
            switch (request.httpMethod ?? "", request.url?.path() ?? "") {
            case ("POST", "/v2/upload"):
                sawUpload?.withValue { $0 = request }
                return (200, uploadResponse)
            case ("POST", "/v2/transcript"):
                sawCreate?.withValue { $0 = request.httpBodyData }
                return (200, job("queued"))
            case ("GET", "/v2/transcript/j1"):
                let count = polls.withValue { $0 += 1; return $0 }
                return count < completeAfter
                    ? (200, job("processing"))
                    : (200, Data(#"{"id": "j1", "status": "completed", "language_code": "es"}"#.utf8))
            default:
                return (404, Data())
            }
        }
    }

    // MARK: - Upload

    @Test("the file goes up as raw bytes with the key in the authorization header")
    func uploadSendsRawBytes() async throws {
        let polls = Locked(0)
        let sawUpload = Locked<URLRequest?>(nil)
        let sut = client(respond: Self.route(polls: polls, sawUpload: sawUpload))

        _ = try await sut.transcribe(
            file: try audioFile(), request: AssemblyAIRequest(speakerLabels: false)
        ) { _ in }

        let request = try #require(sawUpload.value)
        // The raw key, no Bearer prefix: that is the shape their API documents.
        #expect(request.value(forHTTPHeaderField: "authorization") == "aai-test-key")
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/octet-stream")
        #expect(request.httpBodyData == Data("not really audio".utf8))
    }

    // MARK: - Creating the job

    @Test("the job pins the model and points at the uploaded file")
    func createPinsModelAndAudio() async throws {
        let polls = Locked(0)
        let sawCreate = Locked<Data?>(nil)
        let sut = client(respond: Self.route(polls: polls, sawCreate: sawCreate))

        _ = try await sut.transcribe(
            file: try audioFile(), request: AssemblyAIRequest(speakerLabels: true)
        ) { _ in }

        let body = try #require(sawCreate.value)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        // Pinned, so AssemblyAI's routing changes never silently change what a session costs.
        #expect(json["speech_models"] as? [String] == ["universal-2"])
        #expect(json["audio_url"] as? String == "https://cdn.assemblyai.com/upload/x1")
        #expect(json["speaker_labels"] as? Bool == true)
    }

    @Test("a fixed language travels as its bare code")
    func createSendsFixedLanguage() async throws {
        let polls = Locked(0)
        let sawCreate = Locked<Data?>(nil)
        let sut = client(respond: Self.route(polls: polls, sawCreate: sawCreate))

        _ = try await sut.transcribe(
            file: try audioFile(),
            request: AssemblyAIRequest(speakerLabels: false, languageCode: "es")
        ) { _ in }

        let body = try #require(sawCreate.value)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["language_code"] as? String == "es")
        #expect(json["language_detection"] == nil)
    }

    @Test("automatic asks for detection and names no language")
    func createSendsDetection() async throws {
        let polls = Locked(0)
        let sawCreate = Locked<Data?>(nil)
        let sut = client(respond: Self.route(polls: polls, sawCreate: sawCreate))

        _ = try await sut.transcribe(
            file: try audioFile(),
            request: AssemblyAIRequest(speakerLabels: false, languageDetection: true)
        ) { _ in }

        let body = try #require(sawCreate.value)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["language_detection"] as? Bool == true)
        #expect(json["language_code"] == nil)
    }

    // MARK: - Polling

    @Test("polls until the job completes and hands back the result")
    func pollsUntilCompleted() async throws {
        let polls = Locked(0)
        let sut = client(respond: Self.route(polls: polls, completeAfter: 3))

        let result = try await sut.transcribe(
            file: try audioFile(), request: AssemblyAIRequest(speakerLabels: false)
        ) { _ in }

        #expect(result.status == .completed)
        #expect(result.languageCode == "es")
        #expect(polls.value == 3)
    }

    @Test("progress reaches waiting once the job exists")
    func reportsWaiting() async throws {
        let polls = Locked(0)
        let seen = Locked<[AssemblyAIProgress]>([])
        let sut = client(respond: Self.route(polls: polls))

        _ = try await sut.transcribe(
            file: try audioFile(), request: AssemblyAIRequest(speakerLabels: false)
        ) { progress in seen.withValue { $0.append(progress) } }

        #expect(seen.value.contains(.waiting))
    }

    // MARK: - Failures

    @Test("a failed job surfaces AssemblyAI's own explanation")
    func failedJobThrowsWithMessage() async throws {
        let polls = Locked(0)
        let sut = client { request in
            switch (request.httpMethod ?? "", request.url?.path() ?? "") {
            case ("POST", "/v2/upload"): return (200, Self.uploadResponse)
            case ("POST", "/v2/transcript"): return (200, Self.job("queued"))
            default:
                _ = polls.withValue { $0 += 1 }
                return (200, Self.job("error", error: "Audio file is empty"))
            }
        }

        do {
            _ = try await sut.transcribe(
                file: try audioFile(), request: AssemblyAIRequest(speakerLabels: false)
            ) { _ in }
            Issue.record("expected the failed job to throw")
        } catch let TranscriptionError.engineFailed(message) {
            #expect(message.contains("Audio file is empty"))
        }
    }

    @Test("a rejected key names the key, not a status code")
    func unauthorizedNamesTheKey() async throws {
        let sut = client { _ in (401, Data(#"{"error": "unauthorized"}"#.utf8)) }

        do {
            _ = try await sut.transcribe(
                file: try audioFile(), request: AssemblyAIRequest(speakerLabels: false)
            ) { _ in }
            Issue.record("expected the rejected key to throw")
        } catch let TranscriptionError.modelUnavailable(message) {
            #expect(message.contains("clave"))
        }
    }

    @Test("no key means nothing is sent at all")
    func missingKeyNeverCalls() async throws {
        let called = Locked(false)
        let sut = client(key: nil) { _ in
            called.withValue { $0 = true }
            return (200, Self.uploadResponse)
        }

        do {
            _ = try await sut.transcribe(
                file: try audioFile(), request: AssemblyAIRequest(speakerLabels: false)
            ) { _ in }
            Issue.record("expected the missing key to throw")
        } catch let TranscriptionError.modelUnavailable(message) {
            #expect(message.contains("clave"))
        }
        #expect(!called.value)
    }
}

// MARK: - Transport double

/// Intercepts the request instead of letting it reach the network.
private final class StubTransport: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension URLRequest {
    /// `URLProtocol` hands the body over as a stream, so `httpBody` is nil by the time a stub
    /// sees it. This reads whichever of the two is actually populated.
    var httpBodyData: Data? {
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
