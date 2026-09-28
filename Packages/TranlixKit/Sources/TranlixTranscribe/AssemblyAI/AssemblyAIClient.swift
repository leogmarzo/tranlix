import Foundation

/// What one AssemblyAI job should do, decided per track by the engine.
public struct AssemblyAIRequest: Sendable, Equatable {
    public var speakerLabels: Bool
    public var languageCode: String?
    public var languageDetection: Bool

    public init(
        speakerLabels: Bool,
        languageCode: String? = nil,
        languageDetection: Bool = false
    ) {
        self.speakerLabels = speakerLabels
        self.languageCode = languageCode
        self.languageDetection = languageDetection
    }
}

/// Where a job is, for the progress strip.
public enum AssemblyAIProgress: Sendable, Equatable {
    case uploading(Double)
    case waiting
}

/// The HTTP surface of AssemblyAI's async API: upload a file, create a job, poll it.
///
/// Everything is injectable — key, session, base URL, poll cadence — so the tests run against
/// a stubbed transport and the engine against the real one. The upload streams from disk
/// rather than loading the file: a six-hour track is ninety megabytes that have no reason to
/// visit memory.
public actor AssemblyAIClient {
    public static let defaultBaseURL = URL(string: "https://api.assemblyai.com")!

    private let apiKey: @Sendable () -> String?
    private let session: URLSession
    private let baseURL: URL
    private let pollInterval: Duration

    public init(
        apiKey: @escaping @Sendable () -> String?,
        session: URLSession = .shared,
        baseURL: URL = AssemblyAIClient.defaultBaseURL,
        pollInterval: Duration = .seconds(3)
    ) {
        self.apiKey = apiKey
        self.session = session
        self.baseURL = baseURL
        self.pollInterval = pollInterval
    }

    static let missingKeyMessage =
        "Falta la clave de API de AssemblyAI. Cargala en Ajustes → Transcripción."

    static let rejectedKeyMessage =
        "AssemblyAI rechazó la clave de API. Revisala en Ajustes → Transcripción."

    // MARK: - The whole job

    /// Uploads a file, creates a transcription job for it, and polls until it resolves.
    public func transcribe(
        file: URL,
        request: AssemblyAIRequest,
        progress: @escaping @Sendable (AssemblyAIProgress) -> Void
    ) async throws -> AssemblyAITranscript {
        guard let key = apiKey(), !key.isEmpty else {
            throw TranscriptionError.modelUnavailable(Self.missingKeyMessage)
        }

        progress(.uploading(0))
        let upload = try await uploadAudio(file, key: key, progress: progress)
        progress(.waiting)

        let job = try await createJob(audioURL: upload.uploadURL, request: request, key: key)

        var current = job
        while true {
            switch current.status {
            case .completed:
                return current
            case .error:
                throw TranscriptionError.engineFailed(
                    current.error ?? "AssemblyAI no explicó por qué falló el trabajo."
                )
            case .queued, .processing:
                // Between polls, which bounds a cancellation to one poll's wait. The job
                // keeps running server-side; a re-run picks the result up by uploading and
                // transcribing again.
                try Task.checkCancellation()
                try await Task.sleep(for: pollInterval)
                current = try await poll(job.id, key: key)
            }
        }
    }

    // MARK: - Requests

    private func uploadAudio(
        _ file: URL,
        key: String,
        progress: @escaping @Sendable (AssemblyAIProgress) -> Void
    ) async throws -> AssemblyAIUpload {
        var request = URLRequest(url: baseURL.appending(path: "v2/upload"))
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "content-type")
        // A slow uplink pushing a long recording needs more patience than the default 60 s
        // between progress events; the resource itself has no deadline worth imposing.
        request.timeoutInterval = 600

        let (data, response) = try await perform {
            try await self.session.upload(
                for: request, fromFile: file, delegate: UploadProgress(progress)
            )
        }
        try ensure(response, data: data)
        return try decode(AssemblyAIUpload.self, from: data)
    }

    private func createJob(
        audioURL: String,
        request: AssemblyAIRequest,
        key: String
    ) async throws -> AssemblyAITranscript {
        var urlRequest = URLRequest(url: baseURL.appending(path: "v2/transcript"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(key, forHTTPHeaderField: "authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.httpBody = try JSONEncoder().encode(JobBody(
            audioURL: audioURL,
            speakerLabels: request.speakerLabels,
            languageCode: request.languageCode,
            languageDetection: request.languageDetection ? true : nil
        ))

        let (data, response) = try await perform {
            try await self.session.data(for: urlRequest)
        }
        try ensure(response, data: data)
        return try decode(AssemblyAITranscript.self, from: data)
    }

    private func poll(_ id: String, key: String) async throws -> AssemblyAITranscript {
        var request = URLRequest(url: baseURL.appending(path: "v2/transcript/\(id)"))
        request.setValue(key, forHTTPHeaderField: "authorization")

        let (data, response) = try await perform {
            try await self.session.data(for: request)
        }
        try ensure(response, data: data)
        return try decode(AssemblyAITranscript.self, from: data)
    }

    // MARK: - Plumbing

    /// Wraps transport failures in the pipeline's own error, keeping cancellation itself.
    private func perform(
        _ work: () async throws -> (Data, URLResponse)
    ) async throws -> (Data, URLResponse) {
        do {
            return try await work()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TranscriptionError {
            throw error
        } catch {
            throw TranscriptionError.engineFailed(error.localizedDescription)
        }
    }

    private func ensure(_ response: URLResponse, data: Data) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard !(200 ..< 300).contains(status) else { return }
        if status == 401 || status == 403 {
            throw TranscriptionError.modelUnavailable(Self.rejectedKeyMessage)
        }
        let detail = String(data: data.prefix(300), encoding: .utf8) ?? "sin detalle"
        throw TranscriptionError.engineFailed("AssemblyAI respondió \(status): \(detail)")
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw TranscriptionError.engineFailed(
                "No se pudo leer la respuesta de AssemblyAI: \(error.localizedDescription)"
            )
        }
    }

    /// The job creation body. `speech_models` is pinned so AssemblyAI's routing changes never
    /// silently change what a session costs; upgrading is a one-string decision here.
    private struct JobBody: Encodable {
        let audioURL: String
        let speechModels = ["universal-2"]
        let speakerLabels: Bool
        let languageCode: String?
        let languageDetection: Bool?

        enum CodingKeys: String, CodingKey {
            case audioURL = "audio_url"
            case speechModels = "speech_models"
            case speakerLabels = "speaker_labels"
            case languageCode = "language_code"
            case languageDetection = "language_detection"
        }
    }
}

/// Relays upload progress out of the session's delegate queue.
private final class UploadProgress: NSObject, URLSessionTaskDelegate {
    private let report: @Sendable (AssemblyAIProgress) -> Void

    init(_ report: @escaping @Sendable (AssemblyAIProgress) -> Void) {
        self.report = report
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didSendBodyData _: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(.uploading(Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}
