# Remote transcription through AssemblyAI

Translix currently transcribes with WhisperKit and separates voices with FluidAudio, both
on-device. A real user reports that transcription freezes the app, and that closing the lid
mid-processing can hang the whole machine on wake. The cause is structural, not a bug to
patch: hours of Neural Engine work inside a GUI app, holding a power assertion
(`PipelineCoordinator.beginActivity`), across sleep/wake cycles the app does not control.

The decision, already taken: transcription and diarization move to a server. Notes already
run through Anthropic's API, so they are unaffected. The provider is AssemblyAI's async API —
transcription and speaker diarization in one request, Spanish and English with automatic
detection, billed per audio-hour with no infrastructure to run.

## Problem

Concretely, in the code as it stands:

**The heavy work is local by design.** `WhisperKitEngine` runs `large-v3-turbo` on CoreML
(~1.6 GB model, minutes of ANE compilation, then sustained inference), and
`FluidAudioDiarizer` runs pyannote models the same way. A six-hour recording means hours of
sustained ANE/GPU load on the user's laptop.

**The pipeline outlives the recording and fights sleep.** `PipelineCoordinator` holds
`idleSystemSleepDisabled` for the whole chain, which "routinely outlives the recording by
twenty minutes". A closed lid forces sleep anyway; resuming CoreML work across that boundary
is where the reported hangs live.

**Everything else is already shaped for this move.** Audio is archived per track to
compressed m4a; transcripts are cached per engine so engines remain comparable; the summary
stage already talks to a remote API. What is missing is an engine whose compute is not on
this machine.

## Constraints discovered while designing

**The mic/system split must survive.** The data model is built around it: `TranscriptSegment`
carries its `AudioTrack`; the mic speaker is the fixed id `mic` ("Yo") and is never diarized;
system voices are `system-1`, `system-2`, … numbered by first speech. Mixing both tracks into
one mono upload — attractive because AssemblyAI bills per file duration — would make the user
just another clustered voice and leave every segment's `track` a guess. So both tracks are
uploaded, and a six-hour meeting bills roughly twelve track-hours. That is the honest price
of the app's own quality bar; a mono variant is a later cost lever, not the default.

**Whole tracks, not chunks.** The chunk protocol (`transcribe(chunk:language:track:)`) is
wrong for a remote engine: speaker identity comes from clustering an entire recording, and a
model shown five minutes at a time renumbers the same person on every chunk — the reason
`Diarizer.diarize` already takes whole tracks. The remote engine therefore gets a track-level
entry point, one job per track per session.

**Diarization must not run twice.** When AssemblyAI transcribes, speakers arrive with the
transcript. `ChainPlanner` has to know the engine separates speakers so it can skip the
FluidAudio stage — but only when transcription itself runs. A manual "separar voces" on an
existing transcript still uses the local diarizer, which remains useful and installed.

**Audio leaving the machine is a bigger send than the transcript.** The manifest records
`transcriptSharedAt` precisely so the one remote send is auditable. Remote transcription
sends the raw recording, so it gets the same treatment: an `audioSharedAt` date, written
once, the first time a session's audio is uploaded. Choosing the cloud engine and pasting an
API key is the consent; the manifest keeps the receipt. The README's "everything runs
locally" framing is updated in the same change.

**AssemblyAI's API, as verified 2026-08-30.** Upload is `POST /v2/upload` with raw bytes and
`authorization: <key>`, answering `{"upload_url": …}` readable only by their servers. Jobs
are `POST /v2/transcript` — the model parameter is now the *plural* `speech_models` array —
then `GET /v2/transcript/{id}` every ~3 s until `completed`/`error`. Word and utterance
times are in **milliseconds**; speakers are letters `A`, `B`, `C`. Limits that matter here:
2.2 GB per upload, 10 h per job, ~15 MB per archived track-hour — a six-hour class fits
several times over. Turnaround is minutes even for hours of audio. `.m4a` is supported.
Language: `language_code: "es"`/`"en"` fixed, or `language_detection: true`, combinable with
`speaker_labels`. Caveat their docs state: features unsupported for a detected language are
*silently omitted*, so the mapper must not assume `utterances` exists.

**Model choice: `universal-2`, pinned.** The current default routes to `universal-3-5-pro`
($0.21/h); `universal-2` ($0.15/h) is the tier the cost decision was made on, supports
Spanish natively, and pinning `speech_models: ["universal-2"]` makes billing immune to
AssemblyAI's routing changes. Upgrading later is a one-string change in the client.

