import CoreAudio
import Darwin
import Foundation

/// Reads Core Audio's process objects: which processes do audio I/O, and which of them are
/// capturing from an input device.
///
/// Reading these needs no permission. They say *whether* a process captures, never *what* —
/// the audio-capture prompt belongs to process taps, which this never creates.
///
/// One serial queue owns every piece of mutable state, Core Audio delivers its notifications
/// on that same queue, and snapshots are read there too. Nothing on it ever waits on an actor:
/// the observer callback only spawns a `Task`.
public final class CoreAudioProcessProbe: AudioProcessProbe, @unchecked Sendable {
    /// Long enough to see a burst of notifications — a meeting app opening its input fires
    /// the list listener and an input listener together — as one; short enough not to matter
    /// next to the start grace.
    private static let coalescingWindow = DispatchTimeInterval.milliseconds(50)

    private let queue = DispatchQueue(
        label: "com.leomarzo.tranlix.meeting-probe", qos: .utility
    )

    // `queue` only, all of it.
    private var onChange: (@Sendable () -> Void)?
    private var listListener: AudioObjectPropertyListenerBlock?
    private var inputListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var notifyScheduled = false

    /// What a process object is, which does not change while it exists. Resolving the
    /// responsible app reads the filesystem, so it is done once per process, not once per look.
    private struct Identity {
        var pid: pid_t
        var bundleID: String?
        var appBundleID: String?
        var appName: String?
    }

    private var identities: [AudioObjectID: Identity] = [:]

    public init() {}

    deinit {
        // Nothing else can reach the probe by now, and every listener holds it weakly, so a
        // notification already queued finds nothing and returns.
        removeAllListeners()
    }

    // MARK: - AudioProcessProbe

    public func snapshot() async -> [AudioProcessSnapshot] {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.read())
            }
        }
    }

    public func startObserving(_ onChange: @escaping @Sendable () -> Void) {
        queue.async {
            self.onChange = onChange
            self.installListListener()
            self.reconcileInputListeners()
        }
    }

    public func stopObserving() {
        queue.async {
            self.onChange = nil
            self.removeAllListeners()
        }
    }

    // MARK: - Reading

    /// `queue` only.
    private func read() -> [AudioProcessSnapshot] {
        let objects = CoreAudioProperties.processObjectIDs()
        let alive = Set(objects)
        identities = identities.filter { alive.contains($0.key) }

        return objects.compactMap { object in
            guard let identity = identity(of: object),
                  let running = CoreAudioProperties.processIsRunningInput(object)
            else { return nil }
            return AudioProcessSnapshot(
                pid: identity.pid,
                bundleID: identity.bundleID,
                appBundleID: identity.appBundleID,
                appName: identity.appName,
                isRunningInput: running
            )
        }
    }

    /// `queue` only.
    private func identity(of object: AudioObjectID) -> Identity? {
        if let known = identities[object] { return known }
        guard let pid = CoreAudioProperties.processPID(object), pid > 0 else { return nil }

        let app = ResponsibleApp.resolve(for: pid)
        let identity = Identity(
            pid: pid,
            bundleID: CoreAudioProperties.processBundleID(object),
            appBundleID: app?.bundleID,
            appName: app?.name
        )
        identities[object] = identity
        return identity
    }

    // MARK: - Listening

    /// `queue` only.
    private func installListListener() {
        guard listListener == nil else { return }
        var address = CoreAudioProperties.address(kAudioHardwarePropertyProcessObjectList)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            // Delivered on `queue`, so the state is ours to touch.
            reconcileInputListeners()
            scheduleNotify()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, listener
        )
        // Without it the monitor still finds changes on its safety poll, only later.
        if status == noErr { listListener = listener }
    }

    /// Keeps one input listener per process object that exists. `queue` only.
    private func reconcileInputListeners() {
        let objects = Set(CoreAudioProperties.processObjectIDs())

        for (object, listener) in inputListeners where !objects.contains(object) {
            // The object is usually gone by now and Core Audio says so; that is fine.
            var address = CoreAudioProperties.address(kAudioProcessPropertyIsRunningInput)
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, listener)
            inputListeners[object] = nil
        }

        for object in objects where inputListeners[object] == nil {
            var address = CoreAudioProperties.address(kAudioProcessPropertyIsRunningInput)
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.scheduleNotify()
            }
            if AudioObjectAddPropertyListenerBlock(object, &address, queue, listener) == noErr {
                inputListeners[object] = listener
            }
        }
    }

    /// Not `queue`-only: also called from `deinit`, when nothing else can reach the probe.
    private func removeAllListeners() {
        if let listListener {
            var address = CoreAudioProperties.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, queue, listListener
            )
            self.listListener = nil
        }
        for (object, listener) in inputListeners {
            var address = CoreAudioProperties.address(kAudioProcessPropertyIsRunningInput)
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, listener)
        }
        inputListeners.removeAll()
    }

    /// Collapses a burst of notifications into one call. `queue` only.
    private func scheduleNotify() {
        guard onChange != nil, !notifyScheduled else { return }
        notifyScheduled = true
        queue.asyncAfter(deadline: .now() + Self.coalescingWindow) { [weak self] in
            guard let self else { return }
            notifyScheduled = false
            onChange?()
        }
    }
}

