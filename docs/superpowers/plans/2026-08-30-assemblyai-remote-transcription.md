# AssemblyAI Remote Transcription Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transcription and diarization run on AssemblyAI's servers as a selectable engine, so a laptop that records six hours of meetings never melts running models locally.

**Architecture:** A new `TrackTranscribing` refinement of `TranscriptionEngine` transcribes whole track files (one AssemblyAI job per track: mic without speaker labels, system with them). `TranscriptionPipeline` grows a per-track branch that reuses the chunk-transcript store for caching, and the mapper renumbers AssemblyAI speakers into the app's `mic`/`system-N` convention so everything downstream is untouched. `ChainPlanner` skips local diarization when the engine already separated speakers.

**Tech Stack:** Swift 6.2 / macOS 26, Swift Testing (`import Testing`), URLSession with `URLProtocol` stubs, XcodeGen + `scripts/test.sh`.

**Spec:** `docs/superpowers/specs/2026-08-30-assemblyai-remote-transcription-design.md`

## Global Constraints

- All code, comments and commit messages in English; commit messages lowercase imperative, no attribution trailers (user rule).
- UI copy and user-facing error strings in Rioplatense Spanish, matching existing tone.
- `speech_models` pinned to `["universal-2"]`; base URL `https://api.assemblyai.com`; auth header `authorization: <key>` with no Bearer prefix; poll every 3 s.
- AssemblyAI times are milliseconds; the app's are seconds (`TimeInterval`).
- Speaker ids: `SessionManifest.micSpeakerID` (`"mic"`) and `SessionManifest.systemSpeakerID(n)` (`"system-n"`, numbered by first speech).
- On-disk contract is additive only: new manifest field decodes with `decodeIfPresent`; `EngineID` raw value `"assemblyai"` is forever.
- Tests never touch the network; run with `scripts/test.sh` (or `swift test --package-path Packages/TranslixKit`).

---

### Task 1: DTOs and mapper (the pure core)

**Files:**
- Create: `Packages/TranslixKit/Sources/TranslixTranscribe/AssemblyAI/AssemblyAIModels.swift`
- Create: `Packages/TranslixKit/Sources/TranslixTranscribe/AssemblyAI/AssemblyAIMapper.swift`
- Test: `Packages/TranslixKit/Tests/TranslixTranscribeTests/AssemblyAIMapperTests.swift`

**Interfaces:**
- Produces `AssemblyAITranscript: Decodable, Sendable` mirroring the poll response: `id: String`, `status: Status` (`queued|processing|completed|error`), `error: String?`, `languageCode: String?`, `words: [Word]?`, `utterances: [Utterance]?` where `Word = {text: String, start: Int, end: Int, confidence: Double?, speaker: String?}` and `Utterance = {speaker: String, start: Int, end: Int, text: String, confidence: Double?, words: [Word]}` (snake_case decoding via explicit CodingKeys; times in ms).
- Produces `AssemblyAIUpload: Decodable` (`uploadURL: String` from `upload_url`).
- Produces `enum AssemblyAIMapper` with:
  - `static func segments(for transcript: AssemblyAITranscript, track: AudioTrack) -> (segments: [TranscriptSegment], turns: [SpeakerTurn])` — times in seconds on the track's own timeline; system utterances → one segment per utterance with `speakerID: system-N` renumbered by first speech, plus matching turns (confidence from utterance, default 1); mic (or utterance-less system) → gap-split words, `speakerID: "mic"` for mic, `"system-1"` for the fallback, empty turns for mic.
  - `static let segmentGap: TimeInterval = 1.2`, `static let segmentCap: TimeInterval = 30`

- [ ] Write failing tests: system utterances map (ms→s, renumbering A/B→system-1/2 by first speech, words attached, turns produced); mic words gap-split at ≥1.2 s and at 30 s runs, all `mic`, no turns; system without utterances falls back to single `system-1`; empty/nil words produce empty result.
- [ ] Run `swift test --package-path Packages/TranslixKit --filter AssemblyAIMapperTests` — expect compile failure/red.
- [ ] Implement DTOs + mapper.
- [ ] Tests green.
- [ ] Commit: `map assemblyai responses onto the app's transcript shapes`

