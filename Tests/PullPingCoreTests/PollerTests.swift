import XCTest
@testable import PullPingCore

final class PollerTests: XCTestCase {
    let account = Account(login: "dana")
    let github = FakeGitHub()
    let clock = Clock()
    var store = StateStore(url: nil)

    func poller(_ transport: GraphQLTransport? = nil, trackIssues: Bool = true, owned: Bool = true, watch: [String] = [], exclude: [String] = []) -> Poller {
        let clock = clock
        var settings = AppSettings()
        settings.trackIssues = trackIssues
        (settings.watchOwnedIssues, settings.watchedIssueRepos, settings.excludedIssueRepos) = (owned, watch, exclude)
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
        XCTAssertEqual(Attention.bucket(store.state.prs["PR_2"]!), .review)

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

    /// mergeStateStatus is computed lazily after a push and resolving it doesn't bump updatedAt: my PR stays in the changed
    /// set while UNKNOWN; someone else's doesn't.
    func testUnknownMergeStateIsRefreshedUntilItResolves() async throws {
        github.prs["PR_1"] = .init(updatedAt: t0, node: prNode("PR_1", number: 1, updatedAt: t0, mergeState: "UNKNOWN"))
        github.prs["PR_2"] = .init(updatedAt: t0, node: prNode("PR_2", number: 2, author: "bob", updatedAt: t0, mergeState: "UNKNOWN"))
        github.involved = ["PR_1", "PR_2"]
        let poller = poller()
        _ = await poller.poll(account: account)
        github.prs["PR_1"]?.node = prNode("PR_1", number: 1, updatedAt: t0, mergeState: "DIRTY")
        let second = try await polled(poller)
        XCTAssertEqual(refreshedIDs().last, ["PR_1"])
        XCTAssertEqual(store.state.prs["PR_1"]?.mergeState, "DIRTY")
        XCTAssertEqual(second.events.map(\.kind), [.conflicts])
        let third = try await polled(poller)
        XCTAssertEqual(third.stats.batches, 0)
    }

    /// State from 0.6.1 has no `autoMerge` / `myReview`: every open pull request is refreshed once, issues aren't.
    func testPullRequestsFromBefore070AreRefreshedOnce() async throws {
        seed()
        github.prs["PR_1"]?.node = prNode("PR_1", number: 1, updatedAt: t0)  // CI settled: only the backfill refreshes it
        github.prs["I_1"] = .init(updatedAt: t0, node: issueNode("I_1", number: 3, updatedAt: t0, assignees: [me]), issue: true)
        github.issues = ["I_1"]
        let poller = poller()
        _ = await poller.poll(account: account)
        XCTAssertEqual(store.state.prs["PR_1"]?.autoMerge, false)
        XCTAssertNil(store.state.prs["I_1"]?.autoMerge)
        store.update { state in for id in state.prs.keys { state.prs[id]?.autoMerge = nil } }  // as written by 0.6.1

        let backfill = try await polled(poller)
        XCTAssertEqual(refreshedIDs().last, ["PR_1", "PR_2"])
        XCTAssertEqual(backfill.events, [])
        XCTAssertEqual(store.state.prs["PR_2"]?.autoMerge, false)
        let steady = try await polled(poller)
        XCTAssertEqual(steady.stats.batches, 0)
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

    /// `ok` = what `saveTokens` answers (false: keychain write failed or account removed).
    final class Saved: @unchecked Sendable { var tokens: [OAuthTokens] = []; var ok = true }

    /// GitHub rejects the `rejected` tokens (expired); the refresh endpoint answers `refreshReply`, or throws `refreshError`.
    func expiringTransport(_ refreshReply: String, rejected: Set<String> = ["bearer gho_old"], refreshError: URLError? = nil) -> FakeTransport {
        let github = github
        return FakeTransport { request in
            if request.url?.host == "github.com" {
                if let refreshError { throw refreshError }
                return (200, [:], Data(refreshReply.utf8))
            }
            if rejected.contains(request.value(forHTTPHeaderField: "Authorization") ?? "") { return (401, [:], Data(#"{"message":"Bad credentials"}"#.utf8)) }
            return github.reply(request)
        }
    }

    func expiringPoller(_ transport: FakeTransport, saved: Saved) -> Poller {
        Poller(transport: transport, tokenProvider: { _ in "gho_old" }, refreshToken: { _ in "ghr_old" },
               saveTokens: { saved.tokens.append($1); return saved.ok }, state: store, settings: { AppSettings() })
    }

    func testExpiredSignInTokenIsRefreshedOnceAndThePollRetried() async throws {
        seed()
        let saved = Saved()
        let fake = expiringTransport(#"{"access_token":"gho_new","refresh_token":"ghr_new","expires_in":28800}"#)
        let result = try await polled(expiringPoller(fake, saved: saved))
        XCTAssertEqual(result.status, .ok)
        XCTAssertEqual(result.stats.refreshed, 2)
        XCTAssertEqual(saved.tokens, [OAuthTokens(access: "gho_new", refresh: "ghr_new")])
        let refreshes = fake.requests.filter { $0.url?.host == "github.com" }
        XCTAssertEqual(refreshes.count, 1)
        XCTAssertTrue(String(decoding: refreshes[0].httpBody!, as: UTF8.self).contains("refresh_token=ghr_old"))
        XCTAssertEqual(fake.requests.last?.value(forHTTPHeaderField: "Authorization"), "bearer gho_new")
    }

    /// Any other GitHub error: keep the refresh token, stay "Token rejected".
    func testFailedRefreshKeepsBadToken() async throws {
        seed()
        let saved = Saved()
        let fake = expiringTransport(#"{"error":"unsupported_grant_type"}"#)
        let result = try await polled(expiringPoller(fake, saved: saved))
        XCTAssertEqual(result.status, .badToken)
        XCTAssertTrue(saved.tokens.isEmpty)
        XCTAssertEqual(fake.requests.filter { $0.url?.host == "github.com" }.count, 1)
        XCTAssertEqual(fake.requests.count, 2)  // one rejected poll, one refresh, no retry
    }

    /// A refresh token GitHub rejected is deleted (access token kept as is), so it is not re-sent every poll.
    func testRejectedRefreshTokenIsForgotten() async throws {
        seed()
        let saved = Saved()
        let fake = expiringTransport(#"{"error":"bad_refresh_token","error_description":"The refresh token passed is incorrect or expired."}"#)
        let result = try await polled(expiringPoller(fake, saved: saved))
        XCTAssertEqual(result.status, .badToken)
        XCTAssertEqual(saved.tokens, [OAuthTokens(access: "gho_old", refresh: "")])
        XCTAssertEqual(fake.requests.count, 2)  // no retry
    }

    /// The refresh request never got an answer: offline (not "Token rejected"), refresh token kept for the next poll.
    func testRefreshTransportErrorKeepsRefreshTokenAndReportsOffline() async throws {
        seed()
        let saved = Saved()
        let fake = expiringTransport("", refreshError: URLError(.timedOut))
        let result = try await polled(expiringPoller(fake, saved: saved))
        XCTAssertEqual(result.status, .offline)
        XCTAssertTrue(saved.tokens.isEmpty)
        XCTAssertEqual(fake.requests.filter { $0.url?.host == "github.com" }.count, 1)
        XCTAssertEqual(fake.requests.count, 2)
    }

    /// The refreshed token is rejected too: one refresh, one retry, then "Token rejected" — no loop.
    func testRetryAlsoRejectedRefreshesOnlyOnce() async throws {
        seed()
        let saved = Saved()
        let fake = expiringTransport(#"{"access_token":"gho_new","refresh_token":"ghr_new"}"#, rejected: ["bearer gho_old", "bearer gho_new"])
        let result = try await polled(expiringPoller(fake, saved: saved))
        XCTAssertEqual(result.status, .badToken)
        XCTAssertEqual(saved.tokens, [OAuthTokens(access: "gho_new", refresh: "ghr_new")])
        XCTAssertEqual(fake.requests.filter { $0.url?.host == "github.com" }.count, 1)
        XCTAssertEqual(fake.requests.count, 3)  // rejected poll, refresh, rejected retry
    }

    /// Tokens not saved (keychain write failed, or the account was removed meanwhile): reported, no retry poll.
    func testUnsavedRefreshSkipsTheRetry() async throws {
        seed()
        let saved = Saved()
        saved.ok = false
        let fake = expiringTransport(#"{"access_token":"gho_new","refresh_token":"ghr_new"}"#)
        let result = try await polled(expiringPoller(fake, saved: saved))
        XCTAssertEqual(result.status, .failed("Could not save the renewed GitHub sign-in to the keychain."))
        XCTAssertEqual(fake.requests.count, 2)
        XCTAssertFalse(fake.requests.contains { $0.value(forHTTPHeaderField: "Authorization") == "bearer gho_new" })
    }

    /// Personal access tokens (no refresh token): a 401 is final, nothing goes to github.com.
    func testBadTokenWithoutRefreshTokenIsNotRefreshed() async throws {
        let fake = expiringTransport("")
        let result = try await polled(Poller(transport: fake, tokenProvider: { _ in "gho_old" }, state: store, settings: { AppSettings() }))
        XCTAssertEqual(result.status, .badToken)
        XCTAssertEqual(fake.requests.count, 1)
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

    // MARK: Issues in my repositories

    /// alice's open issue in `repo`, created `created`, in the watched search.
    func watchedIssue(_ id: String, _ number: Int, repo: String = "dana/app", created: Date, updatedAt: Date = t0, author: String = "alice") {
        github.prs[id] = .init(updatedAt: updatedAt, node: issueNode(id, number: number, author: author, updatedAt: updatedAt, body: "It crashes.",
                                                                     repo: repo, createdAt: created), issue: true)
        if !github.watched.contains(id) { github.watched.append(id) }
    }

    func opened(_ result: AccountResult) -> [String] { result.events.filter { $0.kind == .issueOpened && !$0.isOwn }.map(\.prID) }

    /// An account baselined before the feature: open issues already there are listed, read and silent; a newer one notifies.
    func testUpgradeListsExistingIssuesSilentlyThenANewOneNotifies() async throws {
        seed()
        _ = try await polled(poller(owned: false))  // baselined (pull requests and issues) before watching
        for (i, id) in ["I_1", "I_2", "I_3"].enumerated() { watchedIssue(id, i + 1, created: t0.addingTimeInterval(-86_400 * Double(30 - i))) }
        clock.now = t0.addingTimeInterval(180)
        let upgrade = try await polled(poller())
        XCTAssertEqual(upgrade.stats.watched, 3)
        XCTAssertTrue(upgrade.events.filter { !$0.isOwn }.isEmpty)
        for id in ["I_1", "I_2", "I_3"] {
            let issue = try XCTUnwrap(store.state.prs[id])
            XCTAssertTrue(issue.watched)
            XCTAssertEqual(Attention.bucket(issue), .issueWatched)
            XCTAssertNil(Attention.needReason(issue))
        }
        XCTAssertEqual(store.state.watchedSince?[account.id], ["dana/*": clock.now])
        let discover = github.transport.requests.map(FakeTransport.operation).last { $0.name == "Discover" }
        XCTAssertEqual(discover?.variables["watched"] as? String, "is:issue is:open archived:false sort:created-desc user:@me")
        XCTAssertEqual(discover?.variables["withWatched"] as? Bool, true)

        clock.now = t0.addingTimeInterval(360)
        watchedIssue("I_4", 4, created: t0.addingTimeInterval(300), updatedAt: t0.addingTimeInterval(300))
        let next = try await polled(poller())
        XCTAssertEqual(opened(next), ["I_4"])
        XCTAssertEqual(next.events.first { $0.prID == "I_4" }?.id, "opened:I_4")
        XCTAssertEqual(Attention.needReason(store.state.prs["I_4"]!), .toTriage)
        XCTAssertEqual(store.state.watchedSince?[account.id], ["dana/*": t0.addingTimeInterval(180)], "kept, not moved")
    }

    /// A repository added later: its open issues are silent, a newer one notifies; one opened while PullPing was off still
    /// notifies days later; an old one sliding into the newest-500 window stays silent.
    func testWatchBaselinePerPattern() async throws {
        seed()
        _ = try await polled(poller())
        clock.now = t0.addingTimeInterval(180)
        watchedIssue("I_7", 7, repo: "octo-org/tools", created: t0.addingTimeInterval(-86_400))
        let added = try await polled(poller(watch: ["octo-org/*"]))
        XCTAssertTrue(opened(added).isEmpty, "already open when the pattern was added")
        XCTAssertEqual(store.state.watchedSince?[account.id], ["dana/*": t0, "octo-org/*": t0.addingTimeInterval(180)])
        XCTAssertTrue(store.state.prs["I_7"]!.watched)

        // The Mac was off for three days; an issue opened on the first one.
        clock.now = t0.addingTimeInterval(3 * 86_400)
        watchedIssue("I_8", 8, repo: "octo-org/tools", created: t0.addingTimeInterval(86_400), updatedAt: t0.addingTimeInterval(86_400))
        watchedIssue("I_9", 9, repo: "octo-org/tools", created: t0.addingTimeInterval(-40 * 86_400), updatedAt: t0.addingTimeInterval(86_400))
        let monday = try await polled(poller(watch: ["octo-org/*"]))
        XCTAssertEqual(opened(monday), ["I_8"], "I_9 was open before watching began")
        XCTAssertNil(Attention.needReason(store.state.prs["I_9"]!))
    }

    /// My own new issue never notifies; the watched search pages like the others.
    func testOwnIssueIsSilentAndWatchedSearchPages() async throws {
        seed()
        _ = try await polled(poller())
        clock.now = t0.addingTimeInterval(180)
        watchedIssue("I_1", 1, created: t0.addingTimeInterval(100), author: "dana")
        github.prs["I_2"] = .init(updatedAt: t0, node: issueNode("I_2", number: 2, author: "alice", updatedAt: t0, repo: "dana/app",
                                                                 createdAt: t0.addingTimeInterval(120)), issue: true)
        github.watchedPage2 = ["I_2"]
        let next = try await polled(poller())
        XCTAssertEqual(opened(next), ["I_2"])
        XCTAssertEqual(Attention.bucket(store.state.prs["I_1"]!), .issueMine)
        let page = github.transport.requests.map(FakeTransport.operation).last { $0.name == "Page" }
        XCTAssertEqual(page?.variables["q"] as? String, IssueWatch.query(owned: true, extra: []))
    }

    /// A pattern removed: issues watched only through it go (open ones), one I am part of stays without the flag.
    func testRemovedPatternDropsWatchedOnlyIssues() async throws {
        seed()
        _ = try await polled(poller(watch: ["octo-org/*"]))
        clock.now = t0.addingTimeInterval(180)
        watchedIssue("I_1", 1, repo: "octo-org/widgets", created: t0.addingTimeInterval(-86_400))
        github.prs["I_2"] = .init(updatedAt: t0, node: issueNode("I_2", number: 2, author: "alice", updatedAt: t0, assignees: [me],
                                                                 createdAt: t0.addingTimeInterval(-86_400)), issue: true)
        github.watched.append("I_2")
        github.issues = ["I_2"]
        _ = try await polled(poller(watch: ["octo-org/*"]))
        XCTAssertEqual([store.state.prs["I_1"]?.watched, store.state.prs["I_2"]?.watched], [true, true])

        clock.now = t0.addingTimeInterval(360)
        let removed = try await polled(poller(owned: false))
        XCTAssertTrue(removed.events.filter { !$0.isOwn }.isEmpty)
        XCTAssertNil(store.state.prs["I_1"])
        XCTAssertEqual(store.state.prs["I_2"]?.watched, false)
        XCTAssertEqual(Attention.bucket(store.state.prs["I_2"]!), .issueAssigned)
        XCTAssertFalse(store.state.ignoredIDs.contains("I_1"), "not ignored: watching again brings it back")
        let discover = github.transport.requests.map(FakeTransport.operation).last { $0.name == "Discover" }
        XCTAssertEqual(discover?.variables["withWatched"] as? Bool, false, "nothing to watch: no search")
        XCTAssertEqual(store.state.watchedSince?[account.id], [:])
    }

    /// Two accounts: dana watches dana/*, erin is mentioned in a new issue there. Whichever account refreshes it, the issue is
    /// watched (every account's patterns count), and opening it notifies once, from the account that saw it first.
    func testWatchedThroughAnyAccount() async throws {
        seed()
        let erin = Account(login: "erin"), other = FakeGitHub()
        other.login = "erin"
        let erinPoller = poller(other.transport)
        _ = try await polled(poller())
        _ = await erinPoller.poll(account: erin)
        func issue(_ updated: TimeInterval) {
            other.prs["I_1"] = .init(updatedAt: t0.addingTimeInterval(updated), node: issueNode(
                "I_1", number: 1, author: "alice", updatedAt: t0.addingTimeInterval(updated), body: "@erin can you look?", repo: "dana/app",
                createdAt: t0.addingTimeInterval(100)), issue: true)
            github.prs["I_1"] = other.prs["I_1"]
        }
        issue(100)
        (other.issues, github.watched) = (["I_1"], ["I_1"])
        clock.now = t0.addingTimeInterval(180)
        let first = await erinPoller.poll(account: erin)
        XCTAssertEqual(opened(try XCTUnwrap(first)), ["I_1"], "dana's repository, seen first by erin")
        XCTAssertEqual(store.state.prs["I_1"]?.watched, true)
        let again = try await polled(poller())
        XCTAssertTrue(opened(again).isEmpty, "once")

        // dana refreshes it, then erin last: still watched.
        issue(200)
        clock.now = t0.addingTimeInterval(360)
        _ = try await polled(poller())
        XCTAssertEqual(store.state.prs["I_1"]?.accountID, account.id)
        issue(400)
        clock.now = t0.addingTimeInterval(540)
        _ = await erinPoller.poll(account: erin)
        let entry = try XCTUnwrap(store.state.prs["I_1"])
        XCTAssertEqual(entry.accountID, erin.id)
        XCTAssertTrue(entry.watched)
        XCTAssertEqual(Attention.bucket(entry), .issueWatched)
        XCTAssertEqual(store.state.watchedSince?[erin.id], ["erin/*": t0], "erin's baseline stays its own")
    }

    /// An issue that comes back is not new again: after Stop Tracking and Reset Ignored, or pruned and found again.
    func testIssueComingBackDoesNotNotifyAgain() async throws {
        seed()
        _ = try await polled(poller())
        clock.now = t0.addingTimeInterval(600)
        watchedIssue("I_1", 1, created: t0.addingTimeInterval(500), updatedAt: t0.addingTimeInterval(500))
        let opening = try await polled(poller())
        XCTAssertEqual(opened(opening), ["I_1"])
        store.update { $0.prs["I_1"] = nil; $0.ignoredIDs.insert("I_1") }  // Stop Tracking
        clock.now = t0.addingTimeInterval(1200)
        _ = try await polled(poller())
        XCTAssertNil(store.state.prs["I_1"])

        store.update { $0.ignoredIDs = [] }  // Reset Ignored
        clock.now = t0.addingTimeInterval(1800)
        let reset = try await polled(poller())
        XCTAssertTrue(opened(reset).isEmpty)
        XCTAssertNil(Attention.needReason(try XCTUnwrap(store.state.prs["I_1"])))

        store.update { $0.prs["I_1"] = nil }  // pruned
        clock.now = t0.addingTimeInterval(2400)
        let found = try await polled(poller())
        XCTAssertTrue(opened(found).isEmpty)
        XCTAssertNotNil(store.state.prs["I_1"])
    }

    /// A first sync of a big scope refreshes the newest 100 new watched issues; the rest follow on the next poll, silent, and
    /// a newer issue in that poll still notifies.
    func testFreshWatchedIssuesPerPollAreCapped() async throws {
        seed()
        _ = try await polled(poller())
        let old = (1...150).map { "I_\($0)" }  // newest first, as the search returns them
        for (i, id) in old.enumerated() { watchedIssue(id, i + 1, repo: "octo-org/tools", created: t0.addingTimeInterval(-3600 * Double(i + 1))) }
        clock.now = t0.addingTimeInterval(180)
        let added = try await polled(poller(watch: ["octo-org/*"]))
        XCTAssertEqual(added.stats.new, 100)
        XCTAssertTrue(opened(added).isEmpty)
        XCTAssertNotNil(store.state.prs["I_100"])
        XCTAssertNil(store.state.prs["I_101"])
        XCTAssertEqual(store.state.watchedSince?[account.id]?["octo-org/*"], clock.now)

        clock.now = t0.addingTimeInterval(360)
        watchedIssue("I_151", 151, repo: "octo-org/tools", created: t0.addingTimeInterval(300), updatedAt: t0.addingTimeInterval(300))
        github.watched = ["I_151"] + old
        let next = try await polled(poller(watch: ["octo-org/*"]))
        XCTAssertEqual(next.stats.new, 51)
        XCTAssertEqual(opened(next), ["I_151"])
        XCTAssertEqual(store.state.prs.values.filter(\.watched).count, 151)
        XCTAssertEqual(store.state.prs.values.filter { Attention.needReason($0) == .toTriage }.map(\.id), ["I_151"])
        XCTAssertEqual(store.state.watchedSince?[account.id]?["octo-org/*"], t0.addingTimeInterval(180), "kept")
    }

    /// Track Issues off drops them and forgets when watching began; on again, they come back silently.
    func testTrackIssuesOffForgetsTheWatchBaseline() async throws {
        seed()
        _ = try await polled(poller())
        watchedIssue("I_1", 1, created: t0.addingTimeInterval(-86_400))
        clock.now = t0.addingTimeInterval(180)
        _ = try await polled(poller())
        clock.now = t0.addingTimeInterval(360)
        _ = try await polled(poller(trackIssues: false))
        XCTAssertNil(store.state.prs["I_1"])
        XCTAssertNil(store.state.watchedSince?[account.id])
        XCTAssertEqual(github.transport.requests.map(FakeTransport.operation).last { $0.name == "Discover" }?.variables["withWatched"] as? Bool, false)

        clock.now = t0.addingTimeInterval(540)
        watchedIssue("I_2", 2, created: t0.addingTimeInterval(400), updatedAt: t0.addingTimeInterval(400))  // opened while off
        let on = try await polled(poller())
        XCTAssertTrue(on.events.filter { !$0.isOwn }.isEmpty)
        XCTAssertEqual(store.state.prs["I_1"]?.watched, true)
        XCTAssertEqual(store.state.watchedSince?[account.id], ["dana/*": clock.now])
    }

    // MARK: Repositories

    func discoverWatched() -> String? {
        github.transport.requests.map(FakeTransport.operation).last { $0.name == "Discover" }?.variables["watched"] as? String
    }

    /// Excluded Repositories: the search leaves the repository out; a watched issue there I am not part of goes, one assigned
    /// to me stays, no longer watched.
    func testExcludedRepositoryLeavesTheWatch() async throws {
        seed()
        _ = try await polled(poller(watch: ["octo-org/*"]))
        clock.now = t0.addingTimeInterval(180)
        watchedIssue("I_1", 1, repo: "octo-org/legacy", created: t0.addingTimeInterval(-86_400))
        github.prs["I_2"] = .init(updatedAt: t0, node: issueNode("I_2", number: 2, author: "alice", updatedAt: t0, assignees: [me], repo: "octo-org/legacy",
                                                                 createdAt: t0.addingTimeInterval(-86_400)), issue: true)
        (github.issues, github.watched) = (["I_2"], github.watched + ["I_2"])
        _ = try await polled(poller(watch: ["octo-org/*"]))
        XCTAssertEqual([store.state.prs["I_1"]?.watched, store.state.prs["I_2"]?.watched], [true, true])

        clock.now = t0.addingTimeInterval(360)
        github.watched = []  // GitHub applies the -repo:
        let excluded = try await polled(poller(watch: ["octo-org/*"], exclude: ["octo-org/legacy"]))
        XCTAssertEqual(discoverWatched(), "is:issue is:open archived:false sort:created-desc user:@me user:octo-org -repo:octo-org/legacy")
        XCTAssertTrue(excluded.events.filter { !$0.isOwn }.isEmpty)
        XCTAssertNil(store.state.prs["I_1"])
        XCTAssertEqual(store.state.prs["I_2"]?.watched, false)
        XCTAssertEqual(Attention.bucket(store.state.prs["I_2"]!), .issueAssigned)
        XCTAssertEqual(store.state.watchedSince?[account.id]?["octo-org/*"], t0, "the baseline is not touched")
    }

    /// Removed from Excluded Repositories: its open issues come back read and silent; one opened after the last poll notifies.
    func testReincludedRepositoryComesBackSilently() async throws {
        seed()
        _ = try await polled(poller(watch: ["octo-org/*"]))
        clock.now = t0.addingTimeInterval(180)
        watchedIssue("I_1", 1, repo: "octo-org/legacy", created: t0.addingTimeInterval(-86_400))
        _ = try await polled(poller(watch: ["octo-org/*"]))
        clock.now = t0.addingTimeInterval(360)
        github.watched = []
        _ = try await polled(poller(watch: ["octo-org/*"], exclude: ["octo-org/legacy"]))
        XCTAssertNil(store.state.prs["I_1"])

        clock.now = t0.addingTimeInterval(600)
        github.watched = ["I_1"]
        watchedIssue("I_3", 3, repo: "octo-org/legacy", created: t0.addingTimeInterval(20), updatedAt: t0.addingTimeInterval(20))  // while excluded
        watchedIssue("I_2", 2, repo: "octo-org/legacy", created: t0.addingTimeInterval(500), updatedAt: t0.addingTimeInterval(500))  // after the last poll
        let back = try await polled(poller(watch: ["octo-org/*"]))
        XCTAssertEqual(opened(back), ["I_2"])
        for id in ["I_1", "I_3"] {
            let issue = try XCTUnwrap(store.state.prs[id])
            XCTAssertTrue(issue.watched)
            XCTAssertNil(Attention.needReason(issue))
        }
        XCTAssertEqual(store.state.watchedSince?[account.id]?["octo-org/*"], t0)
    }

    /// A muted repository: a new pull request there starts muted (its events still go out, the App keeps them quiet); one of
    /// its items unmuted by hand stays unmuted.
    func testMutedRepositoryMutesNewItems() async throws {
        seed()
        _ = try await polled(poller())
        store.update { state in
            RepoMute.mute(["Octo-Org/Widgets"], in: &state)
            state.prs["PR_1"]?.muted = false  // Unmute by hand (`Store.setMuted`)
            state.prs["PR_1"]?.mutedByRepo = false
        }
        clock.now = t0.addingTimeInterval(180)
        github.prs["PR_3"] = .init(updatedAt: t0.addingTimeInterval(100), node: prNode("PR_3", number: 3, author: "bob", updatedAt: t0.addingTimeInterval(100), requested: [me]))
        github.prs["PR_1"] = .init(updatedAt: t0.addingTimeInterval(100), node: prNode("PR_1", number: 1, updatedAt: t0.addingTimeInterval(100), ci: "SUCCESS"))
        (github.involved, github.requested) = (["PR_1", "PR_2", "PR_3"], ["PR_2", "PR_3"])
        let next = try await polled(poller())
        let pr3 = try XCTUnwrap(store.state.prs["PR_3"])
        XCTAssertEqual([pr3.muted, pr3.mutedByRepo], [true, true])
        XCTAssertEqual(next.events.filter { $0.prID == "PR_3" }.map(\.kind), [.reviewRequested])
        XCTAssertNil(Attention.needReason(pr3))
        XCTAssertEqual([store.state.prs["PR_1"]?.muted, store.state.prs["PR_1"]?.mutedByRepo], [false, false])
        XCTAssertEqual([store.state.prs["PR_2"]?.muted, store.state.prs["PR_2"]?.mutedByRepo], [true, true])
    }
}
