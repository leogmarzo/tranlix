import AVFoundation
import Foundation
import Speech
import TranlixModel

/// Transcription through Apple's on-device `SpeechAnalyzer`, native to macOS 26.
///
/// The default engine, because it costs nothing to ship: no model to bundle, no gigabyte to
/// download before the first session, and nothing extra to sign or notarize. Benchmarks put
/// it ahead of `large-v3-turbo` on speed at comparable quality.
///
/// What it cannot do is detect the language. Apple's transcriber is built around a chosen
/// locale, so `.automatic` is reported unsupported here rather than quietly transcribing a
/// Spanish class with an English model. That is a real difference from WhisperKit, and the
/// point of keeping both is that the user can see it.
public struct AppleSpeechEngine: TranscriptionEngine {
    public let id = EngineID.apple
    public let displayName = "Apple (macOS)"

    public init() {}

    // MARK: - Availability

    public func availability(for language: TranscriptionLanguage) async -> EngineAvailability {
        guard SpeechTranscriber.isAvailable else {
            return .unsupported(reason: "La transcripción del sistema no está disponible en este Mac.")
        }
        guard case let .fixed(identifier) = language else {
            return .unsupported(
                reason: "El motor de Apple necesita un idioma fijo. Elegí Español o English, o usá WhisperKit."
            )
        }
        guard let locale = await supportedLocale(for: identifier) else {
            return .unsupported(reason: "El motor de Apple no soporta \(identifier).")
        }

        let installed = await SpeechTranscriber.installedLocales
        if installed.contains(where: { $0.matches(locale) }) {
            return .ready
        }
        // The Speech framework does not publish asset sizes ahead of the request, and
        // guessing a number that ends up wrong is worse than admitting we do not know.
        return .needsDownload(estimatedBytes: nil)
    }

    // MARK: - Preparing

    public func prepare(
        for language: TranscriptionLanguage,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard case let .fixed(identifier) = language else {
            throw TranscriptionError.languageNotSupported("auto", engine: displayName)
        }
        guard let locale = await supportedLocale(for: identifier) else {
            throw TranscriptionError.languageNotSupported(identifier, engine: displayName)
        }

        try await reserve(locale)

        let transcriber = makeTranscriber(locale: locale)
        guard let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) else {
            progress(1)
            return // already installed
        }

        // `downloadAndInstall` reports nothing on its own, so the request's Progress is
        // sampled alongside it. Downloads here are hundreds of megabytes and the user is
        // waiting on a bar that would otherwise sit at zero.
        let reporter = Task {
            while !Task.isCancelled {
                progress(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { reporter.cancel() }

        try await request.downloadAndInstall()
        progress(1)
    }

    /// Locale assets are a limited resource; the system caps how many may be held at once.
    /// Reserving ours, and freeing someone else's if we are at the cap, is what keeps a
    /// second language from failing to install months after the first.
    private func reserve(_ locale: Locale) async throws {
        let reserved = await AssetInventory.reservedLocales
        guard !reserved.contains(where: { $0.matches(locale) }) else { return }

        if await reserved.count >= AssetInventory.maximumReservedLocales,
           let evictable = reserved.first
        {
            _ = await AssetInventory.release(reservedLocale: evictable)
        }
        _ = try await AssetInventory.reserve(locale: locale)
    }

    // MARK: - Transcribing

    public func transcribe(
        chunk url: URL,
        language: TranscriptionLanguage,
        track: AudioTrack
    ) async throws -> [TranscriptSegment] {
        guard case let .fixed(identifier) = language else {
            throw TranscriptionError.languageNotSupported("auto", engine: displayName)
        }
        guard let locale = await supportedLocale(for: identifier) else {
            throw TranscriptionError.languageNotSupported(identifier, engine: displayName)
        }
        guard let file = try? AVAudioFile(forReading: url) else {
            throw TranscriptionError.audioUnreadable(url)
        }

        let transcriber = makeTranscriber(locale: locale)
        let analyzer: SpeechAnalyzer
        do {
            // `finishAfterFile` makes the results sequence terminate at the end of the chunk
            // instead of waiting for more input that will never come.
            analyzer = try await SpeechAnalyzer(
                inputAudioFile: file,
                modules: [transcriber],
                finishAfterFile: true
            )
        } catch {
            throw TranscriptionError.engineFailed(error.localizedDescription)
        }

        var segments: [TranscriptSegment] = []
        do {
            for try await result in transcriber.results {
                guard let segment = segment(from: result, track: track) else { continue }
                segments.append(segment)
            }
        } catch {
            throw TranscriptionError.engineFailed(error.localizedDescription)
        }
        withExtendedLifetime(analyzer) {}

        return segments
    }

    private func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            // No volatile results: this runs over a finished file, so partial guesses that
            // get revised are pure overhead.
            reportingOptions: [],
            // Word-level timing is what lets diarization line up with the text later.
            attributeOptions: [.audioTimeRange]
        )
    }

    private func segment(
        from result: SpeechTranscriber.Result,
        track: AudioTrack
    ) -> TranscriptSegment? {
        let text = String(result.text.characters)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        return TranscriptSegment(
            track: track,
            start: result.range.start.seconds,
            end: result.range.end.seconds,
            text: text,
            words: words(in: result.text)
        )
    }

    private func words(in text: AttributedString) -> [TranscriptWord] {
        text.runs.compactMap { run in
            guard let range = run.audioTimeRange else { return nil }
            let word = String(text[run.range].characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { return nil }
            return TranscriptWord(
                text: word,
                start: range.start.seconds,
                end: range.end.seconds
            )
        }
    }

    /// Maps a requested identifier onto whatever variant this Mac actually has.
    ///
    /// There is no `es-AR`, so a Rioplatense session asks for `es-CL` and this is what finds
    /// the nearest installed equivalent rather than failing outright.
    private func supportedLocale(for identifier: String) async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier))
    }
}

extension Locale {
    /// Compares on BCP-47, since the same locale can be spelled several ways.
    func matches(_ other: Locale) -> Bool {
        identifier(.bcp47).caseInsensitiveCompare(other.identifier(.bcp47)) == .orderedSame
    }
}
