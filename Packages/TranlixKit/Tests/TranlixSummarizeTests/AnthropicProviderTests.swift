import Foundation
import Testing

@testable import TranlixSummarize

/// The network client, against a stubbed transport. No live calls: a suite that spends money
/// and needs a key is a suite nobody runs.
@Suite("AnthropicProvider", .serialized)
struct AnthropicProviderTests {
    private func provider(
        key: String? = "sk-ant-test",
        respond: @escaping @Sendable (URLRequest) -> (Int, Data)
    ) -> AnthropicProvider {
        StubTransport.handler = respond
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubTransport.self]
        return AnthropicProvider(
            keys: StubKeys.store(returning: key),
            session: URLSession(configuration: configuration)
        )
    }

    private var request: SummaryRequest {
        SummaryRequest(instruction: "Resumí esto.", transcript: "Persona 1: hola.")
    }

    private func success(_ text: String) -> Data {
        Data(#"{"content":[{"type":"text","text":"\#(text)"}]}"#.utf8)
    }

    // MARK: - The request

    @Test("the instruction goes in the system prompt and the transcript in the message")
    func separatesInstructionFromTranscript() async throws {
        // Keeping them apart is what stops a transcript that happens to contain something
        // shaped like an instruction from being obeyed as one.
        let seen = Locked<URLRequest?>(nil)
        let sut = provider { request in
            seen.withValue { $0 = request }
            return (200, self.success("listo"))
        }

        _ = try await sut.summarize(request)

        let body = try #require(seen.value?.httpBodyData)
        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(json["system"] as? String == "Resumí esto.")

        let messages = try #require(json["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? String)
        #expect(content.contains("Persona 1: hola."))
        #expect(content.contains("<transcripcion>"))
        #expect(!content.contains("Resumí esto."))
    }

    @Test("the key and the pinned API version are sent as headers")
    func sendsAuthHeaders() async throws {
        let seen = Locked<URLRequest?>(nil)
        let sut = provider { request in
            seen.withValue { $0 = request }
            return (200, self.success("listo"))
        }

        _ = try await sut.summarize(request)

        #expect(seen.value?.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
        #expect(
            seen.value?.value(forHTTPHeaderField: "anthropic-version")
                == AnthropicProvider.apiVersion
        )
        #expect(seen.value?.httpMethod == "POST")
    }

    @Test("the chosen model is the one asked for")
    func sendsSelectedModel() async throws {
        let seen = Locked<URLRequest?>(nil)
        let sut = provider { request in
            seen.withValue { $0 = request }
            return (200, self.success("listo"))
        }

        _ = try await sut.summarize(
            SummaryRequest(instruction: "x", transcript: "y", model: SummaryModel.haiku.identifier)
        )

        let body = try #require(seen.value?.httpBodyData)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "claude-haiku-4-5-20251001")
    }

    // MARK: - The response

    @Test("text blocks come back joined")
    func joinsTextBlocks() async throws {
        let sut = provider { _ in
            (200, Data(#"{"content":[{"type":"text","text":"uno "},{"type":"text","text":"dos"}]}"#.utf8))
        }

        #expect(try await sut.summarize(request) == "uno dos")
    }

    @Test("non-text blocks are ignored rather than rendered")
    func ignoresNonTextBlocks() async throws {
        let sut = provider { _ in
            (200, Data(#"{"content":[{"type":"thinking"},{"type":"text","text":"la nota"}]}"#.utf8))
        }

        #expect(try await sut.summarize(request) == "la nota")
    }

    @Test("a response with no text is an error, not an empty note")
    func emptyResponseFails() async throws {
        let sut = provider { _ in (200, Data(#"{"content":[]}"#.utf8)) }

        await #expect(throws: SummaryError.emptyResponse) {
            try await sut.summarize(request)
        }
    }

    // MARK: - Failures

    @Test("a rejected key says so instead of showing a status code")
    func unauthorized() async throws {
        let sut = provider { _ in (401, Data(#"{"error":{"message":"invalid x-api-key"}}"#.utf8)) }

        await #expect(throws: SummaryError.unauthorized) {
            try await sut.summarize(request)
        }
    }

    @Test("rate limiting is told apart from a real failure")
    func rateLimited() async throws {
        let sut = provider { _ in (429, Data("{}".utf8)) }

        await #expect(throws: SummaryError.rateLimited) {
            try await sut.summarize(request)
        }
    }

    @Test("Anthropic's own explanation is what the user is shown")
    func surfacesServerMessage() async throws {
        let sut = provider { _ in
            (400, Data(#"{"error":{"message":"max_tokens is too large"}}"#.utf8))
        }

        await #expect(throws: SummaryError.server(status: 400, message: "max_tokens is too large")) {
            try await sut.summarize(request)
        }
    }

    @Test("no key means nothing is sent at all")
    func missingKeyNeverCalls() async throws {
        let called = Locked(false)
        let sut = provider(key: nil) { _ in
            called.withValue { $0 = true }
            return (200, self.success("no debería llegar acá"))
        }

        await #expect(throws: SummaryError.missingAPIKey) {
            try await sut.summarize(request)
        }
        #expect(!called.value)
    }

    @Test("an empty transcript is refused before the network")
    func emptyTranscriptNeverCalls() async throws {
        let called = Locked(false)
        let sut = provider { _ in
            called.withValue { $0 = true }
            return (200, self.success("no"))
        }

        await #expect(throws: SummaryError.emptyTranscript) {
            try await sut.summarize(SummaryRequest(instruction: "x", transcript: "   "))
        }
        #expect(!called.value)
    }
}

// MARK: - Doubles

/// A value a `@Sendable` closure can write to from whatever thread it runs on.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func withValue<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }
}

/// Keychain access, faked by pointing the store at a service nothing else uses.
private enum StubKeys {
    static func store(returning key: String?) -> APIKeyStore {
        let store = APIKeyStore(
            service: "com.leomarzo.tranlix.tests", account: UUID().uuidString
        )
        if let key { try? store.save(key) }
        return store
    }
}

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

private extension URLRequest {
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
