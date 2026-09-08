import Foundation
import Testing
import TranslixModel
import TranslixTestSupport

@testable import TranslixTranscribe

@Suite("AssemblyAIEngine", .serialized)
struct AssemblyAIEngineTests {
    private func engine(
        key: String? = "aai-test-key",
        respond: @escaping @Sendable (URLRequest) -> (Int, Data)
    ) -> AssemblyAIEngine {
        EngineStubTransport.handler = respond
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EngineStubTransport.self]
        return AssemblyAIEngine(
            apiKey: { key },
            session: URLSession(configuration: configuration),
            pollInterval: .milliseconds(1)
        )
    }

    private func audioFile() throws -> URL {
        let url = URL(filePath: NSTemporaryDirectory())
            .appending(path: "aai-engine-\(UUID().uuidString).m4a")
        try Data("audio".utf8).write(to: url)
        return url
    }

    /// Serves upload → create → completed with one system utterance, recording the job body.
    private static func route(sawCreate: Locked<Data?>? = nil) -> @Sendable (URLRequest) -> (Int, Data) {
        { request in
            switch (request.httpMethod ?? "", request.url?.path() ?? "") {
            case ("POST", "/v2/upload"):
                return (200, Data(#"{"upload_url": "https://cdn.assemblyai.com/upload/x1"}"#.utf8))
            case ("POST", "/v2/transcript"):
                sawCreate?.withValue { $0 = request.assemblyAIBodyData }
                return (200, Data(#"{"id": "j1", "status": "queued"}"#.utf8))
            default:
                return (200, Data("""
                {
                  "id": "j1", "status": "completed", "language_code": "es",
                  "words": [
                    {"text": "hola", "start": 0, "end": 400, "confidence": 0.9, "speaker": "A"}
                  ],
                  "utterances": [
                    {"speaker": "A", "start": 0, "end": 400, "text": "hola", "confidence": 0.9,
                     "words": [{"text": "hola", "start": 0, "end": 400, "confidence": 0.9, "speaker": "A"}]}
                  ]
                }
                """.utf8))
            }
        }
    }

    // MARK: - Availability

    @Test("with a key the engine is ready for any language, nothing to download")
    func readyWithKey() async {
        let sut = engine { _ in (500, Data()) }

        #expect(await sut.availability(for: .automatic) == .ready)
        #expect(await sut.availability(for: .fixed("es-CL")) == .ready)
    }

    @Test("without a key the engine says which key is missing")
    func unsupportedWithoutKey() async {
        let sut = engine(key: nil) { _ in (500, Data()) }

        let availability = await sut.availability(for: .automatic)
        guard case let .unsupported(reason) = availability else {
            Issue.record("expected unsupported, got \(availability)")
            return
        }
        #expect(reason.contains("AssemblyAI"))
        #expect(reason.contains("clave"))
    }

    // MARK: - Track transcription

    @Test("the system track asks for speaker labels, the mic track does not")
    func speakerLabelsFollowTheTrack() async throws {
        for (track, expected) in [(AudioTrack.system, true), (.mic, false)] {
            let sawCreate = Locked<Data?>(nil)
            let sut = engine(respond: Self.route(sawCreate: sawCreate))

            _ = try await sut.transcribe(
                trackFile: try audioFile(), track: track, language: .fixed("es-CL")
            ) { _ in }

            let body = try #require(sawCreate.value)
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["speaker_labels"] as? Bool == expected)
        }
    }

    @Test("a fixed regional language reaches AssemblyAI as its bare code")
    func fixedLanguageDropsRegion() async throws {
        let sawCreate = Locked<Data?>(nil)
        let sut = engine(respond: Self.route(sawCreate: sawCreate))

        _ = try await sut.transcribe(
            trackFile: try audioFile(), track: .mic, language: .fixed("es-CL")
        ) { _ in }

        let body = try #require(sawCreate.value)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["language_code"] as? String == "es")
        #expect(json["language_detection"] == nil)
    }

    @Test("automatic asks for detection and reports what came back")
    func automaticDetects() async throws {
        let sawCreate = Locked<Data?>(nil)
        let sut = engine(respond: Self.route(sawCreate: sawCreate))

        let result = try await sut.transcribe(
            trackFile: try audioFile(), track: .system, language: .automatic
        ) { _ in }

        let body = try #require(sawCreate.value)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["language_detection"] as? Bool == true)
        #expect(result.detectedLanguage == "es")
    }

    @Test("a fixed language is echoed by nobody: only detection reports one")
    func fixedLanguageReportsNothing() async throws {
        // Passing the instruction back as a discovery is the exact bug EngineTranscription
        // was created to avoid; the track path keeps the same rule.
        let sut = engine(respond: Self.route())

        let result = try await sut.transcribe(
            trackFile: try audioFile(), track: .system, language: .fixed("es-CL")
        ) { _ in }

        #expect(result.detectedLanguage == nil)
    }

    @Test("system utterances come back as segments and turns in app conventions")
    func mapsThroughTheMapper() async throws {
        let sut = engine(respond: Self.route())

        let result = try await sut.transcribe(
            trackFile: try audioFile(), track: .system, language: .fixed("es")
        ) { _ in }

        #expect(result.segments.map(\.speakerID) == ["system-1"])
        #expect(result.segments.first?.end == 0.4)
        #expect(result.turns.count == 1)
    }

    @Test("chunk transcription rides the same path and just drops the turns")
    func chunkConformanceWorks() async throws {
        let sut = engine(respond: Self.route())

        let result = try await sut.transcribe(
            chunk: try audioFile(), language: .fixed("es"), track: .mic
        )

        #expect(!result.segments.isEmpty)
        #expect(result.segments.allSatisfy { $0.speakerID == SessionManifest.micSpeakerID })
    }

    // MARK: - Registry

    @Test("the registry offers the cloud engine and reports it takes no disk")
    func registryOffersAssemblyAI() async {
        let registry = TranscriptionEngineRegistry(assemblyAIKey: { "aai-test-key" })

        #expect(registry.availableEngineIDs.contains(.assemblyAI))

        let engine = await registry.engine(.assemblyAI)
        #expect(engine.id == .assemblyAI)

        let status = await registry.status(for: .assemblyAI, language: .automatic)
        #expect(status.installedBytes == nil)
        #expect(!status.canRemove)
        #expect(status.availability == .ready)
    }

    @Test("engine ids stay stable, because results are filed under them")
    func engineIDIsStable() {
        #expect(EngineID.assemblyAI.rawValue == "assemblyai")
    }
}

// MARK: - Transport double

private final class EngineStubTransport: URLProtocol, @unchecked Sendable {
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

private extension URLRequest {
    /// `URLProtocol` hands the body over as a stream, so `httpBody` is nil by the time a stub
    /// sees it. This reads whichever of the two is actually populated.
    var assemblyAIBodyData: Data? {
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
