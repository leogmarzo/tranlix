# Persistent Speaker Recognition Implementation Plan

**Goal:** Remember explicitly enrolled people and recognize their voices in subsequent meetings.

**Spec:** ../specs/2026-09-24-speaker-recognition-design.md

**Execution:** Implement inline in the current checkout, preserving pre-existing edits. The user approved the written scope and implementation; no additional approval stage is needed.

## Tasks

- [x] Add versioned descriptors and person profiles; test persistence, malformed evidence, duplicate names, rename and deletion.
- [x] Preserve FluidAudio embeddings and align local analysis with existing speaker labels; test confidence thresholds, ambiguity, overlaps, short speech and model compatibility.
- [x] Integrate recognition before notes, recording provenance and retryable errors; test manual corrections and old recordings.
- [x] Add enrollment, confirmation, retry and profile management UI; build the macOS app.
- [x] Run the package suite and independent final review; document accuracy limits.

## Decisions

- Use the existing checkout because active uncommitted work must remain available in the app; do not commit unrelated changes.
- Keep model identity with every descriptor. The installed FluidAudio implementation returns 256-dimensional community speaker centroids, before its PLDA transform.
- Treat thresholds as conservative similarity policies, not calibrated probabilities. Real-world accuracy needs labeled recordings from separate meetings.
- Never enroll automatically recognized voices without explicit user action.

## Verification and review

- Full package suite: 544 tests reported passing; opt-in hardware/model suites remain disabled by default.
- Real CoreML integration: one additional cross-utterance synthetic-voice test passed; cosine similarity 0.8937, automatic identification. This does not establish accuracy on real meetings.
- macOS Debug app build passed.
- Independent reviewer identified four important issues. Fixed stale audio fingerprints with shared SHA-256, preferred fresh local diarization over auxiliary analysis, reconciled automatic matches that became unknown, and isolated optional profile loading from playback initialization. The three data/recognition regressions were reproduced before the fixes and passed afterwards; playback isolation was checked in the app build and code review.
- Preserved the pre-existing title-generation changes and did not create a commit.

## Execution notes

- The automatic approval reviewer rejected a shell-based insertion into an existing test file, interpreting it as a possible replacement. The integration tests were added to a separate new file; no existing tests were removed.
- An initial full-suite run exposed a missing temporary directory in a new corruption test. Fixed the test setup, then reran the full suite successfully.
- UI validation is compilation-based; no interactive UI session was used.
