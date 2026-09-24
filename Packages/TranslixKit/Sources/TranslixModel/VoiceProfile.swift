import Foundation

/// A voice vector is meaningful only within the model space that produced it.
public struct VoiceDescriptor: Codable, Sendable, Equatable {
    public var modelID: String
    public var vector: [Float]
    public var speechSeconds: Double

    public init(modelID: String, vector: [Float], speechSeconds: Double) {
        self.modelID = modelID
        self.vector = vector
        self.speechSeconds = speechSeconds
    }

    public var normalizedVector: [Float]? {
        guard !modelID.isEmpty, !vector.isEmpty, vector.count <= 4096,
              vector.allSatisfy(\.isFinite), speechSeconds.isFinite, speechSeconds >= 6
        else { return nil }
        let magnitude = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard magnitude.isFinite, magnitude > 0.000001 else { return nil }
        return vector.map { Float(Double($0) / magnitude) }
    }
}

public struct VoiceProfile: Codable, Sendable, Equatable, Identifiable {
    public struct Origin: Codable, Sendable, Equatable {
        public var sessionID: UUID
        public var speakerID: String

        public init(sessionID: UUID, speakerID: String) {
            self.sessionID = sessionID
            self.speakerID = speakerID
        }
    }

    public var id: UUID
    public var name: String
    public var descriptor: VoiceDescriptor
    public var origin: Origin?

    public init(id: UUID = UUID(), name: String, descriptor: VoiceDescriptor, origin: Origin? = nil) {
        self.id = id
        self.name = name
        self.descriptor = descriptor
        self.origin = origin
    }
}

public struct SpeakerIdentity: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable {
        case automatic, suggested, confirmed, manual, inferredFromNotes
    }

    public var personID: UUID?
    public var name: String
    public var source: Source
    /// Cosine similarity, not a calibrated probability.
    public var similarity: Double?
    public var evidence: String?
    public var transcriptRevision: String?

    public init(personID: UUID? = nil, name: String, source: Source, similarity: Double? = nil,
                evidence: String? = nil, transcriptRevision: String? = nil) {
        self.personID = personID
        self.name = name
        self.source = source
        self.similarity = similarity
        self.evidence = evidence
        self.transcriptRevision = transcriptRevision
    }
}

public enum VoiceProfileError: Error, LocalizedError {
    case invalidEvidence, emptyName, missingPerson, unsupportedVersion

    public var errorDescription: String? {
        switch self {
        case .invalidEvidence: "At least six seconds of clear, unambiguous speech are required."
        case .emptyName: "Enter a name before remembering this person."
        case .missingPerson: "This saved person no longer exists."
        case .unsupportedVersion: "These voice profiles were created by a newer version of Translix."
        }
    }
}
