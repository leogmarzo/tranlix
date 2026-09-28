import Foundation

/// Runs a block against a throwaway recordings root and removes it afterwards.
///
/// The store's whole job is filesystem behaviour, so its tests exercise a real filesystem
/// rather than an abstraction over one. A mocked file layer would only prove the mock works.
public func withTemporaryRoot<T>(_ body: (URL) async throws -> T) async throws -> T {
    let root = URL(filePath: NSTemporaryDirectory())
        .appending(path: "tranlix-tests-\(UUID().uuidString)")
        .appending(path: "Grabaciones")
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    return try await body(root)
}

public extension FileManager {
    func exists(_ url: URL) -> Bool {
        fileExists(atPath: url.path)
    }

    func entries(in url: URL) -> [String] {
        ((try? contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }
}
