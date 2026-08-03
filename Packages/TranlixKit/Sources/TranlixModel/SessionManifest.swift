import Foundation

/// The source of truth for a session.
///
/// Written to `manifest.json` before any audio is captured and updated on every closed
/// chunk, so a session folder found after a crash always explains itself. There is no
/// database: the library is rebuilt by scanning these files at launch, which means the whole
/// thing is inspectable with a text editor and survives any failure of the app.
public struct SessionManifest: Codable, Sendable, Equatable {
    /// Bumped whenever the on-disk shape changes incompatibly.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID

    /// What the user called the session. May be empty, in which case the UI falls back to
    /// the creation date.
    public var title: String

    public var createdAt: Date
    public var state: SessionState

    /// What the user picked before recording.
    public var language: SessionLanguage

    /// The BCP-47 locale actually handed to the engine, recorded once transcription runs.
    ///
    /// Kept separately from `language` because the mapping lives in settings and can change:
    /// this says what really happened, not what would happen today.
    public var resolvedLocaleIdentifier: String?

    /// Capture sample rate for both tracks. 16 kHz is what every speech model wants, so
    /// recording at it avoids a resampling pass later.
    public var sampleRate: Double

    public var tracks: [AudioTrack: TrackInfo]
    public var markers: [Marker]
    public var deviceChanges: [DeviceChangeEvent]

    /// Raw speaker id (`system-1`, `mic`) to the name the user typed.
    ///
    /// Renaming writes here rather than rewriting the transcript, which keeps the operation
    /// instant and non-destructive: `transcript.json` always holds the ids the diarizer
    /// produced, and names are applied when rendering.
    public var speakerNames: [String: String]

    /// Identifier of the engine that produced the current transcript.
    public var transcriptionEngine: String?

    /// What ran over the system track to separate voices, `nil` if nothing has.
    public var diarization: DiarizationInfo?

    /// When the user allowed this session's transcript to be sent to the summariser.
    ///
    /// Everything else in this app runs locally; summarising is the one thing that sends a
    /// recording of a class or a meeting to somebody else's server. The scope accepts that
    /// tradeoff consciously, and recording the moment it was accepted is what keeps it
    /// conscious — the confirmation is asked once per session, and it is auditable afterwards.
    public var transcriptSharedAt: Date?

    public var failure: FailureInfo?

    public init(
        schemaVersion: Int = SessionManifest.currentSchemaVersion,
        id: UUID = UUID(),
        title: String,
        createdAt: Date,
        state: SessionState = .recording,
        language: SessionLanguage,
        resolvedLocaleIdentifier: String? = nil,
        sampleRate: Double = 16000,
        tracks: [AudioTrack: TrackInfo] = [.mic: TrackInfo(), .system: TrackInfo()],
        markers: [Marker] = [],
        deviceChanges: [DeviceChangeEvent] = [],
        speakerNames: [String: String] = [:],
        transcriptionEngine: String? = nil,
        diarization: DiarizationInfo? = nil,
        transcriptSharedAt: Date? = nil,
        failure: FailureInfo? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.state = state
        self.language = language
        self.resolvedLocaleIdentifier = resolvedLocaleIdentifier
        self.sampleRate = sampleRate
        self.tracks = tracks
        self.markers = markers
        self.deviceChanges = deviceChanges
        self.speakerNames = speakerNames
        self.transcriptionEngine = transcriptionEngine
        self.diarization = diarization
        self.transcriptSharedAt = transcriptSharedAt
        self.failure = failure
    }

