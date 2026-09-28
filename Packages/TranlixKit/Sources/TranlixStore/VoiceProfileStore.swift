import Foundation
import Synchronization
import TranlixModel

/// One registry per recordings library. A process-wide lock also protects multiple store
/// instances during library switches; there is no suspension inside a read-modify-write.
public actor VoiceProfileStore {
    private static let diskLock = Mutex(())
    private let url: URL

    private struct Registry: Codable {
        var schemaVersion = 1
        var profiles: [VoiceProfile] = []
    }

    public init(root: URL) {
        url = root.appending(path: "voice-profiles.json")
    }

    public func profiles() throws -> [VoiceProfile] {
        try Self.diskLock.withLock { _ in try read().profiles }
    }

    @discardableResult
    public func enroll(name: String, descriptor: VoiceDescriptor, origin: VoiceProfile.Origin? = nil) throws -> VoiceProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VoiceProfileError.emptyName }
        guard let normalized = descriptor.normalizedVector else { throw VoiceProfileError.invalidEvidence }
        var descriptor = descriptor
        descriptor.vector = normalized
        let profile = VoiceProfile(name: trimmed, descriptor: descriptor, origin: origin)
        try mutate { $0.profiles.append(profile) }
        return profile
    }

    public func rename(_ id: UUID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VoiceProfileError.emptyName }
        try mutate { registry in
            guard let index = registry.profiles.firstIndex(where: { $0.id == id })
            else { throw VoiceProfileError.missingPerson }
            registry.profiles[index].name = trimmed
        }
    }

    public func delete(_ id: UUID) throws {
        try mutate { $0.profiles.removeAll { $0.id == id } }
    }

    private func read() throws -> Registry {
        guard FileManager.default.fileExists(atPath: url.path) else { return Registry() }
        let registry = try TranlixJSON.decode(Registry.self, from: Data(contentsOf: url))
        guard registry.schemaVersion == 1 else { throw VoiceProfileError.unsupportedVersion }
        return registry
    }

    private func mutate(_ body: (inout Registry) throws -> Void) throws {
        try Self.diskLock.withLock { _ in
            var registry = try read()
            try body(&registry)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try AtomicFile.write(TranlixJSON.encode(registry), to: url)
        }
    }
}
