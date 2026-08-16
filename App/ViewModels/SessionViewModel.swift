import AppKit
import Foundation
import Observation
import TranslixDiarize
import TranslixExport
import TranslixModel
import TranslixPipeline
import TranslixPlayback
import TranslixStore
import TranslixSummarize
import TranslixTranscribe

/// Everything one session shows, in one place.
///
/// It replaces three view models that each loaded part of a session and had to be reloaded in
/// the right order after any of them changed anything — a dance that lived in the view. It
/// also runs nothing: every stage goes through `PipelineCoordinator`, so there is one answer
/// to "is this session busy" instead of three.
@MainActor
@Observable
final class SessionViewModel {
    enum Tab: Hashable { case notes, transcript }

    struct SpeakerRow: Identifiable, Equatable {
        let id: String
        var name: String
        let placeholder: String
        let speakingTime: TimeInterval
    }

    struct SavedNote: Identifiable, Equatable {
        var id: URL { url }
        let url: URL
        let title: String
        let modifiedAt: Date
    }

    let summary: SessionSummary

    private(set) var manifest: SessionManifest?
    private(set) var transcript: Transcript?
    private(set) var player: SessionPlayer?
    private(set) var peaks: [AudioTrack: [Float]] = [:]
    private(set) var speakers: [SpeakerRow] = []
    private(set) var notes: [SavedNote] = []

    var tab: Tab = .notes
    var query = ""
    var isFinding = false
    var showInspector = true
    var errorMessage: String?

    private let environment: AppEnvironment
    private let settings: SettingsStore

    init(summary: SessionSummary, environment: AppEnvironment, settings: SettingsStore) {
        self.summary = summary
        self.environment = environment
        self.settings = settings
    }

    // MARK: - Loading

