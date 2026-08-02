import Foundation
import Testing

@testable import TranlixModel

@Suite("SessionManifest")
struct SessionManifestTests {
    private func manifest(
        mic: TrackInfo = TrackInfo(),
        system: TrackInfo = TrackInfo(),
        sampleRate: Double = 16000
    ) -> SessionManifest {
        SessionManifest(
            title: "Clase",
            createdAt: Date(timeIntervalSince1970: 0),
            language: .spanish,
            sampleRate: sampleRate,
            tracks: [.mic: mic, .system: system]
        )
    }

    private func chunks(_ counts: [Int64]) -> [ChunkRef] {
        var start: Int64 = 0
        return counts.enumerated().map { index, count in
            defer { start += count }
            return ChunkRef(
                index: index,
                fileName: ChunkRef.fileName(track: .mic, index: index),
                startFrame: start,
                frameCount: count
            )
        }
    }

    // MARK: - On-disk shape

    @Test("tracks encode as a JSON object so the manifest stays readable by hand")
    func tracksEncodeAsObject() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try String(decoding: encoder.encode(manifest()), as: UTF8.self)

        #expect(json.contains(#""tracks":{"mic":{"#))
        #expect(json.contains(#""system":{"#))
        // A dictionary with non-string keys would serialize as a flat array instead.
        #expect(!json.contains(#""tracks":["#))
    }

    @Test("round-trips through JSON unchanged")
    func roundTrips() throws {
        var original = manifest(
            mic: TrackInfo(firstBufferHostTime: 100.5, chunks: chunks([160_000])),
            system: TrackInfo(
                firstBufferHostTime: 100.7,
                chunks: chunks([160_000]),
                archive: ArchivedAudio(
                    fileName: "system.m4a",
                    duration: 10,
                    verifiedAt: Date(timeIntervalSince1970: 42)
                )
            )
        )
        original.markers = [Marker(offset: 3.5, label: "acá", createdAt: Date(timeIntervalSince1970: 5))]
        original.deviceChanges = [
            DeviceChangeEvent(
                track: .mic,
                offset: 7,
                detail: "AirPods removed",
                occurredAt: Date(timeIntervalSince1970: 9)
            ),
        ]
        original.speakerNames = ["system-1": "Martín"]
        original.transcriptionEngine = "apple"
        original.resolvedLocaleIdentifier = "es-CL"

        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(SessionManifest.self, from: data) == original)
    }

    @Test("missing collections decode as empty instead of throwing")
    func toleratesMissingCollections() throws {
        let json = """
        {
          "id": "6C9B1A5E-0000-4000-8000-000000000000",
          "createdAt": 0,
          "state": "recorded"
        }
        """
        let decoded = try JSONDecoder().decode(SessionManifest.self, from: Data(json.utf8))

        #expect(decoded.markers.isEmpty)
        #expect(decoded.deviceChanges.isEmpty)
        #expect(decoded.speakerNames.isEmpty)
        #expect(decoded.tracks.isEmpty)
        #expect(decoded.title == "")
        #expect(decoded.language == .auto)
        #expect(decoded.sampleRate == 16000)
        #expect(decoded.schemaVersion == SessionManifest.currentSchemaVersion)
    }

    // MARK: - Timeline alignment

    @Test("the track that delivered audio first defines the session start")
    func earliestTrackDefinesStart() {
        let sut = manifest(
            mic: TrackInfo(firstBufferHostTime: 100.7),
            system: TrackInfo(firstBufferHostTime: 100.2)
        )
        #expect(sut.startHostTime == 100.2)
    }

    @Test("the later track is offset by exactly how late it was")
    func laterTrackIsOffset() {
        let sut = manifest(
            mic: TrackInfo(firstBufferHostTime: 100.7),
            system: TrackInfo(firstBufferHostTime: 100.2)
        )
        #expect(sut.offset(for: .system) == 0)
        #expect(abs(sut.offset(for: .mic) - 0.5) < 1e-9)
    }

    @Test("a track that never delivered audio gets no offset rather than a wrong one")
    func silentTrackHasNoOffset() {
        let sut = manifest(
            mic: TrackInfo(firstBufferHostTime: 100.7),
            system: TrackInfo()
        )
        #expect(sut.offset(for: .system) == 0)
    }

    @Test("chunk position comes from frame counts, not wall clock")
    func chunkPositionsComeFromFrames() {
        let sut = manifest(mic: TrackInfo(firstBufferHostTime: 10, chunks: chunks([160_000, 80_000])))
        let second = sut.track(.mic).chunks[1]

        #expect(second.startFrame == 160_000)
        #expect(second.start(sampleRate: 16000) == 10)
        #expect(second.duration(sampleRate: 16000) == 5)
        #expect(second.end(sampleRate: 16000) == 15)
    }

    @Test("a chunk's session time includes its track's alignment offset")
    func chunkSessionStartIncludesOffset() {
        let sut = manifest(
            mic: TrackInfo(firstBufferHostTime: 100.5, chunks: chunks([160_000, 160_000])),
            system: TrackInfo(firstBufferHostTime: 100.0)
        )
        let second = sut.track(.mic).chunks[1]

        // 10s into the mic's own timeline, but the mic started half a second late.
        #expect(abs(sut.sessionStart(of: second, on: .mic) - 10.5) < 1e-9)
    }

    @Test("duration is the furthest point reached by either track")
    func durationSpansBothTracks() {
        let sut = manifest(
            mic: TrackInfo(firstBufferHostTime: 100.5, chunks: chunks([160_000])),
            system: TrackInfo(firstBufferHostTime: 100.0, chunks: chunks([320_000]))
        )
        // mic: 0.5 offset + 10s = 10.5 · system: 0 offset + 20s = 20
        #expect(sut.duration == 20)
    }

    @Test("a session with no frames reports no audio")
    func emptySessionHasNoAudio() {
        #expect(!manifest().hasAudio)
        #expect(manifest(mic: TrackInfo(chunks: chunks([1]))).hasAudio)
    }

    // MARK: - Speakers

    @Test("speaker names come from the manifest and fall back to the raw id")
    func speakerNamesFallBackToID() {
        var sut = manifest()
        sut.speakerNames = ["system-1": "Martín"]

        #expect(sut.displayName(forSpeaker: "system-1") == "Martín")
        #expect(sut.displayName(forSpeaker: "system-2") == "system-2")
    }

    @Test("chunk file names are zero-padded and prefixed by track")
    func chunkFileNaming() {
        #expect(ChunkRef.fileName(track: .mic, index: 0) == "mic-0000.caf")
        #expect(ChunkRef.fileName(track: .system, index: 7) == "system-0007.caf")
        #expect(ChunkRef.fileName(track: .system, index: 1234) == "system-1234.caf")
    }

    @Test("only the system track is diarized")
    func onlySystemIsDiarized() {
        #expect(AudioTrack.system.needsDiarization)
        #expect(!AudioTrack.mic.needsDiarization)
    }
}
