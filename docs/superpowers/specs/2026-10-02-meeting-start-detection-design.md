# Meeting Start Detection

## Intent

When a Zoom, Microsoft Teams or Google Meet call starts, Tranlix notices it on its own and offers to record it with a macOS notification that has a **Grabar** button. Pressing the button starts the recording at once, without bringing the main window forward. Today a meeting is recorded only if the user remembers to open Tranlix and press Grabar.

Detecting the **end** of a meeting is being built separately (branch `claude/tranlix-meeting-end-detection-00e2cf`). That work watches silence on the system track while a session records. This design does not depend on it and does not change the recording session.

## Decisions taken with the user

- **Signal:** a known meeting app starts using the microphone. Opening the app is not enough.
- **On accept:** recording starts directly from the notification.
- **Settings:** one master toggle plus one toggle per app (Zoom, Teams, Meet in the browser). All are on by default.

## How a meeting is detected

Core Audio publishes one *process object* per process that does audio I/O (macOS 14.4+). For each one Tranlix reads three properties:

| Property | Use |
|---|---|
| `kAudioProcessPropertyPID` | Resolve the enclosing app bundle. |
| `kAudioProcessPropertyBundleID` | First candidate identifier. |
| `kAudioProcessPropertyIsRunningInput` | Whether the process is capturing from an input device right now. |

Reading these needs no TCC permission. They describe *whether* a process captures, not *what* it captures.

**Helper processes.** Browsers capture in a helper process. A probe on this Mac showed Chrome's audio service as `com.google.Chrome.helper`. Safari captures in WebKit's shared `com.apple.WebKit.GPU` process, which every app that hosts a web view also uses. So each process carries two identities:

1. its own Core Audio bundle id;
2. the app **responsible** for it. That is the process macOS holds responsible for it, looked up at run time with `responsibility_get_pid_responsible_for_pid`. Then comes the **outermost** app bundle around that process's executable, found with `proc_pidpath`. When either step fails, the process's own executable is used instead.

The responsible app decides whenever it names a meeting app. That maps a Chrome helper to Chrome, and a WebKit capture run on behalf of Teams to Teams. WebKit's shared process counts as a browser only when no responsible app is known. That way Mail using the microphone is not a meeting.

Seen on a real Mac: after an update, Chrome's main process runs from a code-signing clone named `Google Chrome.app.bundle` in a temporary folder. So `.app.bundle` counts as an app bundle too.

**Matching rules.** Prefix match, case-insensitive:

| App | Prefixes |
|---|---|
| Zoom | `us.zoom.` |
| Teams | `com.microsoft.teams` (classic and `teams2`) |
| Meet (browser) | `com.google.chrome`, `org.chromium.chromium`, `com.apple.safari`, `com.apple.safaritechnologypreview`, `company.thebrowser.`, `com.microsoft.edgemac`, `com.brave.browser`, `org.mozilla.firefox`, `org.mozilla.plugincontainer`, `com.vivaldi.vivaldi`, `com.operasoftware.opera` |
| Meet (fallback) | `com.apple.webkit.`, only when no responsible app is known |

A prefix ending in a dot matches anything under it. Any other prefix matches itself, or itself followed by a dot. So `com.google.chrome` does not claim `com.google.chromecast`.

Tranlix's own process is always excluded, both by PID and by bundle id (`com.leomarzo.tranlix`).

**Meet is browser-level.** A browser using the microphone is reported as "a meeting in Chrome". Telling Meet apart from another page using the mic would need the tab URL, which means Accessibility or Screen Recording permission. The user chose the cheaper signal. The settings caption says so.

**Change notification.** The probe listens to `kAudioHardwarePropertyProcessObjectList` on the system object. On each process object it also listens to `kAudioProcessPropertyDevices` in the input scope, and it re-registers those listeners whenever the process list changes. It does **not** listen to `kAudioProcessPropertyIsRunningInput`, although that is the property it reads.

This was measured on macOS 26 with Chrome opening and closing the microphone. A listener on `IsRunningInput` never fired. The input-scoped device list fired at both the start and the stop.

A slow safety poll every 10 seconds covers any notification Core Audio fails to deliver. With the poll disabled, a live run reported the start 3.2 s after Chrome opened the microphone and the end 8.1 s after it closed it. Those are the two grace periods, plus the 50 ms coalescing window. Each snapshot is cheap: a few dozen property reads.

## Debouncing

`MeetingActivityDetector` is a pure value type. It turns raw "these apps are capturing now" snapshots into events, using a per-app state machine:

```
idle ──capturing──▶ pending(since) ──≥ startGrace──▶ active   ⇒ emits .started
pending ──stops──▶ idle (no event)
active ──stops──▶ releasing(since) ──≥ endGrace──▶ idle      ⇒ emits .ended
releasing ──capturing again──▶ active (no event)
```

| Parameter | Value | Why |
|---|---|---|
| `startGrace` | 3 s | Ignore a microphone opened for a level check or a permission probe. |
| `endGrace` | 8 s | A device switch, such as connecting AirPods, closes and reopens input. That must not look like a new meeting. |

The detector also exposes `nextDeadline`. The monitor uses it to re-evaluate exactly when a grace period ends, without polling.

## Deciding whether to prompt

`MeetingPromptPolicy` is a pure value type. It decides what the user sees:

