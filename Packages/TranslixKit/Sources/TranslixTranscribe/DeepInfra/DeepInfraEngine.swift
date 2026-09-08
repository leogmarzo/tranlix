import Foundation
import TranslixModel

/// Whisper `large-v3` running on DeepInfra's servers.
///
/// The cheap half of the remote story: it transcribes and nothing else, leaving speakers to
/// the local diarizer — which is free, already installed, and runs at roughly a hundred times
/// real time. Transcription is the part that was melting laptops, and the part worth paying
/// somebody else to do.
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

    private let apiKey: @Sendable () -> String?
    private let model: String
    private let baseURL: URL
    private let session: URLSession

    public init(
        apiKey: @escaping @Sendable () -> String?,
        model: String = DeepInfraEngine.defaultModel,
        baseURL: URL = DeepInfraEngine.defaultBaseURL,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
        self.session = session
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

        progress(.uploading(0))

        var request = URLRequest(
            url: baseURL.appending(path: "v1/inference/\(model)")
        )
        request.httpMethod = "POST"
        // Their own examples spell it lowercase; the header name is case-insensitive but the
        // scheme token is what their gateway matches on.
        request.setValue("bearer \(key)", forHTTPHeaderField: "Authorization")
        // One request carries the whole track, so the default minute is nowhere near enough
        // for an hour of audio on a domestic uplink.
        request.timeoutInterval = 900

        let body = MultipartBody()
        body.appendFile(
            named: "audio",
            fileName: trackFile.lastPathComponent,
            contentType: "audio/m4a",
            data: try Data(contentsOf: trackFile, options: .mappedIfSafe)
        )
        // Word-level timings, which is what lets the local diarizer cut a segment where the
        // voice changes rather than attributing the whole thing to one person.
        body.appendField(named: "chunk_level", value: "word")
        // Named only when the session asked for a fixed language; otherwise Whisper detects,
        // which is the whole point of `.automatic`.
        if let code = language.whisperLanguageCode {
            body.appendField(named: "language", value: code)
        }
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body.finished()

        progress(.waiting)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranscriptionError.engineFailed(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            if status == 401 || status == 403 {
                throw TranscriptionError.modelUnavailable(Self.rejectedKeyMessage)
            }
            let detail = String(data: data.prefix(300), encoding: .utf8) ?? "sin detalle"
            throw TranscriptionError.engineFailed("DeepInfra respondió \(status): \(detail)")
        }

        let decoded: DeepInfraTranscription
        do {
            decoded = try JSONDecoder().decode(DeepInfraTranscription.self, from: data)
        } catch {
            // The body goes in the message. A decoding error on its own names a missing key
            // and nothing about what actually arrived, which is a diagnosis nobody can make
            // from the error alone — this one cost a round trip to work out.
            let body = String(data: data.prefix(400), encoding: .utf8) ?? "(ilegible)"
            throw TranscriptionError.engineFailed(
                "No se pudo leer la respuesta de DeepInfra: \(error.localizedDescription). "
                    + "Respondió: \(body)"
            )
        }

        return TrackTranscription(
            segments: DeepInfraMapper.segments(for: decoded, track: track),
            // Whisper does not separate voices; the chain diarizes locally afterwards.
            turns: [],
            detectedLanguage: language == .automatic ? decoded.language : nil
        )
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

/// Assembles a `multipart/form-data` body.
///
/// Written by hand rather than pulled in as a dependency: it is thirty lines, and the audio
/// is appended as raw bytes so an hour-long track is copied once rather than base64-expanded.
final class MultipartBody {
    private let boundary = "translix-\(UUID().uuidString)"
    private var data = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    func appendField(named name: String, value: String) {
        data.append(Data("--\(boundary)\r\n".utf8))
        data.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        data.append(Data("\(value)\r\n".utf8))
    }

    func appendFile(named name: String, fileName: String, contentType: String, data payload: Data) {
        data.append(Data("--\(boundary)\r\n".utf8))
        data.append(Data(
            "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n".utf8
        ))
        data.append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
        data.append(payload)
        data.append(Data("\r\n".utf8))
    }

    func finished() -> Data {
        var body = data
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }
}
