import XCTest
@testable import PullPingCore

/// Fake Claude config and Codex homes under a temp HOME: never the real ~/.claude or ~/.codex.
final class SessionFinderTests: XCTestCase {
    var dir: URL!
    var env: [String: String] { ["HOME": dir.path, "CODEX_HOME": dir.appendingPathComponent("codex").path] }
    let url = URL(string: "https://github.com/octo-org/widgets/pull/12")!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// A Claude transcript `<id>.jsonl` changed `age` seconds before t0.
    @discardableResult
    func claude(_ id: String, _ lines: [String], age: TimeInterval, config: String = ".claude", project: String = "-Users-alice-Code") throws -> String {
        let folder = dir.appendingPathComponent(config).appendingPathComponent("projects").appendingPathComponent(project)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(id).jsonl")
        try Data(lines.joined(separator: "\n").utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(-age)], ofItemAtPath: file.path)
        return file.path
    }

    func codex(_ id: String, _ lines: [String], age: TimeInterval) throws {
        let folder = dir.appendingPathComponent("codex/sessions/2027/01/15")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("rollout-2027-01-15T10-00-00-\(id).jsonl")
        try Data(lines.joined(separator: "\n").utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(-age)], ofItemAtPath: file.path)
    }

    func line(cwd: String, branch: String = "HEAD", text: String = "") -> String {
        #"{"type":"user","cwd":"\#(cwd)","gitBranch":"\#(branch)","sessionId":"x","message":{"content":"\#(text)"}}"#
    }

    let prLink = #"{"type":"pr-link","sessionId":"x","prNumber":12,"prUrl":"https://github.com/octo-org/widgets/pull/12","prRepository":"octo-org/widgets"}"#

    func find(headRef: String? = nil, exclude: String? = nil, days: Int = 60, env extra: [String: String] = [:],
              cap: Int = SessionFinder.maxFiles) -> (candidates: [SessionCandidate], scanned: Int, truncated: Bool) {
        SessionFinder.find(url: url, repo: "octo-org/widgets", number: 12, headRef: headRef, env: env.merging(extra) { $1 }, exclude: exclude, days: days,
                           now: t0, cap: cap)
    }

    func testTiersAndOrder() throws {
        try claude("aaaa-link", [#"{"type":"summary"}"#, line(cwd: "/Users/alice/Code"), prLink, line(cwd: "/Users/alice/Code/widgets-wt"),
                                 #"{"type":"ai-title","aiTitle":"Widget\ncache"}"#], age: 7200)
        try claude("bbbb-mention", [line(cwd: "/a", text: "see https://github.com/octo-org/widgets/pull/12 please")], age: 60)
        try claude("cccc-older-mention", [line(cwd: "/b", text: "octo-org/widgets#12.")], age: 600)
        let result = find()
        XCTAssertEqual(result.candidates.map(\.sessionID), ["aaaa-link", "bbbb-mention"])  // pr-link first; the newest mention
        XCTAssertEqual(result.candidates.map(\.tier), ["pr-link", "mention"])
        let best = try XCTUnwrap(result.candidates.first)
        XCTAssertEqual([best.launchDir, best.workDir, best.title, best.branch], ["/Users/alice/Code", "/Users/alice/Code/widgets-wt", "Widget cache", "HEAD"])
        XCTAssertEqual(best.agent, .claude)
        XCTAssertEqual(best.modifiedAt, t0.addingTimeInterval(-7200))
        XCTAssertFalse(best.mayBeOpen)
        XCTAssertTrue(result.candidates[1].mayBeOpen)  // changed a minute ago
        XCTAssertTrue(best.transcript.hasSuffix("/projects/-Users-alice-Code/aaaa-link.jsonl"))
        XCTAssertEqual(result.scanned, 3)  // nothing older than the pr-link file was read
        XCTAssertFalse(result.truncated)
    }

    func testMentionNeedsTheWholeNumber() throws {
        try claude("one", [line(cwd: "/a", text: "octo-org/widgets#123 and https://github.com/octo-org/widgets/pull/120")], age: 60)
        XCTAssertTrue(find().candidates.isEmpty)
        try claude("two", [line(cwd: "/a", text: "https://github.com/octo-org/widgets/pull/12/files")], age: 120)
        XCTAssertEqual(find().candidates.map(\.sessionID), ["two"])
    }

    func testBranchTier() throws {
        try claude("other-repo", [line(cwd: "/x/gadgets", branch: "feature/cache")], age: 60)  // the branch, but not this repository
        try claude("on-main", [line(cwd: "/x/widgets", branch: "main")], age: 60)
        XCTAssertTrue(find(headRef: "feature/cache").candidates.isEmpty)
        try claude("in-wt", [line(cwd: "/Users/alice/Code/widgets-wt", branch: "feature/cache")], age: 120)
        XCTAssertEqual(find(headRef: "feature/cache").candidates.map(\.tier), ["branch"])
        XCTAssertTrue(find(headRef: "main").candidates.isEmpty)  // too common to mean anything
        XCTAssertTrue(find(headRef: nil).candidates.isEmpty)
    }

    func testSkipsSubAgentsExcludedAndOld() throws {
        let sub = dir.appendingPathComponent(".claude/projects/-p/main-session/subagents")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(prLink.utf8).write(to: sub.appendingPathComponent("agent-1.jsonl"))  // sub-agent transcripts are not resumable
        try claude("me", [prLink, line(cwd: "/a")], age: 10)
        try claude("old", [prLink, line(cwd: "/a")], age: 61 * 86_400)
        XCTAssertEqual(find().candidates.map(\.sessionID), ["me"])
        XCTAssertTrue(find(exclude: "me").candidates.isEmpty)  // the caller's own session; the old one is past 60 days
        XCTAssertEqual(find(exclude: "me", days: 90).candidates.map(\.sessionID), ["old"])
    }

    func testFileCapTruncates() throws {
        for i in 0...3 { try claude("s\(i)", [line(cwd: "/a")], age: Double(100 + i)) }
        try claude("hit", [prLink], age: 99_000)  // older than the first 4
        let result = find(cap: 3)
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.scanned, 3)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(find().candidates.map(\.sessionID), ["hit"])  // the default rail is far above
    }

    /// A restore resets modification dates: the last record's timestamp orders the search, the date is only the fallback.
    func testLastTimestampOrdersTheSearch() throws {
        let stamp = { (age: TimeInterval) in #"{"type":"assistant","timestamp":"\#(Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(t0.addingTimeInterval(-age)))"}"# }
        try claude("restored-old", [prLink, stamp(40 * 86_400)], age: 60)  // touched a minute ago, last active 40 days ago
        try claude("recent", [prLink, stamp(3600), #"{"type":"last-prompt"}"#], age: 3000)
        try claude("restored-ancient", [prLink, stamp(90 * 86_400)], age: 30)  // past the 60 days by its timestamp
        try claude("no-stamp", [line(cwd: "/a", text: "octo-org/widgets#12")], age: 7200)
        let result = find()
        XCTAssertEqual(result.candidates.map(\.sessionID), ["recent"])
        XCTAssertEqual(result.candidates.first?.modifiedAt, t0.addingTimeInterval(-3600))
        XCTAssertEqual(result.candidates.first?.mayBeOpen, false)
        XCTAssertEqual(result.scanned, 1)  // the pr-link in "recent" ends the scan before the restored ones
        let files = SessionFinder.files(env: env, since: t0.addingTimeInterval(-60 * 86_400))
        XCTAssertEqual(files.map { ($0.path as NSString).lastPathComponent }, ["recent.jsonl", "no-stamp.jsonl", "restored-old.jsonl"])
        XCTAssertEqual(files[1].active, t0.addingTimeInterval(-7200))  // no timestamp: the modification date
        XCTAssertEqual(SessionFinder.lastTimestamp(try claude("plain", [#"{"timestamp":"2027-01-15T10:00:00Z"}"#], age: 0), size: 40),
                       ISO8601DateFormatter().date(from: "2027-01-15T10:00:00Z"))  // Codex-style, no fraction
    }

    func testCodexRollouts() throws {
        try codex("0199aaaa-0000-7000-8000-000000000001", [
            #"{"timestamp":"2027-01-15T10:00:00Z","type":"session_meta","payload":{"id":"0199aaaa-0000-7000-8000-000000000001","cwd":"/Users/alice/Code/widgets","originator":"codex_cli_rs"}}"#,
            #"{"type":"turn_context","payload":{"cwd":"/Users/alice/Code/widgets-wt"}}"#,
            #"{"type":"response_item","payload":{"content":"fix octo-org/widgets#12 now"}}"#], age: 30)
        let found = try XCTUnwrap(find().candidates.first)
        XCTAssertEqual(found.agent, .codex)
        XCTAssertEqual([found.sessionID, found.launchDir, found.workDir, found.title, found.branch, found.tier],
                       ["0199aaaa-0000-7000-8000-000000000001", "/Users/alice/Code/widgets", "/Users/alice/Code/widgets-wt", "", "", "mention"])
        XCTAssertTrue(found.mayBeOpen)
        XCTAssertEqual(SessionFinder.transcript(agent: .codex, sessionID: found.sessionID, env: env), found.transcript)
        XCTAssertTrue(find(exclude: found.sessionID).candidates.isEmpty)
    }

    func testOneProjectsFolderScannedOnce() throws {
        try claude("shared", [prLink], age: 60)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("profile2"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("profile2/projects"), withDestinationURL: dir.appendingPathComponent(".claude/projects"))
        try claude("mention", [line(cwd: "/a", text: "octo-org/widgets#12")], age: 30)
        let result = find(env: ["CLAUDE_CONFIG_DIR": dir.appendingPathComponent("profile2").path])
        XCTAssertEqual(result.scanned, 2)
        XCTAssertEqual(result.candidates.map(\.sessionID), ["shared", "mention"])
    }

    func testJSONStringExtraction() {
        let data = Data(#"{"cwd":"/a"} {"cwd":"/b \"q\" é\\"} {"cwd":"/c"#.utf8)
        XCTAssertEqual(data.jsonString(after: #""cwd":""#, last: false), "/a")
        XCTAssertEqual(data.jsonString(after: #""cwd":""#, last: true), nil)  // the last one never ends
        XCTAssertEqual(Data(#"x {"cwd":"/b \"q\" é\\"}"#.utf8).jsonString(after: #""cwd":""#, last: true), #"/b "q" é\"#)
    }
}
