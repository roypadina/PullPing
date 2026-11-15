import XCTest
@testable import PullPingCore

/// Issues in my repositories: the Other Repositories field, the search, the patterns and when watching began.
final class IssueWatchTests: XCTestCase {
    func testParse() {
        let parsed = IssueWatch.parse("Octo-Org/widgets, octo-org/*  foo\nocto-org/WIDGETS,,bad/name/x  */x a/* ")
        XCTAssertEqual(parsed.patterns, ["octo-org/widgets", "octo-org/*", "a/*"])
        XCTAssertEqual(parsed.rejected, ["foo", "bad/name/x", "*/x"])
        XCTAssertEqual(IssueWatch.parse(" ").patterns, [])
        let many = (1...21).map { "octo-org/repo\($0)" }.joined(separator: " ")
        let capped = IssueWatch.parse(many)
        XCTAssertEqual(capped.patterns.count, IssueWatch.maxRepos)
        XCTAssertEqual(capped.rejected, ["octo-org/repo21"])
    }

    func testQuery() {
        XCTAssertEqual(IssueWatch.query(owned: true, extra: []), "is:issue is:open archived:false sort:created-desc user:@me")
        XCTAssertEqual(IssueWatch.query(owned: false, extra: ["octo-org/widgets", "octo-org/*"]),
                       "is:issue is:open archived:false sort:created-desc repo:octo-org/widgets user:octo-org")
        XCTAssertEqual(IssueWatch.query(owned: true, extra: ["octo-org/widgets", "octo-org/*"]),
                       "is:issue is:open archived:false sort:created-desc user:@me repo:octo-org/widgets user:octo-org")
        XCTAssertNil(IssueWatch.query(owned: false, extra: []))
    }

    func testPatternsMatchesAndSince() {
        XCTAssertEqual(IssueWatch.patterns(login: "Dana", owned: true, extra: ["octo-org/*", "dana/*"]), ["dana/*", "octo-org/*"])
        XCTAssertEqual(IssueWatch.patterns(login: "dana", owned: false, extra: ["octo-org/widgets"]), ["octo-org/widgets"])
        let patterns = ["dana/*", "octo-org/widgets", "octo-org/*"]
        XCTAssertTrue(IssueWatch.matches("Dana/App", patterns))
        XCTAssertTrue(IssueWatch.matches("octo-org/gadgets", patterns))
        XCTAssertFalse(IssueWatch.matches("octo-org-evil/widgets", patterns))
        XCTAssertFalse(IssueWatch.matches("alice/app", []))
        let since = ["octo-org/*": t0.addingTimeInterval(-60), "octo-org/widgets": t0.addingTimeInterval(-3600)]
        XCTAssertEqual(IssueWatch.since("octo-org/widgets", patterns: patterns, since: since, now: t0), t0.addingTimeInterval(-3600), "the earliest")
        XCTAssertEqual(IssueWatch.since("octo-org/gadgets", patterns: patterns, since: since, now: t0), t0.addingTimeInterval(-60))
        XCTAssertEqual(IssueWatch.since("dana/app", patterns: patterns, since: since, now: t0), t0, "a pattern not polled yet: now")
        XCTAssertNil(IssueWatch.since("alice/app", patterns: patterns, since: since, now: t0))
    }
}
