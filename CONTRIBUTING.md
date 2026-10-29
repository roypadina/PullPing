# Contributing to PullPing

Thanks for your interest! Bug reports, feature ideas, docs and code are all welcome.

## Ground rules

- **`main` is protected.** No direct pushes; changes land via Pull Request and are
  reviewed/merged by the maintainer ([@roypadina](https://github.com/roypadina)).
- Be respectful — see the [Code of Conduct](CODE_OF_CONDUCT.md).
- Keep changes focused. One logical change per PR, smallest diff that solves it.
- Keep it public-clean: no real access tokens, logins, organization or repository names in code,
  fixtures, screenshots or issues. Use generic names (`octo-org/widgets`, `alice`, `bob`).

## Getting started

```bash
git clone https://github.com/roypadina/PullPing.git
cd PullPing
swift test                 # core logic tests
./build.sh                 # builds dist/PullPing.app
open dist/PullPing.app
```

Requirements: **macOS 14+**, Xcode or the Xcode command line tools (Swift 5.9 or later).

`Scripts/package_app.sh` (what `build.sh` runs) signs with `PULLPING_SIGN_IDENTITY` if set, falls
back to the maintainer's stable identity when it is in your keychain, and otherwise signs ad hoc.
Use your own code-signing certificate through `PULLPING_SIGN_IDENTITY` if you want a stable
signature between builds. `RELEASE=1 ./build.sh` also strips the binary and writes `dist/PullPing.zip`.

To try the polling and event logic against a real account without the UI, run the debug binary
in smoke mode (read-only, prints a report and never prints the token):

```bash
PULLPING_SMOKE=1 PULLPING_TOKEN=<token> .build/debug/PullPing
```

## Layout

- `Sources/PullPingCore` — UI-free, tested logic: models, GitHub GraphQL client, poller,
  event engine, reminders, persistence, keychain access.
- `Sources/PullPing` — the SwiftUI/AppKit menu-bar app: status panel, main window, notification
  panels, settings.
- `Tests/PullPingCoreTests` — tests for the core, with generic JSON fixtures.
- `Tests/PullPingScreenshotTests` — renders the README screenshots (skipped unless
  `RENDER_SCREENSHOTS=<dir>` is set).
- `Assets/icons` and `AppIcon.icon` — SVG sources and the Liquid Glass icon; regenerate the PNG and
  icns files with `Scripts/make_icons.sh` (needs `brew install librsvg`).

## Workflow

1. **Fork** and branch: `git checkout -b feat/my-thing`.
2. Make your change; run `swift test` and try it in the packaged app.
3. Match the surrounding style; no drive-by refactors.
4. Open a **Pull Request** against `main`. CI must be green and the maintainer must approve.

## Commit messages

[Conventional Commits](https://www.conventionalcommits.org): `feat: ...`, `fix: ...`, `docs: ...`.

## Feature requests and bugs

- **Feature requests:** [open one](https://github.com/roypadina/PullPing/issues/new?template=feature_request.yml) and say what you're trying to do; that matters more than the exact feature. Search the [open requests](https://github.com/roypadina/PullPing/issues?q=is%3Aissue+is%3Aopen+label%3Aenhancement) first and 👍 an existing one if it's there.
- **Bugs:** use the [bug report](https://github.com/roypadina/PullPing/issues/new?template=bug_report.yml).
- **Ko-fi supporters:** add your Ko-fi name to the request and it goes to the front of my queue. It's a thank-you, not a purchase: no promise on what ships or when.
- **Bigger changes:** open an issue before the PR so we agree on the shape first. Small, focused PRs can come straight in.
- Replies are best effort, evenings and weekends. I read everything.
