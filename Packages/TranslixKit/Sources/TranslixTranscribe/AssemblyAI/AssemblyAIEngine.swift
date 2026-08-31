import Foundation
import TranslixModel

/// Transcription and speaker separation through AssemblyAI's servers.
public actor AssemblyAIEngine: TrackTranscribing {
    public nonisolated let id = EngineID.assemblyAI
    public nonisolated let displayName = "AssemblyAI (nube)"

    /// Keychain service holding the API key. Fixed forever, like the Anthropic one: a
    /// renamed service would silently read back nothing.
    public static let keychainService = "com.leomarzo.tranlix.assemblyai"

    private let apiKey: @Sendable () -> String?
    private let client: AssemblyAIClient

    public init(
        apiKey: @escaping @Sendable () -> String?,
        session: URLSession = .shared,
        baseURL: URL = AssemblyAIClient.defaultBaseURL,
        pollInterval: Duration = .seconds(3)
    ) {
        self.apiKey = apiKey
        client = AssemblyAIClient(
            apiKey: apiKey, session: session, baseURL: baseURL, pollInterval: pollInterval
        )
    }

    // MARK: - Availability

    /// Ready with a key, for any language: both languages the app offers are covered by the
    /// pinned model, detection included, and there is nothing to download.
    public func availability(for _: TranscriptionLanguage) async -> EngineAvailability {
        guard let key = apiKey(), !key.isEmpty else {
            return .unsupported(reason: AssemblyAIClient.missingKeyMessage)
        }
        return .ready
    }

    /// Nothing to prepare: the models live on their servers.
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
        let request = AssemblyAIRequest(
            // The microphone is one known person; asking a clustering model to separate a
            // single voice could only invent speakers who are not there.
            speakerLabels: track == .system,
            // Bare code, never a region: AssemblyAI, like Whisper, has no notion of variants.
            languageCode: language.whisperLanguageCode,
            languageDetection: language == .automatic
        )

        let transcript = try await client.transcribe(file: trackFile, request: request) { phase in
            switch phase {
            case let .uploading(fraction): progress(.uploading(fraction))
            case .waiting: progress(.waiting)
            }
        }

        let (segments, turns) = AssemblyAIMapper.segments(for: transcript, track: track)
        return TrackTranscription(
            segments: segments,
            turns: turns,
            // Only reported when it was actually worked out. Asked for a fixed language, the
            // API echoes it back, and passing that on would dress an instruction up as a
            // discovery.
            detectedLanguage: language == .automatic ? transcript.languageCode : nil
        )
    }

    /// A chunk is just a short track file, so it rides the same path and drops the turns.
    public func transcribe(
        chunk url: URL,
        language: TranscriptionLanguage,
        track: AudioTrack
    ) async throws -> EngineTranscription {
        let result = try await transcribe(
            trackFile: url, track: track, language: language
        ) { _ in }
        return EngineTranscription(
            segments: result.segments,
            detectedLanguage: result.detectedLanguage
        )
    }
}
