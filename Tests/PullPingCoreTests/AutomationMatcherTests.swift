import XCTest
@testable import PullPingCore

final class AutomationMatcherTests: XCTestCase {
    let account = Account(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, login: me)

    func pr(_ id: String = "PR_1", repo: String = "octo-org/widgets", number: Int = 12, mine: Bool = true) -> TrackedPR {
        var pr = TrackedPR(id: id, accountID: account.id, firstTrackedAt: t0)
        pr.repo = repo
        pr.number = number
        pr.roles = mine ? [.author] : [.reviewRequested]
        return pr
    }

    func event(_ id: String = "IC_1", prID: String = "PR_1", _ kind: EventKind = .comment, by actor: String = "alice",
               at: Date = t0.addingTimeInterval(60), own: Bool = false) -> PREvent {
        PREvent(id: id, prID: prID, kind: kind, actor: actor, at: at, summary: "", url: nil, isOwn: own)
    }

    func rule(_ kinds: Set<EventKind> = [.comment], mode: RunMode = .ask) -> Automation {
        var a = Automation(name: "Rule", kinds: kinds, workingDirectory: "/tmp", createdAt: t0)
        a.mode = mode
        return a
    }

    func hook(repo: String = "octo-org/widgets", number: Int = 12, _ kinds: Set<EventKind> = [.comment]) -> Automation {
        var a = rule(kinds)
        a.pr = PRRef(repo: repo, number: number)
        a.maxRunsPerPR = 1
        a.repos = ["other/*"]  // ignored on hooks
        a.scope = .others
        return a
    }

    func plan(_ events: [PREvent], _ prs: [TrackedPR], _ automations: [Automation], runs: [RunRecord] = [],
              enabled: Bool = true, paused: Bool = false, accounts: [Account]? = nil, now: Date = t0.addingTimeInterval(120)) -> (auto: [AutomationMatcher.Match], offers: [AutomationMatcher.Match]) {
        AutomationMatcher.plan(events: events, prs: Dictionary(uniqueKeysWithValues: prs.map { ($0.id, $0) }), automations: automations, runs: runs,
                               settingsEnabled: enabled, paused: paused, accounts: accounts ?? [account], now: now)
    }

    func testKinds() {
        XCTAssertTrue(AutomationMatcher.matches(rule([.comment]), pr: pr(), event: event(), me: me))
        XCTAssertFalse(AutomationMatcher.matches(rule([.ciFailed]), pr: pr(), event: event(), me: me))
        var off = rule([.comment])
        off.enabled = false
        XCTAssertFalse(AutomationMatcher.matches(off, pr: pr(), event: event(), me: me))
    }

    func testScope() {
        var a = rule()
        for (scope, mine, expected) in [(AutomationScope.any, true, true), (.any, false, true), (.mine, true, true), (.mine, false, false),
                                        (.others, true, false), (.others, false, true)] {
            a.scope = scope
            XCTAssertEqual(AutomationMatcher.matches(a, pr: pr(mine: mine), event: event(), me: me), expected, "\(scope) mine=\(mine)")
        }
    }

    func testRepos() {
        XCTAssertTrue(AutomationMatcher.repoMatches("octo-org/widgets", "octo-org/widgets"))
        XCTAssertTrue(AutomationMatcher.repoMatches("Octo-Org/Widgets", "octo-org/widgets"))
        XCTAssertTrue(AutomationMatcher.repoMatches("octo-org/*", "Octo-Org/gadgets"))
        XCTAssertFalse(AutomationMatcher.repoMatches("octo-org/*", "octo-organization/widgets"))
        XCTAssertFalse(AutomationMatcher.repoMatches("octo-org/widget", "octo-org/widgets"))
        var a = rule()
        a.repos = ["other/thing", "octo-org/*"]
        XCTAssertTrue(AutomationMatcher.matches(a, pr: pr(), event: event(), me: me))
        a.repos = ["other/thing"]
        XCTAssertFalse(AutomationMatcher.matches(a, pr: pr(), event: event(), me: me))
    }

