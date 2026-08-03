import AVFoundation
import Foundation
import TranlixModel

/// Turns a track's chunks into one compressed file, and back again.
///
/// Lives here rather than in capture or transcription because this is the on-disk audio
/// lifecycle, and the store is the module that owns it. Both directions matter: chunks
/// become an archive once transcription has succeeded, and the archive becomes chunks again
/// when a session is re-transcribed with the other engine months later.
public enum AudioArchiver {
    /// AAC mono at 32 kbps: about 15 MB an hour per track, which is what makes keeping every
    /// recording indefinitely a reasonable thing to do.
    public static let bitRate = 32000

    public enum ArchiveError: Error, LocalizedError {
        case nothingToArchive(AudioTrack)
        case chunkUnreadable(URL)
        case encodingFailed(String)
        case verificationFailed(expected: TimeInterval, actual: TimeInterval)

        public var errorDescription: String? {
            switch self {
            case let .nothingToArchive(track):
                "No hay audio para archivar en la pista \(track.rawValue)."
            case let .chunkUnreadable(url):
                "No se pudo leer el fragmento \(url.lastPathComponent)."
            case let .encodingFailed(detail):
                "Falló la compresión a AAC: \(detail)"
            case let .verificationFailed(expected, actual):
                """
                El archivo comprimido no coincide con los fragmentos: se esperaban \
                \(String(format: "%.2f", expected)) s y tiene \(String(format: "%.2f", actual)) s. \
                Los fragmentos originales no se borraron.
                """
            }
        }
    }

    /// Concatenates a track's chunks into `audio/<track>.m4a` and verifies the result.
    ///
    /// Verification is not a formality. The chunks are the only copy of the recording until
    /// this succeeds, so the compressed file is reopened and measured before anything is
    /// allowed to delete them.
    public static func archive(
        track: AudioTrack,
        chunks: [ChunkRef],
        layout: SessionLayout,
        sampleRate: Double
    ) throws -> ArchivedAudio {
        guard !chunks.isEmpty else { throw ArchiveError.nothingToArchive(track) }

        try FileManager.default.createDirectory(
            at: layout.audioDirectory, withIntermediateDirectories: true
        )
        let destination = layout.archiveURL(track: track)
        try? FileManager.default.removeItem(at: destination)

        let expected = chunks.reduce(Int64(0)) { $0 + $1.frameCount }
        let expectedSeconds = Double(expected) / sampleRate

        do {
            try encode(chunks: chunks, layout: layout, sampleRate: sampleRate, to: destination)
        } catch let error as ArchiveError {
            try? FileManager.default.removeItem(at: destination)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw ArchiveError.encodingFailed(error.localizedDescription)
        }

        guard let written = try? AVAudioFile(forReading: destination) else {
            try? FileManager.default.removeItem(at: destination)
            throw ArchiveError.encodingFailed("el archivo escrito no se puede reabrir")
        }
        let actualSeconds = Double(written.length) / written.processingFormat.sampleRate

        // AAC adds encoder priming and padding, so an exact match is not expected. A real
        // failure is short by seconds or minutes, never by a fraction of one.
        guard abs(actualSeconds - expectedSeconds) <= 1.0 else {
            try? FileManager.default.removeItem(at: destination)
            throw ArchiveError.verificationFailed(expected: expectedSeconds, actual: actualSeconds)
        }

        return ArchivedAudio(
            fileName: destination.lastPathComponent,
            duration: actualSeconds,
            verifiedAt: Date()
        )
    }

    private static func encode(
        chunks: [ChunkRef],
        layout: SessionLayout,
        sampleRate: Double,
        to destination: URL
    ) throws {
        let output = try AVAudioFile(
            forWriting: destination,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: bitRate,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        let format = output.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16384) else {
            throw ArchiveError.encodingFailed("no se pudo reservar el buffer de lectura")
        }

        for chunk in chunks.sorted(by: { $0.index < $1.index }) {
            let url = layout.chunkURL(chunk)
            guard let input = try? AVAudioFile(forReading: url) else {
                throw ArchiveError.chunkUnreadable(url)
            }
            while input.framePosition < input.length {
                try input.read(into: buffer)
                guard buffer.frameLength > 0 else { break }
                try output.write(from: buffer)
            }
        }
    }

    /// Deletes a track's chunk files. Only ever called once the archive has been verified.
    public static func removeChunks(_ chunks: [ChunkRef], layout: SessionLayout) {
        for chunk in chunks {
            try? FileManager.default.removeItem(at: layout.chunkURL(chunk))
        }
    }

    /// Rebuilds chunk-sized pieces from an archive, in a directory of the caller's choosing.
    ///
    /// This is what keeps re-transcription resumable after the CAFs are gone: a session
    /// transcribed a year ago with Apple's engine can be run through Whisper and still pick
    /// up where it left off if that run is interrupted.
    public static func split(
        archive url: URL,
        track: AudioTrack,
        framesPerChunk: Int64,
        into directory: URL
    ) throws -> [(chunk: ChunkRef, url: URL)] {
        guard let input = try? AVAudioFile(forReading: url) else {
            throw ArchiveError.chunkUnreadable(url)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let format = input.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16384) else {
            throw ArchiveError.encodingFailed("no se pudo reservar el buffer de lectura")
        }

        var pieces: [(chunk: ChunkRef, url: URL)] = []
        var index = 0
        var startFrame: Int64 = 0

        while input.framePosition < input.length {
            let fileName = ChunkRef.fileName(track: track, index: index)
            let pieceURL = directory.appending(path: fileName)
            try? FileManager.default.removeItem(at: pieceURL)

            let output = try AVAudioFile(
                forWriting: pieceURL,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: format.sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )

            var written: Int64 = 0
            while written < framesPerChunk, input.framePosition < input.length {
                let wanted = min(
                    AVAudioFrameCount(framesPerChunk - written),
                    buffer.frameCapacity
                )
                try input.read(into: buffer, frameCount: wanted)
                guard buffer.frameLength > 0 else { break }
                try output.write(from: buffer)
                written += Int64(buffer.frameLength)
            }

            guard written > 0 else {
                try? FileManager.default.removeItem(at: pieceURL)
                break
            }

            pieces.append((
                ChunkRef(
                    index: index,
                    fileName: fileName,
                    startFrame: startFrame,
                    frameCount: written
                ),
                pieceURL
            ))
            startFrame += written
            index += 1
        }

        return pieces
    }
}
