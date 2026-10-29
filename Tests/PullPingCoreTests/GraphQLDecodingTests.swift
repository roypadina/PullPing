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
        XCTAssertEqual(s.headAuthorLogin, "dana")
        XCTAssertEqual(s.ci, .failure)
        XCTAssertEqual(s.checks.map(\.name), ["build", "lint", "docs", "ci/legacy"])
        XCTAssertEqual(s.checks.map(\.state), [.success, .pending, .success, .failure])
        XCTAssertEqual(s.assignees, ["dana"])
        XCTAssertEqual(s.requestedTeams, ["core"])
        XCTAssertEqual(s.reviewers.map(\.login), ["alice", "bob", "carol"])
        XCTAssertEqual(s.reviewers.map(\.state), ["APPROVED", "CHANGES_REQUESTED", ""])
        XCTAssertEqual(s.reviewers.map(\.requested), [false, false, true])
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
