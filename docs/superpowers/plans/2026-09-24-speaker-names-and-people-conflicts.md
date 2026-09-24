# Speaker Names from Notes and People Name Conflicts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans for native execution, or superpowers:subagent-driven-development if the user selects delegation. Steps use checkbox syntax for tracking. Approved by the user and implemented on 2026-09-24; see execution results below.

**Goal:** Fill unnamed recording participants from names identified during notes generation, and help users distinguish saved people who share a display name.

**Architecture:** Return optional speaker-name metadata in the existing notes request, associate it with stable recording speaker IDs, and apply validated names without overriding user decisions or saved-person recognition. Derive name conflicts from the current People registry and expose them through an in-app bell linked to the People settings tab.

**Tech Stack:** Existing Swift 6 package modules, SwiftUI macOS app, Observation, actor-backed JSON stores, Swift Testing, and the current SummaryProvider abstraction. No new service or dependency.

**Spec:** The proposed design below extends [Persistent Speaker Recognition](../specs/2026-09-24-speaker-recognition-design.md). The implementation already exists as uncommitted working-tree changes; those files are the baseline for this plan.

## Proposed design

### 1. Default participant names

- During the existing notes-generation request, ask for a machine-readable mapping from recording speaker ID to name, alongside the normal Markdown notes and optional automatic session title.
- Include stable speaker IDs in the model-facing transcript. A visible label such as “Speaker 2” or “Alex” is not an identity key.
- Only infer names for separated system-audio speakers with no manual name, confirmed identity, recognized saved person, or pending saved-person suggestion. Keep the microphone's existing self-speaker behavior.
- Require explicit, unambiguous evidence tying the name to that speaker. Merely mentioning an absent person, listing an attendee, or assigning an action item is insufficient. When uncertain, leave the default speaker label.
- Apply the name automatically after the notes file has been saved successfully. Mark its provenance as inferred from notes; show an editable name with an “Inferred from notes” explanation in the speaker inspector.
- Precedence: manual/confirmed decisions, then saved-person voice recognition, then inferred names, then generic speaker labels. A pending voice suggestion remains available for confirmation and is not overwritten by notes.
- Saving a name in a recording does not create a persistent Person. The existing “Remember for future meetings” action remains explicit and uses the inferred name as its initial value.
- A matching name in People is never sufficient to associate a new voice with an existing profile. Two voices can both be named Alex without sharing a person ID.
- Repeated notes generation preserves an existing inferred name for the same transcript. A user correction or explicit clearing of a name always wins. Inferred names are invalidated when transcription or speaker separation changes their underlying speaker mapping.
- Existing notes are not scanned automatically on startup. Existing recordings gain this behavior when the user regenerates notes; recordings without separate speaker IDs retain generic labels.

### 2. Duplicate saved-person names

- Group saved profiles by normalized display name: trim and collapse whitespace, normalize Unicode canonically, and compare case-insensitively with a fixed locale. Preserve accents and punctuation; do not introduce fuzzy matching.
- A group with two or more distinct profile UUIDs is a naming conflict. This identifies separate saved records, not proof that they represent different human beings. Present it as a request to review and distinguish the names.
- Do not merge, delete, or automatically rename profiles. Suggest adding a surname or another distinguishing detail chosen by the user; do not invent one.
- Put a bell in the main window toolbar. Its badge counts unresolved name groups, not people or historical notifications. For example, two profiles named Alex and three named Sam produce a badge of 2.
- Clicking the bell opens a popover listing the conflicting names and counts. Clicking an item opens Settings → People, scrolls to that group, highlights all affected rows, and focuses the first editable name.
- Keep a conflict listed while it remains unresolved, even after it has been opened. Recompute immediately after enrollment, rename, and deletion; also refresh on launch, window activation, and recordings-library changes.
- In People, show an explanatory banner and a warning on every affected row. Keep all people visible; highlight the selected conflict rather than hiding unrelated profiles.
- To help distinguish identical names, save an optional origin reference for future enrollments: recording UUID and speaker ID. Display the recording title/date from the library and allow opening it for review. Existing profiles remain usable and show a short profile identifier if no origin is available; never guess their origin from the name.
- If a conflict is resolved before its notification is clicked, open People normally and show its current state. Do not focus a stale or unrelated row.
- Renaming a saved Person retains the existing behavior: it affects future recognition and leaves previously saved recording labels and notes unchanged.

### 3. Approach and alternatives

**Recommended:** Extract structured identity evidence during the existing notes request and derive notifications from the People registry. This preserves speaker context, avoids another model request, and prevents stale notification records.

