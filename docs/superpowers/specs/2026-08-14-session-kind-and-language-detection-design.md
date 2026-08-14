# Automatic session kind and language detection

Tranlix should work out what a recording *is* — a university class, a work meeting, or
something else — and what language it is in, instead of asking the user up front and then
producing notes shaped by whatever happened to be configured.

Two features that share one idea and touch different layers. Language is a prerequisite:
both the classification prompt and the notes prompt depend on knowing it.

## Problem

Three concrete gaps in the code as it stands.

**The notes template never varies.** `PipelineCoordinator.notesRequest()` resolves
`settings.defaultTemplateID` (or the first template) and puts one `instruction` and `title`
into the `NotesRequest`. The two seeded templates — "Resumen de clase" and "Notas de
reunión" — are genuinely different in shape, and nothing ever chooses between them.

**Language detection exists but its result is discarded.** With `SessionLanguage.auto`,
WhisperKit receives `detectLanguage: true` and reports what it found in
`TranscriptionResult.language`. `WhisperKitEngine.transcribe` drops it on the floor with
`results.flatMap(\.segments)`, and `TranscriptionPipeline` then writes
`manifest.resolvedLocaleIdentifier = language.identifier`, which is `nil` for `.automatic`.
The engine works out the language and the app forgets it.

**Nothing reaches that branch anyway.** `RecorderViewModel.language` starts at `.spanish`
and the pre-recording form was removed. Every session is transcribed forcing Spanish, so an
English class is transcribed with `language: "es"` — not merely suboptimal but actively
worse than not specifying. And all three prompts hardcode "en español rioplatense", so an
English meeting yields a Spanish minute regardless.

## Constraints discovered while designing

**`.automatic` must never reach `ChainPlanner`.** `AppleSpeechEngine.availability` returns
`.unsupported` for `.automatic` — Apple's transcriber is built around a chosen locale — and
`ChainPlanner` turns an unsupported transcription engine into a *refusal*, not a skip
(`ChainPlanner.swift:65`). Nothing runs at all, notes included. Making `.auto` the default
without addressing this would leave every Apple-engine user unable to process anything.

**Forcing a language beats detecting per chunk.** `SessionLanguage` documents this
deliberately: a class taught in Spanish that quotes English terminology will flap between
languages if each chunk detects independently. The resolution is to detect *once* and then
force: the first chunk decides, the rest are transcribed with `.fixed(...)`.

**Classification sends the transcript to Anthropic.** It has to sit behind the same
`NotesAllowance` gate as summarising, and it must not send before `transcriptSharedAt` is
recorded — otherwise the auditable record of "when the transcript left this machine" starts
lying.

## Design

### Language

Two detection moments, because they answer different questions.

**At transcription — what language to hand the engine.** `TranscriptionEngine.transcribe`
returns `ChunkTranscription { segments, detectedLanguage: String? }` instead of a bare
`[TranscriptSegment]`. `WhisperKitEngine` fills `detectedLanguage` from
`TranscriptionResult.language`; `AppleSpeechEngine` returns `nil`, which is honest — it
cannot detect. `TranscriptionPipeline` transcribes the first chunk with the requested
language, and if that was `.automatic` and the engine reported something, pins every
subsequent chunk to `.fixed(...)` of what came back. `resolvedLocaleIdentifier` is then
written with what actually ran rather than `nil`.

When the engine cannot detect, `.auto` falls back to the configured default language rather
than refusing, and the UI says which language it settled on.

**After transcription — what language the session actually is.** `NLLanguageRecognizer`
(system `NaturalLanguage` framework: no download, no network, no API key) over the merged
transcript, constrained to `[.spanish, .english]`. This is authoritative because it sees the
whole session, and it corrects a misleading opening — a class that begins "good morning
everyone" and then proceeds in Spanish. The result is stored as
`SessionManifest.detectedLanguage: SessionLanguage?`.

This is deliberately *not* folded into the classifier's model call. Local detection is free,
instant, works offline and without an API key, and on a full transcript with two candidates
it is more reliable than a sampled excerpt sent to a model.

**Notes language policy.** A new setting with three values: follow the session (default),
always Spanish, always English. The instruction is composed in
`SessionPipeline.instruction()` alongside `citationRule`, for the reason already documented
there: composed rules reach custom templates without their authors having to remember them.
The three seeded templates drop their hardcoded "en español rioplatense"; when the policy
resolves to Spanish the composed rule asks for Rioplatense.

### Session kind

`SessionKind` — `lecture` / `meeting` / `general` — recorded in the manifest together with
how it got there:

```swift
public struct SessionKindInfo: Codable, Sendable, Equatable {
    public var kind: SessionKind
    public var source: Source        // .detected | .chosenByUser
    public var confidence: Double?
    public var reason: String?
    public var decidedAt: Date
}
```

`source` is what makes a manual correction stick: detection runs only when `kind` is `nil`,
and a `.chosenByUser` value is never overwritten. The field is additive and decoded with
`decodeIfPresent`, like `diarization` and `transcriptSharedAt`, so existing manifests load
unchanged and `schemaVersion` does not move.

**The classifier.** A `SessionClassifier` protocol in `TranlixSummarize` with one
implementation that reuses `SummaryProvider`: it builds a `SummaryRequest` whose instruction
is the classification prompt and whose transcript is the excerpt plus local signals, then
parses JSON out of the reply. Reusing the provider inherits the HTTP client, keychain
handling and error mapping that already exist and are tested, and lets the tests run against
the existing `StubProvider` with no network.

