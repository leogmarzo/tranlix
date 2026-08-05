import AVFoundation
import Foundation
import TranlixModel
import TranlixStore

/// Something worth telling the user about while recording.
public enum RecordingEvent: Sendable, Equatable {
    case started(URL)
    case deviceChanged(AudioTrack, String)
    case lowDiskSpace(availableBytes: Int64)
    case writeFailed(AudioTrack, String)

    /// The writer queue fell behind and samples were lost. Should never happen; surfaced
    /// rather than hidden so that a recording with holes is never presented as intact.
    case droppedFrames(AudioTrack, Int)

    case paused(offset: TimeInterval)
    case resumed(pausedFor: TimeInterval)

    case stopped(URL)
}

public struct RecordingConfiguration: Sendable {
    public var sampleRate: Double = 16000

    /// Chunks are short enough that losing the one in progress costs little, and long enough
    /// that the manifest is not rewritten constantly.
    public var chunkDuration: TimeInterval = 300

    /// How much recording time must fit on disk before starting.
    public var requiredHours: Double = 3

    public var drainInterval: DispatchTimeInterval = .milliseconds(100)
    public var diskCheckInterval: TimeInterval = 30

    public init() {}
}

/// Builds a capture backend for a track. Injectable so the coordinator can be driven from
/// scripted audio in tests instead of from hardware.
public typealias AudioSourceFactory = @Sendable (AudioTrack, Double) throws -> any AudioSource

