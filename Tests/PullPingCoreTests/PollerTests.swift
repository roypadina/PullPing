import XCTest
@testable import PullPingCore

final class PollerTests: XCTestCase {
    let account = Account(login: "dana")
    let github = FakeGitHub()
    let clock = Clock()
    var store = StateStore(url: nil)

    func poller(_ transport: GraphQLTransport? = nil, trackIssues: Bool = true) -> Poller {
        let clock = clock
        var settings = AppSettings()
        settings.trackIssues = trackIssues
        return Poller(transport: transport ?? github.transport, tokenProvider: { _ in "test-token" }, state: store, settings: { settings }, now: { clock.now })
    }

    /// PR_1: mine, CI pending. PR_2: bob's, requests my review.
    func seed() {
        github.prs["PR_1"] = .init(updatedAt: t0, node: prNode("PR_1", number: 1, updatedAt: t0, ci: "PENDING"))
        github.prs["PR_2"] = .init(updatedAt: t0, node: prNode("PR_2", number: 2, author: "bob", updatedAt: t0, requested: [me]))
        github.involved = ["PR_1", "PR_2"]
        github.requested = ["PR_2"]
    }

    func polled(_ poller: Poller) async throws -> AccountResult {
        let result = await poller.poll(account: account)
        return try XCTUnwrap(result)
    }

    func refreshedIDs() -> [[String]] {
        github.transport.requests.map(FakeTransport.operation).filter { $0.name == "Refresh" }.map { $0.variables["ids"] as! [String] }
    }

    func testBaselineThenIncrementalPoll() async throws {
        seed()
        let poller = poller()
        let first = try await polled(poller)
        XCTAssertEqual(first.status, .ok)
        XCTAssertTrue(first.stats.baseline)
        XCTAssertTrue(first.events.isEmpty)  // first sync is silent, even the review request
        XCTAssertEqual([first.stats.changed, first.stats.new, first.stats.batches, first.stats.refreshed], [2, 2, 1, 2])
        XCTAssertEqual(store.state.prs["PR_2"]?.roles, [.reviewRequested])
        XCTAssertEqual(store.state.prs["PR_1"]?.lastReadAt, t0)  // baseline = read
        XCTAssertEqual(Attention.group(store.state.prs["PR_2"]!), .toReview)

        // alice comments on PR_2; PR_1 is unchanged but its CI is still pending.
        clock.now = t0.addingTimeInterval(180)
        let comment = #"{ "__typename": "IssueComment", "id": "IC_1", "createdAt": "\#(iso(t0.addingTimeInterval(100)))", "url": null, "body": "Ready?", "author": { "login": "alice" } }"#
        github.prs["PR_2"] = .init(updatedAt: t0.addingTimeInterval(100),
                                   node: prNode("PR_2", number: 2, author: "bob", updatedAt: t0.addingTimeInterval(100), requested: [me], timeline: comment))
        let report = await poller.pollAll(accounts: [account], reason: .timer)
        let result = try XCTUnwrap(report.results[account.id])
        XCTAssertFalse(result.stats.baseline)
        XCTAssertEqual(result.stats.tracked, 2)
        XCTAssertEqual(report.events.map(\.id), ["IC_1"])
        XCTAssertEqual(report.events.first?.prID, "PR_2")
        XCTAssertEqual(refreshedIDs().last, ["PR_1", "PR_2"])
        let since = FakeTransport.operation(github.transport.requests.last!).variables["since"] as? String
        XCTAssertEqual(since, iso(t0.addingTimeInterval(-60)))  // min watermark − 60 s
        XCTAssertEqual(Attention.unread(store.state.prs["PR_2"]!), 1)
    }

    /// CI completion does not bump updatedAt: a stored pending CI keeps the PR in the changed set.
    func testPendingCIIsRefreshedUntilItSettles() async throws {
        seed()
        let poller = poller()
        _ = await poller.poll(account: account)
        github.prs["PR_1"]?.node = prNode("PR_1", number: 1, updatedAt: t0, ci: "SUCCESS")
        let second = try await polled(poller)
        XCTAssertEqual(second.stats.changed, 1)
        XCTAssertEqual(second.events.map(\.kind), [.ciPassed])
        XCTAssertEqual(second.events.first?.id, "ci:aaa1111:success")
        let third = try await polled(poller)
        XCTAssertEqual(third.stats.changed, 0)
        XCTAssertEqual(third.stats.batches, 0)
    }

