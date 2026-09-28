import AVFoundation
import Foundation
import Testing
import TranlixModel
import TranlixStore
import TranlixTestSupport

@testable import TranlixTranscribe

/// The whole pipeline over real speech with the real engine.
///
/// Run deliberately:
///
///     TRANLIX_INTEGRATION=1 swift test --filter Integration
@Suite(
    "Pipeline Integration",
    .enabled(if: ProcessInfo.processInfo.integrationEnabled),
    .serialized
)
struct PipelineIntegrationTests {
    private let epoch = Date(timeIntervalSince1970: 1_754_152_200)
    private let language = TranscriptionLanguage.fixed("es-CL")

    private let lines = [
        "Buenos días. Hoy vamos a ver la distribución normal.",
        "El teorema central del límite explica por qué aparece tan seguido.",
    ]

    /// A session whose chunks hold real spoken Spanish, one sentence each.
    private func spokenSession(in root: URL) async throws -> SessionHandle {
        let store = SessionStore(root: root)
        let handle = try store.createSession(title: "Clase", language: .spanish, now: epoch)
        let layout = await handle.layout
        try FileManager.default.createDirectory(
            at: layout.chunksDirectory, withIntermediateDirectories: true
        )

        var startFrame: Int64 = 0
        for (index, line) in lines.enumerated() {
            let url = layout.chunkURL(track: .system, index: index)
            try await SpeechSample.write(text: line, languageCode: "es-MX", to: url)
            let frames = try AVAudioFile(forReading: url).length
            try await handle.appendChunk(
                ChunkRef(
                    index: index,
                    fileName: url.lastPathComponent,
                    startFrame: startFrame,
                    frameCount: frames
                ),
                to: .system
            )
            startFrame += frames
        }

        try await handle.recordFirstBuffer(hostTime: 100, for: .system)
        try await handle.setState(.recorded)
        return handle
    }

    @Test("transcribes a whole session, archives the audio and removes the chunks")
    func endToEnd() async throws {
        try await withTemporaryRoot { root in
            let handle = try await spokenSession(in: root)
            let layout = await handle.layout
            let chunkURLs = await handle.manifest.track(.system).chunks.map { layout.chunkURL($0) }
            let rawBytes = chunkURLs.reduce(Int64(0)) { total, url in
                total + (((try? FileManager.default
                    .attributesOfItem(atPath: url.path)[.size]) as? Int64) ?? 0)
            }

            let pipeline = TranscriptionPipeline(engine: AppleSpeechEngine())
            let phases = Locked<[String]>([])
            let transcript = try await pipeline.process(
                session: handle,
                language: language,
                progress: { phase in phases.withValue { $0.append("\(phase)") } }
            )

            let text = transcript.segments.map(\.text).joined(separator: " ")
            print("TRANSCRIPT[end-to-end]: \(text)")

            // Both chunks are represented, so the run really covered the session rather than
            // stopping at the first piece.
            #expect(text.lowercased().contains("distribución"))
            #expect(text.lowercased().contains("teorema"))

            // Times advance across chunk boundaries onto one session timeline.
            #expect(zip(transcript.segments, transcript.segments.dropFirst())
                .allSatisfy { $0.start <= $1.start })
            let secondChunkStart = try await Double(
                handle.manifest.track(.system).chunks[1].startFrame
            ) / handle.manifest.sampleRate
            #expect(transcript.segments.contains { $0.start >= secondChunkStart - 0.5 })

            // The audio was archived and only then were the originals removed.
            let manifest = await handle.manifest
            #expect(manifest.state == .ready)
            let archive = try #require(manifest.track(.system).archive)
            #expect(FileManager.default.exists(layout.archiveURL(track: .system)))
            for url in chunkURLs {
                #expect(!FileManager.default.exists(url))
            }

            let archivedBytes = ((try? FileManager.default.attributesOfItem(
                atPath: layout.archiveURL(track: .system).path
            )[.size]) as? Int64) ?? 0
            print("ARCHIVE: \(rawBytes) B de CAF -> \(archivedBytes) B de AAC, \(String(format: "%.2f", archive.duration)) s")
            #expect(archivedBytes < rawBytes / 3)

            #expect(phases.value.contains { $0.contains("archiving") })
            #expect(FileManager.default.exists(layout.transcriptJSONURL))
        }
    }

    @Test("a second run over the same session reuses every stored result")
    func secondRunReusesEverything() async throws {
        try await withTemporaryRoot { root in
            let handle = try await spokenSession(in: root)
            let pipeline = TranscriptionPipeline(engine: AppleSpeechEngine())

            try await pipeline.transcribe(session: handle, language: language, progress: { _ in })

            let reused = Locked(0)
            let started = Date()
            try await pipeline.transcribe(
                session: handle,
                language: language,
                progress: { phase in
                    if case let .transcribing(_, _, count) = phase {
                        reused.withValue { $0 = max($0, count) }
                    }
                }
            )
            let elapsed = Date().timeIntervalSince(started)

            #expect(reused.value == 2)
            // Reuse is the point: a second pass should be filesystem-fast, not model-slow.
            #expect(elapsed < 2)
        }
    }
}
