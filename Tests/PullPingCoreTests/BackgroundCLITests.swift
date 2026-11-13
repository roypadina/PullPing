import XCTest
@testable import PullPingCore

/// `pullping background` and `pullping drafts`, and `rule --background`, on a scratch store.
final class BackgroundCLITests: XCTestCase {
    var dir: URL!
    var store: AutomationStore!
    var env: [String: String] { ["PWD": dir.path, "HOME": dir.path, "PULLPING_ACTIVITY": dir.appendingPathComponent("activity.jsonl").path] }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = AutomationStore(url: dir.appendingPathComponent("automations.json"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    var tracked: TrackedState {
        var state = TrackedState()
        for (id, number, mine) in [("PR_7", 7, false), ("PR_8", 8, true)] {
            var pr = TrackedPR(id: id, accountID: UUID(), firstTrackedAt: t0)
            (pr.repo, pr.number, pr.url, pr.title, pr.headOID) = ("octo-org/widgets", number, URL(string: "https://github.com/octo-org/widgets/pull/\(number)")!, "Add cache", "abc1234")
            if mine { pr.roles = [.author] }
            state.prs[id] = pr
        }
        return state
    }

    @discardableResult
    func run(_ line: [String]) -> (output: String, error: String, status: Int32) {
        AutomationCLI.run(line, store: store, env: env, now: t0, state: { self.tracked })
    }

    var runs: [RunRecord] { store.load().runs }

    func testSwitchAndCap() {
        XCTAssertEqual(run(["background", "status"]).output, "Background runs: off · 0 of 20 in the last 24 hours · 0 running, 0 waiting")
        XCTAssertEqual(run(["background", "on"]).output, "Background runs: on · 0 of 20 in the last 24 hours · 0 running, 0 waiting")
        XCTAssertEqual(run(["background", "set", "--daily-cap", "5"]).output, "Background runs: on · 0 of 5 in the last 24 hours · 0 running, 0 waiting")
        XCTAssertEqual(run(["background", "set", "--daily-cap", "0"]).status, 2)
        XCTAssertEqual(run(["background", "set"]).status, 2)
        XCTAssertEqual(run(["background", "status", "--json"]).output.contains(#""dailyCap" : 5"#), true)
        XCTAssertEqual(run(["background", "off"]).status, 0)
        XCTAssertFalse(store.load().background.enabled)
    }

    func testRunQueuesAndRefuses() throws {
        let off = run(["background", "run", "review", "--pr", "octo-org/widgets#7"])
        XCTAssertEqual([off.status], [1])
        XCTAssertEqual(off.error, "pullping: Background Runs are off (Settings → Automations, or pullping background on)")
        run(["background", "on"])
        let queued = run(["background", "run", "review", "--pr", "https://github.com/octo-org/widgets/pull/7"])
        XCTAssertEqual(queued.status, 0, queued.error)
        let record = try XCTUnwrap(runs.last)
        XCTAssertEqual(record.status, .queued)
        XCTAssertEqual(record.background, .review)
        XCTAssertEqual(record.automationID, Automation.backgroundID)
        XCTAssertEqual(record.head, "abc1234")
        let id = try XCTUnwrap(record.runID)
        XCTAssertEqual(queued.output, "Queued Review in Background · octo-org/widgets #7 (run \(id.prefix(8))). PullPing starts it within 30 seconds; pullping background list shows it, pullping drafts shows the result.")
        XCTAssertEqual(run(["background", "run", "review", "--pr", "octo-org/widgets#7"]).error, "pullping: Review in Background is already running on this pull request")
        XCTAssertEqual(run(["background", "run", "review", "--pr", "octo-org/widgets#8"]).error, "pullping: Review in Background is for others' pull requests")
        XCTAssertEqual(run(["background", "run", "summarize", "--pr", "octo-org/widgets#8"]).status, 0)
        XCTAssertEqual(run(["background", "run", "review", "--pr", "octo-org/widgets#99"]).error, "pullping: PullPing is not tracking octo-org/widgets #99 yet")
        XCTAssertEqual(run(["background", "run", "explain", "--pr", "octo-org/widgets#7"]).status, 2)
        XCTAssertEqual(run(["background", "run", "review"]).status, 2)
        XCTAssertTrue(run(["background", "list"]).output.contains("queued       \(id.prefix(8))  Review in Background · octo-org/widgets #7"), run(["background", "list"]).output)
        XCTAssertEqual(run(["background", "cancel", String(id.prefix(6))]).output, "Cancelled Review in Background · octo-org/widgets #7.")
        XCTAssertEqual(runs.first { $0.runID == id }?.status, .cancelled)
        XCTAssertEqual(run(["background", "cancel", String(id.prefix(6))]).error, "pullping: Review in Background · octo-org/widgets #7 is cancelled already")
        XCTAssertEqual(run(["background", "cancel", "zzzz"]).status, 1)
        XCTAssertEqual(run(["background", "cancel", "ab"]).status, 2)
    }

    func testDryRunWritesNothing() throws {
        run(["background", "on"])
        let result = run(["background", "run", "review", "--pr", "octo-org/widgets#7", "--dry-run"])
        XCTAssertEqual(result.status, 0, result.error)
        XCTAssertTrue(result.output.contains("(not cloned here: the diff and discussion only)"), result.output)
        XCTAssertTrue(result.output.contains("command      \\claude -p --session-id '"), result.output)
        XCTAssertTrue(result.output.contains("--restricted --tools 'Read,Grep,Glob' --disallowedTools 'mcp__*' --strict-mcp-config"), result.output)
        XCTAssertTrue(result.output.contains("  You run unattended on octo-org/widgets #7"), result.output)
        XCTAssertTrue(result.output.contains(Scenario.review.builtIn), result.output)
        XCTAssertEqual(runs.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("runs").path), "a dry run creates no folder")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(run(["background", "run", "summarize", "--pr", "octo-org/widgets#7", "--dry-run", "--json"]).output.utf8)) as? [String: Any])
        XCTAssertEqual(json["notCloned"] as? Bool, true)
        XCTAssertTrue((json["prompt"] as? String ?? "").contains(BackgroundPlanner.summarizeTask))
    }

    func testRuleBackgroundOption() throws {
        let added = run(["rule", "add", "--name", "Draft reviews", "--on", "reviewRequested", "--scope", "others", "--background", "review"])
        XCTAssertEqual(added.status, 0, added.error)
        let rule = try XCTUnwrap(store.load().automations.last)
        XCTAssertEqual(rule.background, .review)
        XCTAssertTrue(added.output.contains("→ claude reviews in the background (a draft), ask"), added.output)
        XCTAssertTrue(run(["rule", "show", String(rule.id.uuidString.prefix(8))]).output.contains("background      review"))
        XCTAssertTrue(run(["rule", "list"]).output.contains("background review"))
        XCTAssertEqual(run(["rule", "edit", String(rule.id.uuidString.prefix(8)), "--background", "off"]).status, 0)
        XCTAssertNil(store.load().automations.last?.background)
        XCTAssertEqual(run(["rule", "add", "--name", "x", "--on", "comment", "--background", "post"]).status, 2)
        XCTAssertEqual(run(["hook", "add", "--pr", "octo-org/widgets#7", "--on", "comment", "--prompt", "p", "--background", "review"]).error,
                       "pullping: --background is for rules only: a hook always opens a session\nRun `pullping hook --help` for usage.")
    }

    func testDraftsListShowDiscard() throws {
        let runID = "0f3c1234-5678-4abc-8def-0123456789ab"
        let draft = BackgroundDraft(runID: runID, action: .review, prID: "PR_7", repo: "octo-org/widgets", number: 7,
                                    url: URL(string: "https://github.com/octo-org/widgets/pull/7")!, title: "Add cache", accountID: UUID(), login: "dana",
                                    head: "abc1234", agent: .claude, sessionID: runID, cwd: "/tmp", notCloned: true, createdAt: t0,
                                    summary: "Retry loop has no cap.", verdict: .requestChanges, body: "## Findings\nNo cap.")
        let url = try XCTUnwrap(BackgroundDraft.url(runID: runID, runsDir: try XCTUnwrap(store.runsDirectory)))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AutomationStore.encoder.encode(draft).write(to: url)
        var record = RunRecord.background(.review, pr: tracked.prs["PR_7"]!, rule: nil, eventID: "manual:x", runID: runID, at: t0)
        (record.status, record.draft) = (.done, url.path)
        store.mutate { $0.runs.append(record) }
        XCTAssertEqual(run(["drafts", "list"]).output, "\(AutomationCLI.stamp(t0))  0f3c1234  octo-org/widgets #7  review draft  suggests request changes  Retry loop has no cap.")
        let shown = run(["drafts", "show", "0f3c"]).output
        XCTAssertTrue(shown.contains("verdict         request changes"), shown)
        XCTAssertTrue(shown.hasSuffix("body:\n  ## Findings\n  No cap."), shown)
        XCTAssertEqual(try StateStore.decoder.decode(BackgroundDraft.self, from: Data(run(["drafts", "show", "0f3c", "--json"]).output.utf8)), draft)
        XCTAssertEqual(run(["drafts", "discard", "0f3c"]).output, "Discarded the review draft of Review in Background · octo-org/widgets #7.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(runs.last?.draft)
        XCTAssertEqual(ActivityLog.read(URL(fileURLWithPath: env["PULLPING_ACTIVITY"]!)).last?.what, "Discarded: Review in Background")
        XCTAssertEqual(run(["drafts", "list"]).output, "No drafts.")
        XCTAssertEqual(run(["drafts", "show", "0f3c"]).status, 1)
    }

    func testHelpAndStatus() throws {
        XCTAssertTrue(AutomationCLI.help.contains("pullping session set"), "the external helper greps for it")
        XCTAssertTrue(run(["background", "--help"]).output.contains("no command posts"))
        XCTAssertTrue(run(["drafts"]).output.contains("No command posts."))
        let status = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(run(["setup", "status", "--json"]).output.utf8)) as? [String: Any])
        XCTAssertEqual((status["background"] as? [String: Any])?["enabled"] as? Bool, false)
    }
}
