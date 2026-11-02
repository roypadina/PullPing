import XCTest
@testable import PullPingCore

final class LaunchPlannerTests: XCTestCase {
    var home: URL!
    var cwd: String { home.appendingPathComponent("Code/widgets").path }
    let runs = URL(fileURLWithPath: "/tmp/pp runs")

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Code/widgets"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    var pr: TrackedPR {
        var pr = TrackedPR(id: "PR_1", accountID: UUID(), firstTrackedAt: t0)
        pr.repo = "octo-org/widgets"
        pr.number = 12
        pr.title = "Add\nwidget cache"
        pr.url = URL(string: "https://github.com/octo-org/widgets/pull/12")!
        pr.authorLogin = "bob"
        pr.headOID = "abc123"
        return pr
    }

    let event = PREvent(id: "PRR_1", prID: "PR_1", kind: .reviewApproved, actor: "alice", at: t0, summary: "LGTM\u{7}", url: nil, isOwn: false)

    func automation(_ prompt: String = "x", agent: AgentKind = .claude, session: String? = nil, command: String = "",
                    launcher: Launcher = .terminal, custom: String = "") -> Automation {
        var a = Automation(name: "Follow up", kinds: [.reviewApproved], prompt: prompt, workingDirectory: "~/Code/{repo_name}", createdAt: t0)
        a.agent = agent
        a.sessionID = session
        a.agentCommand = command
        a.launcher = launcher
        a.customCommand = custom
        return a
    }

    func plan(_ a: Automation, event: PREvent? = nil) throws -> LaunchPlan {
        try LaunchPlanner.plan(a, pr: pr, event: event ?? self.event, account: "dana", runID: "RUN", runsDir: runs, home: home.path)
    }

    func testEveryPlaceholder() throws {
        let tokens = ["pr_url", "pr_number", "repo", "repo_owner", "repo_name", "is_issue", "head_sha", "event", "event_label", "account",
                      "session_id", "cwd", "automation", "title", "author", "actor", "summary"]
        let p = try plan(automation(tokens.map { "\($0)={\($0)}" }.joined(separator: "|"), session: "sid-1"))
        XCTAssertEqual(p.promptText, "pr_url=https://github.com/octo-org/widgets/pull/12|pr_number=12|repo=octo-org/widgets|repo_owner=octo-org|repo_name=widgets|is_issue=false|head_sha=abc123|event=reviewApproved|event_label=Review approved|account=dana|session_id=sid-1|cwd=\(cwd)|automation=Follow up|title=Add widget cache|author=bob|actor=alice|summary=LGTM")
        let manual = try LaunchPlanner.plan(automation("{event} {event_label} {actor}"), pr: pr, event: nil, account: "dana", runID: "R", runsDir: runs, home: home.path)
        XCTAssertEqual(manual.promptText, "\nmanual Manual run dana")
    }

    func testUnknownTokensStayAndValuesAreNotReexpanded() throws {
        var p = pr
        p.title = "{cwd} {}"
        let a = automation("{nope} {} {title} {Repo}")
        XCTAssertEqual(try LaunchPlanner.plan(a, pr: p, event: event, account: "dana", runID: "R", runsDir: runs, home: home.path).promptText,
                       "\n{nope} {} {cwd} {} {Repo}")  // starts with a placeholder: guarded
    }

    func testCleanStripsControlsAndCaps() {
        XCTAssertEqual(PromptTemplate.clean("a\nb\r\nc\t\u{1B}[31md\u{85}e\u{7F}", max: 100), "a b  c  [31md e")
        XCTAssertEqual(PromptTemplate.clean("  \n" + String(repeating: "x", count: 300), max: 200).count, 200)
        XCTAssertEqual(try plan(automation("{summary}"), event: PREvent(id: "e", prID: "PR_1", kind: .comment, actor: String(repeating: "m", count: 80), at: t0,
                                                                        summary: String(repeating: "s", count: 150), url: nil, isOwn: false)).promptText.count, 121)  // "\n" guard
    }

    /// The quoted string comes back unchanged from a real shell.
    func testShellQuoteRoundTripsThroughSh() throws {
        for s in ["it's", "two words", "$(touch /tmp/pp-pwned) `id` $HOME", "line\nbreak", "'", "", "a'\"b\\c"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-fc", "printf %s \(LaunchPlanner.shellQuote(s))"]
            let out = Pipe()
            process.standardOutput = out
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), s)
        }
        XCTAssertEqual(LaunchPlanner.shellQuote("it's"), #"'it'\''s'"#)
    }

    func testScripts() throws {
        let prompt = #""$(< '/tmp/pp runs/RUN.prompt.md')""#
        let cases: [(AgentKind, String?, String, String)] = [
            (.claude, nil, "", #"\claude "# + prompt),
            (.claude, "0f3c-1", "", #"\claude --resume '0f3c-1' "# + prompt),
            (.codex, nil, "", #"\codex "# + prompt),
            (.codex, "thread.2", "", #"\codex resume 'thread.2' "# + prompt),
            (.claude, "0f3c-1", "cc", "cc --resume '0f3c-1' \(prompt)"),
            (.codex, nil, "cx", "cx \(prompt)"),
        ]
        for (agent, session, command, line) in cases {
            let p = try plan(automation(agent: agent, session: session, command: command))
            XCTAssertEqual(p.script, """
                #!/bin/zsh -il
                # PullPing automation "Follow up" — octo-org/widgets #12 — reviewApproved
                cd '\(cwd)' || exit 1
                \(line)
                exec /bin/zsh -il

                """)
            XCTAssertFalse(p.script.contains("dangerously") || p.script.contains("permission") || p.script.contains("full-auto"))
        }
        XCTAssertEqual(try plan(automation()).promptPath, "/tmp/pp runs/RUN.prompt.md")
        XCTAssertEqual(try plan(automation()).scriptPath, "/tmp/pp runs/RUN.command")
    }

    /// GitHub text at the start of the prompt never reaches the agent as an option or a subcommand: printf stands in for
    /// the agent and shows the argument a real zsh hands it, for both agents, new and resumed.
    func testPromptStartingWithGitHubTextIsNeverAnOption() throws {
        let attack = PREvent(id: "e", prID: "PR_1", kind: .comment, actor: "mallory", at: t0, summary: #"--settings={"hooks":{}}"#, url: nil, isOwn: false)
        let dir = home.appendingPathComponent("runs")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for agent in AgentKind.allCases {
            for session in [nil, "sid-1"] {
                let a = automation("{summary}\n\nAddress this on {pr_url}", agent: agent, session: session, command: "printf '<%s>'")
                let p = try LaunchPlanner.plan(a, pr: pr, event: attack, account: "dana", runID: "RUN", runsDir: dir, home: home.path)
                XCTAssertEqual(p.promptText, "\n--settings={\"hooks\":{}}\n\nAddress this on https://github.com/octo-org/widgets/pull/12")
                try p.promptText.write(toFile: p.promptPath, atomically: true, encoding: .utf8)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-fc", String(p.script.split(separator: "\n")[3])]  // the agent line
                let out = Pipe()
                process.standardOutput = out
                try process.run()
                process.waitUntilExit()
                let args = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let expected = session == nil ? "" : (agent == .claude ? "<--resume><sid-1>" : "<resume><sid-1>")
                XCTAssertEqual(args, expected + "<\(p.promptText)>", "\(agent) \(session ?? "new")")
            }
        }
        let bare = PREvent(id: "e", prID: "PR_1", kind: .comment, actor: "mallory", at: t0, summary: "logout", url: nil, isOwn: false)
        XCTAssertEqual(try plan(automation("{summary}", agent: .codex), event: bare).promptText, "\nlogout")  // not `codex logout`
        XCTAssertEqual(try plan(automation("-x {pr_number}")).promptText, "\n-x 12")
        XCTAssertEqual(try plan(automation("Fix {summary}")).promptText, "Fix LGTM")  // text first: unchanged
    }

    /// New Claude sessions start with an id PullPing picked (so the pull request can link them); resumes and Codex never get one.
    func testNewSessionID() throws {
        let id = try XCTUnwrap(LaunchPlanner.newSessionID(for: automation()))
        XCTAssertNotNil(UUID(uuidString: id))
        XCTAssertEqual(id, id.lowercased())
        XCTAssertNil(LaunchPlanner.newSessionID(for: automation(session: "0f3c-1")))
        XCTAssertNil(LaunchPlanner.newSessionID(for: automation(agent: .codex)))
        let prompt = #""$(< '/tmp/pp runs/RUN.prompt.md')""#
        let cases: [(AgentKind, String?, String, String)] = [
            (.claude, nil, "", #"\claude --session-id '\#(id)' "# + prompt),
            (.claude, nil, "cc", "cc --session-id '\(id)' \(prompt)"),
            (.claude, "0f3c-1", "", #"\claude --resume '0f3c-1' "# + prompt),  // a resume keeps its own id
            (.codex, nil, "", #"\codex "# + prompt),
        ]
        for (agent, session, command, line) in cases {
            let p = try LaunchPlanner.plan(automation(agent: agent, session: session, command: command), pr: pr, event: event, account: "dana",
                                           runID: "RUN", runsDir: runs, home: home.path, newSessionID: id)
            XCTAssertEqual(String(p.script.split(separator: "\n")[3]), line)
            XCTAssertFalse(p.script.contains("dangerously") || p.script.contains("permission") || p.script.contains("full-auto"))
        }
        XCTAssertThrowsError(try LaunchPlanner.plan(automation(), pr: pr, event: event, account: "dana", runID: "R", runsDir: runs, home: home.path,
                                                    newSessionID: "x'; rm -rf ~")) { XCTAssertEqual($0 as? LaunchError, .badSessionID) }
    }

    func testNameStaysOnTheCommentLine() throws {
        var a = automation()
        a.name = "evil\nrm -rf ~"
        XCTAssertTrue(try plan(a).script.contains("# PullPing automation \"evil rm -rf ~\""))
    }

    func testLaunchLines() throws {
        XCTAssertEqual(try plan(automation(launcher: .terminal)).launchLine, "open -a Terminal '/tmp/pp runs/RUN.command'")
        XCTAssertEqual(try plan(automation(launcher: .ghostex)).launchLine,
                       "ghostex terminal --cwd '\(cwd)' --title 'PullPing: octo-org/widgets #12' -- '/tmp/pp runs/RUN.command'")
        XCTAssertEqual(try plan(automation(launcher: .iterm2)).launchLine, "open -b com.googlecode.iterm2 '/tmp/pp runs/RUN.command'")
        XCTAssertEqual(try plan(automation(launcher: .ghostty)).launchLine,
                       "osascript -e 'on run argv' -e 'tell application id \"com.mitchellh.ghostty\"' -e 'set cfg to new surface configuration' "
                       + "-e 'set initial working directory of cfg to item 1 of argv' -e 'set command of cfg to item 2 of argv' "
                       + "-e 'new window with configuration cfg' -e 'activate' -e 'end tell' -e 'end run' '\(cwd)' "
                       + #"'/bin/zsh -il '\''/tmp/pp runs/RUN.command'\'''"#)
        let custom = try plan(automation(launcher: .custom, custom: "my-launch {script} {cwd} {title} {prompt_file} {agent_command} {pr_url}"))
        XCTAssertEqual(custom.launchLine, #"my-launch '/tmp/pp runs/RUN.command' '\#(cwd)' 'PullPing: octo-org/widgets #12' '/tmp/pp runs/RUN.prompt.md' '\claude "$(< '\''/tmp/pp runs/RUN.prompt.md'\'')"' {pr_url}"#)
    }

    func testErrors() throws {
        var a = automation()
        a.workingDirectory = "~/Missing"
        XCTAssertThrowsError(try plan(a)) { XCTAssertEqual($0 as? LaunchError, .badWorkingDirectory(home.path + "/Missing")) }
        a.workingDirectory = "~/Code/widgets/../widgets"
        XCTAssertThrowsError(try plan(a)) { XCTAssertEqual($0 as? LaunchError, .badWorkingDirectory(home.path + "/Code/widgets/../widgets")) }
        a.workingDirectory = "Code/widgets"  // relative
        XCTAssertThrowsError(try plan(a)) { XCTAssertEqual($0 as? LaunchError, .badWorkingDirectory("Code/widgets")) }
        XCTAssertThrowsError(try plan(automation(session: "abc; rm -rf ~"))) { XCTAssertEqual($0 as? LaunchError, .badSessionID) }
        XCTAssertThrowsError(try plan(automation(session: String(repeating: "a", count: 129)))) { XCTAssertEqual($0 as? LaunchError, .badSessionID) }
        XCTAssertThrowsError(try plan(automation(launcher: .custom, custom: "  "))) { XCTAssertEqual($0 as? LaunchError, .emptyCustomCommand) }
        var bad = pr
        bad.repo = "octo-org/wid gets"
        XCTAssertThrowsError(try LaunchPlanner.plan(automation(), pr: bad, event: nil, account: "dana", runID: "R", runsDir: runs, home: home.path))
    }

    func testNotInstalled() throws {
        func plan(_ launcher: Launcher) throws -> LaunchPlan {
            try LaunchPlanner.plan(automation(launcher: launcher, custom: "x"), pr: pr, event: nil, account: "dana", runID: "R", runsDir: runs,
                                   home: home.path, installed: { $0 != .iterm2 })
        }
        XCTAssertThrowsError(try plan(.iterm2)) {
            XCTAssertEqual($0 as? LaunchError, .notInstalled("iTerm2"))
            XCTAssertEqual($0.localizedDescription, "iTerm2 is not installed; choose another app under Open in (--launcher)")
        }
        XCTAssertNoThrow(try plan(.ghostty))
        XCTAssertEqual(Launcher.allCases.filter { $0.bundleID == nil }, [.custom])  // only Custom needs no app
    }

    /// `{repo_dir}`: the first root (in order) holding the repository in any case, else the fallback; the result is checked like any cwd.
    func testRepoDir() throws {
        let fm = FileManager.default
        for path in ["Code/Padina/Widgets", "Code/Work/widgets", "Inbox", "Files"] {
            try fm.createDirectory(at: home.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try Data().write(to: home.appendingPathComponent("Files/widgets"))  // a file, not a folder
        var folders = RepoFolders()
        func dir() throws -> String {
            var a = automation("in {repo_dir}")
            a.workingDirectory = "{repo_dir}"
            let p = try LaunchPlanner.plan(a, pr: pr, event: nil, account: "dana", runID: "R", runsDir: runs, home: home.path, folders: folders)
            XCTAssertEqual(p.promptText, "in \(p.cwd)")
            return p.cwd
        }
        XCTAssertEqual(try dir(), cwd)  // default ~/Code: ~/Code/widgets
        folders.roots = ["~/Missing", "~/Files", "Code", "~/Code/Padina", "~/Code/Work"]
        XCTAssertEqual(try dir(), home.path + "/Code/Padina/Widgets")  // missing, file-only and relative roots skipped; the folder's own case
        folders.roots.removeAll { $0 == "~/Code/Padina" }
        XCTAssertEqual(try dir(), home.path + "/Code/Work/widgets")
        folders.roots = ["~/Code/Padina/Widgets"]  // not cloned anywhere: the fallback
        XCTAssertEqual(try dir(), home.path)
        folders.fallback = "~/Inbox"
        XCTAssertEqual(try dir(), home.path + "/Inbox")
        folders.fallback = "~/Gone"
        XCTAssertThrowsError(try dir()) { XCTAssertEqual($0 as? LaunchError, .badWorkingDirectory(home.path + "/Gone")) }
        folders.fallback = "~/Inbox/../Inbox"
        XCTAssertThrowsError(try dir()) { XCTAssertEqual($0 as? LaunchError, .badWorkingDirectory(home.path + "/Inbox/../Inbox")) }
    }

    func testWorkingDirectoryResolution() throws {
        XCTAssertEqual(try plan(automation()).cwd, cwd)  // ~/Code/{repo_name}
        var a = automation()
        a.workingDirectory = "~"
        XCTAssertEqual(try plan(a).cwd, home.path)
        a.workingDirectory = cwd
        XCTAssertEqual(try plan(a).cwd, cwd)
        var p = pr
        p.title = "widgets"  // GitHub text never picks the folder
        a.workingDirectory = "~/Code/{title}"
        XCTAssertThrowsError(try LaunchPlanner.plan(a, pr: p, event: event, account: "dana", runID: "R", runsDir: runs, home: home.path)) {
            XCTAssertEqual($0 as? LaunchError, .badWorkingDirectory(home.path + "/Code/{title}"))
        }
        p.headRef = "widgets"  // nor the branch name
        a.workingDirectory = "~/Code/{branch}"
        XCTAssertThrowsError(try LaunchPlanner.plan(a, pr: p, event: event, account: "dana", runID: "R", runsDir: runs, home: home.path)) {
            XCTAssertEqual($0 as? LaunchError, .badWorkingDirectory(home.path + "/Code/{branch}"))
        }
    }

    func testBranch() throws {
        var p = pr
        p.headRef = "feature/cache\u{7}"
        let a = automation("on {branch}.")
        XCTAssertEqual(try LaunchPlanner.plan(a, pr: p, event: nil, account: "", runID: "R", runsDir: runs, home: home.path).promptText, "on feature/cache.")
        p.headRef = nil  // not refreshed since 0.5.0
        XCTAssertEqual(try LaunchPlanner.plan(a, pr: p, event: nil, account: "", runID: "R", runsDir: runs, home: home.path).promptText, "on .")
        p.headRef = "main"
        p.isIssue = true
        XCTAssertEqual(try LaunchPlanner.plan(a, pr: p, event: nil, account: "", runID: "R", runsDir: runs, home: home.path).promptText, "on .")
    }

    func testLaunchEnvironmentDropsAgentSessionVariables() {
        let env = ["PATH": "/usr/bin", "HOME": "/Users/dana", "CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "s", "CLAUDE_CODE_CHILD_SESSION": "1",
                   "SESSIONHOPPER_PROFILE": "p", "CODEX_HOME": "/x", "AGENTCTL_SESSION": "a", "MY_CLAUDE": "kept", "PULLPING_STATE": "/s"]
        XCTAssertEqual(LaunchPlanner.launchEnvironment(env), ["PATH": "/usr/bin", "HOME": "/Users/dana", "MY_CLAUDE": "kept", "PULLPING_STATE": "/s"])
    }
}
