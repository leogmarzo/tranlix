import Foundation
import TranlixModel
import TranlixStore

/// Recognition is a separate optional pass: remote speaker labels remain authoritative for
/// the transcript, while local voice analysis supplies reusable identity evidence.
public actor VoiceRecognitionService {
    private let profiles: VoiceProfileStore
    private let diarizer: any Diarizer

    public init(profiles: VoiceProfileStore, diarizer: any Diarizer) {
        self.profiles = profiles
        self.diarizer = diarizer
    }

    public func recognize(
        session: SessionHandle, progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        guard try await !profiles.profiles().isEmpty else { return }
        guard !(await labels(for: session)).isEmpty else { return }
        let voices = try await descriptors(session: session, progress: progress)
        try Task.checkCancellation()
        // Profiles can be deleted or renamed while the model is running.
        let known = try await profiles.profiles()
        var identities = voices.compactMapValues { VoiceMatcher.match($0, profiles: known) }
        // A collision between clusters is uncertain even if each individual score is high.
        let groups = Dictionary(grouping: identities.keys, by: { identities[$0]!.personID })
        for ids in groups.values where ids.count > 1 {
            for id in ids { identities[id]?.source = .suggested }
        }
        try await session.applyVoiceIdentities(identities,
            evaluatedSpeakers: Set(await labels(for: session).map(\.speakerID)),
            existingPersonIDs: Set(known.map(\.id)))
    }

    @discardableResult
    public func enroll(
        session: SessionHandle, speakerID: String, name: String,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> VoiceProfile {
        guard speakerID != SessionManifest.micSpeakerID else { throw VoiceProfileError.invalidEvidence }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VoiceProfileError.emptyName }
        let voices = try await descriptors(session: session, progress: progress)
        try Task.checkCancellation()
        guard let voice = voices[speakerID] else { throw VoiceProfileError.invalidEvidence }
        let origin = await VoiceProfile.Origin(sessionID: session.manifest.id, speakerID: speakerID)
        let profile = try await profiles.enroll(name: name, descriptor: voice, origin: origin)
        do {
            try await session.confirmVoiceIdentity(profile, for: speakerID)
        } catch {
            try? await profiles.delete(profile.id)
            throw error
        }
        return profile
    }

    public func confirm(session: SessionHandle, speakerID: String, personID: UUID) async throws {
        guard let profile = try await profiles.profiles().first(where: { $0.id == personID })
        else { throw VoiceProfileError.missingPerson }
        try await session.confirmVoiceIdentity(profile, for: speakerID)
    }

    public func descriptors(
        session: SessionHandle, progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> [String: VoiceDescriptor] {
        try Task.checkCancellation()
        let labels = await labels(for: session)
        guard !labels.isEmpty else { throw VoiceProfileError.invalidEvidence }
        let manifest = await session.manifest
        let layout = await session.layout
        let scratch = URL(filePath: NSTemporaryDirectory()).appending(path: "tranlix-voices-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let audio = try await DiarizationPipeline(diarizer: diarizer).systemAudio(
            manifest: manifest, layout: layout, scratch: scratch
        )
        let fingerprint = try DiarizationPipeline.fingerprint(of: audio.url)
        let offset = manifest.offset(for: .system)
        let local: [SpeakerTurn]
        // A freshly forced local analysis takes precedence over the auxiliary remote cache.
        if let stored = await session.readDiarization(), stored.diarizerID == diarizer.id.rawValue,
           stored.audioFingerprint == fingerprint, Self.compatible(stored.turns) {
            local = stored.turns.map { turn in
                var raw = turn
                raw.start -= offset
                raw.end -= offset
                return raw
            }
        } else if let cached = await session.readVoiceAnalysis(), cached.audioFingerprint == fingerprint,
                  cached.configurationID == diarizer.configurationID, Self.compatible(cached.turns) {
            local = cached.turns
        } else {
            try await diarizer.prepare { progress($0 * 0.1) }
            try Task.checkCancellation()
            local = try await diarizer.diarize(audio: audio.url) { progress(0.1 + $0 * 0.9) }
            try Task.checkCancellation()
            try await cache(local, fingerprint: fingerprint, session: session)
        }
        let shifted = local.map { turn in
            var result = turn
            result.start += offset
            result.end += offset
            return result
        }
        progress(1)
        return VoiceMatcher.descriptors(local: shifted, labels: labels)
    }

    private func cache(_ turns: [SpeakerTurn], fingerprint: String, session: SessionHandle) async throws {
        try await session.writeVoiceAnalysis(Diarization(diarizerID: diarizer.id.rawValue,
            configurationID: diarizer.configurationID, generatedAt: Date(),
            audioFingerprint: fingerprint, turns: turns))
    }

    private static func compatible(_ turns: [SpeakerTurn]) -> Bool {
        !turns.isEmpty && turns.allSatisfy {
            $0.voice?.modelID == FluidAudioDiarizer.voiceModelID && $0.voice?.vector.count == 256
        }
    }

    private func labels(for session: SessionHandle) async -> [SpeakerTurn] {
        if let stored = await session.readDiarization(), !stored.turns.isEmpty { return stored.turns }
        guard let transcript = try? await session.readTranscript() else { return [] }
        return transcript.segments.compactMap { segment in
            guard segment.track == .system, let id = segment.speakerID else { return nil }
            return SpeakerTurn(speakerID: id, start: segment.start, end: segment.end)
        }
    }
}
