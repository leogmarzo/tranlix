import Foundation

public struct PeopleNameConflict: Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let personIDs: [UUID]

    /// A notification targets the original identities, never a reused display name.
    public func revalidated(in profiles: [VoiceProfile]) -> PeopleNameConflict? {
        Self.detect(in: profiles).first { $0.id == id && $0.personIDs == personIDs }
    }

    public static func detect(in profiles: [VoiceProfile]) -> [PeopleNameConflict] {
        let groups = Dictionary(grouping: profiles, by: { normalizedName($0.name) })
        return groups.compactMap { key, people in
            let ids = Set(people.map(\.id)).sorted { $0.uuidString < $1.uuidString }
            guard !key.isEmpty, ids.count > 1 else { return nil }
            let name = people.map { collapsed($0.name) }.sorted().first ?? key
            return PeopleNameConflict(id: key, displayName: name, personIDs: ids)
        }.sorted { $0.id < $1.id }
    }

    private static func normalizedName(_ name: String) -> String {
        collapsed(name).folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func collapsed(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