    /// The search index lags the PR: a team request found by the requested search later, with no PR update, still lands.
    func testTeamRequestFoundByALaggingSearchIsRefreshed() async throws {
        github.prs["PR_3"] = .init(updatedAt: t0, node: prNode("PR_3", number: 3, author: "bob", updatedAt: t0, teams: ["core"]))
        github.involved = ["PR_3"]
        let poller = poller()
        _ = await poller.poll(account: account)
        XCTAssertFalse(store.state.prs["PR_3"]!.roles.contains(.teamReviewRequested))

        clock.now = t0.addingTimeInterval(180)
        github.requested = ["PR_3"]
        let caughtUp = try await polled(poller)
        XCTAssertEqual(refreshedIDs().last, ["PR_3"])
        XCTAssertEqual(caughtUp.events.map(\.summary), ["via team core"])
        XCTAssertTrue(store.state.prs["PR_3"]!.roles.contains(.teamReviewRequested))
        let steady = try await polled(poller)
        XCTAssertEqual(steady.stats.batches, 0)

        github.requested = []  // request gone from the search: the role follows
        _ = try await polled(poller)
        XCTAssertFalse(store.state.prs["PR_3"]!.roles.contains(.teamReviewRequested))
    }

    func testTrackedPRsMissingFromSearchAreStampedOrDropped() async throws {
        seed()
        let poller = poller()
        _ = await poller.poll(account: account)
        // PR_1 merged (left the open search), PR_2 deleted.
        github.involved = []
        github.requested = []
        github.prs["PR_1"] = .init(updatedAt: t0.addingTimeInterval(50), state: "MERGED",
                                   node: prNode("PR_1", number: 1, updatedAt: t0.addingTimeInterval(50), state: "MERGED"))
        github.prs["PR_2"] = nil
        let result = try await polled(poller)
        XCTAssertEqual(result.stats.dropped, 1)
        XCTAssertEqual(Set(store.state.prs.keys), ["PR_1"])
        XCTAssertEqual(store.state.prs["PR_1"]?.state, .merged)
        XCTAssertEqual(store.state.prs["PR_1"]?.closedAt, t0.addingTimeInterval(50))
    }

    func testIgnoredPRsAreNotTracked() async {
        seed()
        store.update { $0.ignoredIDs = ["PR_2"] }
        _ = await poller().poll(account: account)
        XCTAssertEqual(Set(store.state.prs.keys), ["PR_1"])
    }

