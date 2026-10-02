import Foundation
import Testing

@testable import TranlixCapture

/// Deciding when a detected meeting turns into a "¿Grabar?" notification, and when one that
/// is showing should be taken down.
@Suite("Meeting prompt policy")
struct MeetingPromptPolicyTests {
    private let epoch = Date(timeIntervalSince1970: 1_759_400_000)
    private func at(_ seconds: TimeInterval) -> Date { epoch.addingTimeInterval(seconds) }

    private let all = MeetingPromptPolicy.Preferences(enabled: true, watched: Set(MeetingApp.allCases))

    private func policy() -> MeetingPromptPolicy {
        MeetingPromptPolicy(rePromptCooldown: 120)
    }

    @Test("a meeting starting with everything on is proposed")
    func prompts() {
        var policy = policy()
        let decision = policy.handle(.started(.zoom, appName: "Zoom"), preferences: all, canRecord: true, at: at(0))
        #expect(decision == .prompt(.zoom, appName: "Zoom"))
        #expect(policy.outstanding == .zoom)
    }

    @Test("nothing is proposed with detection off")
    func disabled() {
        var policy = policy()
        let off = MeetingPromptPolicy.Preferences(enabled: false, watched: Set(MeetingApp.allCases))
        #expect(policy.handle(.started(.zoom, appName: "Zoom"), preferences: off, canRecord: true, at: at(0)) == MeetingPromptPolicy.Decision.none)
        #expect(policy.outstanding == nil)
    }

    @Test("an app left unticked is not proposed")
    func unwatched() {
        var policy = policy()
        let onlyZoom = MeetingPromptPolicy.Preferences(enabled: true, watched: [.zoom])
        #expect(policy.handle(.started(.meet, appName: "Google Chrome"), preferences: onlyZoom, canRecord: true, at: at(0)) == MeetingPromptPolicy.Decision.none)
        #expect(policy.handle(.started(.zoom, appName: "Zoom"), preferences: onlyZoom, canRecord: true, at: at(1)) == .prompt(.zoom, appName: "Zoom"))
    }

    @Test("nothing is proposed while a session is already open")
    func recorderBusy() {
        var policy = policy()
        #expect(policy.handle(.started(.zoom, appName: "Zoom"), preferences: all, canRecord: false, at: at(0)) == MeetingPromptPolicy.Decision.none)
        #expect(policy.outstanding == nil)
    }

    @Test("the meeting ending takes its question down")
    func endWithdraws() {
        var policy = policy()
        _ = policy.handle(.started(.teams, appName: "Microsoft Teams"), preferences: all, canRecord: true, at: at(0))
        #expect(policy.handle(.ended(.teams), preferences: all, canRecord: true, at: at(60)) == .withdraw)
        #expect(policy.outstanding == nil)
    }

    @Test("another app ending leaves the question up")
    func otherEndKeepsPrompt() {
        var policy = policy()
        _ = policy.handle(.started(.zoom, appName: "Zoom"), preferences: all, canRecord: true, at: at(0))
        #expect(policy.handle(.ended(.meet), preferences: all, canRecord: true, at: at(5)) == MeetingPromptPolicy.Decision.none)
        #expect(policy.outstanding == .zoom)
    }

    @Test("starting to record by any route takes the question down")
    func recordingWithdraws() {
        var policy = policy()
        #expect(policy.recordingStarted() == MeetingPromptPolicy.Decision.none)
        _ = policy.handle(.started(.zoom, appName: "Zoom"), preferences: all, canRecord: true, at: at(0))
        #expect(policy.recordingStarted() == .withdraw)
        #expect(policy.outstanding == nil)
    }

