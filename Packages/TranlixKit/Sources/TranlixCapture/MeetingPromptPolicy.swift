import Foundation

/// Decides when a detected meeting turns into a "¿Grabar?" notification, and when one that is
/// showing should be taken down.
///
/// Kept out of the app so it can be tested: the notification center and the recorder are on
/// the other side of `Decision`.
///
/// There is at most one question at a time, because there is at most one recording.
public struct MeetingPromptPolicy: Sendable {
    public struct Preferences: Equatable, Sendable {
        public var enabled: Bool
        public var watched: Set<MeetingApp>

        public init(enabled: Bool, watched: Set<MeetingApp>) {
            self.enabled = enabled
            self.watched = watched
        }

        func covers(_ app: MeetingApp) -> Bool {
            enabled && watched.contains(app)
        }
    }

    public enum Decision: Equatable, Sendable {
        case none

        /// Show the question, replacing any question already showing.
        case prompt(MeetingApp, appName: String)

        /// Take the question that is showing down.
        case withdraw
    }

    /// How long after a meeting that was asked about and not recorded the same app stays
    /// quiet. Some apps release the microphone on mute; without this, every unmute in a
    /// meeting the user already declined would bring the question back.
    public let rePromptCooldown: TimeInterval

    /// The app the question showing right now is about.
    public private(set) var outstanding: MeetingApp?

    /// Apps whose current meeting was asked about, or was kept quiet by the cooldown, and has
    /// not been recorded.
    private var unanswered: Set<MeetingApp> = []

    /// When each app's last unanswered meeting ended.
    private var lastUnansweredEnd: [MeetingApp: Date] = [:]

    public init(rePromptCooldown: TimeInterval = 120) {
        self.rePromptCooldown = rePromptCooldown
    }

    public mutating func handle(
        _ event: MeetingEvent,
        preferences: Preferences,
        canRecord: Bool,
        at now: Date
    ) -> Decision {
        switch event {
        case let .started(app, appName):
            // A session already open is not a reason to remember anything: whatever it was
            // recording, it was not this question being turned down.
            guard preferences.covers(app), canRecord else { return .none }

            if let ended = lastUnansweredEnd[app], now.timeIntervalSince(ended) < rePromptCooldown {
                unanswered.insert(app)
                return .none
            }
            lastUnansweredEnd[app] = nil
            unanswered.insert(app)
            outstanding = app
            return .prompt(app, appName: appName)

        case let .ended(app):
            if unanswered.remove(app) != nil {
                lastUnansweredEnd[app] = now
            }
            guard outstanding == app else { return .none }
            outstanding = nil
            return .withdraw
        }
    }

    /// A session started, from the question or any other way.
    public mutating func recordingStarted() -> Decision {
        unanswered.removeAll()
        lastUnansweredEnd.removeAll()
        guard outstanding != nil else { return .none }
        outstanding = nil
        return .withdraw
    }

    /// The user answered the question showing, either way. It is gone from the screen.
    public mutating func promptAnswered() {
        outstanding = nil
    }

    /// The settings changed. A question about an app that is no longer watched comes down.
    public mutating func preferencesChanged(_ preferences: Preferences) -> Decision {
        guard let outstanding, !preferences.covers(outstanding) else { return .none }
        self.outstanding = nil
        return .withdraw
    }
}