## Design

### The engine

`EngineID.assemblyAI` (`"assemblyai"`) joins `apple` and `whisperKit`. Three new files in
`TranslixTranscribe/`:

**`AssemblyAIClient`** — the HTTP surface: upload a file, create a transcript job, poll it.
An actor holding the base URL, a `@Sendable () -> String?` key provider, and a `URLSession`,
all injectable so tests run against `URLProtocol` stubs exactly as `AnthropicProviderTests`
does. Polls every 3 s with `Task.checkCancellation()` between polls, so dropping the stream
cancels cleanly. No wall-clock timeout: jobs finish or report `error`, and cancellation is
the user's escape hatch.

**`AssemblyAIMapper`** — pure functions from response DTOs to the app's types, where the
correctness lives and is exhaustively testable:

- System track: `utterances` → one `TranscriptSegment` each (`track: .system`), words
  attached, ms → seconds. AssemblyAI's `A`/`B`/`C` are renumbered by first speech into
  `system-1`, `system-2`, … — the ids the rename UI, the manifest and the prompts already
  speak. The same utterances become `SpeakerTurn`s for `diarization.json`.
- Mic track: no `speaker_labels` (clustering one voice invents people, as the code already
  documents), so no utterances. Segments are cut from `words` at silence gaps ≥ 1.2 s or
  30 s of run, every segment stamped `speakerID: "mic"`.
- If `utterances` comes back absent despite being requested (the silent-omission case), the
  system track falls back to the mic treatment with a single `system-1` speaker.

**`AssemblyAIEngine`** — conforms to `TranscriptionEngine` (availability is `.ready` with a
key, `.unsupported("Falta la clave de API de AssemblyAI…")` without one, which
`ChainPlanner` already turns into a refusal that the UI surfaces; `prepare` is a no-op) and
to a new protocol:

```swift
public protocol TrackTranscribing: TranscriptionEngine {
    func transcribe(
        trackFile: URL, track: AudioTrack, language: TranscriptionLanguage,
        progress: @escaping @Sendable (TrackTranscriptionPhase) -> Void
    ) async throws -> TrackTranscription
}
// TrackTranscription: segments (track timeline, speaker ids set),
// turns (empty for mic), detectedLanguage
```

The chunk requirement is implemented through the same path — a chunk is just a short track
file — so the conformance is honest, but the pipeline never uses it for this engine.

The keychain service is `com.leomarzo.tranlix.assemblyai` (the constant lives on the engine;
the app builds `APIKeyStore(service:)` with it — `APIKeyStore` is already generic and does
not move modules). The key reaches the engine as a closure through
`TranscriptionEngineRegistry.init`, wired in `AppEnvironment`; the registry lists the new id
and reports its status with no bytes and nothing to remove.

### The pipeline

`TranscriptionPipeline.transcribe` grows a branch: when the engine `is TrackTranscribing`,
the per-chunk loop is replaced by a per-track loop. Everything around it — `process`'s
begin/fail/revert bookkeeping, transcribe-then-archive order, the manifest fields written at
the end — stays identical, so the property that chunks are the only copy of the recording
until transcription succeeds still holds.

Per track with audio, in `AudioTrack.allCases` order:

1. Source one continuous file: the archive when it exists, otherwise the chunks concatenated
   into scratch (`AudioArchiver.concatenate`, the same both-cases logic
   `DiarizationPipeline.systemAudio` uses).
2. Fingerprint it (frames + bytes) and look for a cached whole-track result — a
   `ChunkTranscript` at `chunkIndex: 0` under `transcripts/assemblyai/<track>/`, the existing
   store reused as-is. A hit skips the upload entirely: a crash after a track completed costs
   nothing on the retry. (A crash *before* the result lands re-uploads and re-bills that
   track — pennies, and the window is minutes.)
3. Otherwise record `audioSharedAt` if unset, upload, create the job (`speaker_labels` only
   for `.system`; `language_code` from the fixed language's bare code, or
   `language_detection: true` for `.automatic`), poll, map, persist the track result.
4. As with chunks: a detected language narrows `effective` before the result is filed, so
   the second track and any re-run are keyed under the language the session turned out to be.

