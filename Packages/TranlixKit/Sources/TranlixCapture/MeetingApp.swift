import Foundation

/// A meeting app whose calls Tranlix offers to record.
///
/// Recognized by bundle id rather than by window or URL: whether a process is capturing from
/// the microphone is public Core Audio metadata, while a window title or a tab's URL would
/// take the Accessibility or Screen Recording permission. The cost is that `meet` really
/// means "a browser is using the microphone" — the common case is Google Meet, but any page
/// that asks for the microphone looks the same from here.
public enum MeetingApp: String, CaseIterable, Codable, Hashable, Sendable {
    case zoom
    case teams
    case meet

    /// What the settings and the notifications call it.
    public var displayName: String {
        switch self {
        case .zoom: "Zoom"
        case .teams: "Microsoft Teams"
        case .meet: "Google Meet"
        }
    }

    /// The name a session started from the prompt gets when it has none yet.
    public var defaultSessionTitle: String {
        switch self {
        case .zoom: "Reunión de Zoom"
        case .teams: "Reunión de Teams"
        case .meet: "Reunión de Meet"
        }
    }

    /// What to call the app that was seen capturing, in a sentence like "… está usando el
    /// micrófono". A browser is named after itself, because "Google Meet" would be a guess;
    /// the native apps are named after the product rather than their bundle (`zoom.us`).
    public func label(appName: String?) -> String {
        switch self {
        case .zoom, .teams:
            return displayName
        case .meet:
            guard let appName, !appName.isEmpty else { return "El navegador" }
            return appName
        }
    }

    /// Which meeting app a process belongs to, if any.
    ///
    /// - Parameters:
    ///   - bundleID: the process's own bundle id, as Core Audio reports it. For a browser this
    ///     is usually a helper (`com.google.Chrome.helper`) rather than the browser itself.
    ///   - appBundleID: the app responsible for the process, when it could be worked out. It
    ///     decides whenever it names a meeting app: Teams draws with WebKit, and a capture that
    ///     runs in WebKit's shared process carries WebKit's id, not Teams'.
    public static func matching(bundleID: String?, appBundleID: String?) -> MeetingApp? {
        let own = bundleID?.lowercased() ?? ""
        let app = appBundleID?.lowercased() ?? ""

        // Tranlix records the microphone too, and must never propose recording itself.
        if isTranlix(own) || isTranlix(app) { return nil }

        if let match = match(app) { return match }
        if let match = match(own) { return match }

        // WebKit's shared process is used by every app that hosts a web view. It only counts
        // as a browser when there is no responsible app to say otherwise.
        if appBundleID == nil, sharedWebKitPrefixes.contains(where: { matches(own, prefix: $0) }) {
            return .meet
        }
        return nil
    }

    /// Lowercased. A prefix ending in a dot matches anything under it; any other prefix
    /// matches itself or itself followed by a dot, so `com.google.chrome` does not claim
    /// `com.google.chromecast`.
    static let prefixes: [MeetingApp: [String]] = [
        .zoom: ["us.zoom."],
        .teams: ["com.microsoft.teams", "com.microsoft.teams2"],
        .meet: [
            "com.google.chrome",
            "org.chromium.chromium",
            "com.apple.safari",
            "com.apple.safaritechnologypreview",
            "company.thebrowser.",
            "com.microsoft.edgemac",
            "com.brave.browser",
            "org.mozilla.firefox",
            "org.mozilla.plugincontainer",
            "com.vivaldi.vivaldi",
            "com.operasoftware.opera",
        ],
    ]

    /// WebKit's out-of-process capture runs here for Safari and for every other WebKit host.
    static let sharedWebKitPrefixes = ["com.apple.webkit."]

    static let tranlixBundleID = "com.leomarzo.tranlix"

    private static func match(_ identifier: String) -> MeetingApp? {
        guard !identifier.isEmpty else { return nil }
        return allCases.first { app in
            prefixes[app, default: []].contains { matches(identifier, prefix: $0) }
        }
    }

    private static func matches(_ identifier: String, prefix: String) -> Bool {
        if prefix.hasSuffix(".") { return identifier.hasPrefix(prefix) }
        return identifier == prefix || identifier.hasPrefix(prefix + ".")
    }

    private static func isTranlix(_ identifier: String) -> Bool {
        matches(identifier, prefix: tranlixBundleID)
    }
}