/// Runs a recording session end to end.
///
/// Owns the two capture backends, the two writer pipelines and the session handle, and keeps
/// the manifest describing exactly what has reached the disk. Everything here exists to
/// protect one property: a session that was interrupted, whose device changed, or whose app
/// was killed still leaves usable audio and a manifest that explains it.
public actor RecordingCoordinator {
    /// A session is under way. Stays true across a pause: the session has not ended, it is
    /// just not capturing at this instant.
    public private(set) var isRecording = false

    /// Capturing is suspended and can be resumed.
    public private(set) var isPaused = false

    private let store: SessionStore
    private let configuration: RecordingConfiguration
    private let sourceFactory: AudioSourceFactory
    private let hostTime: @Sendable () -> TimeInterval

    private var handle: SessionHandle?
    private var recorders: [AudioTrack: TrackRecorder] = [:]
    private var sources: [AudioTrack: any AudioSource] = [:]
    private var activity: (any NSObjectProtocol)?
    private var diskCheck: Task<Void, Never>?

    private let events = AsyncStream.makeStream(of: RecordingEvent.self)

    /// Events worth surfacing in the UI.
    public nonisolated var eventStream: AsyncStream<RecordingEvent> { events.stream }

    public init(
        store: SessionStore,
        configuration: RecordingConfiguration = RecordingConfiguration(),
        hostTime: @escaping @Sendable () -> TimeInterval = { CACurrentMediaTime() },
        sourceFactory: @escaping AudioSourceFactory = RecordingCoordinator.defaultSourceFactory
    ) {
        self.store = store
        self.configuration = configuration
        self.hostTime = hostTime
        self.sourceFactory = sourceFactory
    }

    public static let defaultSourceFactory: AudioSourceFactory = { track, sampleRate in
        switch track {
        case .mic: try MicrophoneSource(sampleRate: sampleRate)
        case .system: try SystemAudioSource(sampleRate: sampleRate)
        }
    }

    // MARK: - Starting

    /// Creates the session and starts both tracks.
    ///
    /// Disk space is checked before anything is created: running out mid-session is the one
    /// failure the rest of this design cannot recover from. If one track fails to start the
    /// other keeps going — half a recording beats none, and the manifest records which track
    /// is missing.
    @discardableResult
    public func start(
        title: String,
        language: SessionLanguage,
        now: Date
    ) async throws -> SessionHandle {
        guard !isRecording else { throw CaptureError.engineFailed("ya hay una grabación en curso") }

        try store.requireSpace(forHours: configuration.requiredHours)

        let handle = try store.createSession(
            title: title,
            language: language,
            sampleRate: configuration.sampleRate,
            now: now
        )
        self.handle = handle
        isRecording = true

        let layout = await handle.layout
        let framesPerChunk = Int64(configuration.chunkDuration * configuration.sampleRate)

        var startErrors: [any Error] = []
        for track in AudioTrack.allCases {
            do {
                try startTrack(track, layout: layout, framesPerChunk: framesPerChunk)
            } catch {
                startErrors.append(error)
                emit(.writeFailed(track, error.localizedDescription))
            }
        }

        guard startErrors.count < AudioTrack.allCases.count else {
            // Nothing is capturing; do not leave an empty session behind pretending otherwise.
            await cleanUp()
            isRecording = false
            self.handle = nil
            try? FileManager.default.removeItem(at: layout.root)
            throw startErrors[0]
        }

        preventSleep()
        startDiskMonitor()
        emit(.started(layout.root))
        return handle
    }

    private func startTrack(
        _ track: AudioTrack,
        layout: SessionLayout,
        framesPerChunk: Int64
    ) throws {
        let recorder = try TrackRecorder(
            track: track,
            layout: layout,
            sampleRate: configuration.sampleRate,
            framesPerChunk: framesPerChunk,
            drainInterval: configuration.drainInterval
        )

        // Best-effort during recording: gets each chunk into the manifest promptly so a crash
        // loses at most the chunk in progress. `stop` flushes again, awaited, so the final
        // state never depends on one of these tasks having landed.
        recorder.onChunkClosed = { [weak self] in
            Task { await self?.flushTrack(track) }
        }
        // Gets the track's start time into the manifest within one drain cycle rather than
        // one chunk, so elapsed time, marker offsets and recovery all work from the moment
        // audio starts flowing.
        recorder.onFirstBuffer = { [weak self] in
            Task { await self?.flushTrack(track) }
        }
        recorder.onWriteError = { [weak self] error in
            Task { await self?.emit(.writeFailed(track, error.localizedDescription)) }
        }

        let source = try sourceFactory(track, configuration.sampleRate)
        source.onDeviceChange = { [weak self] detail in
            Task { await self?.handleDeviceChange(track, detail: detail) }
        }

        recorder.start()
        do {
            try source.start(into: recorder)
        } catch {
            recorder.stop()
            throw error
        }

        recorders[track] = recorder
        sources[track] = source
    }

    // MARK: - During

    public func addMarker(label: String?, now: Date) async throws {
        guard let handle else { return }
        let marker = Marker(
            offset: await elapsed(),
            label: label,
            createdAt: now
        )
        try await handle.addMarker(marker)
    }

    /// Current RMS level per track, for the meters.
    public var levels: [AudioTrack: Float] {
        recorders.mapValues(\.level)
    }

    /// How much audio the session holds, in seconds.
    ///
    /// Counted in recorded frames rather than in elapsed wall clock, for two reasons. Audio
    /// clocks drift against the system clock, so over a long class the two disagree by enough
    /// to smear the merged transcript. And a paused session records nothing while the wall
    /// clock keeps running — anything positioned by wall clock would land past the end of the
    /// audio it is supposed to point at.
    ///
    /// This is the same quantity `SessionManifest.duration` reports once the session is on
    /// disk; it is computed live here because the manifest only learns about a chunk when the
    /// chunk closes.
    public func elapsed() async -> TimeInterval {
        guard let handle else { return 0 }
        let manifest = await handle.manifest
        return AudioTrack.allCases.reduce(0) { furthest, track in
            guard let recorder = recorders[track] else { return furthest }
            let seconds = Double(recorder.totalFrames) / configuration.sampleRate
            return max(furthest, manifest.offset(for: track) + seconds)
        }
    }

    // MARK: - Pausing

    /// Suspends capture without ending the session.
    ///
    /// The paused stretch is elided rather than recorded as silence: nothing is written, so an
    /// hour-long break costs no disk, no transcription time and no waiting. Both tracks close
    /// their chunk on the way in, which means everything recorded so far is already complete
    /// on disk and in the manifest — a session killed while paused loses nothing.
    ///
    /// The two tracks stop at their own next audio callback rather than at one shared instant,
    /// so each pause can shift them against each other by up to one callback, on the order of
    /// ten milliseconds. Correcting that would mean padding from the system clock, which is
    /// the very clock this design avoids; a bounded, unbiased ten milliseconds per pause is
    /// the better trade, and well under what diarization can resolve anyway.
    public func pause(now: Date = Date()) async throws {
        guard isRecording, !isPaused, let handle else { return }
        isPaused = true

        let offset = await elapsed()
        for recorder in recorders.values { recorder.pause() }
        for track in AudioTrack.allCases { await flushTrack(track) }

        // Written after the flush so the offset it carries is one the manifest can already
        // account for in chunks.
        try await handle.recordPause(PauseEvent(offset: offset, pausedAt: now))
        emit(.paused(offset: offset))
    }

    public func resume(now: Date = Date()) async throws {
        guard isRecording, isPaused, let handle else { return }

        let pausedFor = await handle.manifest.pauses.last
            .map { max(0, now.timeIntervalSince($0.pausedAt)) } ?? 0
        try await handle.recordResume(at: now)

        isPaused = false
        for recorder in recorders.values { recorder.resume() }
        emit(.resumed(pausedFor: pausedFor))
    }

    /// Moves everything a track has finished into the manifest.
    ///
    /// Covers both the closed chunks and the track's start time, so that whenever this
    /// returns the manifest matches what is on disk for that track.
    private func flushTrack(_ track: AudioTrack) async {
        guard let handle, let recorder = recorders[track] else { return }

        if let hostTime = recorder.firstBufferHostTime {
            try? await handle.recordFirstBuffer(hostTime: hostTime, for: track)
        }
        for chunk in recorder.takePendingChunks() {
            do {
                try await handle.appendChunk(chunk, to: track)
            } catch {
                emit(.writeFailed(track, error.localizedDescription))
            }
        }
    }

    /// Handles a device change without ending the session.
    ///
    /// The source has already rebuilt itself by the time this runs; all that is left is to
    /// close the chunk in progress so the discontinuity lands on a file boundary, and to note
    /// the event in the manifest so it is not mistaken for a bug when reviewing later.
    private func handleDeviceChange(_ track: AudioTrack, detail: String) async {
        guard isRecording, let handle else { return }
        recorders[track]?.rollOverChunk()
        await flushTrack(track)

        let event = DeviceChangeEvent(
            track: track,
            offset: await elapsed(),
            detail: detail,
            occurredAt: Date()
        )
        try? await handle.recordDeviceChange(event)
        emit(.deviceChanged(track, detail))
    }

    private func startDiskMonitor() {
        let interval = configuration.diskCheckInterval
        let store = store
        diskCheck = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                guard let available = try? store.availableCapacityBytes() else { continue }
                if available < SessionStore.estimatedBytes(forHours: 0.5) {
                    await self?.emit(.lowDiskSpace(availableBytes: available))
                }
            }
        }
    }

    /// Keeps the machine awake for the length of the session, pauses included.
    ///
    /// Held through a pause on purpose. Letting the Mac sleep would tear down the microphone
    /// engine and the system tap, and resuming onto a half-rebuilt graph is a far worse
    /// outcome than a laptop that stayed awake through a coffee break.
    private func preventSleep() {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: "Grabando una sesión"
        )
    }

    // MARK: - Stopping

    /// Ends the session for good and leaves it in `.recorded`.
    ///
    /// Works the same whether the session was running or paused, and is deliberately the only
    /// thing that ends one: the stop button pauses, so finishing always takes a second,
    /// separate decision. Losing a class to a misplaced click is the failure this whole design
    /// exists to prevent.
    ///
    /// Each recorder drains synchronously, so by the time this returns the manifest describes
    /// every sample that reached the disk.
    public func stop(now: Date = Date()) async throws {
        guard isRecording, let handle else { return }
        // A session finished from a pause has an open pause event. Closing it keeps the
        // manifest honest about how long the recording was actually suspended.
        if isPaused {
            try? await handle.recordResume(at: now)
        }
        isRecording = false
        isPaused = false

        // Each recorder drains synchronously, so once this returns everything that reached
        // the disk is sitting in the pending queues.
        await cleanUp()

        for track in AudioTrack.allCases {
            await flushTrack(track)
        }
        for (track, recorder) in recorders where recorder.droppedFrames > 0 {
            emit(.droppedFrames(track, recorder.droppedFrames))
        }
        recorders.removeAll()
        sources.removeAll()

        try await handle.setState(.recorded)
        let layout = await handle.layout
        self.handle = nil
        emit(.stopped(layout.root))
    }

    /// Stops capture without touching the session state. Used on app termination, where the
    /// goal is only to close the current chunk before the process dies.
    public func finalizeForTermination() async {
        guard isRecording else { return }
        isRecording = false
        isPaused = false
        await cleanUp()
        for track in AudioTrack.allCases {
            await flushTrack(track)
        }
        recorders.removeAll()
        sources.removeAll()
        handle = nil
    }

    private func cleanUp() async {
        diskCheck?.cancel()
        diskCheck = nil

        for source in sources.values { source.stop() }
        for recorder in recorders.values { recorder.stop() }

        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    private func emit(_ event: RecordingEvent) {
        events.continuation.yield(event)
    }
}
