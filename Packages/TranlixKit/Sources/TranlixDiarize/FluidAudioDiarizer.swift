import AVFoundation
import FluidAudio
import Foundation
import Synchronization
import TranlixModel

/// Speaker separation through FluidAudio's offline pyannote pipeline, on CoreML.
///
/// The offline pipeline rather than the streaming one: the app only ever diarizes a finished
/// recording, and the offline variant is allowed to look at the whole track before deciding
/// who is who — which is exactly the information a streaming model has to guess at.
///
/// The models are about 22 MB in total, small enough that this is worth having on by default
/// in a way the 1.6 GB Whisper download is not.
public actor FluidAudioDiarizer: Diarizer {
    public nonisolated let id = DiarizerID.fluidAudio
    public nonisolated let displayName = "FluidAudio (pyannote)"

    /// Where the CoreML models are cached.
    ///
    /// Under our own Application Support folder rather than FluidAudio's default, for the same
    /// reason as WhisperKit's: it is data the user did not create, and keeping it somewhere we
    /// chose is what lets Settings report its size and offer to remove it.
    public nonisolated let modelsDirectory: URL

    private var manager: Unchecked<OfflineDiarizerManager>?

    /// Carries a value that is safe to use but not marked `Sendable` across an isolation
    /// boundary.
    ///
    /// `OfflineDiarizerManager` holds its CoreML models in `nonisolated(unsafe)` storage
    /// because they are written once at load and only read afterwards — FluidAudio's own
    /// stated reasoning. It just never got the annotation, so an actor cannot hand it to its
    /// own `async` methods. The serialization that makes this safe is this actor.
    private struct Unchecked<Value>: @unchecked Sendable {
        let value: Value
    }

    public init(modelsDirectory: URL = FluidAudioDiarizer.defaultModelsDirectory) {
        self.modelsDirectory = modelsDirectory
    }

    public static var defaultModelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(filePath: NSTemporaryDirectory())
        return base.appending(path: "Tranlix/Models/Diarization")
    }

    /// Roughly what the four CoreML models occupy. Reported before the download so the choice
    /// is informed, even though at this size it rarely is a choice.
    public static let approximateModelBytes: Int64 = 22_000_000

    // MARK: - Availability

    public func availability() async -> DiarizerAvailability {
        installedModelFolder() == nil
            ? .needsDownload(estimatedBytes: Self.approximateModelBytes)
            : .ready
    }

    /// Everything the offline pipeline needs before it can load.
    ///
    /// Checked by name rather than by asking FluidAudio, because asking it means calling the
    /// loader, and the loader downloads. This has to answer "is it here?" without fetching
    /// 22 MB to find out.
    private nonisolated static var requiredEntries: [String] {
        [
            ModelNames.OfflineDiarizer.segmentationPath,
            ModelNames.OfflineDiarizer.fbankPath,
            ModelNames.OfflineDiarizer.embeddingPath,
            ModelNames.OfflineDiarizer.pldaRhoPath,
            ModelNames.OfflineDiarizer.pldaParameters,
        ]
    }

    /// The folder holding a complete set of models, if there is one.
    ///
    /// Looks in the models directory and one level below it: FluidAudio puts the repo in a
    /// subfolder it names itself, and pinning that name here would make a rename upstream
    /// look like a missing download.
    public nonisolated func installedModelFolder() -> URL? {
        let candidates = [modelsDirectory] + immediateSubdirectories(of: modelsDirectory)
        return candidates.first { folder in
            Self.requiredEntries.allSatisfy {
                FileManager.default.fileExists(atPath: folder.appending(path: $0).path)
            }
        }
    }

    private nonisolated func immediateSubdirectories(of url: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

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

    public func removeInstalledModel() throws {
        guard let folder = installedModelFolder() else { return }
        // The loaded models keep the compiled bundles alive; dropping them first is what makes
        // the removal actually free the space rather than unlink files still held open.
        manager = nil
        try FileManager.default.removeItem(at: folder)
    }

    // MARK: - Preparing

    public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await preparedManager(progress: Self.monotone(progress))
        progress(1)
    }

    /// Wraps a progress handler so it can never report less than it already has.
    ///
    /// The model load reports two independent 0-to-1 passes, one for the segmentation and
    /// embedding models and one for the filterbank, so a bar wired straight to it jumps back
    /// to zero halfway through. Clamping here rather than in the UI keeps every caller from
    /// having to know that.
    private static func monotone(
        _ handler: @escaping @Sendable (Double) -> Void
    ) -> @Sendable (Double) -> Void {
        let highest = Mutex(0.0)
        return { fraction in
            handler(highest.withLock { value in
                value = max(value, fraction)
                return value
            })
        }
    }

    private func preparedManager(
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Unchecked<OfflineDiarizerManager> {
        if let manager { return manager }

        try FileManager.default.createDirectory(
            at: modelsDirectory, withIntermediateDirectories: true
        )

        let created = OfflineDiarizerManager()
        do {
            // Loading is driven here rather than through `prepareModels` so the download can
            // report progress at all: `prepareModels` takes no handler, and a first run that
            // pulls four models with a still bar is indistinguishable from a hang.
            let models = try await OfflineDiarizerModels.load(
                from: modelsDirectory,
                progressHandler: { progress($0.fractionCompleted) }
            )
            created.initialize(models: models)
        } catch {
            throw DiarizationError.modelUnavailable(error.localizedDescription)
        }

        let boxed = Unchecked(value: created)
        manager = boxed
        return boxed
    }

    /// Frees the models. Worth doing once a session is diarized, for the same reason as
    /// unloading Whisper: nothing should hold model memory while the app sits idle.
    public func unload() {
        manager = nil
    }

    // MARK: - Diarizing

    public func diarize(
        audio url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [SpeakerTurn] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DiarizationError.audioUnreadable(url)
        }
        // Downloading is a small part of a first run and none of any later one, so it gets a
        // small share of the bar and diarization itself gets the rest.
        let report = Self.monotone(progress)
        let manager = try await preparedManager(progress: { report($0 * Self.prepareShare) })

        let result: DiarizationResult
        do {
            result = try await manager.value.process(url) { done, total in
                guard total > 0 else { return }
                let fraction = Double(done) / Double(total)
                report(Self.prepareShare + (1 - Self.prepareShare) * fraction)
            }
        } catch {
            throw DiarizationError.failed(error.localizedDescription)
        }

        progress(1)
        return Self.turns(from: result)
    }

    /// The share of `diarize`'s progress reserved for getting the models ready.
    static let prepareShare = 0.15

    /// Converts FluidAudio's segments into our turns, renumbering the speakers.
    ///
    /// The model's own ids are opaque and not ordered by anything meaningful. Renumbering by
    /// who speaks first makes `system-1` mean "the first voice you hear", which is what the
    /// rename UI lists and what a user can actually match to a person.
    static func turns(from result: DiarizationResult) -> [SpeakerTurn] {
        let ordered = result.segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }

        var numbers: [String: Int] = [:]
        return ordered.map { segment in
            let number = numbers[segment.speakerId] ?? {
                let next = numbers.count + 1
                numbers[segment.speakerId] = next
                return next
            }()
            return SpeakerTurn(
                speakerID: SessionManifest.systemSpeakerID(number),
                start: TimeInterval(segment.startTimeSeconds),
                end: TimeInterval(segment.endTimeSeconds),
                confidence: Double(segment.qualityScore)
            )
        }
    }
}