### Task 2: HTTP client

**Files:**
- Create: `Packages/TranslixKit/Sources/TranslixTranscribe/AssemblyAI/AssemblyAIClient.swift`
- Test: `Packages/TranslixKit/Tests/TranslixTranscribeTests/AssemblyAIClientTests.swift`

**Interfaces:**
- Produces `actor AssemblyAIClient`:
  - `init(apiKey: @escaping @Sendable () -> String?, session: URLSession = .shared, baseURL: URL = AssemblyAIClient.defaultBaseURL, pollInterval: Duration = .seconds(3))`
  - `func transcribe(file: URL, request: AssemblyAIRequest, progress: @escaping @Sendable (AssemblyAIProgress) -> Void) async throws -> AssemblyAITranscript` — upload → create → poll until `completed` (returns) or `error` (throws `TranscriptionError.engineFailed(message)`); `Task.checkCancellation()` between polls.
  - `struct AssemblyAIRequest: Encodable, Sendable` — `speakerLabels: Bool`, `languageCode: String?`, `languageDetection: Bool`; encodes `speech_models: ["universal-2"]`, `audio_url`, snake_case keys.
  - `enum AssemblyAIProgress: Sendable, Equatable { case uploading(Double), waiting }`
  - Missing key throws `TranscriptionError.modelUnavailable("Falta la clave de API de AssemblyAI. Cargala en Ajustes → Transcripción.")`; non-2xx throws `engineFailed` including the server's message; 401/403 message names the key.
- Upload progress: report `.uploading(fraction)` via `URLSessionTaskDelegate` `didSendBodyData` (fraction of `totalBytesExpectedToSend`), then `.waiting` once the job is created; wire through a small `NSObject` delegate class.

- [ ] Write failing tests using a `URLProtocol` stub (same pattern as `AnthropicProviderTests` — read it first and mirror the fixture style): upload sends raw bytes with `authorization` header and no Bearer; create body pins `speech_models` and carries `speaker_labels`/`language_code`/`language_detection`; polls until completed; `status: error` throws with AssemblyAI's message; missing key throws before any request.
- [ ] Red, implement, green.
- [ ] Commit: `add the assemblyai client behind an injectable transport`

### Task 3: Engine, protocol, registry

**Files:**
- Modify: `Packages/TranslixKit/Sources/TranslixTranscribe/TranscriptionEngine.swift` (add `EngineID.assemblyAI`; add `TrackTranscribing` protocol + `TrackTranscription` + `TrackTranscriptionPhase`)
- Create: `Packages/TranslixKit/Sources/TranslixTranscribe/AssemblyAI/AssemblyAIEngine.swift`
- Modify: `Packages/TranslixKit/Sources/TranslixTranscribe/TranscriptionSettings.swift` (registry: id list, construction with key closure, status row)
- Test: `Packages/TranslixKit/Tests/TranslixTranscribeTests/AssemblyAIEngineTests.swift`

**Interfaces:**
- `EngineID.assemblyAI` = `"assemblyai"`.
- `struct TrackTranscription: Sendable { var segments: [TranscriptSegment]; var turns: [SpeakerTurn]; var detectedLanguage: String? }`
- `enum TrackTranscriptionPhase: Sendable, Equatable { case uploading(Double), waiting }`
- `protocol TrackTranscribing: TranscriptionEngine { func transcribe(trackFile: URL, track: AudioTrack, language: TranscriptionLanguage, progress: @escaping @Sendable (TrackTranscriptionPhase) -> Void) async throws -> TrackTranscription }`
- `actor AssemblyAIEngine: TrackTranscribing`:
  - `static let keychainService = "com.leomarzo.tranlix.assemblyai"`
  - `init(apiKey: @escaping @Sendable () -> String?, client: AssemblyAIClient? = nil)` (client built from the key when nil; tests inject)
  - `displayName` `"AssemblyAI (nube)"`; `availability` `.ready` with key else `.unsupported("Falta la clave de API de AssemblyAI. Cargala en Ajustes → Transcripción.")`; `prepare` no-op.
  - Track call: `speaker_labels = (track == .system)`; `.automatic` → `languageDetection: true`, `.fixed(id)` → bare code via the existing `whisperLanguageCode` logic; maps via `AssemblyAIMapper`; `detectedLanguage` only when asked to detect.
  - Chunk conformance routes through the track path and drops turns.
