import Foundation
import Observation
import TranlixCapture
import TranlixModel
import TranlixSummarize
import TranlixTranscribe

/// User preferences, kept in `UserDefaults`.
///
/// Deliberately not in the session folder: these describe how this Mac should behave, while a
/// session folder describes one recording and has to stay portable between the two machines.
@MainActor
@Observable
final class SettingsStore {
    /// Which Claude model writes the notes. Only the choice is stored here — the API key
    /// lives in the keychain, never in `UserDefaults`.
    var summaryModel: SummaryModel {
        didSet {
            guard summaryModel != oldValue else { return }
            UserDefaults.standard.set(summaryModel.rawValue, forKey: Self.summaryModelKey)
        }
    }

    /// Which DeepInfra model transcribes new recordings. Qwen3-ASR unless changed; a single
    /// session can still be re-transcribed with the other one from its inspector.
    var transcriptionModel: DeepInfraModel {
        didSet {
            guard transcriptionModel != oldValue else { return }
            UserDefaults.standard.set(transcriptionModel.rawValue, forKey: Self.transcriptionModelKey)
        }
    }

    /// Which prompt answers which kind of session.
    ///
    /// Replaces the single default template this used to hold. Now that the kind is worked out
    /// per session, one prompt for everything would defeat the point of working it out.
    ///
    /// Being set is not, by itself, permission for anything: whether a session's transcript may
    /// be sent is `NotesPolicy`'s decision and nothing else's.
    var templateIDs: [SessionKind: UUID] {
        didSet {
            guard templateIDs != oldValue else { return }
            let stored = templateIDs.reduce(into: [String: String]()) { result, pair in
                result[pair.key.rawValue] = pair.value.uuidString
            }
            guard let data = try? JSONEncoder().encode(stored) else { return }
            UserDefaults.standard.set(data, forKey: Self.templateIDsKey)
        }
    }

    /// What language the notes come out in, whatever language was spoken.
    var notesLanguage: NotesLanguage {
        didSet {
            guard notesLanguage != oldValue else { return }
            UserDefaults.standard.set(notesLanguage.rawValue, forKey: Self.notesLanguageKey)
        }
    }

    /// Hours of recorded audio after which a recording ends on its own. Nil for never.
    ///
    /// On by default, because what it prevents fails silently: a recording nobody stopped once
    /// ran from a Friday night to a Monday morning. A session cut this way is not processed —
    /// that is the app's rule, not this setting's.
    var recordingLimitHours: Int? {
        didSet {
            guard recordingLimitHours != oldValue else { return }
            // Zero stands for "never": `UserDefaults` cannot hold a nil.
            UserDefaults.standard.set(recordingLimitHours ?? 0, forKey: Self.recordingLimitKey)
        }
    }

    /// Whether the small control that floats over other apps appears while a session runs.
    ///
    /// On by default: a recording usually happens behind the call it is recording, and this is
    /// what keeps the clock and Pausar in reach without bringing the window forward.
    var showFloatingRecorder: Bool {
        didSet {
            guard showFloatingRecorder != oldValue else { return }
            UserDefaults.standard.set(showFloatingRecorder, forKey: Self.showFloatingRecorderKey)
        }
    }

    /// The limits offered, in hours.
    static let recordingLimitOptions = [1, 2, 3, 4, 6, 8, 12]

    static let defaultRecordingLimitHours = 4

    /// The limit in the seconds the recorder counts in.
    var recordingLimit: TimeInterval? {
        recordingLimitHours.map { TimeInterval($0) * 3600 }
    }

    // MARK: - Meeting detection

    /// Whether Tranlix offers to record when a meeting app starts using the microphone.
    ///
    /// On by default: the meeting nobody remembered to record is the one this is for, and
    /// the offer is a notification that can be ignored, never a recording started unasked.
    var autoDetectMeetings: Bool {
        didSet {
            guard autoDetectMeetings != oldValue else { return }
            UserDefaults.standard.set(autoDetectMeetings, forKey: Self.autoDetectMeetingsKey)
        }
    }

