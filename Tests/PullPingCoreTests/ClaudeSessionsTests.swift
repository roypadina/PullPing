import XCTest
@testable import PullPingCore

/// A fake Claude config dir under a temp HOME: never the real ~/.claude.
final class ClaudeSessionsTests: XCTestCase {
    var dir: URL!
    let id = "1a2b3c4d-0000-4000-8000-000000000001"
    var env: [String: String] { ["HOME": dir.path] }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        for folder in ["Code/widgets", "Code/gadgets"] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// `<config>/projects/<slug>/<id>.jsonl` with these lines.
    func transcript(_ lines: [String], config: String = ".claude", slug: String = "-Users-alice-Code", id: String? = nil) throws {
        let folder = dir.appendingPathComponent(config).appendingPathComponent("projects").appendingPathComponent(slug)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(lines.joined(separator: "\n").utf8).write(to: folder.appendingPathComponent("\(id ?? self.id).jsonl"))
    }

    func cwdLine(_ path: String) -> String { #"{"type":"user","cwd":"\#(path)","sessionId":"x"}"# }

    func testFirstCwdAfterACwdLessLine() throws {
        try transcript([#"{"type":"summary","summary":"Hi"}"#, "not json", cwdLine("/Users/alice/Code"), cwdLine("/elsewhere")])
        try transcript([cwdLine("/other")], slug: "-other", id: "someone-else")
        XCTAssertEqual(ClaudeSessions.launchDirectory(sessionID: id, env: env), "/Users/alice/Code")
        XCTAssertNil(ClaudeSessions.launchDirectory(sessionID: "unknown-id", env: env))
        XCTAssertNil(ClaudeSessions.launchDirectory(sessionID: "../\(id)", env: env))  // never a path
    }

    func testPrefersClaudeConfigDir() throws {
        try transcript([cwdLine("/from/home")])
        try transcript([cwdLine("/from/config")], config: "profile2")
        XCTAssertEqual(ClaudeSessions.launchDirectory(sessionID: id, env: env.merging(["CLAUDE_CONFIG_DIR": dir.appendingPathComponent("profile2").path]) { $1 }),
                       "/from/config")
        XCTAssertEqual(ClaudeSessions.launchDirectory(sessionID: id, env: env.merging(["CLAUDE_CONFIG_DIR": dir.appendingPathComponent("empty").path]) { $1 }),
                       "/from/home")  // not in that config: ~/.claude next
    }

    func testReadsOnlyTheFirstLines() throws {
        let filler = #"{"type":"user","message":"\#(String(repeating: "x", count: 50_000))"}"#
        try transcript(Array(repeating: #"{"type":"summary"}"#, count: 20) + [cwdLine("/late")] + Array(repeating: filler, count: 20))  // ≈ 1 MB
        XCTAssertNil(ClaudeSessions.launchDirectory(sessionID: id, env: env))
        try transcript([#"{"type":"summary"}"#, cwdLine("/early")] + Array(repeating: filler, count: 20))
        XCTAssertEqual(ClaudeSessions.launchDirectory(sessionID: id, env: env), "/early")
    }

    // MARK: AutomationFile.resolved

    func linked(_ agent: AgentKind = .claude, command: String = "") -> Automation {
        var a = Automation(name: "Rule", kinds: [.comment], workingDirectory: "~/Code/{repo_name}", createdAt: t0)
        a.agent = agent
        a.agentCommand = command
        a.sessionID = Automation.linkedSession
        return a
    }

    func file(_ agent: AgentKind, cwd: String, session: String? = nil) -> AutomationFile {
        var file = AutomationFile()
        file.setLink(SessionLink(pr: PRRef(repo: "octo-org/widgets", number: 12), agent: agent, sessionID: session ?? id, cwd: cwd, setAt: t0, source: "cli", by: ""))
        return file
    }

    func testResolvedTakesTheLink() throws {
        let widgets = dir.appendingPathComponent("Code/widgets").path
        let plain = Automation(name: "Rule", kinds: [.comment], workingDirectory: "/tmp", createdAt: t0)
        XCTAssertEqual(try AutomationFile().resolved(plain, repo: "octo-org/widgets", number: 12, env: env).automation, plain)  // not linked: as is
        XCTAssertThrowsError(try AutomationFile().resolved(linked(), repo: "octo-org/widgets", number: 12, env: env)) {
            XCTAssertEqual($0 as? LaunchError, .noLinkedSession)
        }
        let same = try file(.claude, cwd: widgets).resolved(linked(command: "cc"), repo: "Octo-Org/Widgets", number: 12, env: env)
        XCTAssertEqual([same.automation.sessionID, same.automation.workingDirectory, same.automation.agentCommand], [id, widgets, "cc"])
        XCTAssertNil(same.relinked)
        let other = try file(.codex, cwd: widgets, session: "thread.2").resolved(linked(command: "cc"), repo: "octo-org/widgets", number: 12, env: env)
        XCTAssertEqual(other.automation.agent, .codex)
        XCTAssertEqual(other.automation.agentCommand, "")  // a claude wrapper never launches Codex
        XCTAssertEqual(other.automation.sessionID, "thread.2")
    }

    func testResolvedFindsAMovedFolder() throws {
        let gone = dir.appendingPathComponent("Code/gone").path, gadgets = dir.appendingPathComponent("Code/gadgets").path
        let widgets = dir.appendingPathComponent("Code/widgets").path
        // No transcript to ask: the pull request's folders, {worktree_dir} first (here ~/Code/widgets, by name).
        let chained = try file(.claude, cwd: gone).resolved(linked(), repo: "octo-org/widgets", number: 12, env: env)
        XCTAssertEqual([chained.automation.workingDirectory, chained.relinked?.cwd], [widgets, widgets])
        XCTAssertEqual(chained.note, " (folder gone, resumed in \(widgets))")
        try transcript([cwdLine(gadgets)])  // the transcript's launch folder comes first
        let found = try file(.claude, cwd: gone).resolved(linked(), repo: "octo-org/widgets", number: 12, env: env)
        XCTAssertEqual(found.automation.workingDirectory, gadgets)
        XCTAssertEqual(found.relinked?.cwd, gadgets)
        XCTAssertEqual(found.relinked?.sessionID, id)
        let codex = try file(.codex, cwd: gone).resolved(linked(.codex), repo: "octo-org/widgets", number: 12, env: env)
        XCTAssertEqual([codex.automation.workingDirectory, codex.relinked?.cwd], [widgets, widgets])  // Codex resumes by id from anywhere
        var nowhere = file(.codex, cwd: gone)
        nowhere.repoFolders.roots = []
        nowhere.repoFolders.fallback = "~/missing"
        XCTAssertThrowsError(try nowhere.resolved(linked(.codex), repo: "octo-org/widgets", number: 12, env: env)) {
            XCTAssertEqual($0 as? LaunchError, .sessionFolderGone(gone))
        }
        let here = try file(.claude, cwd: widgets).resolved(linked(), repo: "octo-org/widgets", number: 12, env: env)
        XCTAssertEqual([here.automation.workingDirectory, here.note], [widgets, ""])
        XCTAssertNil(here.relinked)
    }

    func testResolvedRefusesAGoneTranscript() throws {
        let widgets = dir.appendingPathComponent("Code/widgets").path
        try transcript([cwdLine(widgets)], id: "someone-else")  // Claude keeps transcripts here, not this one's
        XCTAssertThrowsError(try file(.claude, cwd: widgets).resolved(linked(), repo: "octo-org/widgets", number: 12, env: env)) {
            XCTAssertEqual($0 as? LaunchError, .sessionGone(id))
            XCTAssertEqual($0.localizedDescription, "The session's transcript is gone: \(id)")
        }
        XCTAssertNoThrow(try file(.codex, cwd: widgets).resolved(linked(.codex), repo: "octo-org/widgets", number: 12, env: env))
        XCTAssertEqual(ClaudeSessions.transcriptPath(sessionID: "someone-else", env: env),
                       dir.appendingPathComponent(".claude/projects/-Users-alice-Code/someone-else.jsonl").path)
        XCTAssertNil(ClaudeSessions.transcriptPath(sessionID: "../someone-else", env: env))
    }

    /// Profiles that share one `projects/` through a symlink count once.
    func testProjectDirectoriesDedupeSymlinks() throws {
        try transcript([cwdLine("/x")])
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("profile2"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("profile2/projects"), withDestinationURL: dir.appendingPathComponent(".claude/projects"))
        XCTAssertEqual(ClaudeSessions.projectDirectories(env: env.merging(["CLAUDE_CONFIG_DIR": dir.appendingPathComponent("profile2").path]) { $1 }),
                       [dir.appendingPathComponent("profile2/projects").path])
    }
}
