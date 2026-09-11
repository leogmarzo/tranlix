import Foundation
import TranslixModel

/// Whisper `large-v3` running on DeepInfra's servers.
///
/// The cheap half of the remote story: it transcribes and nothing else, leaving speakers to
/// the local diarizer — which is free, already installed, and runs at roughly a hundred times
/// real time. Transcription is the part that was melting laptops, and the part worth paying
/// somebody else to do.
///
/// Their inference endpoint is synchronous: there is no job to poll and no id to come back
/// to, so one request has to cover upload, queue, inference and download. That shape is why
/// `maxUploadSeconds` exists here. On 2026-09-10 a twenty-four-minute track uploaded cleanly
/// in under eight seconds and then drew **no response at all** for nine hundred — and because
/// the whole track was one request, the whole session was lost with it.
public actor DeepInfraEngine: TrackTranscribing {
    public nonisolated let id = EngineID.deepInfra
    public nonisolated let displayName = "DeepInfra (Whisper large-v3)"

    /// Whisper brings no notion of who is speaking, so the chain must still diarize locally.
    public nonisolated let separatesSpeakers = false

    /// Keychain service holding the API token. Fixed forever, like the other two.
    public static let keychainService = "com.leomarzo.tranlix.deepinfra"

    /// The full model rather than `-turbo`: turbo is a pruned distillation that gives up the
    /// most on languages other than English, and the difference costs about three dollars a
    /// month at this volume.
    public static let defaultModel = "openai/whisper-large-v3"

    public static let defaultBaseURL = URL(string: "https://api.deepinfra.com")!

    /// Ten minutes of audio per request, about 2.4 MB at the archiver's bitrate.
    ///
    /// Short enough that losing one costs ten minutes rather than a meeting, long enough that
    /// an hour-long session is six requests per track rather than twelve. It also bounds the
    /// job on their side, which matters more than it looks: word-level alignment over
    /// twenty-four minutes is a long serial piece of work, and the failure it produced was a
    /// handler that never finished rather than a network that broke.
    public static let defaultMaxUploadSeconds: Double = 600

    /// Four minutes without a byte from them.
    ///
    /// `timeoutInterval` is an inactivity timer, not a budget for the whole run, so it wants
    /// to be proportionate to how long one batch could plausibly take to think about — a few
    /// seconds to send and a minute or two to transcribe. Four minutes of total silence is
    /// already anomalous, and three attempts of it still bounds a batch at twelve minutes
    /// while leaving every other batch untouched.
    public static let defaultRequestTimeout: TimeInterval = 240

    public nonisolated let maxUploadSeconds: Double?

    private let apiKey: @Sendable () -> String?
    private let model: String
    private let baseURL: URL
    private let session: URLSession
    private let requestTimeout: TimeInterval
    private let maxAttempts: Int
    private let retryDelay: @Sendable (Int) -> Duration

    public init(
        apiKey: @escaping @Sendable () -> String?,
        model: String = DeepInfraEngine.defaultModel,
        baseURL: URL = DeepInfraEngine.defaultBaseURL,
        session: URLSession = .shared,
        maxUploadSeconds: Double = DeepInfraEngine.defaultMaxUploadSeconds,
        requestTimeout: TimeInterval = DeepInfraEngine.defaultRequestTimeout,
        maxAttempts: Int = RemoteRetry.maxAttempts,
        retryDelay: @escaping @Sendable (Int) -> Duration = RemoteRetry.backoff
    ) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
        self.session = session
        self.maxUploadSeconds = maxUploadSeconds
        self.requestTimeout = requestTimeout
        self.maxAttempts = maxAttempts
        self.retryDelay = retryDelay
    }

    static let missingKeyMessage =
        "Falta la clave de API de DeepInfra. Cargala en Ajustes → Transcripción."

    static let rejectedKeyMessage =
        "DeepInfra rechazó la clave de API. Revisala en Ajustes → Transcripción."

    // MARK: - Availability

    public func availability(for _: TranscriptionLanguage) async -> EngineAvailability {
        guard let key = apiKey(), !key.isEmpty else {
            return .unsupported(reason: Self.missingKeyMessage)
        }
        return .ready
    }

    /// Nothing to prepare: the model lives on their servers.
    public func prepare(
        for _: TranscriptionLanguage,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        progress(1)
    }

    // MARK: - Transcribing

    public func transcribe(
        trackFile: URL,
        track: AudioTrack,
        language: TranscriptionLanguage,
        progress: @escaping @Sendable (TrackTranscriptionPhase) -> Void
    ) async throws -> TrackTranscription {
        guard let key = apiKey(), !key.isEmpty else {
            throw TranscriptionError.modelUnavailable(Self.missingKeyMessage)
        }
        guard FileManager.default.fileExists(atPath: trackFile.path) else {
            throw TranscriptionError.audioUnreadable(trackFile)
        }

        let body = MultipartBody()
        body.appendFile(
            named: "audio",
            fileName: trackFile.lastPathComponent,
            contentType: "audio/m4a",
            at: trackFile
        )
        // Word-level timings, which is what lets the local diarizer cut a segment where the
        // voice changes rather than attributing the whole thing to one person.
        body.appendField(named: "chunk_level", value: "word")
        // Named only when the session asked for a fixed language; otherwise Whisper detects,
        // which is the whole point of `.automatic`.
        if let code = language.whisperLanguageCode {
            body.appendField(named: "language", value: code)
        }

        // Assembled on disk once and uploaded from there on every attempt. The audio is never
        // held in memory, and a retry re-sends the same bytes instead of rebuilding them.
        let envelope = URL(filePath: NSTemporaryDirectory())
            .appending(path: "translix-deepinfra-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: envelope) }
        try body.write(to: envelope)

        progress(.uploading(0))

        let decoded: DeepInfraTranscription
        do {
            decoded = try await RemoteRetry.perform(
                maxAttempts: maxAttempts,
                delay: retryDelay,
                reportingRetry: { attempt, total in
                    progress(.retrying(attempt: attempt, of: total))
                }
            ) { attempt in
                try await self.send(
                    envelope: envelope,
                    contentType: body.contentType,
                    key: key,
                    attempt: attempt,
                    progress: progress
                )
            }
        } catch let exhausted as RemoteRetry.Exhausted {
            throw Self.error(for: exhausted)
        }

        return TrackTranscription(
            segments: DeepInfraMapper.segments(for: decoded, track: track),
            // Whisper does not separate voices; the chain diarizes locally afterwards.
            turns: [],
            detectedLanguage: language == .automatic ? decoded.language : nil
        )
    }

    private func send(
        envelope: URL,
        contentType: String,
        key: String,
        attempt: Int,
        progress: @escaping @Sendable (TrackTranscriptionPhase) -> Void
    ) async throws -> DeepInfraTranscription {
        var request = URLRequest(url: baseURL.appending(path: "v1/inference/\(model)"))
        request.httpMethod = "POST"
        // Their own examples spell it lowercase; the header name is case-insensitive but the
        // scheme token is what their gateway matches on.
        request.setValue("bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = requestTimeout

        let delegate = UploadProgressDelegate { fraction in
            // A later attempt has already reported `.retrying`, and reporting upload
            // fractions again from there would walk the progress bar backwards. Only the
            // moment the body is fully out is worth saying twice.
            if fraction >= 1 {
                progress(.waiting)
            } else if attempt == 1 {
                progress(.uploading(fraction))
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(
                for: request, fromFile: envelope, delegate: delegate
            )
        } catch {
            throw RemoteRetry.classify(error, bodyFullySent: delegate.bodyFullySent)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            if status == 401 || status == 403 {
                // Thrown past the retry policy on purpose: a key they have already refused is
                // not going to be accepted on the second upload, and the advice is specific.
                throw TranscriptionError.modelUnavailable(Self.rejectedKeyMessage)
            }
            let detail = String(data: data.prefix(300), encoding: .utf8) ?? "sin detalle"
            throw RemoteFailure.status(status, detail: detail)
        }

        do {
            return try JSONDecoder().decode(DeepInfraTranscription.self, from: data)
        } catch {
            // The body goes in the message. A decoding error on its own names a missing key
            // and nothing about what actually arrived, which is a diagnosis nobody can make
            // from the error alone — this one cost a round trip to work out.
            let body = String(data: data.prefix(400), encoding: .utf8) ?? "(ilegible)"
            throw RemoteFailure.undecodable(detail: error.localizedDescription, body: body)
        }
    }

    /// Says what actually went wrong, in the terms someone deciding what to do next needs.
    ///
    /// The old version passed `error.localizedDescription` straight through, which on a
    /// Spanish system turned the worst failure this engine has into "Se ha agotado el tiempo
    /// de espera." — true, and useless. Whether the audio arrived is the fact that separates a
    /// server problem from a connection problem, and it is worth a sentence.
    static func error(for exhausted: RemoteRetry.Exhausted) -> TranscriptionError {
        let tries = exhausted.attempts == 1 ? "1 intento" : "\(exhausted.attempts) intentos"
        let seconds = exhausted.elapsedSeconds

        switch exhausted.failure {
        case let .transport(error, bodyFullySent):
            switch error.code {
            case .notConnectedToInternet:
                return .engineFailed(
                    "No hay conexión a internet. Reintentá cuando vuelva."
                )
            case .timedOut where bodyFullySent:
                return .engineFailed("""
                DeepInfra recibió el audio y no contestó nada en \(seconds) s, en \(tries).
                """)
            default:
                return .engineFailed("""
                Se cortó la conexión con DeepInfra a los \(seconds) s, en \(tries): \
                \(error.localizedDescription)
                """)
            }

        case let .status(status, detail):
            switch status {
            case 429:
                return .engineFailed("""
                DeepInfra está saturado (429) y no aflojó en \(tries). \
                Probá de nuevo en unos minutos.
                """)
            case 413:
                return .engineFailed("""
                DeepInfra rechazó el audio por tamaño (413). Hay que mandar bloques más cortos.
                """)
            default:
                return .engineFailed("DeepInfra respondió \(status): \(detail)")
            }

        case let .undecodable(detail, body):
            return .engineFailed(
                "No se pudo leer la respuesta de DeepInfra: \(detail). Respondió: \(body)"
            )
        }
    }

    /// A chunk is just a short track file, so it rides the same path.
    public func transcribe(
        chunk url: URL,
        language: TranscriptionLanguage,
        track: AudioTrack
    ) async throws -> EngineTranscription {
        let result = try await transcribe(
            trackFile: url, track: track, language: language
        ) { _ in }
        return EngineTranscription(
            segments: result.segments, detectedLanguage: result.detectedLanguage
        )
    }
}

/// Assembles a `multipart/form-data` body on disk.
///
/// Written by hand rather than pulled in as a dependency: it is sixty lines, and the audio is
/// copied straight from its file into the envelope rather than being read into memory and
/// then copied again to close the body.
final class MultipartBody {
    private let boundary = "translix-\(UUID().uuidString)"
    private var fields = Data()
    private var fileHeader: Data?
    private var fileURL: URL?

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    func appendField(named name: String, value: String) {
        fields.append(Data("--\(boundary)\r\n".utf8))
        fields.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        fields.append(Data("\(value)\r\n".utf8))
    }

    /// Records a file to be copied into the body. The file is not read until `write(to:)`.
    func appendFile(named name: String, fileName: String, contentType: String, at url: URL) {
        var header = Data()
        header.append(Data("--\(boundary)\r\n".utf8))
        header.append(Data(
            "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n".utf8
        ))
        header.append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
        fileHeader = header
        fileURL = url
    }

    /// Streams the assembled body to `destination`.
    func write(to destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw TranscriptionError.audioUnreadable(destination)
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        if let fileHeader, let fileURL {
            try output.write(contentsOf: fileHeader)
            let input = try FileHandle(forReadingFrom: fileURL)
            defer { try? input.close() }
            while let block = try input.read(upToCount: 1 << 20), !block.isEmpty {
                try output.write(contentsOf: block)
            }
            try output.write(contentsOf: Data("\r\n".utf8))
        }

        try output.write(contentsOf: fields)
        try output.write(contentsOf: Data("--\(boundary)--\r\n".utf8))
    }
}
