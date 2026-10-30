# Changelog

All notable changes to PullPing are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-10-30

### Changed
- Lists are sorted by what needs you: pull requests waiting on you first, then ones with unread activity, then the most recently active. The panel, the main window and every filter use the same order.
- Pull requests with nothing left for you move to a **Done** group at the bottom: merged or closed ones, and others' pull requests you're only involved in once everything is read and no review is asked of you or your team. In the panel Done is collapsed, like Hidden; in the main window it's a section you can collapse, and PullPing remembers your choice.

## [0.2.0] - 2026-10-30

### Added
- The welcome window now says why PullPing exists and shows the app icon, a Ko-fi support box and a wider layout.
- **Welcome Guide…** in Settings → General → About reopens the welcome window.

## [0.1.2] - 2026-10-30

### Added
- Settings → General → Count in the Menu Bar: choose which reasons count toward the menu-bar number. Review requests from your team now have their own switch and their own line in the panel header.

### Changed
- Account names you set in Settings now show everywhere: the panel's account switch, row chips, notification panels, the main window sidebar, error lines and phone notifications ("Account: …").
- The panel's menu button is now ⋯ (More) instead of a gear, with the same items as the right-click menu, including Pause Notifications.

### Fixed
- An empty "PullPing Settings" window could appear after closing Settings or reopening PullPing.
- The panel header no longer overflows and clips with long account names; the account switch becomes a menu when it doesn't fit.

## [0.1.1] - 2026-10-30

### Added
- Sign in with GitHub: add an account by approving a short code on github.com (OAuth device flow), no personal access token needed. Organizations that restrict OAuth apps may need an owner to approve PullPing first.

## [0.1.0] - 2026-10-29

First release.

### Added
- Tracks every open pull request you are involved in, across any number of GitHub accounts: ones you opened, ones assigned to you, ones where your review is requested (directly or through a team), and ones where you commented, reviewed or were mentioned. Merged and closed pull requests stay listed for a few days (1, 3, 7 or 14, your choice).
- Menu-bar panel with your pull requests in three groups (Mine, To Review, Involved), each row showing CI status, review state, draft, merged or closed, and an unread dot. With several accounts, switch between All and each account; a filter menu picks Inbox, All, Mine, To Review, Involved, Recently Closed, Muted or Hidden. Both are remembered.
- Menu-bar count of the pull requests that need you (review requests, unread mentions, and your own pull requests with changes requested, failed CI, new comments, or ready to merge), spelled out in the panel header and the icon's VoiceOver label. Settings → General can count everything unread instead, or show no number.
- Right-click (or Control-click) the menu-bar icon: Open PullPing, Refresh Now, Mark All as Read, Dismiss All Notifications, Pause Notifications (1 hour, 3 hours, until tomorrow 9:00), Settings, About, Ko-fi and Quit.
- Main window with a Mail-style sidebar: the same filters for All Accounts and for each account (collapsible), with counts, plus search and a detail view with reviewers, checks and the recent activity of each pull request. Settings → General → Inbox switches to one inbox per account.
- Phone notifications through ntfy (Settings → Phone): server, topic, optional access token and fallback topic URL (both in the keychain), a test button, and a choice per kind of event for your own pull requests and for others, independent of the desktop style.
- Notifications for comments, mentions, reviews (approved, changes requested, commented), review requests, assignments, new commits, CI passed or failed, ready for review, converted to draft, merged, closed, reopened, dismissed reviews and title changes. Your own actions never notify you.
- Notification panels that appear at the top right without taking keyboard focus, one per pull request, with a choice of Off, Banner (hides itself) or Alert (stays) for each kind of event, separately for your own pull requests and the ones you review or follow. Open, Snooze (15 minutes, 1 hour, 3 hours, tomorrow 9:00), Mute and Dismiss are one click away; an optional sound plays when a panel appears.
- Review reminders: while your review is requested on an open, non-draft pull request, PullPing reminds you again every 15 to 240 minutes (every 60 by default) until you review it, the request is removed, or it is merged or closed.
- Mark as read, mute (keeps the row, silences panels and reminders), hide (leaves every list and count, still notifies), snooze, and Hide and Stop Tracking with Undo.
- Accounts with personal access tokens (classic or fine-grained), checked when you add them, with a clear status when a token is rejected, lacks a scope, needs SSO approval or hits the rate limit. "Sign in with GitHub" (device flow) appears once an OAuth client id is configured. Tokens live in your login keychain.
- Settings for how often to check GitHub (1 to 15 minutes, 3 by default), how long to keep merged and closed pull requests, launch at login, and showing the menu-bar icon.
- `pullping://` links: `open`, `open?pr=<id>`, `refresh` and `settings`, for Shortcuts and Raycast.
- Welcome and About windows, with a link to support the project on Ko-fi.
- Universal app (Apple Silicon and Intel) for macOS 14 or later.
