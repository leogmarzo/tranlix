# Persistent Speaker Recognition

## Intent

Remember a person explicitly named in one meeting and recognize that person by voice in later meetings. Recognition runs locally after recording, before notes generation. The user has approved this feature concept; this document defines the implementation scope for review.

## User experience

- Add an explicit remember-person action to the existing speaker inspector after a name has been entered.
- Store a reusable voice profile only when the user selects this action. Naming a speaker alone continues to rename that meeting.
- Apply a saved name automatically only when the voice comparison is strong and unambiguous. Show a suggested name requiring confirmation for plausible but uncertain matches; leave unknown voices unnamed.
- Allow a user to correct the meeting's assignment, rename a saved person, and delete a saved voice profile. Deleting a profile stops future recognition without erasing names already recorded in meetings.
- Never merge two people merely because their names match. Profiles have stable identifiers independent of display names.
- Do not automatically learn from inferred names. Only explicit enrollment or confirmation may add training evidence.

## Architecture

Extend TranslixModel with versioned voice descriptors, persistent person profiles, and assignment provenance. Keep speaker IDs scoped to a meeting; associate them with a separate person ID when recognized or confirmed.

Add an actor-backed profile store in TranslixStore, scoped to the recordings library. Use atomic writes and the existing JSON conventions. Keep profiles local and preserve compatibility with existing manifests and diarization files through optional fields and decoding defaults.

Add comparison and enrollment services in TranslixDiarize. FluidAudio's installed offline pipeline returns speaker segments with embeddings; the current adapter drops those embeddings. Preserve usable descriptors with their embedding model identity. Validate dimensions, finite values, nonzero magnitude, and sufficient speech before accepting descriptors. Never compare incompatible model representations.

Use normalized similarity with both a minimum match threshold and a minimum margin over the next candidate. Thresholds are policy parameters, not probabilities. Validate them against real recordings before claiming recognition accuracy. Reject ambiguous and insufficient evidence rather than assigning a name.

Wire recognition into SessionPipeline after speaker separation and before notes rendering. Preserve manual names and corrections on reruns. An optional recognition failure must not discard the transcript or prevent notes generation; expose a retryable status.

Expose enrollment, suggestions, and corrections through SessionViewModel and SessionInspector. Provide saved-person management through settings. AppEnvironment owns shared profile services; PipelineCoordinator passes them to the processing chain.

## Existing recordings and transcription engines

Old recordings remain readable. Enrollment requires voice descriptors, so recordings without descriptors need local voice analysis from retained audio. Show the required processing explicitly and report when audio is missing.

Recognition must also work when a remote transcription engine already supplied speaker labels. Obtain compatible local voice descriptors from the retained system audio and align them with those labels; do not silently claim remote labels contain reusable voice identities. Reject conflicting alignment or overlapping speech. The microphone retains its existing self-speaker behavior and is outside initial enrollment scope.

## Alternatives

The recommended approach reuses local FluidAudio descriptors with a library-level person registry. A cloud identification service adds a separate provider and audio transfer dependency. Reusing numbered speaker IDs across meetings cannot recognize people because those numbers depend on speaking order.

## Validation

- Profile persistence across restart, rename/delete behavior, duplicate display names, and concurrent updates.
- Strong, unknown, ambiguous, malformed, short-speech, and incompatible-model matches.
- Enrollment and recognition across distinct meetings with different speaker ordering.
- Preservation of manual corrections and avoidance of self-training from automatic assignments.
- Backward-compatible decoding and enrollment from older audio.
- Remote-engine label alignment, missing audio, cancellation, and optional-stage failures.
- Package tests, macOS app build, and an end-to-end check with available recordings. Report lack of representative labeled recordings as an accuracy-validation limitation.

## Workspace constraints

Preserve existing uncommitted changes in PipelineCoordinator.swift, RootView.swift, SummaryPipeline.swift, and AutomaticTitleTests.swift. All new code, comments, and documentation must be in English. Do not update dependencies unless the installed API proves insufficient.