- `TranscriptionEngineRegistry.init(modelsDirectory:assemblyAIKey: @Sendable () -> String? = { nil })`; `availableEngineIDs` = `[.apple, .whisperKit, .assemblyAI]`; status for assemblyai: `installedBytes: nil, canRemove: false`.

- [ ] Failing tests: availability with/without key; track call builds the right `AssemblyAIRequest` per track/language (assert via injected client stub recording requests); chunk conformance returns segments.
- [ ] Red, implement, green. Commit: `add the assemblyai engine and register it`

### Task 4: Model and planner groundwork

**Files:**
- Modify: `Packages/TranslixKit/Sources/TranslixModel/SessionManifest.swift` (`audioSharedAt: Date?`, decodeIfPresent, init param default nil)
- Modify: `Packages/TranslixKit/Sources/TranslixStore/SessionHandle.swift` (`recordAudioShared(at:)` write-once like `recordTranscriptShared`)
- Modify: `Packages/TranslixKit/Sources/TranslixPipeline/ChainPlanner.swift` (`SkipReason.coveredByTranscription`; `plan(..., engineSeparatesSpeakers: Bool = false)`)
- Tests: `Packages/TranslixKit/Tests/TranslixModelTests/SessionManifestTests.swift`, `Packages/TranslixKit/Tests/TranslixPipelineTests/ChainPlannerTests.swift`

**Interfaces:**
- Produces `manifest.audioSharedAt: Date?`, `SessionHandle.recordAudioShared(at: Date) throws` (idempotent), `SkipReason.coveredByTranscription`, planner param `engineSeparatesSpeakers`.
- Planner rule: skip diarization as `.coveredByTranscription` only when `engineSeparatesSpeakers` **and** `.transcription` ended up in `stages`; diarization requested alone still runs locally.

- [ ] Failing tests: manifest decodes without the field; audioSharedAt write-once; planner skips diarization with the flag when transcription runs, and does not when transcription was skipped/not requested.
- [ ] Red, implement, green. Commit: `record audio sharing and let the planner skip covered diarization`

### Task 5: Remote branch in TranscriptionPipeline

**Files:**
- Modify: `Packages/TranslixKit/Sources/TranslixTranscribe/TranscriptionPipeline.swift`
- Modify: `Packages/TranslixKit/Sources/TranslixTranscribe/TranscriptionEngine.swift` only if a helper is needed (avoid)
- Test: `Packages/TranslixKit/Tests/TranslixTranscribeTests/RemoteTranscriptionPipelineTests.swift`
- Modify: `Packages/TranslixKit/Sources/TranslixTestSupport/StubEngine.swift` (add `StubTrackEngine: TrackTranscribing`)

