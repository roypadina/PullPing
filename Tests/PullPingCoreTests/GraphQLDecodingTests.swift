import XCTest
@testable import PullPingCore

final class GraphQLDecodingTests: XCTestCase {
    func client(_ replies: [String: Data]) -> (GitHubClient, FakeTransport) {
        let transport = FakeTransport { (200, [:], replies[FakeTransport.operation($0).name]!) }
        return (GitHubClient(transport: transport, token: "test-token"), transport)
    }

    func testDiscoverMergesAliasesAndPages() async throws {
        let (client, transport) = client(["Discover": fixture("discover"), "Page": fixture("page")])
        let found = try await client.discover()
        XCTAssertEqual(found.login, "dana")
        XCTAssertEqual(Set(found.stamps.keys), ["PR_1", "PR_2", "PR_3", "PR_4"])
        XCTAssertEqual(found.stamps["PR_3"]?.inRequested, true)
        XCTAssertEqual(found.stamps["PR_2"]?.inReviewed, true)
        XCTAssertEqual(found.stamps["PR_1"]?.inReviewed, false)
        XCTAssertEqual(found.stamps["PR_1"]?.updatedAt, ISO8601DateFormatter().date(from: "2026-10-29T10:00:00Z"))
        XCTAssertEqual([found.involved, found.requested, found.reviewed, found.pages], [3, 1, 1, 4])
        XCTAssertEqual(client.cost, 2)
        XCTAssertEqual(client.rateLimit?.remaining, 4989)
        let page = FakeTransport.operation(transport.requests[1]).variables
        XCTAssertEqual(page["q"] as? String, SearchQueries.involved)
        XCTAssertEqual(page["after"] as? String, "cursor-1")
        XCTAssertEqual(transport.requests[0].value(forHTTPHeaderField: "Authorization"), "bearer test-token")
    }

    func testStampsDropNullNodesAndIgnoreNotFound() async throws {
        let (client, _) = client(["Stamps": fixture("stamps")])
        let (stamps, dropped) = try await client.stamps(["PR_5", "PR_6"])
        XCTAssertEqual(stamps.map(\.id), ["PR_5"])
        XCTAssertEqual(stamps.first?.state, .merged)
        XCTAssertEqual(dropped, ["PR_6"])
        XCTAssertNil(client.warning)
    }

    func testRefreshDecodesAllUnionCasesAndUsesPartialData() async throws {
        let (client, transport) = client(["Refresh": fixture("refresh")])
        let since = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshots = try await client.refresh(["PR_1", "PR_X"], since: since)
        XCTAssertEqual(FakeTransport.operation(transport.requests[0]).variables["since"] as? String, "2027-01-15T08:00:00Z")
        XCTAssertEqual(client.warning, .ssoRequired)  // SAML error on the null node; PR_1 still used
        XCTAssertEqual(snapshots.count, 1)
        let s = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(s.repo, "octo-org/widgets")
        XCTAssertEqual(s.number, 1)
        XCTAssertEqual(s.authorLogin, "dana")
        XCTAssertEqual(s.state, .open)
        XCTAssertEqual(s.reviewDecision, "CHANGES_REQUESTED")
        XCTAssertEqual(s.mergeState, "BLOCKED")
        XCTAssertEqual(s.headOID, "abc1234def5678")
        XCTAssertEqual(s.headRef, "feature/cache")
        XCTAssertEqual(s.headAuthorLogin, "dana")
        XCTAssertEqual(s.ci, .failure)
        XCTAssertEqual(s.checks.map(\.name), ["build", "lint", "docs", "ci/legacy"])
        XCTAssertEqual(s.checks.map(\.state), [.success, .pending, .success, .failure])
        XCTAssertEqual(s.assignees, ["dana"])
        XCTAssertEqual(s.requestedTeams, ["core"])
        XCTAssertEqual(s.reviewers.map(\.login), ["alice", "bob", "carol"])
        XCTAssertEqual(s.reviewers.map(\.state), ["APPROVED", "CHANGES_REQUESTED", ""])
        XCTAssertEqual(s.reviewers.map(\.requested), [false, false, true])
        XCTAssertEqual(s.reviewers.map(\.commitOID), [nil, nil, nil])  // a response without the 0.7.0 fields still decodes
        XCTAssertNil(s.myReview)
        XCTAssertEqual(s.autoMerge, false)
        XCTAssertEqual(s.timeline.map(\.type), ["IssueComment", "PullRequestReview", "PullRequestReview", "ReadyForReviewEvent",
                                                "ConvertToDraftEvent", "MergedEvent", "ClosedEvent", "ReopenedEvent",
                                                "HeadRefForcePushedEvent", "ReviewDismissedEvent", "RenamedTitleEvent"])  // pending review dropped
        let review = s.timeline[2]
        XCTAssertEqual([review.commentPath, review.commentBody, review.reviewState], ["Sources/Cache.swift", "Rename this\nplease", "COMMENTED"])
        XCTAssertEqual(review.commentCount, 3)
        XCTAssertEqual(s.timeline[8].actor, "ghost")
        XCTAssertEqual(s.timeline[8].detail, "abc1234")
        XCTAssertEqual(s.timeline[10].detail, "Add widget cache")
    }

