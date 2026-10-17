import Testing

@testable import TranlixCapture

/// Telling which meeting app, if any, a capturing process belongs to.
@Suite("Meeting app matching")
struct MeetingAppTests {
    @Test("the native apps are recognized by their own bundle ids", arguments: [
        ("us.zoom.xos", MeetingApp.zoom),
        ("us.zoom.CptHost", .zoom),
        ("com.microsoft.teams2", .teams),
        ("com.microsoft.teams", .teams),
        ("com.microsoft.teams2.helper", .teams),
    ])
    func nativeApps(bundleID: String, expected: MeetingApp) {
        #expect(MeetingApp.matching(bundleID: bundleID, appBundleID: nil) == expected)
        #expect(MeetingApp.matching(bundleID: nil, appBundleID: bundleID) == expected)
    }

    @Test("browsers count as Meet, helpers included", arguments: [
        "com.google.Chrome",
        "com.google.Chrome.helper",
        "com.google.Chrome.canary",
        "org.chromium.Chromium",
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "company.thebrowser.Browser",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.helper",
        "com.brave.Browser",
        "com.brave.Browser.helper",
        "org.mozilla.firefox",
        "org.mozilla.plugincontainer",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ])
    func browsers(bundleID: String) {
        #expect(MeetingApp.matching(bundleID: bundleID, appBundleID: nil) == .meet)
    }

    @Test("matching ignores case")
    func caseInsensitive() {
        #expect(MeetingApp.matching(bundleID: "US.ZOOM.XOS", appBundleID: nil) == .zoom)
        #expect(MeetingApp.matching(bundleID: "com.google.chrome.helper", appBundleID: nil) == .meet)
    }

    @Test("apps that are not meeting apps do not match", arguments: [
        "com.spotify.client",
        "com.tinyspeck.slackmacgap",
        "com.apple.controlcenter",
        "com.apple.CoreSpeech",
        "",
        // A prefix only counts at a component boundary.
        "us.zoomer.app",
        "com.google.Chromecast",
        "com.microsoft.teamsish",
    ])
    func unrelated(bundleID: String) {
        #expect(MeetingApp.matching(bundleID: bundleID, appBundleID: nil) == nil)
        #expect(MeetingApp.matching(bundleID: nil, appBundleID: bundleID) == nil)
    }

    @Test("a helper with an unknown id still matches through the app responsible for it")
    func responsibleApp() {
        #expect(MeetingApp.matching(bundleID: "org.chromium.unknown-helper", appBundleID: "com.google.Chrome") == .meet)
        #expect(MeetingApp.matching(bundleID: nil, appBundleID: "us.zoom.xos") == .zoom)
    }

    @Test("the responsible app decides when the two disagree")
    func responsibleAppWins() {
        // Teams renders in WebKit; if its capture runs in a WebKit process, the process id
        // looks like Safari's while the responsible app is Teams.
        #expect(MeetingApp.matching(bundleID: "com.apple.WebKit.GPU", appBundleID: "com.microsoft.teams2") == .teams)
    }

    @Test("WebKit's shared process counts as a browser only when nothing better is known")
    func sharedWebKitProcess() {
        #expect(MeetingApp.matching(bundleID: "com.apple.WebKit.GPU", appBundleID: nil) == .meet)
        #expect(MeetingApp.matching(bundleID: "com.apple.WebKit.GPU", appBundleID: "com.apple.Safari") == .meet)
        // Mail, or any other app hosting a web view, using the microphone is not a meeting.
        #expect(MeetingApp.matching(bundleID: "com.apple.WebKit.GPU", appBundleID: "com.apple.mail") == nil)
    }

    @Test("a process of an unrelated app does not match by its own id")
    func unrelatedResponsibleApp() {
        // A helper's own id is still trusted when it names a meeting app outright.
        #expect(MeetingApp.matching(bundleID: "us.zoom.xos", appBundleID: "com.apple.Terminal") == .zoom)
    }

    @Test("Tranlix itself is never a meeting, whatever else is listed")
    func ownProcessExcluded() {
        #expect(MeetingApp.matching(bundleID: "com.leomarzo.tranlix", appBundleID: nil) == nil)
        #expect(MeetingApp.matching(bundleID: "com.google.Chrome", appBundleID: "com.leomarzo.tranlix") == nil)
        #expect(MeetingApp.matching(bundleID: "com.leomarzo.tranlix", appBundleID: "com.google.Chrome") == nil)
    }

    @Test("every app has a name and a session title")
    func labels() {
        for app in MeetingApp.allCases {
            #expect(!app.displayName.isEmpty)
            #expect(!app.defaultSessionTitle.isEmpty)
        }
        #expect(MeetingApp.zoom.defaultSessionTitle == "Reunión de Zoom")
        #expect(MeetingApp.teams.defaultSessionTitle == "Reunión de Teams")
        #expect(MeetingApp.meet.defaultSessionTitle == "Reunión de Meet")
    }

    @Test("a browser is named after itself; the native apps by their product name")
    func labelForProcess() {
        #expect(MeetingApp.meet.label(appName: "Arc") == "Arc")
        #expect(MeetingApp.meet.label(appName: nil) == "El navegador")
        #expect(MeetingApp.meet.label(appName: "") == "El navegador")
        #expect(MeetingApp.zoom.label(appName: "zoom.us") == "Zoom")
        #expect(MeetingApp.teams.label(appName: nil) == "Microsoft Teams")
    }

    @Test("raw values are stable, because settings store them")
    func rawValues() {
        #expect(MeetingApp.allCases.map(\.rawValue) == ["zoom", "teams", "meet"])
    }
}