    @Test("a newer meeting replaces the question about an older one")
    func newerReplaces() {
        var policy = policy()
        _ = policy.handle(.started(.zoom, appName: "Zoom"), preferences: all, canRecord: true, at: at(0))
        #expect(policy.handle(.started(.meet, appName: "Arc"), preferences: all, canRecord: true, at: at(5)) == .prompt(.meet, appName: "Arc"))
        #expect(policy.outstanding == .meet)
        #expect(policy.handle(.ended(.zoom), preferences: all, canRecord: true, at: at(10)) == MeetingPromptPolicy.Decision.none)
        #expect(policy.outstanding == .meet)
    }

    @Test("an app that keeps dropping the microphone is not asked about again right away")
    func cooldownAfterUnansweredPrompt() {
        // Some apps release the microphone on mute. Without this, every unmute of a meeting
        // the user already declined to record would bring the question back.
        var policy = policy()
        _ = policy.handle(.started(.meet, appName: "Google Chrome"), preferences: all, canRecord: true, at: at(0))
        #expect(policy.handle(.ended(.meet), preferences: all, canRecord: true, at: at(100)) == .withdraw)
        #expect(policy.handle(.started(.meet, appName: "Google Chrome"), preferences: all, canRecord: true, at: at(150)) == MeetingPromptPolicy.Decision.none)
        // The cooldown runs from the latest end, so a meeting that keeps flapping stays quiet.
        #expect(policy.handle(.ended(.meet), preferences: all, canRecord: true, at: at(160)) == MeetingPromptPolicy.Decision.none)
        #expect(policy.handle(.started(.meet, appName: "Google Chrome"), preferences: all, canRecord: true, at: at(250)) == MeetingPromptPolicy.Decision.none)
        #expect(policy.handle(.ended(.meet), preferences: all, canRecord: true, at: at(260)) == MeetingPromptPolicy.Decision.none)
        #expect(policy.handle(.started(.meet, appName: "Google Chrome"), preferences: all, canRecord: true, at: at(380)) == .prompt(.meet, appName: "Google Chrome"))
    }

    @Test("«Ahora no» keeps the question away for the same meeting")
    func dismissArmsCooldown() {
        var policy = policy()
        _ = policy.handle(.started(.zoom, appName: "Zoom"), preferences: all, canRecord: true, at: at(0))
        _ = policy.promptDismissed()
        #expect(policy.outstanding == nil)
        #expect(policy.handle(.ended(.zoom), preferences: all, canRecord: true, at: at(30)) == MeetingPromptPolicy.Decision.none)
        #expect(policy.handle(.started(.zoom, appName: "Zoom"), preferences: all, canRecord: true, at: at(60)) == MeetingPromptPolicy.Decision.none)
    }

    @Test("the cooldown is per app")
    func cooldownPerApp() {
        var policy = policy()
        _ = policy.handle(.started(.zoom, appName: "Zoom"), preferences: all, canRecord: true, at: at(0))
        _ = policy.handle(.ended(.zoom), preferences: all, canRecord: true, at: at(10))
        #expect(policy.handle(.started(.teams, appName: "Microsoft Teams"), preferences: all, canRecord: true, at: at(20)) == .prompt(.teams, appName: "Microsoft Teams"))
    }

    @Test("a recorded meeting does not silence the next one")
    func acceptedClearsCooldown() {
        var policy = policy()
        _ = policy.handle(.started(.zoom, appName: "Zoom"), preferences: all, canRecord: true, at: at(0))
        _ = policy.recordingStarted()
        #expect(policy.handle(.ended(.zoom), preferences: all, canRecord: false, at: at(1800)) == MeetingPromptPolicy.Decision.none)
        #expect(policy.handle(.started(.zoom, appName: "Zoom"), preferences: all, canRecord: true, at: at(1830)) == .prompt(.zoom, appName: "Zoom"))
    }