**Interfaces:**
- `TranscriptionPhase` gains `.preparingUpload`, `.uploading(track: AudioTrack, fraction: Double)`, `.waitingRemote`; fractions: preparingUpload 0.05, uploading 0.1 + 0.5·overall, waitingRemote 0.9 held below archiving's 0.95 (uploading overall = (finishedTracks + trackFraction)/trackCount).
- In `transcribe(session:language:progress:)`: `if let remote = engine as? TrackTranscribing { return try await transcribeRemotely(remote, ...) }` before the chunk loop; `process()` untouched (transcribe → archive order preserved).
- `transcribeRemotely` per track with audio: source file (archive if present, else `AudioArchiver.concatenate` into scratch); fingerprint frames+bytes (AVAudioFile length + file size, same as `DiarizationPipeline.fingerprint`); cache via `handle.chunkTranscript(engineID:track:chunkIndex: 0)` and `matches(...)`; miss → `handle.recordAudioShared(at:)` then remote call, persist `ChunkTranscript(chunkIndex: 0, ...)` with track-relative segments; narrow `effective` from `detectedLanguage` before filing (mirror chunk loop); collect system turns.
- After tracks: shift by `manifest.offset(for:)` (segments, words and turns), sort, write transcript; when system turns exist write `Diarization(diarizerID: engine.id.rawValue, audioFingerprint: <system file fingerprint>, turns:)` + `setDiarizationInfo`; manifest update identical to local path.

- [ ] Failing tests with `StubTrackEngine` + `TemporaryDirectory`/`SilentAudio` helpers: remote path writes transcript with offsets and both tracks interleaved; diarization.json + info written with remote turns; per-track cache hit skips the engine call (stub counts calls); detected language narrows the second track's request and lands in the manifest; audioSharedAt set once; cancellation mid-track reverts state.
- [ ] Red, implement, green. Commit: `transcribe whole tracks remotely when the engine can`

### Task 6: SessionPipeline + PipelinePhase wiring

**Files:**
- Modify: `Packages/TranslixKit/Sources/TranslixPipeline/SessionPipeline.swift` (pass `engineSeparatesSpeakers: engine is TrackTranscribing` to the planner)
- Modify: `Packages/TranslixKit/Sources/TranslixPipeline/PipelinePhase.swift` (details + no fraction regressions for new cases)
- Tests: `Packages/TranslixKit/Tests/TranslixPipelineTests/SessionPipelineTests.swift`, `PipelinePhaseTests.swift`

**Interfaces:**
- Details: `.preparingUpload` → "Preparando el audio para subir…"; `.uploading(track, f)` → "Subiendo \(track.spokenName)… NN %"; `.waitingRemote` → "Transcribiendo en el servidor. Podés cerrar la tapa: la app retoma sola."

- [ ] Failing tests: chain with a `StubTrackEngine` runs transcription and skips diarization as covered (and FluidAudio's stub is never called); phase details and monotone fractions for a remote run.
- [ ] Red, implement, green. Commit: `skip local diarization when the engine separated speakers`

### Task 7: App layer and docs

**Files:**
- Modify: `App/AppEnvironment.swift` (registry with `assemblyAIKey: { try? APIKeyStore(service: AssemblyAIEngine.keychainService).read() }`, `import TranslixSummarize`)
- Modify: `App/Views/SettingsView.swift` (AssemblyAI section: SecureField/hint/delete mirroring `NotesSettingsPane`; engine-aware ready note "Transcribe y separa voces en el servidor. No ocupa disco."; caption with cost ~US$ 0.32/h and the privacy line; refresh statuses after key changes)
- Modify: `App/Views/Session/SessionInspector.swift` (case `EngineID.assemblyAI.rawValue: "AssemblyAI"`)
- Modify: `README.md` (recording pipeline description: local engines or AssemblyAI in the cloud; permissions/privacy paragraph)
- Modify: `Packages/TranslixKit/Sources/TranslixSummarize/AnthropicProvider.swift` (stale "the one place anything leaves the machine" comment)

- [ ] Implement; `scripts/build.sh` compiles; manual smoke not required for commit.
- [ ] Commit: `let settings hold an assemblyai key and offer the cloud engine`

### Task 8: Full verification

- [ ] `scripts/test.sh` — entire suite green (fix any exhaustive-switch fallout the compiler finds anywhere, e.g. views switching on phases).
- [ ] `scripts/build.sh` — app builds.
- [ ] Re-read the spec top to bottom; check every design point landed (mapper conventions, planner rule, audioSharedAt, phases, settings copy). Fix gaps in place.
- [ ] Commit anything outstanding: `finish the assemblyai remote transcription path`
