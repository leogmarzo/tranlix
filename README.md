# Translix

macOS app that records online classes and meetings, transcribes them with speakers
separated, and produces notes through an LLM.

Transcription runs remotely on **DeepInfra** (~US$0.054 per recorded hour), with Whisper
`large-v3`. Speakers are separated afterwards by the local diarizer (pyannote on CoreML via
FluidAudio), which is free and runs at roughly 100x real time. Transcription was the
expensive half in both money and heat, and hours of on-device inference could hang a laptop
that slept mid-run. Long sessions are uploaded in five-minute batches, each stored the moment
it lands, so a failed request costs one batch rather than the session.

Earlier versions also offered on-device engines (WhisperKit, Apple's SpeechAnalyzer) and
AssemblyAI. They were removed; sessions they transcribed still open, and "Volver a
transcribir" re-runs them through DeepInfra and the local diarizer.

**Governing principle: audio is the source of truth.** The transcript and the summary are
always derivable and re-runnable, so no recording is ever lost because a later stage failed.

## Requirements

- macOS 26 or later, Apple Silicon
- Xcode 26
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Getting started

```bash
scripts/run.sh      # generate the project, build, and launch
scripts/build.sh    # generate and build only
scripts/test.sh     # run the TranslixKit unit tests
```

`Translix.xcodeproj` is generated from `project.yml` and is not committed. Run
`xcodegen generate` after changing the project layout, or just use the scripts above.

### First build

The first build blocks on a keychain dialog asking whether `codesign` may use the signing
key. Answer **Always Allow** — plain "Allow" makes every later build stall on the same
prompt. To grant it up front instead:

```bash
security set-key-partition-list -S apple-tool:,apple: -s ~/Library/Keychains/login.keychain-db
```

## Permissions

The app asks for **Microphone** and **Audio Recording**. It does *not* ask for Screen
Recording: system audio is captured with a Core Audio process tap rather than
ScreenCaptureKit, which is what Apple recommends when only audio is needed.

The bundle id `com.leomarzo.tranlix` and the signing identity are deliberately fixed. TCC
keys permission grants to that pair, so changing either makes macOS revoke the granted
permissions on the next build. That is also why the bundle id still spells the app's former
name: it survived the rename to Translix untouched, along with the keychain services holding
the Anthropic and DeepInfra keys and the notarization profile used by `scripts/release.sh`.

What leaves the machine is explicit and audited: generating notes sends the transcript to
Anthropic (recorded as `transcriptSharedAt`), and transcribing uploads the recording itself
to DeepInfra (recorded as `audioSharedAt`). Every transcribed session sends its audio;
speaker separation and voice recognition stay on the machine.

## Layout

```
project.yml              XcodeGen spec — the single source of truth for the app target
App/                     SwiftUI shell: views, view models, Info.plist, entitlements
App/AppIcon.icon/        Icon Composer bundle: icon.json plus the SVG layers it composes
Packages/TranslixKit/     all logic, as a local Swift package
  TranslixModel           Codable types; the on-disk contract. A leaf with no dependencies
  TranslixStore           session folders, atomic manifest I/O, library scan, recovery
  TranslixCapture         Core Audio tap + AVAudioEngine mic, chunk writing, coordination
  TranslixTranscribe      DeepInfra engine, batched upload with retries, hallucination filter
  TranslixDiarize         speaker turns and merge into a single timeline
  TranslixSummarize       Anthropic client, prompt templates, Keychain
  TranslixExport          Markdown rendering
scripts/                 build, test, run
```

Modules are added to `Package.swift` as each milestone lands, so the package always
describes something real rather than a scaffold of empty directories.

## Data on disk

### Remembering people across meetings

In a meeting's speaker inspector, enter a name and select **Remember for future meetings**.
Translix stores a local voice profile and compares it with speakers in later recordings,
before generating notes. Strong, unambiguous matches receive the saved name automatically;
uncertain matches appear as suggestions to confirm or dismiss. Manual names and corrections
take priority. Automatic matches never train new profiles on their own.

Use **Settings → People** to rename or delete saved profiles. These changes affect future
recognition; existing meeting names remain intact. Profiles live in `voice-profiles.json`
at the recordings-library root. Moving to another library selects its own profile registry.
The microphone's self-speaker is excluded from enrollment.

When generating notes, Translix can fill an unnamed participant's label from an explicit
self-introduction in their transcript. This uses the same notes request, preserves manual
names and saved-person recognition, and marks the result **Inferred from notes** in the
speaker inspector. Uncertain names remain blank. Edit the inferred name if needed; choosing
**Remember for future meetings** is still required to create a reusable voice profile.
Regenerating notes enables this for existing recordings with separated speakers. Reprocessing
the transcript clears outdated inferred names.

The toolbar bell lists saved profiles with matching names. Select a notification to open
**Settings → People** with the affected rows highlighted, then add a surname or another
distinguishing detail. New profiles include their source recording for reference; older
profiles show a short identifier. The badge counts unresolved name groups and disappears as
conflicts are resolved. Matching names never cause profiles to be merged or voices to be
associated automatically.

At least six seconds of usable speech are required. Older recordings, including those whose
speakers came from AssemblyAI, may require a local analysis pass from retained audio. The transcript's speaker labels remain
unchanged. If analysis fails, the transcript and notes remain available and recognition can
be retried from the inspector.

Recognition uses conservative cosine-similarity thresholds, not calibrated probabilities.
Audio quality and changes in microphone or voice can affect results. Validate assignments
before relying on them; real-meeting accuracy requires representative labeled recordings.

### Session files

No database. One folder per session, `manifest.json` is the source of truth, and the library
index is rebuilt by scanning at launch. Everything is inspectable, backup-friendly, and
survives any failure of the app itself.

```
~/Grabaciones/2026-08-02_1430_Clase-Estadistica/
  manifest.json          metadata, chunks, markers, speaker names, state
  chunks/                transient CAF chunks, removed once the archive is verified
  audio/                 mic.m4a, system.m4a — AAC mono, roughly 15 MB per hour per track
  transcripts/           per-batch results, keyed by engine, so a failure resumes
  transcript.json        merged timeline with raw speaker ids
  transcript.md
  notas/                 generated summaries
```

## Status

Under construction. Milestones: project skeleton, capture and persistence, transcription,
diarization and merge, summaries and export. Signing, notarization and `.dmg` packaging come
after those.
