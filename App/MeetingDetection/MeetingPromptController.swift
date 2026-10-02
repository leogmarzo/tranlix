import AppKit
import Observation
import OSLog
import TranlixCapture
import UserNotifications

/// Offers to record a meeting the moment one starts.
///
/// Turns the monitor's events into a "¿Grabar la reunión?" notification with a Grabar button,
/// and the button into a recording, without the main window having to be open: the person
/// pressing it is looking at their call, not at Tranlix.
///
/// The decisions — whether to ask, when to take the question down — are `MeetingPromptPolicy`'s,
/// which is tested in the package. This class only carries them out.
@MainActor
final class MeetingPromptController {
    static let categoryID = "meeting.start"
    static let failureCategoryID = "meeting.start.failed"
    static let promptRequestID = "meeting.start.prompt"
    static let failureRequestID = "meeting.start.failed"
    static let recordActionID = "meeting.start.record"
    static let appUserInfoKey = "meetingApp"
    static let launchUserInfoKey = "launch"

    /// Stamped on every question this run posts. An alert stays on screen after Tranlix quits
    /// or crashes, and pressing Grabar on it relaunches the app to deliver the answer — for a
    /// meeting this run never saw, which may be long over.
    private let launchID = UUID().uuidString

    /// Brings the main window forward on the record screen. Installed by the scene, like the
    /// floating recorder's, and used when the body of a notification is clicked.
    var openApp: (() -> Void)?

    private let monitor: MeetingAppMonitor
    private let recorder: RecorderViewModel
    private let settings: SettingsStore
    private let notifications: AppNotifications
    private var policy = MeetingPromptPolicy()

    /// What `sync` last saw, so it acts on changes rather than on every observation.
    private var isMonitoring = false
    private var wasRecording: Bool
    private var lastPreferences: MeetingPromptPolicy.Preferences

    /// Start and stop are async on the monitor; chaining them keeps a quick off-on-off in order.
    private var monitorTransition: Task<Void, Never>?
    private var consumer: Task<Void, Never>?

    private static let log = Logger(subsystem: "com.leomarzo.tranlix", category: "MeetingDetection")

    init(
        monitor: MeetingAppMonitor = MeetingAppMonitor(),
        recorder: RecorderViewModel,
        settings: SettingsStore,
        notifications: AppNotifications
    ) {
        self.monitor = monitor
        self.recorder = recorder
        self.settings = settings
        self.notifications = notifications
        wasRecording = recorder.isRecording
        lastPreferences = settings.meetingPromptPreferences

        // One button. A second action would put both behind an "Opciones" menu on an alert;
        // the alert's own close button is the "Ahora no", reported through `.customDismissAction`.
        let record = UNNotificationAction(identifier: Self.recordActionID, title: "Grabar", options: [])
        notifications.register(
            category: UNNotificationCategory(
                identifier: Self.categoryID,
                actions: [record],
                intentIdentifiers: [],
                options: [.customDismissAction]
            )
        ) { [weak self] answer in
            self?.handle(answer)
        }
        notifications.register(
            category: UNNotificationCategory(
                identifier: Self.failureCategoryID, actions: [], intentIdentifiers: []
            )
        ) { [weak self] answer in
            guard answer.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
            self?.openApp?()
        }

        // A question left over from before a quit is about a meeting this run knows nothing
        // of, and answering it would start a recording for no reason anyone remembers.
        notifications.remove(identifiers: [Self.promptRequestID, Self.failureRequestID])

        consumer = Task { [weak self, monitor] in
            for await event in monitor.events {
                guard let self else { return }
                handle(event)
            }
        }
        observe()
        sync()
    }

    // MARK: - Following the settings and the recorder

    private func observe() {
        withObservationTracking {
            _ = settings.autoDetectMeetings
            _ = settings.watchedMeetingApps
            _ = recorder.isRecording
        } onChange: { [weak self] in
            // Same hop as the menu bar item: onChange runs before the new value is written,
            // and tracking is one-shot, so it has to be registered again.
            Task { @MainActor [weak self] in
                self?.sync()
                self?.observe()
            }
        }
    }