- **On `.started(app)`:** prompt when detection is enabled, the app is watched, and the recorder can record. It does not prompt when a session is already open or busy.
- **Re-prompt cooldown:** do not prompt for the same app again within 2 minutes after its previous meeting ended, if that earlier prompt was not acted on. Some apps release the mic on mute. Without this, every unmute would re-prompt.
- **On `.ended(app)`:** withdraw an outstanding prompt for that app.
- **When recording starts by any route:** withdraw any outstanding prompt.
- **One prompt at a time:** a newer prompt replaces the older one, because only one recording can run.

## User-facing behavior

- **Notification:** titled "¿Grabar la reunión?". The body names the app, e.g. "Zoom está usando el micrófono." or "Google Chrome está usando el micrófono.".
  - The only action is **Grabar**. The alert's own close button means "Ahora no", and it is reported through `.customDismissAction`. A second action would hide both behind an "Opciones" menu on an alert.
  - Clicking the body opens Tranlix on the record screen without recording.
  - `NSUserNotificationAlertStyle = alert` in Info.plist keeps it on screen until answered. A banner would slide away while the user looks at the call. This also applies to the meeting-end question, which is a question too.
- **Grabar:** calls `RecorderViewModel.start()` and leaves the title untouched. An empty title is what lets the notes stage name the session from what was said (`SummaryPipeline`, `needsTitle`). A generic "Reunión de Zoom" would replace that. The floating recorder appears as usual if enabled.
- **Grabar failure:** if starting fails, for example because of a microphone permission or disk space problem, a second notification shows the error. Nobody is looking at the window that would show it.
- **Permission:** notification permission is requested when a meeting is first detected, or when the user turns the setting on. It is never requested at launch. If permission is denied, Settings shows a warning and a button to open System Settings → Notifications.
- **Notification shown while Tranlix is frontmost:** `willPresent` returns banner + sound.

## Components

### Package `TranlixCapture` (testable with Swift Testing)

| File | Type | Role |
|---|---|---|
| `MeetingApp.swift` | `public enum MeetingApp` | Cases, display names, default titles, matching rules. |
| `AudioProcessProbe.swift` | `protocol AudioProcessProbe`, `struct AudioProcessSnapshot` | Seam between Core Audio and logic. |
| `CoreAudioProcessProbe.swift` | `final class CoreAudioProcessProbe` | Real implementation: listeners, safety poll, `proc_pidpath` resolution. |
| `MeetingActivityDetector.swift` | `struct MeetingActivityDetector`, `enum MeetingEvent` | Pure debounce state machine. |
| `MeetingAppMonitor.swift` | `public actor MeetingAppMonitor` | Glues probe + detector + clock and exposes `AsyncStream<MeetingEvent>`. |
| `MeetingPromptPolicy.swift` | `public struct MeetingPromptPolicy` | Pure prompt / withdraw decisions. |

### App

| File | Type | Role |
|---|---|---|
| `App/Notifications/AppNotifications.swift` | `AppNotifications` | The single `UNUserNotificationCenterDelegate`, routing by category id. It is written by the meeting-end work and copied byte-for-byte, so both branches add an identical file. |
| `App/MeetingDetection/MeetingPromptController.swift` | `MeetingPromptController` | Owns the monitor's lifecycle from settings, applies the policy, posts and withdraws, and handles **Grabar**. |
| `App/SettingsStore.swift` | — | Adds `autoDetectMeetings: Bool` and `watchedMeetingApps: Set<MeetingApp>`. |
| `App/Views/MeetingDetectionSettings.swift`, `App/Views/SettingsView.swift` | `MeetingDetectionSettings` | Adds a "Reuniones" section in General, with a warning and a System Settings button when notifications are denied. |
| `App/TranlixApp.swift` | — | Wiring. |

## Concurrency

- The probe works on a private serial queue. Core Audio listener blocks run there too. It reports changes through a `@Sendable` callback that only yields to an `AsyncStream`. It never blocks on an actor, the same rule `SystemAudioSource` follows.
- The monitor is an actor. It sleeps until `nextDeadline` with a cancellable `Task`.
- The app side is `@MainActor`. It follows the existing re-arming `withObservationTracking` pattern for settings and recorder state.

## Error handling

- A property read that fails skips that process for this snapshot.
- If Core Audio refuses to register the process-list listener, the safety poll still works. Detection is slower but still correct.
- A failed notification post is logged with `Logger(subsystem: "com.leomarzo.tranlix", category: "MeetingDetection")` and otherwise ignored. A recording-start error surfaces through `RecorderViewModel.errorMessage`, as today.

## Validation

- **Unit tests in Swift Testing:**
  - Matching rules, including helpers, case and Tranlix exclusion.
  - Detector transitions: grace periods, flapping, device-switch gaps, several apps at once, deadlines.
  - Monitor with a scripted probe and a manual clock.
  - Policy: enabled or disabled, unwatched app, recorder busy, cooldown, withdraw on end and on recording.
- **Integration test gated by `TRANLIX_INTEGRATION`:** the real probe returns a non-empty snapshot without crashing.
- **App build** with `scripts/build.sh`.
- **Manual check:**
  - Open a Meet green room in Chrome and confirm the notification shows; press Grabar and confirm recording starts.
  - Leave the call and confirm the notification is withdrawn.
  - Repeat with Zoom or Teams if installed.

## Out of scope

- Detecting meeting end while recording (separate work).
- Distinguishing Meet from other browser pages.
- Calendar integration.
- Other apps such as Slack huddles or FaceTime. Adding one is one row in the matching table.
