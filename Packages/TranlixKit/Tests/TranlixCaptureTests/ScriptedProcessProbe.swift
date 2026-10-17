import Foundation

@testable import TranlixCapture

/// A process probe the test fills in by hand.
final class ScriptedProcessProbe: AudioProcessProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [AudioProcessSnapshot] = []
    private var onChange: (@Sendable () -> Void)?
    private var observeCalls = 0
    private var stopCalls = 0

    func snapshot() async -> [AudioProcessSnapshot] {
        lock.withLock { processes }
    }

    func startObserving(_ onChange: @escaping @Sendable () -> Void) {
        lock.withLock {
            self.onChange = onChange
            observeCalls += 1
        }
    }

    func stopObserving() {
        lock.withLock {
            onChange = nil
            stopCalls += 1
        }
    }

    var startCount: Int { lock.withLock { observeCalls } }
    var stopCount: Int { lock.withLock { stopCalls } }
    var isObserved: Bool { lock.withLock { onChange != nil } }

    /// Replaces what the probe reports and tells the observer, the way a Core Audio listener would.
    func set(_ processes: [AudioProcessSnapshot]) {
        let callback = lock.withLock {
            self.processes = processes
            return onChange
        }
        callback?()
    }

    /// Replaces what the probe reports without telling anyone: a notification Core Audio dropped.
    func setSilently(_ processes: [AudioProcessSnapshot]) {
        lock.withLock { self.processes = processes }
    }
}

extension AudioProcessSnapshot {
    static func capturing(_ bundleID: String, pid: pid_t = 4242, name: String? = nil) -> AudioProcessSnapshot {
        AudioProcessSnapshot(pid: pid, bundleID: bundleID, appBundleID: nil, appName: name, isRunningInput: true)
    }

    static func idle(_ bundleID: String, pid: pid_t = 4242) -> AudioProcessSnapshot {
        AudioProcessSnapshot(pid: pid, bundleID: bundleID, appBundleID: nil, appName: nil, isRunningInput: false)
    }
}