    func testBusyAccountIsSkipped() async throws {
        seed()
        let slow = FakeTransport(delay: 300_000_000) { [github] in github.reply($0) }
        let poller = poller(slow)
        let first = Task { await poller.poll(account: account) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let skipped = await poller.poll(account: account)
        XCTAssertNil(skipped)
        let finished = await first.value
        XCTAssertNotNil(finished)
    }

    func testFailureBacksOffTimerPolls() async {
        XCTAssertEqual(Poller.backoff(failures: 1, interval: 180), 360)
        XCTAssertEqual(Poller.backoff(failures: 2, interval: 180), 720)
        XCTAssertEqual(Poller.backoff(failures: 9, interval: 180), 1800)

        seed()
        github.failing = true
        let poller = poller()
        let failed = await poller.pollAll(accounts: [account], reason: .timer)
        XCTAssertEqual(failed.results[account.id]?.status, .failed("HTTP 500"))
        clock.now = t0.addingTimeInterval(300)  // inside the 360 s backoff
        let skipped = await poller.pollAll(accounts: [account], reason: .timer)
        XCTAssertTrue(skipped.results.isEmpty)
        github.failing = false
        let manual = await poller.pollAll(accounts: [account], reason: .manual)
        XCTAssertEqual(manual.results[account.id]?.status, .ok)
        let tooSoon = await poller.pollAll(accounts: [account], reason: .manual)
        XCTAssertTrue(tooSoon.results.isEmpty)  // manual refresh at most every 10 s
    }

    func testLowRateLimitSkipsRefresh() async throws {
        seed()
        github.remaining = 120
        let result = try await polled(poller())
        XCTAssertEqual(result.status, .rateLimited(resetAt: t0.addingTimeInterval(3600)))
        XCTAssertTrue(refreshedIDs().isEmpty)
    }

    func testDisabledAccountsAndMissingTokens() async {
        seed()
        var disabled = account
        disabled.enabled = false
        let none = await poller().pollAll(accounts: [disabled], reason: .manual)
        XCTAssertTrue(none.results.isEmpty)
        let noToken = Poller(transport: github.transport, tokenProvider: { _ in nil }, state: store, settings: { AppSettings() })
        let result = await noToken.poll(account: account)
        XCTAssertEqual(result?.status, .badToken)
    }

    /// I_1: carol's issue, assigned to me and mentioning me in its body (loud if it weren't a baseline).
    func seedIssue(updatedAt: Date = t0, timeline: String = "") {
        github.prs["I_1"] = .init(updatedAt: updatedAt, node: issueNode("I_1", number: 9, author: "carol", updatedAt: updatedAt, assignees: [me],
                                                                         body: "cc @dana", timeline: timeline), issue: true)
        github.issues = ["I_1"]
    }

    func comment(_ id: String, at: Date) -> String {
        #"{ "__typename": "IssueComment", "id": "\#(id)", "createdAt": "\#(iso(at))", "url": null, "body": "Any news?", "author": { "login": "alice" } }"#
    }

    func testUpgradeFirstPollWithIssuesIsSilentThenTheSwitchDropsThem() async throws {
        seed()
        _ = try await polled(poller())
        store.update { $0.baselinedIssueAccounts = nil }  // state written by 0.3.0
        seedIssue()
        clock.now = t0.addingTimeInterval(180)
        let upgrade = try await polled(poller())
        XCTAssertFalse(upgrade.stats.baseline)
        XCTAssertEqual(upgrade.stats.issues, 1)
        XCTAssertTrue(upgrade.events.isEmpty)  // assignment and body mention stay quiet on the issue baseline
        let issue = try XCTUnwrap(store.state.prs["I_1"])
        XCTAssertTrue(issue.isIssue)
        XCTAssertEqual(issue.lastReadAt, clock.now)
        XCTAssertNil(Attention.needReason(issue))
        XCTAssertEqual(store.state.baselinedIssueAccounts, [account.id])

        // A new comment on the issue notifies.
        clock.now = t0.addingTimeInterval(360)
        seedIssue(updatedAt: t0.addingTimeInterval(300), timeline: comment("IC_9", at: t0.addingTimeInterval(300)))
        let next = try await polled(poller())
        XCTAssertEqual(next.events.map(\.kind), [.comment])
        XCTAssertEqual(Attention.needReason(store.state.prs["I_1"]!), .newComments)  // assigned to me

        // Track Issues off: not searched, not refreshed, dropped, baseline forgotten.
        clock.now = t0.addingTimeInterval(540)
        let sent = github.transport.requests.count
        let off = try await polled(poller(trackIssues: false))
        XCTAssertTrue(off.events.isEmpty)
        XCTAssertNil(store.state.prs["I_1"])
        XCTAssertNotNil(store.state.prs["PR_1"])
        XCTAssertEqual(store.state.baselinedIssueAccounts, [])
        let offRequests = github.transport.requests[sent...].map(FakeTransport.operation)
        XCTAssertEqual(offRequests.first?.variables["withIssues"] as? Bool, false)
        XCTAssertFalse(offRequests.contains { ($0.variables["ids"] as? [String])?.contains("I_1") == true })  // neither stamped nor refreshed

        // On again: back, silently.
        clock.now = t0.addingTimeInterval(720)
        let on = try await polled(poller())
        XCTAssertTrue(on.events.isEmpty)
        XCTAssertNotNil(store.state.prs["I_1"])
        XCTAssertEqual(store.state.baselinedIssueAccounts, [account.id])
    }

    func testNewAccountBaselinesIssuesWithPullRequests() async throws {
        seed()
        seedIssue()
        let first = try await polled(poller())
        XCTAssertTrue(first.stats.baseline)
        XCTAssertTrue(first.events.isEmpty)
        XCTAssertEqual(store.state.baselinedIssueAccounts, [account.id])
        clock.now = t0.addingTimeInterval(180)
        seedIssue(updatedAt: t0.addingTimeInterval(100), timeline: comment("IC_9", at: t0.addingTimeInterval(100)))
        let next = try await polled(poller())
        XCTAssertEqual(next.events.map(\.kind), [.comment])
    }
}