    // Collections decode to empty rather than throwing when a key is missing. The manifest is
    // meant to be readable and hand-editable, so a file that dropped an empty array should
    // still load.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? SessionManifest.currentSchemaVersion
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        state = try container.decode(SessionState.self, forKey: .state)
        language = try container.decodeIfPresent(SessionLanguage.self, forKey: .language) ?? .auto
        resolvedLocaleIdentifier = try container.decodeIfPresent(
            String.self, forKey: .resolvedLocaleIdentifier
        )
        sampleRate = try container.decodeIfPresent(Double.self, forKey: .sampleRate) ?? 16000
        tracks = try container.decodeIfPresent([AudioTrack: TrackInfo].self, forKey: .tracks) ?? [:]
        markers = try container.decodeIfPresent([Marker].self, forKey: .markers) ?? []
        deviceChanges = try container.decodeIfPresent(
            [DeviceChangeEvent].self, forKey: .deviceChanges
        ) ?? []
        speakerNames = try container.decodeIfPresent(
            [String: String].self, forKey: .speakerNames
        ) ?? [:]
        transcriptionEngine = try container.decodeIfPresent(
            String.self, forKey: .transcriptionEngine
        )
        diarization = try container.decodeIfPresent(DiarizationInfo.self, forKey: .diarization)
        transcriptSharedAt = try container.decodeIfPresent(Date.self, forKey: .transcriptSharedAt)
        failure = try container.decodeIfPresent(FailureInfo.self, forKey: .failure)
    }
}

// MARK: - Timeline

public extension SessionManifest {
    func track(_ track: AudioTrack) -> TrackInfo {
        tracks[track] ?? TrackInfo()
    }

    /// Host time at which the session's timeline begins: whichever track produced audio first.
    var startHostTime: TimeInterval? {
        AudioTrack.allCases.compactMap { tracks[$0]?.firstBufferHostTime }.min()
    }

    /// Seconds to add to a track's own timeline to place it on the session timeline.
    ///
    /// The two captures are started separately and one always wins the race, usually by tens
    /// of milliseconds. Ignoring that would smear the merged transcript by exactly that much.
    func offset(for track: AudioTrack) -> TimeInterval {
        guard let start = startHostTime,
              let trackStart = tracks[track]?.firstBufferHostTime
        else { return 0 }
        return trackStart - start
    }

    /// Session length: the furthest point reached by either track.
    var duration: TimeInterval {
        AudioTrack.allCases.reduce(0) { longest, track in
            guard let info = tracks[track] else { return longest }
            return max(longest, offset(for: track) + info.duration(sampleRate: sampleRate))
        }
    }

    /// Absolute start of a chunk on the session timeline.
    func sessionStart(of chunk: ChunkRef, on track: AudioTrack) -> TimeInterval {
        chunk.start(sampleRate: sampleRate) + offset(for: track)
    }

    /// Whether any audio was actually captured. A session that recorded nothing is not worth
    /// offering for recovery.
    var hasAudio: Bool {
        AudioTrack.allCases.contains { (tracks[$0]?.totalFrames ?? 0) > 0 }
    }
}

// MARK: - Speakers

public extension SessionManifest {
    /// Fixed speaker id for the microphone track. It is always the same person, so it never
    /// goes through diarization.
    static let micSpeakerID = "mic"

    /// Prefix for voices the diarizer found on the system track: `system-1`, `system-2`, …
    ///
    /// Numbered by who speaks first rather than by whatever the model called them internally,
    /// so the ids stay stable and meaningful across diarizer versions.
    static let systemSpeakerPrefix = "system-"

    static func systemSpeakerID(_ number: Int) -> String {
        "\(systemSpeakerPrefix)\(number)"
    }

    /// What to show for a speaker id.
    ///
    /// The name the user typed wins; otherwise a readable default. Falling back to the raw id
    /// would put `system-2` in front of the user and, worse, into the summary prompt.
    func displayName(forSpeaker id: String) -> String {
        if let name = speakerNames[id] { return name }
        return Self.defaultDisplayName(forSpeaker: id)
    }

    /// The label a speaker carries until someone renames it.
    static func defaultDisplayName(forSpeaker id: String) -> String {
        if id == micSpeakerID { return "Yo" }
        if id.hasPrefix(systemSpeakerPrefix) {
            let number = id.dropFirst(systemSpeakerPrefix.count)
            if !number.isEmpty, number.allSatisfy(\.isNumber) {
                return "Persona \(number)"
            }
        }
        return id
    }

    /// Whether this speaker still carries its default label.
    func hasCustomName(forSpeaker id: String) -> Bool {
        speakerNames[id] != nil
    }
}