    func testActors() {
        var a = rule()
        a.actors = ["Alice"]
        XCTAssertTrue(AutomationMatcher.matches(a, pr: pr(), event: event(by: "alice"), me: me))
        XCTAssertFalse(AutomationMatcher.matches(a, pr: pr(), event: event(by: "mallory"), me: me))
    }

    func testHooksMatchByRepoAndNumberOnly() {
        XCTAssertTrue(AutomationMatcher.matches(hook(repo: "OCTO-ORG/widgets"), pr: pr(mine: true), event: event(), me: me))
        XCTAssertFalse(AutomationMatcher.matches(hook(number: 13), pr: pr(), event: event(), me: me))
        XCTAssertFalse(AutomationMatcher.matches(hook(repo: "octo-org/gadgets"), pr: pr(), event: event(), me: me))
        XCTAssertEqual(AutomationMatcher.applicable([rule(), hook(), hook(number: 13)], pr: pr()).count, 2)
    }

    func testOwnEvents() {
        let p = pr()
        XCTAssertFalse(AutomationMatcher.eligible(event("E", .comment, by: me, own: true), pr: p, me: me))  // my comment never triggers
        XCTAssertFalse(AutomationMatcher.eligible(event("E", .newCommits, by: me, own: true), pr: p, me: me))  // agent pushes as me
        XCTAssertTrue(AutomationMatcher.eligible(event("E", .merged, by: "DANA", own: true), pr: p, me: me))  // I merged it after tracking began
        XCTAssertFalse(AutomationMatcher.eligible(event("E", .merged, by: me, at: t0.addingTimeInterval(-60), own: true), pr: p, me: me))  // seeded history
        XCTAssertFalse(AutomationMatcher.eligible(event("E", .merged, by: "alice", own: true), pr: p, me: me))  // seeded merge by someone else
        XCTAssertTrue(AutomationMatcher.eligible(event("E", .merged, by: "alice"), pr: p, me: me))
        XCTAssertTrue(plan([event("E", .merged, by: me, own: true)], [p], [rule([.merged], mode: .auto)]).auto.count == 1)
    }

    func testDuplicateCooldownAndMaxRuns() {
        let a = rule(mode: .auto), now = t0.addingTimeInterval(3600)
        func record(_ eventID: String, minutesAgo: Double, ok: Bool = true) -> RunRecord {
            RunRecord(automationID: a.id, prID: "PR_1", eventID: eventID, at: now.addingTimeInterval(-minutesAgo * 60), ok: ok, detail: "")
        }
        XCTAssertNil(AutomationMatcher.blocked(a, prID: "PR_1", eventID: "e", runs: [], now: now))
        XCTAssertNotNil(AutomationMatcher.blocked(a, prID: "PR_1", eventID: "e", runs: [record("e", minutesAgo: 60)], now: now))
        XCTAssertNotNil(AutomationMatcher.blocked(a, prID: "PR_1", eventID: "e", runs: [record("e", minutesAgo: 60)], now: now, manual: true))
        XCTAssertNotNil(AutomationMatcher.blocked(a, prID: "PR_1", eventID: "e2", runs: [record("e", minutesAgo: 5)], now: now))
        XCTAssertNil(AutomationMatcher.blocked(a, prID: "PR_1", eventID: "e2", runs: [record("e", minutesAgo: 5)], now: now, manual: true))
        XCTAssertNil(AutomationMatcher.blocked(a, prID: "PR_1", eventID: "e2", runs: [record("e", minutesAgo: 11)], now: now))
        XCTAssertNil(AutomationMatcher.blocked(a, prID: "PR_2", eventID: "e2", runs: [record("e", minutesAgo: 5)], now: now))  // per pull request
        let three = [record("a", minutesAgo: 60), record("b", minutesAgo: 50), record("c", minutesAgo: 40)]
        XCTAssertNotNil(AutomationMatcher.blocked(a, prID: "PR_1", eventID: "d", runs: three, now: now, manual: true))
        let failed = three.map { var r = $0; r.ok = false; return r }  // only successful runs count toward maxRuns
        XCTAssertNil(AutomationMatcher.blocked(a, prID: "PR_1", eventID: "d", runs: Array(failed.prefix(2)), now: now))
        XCTAssertEqual(AutomationMatcher.blocked(a, prID: "PR_1", eventID: "d", runs: failed, now: now), "Failed 3 times on this pull request")
        XCTAssertNil(AutomationMatcher.blocked(a, prID: "PR_1", eventID: "d", runs: failed, now: now, manual: true))  // Run still works
        XCTAssertEqual(AutomationMatcher.blocked(a, prID: "PR_1", eventID: "e2", runs: [record("e", minutesAgo: 5)], now: now), "Ran less than 10 minutes ago")
    }

