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
        stream(deltas: [text])
    }

    /// A streamed answer as the Messages API sends it. `stopReason: nil` leaves out the
    /// closing events, the way a dropped connection does.
    private func stream(
        deltas: [String],
        thinking: [String] = [],
        stopReason: String? = "end_turn"
    ) -> Data {
        var events = [#"{"type":"message_start","message":{"id":"msg_1","type":"message"}}"#]
        for chunk in thinking {
            events.append(#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"\#(chunk)"}}"#)
        }
        for chunk in deltas {
            events.append(#"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"\#(chunk)"}}"#)
        }
        if let stopReason {
            events.append(#"{"type":"message_delta","delta":{"stop_reason":"\#(stopReason)"},"usage":{"output_tokens":12}}"#)
            events.append(#"{"type":"message_stop"}"#)
        }
        let body = events.map { event in
            let name = (try? JSONSerialization.jsonObject(with: Data(event.utf8)) as? [String: Any])?["type"] as? String ?? ""
            return "event: \(name)\ndata: \(event)\n\n"
        }.joined()
        return Data(body.utf8)
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

    @Test("the answer is streamed, with room for a long meeting's notes")
    func streamsWithRoomToFinish() async throws {
        // 8,000 cut a 90-minute meeting's notes mid-word. The ceiling is shared with the
        // model's thinking, so it has to be well above what the note itself needs.
        let seen = Locked<URLRequest?>(nil)
        let sut = provider { request in
            seen.withValue { $0 = request }
            return (200, self.success("listo"))
        }

        _ = try await sut.summarize(request)

        let body = try #require(seen.value?.httpBodyData)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["stream"] as? Bool == true)
        #expect(json["max_tokens"] as? Int == 64000)
    }

    // MARK: - The response

    @Test("text deltas come back joined")
    func joinsTextDeltas() async throws {
        let sut = provider { _ in (200, self.stream(deltas: ["uno ", "dos"])) }

        #expect(try await sut.summarize(request) == SummaryReply(text: "uno dos"))
    }

    @Test("thinking is left out of the note")
    func ignoresThinking() async throws {
        let sut = provider { _ in
            (200, self.stream(deltas: ["la nota"], thinking: ["pensando"]))
        }

        #expect(try await sut.summarize(request).text == "la nota")
    }

    @Test("an answer cut at the output ceiling is marked as cut")
    func flagsTruncation() async throws {
        let sut = provider { _ in
            (200, self.stream(deltas: ["**Baref"], stopReason: "max_tokens"))
        }

        let reply = try await sut.summarize(request)
        #expect(reply.isTruncated)
        #expect(reply.text == "**Baref")
    }

    @Test("a finished answer is not marked as cut")
    func finishedIsWhole() async throws {
        let sut = provider { _ in (200, self.success("la nota")) }

        #expect(try await sut.summarize(request).isTruncated == false)
    }

    @Test("a stream that ends without a stop reason is a failure, not a short note")
    func droppedStreamFails() async throws {
        let sut = provider { _ in (200, self.stream(deltas: ["media no"], stopReason: nil)) }

        await #expect(throws: SummaryError.transport("la respuesta se cortó antes de terminar")) {
            try await sut.summarize(request)
        }
    }

    @Test("an error event after the 200 is surfaced")
    func midStreamError() async throws {
        let body = """
        event: error
        data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}


        """
        let sut = provider { _ in (200, Data(body.utf8)) }

        await #expect(throws: SummaryError.server(status: 200, message: "Overloaded")) {
            try await sut.summarize(request)
        }
    }

    @Test("a response with no text is an error, not an empty note")
    func emptyResponseFails() async throws {
        let sut = provider { _ in (200, self.stream(deltas: [])) }

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
