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
    public private(set) var isRecording = false

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
        let start = await handle.manifest.startHostTime ?? hostTime()
        let marker = Marker(
            offset: max(0, hostTime() - start),
            label: label,
            createdAt: now
        )
        try await handle.addMarker(marker)
    }

    /// Current RMS level per track, for the meters.
    public var levels: [AudioTrack: Float] {
        recorders.mapValues(\.level)
    }

    /// Seconds since the first sample of the session.
    public func elapsed() async -> TimeInterval {
        guard let handle, let start = await handle.manifest.startHostTime else { return 0 }
        return max(0, hostTime() - start)
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

        let start = await handle.manifest.startHostTime ?? hostTime()
        let event = DeviceChangeEvent(
            track: track,
            offset: max(0, hostTime() - start),
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

    /// Keeps the machine awake for the length of the session.
    private func preventSleep() {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: "Grabando una sesión"
        )
    }

    // MARK: - Stopping

    /// Stops both tracks and leaves the session in `.recorded`.
    ///
    /// Each recorder drains synchronously, so by the time this returns the manifest describes
    /// every sample that reached the disk.
    public func stop() async throws {
        guard isRecording, let handle else { return }
        isRecording = false

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