    /// The head commit's author can't tell an agent's own push from someone else's: after a run, new commits only offer.
    func testNewCommitsAfterARunOnlyOffer() {
        let a = rule([.newCommits, .comment], mode: .auto), later = t0.addingTimeInterval(3600)
        let ran = RunRecord(automationID: a.id, prID: "PR_1", eventID: "old", at: t0, ok: true, detail: "")
        let push = event("head:abc", .newCommits, by: "Roy Padina", at: later)
        XCTAssertEqual(plan([push], [pr()], [a], now: later).auto.count, 1)  // never ran here: automatic
        let result = plan([push], [pr()], [a], runs: [ran], now: later)
        XCTAssertTrue(result.auto.isEmpty)
        XCTAssertEqual(result.offers.map(\.event.id), ["head:abc"])
        var failed = ran
        failed.ok = false  // nothing was started, so no agent pushed
        XCTAssertEqual(plan([push], [pr()], [a], runs: [failed], now: later).auto.count, 1)
        XCTAssertEqual(plan([event(at: later)], [pr()], [a], runs: [ran], now: later).auto.count, 1)  // other kinds stay automatic
    }

    func testCurrentIsTheSavedEnabledUnexpiredAutomation() {
        var a = rule()
        a.prompt = "edited"
        XCTAssertEqual(AutomationMatcher.current(a.id, in: [rule(), a], now: t0)?.prompt, "edited")
        XCTAssertNil(AutomationMatcher.current(a.id, in: [rule()], now: t0))  // removed
        var off = a
        off.enabled = false
        XCTAssertNil(AutomationMatcher.current(a.id, in: [off], now: t0))
        var expired = hook()
        expired.expiresAt = t0
        XCTAssertNil(AutomationMatcher.current(expired.id, in: [expired], now: t0))
        expired.expiresAt = t0.addingTimeInterval(60)
        XCTAssertNotNil(AutomationMatcher.current(expired.id, in: [expired], now: t0))
    }

    func testBudgetDegradesFourthAutoMatchToOffer() {
        let prs = (1...4).map { pr("PR_\($0)", number: $0) }
        let events = (1...4).map { event("IC_\($0)", prID: "PR_\($0)") }
        let result = plan(events, prs, [rule(mode: .auto)])
        XCTAssertEqual(result.auto.count, 3)
        XCTAssertEqual(result.offers.count, 1)
    }

    func testOneMatchPerAutomationAndPullRequest() {
        let result = plan([event("IC_1"), event("IC_2", at: t0.addingTimeInterval(90))], [pr()], [rule(mode: .auto)])
        XCTAssertEqual(result.auto.map(\.event.id), ["IC_2"])  // the newest
        XCTAssertTrue(result.offers.isEmpty)
    }

    func testAskModeOffersAndSkipsCooldown() {
        let a = rule()
        let recent = RunRecord(automationID: a.id, prID: "PR_1", eventID: "old", at: t0.addingTimeInterval(100), ok: true, detail: "")
        let result = plan([event()], [pr()], [a], runs: [recent])
        XCTAssertEqual(result.offers.count, 1)
        XCTAssertTrue(result.auto.isEmpty)
    }

