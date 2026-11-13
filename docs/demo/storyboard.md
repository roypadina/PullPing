# PullPing demo — storyboard (11.4 s, loops)

Real code: `StatusPanelView` (the status item popover), `NotificationContent` + `PanelModel` (the top-right panel), `Store`, `Fixtures`, `Attention`,
`Theme`, compiled unchanged from `Sources/PullPing` + `Sources/PullPingCore` as static modules (`render.sh`; the UI module with `-enable-testing`, the scene
`@testable import`s it). Both views are drawn by hosting them in an offscreen borderless window and `cacheDisplay` (a `List`/`Picker` cannot go through
`ImageRenderer`), like the app's own `ScreenshotRenderTests`. Fake data: the app's own `Fixtures.sampleStore()` (accounts "Personal" / "Work", repos
`octo-org/widgets|gadgets|docs`, people carol / erin / bob), trimmed to five items so every section fits the popover: PR_2 mine (changes requested, CI failed),
PR_1 mine (approved, ready to merge), I_1 my issue (erin commented), PR_3 awaiting my review (the one that arrives), PR_11 mine waiting on CI.

Numbers and words come from the app, not typed in: the menu-bar count is `Store.badgeCount` (what needs me: 3 before the request, 4 after), the popover header
line is `Store.breakdown` ("1 to review · 1 changes requested · 2 with new comments"), segments "All 4 · Personal 3 · Work 1" are `Store.count(scope)`, the panel
text is `NotificationContent` of the real review-request event (EventEngine records a direct request with an empty summary, so the panel reads "carol requested
your review"), and the panel is an alert because `AppSettings.needStyle(.toReview)` is `.alert` by default.
Status item = the app's `menubar@2x.png` template glyph + `"\(badgeCount)"` (`StatusItem.swift` `render()`).

State machine (checked in source): the request arrives → `Store.handle` reloads the state (count +1) and `Store.show` puts one panel in slot 0
(`NotificationPanels.add`: 0.25 s fade, no slide, 12 pt below the menu bar at the top right); an alert stays until acted on; the xmark is `onDismiss` →
`remove` (0.15 s fade). Left click on the icon = `StatusItem.togglePopover` (popover under the icon, icon highlighted while shown). Picking the "Work" segment
sets `panelAccount` → `scope = .account(work)`: only that account's rows (To Review: PR_3, and Waiting on Others (1) collapsed: PR_11). A click
outside closes the transient popover.

| # | Scene | Start | Dur | What happens | Caption |
|---|-------|-------|-----|--------------|---------|
| 1 | menu bar | 0.0 | 2.2 | Menu bar only, clock 9:41. Status item: PullPing glyph + "3". | A count of pull requests that need you |
| 2 | arrives | 2.2 | 3.0 | At 0.4 s the count becomes "4" and the real panel fades in top right ("Review requested · octo-org/gadgets #57 · Bump build tools to 2.4 · carol requested your review · Open / Snooze… / Mute PR · Work"). It stays. At 1.3 s the cursor appears, glides to the xmark, clicks at 2.05 s: the panel fades out (0.15 s). | A review request arrives as a panel that stays |
| 3 | panel | 5.2 | 3.4 | Cursor glides to the icon, click at 0.9 s: icon highlights, the popover opens at once (0.12 s fade): header "Pull Requests / Updated just now / 1 to review · …" with the Needs Me filter, segments All 4 · Personal 3 · Work 1, To Review (PR_3), Your Pull Requests (PR_2, PR_1), Mentions & Assigned (I_1) with status chips and unread dots. Cursor then heads for "Work". | What needs you first, with whose turn it is |
| 4 | accounts | 8.6 | 2.8 | Click on "Work 1" at 0.35 s: the list switches at once to Work only (To Review, Waiting on Others collapsed). Cursor glides to the desktop, click at 1.95 s: popover closes (0.12 s), icon un-highlights, cursor fades. | Switch between your personal and work accounts |

Transitions: 0.2 s crossfade between scenes; captions fade old 0–0.12 s / new 0.12–0.35 s (never two pills at once); the last 0.2 s dissolves into scene 1's first
frame (count 4 → 3 on the loop dissolve, as a fresh cycle starts). Cursor: system arrow (`NSCursor.arrow`), eased glides on a slight arc, click = dip + ripple;
visible only while it points at something (it stays on screen across the 2→3→4 cuts because it keeps pointing at the next target).
Render: `./render.sh` (swiftc for the two static modules + kit + scene, 30 fps frames, encode). Poster frame 200 (popover open).
Least real: the popover is drawn at 0.9 so it clears the caption pill (380x520 pt on a 600 pt canvas), has no arrow, and its table backing is made transparent so the
kit glass shows through; no hover or pressed states inside SwiftUI views; the notification card is the flat `.regularMaterial` colour from the capture (as in the MeetAlert demo).