**Parse the finished Markdown:** Less provider-facing work, but arbitrary templates and names of nonparticipants make speaker attribution unreliable. Not recommended.

**Run a second identification request:** Allows independent retries, but adds latency, cost, and another workflow. Defer unless the combined response proves inadequate in validation.

## Global constraints

- The planning turn produced this plan only; the user subsequently approved implementation. Preserve all existing source changes and untracked files; do not commit or stage unrelated work.
- All new code, comments, documentation, UI copy, and commit messages must be in English.
- Preserve the current transcript-sharing authorization flow; the feature uses the existing request and introduces no additional network call.
- Never train, enroll, merge, or associate persistent voice identities from a text-inferred name alone.
- Preserve existing recordings, voice registries, manual decisions, automatic session titles, notes templates, exports, and recognition behavior.
- Keep inferred identity metadata out of saved Markdown and exported notes.
- A metadata parse or name-save failure must not discard otherwise successful notes. Surface name-save failures as a nonblocking warning.
- Notifications are local in-app UI; no operating-system notification permission or background notification service is needed.

## Review focus

1. A transcript can mention people who never speak; only evidence attributable to the target speaker can support a default name (Tasks 1–2).
2. Two different speakers can share a visible name; transcript grouping and attribution must retain distinct speaker IDs (Task 1).
3. A user can edit a name, clear it, or confirm a profile while the model responds; fresh stored state must win over the response snapshot (Task 2).
4. Reprocessing can reuse a speaker ID for a different voice; stale inferred names must not follow the reused label (Task 2).
5. A library switch or concurrent profile edit can finish while a conflict refresh is pending; stale results must not appear in the new library or reopen resolved conflicts (Tasks 3–4).

## Task 1: Preserve speaker identity and extract optional notes metadata

**Files**

- Modify `Packages/TranslixKit/Sources/TranslixExport/TranscriptRenderer.swift`.
- Modify `Packages/TranslixKit/Sources/TranslixModel/VoiceProfile.swift` for the shared candidate type.
- Create `Packages/TranslixKit/Sources/TranslixSummarize/SummaryMetadata.swift`.
- Modify `Packages/TranslixKit/Sources/TranslixSummarize/SummaryPipeline.swift` and `Packages/TranslixKit/Sources/TranslixPipeline/SessionPipeline.swift`.
- Extend `Packages/TranslixKit/Tests/TranslixExportTests/TranscriptRendererTests.swift` and `Packages/TranslixKit/Tests/TranslixSummarizeTests/AutomaticTitleTests.swift`.
- Create `Packages/TranslixKit/Tests/TranslixSummarizeTests/SummaryMetadataTests.swift`.

**Contract**

- Add `includeSpeakerIDs: Bool = false` to renderer options; enable it for `.prompt` only. Group consecutive speech by speaker identity, not display name, including in normal exports. Preserve the existing public Block shape if possible by retaining a private grouping key.
- Introduce `SpeakerNameCandidate(speakerID: String, name: String, evidence: String)` in TranslixModel for use by both summary and store code.
- Introduce a summary response parser returning an optional title, `[SpeakerNameCandidate]`, and the Markdown body. Keep `SummaryProvider.summarize` returning String so existing providers and stubs remain compatible.
- Use a bounded metadata header before the Markdown, with a fixed body delimiter. Parse JSON only inside that header. Accept plain Markdown and the current `<session-title>` response format for compatibility.
- The response contract should have this shape when name extraction is enabled:

```text
<translix-metadata>{"sessionTitle":null,"speakerNames":[{"speakerID":"system-1","name":"Alex Rivera","evidence":"I'm Alex Rivera."}]}</translix-metadata>
<!-- translix-notes -->
## Decisions
The team will publish the draft tomorrow.
```

- Ask for a title only when the session needs one. Ask for names independently of whether the title already exists. An empty speakerNames array is valid.
- Metadata absence, invalid JSON, duplicate conflicting entries for one speaker, unknown IDs, or invalid names must leave valid Markdown usable. Strip recognized metadata independently of whether its values are valid. Do not scan or remove arbitrary tags embedded in the body.

**Steps**

