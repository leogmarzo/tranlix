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

    /// The name the question showing right now uses.
    private var outstandingName = ""

    /// Questions a newer one replaced before they were answered, oldest first, kept while
    /// their meeting goes on. A browser tab holding the microphone for a few seconds during a
    /// Zoom call takes the question over; when the tab lets go, the Zoom call is asked about
    /// again rather than left with no question at all.
    private var displaced: [(app: MeetingApp, appName: String)] = []

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
            displaced.removeAll { $0.app == app }
            if let previous = outstanding, previous != app {
                displaced.append((previous, outstandingName))
            }
            return ask(app, appName: appName)

        case let .ended(app):
            if unanswered.remove(app) != nil {
                lastUnansweredEnd[app] = now
            }
            displaced.removeAll { $0.app == app }
            guard outstanding == app else { return .none }
            outstanding = nil
            guard canRecord else { return .withdraw }
            return askDisplaced()
        }
    }

    /// A session started, from the question or any other way.
    public mutating func recordingStarted() -> Decision {
        unanswered.removeAll()
        lastUnansweredEnd.removeAll()
        displaced.removeAll()
        guard outstanding != nil else { return .none }
        outstanding = nil
        return .withdraw
    }

    /// The user took the question up: pressed Grabar, or clicked it to open Tranlix. It is
    /// gone from the screen, and nothing replaced comes back on top of what they chose.
    public mutating func promptAccepted() {
        outstanding = nil
    }

    /// The user closed the question: "Ahora no". It is gone from the screen. A question it had
    /// replaced comes back, because that is a different meeting, still going on.
    public mutating func promptDismissed() -> Decision {
        guard outstanding != nil else { return .none }
        outstanding = nil
        // The closed question is already off the screen: nothing to take down.
        guard !displaced.isEmpty else { return .none }
        return askDisplaced()
    }

    /// The settings changed. A question about an app that is no longer watched comes down, and
    /// a question it had replaced about an app still watched comes back in its place.
    public mutating func preferencesChanged(_ preferences: Preferences) -> Decision {
        displaced.removeAll { !preferences.covers($0.app) }
        guard let outstanding, !preferences.covers(outstanding) else { return .none }
        self.outstanding = nil
        return askDisplaced()
    }

    private mutating func ask(_ app: MeetingApp, appName: String) -> Decision {
        outstanding = app
        outstandingName = appName
        return .prompt(app, appName: appName)
    }

    /// The most recently replaced question, or taking the one showing down when there is none.
    /// Called with nothing outstanding.
    private mutating func askDisplaced() -> Decision {
        guard let next = displaced.popLast() else { return .withdraw }
        return ask(next.app, appName: next.appName)
    }
}
