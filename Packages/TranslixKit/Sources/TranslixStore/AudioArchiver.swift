import AVFoundation
import Foundation
import TranslixModel

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
            try encode(
                sources: chunks.sorted { $0.index < $1.index }.map(layout.chunkURL),
                sampleRate: sampleRate,
                to: destination
            )
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

    /// Joins a track's chunks into one AAC file at a caller-chosen destination.
    ///
    /// Exposed for the stages that need a whole track in one piece and must not disturb the
    /// session folder doing it — diarization clusters voices across the entire recording, so
    /// it cannot be fed chunk by chunk, and it runs on sessions whose archive may not exist
    /// yet. Unlike `archive`, this neither verifies nor records anything: the caller is
    /// producing a scratch file, not replacing the source of truth.
    public static func concatenate(
        track: AudioTrack,
        chunks: [ChunkRef],
        layout: SessionLayout,
        sampleRate: Double,
        to destination: URL
    ) throws {
        guard !chunks.isEmpty else { throw ArchiveError.nothingToArchive(track) }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: destination)
        try encode(
            sources: chunks.sorted { $0.index < $1.index }.map(layout.chunkURL),
            sampleRate: sampleRate,
            to: destination
        )
    }

    /// Encodes audio files, in the order given, into one AAC file at a chosen destination.
    ///
    /// The generalisation `concatenate` always wanted. Nothing about joining audio requires
    /// the pieces to be chunks the layout knows about, and a caller that needs a contiguous
    /// stretch of a track — one batch of it to send to a remote engine, say — has a list of
    /// URLs and no reason to invent `ChunkRef`s to pass them.
    public static func encode(sources: [URL], sampleRate: Double, to destination: URL) throws {
        guard !sources.isEmpty else {
            throw ArchiveError.encodingFailed("no hay nada para codificar")
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: destination)

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

        for url in sources {
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

    /// Cuts one frame range out of an archive into an AAC file at a chosen destination.
    ///
    /// What makes a re-run of an archived session batch-granular rather than all-or-nothing,
    /// the same promise `split` keeps for the chunk path — but producing the compressed shape
    /// a remote engine should be sent, instead of the raw PCM `split` writes, which is eight
    /// times the bytes and nothing anybody should be asked to upload.
    ///
    /// The range is nominal, in frames of the original recording. AAC priming and padding
    /// mean the audio it yields can differ from the same range read out of the CAF chunks by
    /// a fraction of a second — the same bargain the archive's own verification already makes
    /// with its one-second tolerance, and the same drift `split` has always had.
    public static func extract(
        archive url: URL,
        range: Range<Int64>,
        sampleRate: Double,
        to destination: URL
    ) throws {
        guard !range.isEmpty else {
            throw ArchiveError.encodingFailed("el rango pedido está vacío")
        }
        guard let input = try? AVAudioFile(forReading: url) else {
            throw ArchiveError.chunkUnreadable(url)
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: destination)

        // Clamped rather than trusted: the range comes from the manifest's frame counts, and
        // the archive is an AAC re-encoding of those frames, so the two agree to within the
        // encoder's padding and not exactly.
        input.framePosition = min(range.lowerBound, input.length)
        let wantedTotal = min(range.upperBound, input.length) - input.framePosition
        guard wantedTotal > 0 else {
            throw ArchiveError.encodingFailed(
                "el rango pedido cae fuera del archivo comprimido"
            )
        }

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

        let format = input.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16384) else {
            throw ArchiveError.encodingFailed("no se pudo reservar el buffer de lectura")
        }

        var written: Int64 = 0
        while written < wantedTotal, input.framePosition < input.length {
            let wanted = min(AVAudioFrameCount(wantedTotal - written), buffer.frameCapacity)
            try input.read(into: buffer, frameCount: wanted)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
            written += Int64(buffer.frameLength)
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