- [ ] Write renderer tests with two consecutive segments from `system-1` and `system-2`, both labeled Alex: expect separate blocks and different IDs in prompt output; expect no metadata IDs in normal exports.
- [ ] Write parser tests using the contract above, plain Markdown, the legacy title tag, malformed/unterminated metadata with a valid body delimiter, omitted names, duplicate IDs, and a metadata-only response. Valid note bodies survive; metadata-only responses still raise `SummaryError.emptyResponse`.
- [ ] Run the relevant tests to establish failing behavior; implement the renderer option, parser, and prompt composition.
- [ ] Verify that existing title tests still pass and an already-titled recording can request names in one provider call.

## Task 2: Apply default names without overriding stronger identity evidence

**Files**

- Modify `Packages/TranslixKit/Sources/TranslixModel/VoiceProfile.swift` for provenance fields.
- Modify `Packages/TranslixKit/Sources/TranslixStore/SessionHandle.swift`.
- Modify `Packages/TranslixKit/Sources/TranslixSummarize/SummaryPipeline.swift` and `Packages/TranslixKit/Sources/TranslixPipeline/SessionPipeline.swift`.
- Modify `Packages/TranslixKit/Sources/TranslixPipeline/PipelinePhase.swift` and `App/ViewModels/PipelineCoordinator.swift` to carry nonblocking name-save warnings through the running pipeline to the session UI.
- Modify `Packages/TranslixKit/Sources/TranslixTranscribe/TranscriptionPipeline.swift` and `Packages/TranslixKit/Sources/TranslixDiarize/DiarizationPipeline.swift` at successful transcript replacement points.
- Modify `App/Views/Session/SessionInspector.swift` and `App/ViewModels/SessionViewModel.swift`.
- Create `Packages/TranslixKit/Tests/TranslixStoreTests/InferredSpeakerNameTests.swift` and `Packages/TranslixKit/Tests/TranslixSummarizeTests/SpeakerNamingTests.swift`; extend `Packages/TranslixKit/Tests/TranslixPipelineTests/VoicePipelineTests.swift`.

**Contract**

- Add `.inferredFromNotes` to `SpeakerIdentity.Source`; inferred identities have no personID or voice similarity score. Add optional evidence and transcript-revision fields with backward-compatible defaults.
- Extend `SummaryPipeline.generate` with optional typed speaker context, defaulting to nil for existing callers. The context holds the source transcript and eligible speaker IDs, generated from the current manifest.
- Add `SessionHandle.applyInferredSpeakerNames(_:expectedTranscript:) throws -> Int`, consuming candidates and the source Transcript snapshot. Reload the transcript and manifest before applying; reject a changed transcript snapshot and check name precedence within the manifest update.
- Validate each name as a nonempty trimmed value of at most 120 characters without control characters or markup. Reject generic speaker labels. Require the quoted evidence to occur in that speaker's source text after whitespace normalization. This validates attribution and source presence; it does not prove the model's semantic inference, which remains editable and labeled as inferred.
- Save successful notes first, then names. A note-save failure leaves names untouched. Cancellation before applying names leaves names untouched. Return a typed optional warning through GeneratedNote/PipelinePhase if name persistence fails; do not mark the completed notes as failed.
- When recognition later supplies a strong saved-person match, it may replace an inferred name. When it supplies a pending suggestion, remove the applied inferred name and show the suggestion. Ensure no orphaned display name remains when identity provenance changes.
- On a successful replacement of the transcript/speaker mapping, invalidate only note-inferred identities and their matching labels. Do not erase user-authored labels as part of this feature.

**Steps**

- [ ] Test a previously unnamed speaker introducing themselves: after successful notes generation, their name is persisted, shown after reopening, and no VoiceProfile is created.
- [ ] Test manual, confirmed, automatic, pending-suggestion, legacy named, manually cleared, microphone, and undiarized cases: none receive a note-inferred overwrite.
- [ ] Test evidence belonging to another speaker, a name merely mentioned in the notes, missing evidence, nonexistent IDs, and conflicting metadata: no automatic assignment.
- [ ] Test a provider stub that renames or confirms the speaker through another SessionHandle during the request: the user action wins. Also test cancellation, failed note writes, and failed name writes.
- [ ] Test repeated generation on the same transcript, successful re-diarization/transcription, and a later strong or suggested voice match. Confirm correct precedence and stale-name removal.
- [ ] Implement the model/store behavior, connect it after note persistence, and display provenance/warnings in the inspector. Rerun the targeted tests.

## Task 3: Detect naming conflicts and retain useful profile context

**Files**