    func testRefreshDecodesReviewTurnFields() async throws {
        let (client, _) = client(["Refresh": fixture("refresh-070")])
        let s = try await client.refresh(["PR_7", "PR_8", "PR_9", "PR_10"], since: nil)
        XCTAssertEqual(s.map(\.id), ["PR_7", "PR_8", "PR_9", "PR_10"])
        let date = ISO8601DateFormatter().date(from:)

        // My later comment-only review doesn't hide my change request on the older head; reviewers show deciding reviews first.
        XCTAssertEqual(s[0].myReview, MyReview(state: "CHANGES_REQUESTED", commitOID: "aaa1111", submittedAt: date("2026-11-12T10:00:00Z")))
        XCTAssertEqual(s[0].reviewers.map(\.login), ["alice", "dana", "erin", "carol"])
        XCTAssertEqual(s[0].reviewers.map(\.state), ["CHANGES_REQUESTED", "CHANGES_REQUESTED", "COMMENTED", ""])
        XCTAssertEqual(s[0].reviewers.map(\.commitOID), ["aaa1111", "aaa1111", nil, nil])
        XCTAssertEqual(s[0].autoMerge, true)  // auto-merge enabled

        XCTAssertNil(s[1].myReview)  // my own pull request: my comment review is ignored
        XCTAssertEqual(s[1].autoMerge, true)  // in the merge queue
        XCTAssertEqual(s[1].reviewers.map(\.state), ["APPROVED"])
        XCTAssertNil(s[1].reviewers.first?.commitOID)  // reviewed commit force-pushed away

        XCTAssertEqual(s[2].myReview, MyReview(state: "DISMISSED", commitOID: "bbb2222", submittedAt: date("2026-11-12T08:00:00Z")))
        XCTAssertEqual(s[2].autoMerge, false)
        XCTAssertEqual(s[2].mergeState, "UNKNOWN")
        XCTAssertNil(s[3].myReview)  // a pending review is no review yet
    }