    func load() async {
        do {
            let handle = try environment.store.handle(at: summary.layout.root)
            let manifest = await handle.manifest
            self.manifest = manifest
            transcript = try await handle.readTranscript()
            notes = await savedNotes(of: handle)
            rebuildSpeakers()

            // Only once there is audio to open: a session still being processed has no
            // archive yet, and the player is rebuilt when the run finishes.
            if player == nil, manifest.state == .ready {
                player = try? SessionPlayer(manifest: manifest, layout: summary.layout)
                loadPeaks()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Reloads after the chain has written something.
    func reload() async {
        await load()
    }

    private func loadPeaks() {
        let layout = summary.layout
        Task.detached(priority: .utility) {
            var built: [AudioTrack: [Float]] = [:]
            for track in AudioTrack.allCases {
                if let values = try? WaveformDigest.load(track: track, layout: layout) {
                    built[track] = values
                }
            }
            await MainActor.run { [built] in self.peaks = built }
        }
    }

    private func savedNotes(of handle: SessionHandle) async -> [SavedNote] {
        await handle.notes().compactMap { url -> SavedNote? in
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return SavedNote(url: url, title: Self.title(of: url), modifiedAt: modified)
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private static func title(of url: URL) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return url.deletingPathExtension().lastPathComponent
        }
        let heading = text.split(separator: "\n").first { $0.hasPrefix("# ") }
        return heading.map { String($0.dropFirst(2)) }
            ?? url.deletingPathExtension().lastPathComponent
    }

    // MARK: - What the session is doing

    var isProcessing: Bool {
        environment.pipeline?.isRunning(summary.id) == true
    }

    var phase: PipelinePhase? {
        environment.pipeline?.phases[summary.id]
    }

    /// What went wrong, from the manifest if it was recorded there and from the run if not.
    var failure: String? {
        environment.pipeline?.failures[summary.id] ?? manifest?.failure?.message
    }

    var hasTranscript: Bool { transcript?.segments.isEmpty == false }

    var latestNote: SavedNote? { notes.first }

    /// The note's body, with the generated header stripped: the header says which prompt and
    /// model produced it, which belongs in the inspector rather than at the top of the reading
    /// column.
    func body(of note: SavedNote) -> String {
        guard let text = try? String(contentsOf: note.url, encoding: .utf8) else { return "" }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.first?.hasPrefix("# ") == true { lines.removeFirst() }
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty
            || first.hasPrefix("_Generado") {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Running stages

    func retry() {
        run(stages: Set(PipelineStage.allCases))
    }

    func retranscribe(with engineID: EngineID) {
        settings.transcription.engineID = engineID
        run(stages: [.transcription, .diarization], force: true)
    }

    func reprocessSpeakers() {
        run(stages: [.diarization], force: true)
    }

    /// Asking for notes is itself the permission, which is what lets a session past the
    /// automatic limit still be summarised — deliberately, by someone who meant it.
    func generateNotes() {
        run(stages: [.notes], notesConfirmed: true)
    }

    /// What the app took this recording to be, once anything has decided.
    var kind: SessionKindInfo? { manifest?.kind }

    /// Says what this recording actually was, and rewrites the notes to match.
    ///
    /// Recorded as `chosenByUser`, which is what makes it final: the chain only works a kind
    /// out for a session that has none, so nothing will quietly overrule this later.
    func setKind(_ kind: SessionKind) {
        guard !isProcessing, kind != self.kind?.kind else { return }
        Task {
            guard let handle = try? environment.store.handle(at: summary.layout.root) else {
                return
            }
            do {
                try await handle.recordKind(SessionKindInfo(
                    kind: kind, source: .chosenByUser, decidedAt: Date()
                ))
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            await reload()
            generateNotes()
        }
    }

    private func run(
        stages: Set<PipelineStage>,
        force: Bool = false,
        notesConfirmed: Bool = false
    ) {
        guard let pipeline = environment.pipeline, !isProcessing else { return }
        Task {
            guard let handle = try? environment.store.handle(at: summary.layout.root) else {
                return
            }
            pipeline.start(
                handle, stages: stages, force: force, notesConfirmed: notesConfirmed
            )
        }
    }

    func cancel() {
        Task { await environment.pipeline?.cancel(summary.id) }
    }

    // MARK: - Playback

    func seek(to time: TimeInterval) {
        player?.seek(to: time)
    }

    /// The segment being spoken at the playhead, so the transcript can follow along.
    var activeSegmentID: UUID? {
        guard let player, let transcript else { return nil }
        let now = player.currentTime
        return transcript.segments.last { $0.start <= now }?.id
    }

    // MARK: - Speakers

    private func rebuildSpeakers() {
        guard let manifest, let transcript else {
            speakers = []
            return
        }
        var time: [String: TimeInterval] = [:]
        for segment in transcript.segments {
            let id = segment.speakerID ?? (segment.track == .mic ? SessionManifest.micSpeakerID : "")
            guard !id.isEmpty else { continue }
            time[id, default: 0] += segment.duration
        }

        speakers = transcript.speakerIDs.isEmpty
            ? time.keys.sorted().map { row(for: $0, manifest: manifest, time: time) }
            : transcript.speakerIDs.map { row(for: $0, manifest: manifest, time: time) }
    }

    private func row(
        for id: String,
        manifest: SessionManifest,
        time: [String: TimeInterval]
    ) -> SpeakerRow {
        SpeakerRow(
            id: id,
            name: manifest.speakerNames[id] ?? "",
            placeholder: SessionManifest.defaultDisplayName(forSpeaker: id),
            speakingTime: time[id] ?? 0
        )
    }

    func rename(_ id: String, to name: String) async {
        guard let index = speakers.firstIndex(where: { $0.id == id }) else { return }
        speakers[index].name = name
        do {
            let handle = try environment.store.handle(at: summary.layout.root)
            try await handle.renameSpeaker(id: id, to: name)
            manifest = await handle.manifest
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// What to show for a speaker, with the user's name winning.
    func displayName(forSpeaker id: String?) -> String? {
        guard let id else { return nil }
        return manifest?.displayName(forSpeaker: id)
    }

    // MARK: - Export

    enum ExportFormat {
        case markdown, srt, plainText
    }

    func copyNotes() {
        guard let note = latestNote, let text = try? String(contentsOf: note.url, encoding: .utf8)
        else { return }
        write(text, to: .general)
    }

    func copyTranscript() {
        write(rendered(.markdown), to: .general)
    }

    @discardableResult
    func export(_ format: ExportFormat) -> URL? {
        let name: String
        switch format {
        case .markdown: name = "transcript.md"
        case .srt: name = "transcript.srt"
        case .plainText: name = "transcript.txt"
        }
        let url = summary.layout.root.appending(path: name)
        do {
            try Data(rendered(format).utf8).write(to: url, options: .atomic)
            return url
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func rendered(_ format: ExportFormat) -> String {
        guard let transcript, let manifest else { return "" }
        switch format {
        case .markdown:
            return TranscriptRenderer.markdown(transcript: transcript, manifest: manifest)
        case .srt:
            return TranscriptRenderer.srt(transcript: transcript, manifest: manifest)
        case .plainText:
            return TranscriptRenderer.plainText(transcript: transcript, manifest: manifest)
        }
    }

    private func write(_ text: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func revealInFinder(_ url: URL? = nil) {
        NSWorkspace.shared.activateFileViewerSelecting([url ?? summary.layout.root])
    }
}
