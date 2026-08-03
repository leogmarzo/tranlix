import Foundation

/// A value a `@Sendable` callback can safely write to.
///
/// Progress handlers throughout the app are `@Sendable` and get called from whatever thread
/// happens to be doing the work, so a test that wants to record what they reported cannot
/// simply capture a `var`.
public final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    public init(_ value: Value) {
        storage = value
    }

    public var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }

    public func withValue<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }
}
