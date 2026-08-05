import Foundation
import Observation
import SwiftUI
import TranlixCapture
import TranlixModel
import TranlixStore

/// Drives the Record screen.
///
/// Bridges the capture actor to SwiftUI: polls levels and elapsed time on a timer while
/// recording, and turns the coordinator's event stream into things worth showing on screen.
@MainActor
@Observable
final class RecorderViewModel {
    var title = ""
    var language: SessionLanguage = .spanish

    private(set) var isRecording = false

    /// Capture is suspended. The session has not ended: `isRecording` stays true.
    private(set) var isPaused = false

    private(set) var isBusy = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var levels: [AudioTrack: Float] = [:]
    private(set) var markerCount = 0
    private(set) var lastSessionFolder: URL?

    /// Tracks that have been silent long enough to be worth flagging.
    ///
    /// Judged over a few seconds rather than from the current sample: speech is full of gaps,
    /// and a warning that blinks between words is noise. What this is actually for is
    /// catching a track that never produces anything — the wrong input device, or a system
    /// tap that failed — and that condition lasts.
    private(set) var silentTracks: Set<AudioTrack> = []

    /// Matches the meter's floor: below this the signal is indistinguishable from silence.
    private static let silenceFloor: Float = 0.001

    private static let silenceGrace: TimeInterval = 3

    private var lastSignalAt: [AudioTrack: Date] = [:]

    /// Blocking problem, shown as an alert.
    var errorMessage: String?

    /// Things that happened mid-session and the user should know about: a device change, a
    /// track that never started, disk running out. Kept visible rather than flashed.
    private(set) var notices: [Notice] = []

    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let isSevere: Bool
    }

    private let environment: AppEnvironment
    private var pollTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?

    /// Called after a session finishes so the library can refresh.
    var onSessionFinished: (() -> Void)?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    var canRecord: Bool { !isRecording && !isBusy }

    /// Capturing right now, as opposed to open-but-paused.
    var isCapturing: Bool { isRecording && !isPaused }

    func start() async {
        guard canRecord else { return }
        isBusy = true
        defer { isBusy = false }

        notices.removeAll()
        markerCount = 0
        elapsed = 0
        levels = [:]
        silentTracks = []
        let now = Date()
        lastSignalAt = Dictionary(uniqueKeysWithValues: AudioTrack.allCases.map { ($0, now) })

        // Ask before starting so a denial is an explanation rather than a silent empty track.
        guard await MicrophoneSource.requestPermission() else {
            errorMessage = CaptureError.microphonePermissionDenied.localizedDescription
            return
        }

        let coordinator = environment.coordinator
        observeEvents(of: coordinator)

        do {
            try await coordinator.start(title: title, language: language, now: Date())
            isRecording = true
            isPaused = false
            startPolling(coordinator)
        } catch {
            eventTask?.cancel()
            eventTask = nil
            errorMessage = error.localizedDescription
        }
    }

    /// Suspends capture. This is what the stop button does.
    ///
    /// Deliberately not the end of the session: ending one takes a second, explicit action,
    /// so a misplaced click costs a pause rather than a class.
    func pause() async {
        guard isCapturing, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            try await environment.coordinator.pause(now: Date())
            isPaused = true
            levels = [:]
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resume() async {
        guard isRecording, isPaused, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            try await environment.coordinator.resume(now: Date())
            isPaused = false
            // Silence is judged over a window, and the paused stretch is not evidence about
            // whether a device is working.
            let now = Date()
            lastSignalAt = Dictionary(
                uniqueKeysWithValues: AudioTrack.allCases.map { ($0, now) }
            )
            silentTracks = []
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Ends the session for good.
    func finish() async {
        guard isRecording else { return }
        isBusy = true
        defer { isBusy = false }

        pollTask?.cancel()
        pollTask = nil

        do {
            try await environment.coordinator.stop(now: Date())
        } catch {
            errorMessage = error.localizedDescription
        }

        isRecording = false
        isPaused = false
        levels = [:]
        silentTracks = []
        eventTask?.cancel()
        eventTask = nil
        title = ""
        onSessionFinished?()
    }

    func addMarker() async {
        guard isCapturing else { return }
        do {
            try await environment.coordinator.addMarker(label: nil, now: Date())
            markerCount += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Live state

    private func startPolling(_ coordinator: RecordingCoordinator) {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let levels = await coordinator.levels
                let elapsed = await coordinator.elapsed()
                guard !Task.isCancelled else { return }
                self?.levels = levels
                self?.elapsed = elapsed
                if self?.isPaused == false { self?.updateSilence() }
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    private func updateSilence(now: Date = Date()) {
        for track in AudioTrack.allCases {
            if (levels[track] ?? 0) > Self.silenceFloor {
                lastSignalAt[track] = now
            }
            let silentFor = lastSignalAt[track].map { now.timeIntervalSince($0) } ?? .infinity
            if silentFor > Self.silenceGrace {
                silentTracks.insert(track)
            } else {
                silentTracks.remove(track)
            }
        }
    }

    private func observeEvents(of coordinator: RecordingCoordinator) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in coordinator.eventStream {
                guard !Task.isCancelled else { return }
                self?.handle(event)
            }
        }
    }

    private func handle(_ event: RecordingEvent) {
        switch event {
        case let .started(folder):
            lastSessionFolder = folder
        case let .deviceChanged(track, detail):
            notices.append(Notice(text: "\(name(of: track)): \(detail)", isSevere: false))
        case let .lowDiskSpace(available):
            let formatted = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            notices.append(Notice(text: "Queda poco espacio en disco: \(formatted)", isSevere: true))
        case let .writeFailed(track, detail):
            notices.append(Notice(text: "\(name(of: track)): \(detail)", isSevere: true))
        case let .droppedFrames(track, frames):
            notices.append(Notice(
                text: "\(name(of: track)): se perdieron \(frames) muestras, la grabación tiene huecos",
                isSevere: true
            ))
        case .paused, .resumed:
            // The buttons already say which it is; a notice would only be noise.
            break
        case let .stopped(folder):
            lastSessionFolder = folder
        }
    }

    private func name(of track: AudioTrack) -> String {
        switch track {
        case .mic: "Micrófono"
        case .system: "Audio del sistema"
        }
    }
}