- Create `Packages/TranslixKit/Sources/TranslixModel/PeopleNameConflict.swift`.
- Modify `Packages/TranslixKit/Sources/TranslixModel/VoiceProfile.swift`, `Packages/TranslixKit/Sources/TranslixStore/VoiceProfileStore.swift`, and `Packages/TranslixKit/Sources/TranslixDiarize/VoiceRecognitionService.swift`.
- Create `Packages/TranslixKit/Tests/TranslixModelTests/PeopleNameConflictTests.swift` and `Packages/TranslixKit/Tests/TranslixStoreTests/VoiceProfileConflictTests.swift`.

**Contract**

- `PeopleNameConflict` contains a normalized group key, a representative display name, and deterministically ordered profile UUIDs.
- `PeopleNameConflict.detect(in: [VoiceProfile]) -> [PeopleNameConflict]` is a pure function. Empty names do not produce a group; UUIDs are deduplicated before counting.
- Extend profiles with an optional `origin` containing `sessionID: UUID` and `speakerID: String`; add an optional default-nil origin argument to store enrollment. Populate it only on explicit enrollment from a recording. Existing registry version 1 files must still load without a migration or rewrite.
- Keep conflicts derived from live registry data, not separately persisted notifications. Preserve the existing process-wide lock and atomic registry writes.

**Steps**

- [ ] Test names `Alex`, ` alex `, and `ALEX` forming one group; distinct surnames forming none; repeated internal whitespace collapsing; canonical Unicode equivalents matching; accents remaining distinct.
- [ ] Test three profiles sharing a name, repeated UUIDs, deterministic ordering, and two independent conflict groups.
- [ ] Test enrollment, rename into a conflict, rename out of it, deletion, restart, concurrent store instances, and unchanged profile IDs/descriptors.
- [ ] Test legacy profile decoding without origin and new enrollment persisting its source recording. Corrupt registries must return an error rather than pretending there are no conflicts.
- [ ] Implement the detector and optional origin support; run the focused model/store tests and existing recognition tests.

## Task 4: Connect the bell to highlighted People settings

**Files**

- Create `App/ViewModels/PeopleViewModel.swift` and `App/Views/PeopleNotificationsButton.swift`.
- Modify `App/AppEnvironment.swift`, `App/AppNavigation.swift`, `App/Views/RootView.swift`, `App/Views/SettingsView.swift`, and `App/Views/VoiceProfilesSettingsPane.swift`.
- Modify `App/ViewModels/SessionViewModel.swift` to refresh shared People state after enrollment.

**Contract**

- AppEnvironment owns one observable PeopleViewModel with `people`, derived `conflicts`, and a load error. Use it for the bell and People settings so they cannot disagree about counts.
- Provide `refresh()`, `rename(_:to:)`, and `delete(_:)` actions. Successful mutations refresh immediately. Library switching replaces its store, clears prior library state, and ignores late results using a request generation/library-root check.
- Add an explicit settings-tab selection and optional conflict-focus request to AppNavigation. Bind SettingsView's TabView selection and tag all tabs. Set the People tab and focus request before invoking the existing SwiftUI settings-opening action.
- Render conflict popover items from current data. Highlight/focus by profile UUID, not name or row index; revalidate the request after the settings view loads. Consume navigation focus independently of unresolved conflict state.
- Show origin title/date and an open-recording action where resolvable. Fall back to the short UUID for old/deleted/moved-out-of-library source recordings.
- Display profile-read errors explicitly instead of showing an all-clear state. Add accessible bell labels describing the number of unresolved groups, keyboard-operable popover items, and a visible focus indicator.

**Steps**

- [ ] Implement shared People state and route existing People settings mutations through it. Keep the existing enrollment service and add its refresh callback.
- [ ] Add the bell, popover, tab selection, conflict banners, row highlights, and recording-origin context. Add no OS notifications.
- [ ] Build the app. Manually validate a closed Settings window, an already-open non-People tab, repeated notification clicks, multiple groups, and a resolved/stale item.
- [ ] Validate rename/delete/enrollment without reopening windows, library switching during refresh, missing origin recordings, and registry-read errors.
- [ ] Validate keyboard navigation, focus/scroll behavior, and that resolving the final duplicate removes the badge immediately.

## Task 5: End-to-end verification and documentation