    @Test("a start skipped because a session was open does not start a cooldown")
    func busyStartDoesNotArmCooldown() {
        var policy = policy()
        _ = policy.handle(.started(.zoom, appName: "Zoom"), preferences: all, canRecord: false, at: at(0))
        _ = policy.handle(.ended(.zoom), preferences: all, canRecord: true, at: at(10))
        #expect(policy.handle(.started(.zoom, appName: "Zoom"), preferences: all, canRecord: true, at: at(30)) == .prompt(.zoom, appName: "Zoom"))
    }

    @Test("unticking the app being asked about takes the question down")
    func preferencesChangeWithdraws() {
        var policy = policy()
        _ = policy.handle(.started(.meet, appName: "Safari"), preferences: all, canRecord: true, at: at(0))
        #expect(policy.preferencesChanged(MeetingPromptPolicy.Preferences(enabled: true, watched: [.meet, .zoom])) == MeetingPromptPolicy.Decision.none)
        #expect(policy.preferencesChanged(MeetingPromptPolicy.Preferences(enabled: true, watched: [.zoom])) == .withdraw)
        #expect(policy.outstanding == nil)
    }

    @Test("turning detection off takes the question down")
    func disablingWithdraws() {
        var policy = policy()
        _ = policy.handle(.started(.zoom, appName: "Zoom"), preferences: all, canRecord: true, at: at(0))
        #expect(policy.preferencesChanged(MeetingPromptPolicy.Preferences(enabled: false, watched: Set(MeetingApp.allCases))) == .withdraw)
    }

    // MARK: - A question replaced by a newer one

    @Test("a question replaced by a newer one comes back when the newer meeting ends")
    func displacedReturns() {
        // A browser tab holding the microphone for a few seconds during a Zoom call must not
        // cost the Zoom call its question.
        var policy = policy()
        _ = policy.handle(.started(.zoom, appName: "Zoom"), preferences: all, canRecord: true, at: at(0))
        _ = policy.handle(.started(.meet, appName: "Google Chrome"), preferences: all, canRecord: true, at: at(60))
        #expect(policy.handle(.ended(.meet), preferences: all, canRecord: true, at: at(80)) == .prompt(.zoom, appName: "Zoom"))
        #expect(policy.outstanding == .zoom)
        #expect(policy.handle(.ended(.zoom), preferences: all, canRecord: true, at: at(900)) == .withdraw)
    }

    @Test("a replaced question whose meeting ended first does not come back")
    func displacedEndedFirst() {
        var policy = policy()
        _ = policy.handle(.started(.zoom, appName: "Zoom"), preferences: all, canRecord: true, at: at(0))
        _ = policy.handle(.started(.meet, appName: "Arc"), preferences: all, canRecord: true, at: at(10))
        #expect(policy.handle(.ended(.zoom), preferences: all, canRecord: true, at: at(20)) == MeetingPromptPolicy.Decision.none)
        #expect(policy.handle(.ended(.meet), preferences: all, canRecord: true, at: at(30)) == .withdraw)
        #expect(policy.outstanding == nil)
    }

    @Test("the most recently replaced question comes back first")
    func displacedOrder() {
        var policy = policy()
        _ = policy.handle(.started(.zoom, appName: "Zoom"), preferences: all, canRecord: true, at: at(0))
        _ = policy.handle(.started(.teams, appName: "Microsoft Teams"), preferences: all, canRecord: true, at: at(10))
        _ = policy.handle(.started(.meet, appName: "Safari"), preferences: all, canRecord: true, at: at(20))
        #expect(policy.handle(.ended(.meet), preferences: all, canRecord: true, at: at(30)) == .prompt(.teams, appName: "Microsoft Teams"))
        #expect(policy.handle(.ended(.teams), preferences: all, canRecord: true, at: at(40)) == .prompt(.zoom, appName: "Zoom"))
    }

