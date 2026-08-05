# Tranlix

macOS app that records online classes and meetings, transcribes them locally with speakers
separated, and produces notes through an LLM.

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
scripts/test.sh     # run the TranlixKit unit tests
```

`Tranlix.xcodeproj` is generated from `project.yml` and is not committed. Run
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
permissions on the next build.

## Layout

```
project.yml              XcodeGen spec — the single source of truth for the app target
App/                     SwiftUI shell: views, view models, Info.plist, entitlements
App/AppIcon.icon/        Icon Composer bundle: icon.json plus the SVG layers it composes
Packages/TranlixKit/     all logic, as a local Swift package
  TranlixModel           Codable types; the on-disk contract. A leaf with no dependencies
  TranlixStore           session folders, atomic manifest I/O, library scan, recovery
  TranlixCapture         Core Audio tap + AVAudioEngine mic, chunk writing, coordination
  TranlixTranscribe      TranscriptionEngine protocol, Apple and WhisperKit engines
  TranlixDiarize         speaker turns and merge into a single timeline
  TranlixSummarize       Anthropic client, prompt templates, Keychain
  TranlixExport          Markdown rendering
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