- [ ] Add a deterministic package integration fixture containing an unknown speaker with an explicit name, a recognized person, and a third party mentioned in conversation. Verify only the unknown speaker receives an inferred name, using one summary request.
- [ ] Verify two saved profiles with the same name remain distinct through recognition, notification, and renaming. Check that recording names and old notes remain unchanged by profile rename.
- [ ] Update `README.md` to describe name inference, its provenance, explicit remembering, and conflict notifications.
- [ ] Run the full unit suite with `./scripts/test.sh`.
- [ ] Regenerate the project for new App files with `xcodegen generate`, then build with `xcodebuild -project Translix.xcodeproj -scheme Translix -configuration Debug -destination 'platform=macOS' build`. Inspect generated-project changes and retain only those required by this feature.
- [ ] Run one manual end-to-end session using a synthetic or user-approved recording with self-introductions. Check transcript labels, inspector, persisted names after reopening, explicit enrollment, duplicate badge, and navigation to the affected rows. Report separately whether real model behavior was exercised; stub tests cannot establish inference accuracy.
- [ ] Review the diff against the initial dirty-worktree baseline. Do not include unrelated changes in future commits; commit messages must be imperative and omit attribution trailers.

## Execution results

Implemented on `codex/speaker-names-and-people-conflicts`, preserving the pre-existing uncommitted People implementation and unrelated changes.

- Full Swift package suite: **569 tests passed**.
- macOS Debug build: **BUILD SUCCEEDED**.
- Independent review: three findings fixed with regression tests (corrupt transcript replacement, a metadata delimiter appearing inside Markdown, and stale notification focus targeting a reused name).
- Synthetic UI walkthrough: badge counts 2 → 1 → 0; popover groups; Settings → People navigation; highlighted rows and focused name; scrolling to another group; keyboard save; source-recording link; inferred-name provenance.
- No live provider call or real-recording accuracy evaluation was performed. Naming integration tests use a deterministic provider; the UI test uses a separate app identifier and temporary synthetic library.
- Library-switch and read-error guards were statically reviewed. Their OS file-picker scenarios were not manually exercised.

Implementation refinements: inferred-name invalidation is centralized in `SessionHandle.writeTranscript`; revisions use the canonical on-disk JSON format; default names require explicit self-introductions. Address-based names remain unnamed because they cannot satisfy the same-speaker evidence requirement. The existing dirty checkout was preserved on a new feature branch rather than copied to a worktree.

## Walkthrough

### Summary

Notes generation will supply editable default names for previously unnamed recording speakers while preserving saved-person recognition and user corrections. A local notification bell will highlight duplicate saved-profile names and take the user directly to the affected People settings rows.

### Changes

| Cohort / File(s) | Summary |
|---|---|
| **Speaker-aware notes**<br>`TranslixExport/TranscriptRenderer.swift`, `TranslixSummarize/{SummaryMetadata,SummaryPipeline}.swift`, `TranslixPipeline/SessionPipeline.swift` | Preserve distinct speaker identities and extract names in the existing notes request. |
| **Name persistence and precedence**<br>`TranslixModel/VoiceProfile.swift`, `TranslixStore/SessionHandle.swift`, transcription/diarization pipelines, session inspector | Apply only eligible names, retain provenance, invalidate stale inference, and protect manual and saved-person assignments. |
| **People conflicts and context**<br>`TranslixModel/PeopleNameConflict.swift`, `TranslixStore/VoiceProfileStore.swift`, `TranslixDiarize/VoiceRecognitionService.swift` | Detect duplicate profile names without merging identities; retain optional enrollment origins. |
| **Notifications and navigation**<br>`App/{AppEnvironment,AppNavigation}.swift`, shared People view model and related views | Keep the bell current and open People with the affected rows highlighted. |
| **Verification and documentation**<br>`Packages/TranslixKit/Tests/*`, `README.md`, generated Xcode project | Cover attribution, precedence, conflict lifecycle, compatibility, and the complete user flow. |

### Resulting flow

```mermaid
flowchart LR
    A[VoiceRecognitionService] --> B[SessionPipeline]
    B --> C[TranscriptRenderer with speaker IDs]
    C --> D[SummaryPipeline]
    D --> E[Saved Markdown notes]
    E --> F[SessionHandle applies eligible names]
    F --> G[SessionInspector]
    G -->|Explicit remember action| H[VoiceProfileStore]
    H --> I[PeopleViewModel detects conflicts]
    I --> J[PeopleNotificationsButton]
    J -->|Select conflict| K[AppNavigation]
    K --> L[VoiceProfilesSettingsPane highlights profiles]
    L -->|Rename| H
```

### Estimated effort

🎯 4 (Complex) | ⏱️ ~240 min

- Most care is needed in speaker attribution, precedence, and reprocessing compatibility.
- Notification UI is small, but state must remain correct across windows and library changes.
- The estimate includes package tests, a macOS build, and a manual walkthrough; inference quality depends on representative recordings.
