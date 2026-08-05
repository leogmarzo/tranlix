import AVFoundation
import Foundation
import TranlixModel
import WhisperKit

/// Transcription through Whisper `large-v3-turbo`, running on CoreML.
///
/// The scope asked for whisper.cpp; this is the same model without a C build system to
/// maintain or hand-signed binaries to notarize, which is worth a great deal by phase 5.
///
/// It exists alongside Apple's engine rather than instead of it, for two reasons. Whisper can
/// detect the language, which Apple's transcriber cannot. And Whisper has no notion of
/// regional variants, so where Apple has to approximate Rioplatense with `es-CL`, Whisper
/// simply transcribes Spanish — which of those does better on a real class is a question only
/// running both on the same recording can answer.
public actor WhisperKitEngine: TranscriptionEngine {
    public nonisolated let id = EngineID.whisperKit
    public nonisolated let displayName = "WhisperKit (large-v3-turbo)"

    /// Model variant on the `argmaxinc/whisperkit-coreml` repository.
    public nonisolated let variant: String

    /// Where models are kept.
    ///
    /// Application Support rather than WhisperKit's default under Documents: this is cached
    /// data the user did not create, it should not clutter their documents, and keeping it
    /// somewhere we choose is what lets Settings report its size and offer to remove it.
    public nonisolated let modelsDirectory: URL

    /// Loading the model costs seconds and hundreds of megabytes of memory, so it is done
    /// once and held for the rest of the session rather than per chunk.
    private var loaded: WhisperKit?

    public init(
        variant: String = WhisperKitEngine.defaultVariant,
        modelsDirectory: URL = WhisperKitEngine.defaultModelsDirectory
    ) {
        self.variant = variant
        self.modelsDirectory = modelsDirectory
    }

    public static let defaultVariant = "openai_whisper-large-v3-v20240930_turbo"

    /// The share of `prepare`'s progress that downloading accounts for. The remainder is the
    /// model load, which reports nothing and is the part that looks like a freeze.
    public static let downloadShare = 0.85

    public static var defaultModelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(filePath: NSTemporaryDirectory())
        return base.appending(path: "Tranlix/Models")
    }

    // MARK: - Availability

    public func availability(for _: TranscriptionLanguage) async -> EngineAvailability {
        // Whisper is multilingual and can detect the language, so every language this app
        // offers is fine. Only the model download stands in the way.
        installedModelFolder() == nil
            ? .needsDownload(estimatedBytes: Self.approximateModelBytes)
            : .ready
    }

    /// Roughly what `large-v3-turbo` occupies once unpacked. Reported so the user can weigh
    /// it against free disk before committing.
    public static let approximateModelBytes: Int64 = 1_600_000_000

    /// The unpacked model directory, if it is already on disk.
    public nonisolated func installedModelFolder() -> URL? {
        let enumerator = FileManager.default.enumerator(
            at: modelsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        while let candidate = enumerator?.nextObject() as? URL {
            guard candidate.lastPathComponent == variant,
                  (try? candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { continue }
            // A folder with no weights in it is a failed download, not an installed model.
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: candidate.path)) ?? []
            if contents.contains(where: { $0.hasSuffix(".mlmodelc") }) {
                return candidate
            }
        }
        return nil
    }

    /// Bytes the installed model occupies, for Settings.
    public nonisolated func installedModelBytes() -> Int64? {
        guard let folder = installedModelFolder() else { return nil }
        let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.fileSizeKey]
        )
        var total: Int64 = 0
        while let url = enumerator?.nextObject() as? URL {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    public nonisolated func removeInstalledModel() throws {
        guard let folder = installedModelFolder() else { return }
        try FileManager.default.removeItem(at: folder)
    }

    // MARK: - Preparing

    public func prepare(
        for _: TranscriptionLanguage,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        if installedModelFolder() == nil {
            try FileManager.default.createDirectory(
                at: modelsDirectory, withIntermediateDirectories: true
            )
            do {
                _ = try await WhisperKit.download(
                    variant: variant,
                    downloadBase: modelsDirectory,
                    // Downloading is only most of the job, so it only gets most of the bar.
                    // What follows is a Neural Engine compile that reports nothing and takes
                    // its own minute, and a bar sitting at 100% through it looks like a hang.
                    progressCallback: { progress($0.fractionCompleted * Self.downloadShare) }
                )
            } catch {
                throw TranscriptionError.modelUnavailable(error.localizedDescription)
            }
        }
        progress(Self.downloadShare)

        // Loading is part of being prepared: doing it here means the first chunk is not
        // several seconds slower than the rest for no visible reason. On a cold model this
        // is where the system compiles for the Neural Engine, which happens in an XPC
        // service and can take a minute with this process sitting at zero CPU.
        _ = try await kit()
        progress(1)
    }

    private func kit() async throws -> WhisperKit {
        if let loaded { return loaded }

        guard let folder = installedModelFolder() else {
            throw TranscriptionError.modelUnavailable(
                "el modelo \(variant) todavía no está descargado"
            )
        }
        do {
            let config = WhisperKitConfig(
                modelFolder: folder.path,
                verbose: false,
                prewarm: true,
                load: true,
                download: false
            )
            let kit = try await WhisperKit(config)
            loaded = kit
            return kit
        } catch {
            throw TranscriptionError.modelUnavailable(error.localizedDescription)
        }
    }

    /// Frees the model's memory. Worth doing once a session's transcription is finished,
    /// since holding well over a gigabyte for an idle app is rude on a 16 GB machine.
    public func unload() {
        loaded = nil
    }

    // MARK: - Transcribing

    /// How Whisper is asked to decode a chunk.
    ///
    /// Deliberately leaves `chunkingStrategy` unset, which keeps WhisperKit on its sequential
    /// path. Setting it to `.vad` is tempting — Whisper decodes in 30-second windows and laying
    /// them end to end from the start of the file puts boundaries mid-word, which is where the
    /// model loses its run-up and where its repetition loops start — but on this version it
    /// also routes into `transcribeWithOptions(audioArrays:)`, which fans the windows out over
    /// `concurrentWorkerCount` tasks, defaulting to *sixteen* on macOS. Sixteen tasks driving
    /// one CoreML model segfaults in `objc_autoreleasePoolPop`. Revisit with
    /// `concurrentWorkerCount: 1`, and only with a long recording to prove it.
    static func decodingOptions(for language: TranscriptionLanguage) -> DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            // Whisper wants a bare language code, not a regional identifier: `es`, not
            // `es-CL`. It has no notion of variants.
            language: language.whisperLanguageCode,
            detectLanguage: language == .automatic,
            // Whisper's control tokens default to being left in. Without this the transcript
            // reads `<|startoftranscript|><|es|><|transcribe|><|12.16|> Buenos días…`, which
            // is not text anyone can use and would go to the summariser verbatim.
            skipSpecialTokens: true,
            wordTimestamps: true
        )
    }

    public func transcribe(
        chunk url: URL,
        language: TranscriptionLanguage,
        track: AudioTrack
    ) async throws -> [TranscriptSegment] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriptionError.audioUnreadable(url)
        }
        let kit = try await kit()

        let options = Self.decodingOptions(for: language)

        let results: [TranscriptionResult]
        do {
            results = try await kit.transcribe(audioPath: url.path, decodeOptions: options)
        } catch {
            throw TranscriptionError.engineFailed(error.localizedDescription)
        }

        return results.flatMap(\.segments).compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptSegment(
                track: track,
                start: TimeInterval(segment.start),
                end: TimeInterval(segment.end),
                text: text,
                words: (segment.words ?? []).compactMap { word in
                    let cleaned = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleaned.isEmpty else { return nil }
                    return TranscriptWord(
                        text: cleaned,
                        start: TimeInterval(word.start),
                        end: TimeInterval(word.end)
                    )
                }
            )
        }
    }
}

extension TranscriptionLanguage {
    /// The bare language code Whisper expects, dropping any region.
    var whisperLanguageCode: String? {
        guard let identifier else { return nil }
        return identifier.split(separator: "-").first.map(String.init)?.lowercased()
    }
}
