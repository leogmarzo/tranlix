import Foundation
import Observation
import SwiftUI
import TranslixCapture
import TranslixModel
import TranslixStore

/// Drives the Record screen.
///
/// Bridges the capture actor to SwiftUI: polls levels and elapsed time on a timer while
/// recording, and turns the coordinator's event stream into things worth showing on screen.
@MainActor
@Observable
final class RecorderViewModel {
    /// Editable while the session runs, not only before it starts.
    ///
    /// Saved to the manifest a beat after typing stops, like the notes. Before this it was
    /// read once, when Grabar was pressed, so a name typed during the class was silently
    /// thrown away — which is the wrong half of "the name can wait".
    var title = "" {
        didSet {
            guard title != oldValue else { return }
            scheduleTitleSave()
        }
    }

    /// Worked out from the audio rather than asked for.
    ///
    /// The pre-recording form is gone, so this was quietly forcing Spanish on every recording
    /// — which does not merely mislabel an English class, it transcribes it with the wrong
    /// model. Whisper detects the language on the first chunk and the rest of the session is
    /// pinned to what it found, so a class taught in Spanish that quotes English terminology
    /// still does not flap. On the engine that cannot detect, settings falls back to a fixed
    /// language rather than refusing the recording.
    var language: SessionLanguage = .auto

    /// Whether the name was edited after capture started, so the folder still has to catch up.
    ///
    /// The folder is named when the session is created and capture holds it open from then on,
    /// so a name typed mid-class cannot move it. The library does that once the run is over.
    private(set) var titleChangedWhileRecording = false

    private(set) var isRecording = false

    /// Capture is suspended. The session has not ended: `isRecording` stays true.
    private(set) var isPaused = false

    private(set) var isBusy = false

    /// Whole seconds, not the raw interval: everything that shows it shows `HH:MM:SS`, and
    /// two readers redrawing twelve times a second for a digit that has not changed is pure
    /// waste. See `startPolling`.
    private(set) var elapsedSeconds = 0

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

    /// Notes typed while the session runs. Merged into the summary prompt afterwards.
    var notes = "" {
        didSet {
            guard notes != oldValue else { return }
            scheduleNotesSave()
        }
    }

    /// Markers dropped so far, newest last, so the side panel can show what was flagged.
    private(set) var markers: [(offset: TimeInterval, label: String)] = []

    private let environment: AppEnvironment
    private var pollTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?

    /// The running session, kept so notes and markers can be written to it as they are typed.
    private var handle: SessionHandle?
    private var notesSaveTask: Task<Void, Never>?
    private var titleSaveTask: Task<Void, Never>?

    /// Called after a session finishes, with the session that finished.
    ///
    /// It carries the handle because the only useful thing to do with a finished recording is
    /// process it, and that needs to know *which* one. Taking no argument meant the app's only
    /// possible response was to rescan the folder.
    var onSessionFinished: ((SessionHandle) -> Void)?

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
        markers.removeAll()
        titleChangedWhileRecording = false
        notes = ""
        elapsedSeconds = 0
        levels = [:]
        silentTracks = []
        let now = Date()
        lastSignalAt = Dictionary(uniqueKeysWithValues: AudioTrack.allCases.map { ($0, now) })

        // Ask before starting so a denial is an explanation rather than a silent empty track.
        guard await MicrophoneSource.requestPermission() else {
            errorMessage = CaptureError.microphonePermissionDenied.localizedDescription
            return
        }

        // Starts the model loading now, so the wait happens during the class rather than
        // after it.
        environment.pipeline?.warmUp(for: language)

        let coordinator = environment.coordinator
        observeEvents(of: coordinator)

        do {
            handle = try await coordinator.start(title: title, language: language, now: Date())
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

        // Flushed rather than left to the debounce: the last thing typed is often the most
        // important, and the chain reads both of these moments from now.
        titleSaveTask?.cancel()
        notesSaveTask?.cancel()
        if let handle {
            try? await handle.setTitle(title)
            if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try? await handle.writeUserNotes(notes)
            }
        }

        var finished: SessionHandle?
        do {
            finished = try await environment.coordinator.stop(now: Date())
        } catch {
            errorMessage = error.localizedDescription
        }

        isRecording = false
        isPaused = false
        levels = [:]
        silentTracks = []
        eventTask?.cancel()
        eventTask = nil
        handle = nil
        title = ""
        if let finished { onSessionFinished?(finished) }
    }

    /// Drops a marker, with a title when there is one.
    ///
    /// `Marker.label` has been in the model since the beginning and was always written nil, so
    /// a marker was a bookmark with nothing on it — findable only by listening around it.
    func addMarker(label: String = "") async {
        guard isCapturing else { return }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let offset = TimeInterval(elapsedSeconds)
        do {
            try await environment.coordinator.addMarker(
                label: trimmed.isEmpty ? nil : trimmed, now: Date()
            )
            markerCount += 1
            markers.append((offset: offset, label: trimmed.isEmpty ? "Marcador" : trimmed))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Saves a beat after typing stops, rather than on every keystroke.
    private func scheduleTitleSave() {
        guard handle != nil else { return }
        titleChangedWhileRecording = true
        titleSaveTask?.cancel()
        let text = title
        titleSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let handle = self?.handle else { return }
            try? await handle.setTitle(text)
        }
    }

    /// Saves a beat after typing stops, rather than on every keystroke.
    private func scheduleNotesSave() {
        notesSaveTask?.cancel()
        let text = notes
        notesSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let handle = self?.handle else { return }
            try? await handle.writeUserNotes(text)
        }
    }

    // MARK: - Live state

    private func startPolling(_ coordinator: RecordingCoordinator) {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let levels = await coordinator.levels
                let seconds = Int(await coordinator.elapsed())
                guard !Task.isCancelled else { return }
                self?.levels = levels
                // Observation notifies on every write, equal value or not, so the guard is
                // what actually keeps the redraw down to once a second. The levels below it
                // do need the full 80 ms rate — the meters would stutter otherwise.
                if self?.elapsedSeconds != seconds { self?.elapsedSeconds = seconds }
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
        case let .captureLost(track, detail):
            // Severe, unlike the first stall: at this point the track has missed several
            // attempts, and whatever is being recorded is going to be missing it.
            notices.append(Notice(text: "\(name(of: track)): \(detail)", isSevere: true))
        case let .captureRestored(track):
            notices.append(Notice(
                text: "\(name(of: track)): volvió a entregar audio",
                isSevere: false
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
