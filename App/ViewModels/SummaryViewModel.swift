import Foundation
import Observation
import TranlixExport
import TranlixModel
import TranlixStore
import TranlixSummarize

/// A note already on disk.
struct SavedNote: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    let title: String
    let modifiedAt: Date
}

/// Generates notes for one session, and manages what it takes to do that.
@MainActor
@Observable
final class SummaryViewModel {
    private(set) var templates: [PromptTemplate] = []
    private(set) var notes: [SavedNote] = []
    private(set) var isGenerating = false
    private(set) var hasAPIKey = false

    /// Whether this session's transcript has already been sent once.
    private(set) var alreadyShared = false

    /// Set when a run needs the confirmation the user has not given yet.
    var pendingConfirmation = false

    var selectedTemplateID: UUID?
    var freePrompt = ""
    var useFreePrompt = false
    var errorMessage: String?

    private let environment: AppEnvironment
    private let settings: SettingsStore
    private let keys = APIKeyStore()
    private let templateStore = TemplateStore()

    private var summary: SessionSummary?
    private var manifest: SessionManifest?
    private var transcript: Transcript?

    init(environment: AppEnvironment, settings: SettingsStore) {
        self.environment = environment
        self.settings = settings
    }

    // MARK: - Loading

    func load(_ summary: SessionSummary, manifest: SessionManifest?, transcript: Transcript?) async {
        self.summary = summary
        self.manifest = manifest
        self.transcript = transcript

        templates = templateStore.load()
        if selectedTemplateID == nil { selectedTemplateID = templates.first?.id }
        hasAPIKey = keys.hasKey
        alreadyShared = manifest?.transcriptSharedAt != nil
        await refreshNotes()
    }

    func refreshNotes() async {
        guard let summary else { return }
        guard let handle = try? environment.store.handle(at: summary.layout.root) else { return }

        notes = await handle.notes().map { url in
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return SavedNote(url: url, title: Self.title(of: url), modifiedAt: modified)
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// Reads the note's own heading rather than showing a timestamped file name.
    private static func title(of url: URL) -> String {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return url.deletingPathExtension().lastPathComponent
        }
        let heading = contents
            .split(separator: "\n")
            .first { $0.hasPrefix("# ") }?
            .dropFirst(2)
        return heading.map(String.init) ?? url.deletingPathExtension().lastPathComponent
    }

    // MARK: - What would be sent

    var canGenerate: Bool {
        transcript != nil && hasAPIKey && !isGenerating && !instruction.isEmpty
    }

    /// The prompt that would be used: the free text when it is chosen, the template otherwise.
    var instruction: String {
        if useFreePrompt {
            return freePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return templates.first { $0.id == selectedTemplateID }?.prompt ?? ""
    }

    var noteTitle: String {
        if useFreePrompt { return "Nota" }
        return templates.first { $0.id == selectedTemplateID }?.name ?? "Nota"
    }

    /// The exact text that would leave the machine, so the confirmation can show it.
    var renderedTranscript: String {
        guard let transcript, let manifest else { return "" }
        return TranscriptRenderer.markdown(
            transcript: transcript, manifest: manifest, options: .prompt
        )
    }

    var estimatedTokens: Int {
        SummaryRequest(instruction: instruction, transcript: renderedTranscript)
            .estimatedInputTokens
    }

    var isLongSession: Bool {
        estimatedTokens > SummaryRequest.warnAboveTokens
    }

    // MARK: - Generating

    /// Asks first when the session has never been sent, generates directly when it has.
    func generate() {
        guard canGenerate else { return }
        if alreadyShared {
            run(confirmed: false)
        } else {
            pendingConfirmation = true
        }
    }

    /// Called when the user accepts the confirmation.
    func confirmAndGenerate() {
        pendingConfirmation = false
        run(confirmed: true)
    }

    private func run(confirmed: Bool) {
        guard let summary else { return }
        let instruction = instruction
        let title = noteTitle
        let transcriptText = renderedTranscript
        let model = settings.summaryModel.identifier

        isGenerating = true
        Task {
            defer { isGenerating = false }
            do {
                let handle = try environment.store.handle(at: summary.layout.root)
                let pipeline = SummaryPipeline(provider: AnthropicProvider(keys: keys))
                _ = try await pipeline.generate(
                    session: handle,
                    transcript: transcriptText,
                    instruction: instruction,
                    title: title,
                    model: model,
                    userConfirmedSharing: confirmed
                )
                manifest = await handle.manifest
                alreadyShared = manifest?.transcriptSharedAt != nil
                await refreshNotes()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Export

    /// Writes `transcript.md` beside the session and returns where it landed.
    ///
    /// The Markdown is produced from the same renderer as everything else, so what is
    /// exported is what was on screen — names applied, speakers separated, markers in place.
    @discardableResult
    func exportTranscript() -> URL? {
        guard let summary, let transcript, let manifest else { return nil }
        let markdown = TranscriptRenderer.markdown(transcript: transcript, manifest: manifest)
        let url = summary.layout.transcriptMarkdownURL
        do {
            try Data(markdown.utf8).write(to: url, options: .atomic)
            return url
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}