/// The app a process works for: the browser for a browser's helper, Safari for the WebKit
/// process capturing on its behalf, the process's own app otherwise.
enum ResponsibleApp {
    struct Identity: Equatable {
        var bundleID: String
        var name: String
    }

    static func resolve(for pid: pid_t) -> Identity? {
        // The responsible process first: it is what names Safari for `com.apple.WebKit.GPU`,
        // whose own executable lives inside a framework, not inside any app.
        if let responsible = responsiblePID(of: pid), responsible != pid,
           let path = executablePath(of: responsible),
           let app = enclosingApp(ofExecutableAt: path) {
            return app
        }
        guard let path = executablePath(of: pid) else { return nil }
        return enclosingApp(ofExecutableAt: path)
    }

    /// The outermost app bundle a path is inside. Outermost, because a browser's helper is an
    /// app bundle nested inside the browser's own.
    ///
    /// Also `.app.bundle`: Chrome, after downloading an update, runs from a code-signing clone
    /// of itself in a temporary folder named `Google Chrome.app.bundle`.
    static func enclosingApp(ofExecutableAt path: String) -> Identity? {
        guard !path.isEmpty else { return nil }
        let components = URL(fileURLWithPath: path).pathComponents
        guard let index = components.firstIndex(where: isAppBundleName) else { return nil }

        let appPath = NSString.path(withComponents: Array(components[...index]))
        guard let bundle = Bundle(path: appPath), let bundleID = bundle.bundleIdentifier
        else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? appNameFromPath(appPath)
        return Identity(bundleID: bundleID, name: name)
    }

    /// `Google Chrome.app.bundle` and `Google Chrome.app` are both "Google Chrome".
    private static func appNameFromPath(_ appPath: String) -> String {
        var name = URL(fileURLWithPath: appPath).lastPathComponent
        for suffix in [".bundle", ".app"] where name.lowercased().hasSuffix(suffix) {
            name.removeLast(suffix.count)
        }
        return name
    }

    private static func isAppBundleName(_ component: String) -> Bool {
        let name = component.lowercased()
        return name.hasSuffix(".app") || name.hasSuffix(".app.bundle")
    }

    private static func executablePath(of pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE, which Swift does not import.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The process macOS holds responsible for `pid`: the one that shows up in Activity
    /// Monitor and in the microphone indicator. Not public API, so it is looked up at run time
    /// and the fallback is the process's own executable.
    private static func responsiblePID(of pid: pid_t) -> pid_t? {
        guard let lookup = responsibilityLookup else { return nil }
        let responsible = lookup(pid)
        return responsible > 0 ? responsible : nil
    }

    private typealias Lookup = @convention(c) (pid_t) -> pid_t

    private nonisolated(unsafe) static let responsibilityLookup: Lookup? = {
        // RTLD_DEFAULT, which Swift does not import.
        let everywhere = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(everywhere, "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(symbol, to: Lookup.self)
    }()
}
