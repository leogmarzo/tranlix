import Foundation

/// A meeting app starting or stopping its use of the microphone, once debounced.
public enum MeetingEvent: Equatable, Sendable {
    /// `appName` is what to call it in a sentence: "Zoom", or the browser's own name.
    case started(MeetingApp, appName: String)
    case ended(MeetingApp)
}

/// Turns "which meeting apps are capturing right now" into started and ended events.
///
/// Raw input state is noisy in both directions. An app opens the microphone for a moment to
/// draw a level meter or to check a permission, which is not a meeting. And an app in a
/// meeting closes and reopens its input when the device changes — connecting AirPods does
/// exactly that — which is not a new meeting. So each app goes through a grace period before
/// it is reported as started and another before it is reported as ended.
///
/// A value type driven by explicit timestamps, so every transition can be tested without
/// waiting. `nextDeadline` says when it has to be looked at again even if nothing changes.
struct MeetingActivityDetector: Sendable {
    private enum Phase: Equatable, Sendable {
        /// Capturing, not yet for long enough to report.
        case pending(since: Date)

        /// Reported as started.
        case active

        /// Reported as started, and stopped capturing at `since`.
        case releasing(since: Date)
    }

    let startGrace: TimeInterval
    let endGrace: TimeInterval

    /// No entry means idle.
    private var phases: [MeetingApp: Phase] = [:]

    init(startGrace: TimeInterval = 3, endGrace: TimeInterval = 8) {
        self.startGrace = startGrace
        self.endGrace = endGrace
    }

    /// Feeds what is capturing at `now`, each app with the name it should be reported under.
    /// Returns the events that happen at `now`, in `MeetingApp.allCases` order.
    mutating func observe(_ capturing: [MeetingApp: String], at now: Date) -> [MeetingEvent] {
        var events: [MeetingEvent] = []
        for app in MeetingApp.allCases {
            let name = capturing[app]
            switch (phases[app], name) {
            case (nil, nil):
                break
            case (nil, let name?):
                phases[app] = .pending(since: now)
                if startGrace <= 0 {
                    phases[app] = .active
                    events.append(.started(app, appName: name))
                }
            case (.pending(let since)?, let name?):
                if now.timeIntervalSince(since) >= startGrace {
                    phases[app] = .active
                    events.append(.started(app, appName: name))
                }
            case (.pending?, nil):
                phases[app] = nil
            case (.active?, _?):
                break
            case (.active?, nil):
                phases[app] = .releasing(since: now)
                if endGrace <= 0 {
                    phases[app] = nil
                    events.append(.ended(app))
                }
            case (.releasing?, _?):
                phases[app] = .active
            case (.releasing(let since)?, nil):
                if now.timeIntervalSince(since) >= endGrace {
                    phases[app] = nil
                    events.append(.ended(app))
                }
            }
        }
        return events
    }

    /// When a grace period runs out, or nil when nothing is waiting on one.
    var nextDeadline: Date? {
        phases.values.compactMap { phase -> Date? in
            switch phase {
            case .pending(let since): since.addingTimeInterval(startGrace)
            case .releasing(let since): since.addingTimeInterval(endGrace)
            case .active: nil
            }
        }.min()
    }

    /// Reported as started and not yet as ended.
    func isActive(_ app: MeetingApp) -> Bool {
        switch phases[app] {
        case .active?, .releasing?: true
        case .pending?, nil: false
        }
    }

    /// The apps reported as started and not yet as ended, in `MeetingApp.allCases` order.
    var activeApps: [MeetingApp] {
        MeetingApp.allCases.filter(isActive)
    }

    /// Forgets everything, without reporting anything.
    mutating func reset() {
        phases.removeAll()
    }
}