Then, exactly as today: shift each track's segments by `manifest.offset(for:)`, interleave,
write `transcript.json`, update the manifest. The system track's turns (shifted the same
way) become a `Diarization(diarizerID: "assemblyai")` written through the existing
`writeDiarization`/`setDiarizationInfo`, so the rename sheet, speaker lists and re-runs see
exactly what FluidAudio would have left. `SpeakerMerger` is not involved: segments arrive
with their speakers.

`ChainPlanner.plan` gains `engineSeparatesSpeakers: Bool` (default `false`). When it is true
*and* transcription is in the plan, diarization is skipped with a new
`SkipReason.coveredByTranscription`; requested alone, the local diarizer still runs.
`SessionPipeline` passes `engine is TrackTranscribing`.

### Progress

`TranscriptionPhase` gains three cases so the strip narrates the new shape of the work:

- `.preparingUpload` — "Preparando el audio para subir…" (joining chunks, pre-archive runs)
- `.uploading(track:fraction:)` — "Subiendo el micrófono / el audio del sistema… NN %",
  fractions from the `URLSession` task delegate, best-effort
- `.waitingRemote` — "Transcribiendo en el servidor. Podés cerrar la tapa: la app retoma
  sola." — which is now simply true: the job runs remotely, polling pauses with sleep and
  resumes on wake

Fractions ascend `.preparingUpload` (0.05) → uploading (0.1–0.6) → waiting (0.6–0.9) →
`.archiving` (0.95) → 1, so the bar never moves backwards. `PipelinePhase.detail` and
`fraction` are extended in step; the local path's cases and wording do not change.

### Settings and UI

The Transcripción pane gains an "AssemblyAI" section with the same
SecureField/hint/delete-button key flow `NotesSettingsPane` uses for Anthropic, and a caption
saying what the cloud engine means: audio leaves the machine, roughly US$ 0.32 per recorded
hour at current prices, nothing to download, the machine stays usable. The engine appears in
the existing picker and model list ("AssemblyAI (nube)"); its row shows "Transcribe y separa
voces en el servidor. No ocupa disco." when ready, or the missing-key message. The default
engine stays `whisperKit`: a fresh install with no key must keep working, and switching is
one picker away. `SessionInspector` learns the display name.

### Failure behaviour

- **No key / bad key**: availability refusal before anything runs, or `401` mapped to a
  message naming the key, never a generic failure.
- **Job `error`**: `TranscriptionError.engineFailed` with AssemblyAI's own `error` string.
- **Network drop mid-poll**: the poll loop surfaces the transport error; the retry re-polls
  or re-uploads depending on what was persisted. Audio is never at risk — it is on disk,
  archived by the same run or a previous one.
- **Cancellation**: between uploads and between polls, `revertStage` restores the prior
  state, as today.
- **Detection below AssemblyAI's confidence**: not requested (`language_confidence_threshold`
  left at 0); the session-level `SessionLanguageDetector` pass over the merged transcript
  remains the authority, unchanged.

## Testing

All against `URLProtocol` stubs and fixture JSON; nothing reaches the network.

- Mapper: utterances → segments and turns with ms→s, words attached, `A/B/C` → `system-N` by
  first speech; mic words → gap-split segments all owned by `mic`; missing `utterances` falls
  back to one system speaker; empty tracks produce nothing.
- Client: auth header shape, raw-bytes upload, job body (`speech_models` pinned,
  `speaker_labels` per track, language fields per request), poll-until-completed, `error`
  status surfaces AssemblyAI's message, cancellation between polls.
- Pipeline: remote branch caches per-track results and skips the upload on a hit; detected
  language narrows before the second track; offsets applied; `transcript.json`,
  `diarization.json`, `DiarizationInfo` and manifest fields written; `audioSharedAt` set
  once.
- Planner: `engineSeparatesSpeakers` skips diarization only when transcription runs;
  missing key refuses the chain.
- Phases: new details and monotone fractions.

## Out of scope

A mono-downmix cost mode. Webhooks and background-session uploads (polling on wake is enough
for v1). The EU endpoint. Streaming transcription. Flipping the default engine. Retiring the
local engines — they remain the offline path and the comparison baseline.

## Build order

1. Mapper and DTOs with fixtures — the pure core.
2. Client against stubbed transport.
3. Engine, registry and key wiring.
4. Pipeline branch: sourcing, caching, ordering, manifest and diarization writes;
   planner flag; phases.
5. Settings UI, inspector name, README and stale-comment updates.