    func testRefreshFollowsTimelinePages() async throws {
        var first = String(decoding: fixture("refresh"), as: UTF8.self)
        first = first.replacingOccurrences(of: #""hasNextPage": false, "endCursor": "t-1""#, with: #""hasNextPage": true, "endCursor": "t-1""#)
        let second = String(decoding: fixture("refresh"), as: UTF8.self)
        let transport = FakeTransport { request in
            let after = FakeTransport.operation(request).variables["after"] as? String
            return (200, [:], Data((after == "t-1" ? second : first).utf8))
        }
        let client = GitHubClient(transport: transport, token: "t")
        let snapshots = try await client.refresh(["PR_1"], since: nil)
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(FakeTransport.operation(transport.requests[1]).variables["ids"] as? [String], ["PR_1"])
        XCTAssertEqual(snapshots.first?.timeline.count, 22)
    }

    func testDiscoverIssuesAliasFollowsTheSwitch() async throws {
        let github = FakeGitHub()
        github.prs["PR_1"] = .init(updatedAt: t0, node: "")
        github.prs["I_1"] = .init(updatedAt: t0, node: "", issue: true)
        github.involved = ["PR_1"]
        github.issues = ["I_1"]
        let client = GitHubClient(transport: github.transport, token: "t")
        let on = try await client.discover(issues: true)
        XCTAssertEqual(Set(on.stamps.keys), ["PR_1", "I_1"])
        XCTAssertEqual(on.issues, 1)
        let off = try await client.discover(issues: false)
        XCTAssertEqual(Set(off.stamps.keys), ["PR_1"])
        XCTAssertEqual(off.issues, 0)
        let variables = github.transport.requests.map { FakeTransport.operation($0).variables }
        XCTAssertEqual(variables.map { $0["withIssues"] as? Bool }, [true, false])
        XCTAssertEqual(variables.first?["issues"] as? String, SearchQueries.issues)
    }

    /// The watched search runs with Track Issues and a query; `inIssues` comes only from the involves search; it pages.
    func testDiscoverWatchedSearch() async throws {
        let github = FakeGitHub()
        for id in ["I_1", "I_2", "I_3"] { github.prs[id] = .init(updatedAt: t0, node: "", issue: true) }
        github.issues = ["I_1"]
        github.watched = ["I_1", "I_2"]
        github.watchedPage2 = ["I_3"]
        let client = GitHubClient(transport: github.transport, token: "t")
        let query = "is:issue is:open archived:false sort:created-desc user:@me"
        let on = try await client.discover(issues: true, watched: query)
        XCTAssertEqual(Set(on.stamps.keys), ["I_1", "I_2", "I_3"])
        XCTAssertEqual([on.stamps["I_1"]?.inIssues, on.stamps["I_2"]?.inIssues, on.stamps["I_3"]?.inIssues], [true, false, false])
        XCTAssertEqual(on.watched, 2)
        let none = try await client.discover(issues: true)
        XCTAssertEqual(Set(none.stamps.keys), ["I_1"])
        XCTAssertEqual(none.watched, 0)
        _ = try await client.discover(issues: false, watched: query)
        let operations = github.transport.requests.map(FakeTransport.operation)
        let discovers = operations.filter { $0.name == "Discover" }.map(\.variables)
        XCTAssertEqual(discovers.map { $0["withWatched"] as? Bool }, [true, false, false])
        XCTAssertEqual(discovers.map { $0["watched"] as? String }, [query, "", query])
        XCTAssertEqual(operations.filter { $0.name == "Page" }.map { $0.variables["q"] as? String }, [query])
    }

    func testIssueCreatedAtAndDiscoverWithoutWatched() async throws {
        let github = FakeGitHub()
        github.prs["I_1"] = .init(updatedAt: t0, node: issueNode("I_1", number: 7, updatedAt: t0, createdAt: t0.addingTimeInterval(-60)), issue: true)
        github.prs["I_2"] = .init(updatedAt: t0, node: issueNode("I_2", number: 8, updatedAt: t0), issue: true)
        github.prs["PR_1"] = .init(updatedAt: t0, node: prNode("PR_1", number: 1, updatedAt: t0))
        let snapshots = try await GitHubClient(transport: github.transport, token: "t").refresh(["I_1", "I_2", "PR_1"], since: nil)
        XCTAssertEqual(snapshots.map(\.createdAt), [t0.addingTimeInterval(-60), nil, nil])
        XCTAssertTrue(GraphQL.refresh.contains("issueState: state stateReason closedAt updatedAt createdAt body"))
        let (client, _) = client(["Discover": fixture("discover"), "Page": fixture("page")])
        let found = try await client.discover(issues: true, watched: "q")  // a response without the alias (an older fixture)
        XCTAssertEqual(found.watched, 0)
    }

    func testIssueStampsAndMixedRefresh() async throws {
        let github = FakeGitHub()
        let timeline = [
            #"{ "__typename": "LabeledEvent", "id": "LE_1", "createdAt": "\#(iso(t0))", "actor": { "login": "alice" }, "label": { "name": "bug" } }"#,
            #"{ "__typename": "UnlabeledEvent", "id": "UNLE_1", "createdAt": "\#(iso(t0))", "actor": { "login": "bot" }, "label": { "name": "needs-triage" } }"#,
            #"{ "__typename": "ClosedEvent", "id": "CE_1", "createdAt": "\#(iso(t0))", "actor": { "login": "alice" }, "stateReason": "NOT_PLANNED" }"#,
        ].joined(separator: ",")
        github.prs["I_1"] = .init(updatedAt: t0, state: "CLOSED", node: issueNode("I_1", number: 7, updatedAt: t0, state: "CLOSED", stateReason: "NOT_PLANNED",
                                                                                   assignees: [me], timeline: timeline), issue: true)
        github.prs["PR_1"] = .init(updatedAt: t0, node: prNode("PR_1", number: 1, updatedAt: t0))
        let client = GitHubClient(transport: github.transport, token: "t")

        let (stamps, _) = try await client.stamps(["I_1", "PR_1"])
        XCTAssertEqual(stamps.map(\.state), [.closed, .open])

        let snapshots = try await client.refresh(["I_1", "PR_1"], since: nil)
        let issue = try XCTUnwrap(snapshots.first)
        XCTAssertTrue(issue.isIssue)
        XCTAssertEqual(issue.state, .closed)
        XCTAssertEqual(issue.stateReason, "NOT_PLANNED")
        XCTAssertEqual(issue.closedAt, t0)
        XCTAssertEqual(issue.assignees, [me])
        XCTAssertEqual([issue.headOID, issue.mergeState], ["", ""])
        XCTAssertNil(issue.headRef)
        XCTAssertEqual(issue.ci, CIState.none)
        XCTAssertEqual(issue.timeline.map(\.type), ["LabeledEvent", "UnlabeledEvent", "ClosedEvent"])
        XCTAssertEqual(issue.timeline.map(\.detail), ["bug", "needs-triage", "not planned"])
        XCTAssertFalse(snapshots[1].isIssue)
        XCTAssertNil(snapshots[1].stateReason)
    }

    func testCINormalization() {
        XCTAssertEqual(CIState(rollup: nil), CIState.none)
        XCTAssertEqual(CIState(rollup: "SUCCESS"), .success)
        XCTAssertEqual(CIState(rollup: "FAILURE"), .failure)
        XCTAssertEqual(CIState(rollup: "ERROR"), .failure)
        XCTAssertEqual(CIState(rollup: "PENDING"), .pending)
        XCTAssertEqual(CIState(rollup: "EXPECTED"), .pending)
        for failed in ["FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"] {
            XCTAssertEqual(CIState(conclusion: failed), .failure, failed)
        }
        for passed in ["SUCCESS", "NEUTRAL", "SKIPPED"] {
            XCTAssertEqual(CIState(conclusion: passed), .success, passed)
        }
        XCTAssertEqual(CIState(conclusion: nil), .pending)
        XCTAssertEqual(CIState(conclusion: "STALE"), .pending)
    }
}
