import Foundation

/// One process doing audio I/O, as Core Audio sees it.
public struct AudioProcessSnapshot: Hashable, Sendable {
    public var pid: pid_t

    /// The process's own bundle id, as Core Audio reports it. Nil when it has none.
    public var bundleID: String?

    /// The bundle id of the app responsible for the process: the browser for a browser's
    /// helper, the process's own app otherwise. Nil when it could not be worked out.
    public var appBundleID: String?

    /// That app's user-visible name, for the notification.
    public var appName: String?

    /// Capturing from an input device right now.
    public var isRunningInput: Bool

    public init(
        pid: pid_t,
        bundleID: String?,
        appBundleID: String?,
        appName: String?,
        isRunningInput: Bool
    ) {
        self.pid = pid
        self.bundleID = bundleID
        self.appBundleID = appBundleID
        self.appName = appName
        self.isRunningInput = isRunningInput
    }
}

/// Where the meeting monitor reads processes from.
///
/// A protocol so the monitor can be driven by a script in tests: the real implementation
/// needs another app actually holding the microphone.
public protocol AudioProcessProbe: Sendable {
    /// Every process connected to Core Audio right now. A process whose properties cannot be
    /// read is left out rather than failing the whole read.
    func snapshot() async -> [AudioProcessSnapshot]

    /// Calls `onChange` whenever the processes or their input state may have changed. Carries
    /// no payload on purpose: the caller takes a fresh snapshot. Replaces any earlier observer.
    func startObserving(_ onChange: @escaping @Sendable () -> Void)

    /// Stops calling the observer. Safe to call when not observing.
    func stopObserving()
}
