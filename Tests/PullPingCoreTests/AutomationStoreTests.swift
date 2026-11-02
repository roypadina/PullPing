import XCTest
@testable import PullPingCore

final class AutomationStoreTests: XCTestCase {
    var dir: URL!
    var url: URL { dir.appendingPathComponent("automations.json") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    static func everyField() -> Automation {
        var a = Automation(name: "Fix CI", kinds: [.ciFailed, .reviewApproved], prompt: "Fix {pr_url}", workingDirectory: "~/Code/{repo_name}", createdAt: t0)
        a.enabled = false
        a.scope = .mine
        a.repos = ["octo-org/*"]
        a.actors = ["alice"]
        a.mode = .auto
        a.agent = .codex
        a.agentCommand = "cx"
        a.launcher = .custom
        a.customCommand = "open -a iTerm {script}"
        a.pr = PRRef(repo: "octo-org/widgets", number: 12)
        a.sessionID = "0f3c-session"
        a.maxRunsPerPR = 5
        a.expiresAt = t0.addingTimeInterval(86_400)
        a.source = "cli"
        a.by = "0f3c-session"
        a.autoNoticeAt = t0.addingTimeInterval(60)
        return a
    }

    func testRoundTripEveryField() {
        let store = AutomationStore(url: url)
        var file = AutomationFile()
        file.enabled = false
        file.automations = [Self.everyField()]
        file.runs = [RunRecord(automationID: file.automations[0].id, prID: "PR_1", eventID: "IC_1", at: t0, ok: false, detail: "boom", label: "Fix CI · octo-org/widgets #12")]
        store.mutate { $0 = file }
        XCTAssertEqual(AutomationStore(url: url).load(), file)
    }

    func testMissingKeysTakeDefaults() throws {
        let json = #"""
        { "automations": [ { "id": "00000000-0000-0000-0000-0000000000AA", "name": "R", "kinds": ["comment", "someFutureKind"],
            "prompt": "p", "workingDirectory": "/tmp", "createdAt": "\#(iso(t0))", "launcher": "someFutureLauncher" } ],
          "runs": [ { "automationID": "00000000-0000-0000-0000-0000000000AA", "prID": "PR_1", "eventID": "e", "at": "\#(iso(t0))", "ok": true } ] }
        """#
        try Data(json.utf8).write(to: url)
        let file = AutomationStore(url: url).load()
        let a = try XCTUnwrap(file.automations.first)
        XCTAssertEqual(file.version, 1)
        XCTAssertTrue(file.enabled)
        XCTAssertEqual(a.kinds, [.comment])
        XCTAssertEqual([a.enabled, a.isHook], [true, false])
        XCTAssertEqual(a.scope, .any)
        XCTAssertEqual(a.mode, .ask)
        XCTAssertEqual(a.agent, .claude)
        XCTAssertEqual(a.launcher, .terminal)
        XCTAssertEqual(a.maxRunsPerPR, 3)
        XCTAssertEqual([a.repos, a.actors], [[], []])
        XCTAssertNil(a.sessionID)
        XCTAssertNil(a.expiresAt)
        XCTAssertEqual([a.source, a.by], ["", ""])
        XCTAssertNil(a.autoNoticeAt)
        XCTAssertEqual(file.runs.first?.detail, "")
        XCTAssertEqual(file.runs.first?.label, "")
        XCTAssertEqual([file.repoFolders.roots, [file.repoFolders.fallback]], [["~/Code"], ["~"]])
        XCTAssertEqual(file.handler, Automation.defaultHandler())  // before Handle with Agent: off
        XCTAssertFalse(file.handler.enabled)
        XCTAssertEqual(file.sessions, [])
    }

    static func link(_ repo: String = "octo-org/widgets", _ number: Int = 12, session: String = "0f3c1234-aaaa", at: Date = t0) -> SessionLink {
        SessionLink(pr: PRRef(repo: repo, number: number), agent: .claude, sessionID: session, cwd: "/tmp", setAt: at, source: "cli", by: "alice")
    }

    /// Saved launchers keep decoding; a file with only some Repository Folders keys takes the defaults for the rest.
    func testLaunchersAndRepoFoldersDecode() throws {
        let rules = ["terminal", "ghostex", "custom", "iterm2", "ghostty"].enumerated().map { i, launcher in
            #"{ "id": "00000000-0000-0000-0000-00000000000\#(i)", "name": "R", "kinds": ["comment"], "prompt": "p", "workingDirectory": "/tmp", "createdAt": "\#(iso(t0))", "launcher": "\#(launcher)" }"#
        }
        try Data(#"{ "repoFolders": { "roots": ["~/Code/Padina", "~/Code/Work"] }, "automations": [\#(rules.joined(separator: ","))] }"#.utf8).write(to: url)
        var file = AutomationStore(url: url).load()
        XCTAssertEqual(file.automations.map(\.launcher), [.terminal, .ghostex, .custom, .iterm2, .ghostty])
        XCTAssertEqual(file.repoFolders.roots, ["~/Code/Padina", "~/Code/Work"])
        XCTAssertEqual(file.repoFolders.fallback, "~")
        XCTAssertEqual(file.repoFolders.overrides, [:])  // written before overrides and Look for earlier sessions
        XCTAssertFalse(file.findSessions)
        let edited = try JSONDecoder().decode(RepoFolders.self, from: Data(#"{ "overrides": { "Octo-Org/Widgets": "~/w" } }"#.utf8))
        XCTAssertEqual(edited.overrides, ["octo-org/widgets": "~/w"])  // a hand-edited key still matches
        file.repoFolders.fallback = "~/Inbox"
        AutomationStore(url: url).mutate { $0 = file }
        XCTAssertEqual(AutomationStore(url: url).load(), file)
    }

    func testHandlerAndLinksRoundTrip() {
        let store = AutomationStore(url: url)
        var file = AutomationFile()
        file.handler.enabled = true
        file.handler.agent = .codex
        file.handler.agentCommand = "cx"
        file.handler.prompt = "Handle {pr_url}"
        file.sessions = [Self.link(), Self.link("octo-org/gadgets", 3, session: "thread.2")]
        file.sessions[1].agent = .codex
        store.mutate { $0 = file }
        XCTAssertEqual(AutomationStore(url: url).load(), file)
        XCTAssertEqual(Automation.defaultHandler().id, Automation.handlerID)
        XCTAssertEqual(Automation.defaultHandler().workingDirectory, "{repo_dir}")
    }

    /// A new handler gets the actionable kinds; one saved before the choice keeps [] (every kind).
    func testHandlerKinds() throws {
        XCTAssertEqual(Automation.defaultHandler().kinds, [.comment, .mentioned, .reviewRequested, .reviewChangesRequested, .reviewCommented,
                                                           .reviewApproved, .reviewDismissed, .assigned, .ciFailed, .readyForReview, .reopened])
        XCTAssertEqual(AutomationFile().handler.kinds, Automation.defaultHandlerKinds)
        let old = #"{ "handler": { "id": "00000000-0000-4000-8000-00000000AC71", "name": "Handle with Agent", "kinds": [], "prompt": "p", "workingDirectory": "{repo_dir}", "createdAt": "\#(iso(t0))" } }"#
        try Data(old.utf8).write(to: url)
        XCTAssertEqual(AutomationStore(url: url).load().handler.kinds, [])
    }

    func testSetLinkReplacesCaseInsensitively() {
        var file = AutomationFile()
        file.setLink(Self.link())
        file.setLink(Self.link("octo-org/gadgets", 12))
        file.setLink(Self.link("Octo-Org/Widgets", 12, session: "newer"))
        XCTAssertEqual(file.sessions.map(\.pr.repo), ["octo-org/gadgets", "Octo-Org/Widgets"])  // same number, other repo: kept
        XCTAssertEqual(file.link(for: "OCTO-ORG/widgets", number: 12)?.sessionID, "newer")
        XCTAssertNil(file.link(for: "octo-org/widgets", number: 13))
    }

    func testEnabledRoundTrips() {
        let store = AutomationStore(url: url)
        store.mutate { $0.enabled = false }
        XCTAssertFalse(AutomationStore(url: url).load().enabled)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains(#""enabled" : false"#))
        store.mutate { $0.enabled = true }
        XCTAssertTrue(AutomationStore(url: url).load().enabled)
    }

    func testCorruptFileIsMovedAside() throws {
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(AutomationStore(url: url).load(), AutomationFile())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("automations.broken.json"), encoding: .utf8), "not json")
    }

    func testConcurrentMutateKeepsEveryRecord() {
        let id = UUID()
        DispatchQueue.concurrentPerform(iterations: 2) { thread in
            let store = AutomationStore(url: url)  // own instance per thread, like the app and the CLI
            for i in 0..<200 {
                store.mutate { $0.runs.append(RunRecord(automationID: id, prID: "PR_\(thread)", eventID: "\(i)", at: t0, ok: true, detail: "")) }
            }
        }
        let runs = AutomationStore(url: url).load().runs
        XCTAssertEqual(runs.count, 400)
        XCTAssertEqual(Set(runs.map { "\($0.prID)/\($0.eventID)" }).count, 400)
    }

    func testMemoryStore() {
        let store = AutomationStore(url: nil)
        store.mutate { $0.automations.append(Automation(name: "R", kinds: [.comment], workingDirectory: "/tmp")) }
        XCTAssertEqual(store.load().automations.count, 1)
    }

    func testPrune() {
        var file = AutomationFile()
        let rule = Automation(name: "Rule", kinds: [.comment], workingDirectory: "/tmp")
        var expired = Self.everyField(), exhausted = Self.everyField(), live = Self.everyField(), failedOnly = Self.everyField()  // each a new id
        expired.expiresAt = t0
        exhausted.maxRunsPerPR = 1
        exhausted.expiresAt = t0.addingTimeInterval(60)
        live.expiresAt = t0.addingTimeInterval(60)
        failedOnly.maxRunsPerPR = 1
        failedOnly.expiresAt = t0.addingTimeInterval(60)
        file.automations = [rule, expired, exhausted, live, failedOnly]
        file.runs = (0..<AutomationFile.runCap).map { RunRecord(automationID: rule.id, prID: "PR_1", eventID: "\($0)", at: t0, ok: true, detail: "") }
        file.runs.append(RunRecord(automationID: exhausted.id, prID: "PR_1", eventID: "e", at: t0, ok: true, detail: ""))
        file.runs.append(RunRecord(automationID: failedOnly.id, prID: "PR_1", eventID: "e", at: t0, ok: false, detail: "boom"))
        AutomationStore.prune(&file, now: t0)
        XCTAssertEqual(file.automations.map(\.id), [rule.id, live.id, failedOnly.id])  // rules never pruned, even past maxRuns
        XCTAssertEqual(file.runs.count, AutomationFile.runCap)
        XCTAssertEqual(file.runs.first?.eventID, "2")  // oldest dropped first
    }

    func testPruneDropsLinksAfter30Days() {
        var file = AutomationFile()
        file.sessions = [Self.link("octo-org/widgets", 1, at: t0.addingTimeInterval(-29 * 86_400)), Self.link("octo-org/widgets", 2, at: t0.addingTimeInterval(-31 * 86_400))]
        AutomationStore.prune(&file, now: t0)
        XCTAssertEqual(file.sessions.map(\.pr.number), [1])
    }
}