    func testGatesSkip() {
        let a = rule(mode: .auto), e = [event()]
        XCTAssertEqual(plan(e, [pr()], [a]).auto.count, 1)
        XCTAssertTrue(plan(e, [pr()], [a], enabled: false).auto.isEmpty)
        XCTAssertTrue(plan(e, [pr()], [a], paused: true).auto.isEmpty)
        var muted = pr(), hidden = pr(), snoozed = pr()
        muted.muted = true
        hidden.hidden = true
        snoozed.snoozedUntil = t0.addingTimeInterval(3600)
        for p in [muted, hidden, snoozed] { XCTAssertTrue(plan(e, [p], [a]).auto.isEmpty) }
        var disabledAccount = account
        disabledAccount.enabled = false
        XCTAssertTrue(plan(e, [pr()], [a], accounts: [disabledAccount]).auto.isEmpty)
        XCTAssertTrue(plan(e, [pr()], [a], accounts: []).auto.isEmpty)
        var expired = hook()
        expired.mode = .auto
        expired.expiresAt = t0
        XCTAssertTrue(plan(e, [pr()], [expired]).auto.isEmpty)
    }

    // MARK: Linked sessions

    func testLinkedSessionNeedsALink() {
        var linkedRule = rule(), linkedHook = hook()
        linkedRule.sessionID = Automation.linkedSession
        linkedHook.sessionID = Automation.linkedSession
        let plain = rule()
        let link = SessionLink(pr: PRRef(repo: "Octo-Org/Widgets", number: 12), agent: .claude, sessionID: "s1", cwd: "/tmp", setAt: t0, source: "cli", by: "")
        let all = [linkedRule, linkedHook, plain]
        XCTAssertEqual(plan([event()], [pr()], all).offers.map(\.automation.id), [plain.id])  // no link: only the plain rule
        XCTAssertEqual(AutomationMatcher.applicable(all, pr: pr()).map(\.id), [plain.id])
        let linked = AutomationMatcher.plan(events: [event()], prs: ["PR_1": pr()], automations: all, runs: [], settingsEnabled: true, paused: false,
                                            accounts: [account], now: t0.addingTimeInterval(120), sessions: [link])
        XCTAssertEqual(Set(linked.offers.map(\.automation.id)), Set(all.map(\.id)))
        XCTAssertEqual(AutomationMatcher.applicable(all, pr: pr(), sessions: [link]).count, 3)
        XCTAssertEqual(AutomationMatcher.applicable(all, pr: pr(number: 13), sessions: [link]).map(\.id), [plain.id])  // another pull request's link
    }

    /// Handle with Agent's buttons: a panel with one event of the handler's kinds; [] = every kind (files from before the choice).
    func testHandlerEvent() {
        var handler = Automation.defaultHandler()
        XCTAssertEqual(handler.handlerEvent(in: [event("a", .comment)])?.kind, .comment)
        XCTAssertNil(handler.handlerEvent(in: [event("a", .ciPassed)]))
        XCTAssertNil(handler.handlerEvent(in: []))
        XCTAssertEqual(handler.handlerEvent(in: [event("a", .comment), event("b", .ciPassed), event("c", .merged)])?.id, "a")  // the matching one
        XCTAssertEqual(handler.handlerEvent(in: [event("a", .comment), event("b", .ciFailed)])?.id, "b")  // the last matching one
        XCTAssertEqual(handler.handlerEvent(in: [event("a", .reviewReminder)])?.kind, .reviewReminder)  // follows reviewRequested
        handler.kinds = [.ciFailed]
        XCTAssertNil(handler.handlerEvent(in: [event("a", .comment), event("b", .reviewReminder)]))
        handler.kinds = []
        XCTAssertEqual(handler.handlerEvent(in: [event("a", .ciPassed), event("b", .merged)])?.id, "b")
    }
}
