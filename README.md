# Translix

macOS app that records online classes and meetings, transcribes them with speakers
separated, and produces notes through an LLM.

Transcription runs on-device (WhisperKit or Apple's SpeechAnalyzer) or remotely, because
hours of on-device inference can hang a laptop that sleeps mid-run. Two remote engines, for
two different trades:

- **DeepInfra** (~US$0.054 per recorded hour) transcribes with Whisper `large-v3` and leaves
  speakers to the local diarizer, which is free and runs at roughly 100x real time. This is
  the default choice: transcription was the expensive half in both money and heat.
- **AssemblyAI** (~US$0.32 per recorded hour) transcribes *and* separates speakers in one
  call. Worth it when a session mixes Spanish and English inside a sentence, where Whisper
  is weaker.

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
the Anthropic, AssemblyAI and DeepInfra keys and the notarization profile used by
`scripts/release.sh`.

What leaves the machine is explicit and audited: generating notes sends the transcript to
Anthropic (recorded as `transcriptSharedAt`), and choosing a remote transcription engine
uploads the recording itself (recorded as `audioSharedAt`). The local engines send nothing.

## Layout

```
project.yml              XcodeGen spec — the single source of truth for the app target
App/                     SwiftUI shell: views, view models, Info.plist, entitlements
App/AppIcon.icon/        Icon Composer bundle: icon.json plus the SVG layers it composes
Packages/TranslixKit/     all logic, as a local Swift package
  TranslixModel           Codable types; the on-disk contract. A leaf with no dependencies
  TranslixStore           session folders, atomic manifest I/O, library scan, recovery
  TranslixCapture         Core Audio tap + AVAudioEngine mic, chunk writing, coordination
  TranslixTranscribe      TranscriptionEngine protocol; Apple, WhisperKit, DeepInfra, AssemblyAI
  TranslixDiarize         speaker turns and merge into a single timeline
  TranslixSummarize       Anthropic client, prompt templates, Keychain
  TranslixExport          Markdown rendering
scripts/                 build, test, run
```

Modules are added to `Package.swift` as each milestone lands, so the package always
describes something real rather than a scaffold of empty directories.

## Data on disk

No database. One folder per session, `manifest.json` is the source of truth, and the library
index is rebuilt by scanning at launch. Everything is inspectable, backup-friendly, and
survives any failure of the app itself.

```
~/Grabaciones/2026-08-02_1430_Clase-Estadistica/
  manifest.json          metadata, chunks, markers, speaker names, state
  chunks/                transient CAF chunks, removed once the archive is verified
  audio/                 mic.m4a, system.m4a — AAC mono, roughly 15 MB per hour per track
  transcripts/           per-chunk results, keyed by engine, so a failure resumes
  transcript.json        merged timeline with raw speaker ids
  transcript.md
  notas/                 generated summaries
```

## Status

Under construction. Milestones: project skeleton, capture and persistence, transcription,
diarization and merge, summaries and export. Signing, notarization and `.dmg` packaging come
after those.