    @Test("«Ahora no» on the newer question brings the replaced one back")
    func dismissReturnsDisplaced() {
        var policy = policy()
        #expect(policy.promptDismissed() == MeetingPromptPolicy.Decision.none)
        _ = policy.handle(.started(.zoom, appName: "Zoom"), preferences: all, canRecord: true, at: at(0))
        _ = policy.handle(.started(.meet, appName: "Google Chrome"), preferences: all, canRecord: true, at: at(10))
        #expect(policy.promptDismissed() == .prompt(.zoom, appName: "Zoom"))
        #expect(policy.outstanding == .zoom)
        #expect(policy.promptDismissed() == MeetingPromptPolicy.Decision.none)
        #expect(policy.outstanding == nil)
    }

    @Test("accepting a question does not bring a replaced one back")
    func acceptDoesNotReturnDisplaced() {
        var policy = policy()
        _ = policy.handle(.started(.zoom, appName: "Zoom"), preferences: all, canRecord: true, at: at(0))
        _ = policy.handle(.started(.meet, appName: "Google Chrome"), preferences: all, canRecord: true, at: at(10))
        policy.promptAccepted()
        #expect(policy.outstanding == nil)
        #expect(policy.handle(.ended(.meet), preferences: all, canRecord: true, at: at(20)) == MeetingPromptPolicy.Decision.none)
    }

    @Test("a session starting forgets replaced questions")
    func recordingForgetsDisplaced() {
        var policy = policy()
        _ = policy.handle(.started(.zoom, appName: "Zoom"), preferences: all, canRecord: true, at: at(0))
        _ = policy.handle(.started(.meet, appName: "Google Chrome"), preferences: all, canRecord: true, at: at(10))
        #expect(policy.recordingStarted() == .withdraw)
        #expect(policy.handle(.ended(.meet), preferences: all, canRecord: false, at: at(20)) == MeetingPromptPolicy.Decision.none)
        #expect(policy.promptDismissed() == MeetingPromptPolicy.Decision.none)
    }

    @Test("a replaced question does not come back while a session is open")
    func displacedNotWhileBusy() {
        var policy = policy()
        _ = policy.handle(.started(.zoom, appName: "Zoom"), preferences: all, canRecord: true, at: at(0))
        _ = policy.handle(.started(.meet, appName: "Google Chrome"), preferences: all, canRecord: true, at: at(10))
        #expect(policy.handle(.ended(.meet), preferences: all, canRecord: false, at: at(20)) == .withdraw)
        #expect(policy.outstanding == nil)
    }

    @Test("unticking the app asked about brings back a replaced question about one still ticked")
    func preferencesReturnDisplaced() {
        var policy = policy()
        _ = policy.handle(.started(.zoom, appName: "Zoom"), preferences: all, canRecord: true, at: at(0))
        _ = policy.handle(.started(.meet, appName: "Google Chrome"), preferences: all, canRecord: true, at: at(10))
        #expect(policy.preferencesChanged(MeetingPromptPolicy.Preferences(enabled: true, watched: [.zoom])) == .prompt(.zoom, appName: "Zoom"))
        // And a replaced question about an unticked app is dropped.
        _ = policy.handle(.started(.teams, appName: "Microsoft Teams"), preferences: all, canRecord: true, at: at(20))
        _ = policy.preferencesChanged(MeetingPromptPolicy.Preferences(enabled: true, watched: [.teams]))
        #expect(policy.handle(.ended(.teams), preferences: all, canRecord: true, at: at(30)) == .withdraw)
    }

    @Test("the same app starting again is not counted as replacing itself")
    func sameAppDoesNotDisplaceItself() {
        var policy = policy()
        _ = policy.handle(.started(.zoom, appName: "Zoom"), preferences: all, canRecord: true, at: at(0))
        _ = policy.handle(.started(.zoom, appName: "Zoom"), preferences: all, canRecord: true, at: at(5))
        #expect(policy.handle(.ended(.zoom), preferences: all, canRecord: true, at: at(10)) == .withdraw)
        #expect(policy.promptDismissed() == MeetingPromptPolicy.Decision.none)
    }
}
