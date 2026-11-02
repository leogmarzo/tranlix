# Compact recording calendars

Open any HTML file directly in a browser. All four are self-contained, with inline CSS, JavaScript, and vector icons. There are no dependencies, network requests, or build steps. UI copy is in Rioplatense Spanish; this document is in English.

## Variants

- **A — Sidebar calendar:** A 220 px month picker below New Recording and search filters the existing sidebar rows to one day; the detail pane stays available for the selected session. There is no Calendar destination.
- **B — Compact Calendar destination:** A 300 px month picker sits beside the selected day's recording list in the detail pane; the sidebar keeps its grouped library.

- **C — Toolbar popover:** The calendar button beside sidebar search opens a compact month picker and daily recording list in one popover; opening a recording dismisses it.
- **D — Date strip:** A horizontally scrollable row of days filters sidebar sessions, with weekly navigation and a compact month picker for longer jumps.

## Design rationale

- Make the task one action: select a date and see that day's recordings. Dates contain only numbers and a small recording-presence dot; session titles belong in the list.
- Keep the calendar small and independent of window height. A uses existing sidebar space; B uses a compact area at the top of the detail pane and leaves the remaining space clear.
- Preserve native-looking window chrome, a 260 px sidebar, system typography, blue selection, and light/dark semantic colors. HTML approximates native materials without external assets.
- Show state with a dot and text on every session row, replacing the dot with a spinner for processing. Accessible date labels include recording counts; keyboard focus is visible and reduced-motion preferences are respected.
- Keep existing session navigation. Selecting a day changes its list; selecting a recording opens the normal notes/transcript/inspector preview. A and D expose a small Show All action to restore grouped rows.

## Interaction and data

A and B initially show November 2026 with Monday, November 2 selected. A opens today's Statistics session in the detail pane; B shows today's three recordings beside the calendar. Month arrows change the visible month, and Today selects November 2. Adjacent-month dates are clickable. Today and the selected day have distinct treatments when they differ.

A day with recordings has one small dot regardless of count. Select October 29 to see four recordings, October 30 for a processing example, or November 1 for “No hay grabaciones este día”. November 2 also includes a processing recording. Empty states use actual empty days; there is no demonstration toggle.

The October–November sample data is unchanged, including completed, audio-only, interrupted, failed, and processing sessions. Untitled sessions fall back to the folder name. No future recordings are fabricated. Empty library groups are omitted: Ayer has no sessions, and this fixed Monday has no additional Esta semana sessions outside Hoy.

In A and D, the date filter and search query apply together; Show All clears only the date filter. In B and C, search filters the sidebar library. Session previews include illustrative notes and transcripts. The New Recording destination is a placeholder and does not record audio. Switching between variant files resets the prototype to its initial state.

C starts with its popover closed and today’s Statistics session open. The calendar button sits in the sidebar search toolbar, beside the unchanged search field. The grouped sidebar remains independent of the popover date. Selecting a date refreshes the compact rows below the calendar; selecting a row opens its session and closes the popover.

D initially presents two weeks from October 26 through November 8, with November 2 selected and scrolled into view. The single row scrolls horizontally; arrows shift the range by seven days without changing the selected-day filter. Clicking the month label opens a compact month calendar. Select a date there to jump the strip, filter the list, and close the picker. Today returns to November 2; Show All restores grouped sessions. Both popovers support Escape, an explicit close button, and dismissal when clicking or focusing outside.

## SwiftUI component inventory

| Component | Props / state | Existing mapping |
| --- | --- | --- |
| `LibraryNavigation` | Sessions, search query, optional selected date, selected session/destination | Existing sidebar `List` and `NavigationSplitView`; A inserts the mini calendar, B retains the Calendar destination |
| `MiniMonthCalendar` | Visible month, selected day, today, dates with recordings; previous/next/Today/select actions; width 220 or 300 pt | New shared compact calendar, Monday first with `es_AR` date formatting |
| `MiniDayButton` | Date, today/selected/adjacent-month state, recording count | New small date control with a presence dot and spoken recording count |
| `DayFilterHeader` | Selected date, total recording count, clear action | New sidebar section header for A and D; Show All restores grouped rows |
| `LibraryRow` | `SessionSummary`, selected state, title fallback, start time, duration, state | Existing `LibraryRow`; use the same rows for grouped and filtered lists |
| `CompactCalendarDetail` | Visible month, selected day, daily sessions, session-opening action | New compact destination in the existing `NavigationSplitView` detail for B |
| `DayRecordingList` | Selected date, session count, sorted sessions, empty state | New list presentation beside B's calendar; reuse `LibraryRow` title/state formatting |
| `SessionStateIndicator` | Ready/audio-only/interrupted/error/processing, accessible label | Reuse existing row state styling; 6 pt dot plus text or a small `ProgressView` |
| `CalendarPopoverButton` | Open/closed state, accessibility label, anchor | New toolbar button beside the existing sidebar search in C; SF Symbol `calendar` |
| `CalendarDayPopover` | Visible month, selected day, daily sessions, dismiss/open-session actions | New native `.popover` in C; reuse `MiniMonthCalendar`, `DayRecordingList`, and session navigation |
| `DateStrip` | Visible two-week range, selected day, today, recording dates; horizontal scroll and previous/next week actions | New horizontal `ScrollView` below sidebar search in D; reuse `MiniDayButton` and `DayFilterHeader` behavior |
| `MonthJumpPicker` | Open state, visible month, selected date; jump/dismiss actions | New `.popover` anchored to D’s month label; reuse `MiniMonthCalendar` and update the strip range |
| `SessionDetail` | Selected session ID | Existing notes, transcript, and inspector; represented by a lightweight HTML preview |

Use native system materials, semantic colors, and SF Symbols (`record.circle`, `calendar`, `sidebar.left`, `magnifyingglass`, `chevron.left/right`) in SwiftUI. The HTML uses inline vector approximations. Use `Calendar` date arithmetic with Monday explicitly set as the first weekday, and route every recording selection through the existing session-opening action.

## Open question

- Should dates and times use the device's current time zone or the recording's original time zone? Samples use Argentina local wall-clock time.

## Scope and validation

These are desktop review mockups in approximately 1280 × 800 windows, not a recording implementation or an Apple Calendar integration. Smaller widths retain a desktop canvas; B can stack its compact calendar above the list.

Validation covers HTML structure, JavaScript syntax, unchanged sample data, and date/list interaction logic without a browser. No screenshots, browser automation, or visual verification are used.
