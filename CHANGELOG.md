# Changelog

All notable changes to PullPing are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.6.1] - 2026-11-04

### Added
- **Check for Updates…** button in Settings → General → About, next to the About and Welcome Guide buttons.
- The menu-bar icon's right-click menu has **Check for Updates…**, which becomes **Install Update X.Y.Z…** once PullPing has found a newer version.

## [0.6.0] - 2026-11-04

### Added
- Updates from inside the app. PullPing checks for a new version once a day and asks before installing it; tick "Automatically download and install updates" in that prompt to skip the question next time. The check downloads the release feed from GitHub and sends nothing about you. Check by hand with **Check for Updates…** in the About window. Updates are signed, and installing one this way needs no `xattr` step.

## [0.5.0] - 2026-11-02

### Added
- **Agent automations.** PullPing can start Claude Code or Codex in a terminal (Terminal, iTerm2, Ghostty or Ghostex, whichever are installed, or your own command line; `pullping launchers`) when a pull request event arrives. Write rules in the new **Settings → Automations** tab: the kinds of event, Any / Mine / Others, optional repositories and logins, a prompt with placeholders, a working directory, the agent (with an optional wrapper command) and where it opens. **Try with Latest Pull Request** checks a rule right away; **Recent Runs** shows what started and what failed.
- **Agent hooks and the `pullping` command.** `pullping hook add --pr … --on … --session …` lets an agent ask to be resumed on one pull request or issue, for example when it is approved or commented on. Agents get everything the Automations tab does: `pullping rule` and `pullping hook` `add`, `edit`, `show`, `list`, `enable`, `disable` and `rm`, `pullping run` (Run Automation, with `--dry-run`), `pullping runs` (Recent Runs), `pullping automations on|off|status` and `pullping kinds`; every reader and writer takes `--json` in the shape `automations.json` stores. The app picks changes up within 30 seconds, also when it was closed. Automations written from the command line are marked **CLI** in Settings, and the first time one is set to run automatically a notification says so. The command is the app binary itself, so the Homebrew cask links it as `pullping`; any other word after it is a command, never a second copy of the app. A Claude Code skill with the recipes is in `docs/claude-skill/pullping`.
- **Handle with Agent.** Turn it on in Settings → Automations (or `pullping handler on`) and the notifications you pick (Edit…, or `pullping handler set --on <kind,…|all>`; by default the ones an agent can act on, not CI passed, new commits, merges, closes, drafts, title or label changes), and the pull request's menu, get a **Handle with Agent** button: one click starts your agent on that pull request or issue with a prompt you can edit, in the agent, terminal and folder you pick. When the pull request has a linked session the button becomes **Resume Session** and **New Session**. It never runs on its own.
- **Linked sessions.** An agent links its session to a pull request with `pullping session set --pr <url> --session "$CLAUDE_CODE_SESSION_ID" --quiet` (also `hook add --session`), and every new Claude Code session PullPing starts on a pull request links itself. The link keeps the folder the session was started in, read from its transcript, so Resume Session finds it. A rule can resume the linked session (**The pull request's linked session**, `--session linked`). Links show in Settings → Automations → Linked Sessions and the main window's detail (`pullping session list|show|rm`) and expire after the pull request is merged or closed, or after 30 days.
- **Repository folders.** The working directory defaults to `{repo_dir}`: the repository's folder under Settings → Automations → Repository Folders (default `~/Code`; add as many as you keep repositories in), else a fallback folder (default `~`), so a run never fails only because a repository isn't cloned. `pullping automations folders list|add|rm` and `pullping automations fallback`. A failed Try shows its whole message, with the folder it tried.
- **Repository locator.** `{repo_dir}` is now the clone whose git remote is the repository (`owner/repo`, any host or SSH alias), found up to 3 levels below the repository folders whatever the clone is called (`~/Code/<org>/<repo>`, `~/src/github.com/<owner>/<repo>`, a renamed clone), then a folder named like the repository, then the fallback. A pull request's linked or earlier session's folder wins when it is inside a clone of the repository, and **Repository Overrides** (`pullping automations repos list|set|rm`) win over everything. `pullping automations folders list` shows how many clones PullPing finds. PullPing reads git's own files and never creates worktrees.
- **Worktree-aware folders.** New placeholders `{branch}` (the pull request's head branch, GitHub text: prompts only), `{worktree_dir}` (the worktree with that branch checked out, else the main worktree), `{main_dir}` and `{repo_root}` (the repository folder that holds the clone). Handle with Agent's default prompt names the worktree. Resume Session whose folder is gone starts in `{worktree_dir}` (Claude Code 2.1.223 and Codex resume by id from anywhere) and says so in Recent Runs; one whose transcript was deleted fails with "The session's transcript is gone".
- **Earlier sessions.** With no linked session, PullPing can find the local Claude Code or Codex session that worked on a pull request (the record Claude writes when a session creates it, its URL, or its branch), within the last 60 days, 1.5 GB or 10 seconds of reading; nothing leaves your Mac. **Look for earlier sessions** under Handle with Agent (off by default) turns Handle with Agent into **Resume Earlier** and **New Session** when one is found; **Find Earlier Session…** in the pull request's menu searches now. Agents use `pullping session find --pr <url> --link` and hand off with `pullping session resume --pr <url>`, which refuses a session that looks open in another terminal, the calling session itself and a second hand-off within a minute, and records who handed off; the default prompts suggest it.
- **Activity.** **Activity** in the main window's sidebar (for All Accounts and each account; also in the menu-bar icon's menu) lists everything PullPing saw and did: every event, whether it showed a banner or an alert, went to your phone, or was not shown and why (your own, notifications off, paused, muted, snoozed, off in Settings), review reminders, and every automation run and Handle with Agent launch. Newest first by day, with search; a row shows its pull request, and opens it in the browser even once it is no longer tracked. Kept 30 days (Settings → General → **Keep activity for**: 7, 30 or 90 days), at most 5000 entries, in `activity.jsonl`; `pullping activity [--since <time>] [--pr <ref>] [--json]` reads it while the app is closed.
- **Run buttons.** An automation asks first by default: its notification gets a **Run …** button and stays until you act, and the pull request's right-click menu and the main window's toolbar get **Run Automation** (`pullping run` from the command line). **Run automatically** is a per-automation choice. The main window's detail lists a pull request's agent hooks.
- Safety limits: no comment bodies or other GitHub text in any shell command or working directory, a prompt the agent never reads as an option, never a permission-bypass flag (the only argument PullPing adds is `--session-id` with a UUID it generated), your own comments and reviews (and pushes GitHub links to your account) never trigger anything, new commits after an automation ran on a pull request only offer it again, and each automation is capped per event, per pull request, per failed start and per check. A Run button left on a notification does nothing once its automation is turned off, removed or expired.

### Changed
- Nothing in the state file or the existing settings changes format (a new pull request's first events gain one optional field): a 0.4.0 build still opens everything this version writes and ignores the new `automations.json` and `activity.jsonl`.
- An open rule or Handle with Agent editor no longer overwrites a change made from the command line meanwhile: Save says "Changed elsewhere" and offers **Reload** or **Save Anyway**, and the Enabled switches and Repository Folders rows change only their own value.

### Fixed
- Accounts added with **Sign in with GitHub** no longer show "Token rejected" every day. GitHub sign-in tokens expire after 8 hours; PullPing now keeps the refresh token GitHub sends with them (in your login keychain) and renews the token by itself; a network drop during the renewal shows Offline (not "Token rejected") and it renews on the next poll, and a renewed token that cannot be saved to the keychain is reported on the account. Accounts signed in with an earlier version have no refresh token yet: sign in with GitHub once more (Add Account…, then remove the old entry). Personal access tokens are not affected.
- Agents PullPing starts are fresh sessions even when PullPing itself was opened from a terminal agent: the launch no longer passes on that agent's session variables (`CLAUDE*`, `CODEX_*` and those of a few session-switching tools); your shell profile still sets anything you export on purpose.

## [0.4.0] - 2026-10-30

### Added
- **Issues.** Open issues you opened, are assigned to, are mentioned in or commented on are tracked next to your pull requests, with an **Issue** chip on their rows. Comments, mentions, assignments, renames, reopening and closing notify like pull request events; a closed issue shows **Completed** or **Not planned**. Settings → General → Track Issues turns them off and removes them from the lists. Issues you were already involved in arrive quietly, marked read.
- **Label changes** on pull requests and issues: a new **Labels changed** kind in Settings → Notifications and Phone (banner on yours, off for others by default).
- **Assigned to me** in Settings → General → Count in the Menu Bar: an unread assignment, on a pull request or an issue, counts toward the menu-bar number. New comments on an issue assigned to you count as new comments.

### Changed
- The Notifications and Phone tables call their first column **Mine**: pull requests and issues you opened.
- Upgrade only: a 0.3.0 build cannot read state or settings written by this version (state moves to state.broken.json, settings reset).

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