    /// Which apps' meetings are offered. All of them unless some were unticked.
    var watchedMeetingApps: Set<MeetingApp> {
        didSet {
            guard watchedMeetingApps != oldValue else { return }
            // Stored as what is left out rather than what is in, so an app added in a later
            // version starts out watched instead of silently missing.
            let unwatched = MeetingApp.allCases.filter { !watchedMeetingApps.contains($0) }
            UserDefaults.standard.set(unwatched.map(\.rawValue), forKey: Self.unwatchedMeetingAppsKey)
        }
    }

    /// Both meeting settings, as the prompt policy takes them.
    var meetingPromptPreferences: MeetingPromptPolicy.Preferences {
        MeetingPromptPolicy.Preferences(enabled: autoDetectMeetings, watched: watchedMeetingApps)
    }

    private static let autoDetectMeetingsKey = "autoDetectMeetings"
    private static let unwatchedMeetingAppsKey = "unwatchedMeetingApps"

    private static func loadWatchedMeetingApps() -> Set<MeetingApp> {
        let unwatched = (UserDefaults.standard.stringArray(forKey: unwatchedMeetingAppsKey) ?? [])
            .compactMap(MeetingApp.init(rawValue:))
        return Set(MeetingApp.allCases).subtracting(unwatched)
    }

    // MARK: -

    private static let summaryModelKey = "summaryModel"
    private static let transcriptionModelKey = "transcriptionModel"
    private static let templateIDsKey = "notesTemplateIDs"
    private static let notesLanguageKey = "notesLanguage"
    private static let recordingLimitKey = "recordingLimitHours"
    private static let showFloatingRecorderKey = "showFloatingRecorder"

    /// The one-template-for-everything preference, read only to migrate it.
    private static let legacyTemplateKey = "defaultTemplateID"

    init() {
        summaryModel = UserDefaults.standard.string(forKey: Self.summaryModelKey)
            .flatMap(SummaryModel.init(rawValue:)) ?? .default
        transcriptionModel = UserDefaults.standard.string(forKey: Self.transcriptionModelKey)
            .flatMap(DeepInfraModel.init(rawValue:)) ?? .default
        notesLanguage = UserDefaults.standard.string(forKey: Self.notesLanguageKey)
            .flatMap(NotesLanguage.init(rawValue:)) ?? .default
        templateIDs = Self.loadTemplateIDs()
        autoDetectMeetings = UserDefaults.standard
            .object(forKey: Self.autoDetectMeetingsKey) as? Bool ?? true
        watchedMeetingApps = Self.loadWatchedMeetingApps()
        recordingLimitHours = Self.loadRecordingLimitHours()
        // Not `bool(forKey:)`: that reads false when nothing was ever stored.
        showFloatingRecorder = UserDefaults.standard
            .object(forKey: Self.showFloatingRecorderKey) as? Bool ?? true
    }

    /// A Mac that never chose gets the default; one that chose "never" stored a zero.
    private static func loadRecordingLimitHours() -> Int? {
        guard let stored = UserDefaults.standard.object(forKey: recordingLimitKey) as? Int else {
            return defaultRecordingLimitHours
        }
        return stored > 0 ? stored : nil
    }

    private static func loadTemplateIDs() -> [SessionKind: UUID] {
        if let data = UserDefaults.standard.data(forKey: templateIDsKey),
           let stored = try? JSONDecoder().decode([String: String].self, from: data) {
            let mapped = stored.reduce(into: [SessionKind: UUID]()) { result, pair in
                guard let kind = SessionKind(rawValue: pair.key),
                      let id = UUID(uuidString: pair.value)
                else { return }
                result[kind] = id
            }
            if !mapped.isEmpty { return mapped }
        }

        // Before kinds existed one template answered every session. Seeding all three slots
        // with it keeps the preference the user actually set rather than silently dropping it.
        if let legacy = UserDefaults.standard.string(forKey: legacyTemplateKey)
            .flatMap(UUID.init(uuidString:)) {
            return SessionKind.allCases.reduce(into: [:]) { $0[$1] = legacy }
        }

        return SessionKind.allCases.reduce(into: [:]) { $0[$1] = PromptTemplate.seededID(for: $1) }
    }
}