    private func sync() {
        let shouldMonitor = settings.autoDetectMeetings
        if shouldMonitor != isMonitoring {
            isMonitoring = shouldMonitor
            let monitor = monitor
            let previous = monitorTransition
            monitorTransition = Task {
                await previous?.value
                if shouldMonitor {
                    await monitor.start()
                } else {
                    // Ends every active meeting, which takes a question that is showing down.
                    await monitor.stop()
                }
            }
        }

        // Switching detection on asks for notification permission from the settings pane
        // itself, which then knows the answer and can say when it is a no.
        let preferences = settings.meetingPromptPreferences
        if preferences != lastPreferences {
            lastPreferences = preferences
            apply(policy.preferencesChanged(preferences))
        }

        if recorder.isRecording, !wasRecording {
            apply(policy.recordingStarted())
        }
        wasRecording = recorder.isRecording
    }

    // MARK: - Meetings

    private func handle(_ event: MeetingEvent) {
        let decision = policy.handle(
            event,
            preferences: settings.meetingPromptPreferences,
            canRecord: recorder.canRecord,
            at: Date()
        )
        apply(decision)
    }

    private func apply(_ decision: MeetingPromptPolicy.Decision) {
        switch decision {
        case .none:
            break
        case .withdraw:
            notifications.remove(identifiers: [Self.promptRequestID])
        case let .prompt(app, appName):
            Task { await prompt(app, appName: appName) }
        }
    }

    private func prompt(_ app: MeetingApp, appName: String) async {
        // With detection on by default there is no moment of switching it on, so the first
        // meeting is when the system asks. The question comes first and the offer right after.
        guard await notifications.requestAuthorizationIfNeeded() else {
            Self.log.info("Meeting detected but notifications are not allowed")
            return
        }
        // The meeting may have ended, a session started, or another app's meeting taken over
        // while the system was asking.
        guard policy.outstanding == app else { return }

        let content = UNMutableNotificationContent()
        content.title = "¿Grabar la reunión?"
        content.body = "\(appName) está usando el micrófono."
        content.categoryIdentifier = Self.categoryID
        content.userInfo = [Self.appUserInfoKey: app.rawValue, Self.launchUserInfoKey: launchID]
        content.sound = .default
        content.interruptionLevel = .active
        // One identifier for every meeting: a newer question replaces the older one, because
        // only one recording can run.
        notifications.post(
            UNNotificationRequest(identifier: Self.promptRequestID, content: content, trigger: nil)
        )
    }

    // MARK: - Answers

    private func handle(_ answer: AppNotifications.Answer) {
        // A question from an earlier run is about a meeting this run knows nothing of. Grabar
        // on it opens Tranlix instead of recording; if that meeting is still going on, the
        // monitor finds it and asks again within seconds.
        let askedByThisRun = answer.userInfo[Self.launchUserInfoKey] == launchID
            && policy.outstanding != nil

        switch answer.actionIdentifier {
        case Self.recordActionID:
            guard askedByThisRun else {
                openApp?()
                return
            }
            policy.promptAccepted()
            startRecording()
        case UNNotificationDefaultActionIdentifier:
            // The body, not the button: show Tranlix and let them decide there.
            if askedByThisRun { policy.promptAccepted() }
            openApp?()
        case UNNotificationDismissActionIdentifier:
            guard askedByThisRun else { return }
            apply(policy.promptDismissed())
        default:
            break
        }
    }

    /// Starts the session as it is, untitled unless a title was already typed: an empty title
    /// is what lets the notes give the session a name from what was actually said.
    private func startRecording() {
        // A session may have been started some other way while the question was up.
        guard recorder.canRecord else { return }
        Task {
            await recorder.start()
            guard !recorder.isRecording else { return }
            // Nobody is looking at the window that would show the error.
            postFailure(recorder.errorMessage ?? "No se pudo empezar a grabar.")
        }
    }

    private func postFailure(_ message: String) {
        let content = UNMutableNotificationContent()
        content.title = "No se pudo grabar la reunión"
        content.body = message
        content.categoryIdentifier = Self.failureCategoryID
        content.sound = .default
        notifications.post(
            UNNotificationRequest(identifier: Self.failureRequestID, content: content, trigger: nil)
        )
    }
}
