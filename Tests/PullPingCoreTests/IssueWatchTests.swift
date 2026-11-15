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

    // MARK: Excluded Repositories

    func testParseWithoutWildcards() {
        let parsed = IssueWatch.parse("octo-org/*, Octo-Org/Legacy foo", wildcards: false)
        XCTAssertEqual(parsed.patterns, ["octo-org/legacy"])
        XCTAssertEqual(parsed.rejected, ["octo-org/*", "foo"])
        let capped = IssueWatch.parse((1...21).map { "octo-org/repo\($0)" }.joined(separator: " "), wildcards: false)
        XCTAssertEqual(capped.patterns.count, IssueWatch.maxRepos)
        XCTAssertEqual(capped.rejected, ["octo-org/repo21"])
    }

    func testQueryWithExcluded() {
        let base = "is:issue is:open archived:false sort:created-desc"
        XCTAssertEqual(IssueWatch.query(owned: true, extra: ["octo-org/*"], excluded: ["octo-org/legacy", "alice/dotfiles"]),
                       "\(base) user:@me user:octo-org -repo:octo-org/legacy -repo:alice/dotfiles")
        XCTAssertEqual(IssueWatch.query(owned: false, extra: ["octo-org/widgets", "Octo-Org/Legacy"], excluded: ["octo-org/legacy"]),
                       "\(base) repo:octo-org/widgets -repo:octo-org/legacy", "an entry in both lists: no repo: for it")
        // repo:X -repo:X cancels the scope and searches all of GitHub: never sent.
        XCTAssertNil(IssueWatch.query(owned: false, extra: ["octo-org/legacy"], excluded: ["octo-org/legacy"]))
        XCTAssertNil(IssueWatch.query(owned: false, extra: [], excluded: ["octo-org/legacy"]), "negatives alone: no search")
        XCTAssertEqual(IssueWatch.query(owned: true, extra: [], excluded: []), IssueWatch.query(owned: true, extra: []))
        XCTAssertEqual(IssueWatch.query(owned: true, extra: ["octo-org/widgets"], excluded: []), "\(base) user:@me repo:octo-org/widgets")
    }

    func testMatchesAndSinceSkipExcluded() {
        let patterns = ["dana/*", "octo-org/*"], since = ["octo-org/*": t0.addingTimeInterval(-60)]
        XCTAssertFalse(IssueWatch.matches("Octo-Org/Legacy", patterns, excluded: ["octo-org/legacy"]))
        XCTAssertTrue(IssueWatch.matches("octo-org/widgets", patterns, excluded: ["octo-org/legacy"]))
        XCTAssertNil(IssueWatch.since("OCTO-ORG/legacy", patterns: patterns, since: since, excluded: ["octo-org/legacy"], now: t0))
        XCTAssertEqual(IssueWatch.since("octo-org/widgets", patterns: patterns, since: since, excluded: ["octo-org/legacy"], now: t0),
                       t0.addingTimeInterval(-60))
    }
}