Always Haiku, regardless of the configured `summaryModel`: this is a three-way choice with
the signals already extracted, and Opus costs thirty times more for the same answer.

The excerpt is sampled, not the whole transcript — roughly 4000 characters from the start,
2000 from the middle, 1000 from the end. The opening is the most diagnostic part of a
recording ("bueno, arranquemos con el tema de hoy" versus "¿están todos?"), and sampling
keeps a two-hour session as cheap as a twenty-minute one.

Local signals travel in the prompt as context: the title the user typed, the duration, and
each speaker's share of speaking time. A lecturer takes 85% of the talking; a meeting spreads
turns. The model decides, but it decides informed.

**`NotesRequest` becomes a plan.** It can no longer carry a single resolved instruction,
because the template is chosen after transcription and the request is built before the chain
starts. It carries one template per kind:

```swift
public struct NotesRequest: Sendable, Equatable {
    public let templates: [SessionKind: NotesTemplate]
    public let model: String
    public let language: NotesLanguage
    public let allowance: NotesAllowance
    public init?(...)   // still fails without an allowance
    public func template(for kind: SessionKind) -> NotesTemplate
}
```

It keeps the property worth protecting: no `Codable`, no public memberwise initialiser, and
holding one is still itself the proof that the rule was applied.

It does *not* carry the already-decided kind, as an earlier draft of this design had it. The
pipeline reads `manifest.kind` directly, which keeps one source of truth for what a session is
rather than two that can disagree. A correction from the notes pane is written to the manifest
before the run starts, so the request never needs to carry it.

`template(for:)` returns a value rather than an optional: the fallback is resolved once at
construction, so the type itself promises there is always something to run and no caller has
to handle its absence.

**The classifier is injected, not defaulted.** `SessionPipeline` takes it alongside the engine,
the diarizer and the provider. Defaulting it to one built from `provider` would have been
convenient and wrong: classification is a second call on the same account, and a test that
could not tell the two apart would stop being able to assert what was sent — which is the
load-bearing assertion of the privacy design.

**Sharing is recorded before classifying.** The "record the send before sending" logic at the
top of `SummaryPipeline.generate` is extracted into its own method. `SessionPipeline`
calls it before classifying; `generate` still calls it too, idempotently. One rule, one
implementation, two call sites.

**Progress.** A new `PipelinePhase.classifying` case — "Viendo de qué se trata la
grabación…" — because a second and a half of silence would be the only unnarrated pause in a
chain that explains everything else. It is not a new `PipelineStage`: it cannot run on its
own, and adding one would leak into `ChainPlanner`, `SessionState` and the manual buttons.

### Settings and UI

`SettingsStore.defaultTemplateID: UUID?` becomes `templateIDs: [SessionKind: UUID]`. On
first load, if the old key exists and the new one does not, all three slots are seeded with
it, so nobody loses a preference silently. `NotesSettingsPane` shows three pickers where it
showed one, plus the notes-language picker. A third seeded template, "Notas generales",
whose prompt asks the model to choose sections that fit what actually happened.

The seeded templates get **fixed** identifiers rather than freshly minted ones, so that a slot
can default to `PromptTemplate.seededID(for:)` and still mean something on the next launch.
Minting them per call, as before, would have unmapped every preference at startup.

`NotesPane` gains a menu beside the note title showing the detected kind. Choosing another
writes `SessionKindInfo(source: .chosenByUser)` and regenerates. The `reason` is the tooltip.

### Failure behaviour

A failed classification must never cost the user their notes. All failures fall back to
`.general` and the note is written; only the summarisation call itself can fail the notes
stage, exactly as today. What differs is whether the fallback is remembered:

- **The call succeeded but the answer was unreadable.** Recorded, with `confidence: 0`, so the
  menu invites a correction. The model was asked and had nothing useful to say; asking again
  would most likely produce the same thing.
- **The call failed** — no network, bad key, rate limit. *Not* recorded. Writing `general` down
  here would turn a network that was unreachable for one second into this session's permanent
  answer, because detection only ever runs on a session with no kind.

A template slot pointing at a deleted template falls back to the template that shipped for
that kind, then to any template at all. `NotesRequest.init?` returns `nil` only when there are
no templates, which is the behaviour today.

A template slot pointing at a deleted template falls back to any template, then to the seeded
one for that kind. `NotesRequest.init?` returns `nil` only when there are no templates at
all, which is the behaviour today.

## Testing

All against `StubProvider` and `StubEngine`; nothing reaches the network.

- Excerpt sampling takes start, middle and end and respects its budget.
- Classification JSON parsing survives fenced replies, prose around the JSON, and malformed
  output; malformed falls back to `.general`.
- A session with no kind is classified and the result persisted; a `.chosenByUser` session is
  never reclassified; a classifier that throws still produces a note.
- `NLLanguageRecognizer` wrapper on short Spanish, short English and mixed text.
- `.automatic` never survives into `ChainPlanner`.
- Apple engine plus `auto` falls back to the default language instead of refusing.
- The composed language rule is correct for all three policies.
- `SettingsStore` migrates an old `defaultTemplateID` into all three slots.
- `NotesRequest` still cannot be constructed without an allowance.

## Out of scope

Session kind in the library sidebar rows. Classification during recording. Languages beyond
Spanish and English. Per-template language overrides.

## Build order

1. Language: engine protocol change, detect-once-then-pin, manifest fields, local detector,
   notes-language policy and composed rule.
2. Kind: model types, classifier, `NotesRequest` reshape, pipeline wiring, settings and UI.
