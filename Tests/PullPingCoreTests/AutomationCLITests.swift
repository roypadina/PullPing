import XCTest
@testable import PullPingCore

final class AutomationCLITests: XCTestCase {
    var dir: URL!
    var store: AutomationStore!
    var env: [String: String] { ["PWD": dir.path, "HOME": dir.path] }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("work"), withIntermediateDirectories: true)
        store = AutomationStore(url: dir.appendingPathComponent("automations.json"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    func run(_ line: [String], env extra: [String: String] = [:]) -> (output: String, error: String, status: Int32) {
        AutomationCLI.run(line, store: store, env: env.merging(extra) { $1 }, now: t0)
    }

    func add(_ extra: [String] = [], pr: String = "octo-org/widgets#12") -> (output: String, error: String, status: Int32) {
        run(["hook", "add", "--pr", pr, "--on", "reviewApproved,comment", "--prompt", "Go {pr_url}"] + extra)
    }

    var hooks: [Automation] { store.load().automations }

    func testAddWithDefaults() throws {
        let result = add()
        XCTAssertEqual(result.status, 0, result.error)
        let hook = try XCTUnwrap(hooks.first)
        XCTAssertEqual(result.output, "Added hook \(hook.id.uuidString.lowercased().prefix(8)): reviewApproved, comment on octo-org/widgets #12 → claude (new session) in Terminal, ask.")
        XCTAssertEqual(hook.pr, PRRef(repo: "octo-org/widgets", number: 12))
        XCTAssertEqual(hook.kinds, [.reviewApproved, .comment])
        XCTAssertEqual(hook.name, "octo-org/widgets #12 hook")
        XCTAssertEqual(hook.prompt, "Go {pr_url}")
        XCTAssertEqual(hook.workingDirectory, "{repo_dir}")  // a new session: the repository's folder
        XCTAssertEqual(hook.agent, .claude)
        XCTAssertEqual(hook.launcher, .terminal)
        XCTAssertEqual(hook.mode, .ask)
        XCTAssertEqual(hook.maxRunsPerPR, 1)
        XCTAssertEqual(hook.expiresAt, t0.addingTimeInterval(14 * 86_400))
        XCTAssertNil(hook.sessionID)
        XCTAssertEqual(hook.createdAt, t0)
    }

    func testAddWithOptions() throws {
        try Data("From a file {repo}".utf8).write(to: dir.appendingPathComponent("prompt.md"))
        let result = run(["hook", "add", "--pr", "https://github.com/octo-org/widgets/issues/7", "--on", "comment", "--prompt-file", "prompt.md",
                          "--session", "0f3c1234-aaaa", "--agent", "codex", "--command", "cx", "--cwd", "work", "--launcher", "custom",
                          "--custom-command", "open -a iTerm {script}", "--auto", "--repeat", "3", "--expires", "2", "--actors", "alice, bob",
                          "--name", "Watch issue"])
        XCTAssertEqual(result.status, 0, result.error)
        XCTAssertTrue(result.output.hasSuffix(": comment on octo-org/widgets #7 → cx (resume 0f3c…) in Custom command, auto."), result.output)
        let hook = try XCTUnwrap(hooks.first)
        XCTAssertEqual(hook.pr, PRRef(repo: "octo-org/widgets", number: 7))
        XCTAssertEqual(hook.prompt, "From a file {repo}")
        XCTAssertEqual(hook.sessionID, "0f3c1234-aaaa")
        XCTAssertEqual(hook.agent, .codex)
        XCTAssertEqual(hook.agentCommand, "cx")
        XCTAssertEqual(hook.workingDirectory, dir.appendingPathComponent("work").path)
        XCTAssertEqual(hook.customCommand, "open -a iTerm {script}")
        XCTAssertEqual(hook.mode, .auto)
        XCTAssertEqual(hook.maxRunsPerPR, 3)
        XCTAssertEqual(hook.expiresAt, t0.addingTimeInterval(2 * 86_400))
        XCTAssertEqual(hook.actors, ["alice", "bob"])
        XCTAssertEqual(hook.name, "Watch issue")
        XCTAssertEqual(add(pr: "https://github.com/octo-org/widgets/pull/12/files").status, 0)
        XCTAssertEqual(hooks.last?.pr, PRRef(repo: "octo-org/widgets", number: 12))
    }

    func testValidationErrors() {
        let base = ["hook", "add", "--pr", "octo-org/widgets#12", "--on", "comment", "--prompt", "p"]
        let bad: [[String]] = [
            ["hook", "add", "--on", "comment", "--prompt", "p"],  // no --pr
            ["hook", "add", "--pr", "octo-org/widgets#0", "--on", "comment", "--prompt", "p"],
            ["hook", "add", "--pr", "octo org/widgets#1", "--on", "comment", "--prompt", "p"],
            ["hook", "add", "--pr", "https://github.com/octo-org/widgets/commits/1", "--on", "comment", "--prompt", "p"],
            ["hook", "add", "--pr", "octo-org/widgets#12", "--prompt", "p"],  // no --on
            ["hook", "add", "--pr", "octo-org/widgets#12", "--on", "comment,approved", "--prompt", "p"],
            ["hook", "add", "--pr", "octo-org/widgets#12", "--on", "reviewReminder", "--prompt", "p"],
            ["hook", "add", "--pr", "octo-org/widgets#12", "--on", "comment"],  // no prompt
            ["hook", "add", "--pr", "octo-org/widgets#12", "--on", "comment", "--prompt", "  \n"],
            ["hook", "add", "--pr", "octo-org/widgets#12", "--on", "comment", "--prompt", "p", "--prompt-file", "x"],
            ["hook", "add", "--pr", "octo-org/widgets#12", "--on", "comment", "--prompt-file", "missing.md"],
            base + ["--session", "abc; rm -rf ~"],
            base + ["--agent", "gemini"],
            base + ["--launcher", "iterm"],
            base + ["--launcher", "custom"],
            base + ["--cwd", "missing"],
            base + ["--repeat", "0"],
            base + ["--repeat", "11"],
            base + ["--expires", "zero"],
            base + ["--bogus", "1"],
            base + ["stray"],
            base + ["--name"],  // missing value
        ]
        for args in bad {
            let result = run(args)
            XCTAssertEqual(result.status, 2, "\(args): \(result.output)")
            XCTAssertTrue(result.error.hasPrefix("pullping: "), result.error)
            XCTAssertTrue(result.output.isEmpty)
        }
        XCTAssertTrue(hooks.isEmpty)
        XCTAssertTrue(run(base + ["--session", ""]).error.contains("--session is empty"))
        XCTAssertEqual(run(["hook", "launch"]).status, 2)
        XCTAssertEqual(run(["bogus"]).status, 2)
    }

    func testListTextAndJSON() throws {
        XCTAssertEqual(run(["hook", "list"]).output, "No hooks.")
        add(["--session", "0f3c1234"])
        add(pr: "octo-org/gadgets#3")
        store.mutate { $0.automations.append(Automation(name: "A rule", kinds: [.comment], workingDirectory: "/tmp")) }  // rules aren't listed
        let lines = run(["hook", "list"]).output.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix("  octo-org/widgets #12  comment,reviewApproved  claude  resume 0f3c…  ask  expires 2027-01-29  on  cli"), String(lines[0]))
        XCTAssertEqual(run(["hook", "list", "--pr", "https://github.com/Octo-Org/widgets/pull/12"]).output.split(separator: "\n").count, 1)
        let json = run(["hook", "list", "--json"]).output
        let decoded = try StateStore.decoder.decode([Automation].self, from: Data(json.utf8))
        XCTAssertEqual(decoded, Array(hooks.prefix(2)))
    }

    func testRemove() throws {
        add()
        add()
        add(pr: "octo-org/gadgets#3")
        let id = hooks[0].id.uuidString.lowercased()
        XCTAssertEqual(run(["hook", "rm", "abc"]).status, 2)  // too short
        XCTAssertEqual(run(["hook", "rm", "ffffffff"]).status, 1)  // no match
        XCTAssertEqual(run(["hook", "rm", String(id.prefix(8))]).output, "Removed hook \(id.prefix(8)) on octo-org/widgets #12.")
        XCTAssertEqual(hooks.count, 2)
        XCTAssertEqual(run(["hook", "rm", "--pr", "octo-org/widgets#12"]).status, 2)  // needs --all
        XCTAssertEqual(run(["hook", "rm", "--pr", "octo-org/widgets#12", "--all"]).output, "Removed 1 hook on octo-org/widgets #12.")
        XCTAssertEqual(hooks.map(\.pr?.repo), ["octo-org/gadgets"])
    }

    func testAmbiguousPrefix() {
        let one = UUID(uuidString: "ABCD0000-0000-0000-0000-000000000001")!, two = UUID(uuidString: "ABCD0000-0000-0000-0000-000000000002")!
        store.mutate { file in
            for id in [one, two] {
                var hook = Automation(id: id, name: "h", kinds: [.comment], workingDirectory: "/tmp")
                hook.pr = PRRef(repo: "octo-org/widgets", number: 1)
                file.automations.append(hook)
            }
        }
        let result = run(["hook", "rm", "abcd"])
        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.error.contains("matches 2 hooks"))
        XCTAssertEqual(hooks.count, 2)
        XCTAssertEqual(run(["hook", "rm", "abcd0000-0000-0000-0000-000000000002"]).status, 0)
    }

    func testKindsAndHelp() {
        let kinds = run(["hook", "kinds"]).output.split(separator: "\n")
        XCTAssertEqual(kinds.count, EventKind.allCases.count - 1)
        XCTAssertTrue(kinds.contains { $0.hasPrefix("reviewApproved") && $0.hasSuffix("Review approved") })
        XCTAssertFalse(kinds.contains { $0.hasPrefix("reviewReminder") })
        let helps = [["hook", "--help"]: "hook", ["hook"]: "hook", ["hook", "help"]: "hook", ["hook", "add", "--pr", "x", "--help"]: "hook",
                     ["rule"]: "rule", ["rule", "edit", "--help"]: "rule", ["runs", "--help"]: "runs", ["automations"]: "automations",
                     ["automations", "on", "--help"]: "automations", ["--help"]: "<command>", ["help"]: "<command>", []: "<command>",
                     ["session"]: "session", ["session", "set", "--help"]: "session", ["handler"]: "handler", ["handler", "set", "--help"]: "handler"]
        for (args, group) in helps {
            let result = run(args)
            XCTAssertEqual(result.status, 0, "\(args)")
            XCTAssertTrue(result.output.hasPrefix("Usage: pullping \(group)"), "\(args)")
        }
        XCTAssertEqual(run(["kinds"]).output, run(["hook", "kinds"]).output)
        for help in [AutomationCLI.ruleHelp, AutomationCLI.hookHelp] {
            XCTAssertTrue(help.contains(#"PullPing automation "{automation}""#))  // shows the default prompt
            XCTAssertTrue(help.contains("--expires <days>") && help.contains("--scope any|mine|others"))  // one shared options block
        }
        XCTAssertTrue(run(["rule", "bogus"]).error.hasSuffix("Run `pullping rule --help` for usage."))
        XCTAssertEqual(run(["automations", "folders"]).output, AutomationCLI.automationsHelp)
    }

    func testLaunchers() throws {
        func cli(_ args: [String]) -> (output: String, error: String, status: Int32) {
            AutomationCLI.run(args, store: store, env: env, now: t0, installed: { $0 != .iterm2 })
        }
        XCTAssertEqual(cli(["launchers"]).output, """
            terminal    Terminal
            iterm2      iTerm2 (not installed)
            ghostty     Ghostty
            ghostex     Ghostex
            custom      Custom command
            """)
        let json = try JSONSerialization.jsonObject(with: Data(cli(["launchers", "--json"]).output.utf8)) as? [[String: Any]]
        XCTAssertEqual(json?.map { $0["id"] as? String }, Launcher.allCases.map(\.rawValue))
        XCTAssertEqual(json?.map { $0["installed"] as? Bool }, [true, false, true, true, true])
        let base = ["rule", "add", "--name", "R", "--on", "comment"]
        let missing = cli(base + ["--launcher", "iterm2"])
        XCTAssertEqual(missing.status, 2)
        XCTAssertTrue(missing.error.hasPrefix("pullping: --launcher iterm2: iTerm2 is not installed"), missing.error)
        XCTAssertTrue(cli(base + ["--launcher", "iterm"]).error.contains("--launcher must be terminal, iterm2, ghostty, ghostex or custom"))
        XCTAssertEqual(cli(["handler", "set", "--launcher", "iterm2"]).status, 2)
        XCTAssertTrue(hooks.isEmpty)
        XCTAssertEqual(cli(base + ["--launcher", "ghostty"]).status, 0)
        XCTAssertEqual(last.launcher, .ghostty)
        XCTAssertEqual(run(base + ["--launcher", "iterm2"]).status, 0)  // installed
        XCTAssertEqual(cli(["rule", "edit", short(last), "--name", "Renamed"]).status, 0)  // a saved launcher isn't rechecked
    }

    func testRepoFolders() throws {
        XCTAssertTrue(run(["automations", "folders", "list"]).output.hasPrefix("~/Code\nfallback: ~\nrepos scanned: 0 ("))
        XCTAssertEqual(run(["automations", "folders", "add", "work"]).output, "Added \(dir.path)/work to the repository folders.")
        XCTAssertEqual(run(["automations", "folders", "add", "~/work"]).output, "~/work is already a repository folder.")  // HOME is the test folder
        XCTAssertEqual(run(["automations", "folders", "add", "~"]).status, 0)
        for bad in [["add", "missing"], ["add", "~/{repo_name}"], ["add", "/tmp/../tmp"], ["add"], ["add", "a", "b"], ["bogus"]] {
            XCTAssertEqual(run(["automations", "folders"] + bad).status, 2, "\(bad)")
        }
        let json = try JSONSerialization.jsonObject(with: Data(run(["automations", "folders", "list", "--json"]).output.utf8)) as? [String: Any]
        XCTAssertEqual(json?["folders"] as? [String], ["~/Code", dir.path + "/work", "~"])
        XCTAssertEqual(json?["fallback"] as? String, "~")
        XCTAssertEqual(run(["automations", "folders", "rm", "~/work"]).output, "Removed ~/work from the repository folders.")  // same folder, other spelling
        XCTAssertEqual(run(["automations", "folders", "rm", "~/work"]).status, 1)
        XCTAssertEqual(store.load().repoFolders.roots, ["~/Code", "~"])
        XCTAssertEqual(run(["automations", "fallback"]).output, "~")
        XCTAssertEqual(run(["automations", "fallback", "~/work"]).output, "Fallback folder: ~/work.")
        XCTAssertEqual(run(["automations", "fallback", "missing"]).status, 2)
        XCTAssertEqual(store.load().repoFolders.fallback, "~/work")
    }

    // MARK: Rules, edit, show, list, runs, automations

    var last: Automation { hooks.last! }
    func short(_ a: Automation) -> String { String(a.id.uuidString.lowercased().prefix(8)) }

    func addRule(_ extra: [String] = []) -> (output: String, error: String, status: Int32) {
        run(["rule", "add", "--name", "Fix failing CI", "--on", "ciFailed", "--cwd", "~/Code/{repo_name}"] + extra)
    }

    func testRuleAddDefaults() throws {
        let result = addRule()
        XCTAssertEqual(result.status, 0, result.error)
        XCTAssertEqual(result.error, "")
        let rule = try XCTUnwrap(hooks.first)
        XCTAssertEqual(result.output, "Added rule \(short(rule)): Fix failing CI — ciFailed on any → claude in Terminal, ask, 3 runs per pull request.")
        var expected = Automation(id: rule.id, name: "Fix failing CI", kinds: [.ciFailed], workingDirectory: "~/Code/{repo_name}", createdAt: t0)
        expected.source = "cli"
        XCTAssertEqual(rule, expected)  // the rule editor's defaults: any, ask, claude, Terminal, 3 runs, default prompt, no expiry
    }

    func testRuleAddEveryOption() throws {
        try Data("From a file {repo}".utf8).write(to: dir.appendingPathComponent("prompt.md"))
        let result = addRule(["--prompt-file", "prompt.md", "--cwd", "work", "--on", "ciFailed,comment", "--scope", "mine",
                              "--repos", "octo-org/*, octo-org/widgets", "--actors", "alice", "--auto", "--agent", "codex", "--command", "cx",
                              "--launcher", "custom", "--custom-command", "open -a iTerm {script}", "--repeat", "5", "--disable", "--by", "agent\n1", "--json"])
        XCTAssertEqual(result.status, 0, result.error)
        XCTAssertEqual(result.error, "")  // --actors given: no warning
        let rule = try XCTUnwrap(hooks.first)
        XCTAssertEqual(try StateStore.decoder.decode(Automation.self, from: Data(result.output.utf8)), rule)  // --json = the saved object
        XCTAssertEqual(rule.kinds, [.ciFailed, .comment])
        XCTAssertEqual(rule.prompt, "From a file {repo}")
        XCTAssertEqual(rule.workingDirectory, dir.appendingPathComponent("work").path)  // no placeholder: resolved against $PWD
        XCTAssertEqual(rule.scope, .mine)
        XCTAssertEqual(rule.repos, ["octo-org/*", "octo-org/widgets"])
        XCTAssertEqual(rule.actors, ["alice"])
        XCTAssertEqual([rule.mode.rawValue, rule.agent.rawValue, rule.agentCommand, rule.launcher.rawValue, rule.customCommand],
                       ["auto", "codex", "cx", "custom", "open -a iTerm {script}"])
        XCTAssertEqual(rule.maxRunsPerPR, 5)
        XCTAssertFalse(rule.enabled)
        XCTAssertEqual([rule.source, rule.by], ["cli", "agent 1"])
        XCTAssertNil(rule.pr)
        XCTAssertNil(rule.expiresAt)
    }

    func testRuleValidation() {
        let base = ["rule", "add", "--name", "R", "--on", "comment", "--cwd", "/tmp"]
        let bad: [[String]] = [
            ["rule", "add", "--on", "comment", "--cwd", "/tmp"],  // no --name
            ["rule", "add", "--name", "R", "--cwd", "/tmp"],  // no --on
            base + ["--name", " \n"],
            base + ["--on", ""],
            base + ["--on", "reviewReminder"],
            base + ["--scope", "everyone"],
            base + ["--repos", "octo-org"],
            base + ["--repos", "octo-org/*/x"],
            base + ["--repos", "octo org/widgets"],
            base + ["--pr", "octo-org/widgets#1"],  // hook-only
            base + ["--session", "abc"],
            base + ["--expires", "3"],
            base + ["--cwd", "~/missing"],  // no placeholder: must exist
            base + ["--cwd", "/tmp/../tmp"],  // the launcher refuses ..
            base + ["--ask", "--auto"],
            base + ["--enable", "--disable"],
            base + ["--prompt", ""],
            base + ["--launcher", "custom"],
            base + ["--repeat", "11"],
            base + ["--all"],
        ]
        for args in bad {
            let result = run(args)
            XCTAssertEqual(result.status, 2, "\(args): \(result.output)")
            XCTAssertTrue(result.error.hasPrefix("pullping: "), result.error)
        }
        XCTAssertTrue(hooks.isEmpty)
        XCTAssertTrue(run(base + ["--expires", "3"]).error.contains("rules don't expire"))
        XCTAssertEqual(run(base + ["--cwd", "~/{repo_name}/../x"]).status, 0)  // placeholders: stored as typed, checked at launch
        XCTAssertEqual(last.workingDirectory, "~/{repo_name}/../x")
        XCTAssertEqual(run(base + ["--cwd", "~/work"]).status, 0)  // HOME is the test folder
        XCTAssertEqual(last.workingDirectory, "~/work")
        XCTAssertEqual(run(["rule", "add", "--name", "R", "--on", "comment"]).status, 0)
        XCTAssertEqual(last.workingDirectory, "{repo_dir}")  // no --cwd: the repository's folder
    }

    func testHookRejectsRuleOptions() throws {
        let base = ["hook", "add", "--pr", "octo-org/widgets#12", "--on", "comment", "--prompt", "p"]
        XCTAssertEqual(run(base + ["--scope", "mine"]).status, 2)
        XCTAssertEqual(run(base + ["--repos", "octo-org/*"]).status, 2)
        XCTAssertEqual(add().status, 0)
        XCTAssertEqual(run(["hook", "edit", short(last), "--scope", "mine"]).status, 2)
        XCTAssertEqual(last.scope, .any)
    }

    func testEditRule() throws {
        addRule(["--repos", "octo-org/*", "--actors", "alice", "--command", "cx", "--launcher", "custom", "--custom-command", "run {script}"])
        let id = short(last), before = last
        XCTAssertEqual(run(["rule", "edit", id]).status, 2)  // nothing to change
        XCTAssertEqual(run(["rule", "edit", id, "--custom-command", ""]).status, 2)  // custom launcher without a line
        XCTAssertEqual(run(["rule", "edit", id, "--repos", "nope"]).status, 2)
        XCTAssertEqual(last, before)  // a failed edit writes nothing
        XCTAssertEqual(run(["rule", "edit", "ffffffff", "--name", "X"]).status, 1)
        let result = run(["rule", "edit", id.uppercased(), "--name", "Renamed", "--repos", "", "--actors", "", "--command", "", "--launcher", "ghostex",
                          "--custom-command", "", "--scope", "others", "--on", "comment", "--prompt", "New {pr_url}", "--repeat", "1", "--agent", "codex",
                          "--cwd", "/tmp", "--by", "agent-2"])
        XCTAssertEqual(result.status, 0, result.error)
        XCTAssertEqual(result.output, "Updated rule \(id): Renamed — comment on others → codex in Ghostex, ask, 1 run per pull request.")
        var expected = before
        expected.name = "Renamed"; expected.repos = []; expected.actors = []; expected.agentCommand = ""; expected.launcher = .ghostex
        expected.customCommand = ""; expected.scope = .others; expected.kinds = [.comment]; expected.prompt = "New {pr_url}"
        expected.maxRunsPerPR = 1; expected.agent = .codex; expected.workingDirectory = "/tmp"; expected.by = "agent-2"
        XCTAssertEqual(last, expected)  // only the given options changed; id and createdAt kept
    }

    func testEditHook() throws {
        add(["--session", "0f3c1234"])
        let id = short(last)
        let result = run(["hook", "edit", id, "--session", "", "--expires", "2", "--pr", "octo-org/gadgets#3", "--repeat", "2", "--json"])
        XCTAssertEqual(result.status, 0, result.error)
        XCTAssertNil(last.sessionID)  // "" = a new session
        XCTAssertEqual(last.expiresAt, t0.addingTimeInterval(2 * 86_400))
        XCTAssertEqual(last.pr, PRRef(repo: "octo-org/gadgets", number: 3))
        XCTAssertEqual(last.maxRunsPerPR, 2)
        XCTAssertEqual(try StateStore.decoder.decode(Automation.self, from: Data(result.output.utf8)), last)
        XCTAssertEqual(run(["hook", "edit", id, "--session", "a b"]).status, 2)
        XCTAssertEqual(run(["hook", "edit", id, "--pr", "nope"]).status, 2)
    }

    func testEnableDisable() throws {
        addRule()
        let id = short(last)
        XCTAssertTrue(run(["rule", "disable", id]).output.hasSuffix("3 runs per pull request, off."))
        XCTAssertFalse(last.enabled)
        XCTAssertTrue(try StateStore.decoder.decode(Automation.self, from: Data(run(["rule", "enable", id, "--json"]).output.utf8)).enabled)
        XCTAssertTrue(last.enabled)
        XCTAssertEqual(run(["rule", "enable"]).status, 2)
        add()
        XCTAssertEqual(run(["hook", "disable", short(last)]).status, 0)
        XCTAssertFalse(last.enabled)
        XCTAssertEqual(run(["rule", "disable", short(last)]).status, 1)  // a hook's id is not a rule's
    }

    func testShow() throws {
        addRule(["--repos", "octo-org/*", "--prompt", "Line one\nLine two"])
        let rule = last
        let text = run(["rule", "show", short(rule)]).output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(text.first, "id              \(rule.id.uuidString.lowercased())")
        XCTAssertTrue(text.contains("name            Fix failing CI"))
        XCTAssertTrue(text.contains("repos           octo-org/*"))
        XCTAssertTrue(text.contains("cwd             ~/Code/{repo_name}"))
        XCTAssertTrue(text.contains("source          cli"))
        XCTAssertTrue(text.contains("pr"))  // empty for a rule
        XCTAssertEqual(Array(text.suffix(3)), ["prompt:", "  Line one", "  Line two"])
        let json = run(["rule", "show", short(rule), "--json"]).output
        XCTAssertEqual(try StateStore.decoder.decode(Automation.self, from: Data(json.utf8)), rule)
        XCTAssertEqual(run(["rule", "show"]).status, 2)
        XCTAssertEqual(run(["hook", "show", short(rule)]).status, 1)
    }

    /// `show --json` → flags → `add` rebuilds the automation: every key has a flag but the four the app and the CLI set.
    func testShowJSONRoundTripsThroughFlags() throws {
        var rule = AutomationStoreTests.everyField()
        rule.pr = nil; rule.sessionID = nil; rule.expiresAt = nil
        store.mutate { $0.automations = [rule] }
        let json = Data(run(["rule", "show", short(rule), "--json"]).output.utf8)
        let shown = try StateStore.decoder.decode(Automation.self, from: json)
        XCTAssertEqual(shown, rule)
        let flags: [String: (Automation) -> [String]] = [
            "name": { ["--name", $0.name] }, "kinds": { ["--on", $0.kinds.map(\.rawValue).joined(separator: ",")] },
            "prompt": { ["--prompt", $0.prompt] }, "workingDirectory": { ["--cwd", $0.workingDirectory] },
            "scope": { ["--scope", $0.scope.rawValue] }, "repos": { ["--repos", $0.repos.joined(separator: ",")] },
            "actors": { ["--actors", $0.actors.joined(separator: ",")] }, "mode": { [$0.mode == .auto ? "--auto" : "--ask"] },
            "agent": { ["--agent", $0.agent.rawValue] }, "agentCommand": { ["--command", $0.agentCommand] },
            "launcher": { ["--launcher", $0.launcher.rawValue] }, "customCommand": { ["--custom-command", $0.customCommand] },
            "maxRunsPerPR": { ["--repeat", "\($0.maxRunsPerPR)"] }, "enabled": { [$0.enabled ? "--enable" : "--disable"] },
            "by": { ["--by", $0.by] },
        ]
        let hookFlags = ["pr", "sessionID", "expiresAt"]  // --pr, --session, --expires
        let setByPullPing: Set = ["id", "createdAt", "source", "autoNoticeAt"]
        let keys = { (data: Data) in Set((try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]).keys) }
        XCTAssertEqual(try keys(json), Set(flags.keys).union(setByPullPing))
        XCTAssertEqual(try keys(AutomationStore.encoder.encode(AutomationStoreTests.everyField())), Set(flags.keys).union(hookFlags).union(setByPullPing))
        let result = run(["rule", "add"] + flags.keys.sorted().flatMap { flags[$0]!(shown) })
        XCTAssertEqual(result.status, 0, result.error)
        var copy = last
        XCTAssertNotEqual(copy.id, rule.id)
        copy.id = rule.id; copy.createdAt = rule.createdAt; copy.source = rule.source; copy.by = rule.by; copy.autoNoticeAt = rule.autoNoticeAt
        XCTAssertEqual(copy, rule)
    }

    func testRuleListRemoveAndKindScoping() throws {
        XCTAssertEqual(run(["rule", "list"]).output, "No rules.")
        addRule(["--scope", "mine", "--repos", "octo-org/*", "--on", "ciFailed,comment"])
        addRule(["--disable"])
        add()
        let rules = hooks.filter { !$0.isHook }, hook = hooks.last!
        let lines = run(["rule", "list"]).output.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, ["\(short(rules[0]))  Fix failing CI  comment,ciFailed  mine  octo-org/*  ask  claude  new session  Terminal  3/pr  on  cli",
                               "\(short(rules[1]))  Fix failing CI  ciFailed  any  all  ask  claude  new session  Terminal  3/pr  off  cli"])
        XCTAssertEqual(try StateStore.decoder.decode([Automation].self, from: Data(run(["rule", "list", "--json"]).output.utf8)), rules)
        XCTAssertEqual(run(["rule", "list", "--pr", "octo-org/widgets#12"]).status, 2)
        let wrong = run(["rule", "rm", short(hook)])
        XCTAssertEqual(wrong.status, 1)
        XCTAssertTrue(wrong.error.contains("no rule matches"), wrong.error)
        XCTAssertTrue(run(["hook", "rm", short(rules[0])]).error.contains("no hook matches"))
        XCTAssertEqual(run(["rule", "rm", short(rules[0])]).output, "Removed rule \(short(rules[0])) (Fix failing CI).")
        XCTAssertEqual(hooks.map(\.id), [rules[1].id, hook.id])
        XCTAssertEqual(run(["rule", "rm", "--pr", "octo-org/widgets#12", "--all"]).status, 2)
    }

    func testAutomationsSwitch() throws {
        XCTAssertEqual(run(["automations", "status"]).output, "on · 0 rules · 0 hooks · 0 runs · handler off")
        addRule(["--auto", "--actors", "alice"])
        addRule()
        add()
        store.mutate { $0.runs = [RunRecord(automationID: UUID(), prID: "PR_1", eventID: "e", at: t0, ok: true, detail: "Terminal")] }
        let off = run(["automations", "off"])
        XCTAssertEqual(off.output, "off · 2 rules (1 automatic) · 1 hook · 1 run, last \(AutomationCLI.stamp(t0)) OK · handler off")
        XCTAssertFalse(store.load().enabled)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(run(["automations", "on", "--json"]).output.utf8)) as? [String: Any])
        XCTAssertEqual(json["enabled"] as? Bool, true)
        XCTAssertEqual([json["rules"], json["hooks"], json["runs"], json["sessions"]].map { $0 as? Int }, [2, 1, 1, 0])
        XCTAssertEqual(json["handler"] as? Bool, false)
        XCTAssertTrue(store.load().enabled)
        XCTAssertEqual(run(["automations", "maybe"]).status, 2)
    }

    func testRuns() throws {
        XCTAssertEqual(run(["runs"]).output, "No runs yet.")
        let id = UUID()
        store.mutate { file in
            file.runs = (0..<12).map { RunRecord(automationID: id, prID: "PR_1", eventID: "\($0)", at: t0.addingTimeInterval(Double($0) * 60), ok: $0 != 11,
                                                 detail: $0 == 11 ? "The launcher exited with status 1: boom" : "Terminal", label: "Fix CI · octo-org/widgets #\($0)") }
        }
        let lines = run(["runs"]).output.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 10)
        XCTAssertEqual(lines[0], "\(AutomationCLI.stamp(t0.addingTimeInterval(660)))  FAIL  Fix CI · octo-org/widgets #11  The launcher exited with status 1: boom")
        XCTAssertEqual(lines[1], "\(AutomationCLI.stamp(t0.addingTimeInterval(600)))  OK    Fix CI · octo-org/widgets #10  Terminal")
        XCTAssertEqual(run(["runs", "--limit", "2"]).output.split(separator: "\n").count, 2)
        XCTAssertEqual(run(["runs", "--all"]).output.split(separator: "\n").count, 12)
        let json = try StateStore.decoder.decode([RunRecord].self, from: Data(run(["runs", "--limit", "3", "--json"]).output.utf8))
        XCTAssertEqual(json.map(\.eventID), ["11", "10", "9"])
        for bad in [["runs", "--limit", "0"], ["runs", "--limit", "2", "--all"], ["runs", "x"]] { XCTAssertEqual(run(bad).status, 2, "\(bad)") }
    }

    func testKindsJSON() throws {
        let kinds = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(run(["kinds", "--json"]).output.utf8)) as? [[String: String]])
        XCTAssertEqual(kinds.count, EventKind.allCases.count - 1)
        XCTAssertEqual(kinds.first, ["kind": "comment", "label": "Comment added"])
    }

    func testAutoWithoutActorsWarns() {
        let result = addRule(["--auto"])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.error, "note: runs for events by anyone who can comment on the repository; add --actors to limit it")
        XCTAssertEqual(run(["rule", "edit", short(last), "--actors", "alice"]).error, "")
        XCTAssertFalse(add(["--auto"]).error.isEmpty)
    }

    func testProvenance() {
        addRule(env: ["CLAUDE_CODE_SESSION_ID": "sess-1"])
        XCTAssertEqual([last.source, last.by], ["cli", "sess-1"])
        run(["rule", "edit", short(last), "--name", "X", "--by", "codex-7"], env: ["CLAUDE_CODE_SESSION_ID": "sess-1"])
        XCTAssertEqual(last.by, "codex-7")
        run(["rule", "edit", short(last), "--name", "Y"])
        XCTAssertEqual(last.by, "")
    }

    func addRule(_ extra: [String] = [], env: [String: String]) {
        run(["rule", "add", "--name", "Fix failing CI", "--on", "ciFailed", "--cwd", "~/Code/{repo_name}"] + extra, env: env)
    }

    /// The app stamps `autoNoticeAt` when it tells the user; the CLI clears it only when a write makes the automation automatic.
    func testAutoNoticeDueOnlyWhenTurnedAutomatic() {
        func stamp() { store.mutate { $0.automations[0].autoNoticeAt = t0 } }
        addRule(["--auto"])
        XCTAssertNil(last.autoNoticeAt)
        stamp()
        let id = short(last)
        run(["rule", "edit", id, "--prompt", "Another {pr_url}"])
        run(["rule", "edit", id, "--auto"])
        XCTAssertEqual(last.autoNoticeAt, t0)  // already automatic: no new notice
        run(["rule", "edit", id, "--ask"])
        XCTAssertEqual(last.autoNoticeAt, t0)
        run(["rule", "edit", id, "--auto"])
        XCTAssertNil(last.autoNoticeAt)  // ask → auto
        stamp()
        run(["rule", "disable", id])
        run(["rule", "enable", id])
        XCTAssertNil(last.autoNoticeAt)  // off → on while automatic
        run(["rule", "edit", id, "--name", "Renamed"])
        XCTAssertNil(last.autoNoticeAt)  // a CLI-made auto rule keeps its due notice
        var ui = Automation(name: "From Settings", kinds: [.comment], workingDirectory: "/tmp")
        ui.mode = .auto
        ui.source = "ui"
        store.mutate { $0.automations.append(ui) }
        run(["rule", "edit", short(last), "--name", "Renamed"])
        XCTAssertEqual(last.autoNoticeAt, t0)  // made automatic in Settings: the CLI edit is no news
    }

    // MARK: run

    var tracked: TrackedState {
        var state = TrackedState()
        for (id, number) in [("PR_12", 12), ("PR_3", 3)] {
            var pr = TrackedPR(id: id, accountID: UUID(), firstTrackedAt: t0)
            pr.repo = "octo-org/widgets"
            pr.number = number
            pr.url = URL(string: "https://github.com/octo-org/widgets/pull/\(number)")!
            state.prs[id] = pr
        }
        return state
    }

    func prepare(_ args: [String]) -> Result<RunRequest, Error> {
        Result { try AutomationCLI.prepareRun(args, store: store, state: tracked, env: env, now: t0) }
    }

    /// Exit status and error text a failed `prepare` prints.
    func refusal(_ args: [String]) -> (status: Int32, error: String) {
        guard case .failure(let error) = prepare(args) else { return (0, "") }
        let result = AutomationCLI.outcome(error, group: "run")
        return (result.status, result.error)
    }

    func testRunResolvesRulesAndHooks() throws {
        add()
        let hook = last
        addRule()
        let rule = last
        let request = try prepare([short(hook)]).get()  // a hook runs on its own pull request
        XCTAssertEqual([request.automation.id.uuidString, request.pr.id, request.eventID], [hook.id.uuidString, "PR_12", "manual:\(t0.ISO8601Format())"])
        XCTAssertFalse(request.dryRun || request.json)
        XCTAssertEqual(refusal([short(rule)]).status, 2)  // a rule needs --pr
        let ruleRun = try prepare([short(rule).uppercased(), "--pr", "https://github.com/Octo-Org/widgets/pull/3", "--dry-run", "--json"]).get()
        XCTAssertEqual(ruleRun.pr.id, "PR_3")
        XCTAssertTrue(ruleRun.dryRun && ruleRun.json)
        XCTAssertEqual(try prepare([short(hook), "--pr", "octo-org/widgets#3"]).get().pr.id, "PR_3")
        XCTAssertEqual(refusal([short(rule), "--pr", "octo-org/widgets#99"]).error, "pullping: PullPing is not tracking octo-org/widgets #99 yet")
        XCTAssertEqual(refusal(["ffffffff"]).error, "pullping: no automation matches ffffffff")
        XCTAssertEqual(refusal([short(rule), short(hook)]).status, 2)
        XCTAssertEqual(refusal([short(rule), "--pr", "x"]).status, 2)
        guard case .failure(let error) = prepare([]) else { return XCTFail("run alone prints its help") }
        XCTAssertEqual(AutomationCLI.outcome(error, group: "run").output, AutomationCLI.runHelp)
    }

    func testRunGatesUseTheMenuWords() throws {
        add(["--repeat", "3"])
        let hook = last, id = short(hook)
        run(["automations", "off"])
        XCTAssertEqual(refusal([id]).error, "pullping: Automations are off (pullping automations on)")
        run(["automations", "on"])
        run(["hook", "disable", id])
        XCTAssertEqual(refusal([id]).error, "pullping: octo-org/widgets #12 hook is off (pullping hook enable \(id))")
        run(["hook", "enable", id])
        store.mutate { $0.automations[0].expiresAt = t0 }
        XCTAssertEqual(refusal([id]).error, "pullping: octo-org/widgets #12 hook has expired")
        store.mutate { $0.automations[0].expiresAt = nil }
        func record(_ eventID: String, ok: Bool, at: Date = t0) {
            store.mutate { $0.runs.append(RunRecord(automationID: hook.id, prID: "PR_12", eventID: eventID, at: at, ok: ok, detail: "")) }
        }
        for i in 0..<3 { record("f\(i)", ok: false, at: t0.addingTimeInterval(-60)) }
        XCTAssertNoThrow(try prepare([id]).get())  // manual: no failure cap, no cooldown
        record("manual:\(t0.ISO8601Format())", ok: false)
        XCTAssertEqual(refusal([id]).status, 1)
        XCTAssertEqual(refusal([id]).error, "pullping: Already ran for this event")
        store.mutate { $0.runs = [] }
        for i in 0..<3 { record("e\(i)", ok: true, at: t0.addingTimeInterval(-86_400)) }
        XCTAssertEqual(refusal([id]).status, 1)
        XCTAssertEqual(refusal([id]).error, "pullping: Already ran 3 times on this pull request")
    }

    func testFinishRunRecordsLikeTheMenu() throws {
        addRule()
        let request = try prepare([short(last), "--pr", "octo-org/widgets#12"]).get()
        let started = AutomationCLI.finishRun(request, runID: "R1", error: nil, store: store, now: t0)
        XCTAssertEqual(started.output, "Started Fix failing CI on octo-org/widgets #12 in Terminal.")
        XCTAssertEqual(started.status, 0)
        XCTAssertEqual(store.load().runs, [RunRecord(automationID: last.id, prID: "PR_12", eventID: request.eventID, at: t0, ok: true, detail: "Terminal",
                                                     label: "Fix failing CI · octo-org/widgets #12")])
        var json = request
        json.json = true
        XCTAssertNotNil(json.newSessionID)
        run(["session", "set", "--pr", "octo-org/widgets#12", "--session", sid, "--quiet"])
        let linked = links
        let failed = AutomationCLI.finishRun(json, runID: "R2", error: "The launcher exited with status 1: boom", store: store, now: t0, cwd: dir.path)
        XCTAssertEqual(links, linked)  // a new session that failed to start links nothing
        XCTAssertEqual(failed.status, 1)
        XCTAssertEqual(failed.error, "pullping: The launcher exited with status 1: boom")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(failed.output.utf8)) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["runID"] as? String, "R2")
        XCTAssertEqual(object["automation"] as? String, last.id.uuidString)
        XCTAssertEqual(object["pr"] as? String, "octo-org/widgets#12")
        XCTAssertEqual(store.load().runs.last?.ok, false)
    }

    func testDryRunPrintsThePlan() throws {
        addRule(["--cwd", dir.path, "--prompt", "Fix {pr_url}"])
        let request = try prepare([short(last), "--pr", "octo-org/widgets#12", "--dry-run"]).get()
        let plan = try LaunchPlanner.plan(request.automation, pr: request.pr, event: nil, account: "alice", runID: "R1",
                                          runsDir: dir.appendingPathComponent("runs"), home: dir.path)
        XCTAssertEqual(AutomationCLI.dryRun(plan, json: false).split(separator: "\n").map(String.init), [
            "cwd          \(dir.path)", "title        PullPing: octo-org/widgets #12",
            "launch line  open -a Terminal '\(dir.path)/runs/R1.command'", "prompt:", "  Fix https://github.com/octo-org/widgets/pull/12"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(AutomationCLI.dryRun(plan, json: true).utf8)) as? [String: String])
        XCTAssertEqual(object.keys.sorted(), ["cwd", "launchLine", "prompt", "title"])
        var located = request.automation
        located.workingDirectory = "{repo_dir}"  // where the repository was found, and how
        let at = try LaunchPlanner.plan(located, pr: request.pr, event: nil, account: "alice", runID: "R1", runsDir: dir.appendingPathComponent("runs"),
                                        home: dir.path, folders: request.folders, index: RepoIndex(scannedAt: t0))
        XCTAssertEqual(AutomationCLI.dryRun(at, json: false).split(separator: "\n")[1], "repo         \(dir.path) (fallback)")
        let repo = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(AutomationCLI.dryRun(at, json: true).utf8)) as? [String: String])
        XCTAssertEqual([repo["repo"], repo["repoSource"]], [dir.path, "fallback"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("runs").path))
        XCTAssertTrue(store.load().runs.isEmpty)
    }

    func testCLIInvocation() {
        let app = "/Applications/PullPing.app/Contents/MacOS/PullPing"
        for args in [["rule"], ["session", "set"], ["typo"], ["help"], ["--help"], ["-h"]] {
            XCTAssertTrue(AutomationCLI.isCLIInvocation(args, program: app), "\(args)")
        }
        for args in [[], ["-psn_0_12345"], ["-NSDocumentRevisionsDebugMode", "YES"]] {
            XCTAssertFalse(AutomationCLI.isCLIInvocation(args, program: app), "\(args)")
        }
        XCTAssertTrue(AutomationCLI.isCLIInvocation([], program: "/usr/local/bin/pullping"))
        XCTAssertTrue(AutomationCLI.isCLIInvocation([], program: "pullping"))
        XCTAssertEqual(run(["-h"]).output, AutomationCLI.help)
        let typo = run(["sesion"])
        XCTAssertEqual(typo.status, 2)
        XCTAssertEqual(typo.error, "pullping: unknown command 'sesion'\nRun `pullping --help` for usage.")
    }

    // MARK: session

    let sid = "1a2b3c4d-0000-4000-8000-000000000001"
    var links: [SessionLink] { store.load().sessions }

    /// A Claude transcript under the test HOME (never the real ~/.claude), started in `cwd`.
    func transcript(cwd: String, id: String? = nil) throws {
        let folder = dir.appendingPathComponent(".claude/projects/-launch-dir")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type":"summary"}\#n{"type":"user","cwd":"\#(cwd)"}"#.utf8).write(to: folder.appendingPathComponent("\(id ?? sid).jsonl"))
    }

    /// The literal Roy's helper greps the binary for to detect `session set` support, in what the help prints.
    func testHelpNamesSessionSet() {
        for line in [["--help"], ["session", "--help"]] {
            XCTAssertTrue(run(line).output.contains("pullping session set --pr"), "\(line)")
        }
    }

    /// The CLI never repairs: the app moves an unreadable file aside, a `session set` from every Claude session must not wipe it.
    func testUnreadableFileIsLeftAlone() throws {
        let url = dir.appendingPathComponent("automations.json")
        try Data("not json".utf8).write(to: url)
        store = AutomationStore(url: url, repair: false)
        for line in [["session", "set", "--pr", "octo-org/widgets#12", "--session", sid, "--quiet"], ["rule", "list"],
                     ["hook", "add", "--pr", "octo-org/widgets#12", "--on", "comment", "--prompt", "Go"]] {
            let result = run(line)
            XCTAssertEqual(result.status, 1, "\(line)")
            XCTAssertEqual(result.output, "")
            XCTAssertEqual(result.error, "pullping: \(url.path) is unreadable; nothing was changed (fix the file or move it aside)")
        }
        XCTAssertEqual(refusal(["1a2b"]).error, "pullping: \(url.path) is unreadable; nothing was changed (fix the file or move it aside)")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "not json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("automations.broken.json").path))
    }

    func testFailedSaveIsAnError() throws {
        let readOnly = dir.appendingPathComponent("ro")
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: readOnly.appendingPathComponent("automations.lock").path, contents: nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnly.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnly.path) }
        store = AutomationStore(url: readOnly.appendingPathComponent("automations.json"), repair: false)
        let result = run(["session", "set", "--pr", "octo-org/widgets#12", "--session", sid, "--quiet"])
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.output, "")
        XCTAssertTrue(result.error.hasPrefix("pullping: could not save \(readOnly.path)/automations.json"), result.error)
        XCTAssertFalse(result.error.contains("\n"))
    }

    func testSessionSet() throws {
        let result = run(["session", "set", "--pr", "https://github.com/octo-org/widgets/pull/12", "--session", sid], env: ["CLAUDE_CODE_SESSION_ID": "sess-9"])
        XCTAssertEqual(result.status, 0, result.error)
        XCTAssertEqual(result.output, "Linked octo-org/widgets #12 → claude 1a2b3c4d… in \(dir.path).")  // no transcript: $PWD
        XCTAssertEqual(links, [SessionLink(pr: PRRef(repo: "octo-org/widgets", number: 12), agent: .claude, sessionID: sid, cwd: dir.path, setAt: t0,
                                           source: "cli", by: "sess-9")])
        XCTAssertEqual(run(["session", "set", "--pr", "https://github.com/octo-org/widgets/pull/12", "--session", sid], env: ["CLAUDE_CODE_SESSION_ID": "sess-9"]).status, 0)
        XCTAssertEqual(links.count, 1)  // idempotent
        let quiet = run(["session", "set", "--pr", "Octo-Org/Widgets#12", "--session", "thread.2", "--agent", "codex", "--cwd", "work", "--by", "agent\n2", "--quiet"])
        XCTAssertEqual([quiet.output, quiet.error], ["", ""])
        XCTAssertEqual(quiet.status, 0)
        XCTAssertEqual(links.count, 1)  // last writer wins, any case
        XCTAssertEqual([links[0].sessionID, links[0].agent.rawValue, links[0].cwd, links[0].by], ["thread.2", "codex", dir.appendingPathComponent("work").path, "agent 2"])
        let json = run(["session", "set", "--pr", "octo-org/widgets#7", "--session", sid, "--json"])
        XCTAssertEqual(try StateStore.decoder.decode(SessionLink.self, from: Data(json.output.utf8)), links.last)
    }

    func testSessionSetUsageErrors() {
        let bad: [[String]] = [
            ["session", "set", "--session", sid],  // no --pr
            ["session", "set", "--pr", "nope", "--session", sid],
            ["session", "set", "--pr", "octo-org/widgets#12"],  // no --session
            ["session", "set", "--pr", "octo-org/widgets#12", "--session", ""],
            ["session", "set", "--pr", "octo-org/widgets#12", "--session", "a b"],
            ["session", "set", "--pr", "octo-org/widgets#12", "--session", "linked"],
            ["session", "set", "--pr", "octo-org/widgets#12", "--session", sid, "--agent", "gpt"],
            ["session", "set", "--pr", "octo-org/widgets#12", "--session", sid, "--cwd", "missing"],
            ["session", "set", "--pr", "octo-org/widgets#12", "--session", sid, "--quiet", "extra"],
            ["session", "bogus"],
        ]
        for args in bad {
            let result = run(args)
            XCTAssertEqual(result.status, 2, "\(args)")
            XCTAssertEqual(result.output, "")
            XCTAssertTrue(result.error.hasPrefix("pullping: ") && !result.error.contains("\n"), result.error)  // one line: scripts call it
        }
        XCTAssertTrue(links.isEmpty)
        XCTAssertTrue(run(["session", "set", "--pr", "octo-org/widgets#12", "--session", ""]).error.contains("$CLAUDE_CODE_SESSION_ID is set only inside Claude Code"))
    }

    func testSessionSetUsesTheClaudeLaunchDirectory() throws {
        let launched = dir.appendingPathComponent("work").path
        try transcript(cwd: launched)
        run(["session", "set", "--pr", "octo-org/widgets#12", "--session", sid, "--quiet"])
        XCTAssertEqual(links.last?.cwd, launched)  // the transcript, not $PWD
        run(["session", "set", "--pr", "octo-org/widgets#12", "--session", sid, "--cwd", dir.path, "--quiet"])
        XCTAssertEqual(links.last?.cwd, dir.path)  // explicit --cwd wins
        run(["session", "set", "--pr", "octo-org/widgets#12", "--session", sid, "--agent", "codex", "--quiet"])
        XCTAssertEqual(links.last?.cwd, dir.path)  // Codex: $PWD
    }

    func testSessionShowListRemove() throws {
        XCTAssertEqual(run(["session", "list"]).output, "No linked sessions.")
        run(["session", "set", "--pr", "octo-org/widgets#12", "--session", sid, "--by", "alice", "--quiet"])
        store.mutate { $0.sessions[0].setAt = t0.addingTimeInterval(-60) }
        run(["session", "set", "--pr", "octo-org/gadgets#3", "--session", "thread.2", "--agent", "codex", "--cwd", "work", "--quiet"])
        XCTAssertEqual(run(["session", "list"]).output.split(separator: "\n").map(String.init), [
            "octo-org/gadgets #3  codex  thread.2…  ~/work  \(AutomationCLI.stamp(t0))  cli",  // newest first; HOME is the test folder
            "octo-org/widgets #12  claude  1a2b3c4d…  ~  \(AutomationCLI.stamp(t0.addingTimeInterval(-60)))  cli"])
        XCTAssertEqual(try StateStore.decoder.decode([SessionLink].self, from: Data(run(["session", "list", "--json"]).output.utf8)), links.reversed())
        XCTAssertEqual(run(["session", "show", "--pr", "https://github.com/octo-org/widgets/pull/12"]).output.split(separator: "\n").map(String.init), [
            "repo            octo-org/widgets", "number          12", "agent           claude", "session         \(sid)", "cwd             \(dir.path)",
            "set             \(t0.addingTimeInterval(-60).ISO8601Format())", "source          cli", "by              alice"])
        XCTAssertEqual(try StateStore.decoder.decode(SessionLink.self, from: Data(run(["session", "show", "--pr", "octo-org/widgets#12", "--json"]).output.utf8)), links[0])
        let missing = run(["session", "show", "--pr", "octo-org/widgets#99"])
        XCTAssertEqual([missing.status], [1])
        XCTAssertEqual(missing.error, "pullping: No session linked to octo-org/widgets #99")
        XCTAssertEqual(run(["session", "rm", "--pr", "Octo-Org/widgets#12"]).output, "Unlinked Octo-Org/widgets #12.")
        XCTAssertEqual(links.map(\.pr.number), [3])
        XCTAssertEqual(run(["session", "rm", "--pr", "octo-org/widgets#12"]).status, 1)
        XCTAssertEqual(run(["session", "rm"]).status, 2)
    }

    // MARK: handler

    func testHandler() throws {
        XCTAssertEqual(try StateStore.decoder.decode(Automation.self, from: Data(run(["handler", "show", "--json"]).output.utf8)), Automation.defaultHandler())
        XCTAssertTrue(run(["handler", "show"]).output.hasPrefix("id              00000000-0000-4000-8000-00000000ac71\nname            Handle with Agent\nenabled         off"))
        XCTAssertEqual(run(["handler", "on"]).output, "Handle with Agent: on · claude in Terminal · {repo_dir}")
        XCTAssertTrue(store.load().handler.enabled)
        let set = run(["handler", "set", "--agent", "codex", "--command", "cx", "--launcher", "custom", "--custom-command", "open -a iTerm {script}",
                       "--cwd", "~/work", "--prompt", "Handle {pr_url}", "--by", "agent-2"])
        XCTAssertEqual(set.status, 0, set.error)
        XCTAssertEqual(set.output, "Handle with Agent: on · cx in Custom command · ~/work")
        var expected = Automation.defaultHandler()
        expected.enabled = true; expected.agent = .codex; expected.agentCommand = "cx"; expected.launcher = .custom
        expected.customCommand = "open -a iTerm {script}"; expected.workingDirectory = "~/work"; expected.prompt = "Handle {pr_url}"
        expected.source = "cli"; expected.by = "agent-2"
        XCTAssertEqual(store.load().handler, expected)
        XCTAssertEqual(run(["handler", "set", "--custom-command", ""]).status, 2)  // custom launcher without a line
        XCTAssertEqual(run(["handler", "set", "--launcher", "terminal", "--custom-command", "", "--command", ""]).status, 0)  // "" clears
        XCTAssertEqual([store.load().handler.agentCommand, store.load().handler.customCommand], ["", ""])
        for bad in [["set"], ["set", "--cwd", "~/missing"], ["set", "--prompt", ""], ["set", "--name", "X"], ["set", "--on", ""],
                    ["set", "--auto"], ["set", "--session", "linked"], ["set", "--repeat", "2"], ["set", "--pr", "o/r#1"], ["off", "--prompt", "x"], ["bogus"]] {
            XCTAssertEqual(run(["handler"] + bad).status, 2, "\(bad)")
        }
        XCTAssertEqual(run(["handler", "set", "--cwd", "~/Code/{repo_name}"]).status, 0)  // placeholders stored as typed
        let off = try StateStore.decoder.decode(Automation.self, from: Data(run(["handler", "off", "--json"]).output.utf8))
        XCTAssertFalse(off.enabled)
        XCTAssertEqual(off, store.load().handler)
        XCTAssertTrue(store.load().automations.isEmpty)  // never a rule
        XCTAssertTrue(run(["automations", "status"]).output.hasSuffix(" · handler off"))
    }

    /// `--on` picks the notifications with the buttons; `all` stores [] (every kind), shown as all.
    func testHandlerOn() throws {
        XCTAssertTrue(run(["handler", "show"]).output.contains("\nkinds           comment,mentioned,reviewApproved,reviewChangesRequested,reviewCommented,reviewRequested,assigned,ciFailed,readyForReview,reopened,reviewDismissed\n"))
        XCTAssertEqual(run(["handler", "set", "--on", "ciFailed,comment", "--by", "agent-2"]).status, 0)
        XCTAssertEqual(store.load().handler.kinds, [.ciFailed, .comment])
        XCTAssertEqual([store.load().handler.source, store.load().handler.by], ["cli", "agent-2"])
        XCTAssertEqual(try StateStore.decoder.decode(Automation.self, from: Data(run(["handler", "show", "--json"]).output.utf8)).kinds, [.ciFailed, .comment])
        XCTAssertEqual(run(["handler", "set", "--on", "all"]).status, 0)
        XCTAssertEqual(store.load().handler.kinds, [])
        XCTAssertTrue(run(["handler", "show"]).output.contains("\nkinds           all\n"))
        XCTAssertEqual(run(["handler", "set", "--on", "bogus"]).status, 2)
        XCTAssertEqual(store.load().handler.kinds, [])  // a failed check changes nothing
        XCTAssertEqual(run(["rule", "add", "--name", "R", "--on", "all"]).status, 2)  // all is the handler's only
        XCTAssertTrue(AutomationCLI.handlerHelp.contains("--on <kind,…|all>"))
    }

    // MARK: --session linked, hooks that link

    func testLinkedSessionOnRulesAndHooks() throws {
        let added = addRule(["--session", "linked", "--auto"])
        XCTAssertEqual(added.status, 0)
        XCTAssertTrue(last.usesLinkedSession)
        XCTAssertTrue(added.output.contains("→ claude (linked session) in Terminal"), added.output)
        XCTAssertTrue(added.error.hasPrefix("note: resumes the pull request's linked session for events by anyone"), added.error)
        XCTAssertTrue(run(["rule", "list"]).output.contains("  claude  linked session  Terminal  "))
        XCTAssertEqual(run(["rule", "edit", short(last), "--session", sid]).status, 2)  // a rule spans many pull requests
        XCTAssertEqual(run(["rule", "edit", short(last), "--session", ""]).status, 0)
        XCTAssertNil(last.sessionID)
        XCTAssertEqual(add(["--session", "linked"]).status, 0)
        XCTAssertTrue(last.usesLinkedSession)
        XCTAssertTrue(add(["--session", "linked"]).output.contains("(linked session)"))
        XCTAssertTrue(links.isEmpty)  // linked links nothing
    }

    func testHookWithSessionLinksIt() throws {
        let launched = dir.appendingPathComponent("work").path
        try transcript(cwd: launched)
        XCTAssertEqual(add(["--session", sid, "--by", "alice"]).status, 0)
        XCTAssertEqual(last.workingDirectory, launched)  // the session's folder, not $PWD
        XCTAssertEqual(links, [SessionLink(pr: PRRef(repo: "octo-org/widgets", number: 12), agent: .claude, sessionID: sid, cwd: launched, setAt: t0,
                                           source: "cli", by: "alice")])
        XCTAssertEqual(add(["--session", sid, "--cwd", dir.path]).status, 0)
        XCTAssertEqual(last.workingDirectory, dir.path)  // explicit --cwd wins
        XCTAssertEqual(links.map(\.cwd), [dir.path])
        XCTAssertEqual(run(["hook", "edit", short(last), "--session", "thread.9", "--agent", "codex"]).status, 0)
        XCTAssertEqual([links[0].sessionID, links[0].agent.rawValue, links[0].cwd], ["thread.9", "codex", dir.path])
        XCTAssertEqual(add(["--session", "other-session"]).status, 0)
        XCTAssertEqual(last.workingDirectory, dir.path)  // no transcript: $PWD
    }

    // MARK: run with links

    func testRunResolvesTheLinkedSession() throws {
        addRule(["--session", "linked", "--cwd", dir.path])
        let rule = last
        XCTAssertEqual(refusal([short(rule), "--pr", "octo-org/widgets#12"]).error, "pullping: No linked session on this pull request")
        run(["session", "set", "--pr", "octo-org/widgets#12", "--session", sid, "--cwd", "work", "--quiet"])
        let request = try prepare([short(rule), "--pr", "octo-org/widgets#12"]).get()
        XCTAssertEqual([request.automation.sessionID, request.automation.workingDirectory], [sid, dir.appendingPathComponent("work").path])
        XCTAssertNil(request.newSessionID)  // a resume
        addRule()
        let fresh = try prepare([short(last), "--pr", "octo-org/widgets#3"]).get()
        let id = try XCTUnwrap(fresh.newSessionID)
        _ = AutomationCLI.finishRun(fresh, runID: "R1", error: nil, store: store, now: t0, cwd: dir.path)
        XCTAssertEqual(store.load().link(for: "octo-org/widgets", number: 3)?.sessionID, id)  // a new Claude session links itself
        XCTAssertEqual(store.load().link(for: "octo-org/widgets", number: 3)?.cwd, dir.path)
    }

    // MARK: Session discovery, hand-off, repository overrides

    /// A Claude transcript under the test HOME, changed `age` seconds before t0.
    @discardableResult
    func transcript(_ id: String, _ lines: [String], age: TimeInterval) throws -> String {
        let folder = dir.appendingPathComponent(".claude/projects/-p")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(id).jsonl")
        try Data(lines.joined(separator: "\n").utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(-age)], ofItemAtPath: file.path)
        return file.path
    }

    func find(_ extra: [String], env more: [String: String] = [:]) -> (output: String, error: String, status: Int32) {
        AutomationCLI.run(["session", "find", "--pr", "octo-org/widgets#12"] + extra, store: store, env: env.merging(more) { $1 }, now: t0,
                          state: { self.tracked })
    }

    func testSessionFind() throws {
        let none = find([])
        XCTAssertEqual([none.output, "\(none.status)"], ["No earlier session found for octo-org/widgets #12 (scanned 0 transcripts).", "1"])
        let cwd = dir.appendingPathComponent("work").path
        let path = try transcript(sid, [#"{"type":"user","cwd":"\#(cwd)","gitBranch":"HEAD"}"#,
                                        #"{"type":"pr-link","prUrl":"https://github.com/octo-org/widgets/pull/12"}"#,
                                        #"{"type":"ai-title","aiTitle":"Widget cache"}"#], age: 7200)
        let text = find([])
        XCTAssertEqual(text.status, 0, text.error)
        let lines = text.output.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "Found claude 1a2b3c4d… (pr-link, 2 h ago) \"Widget cache\" launched in ~/work, last in ~/work")
        XCTAssertEqual(lines[1], "  \(path)")
        XCTAssertTrue(lines[2].hasPrefix("Scanned 1 transcripts in "), lines[2])
        XCTAssertTrue(links.isEmpty)  // nothing linked without --link
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(find(["--json"]).output.utf8)) as? [String: Any])
        XCTAssertEqual(json["scanned"] as? Int, 1)
        XCTAssertEqual(json["linked"] as? Bool, false)
        XCTAssertEqual((json["candidates"] as? [[String: Any]])?.first?["sessionID"] as? String, sid)
        XCTAssertTrue(find(["--exclude", sid]).output.hasPrefix("No earlier session"))
        XCTAssertTrue(find([], env: ["CLAUDE_CODE_SESSION_ID": sid]).output.hasPrefix("No earlier session"))  // never the caller itself
        let linked = find(["--link"], env: ["CLAUDE_CODE_SESSION_ID": "caller"])
        XCTAssertTrue(linked.output.hasSuffix("Linked.\nContinue it: pullping session resume --pr https://github.com/octo-org/widgets/pull/12"), linked.output)
        XCTAssertEqual(links, [SessionLink(pr: PRRef(repo: "octo-org/widgets", number: 12), agent: .claude, sessionID: sid, cwd: cwd, setAt: t0,
                                           source: "found", by: "caller")])
        for bad in [["--days", "0"], ["--days", "x"], ["--bogus"]] { XCTAssertEqual(find(bad).status, 2, "\(bad)") }
    }

    func testSessionFindNeverLinksAMention() throws {
        try transcript("only-listed", [#"{"type":"user","cwd":"/x","message":"gh pr list: octo-org/widgets#12 Widget cache"}"#], age: 60)
        let result = find(["--link"])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("(mention, 1 min ago, may be open)"), result.output)
        XCTAssertTrue(result.output.hasSuffix("Not linked: it only mentions the pull request. If it is the one: pullping session set --pr https://github.com/octo-org/widgets/pull/12 --session only-listed --agent claude"), result.output)
        XCTAssertTrue(links.isEmpty)
    }

    /// The link's folder passes the working-directory check (absolute, existing, no `..`); none does → nothing is linked.
    func testSessionFindLinksOnlyAnExistingFolder() throws {
        let prLink = #"{"type":"pr-link","prUrl":"https://github.com/octo-org/widgets/pull/12"}"#
        let work = dir.appendingPathComponent("work").path
        try transcript("no-folder", [prLink], age: 600)  // no cwd at all
        let none = find(["--link"])
        XCTAssertEqual(none.status, 0)
        XCTAssertTrue(none.output.hasSuffix("Not linked: its folders are gone."), none.output)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(find(["--link", "--json"]).output.utf8)) as? [String: Any])
        XCTAssertEqual(json["linked"] as? Bool, false)
        XCTAssertTrue(links.isEmpty)
        try transcript("no-folder", [#"{"cwd":"/gone/folder"}"#, prLink, #"{"cwd":"\#(work)/../work"}"#], age: 600)
        XCTAssertTrue(find(["--link"]).output.hasSuffix("Not linked: its folders are gone."))
        XCTAssertTrue(links.isEmpty)
        try transcript("no-folder", [#"{"cwd":"/gone/folder"}"#, prLink, #"{"cwd":"\#(work)"}"#], age: 600)  // launch folder gone: the last one
        XCTAssertTrue(find(["--link"]).output.contains("\nLinked.\n"))
        XCTAssertEqual(links.map(\.cwd), [work])
    }

    func resume(_ args: [String], env extra: [String: String] = [:]) -> Result<RunRequest, Error> {
        Result { try AutomationCLI.prepareHandlerRun(["--pr", "https://github.com/octo-org/widgets/pull/12"] + args, store: store, state: tracked,
                                                     env: env.merging(extra) { $1 }, now: t0) }
    }

    func resumeError(_ args: [String] = [], env extra: [String: String] = [:]) -> String {
        guard case .failure(let error) = resume(args, env: extra) else { return "" }
        return AutomationCLI.outcome(error, group: "session").error
    }

    func testSessionResumeGatesInOrder() throws {
        run(["automations", "off"])
        XCTAssertEqual(resumeError(), "pullping: Automations are off (pullping automations on)")
        run(["automations", "on"])
        XCTAssertEqual(resumeError(), "pullping: Handle with Agent is off (pullping handler on)")
        run(["handler", "on"])
        XCTAssertEqual(resumeError(), "pullping: No session linked to octo-org/widgets #12 (pullping session find --pr <url> --link)")
        run(["session", "set", "--pr", "octo-org/widgets#99", "--session", sid, "--quiet"])
        XCTAssertEqual(resumeError(["--pr", "octo-org/widgets#99"]), "pullping: PullPing is not tracking octo-org/widgets #99 yet")
        run(["session", "set", "--pr", "octo-org/widgets#12", "--session", sid, "--cwd", "work", "--quiet"])
        try transcript("someone-else", ["{}"], age: 3600)
        XCTAssertEqual(resumeError(), "pullping: The session's transcript is gone: \(sid)")
        try transcript(sid, [#"{"cwd":"/x"}"#], age: 40)
        XCTAssertEqual(resumeError(), "pullping: Session 1a2b3c4d… appears to be open in another terminal (changed 40 s ago); continue there, or add --force")
        XCTAssertNoThrow(try resume(["--force"]).get())
        // the caller's own session: never, not even with --force
        XCTAssertEqual(resumeError(["--force"], env: ["CLAUDE_CODE_SESSION_ID": sid]), "pullping: Session 1a2b3c4d… is this session; continue here")
        try transcript(sid, [#"{"cwd":"/x"}"#], age: 600)
        XCTAssertEqual(resumeError(env: ["CLAUDE_CODE_SESSION_ID": sid]), "pullping: Session 1a2b3c4d… is this session; continue here")
        func record(_ label: String, ago: TimeInterval) {
            store.mutate { $0.runs.append(RunRecord(automationID: Automation.handlerID, prID: "PR_12", eventID: "manual:x", at: t0.addingTimeInterval(-ago),
                                                    ok: true, detail: "Terminal", label: label)) }
        }
        record("Handle with Agent (new session) · octo-org/widgets #12", ago: 20)  // the run that started the caller: no brake
        XCTAssertNoThrow(try resume([]).get())
        record("Handle with Agent (resume 1a2b…) · octo-org/widgets #12", ago: 20)
        XCTAssertEqual(resumeError(), "pullping: Handed off 20 s ago")
        store.mutate { $0.runs[$0.runs.count - 1].at = t0.addingTimeInterval(-61) }
        let request = try resume(["--prompt", "Continue {pr_url}", "--json"]).get()
        XCTAssertEqual([request.automation.id.uuidString, request.automation.sessionID, request.automation.workingDirectory, request.automation.prompt],
                       [Automation.handlerID.uuidString, sid, dir.appendingPathComponent("work").path, "Continue {pr_url}"])
        XCTAssertTrue(request.handoff && request.json)
        XCTAssertNil(request.newSessionID)
        XCTAssertEqual(request.hints, [dir.appendingPathComponent("work").path])
        XCTAssertEqual(AutomationCLI.outcome(try XCTUnwrap(resume(["--bogus"]).failureValue), group: "session").error,
                       "pullping: unknown option --bogus (see pullping session --help)")
    }

    func testSessionResumeRecordsAHandOff() throws {
        run(["handler", "on"])
        run(["session", "set", "--pr", "octo-org/widgets#12", "--session", sid, "--cwd", "work", "--quiet"])
        XCTAssertEqual(try resume(["--by", "claude:\nclaude2"], env: ["CLAUDE_CODE_SESSION_ID": "caller-1"]).get().note, " · by claude: claude2")
        XCTAssertEqual(try resume([]).get().note, "")  // no caller, no --by
        var request = try resume([], env: ["CLAUDE_CODE_SESSION_ID": "caller-1"]).get()
        let started = AutomationCLI.finishRun(request, runID: "R1", error: nil, store: store, now: t0, cwd: dir.appendingPathComponent("work").path)
        XCTAssertEqual(started.output, "Resumed claude 1a2b3c4d… on octo-org/widgets #12 in Terminal (\(dir.appendingPathComponent("work").path)).")
        XCTAssertEqual(store.load().runs.last?.label, "Handle with Agent (resume 1a2b…) · octo-org/widgets #12")
        XCTAssertEqual(store.load().runs.last?.detail, "Terminal · by caller-1")  // who handed off (spec 3.2)
        request.json = true
        request.note = " (folder gone, resumed in /x)"
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(AutomationCLI.finishRun(request, runID: "R2", error: nil, store: store, now: t0).output.utf8)) as? [String: Any])
        XCTAssertEqual(object["session"] as? String, sid)
        XCTAssertEqual(object["detail"] as? String, "Terminal (folder gone, resumed in /x)")
    }

    func testRepoOverrides() throws {
        XCTAssertEqual(run(["automations", "repos", "list"]).output, "No repository overrides.")
        XCTAssertEqual(run(["automations", "repos", "set", "Octo-Org/Widgets", "work"]).output, "octo-org/widgets → \(dir.path)/work.")
        XCTAssertEqual(run(["automations", "repos", "set", "a/b", "~/gone"]).status, 2)
        for bad in [["set", "nope", "work"], ["set", "a/b/c", "work"], ["set", "a/b", "{repo_dir}"], ["set", "a/b"], ["bogus"]] {
            XCTAssertEqual(run(["automations", "repos"] + bad).status, 2, "\(bad)")
        }
        XCTAssertEqual(store.load().repoFolders.overrides, ["octo-org/widgets": dir.path + "/work"])
        XCTAssertEqual(run(["automations", "repos", "list"]).output, "octo-org/widgets  \(dir.path)/work")
        try FileManager.default.removeItem(at: dir.appendingPathComponent("work"))
        XCTAssertEqual(run(["automations", "repos", "list"]).output, "octo-org/widgets  \(dir.path)/work  (missing)")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(run(["automations", "repos", "list", "--json"]).output.utf8)) as? [String: String],
                       ["octo-org/widgets": dir.path + "/work"])
        XCTAssertEqual(run(["automations", "repos", "rm", "OCTO-ORG/widgets"]).output, "Removed the override for octo-org/widgets.")
        XCTAssertEqual(run(["automations", "repos", "rm", "octo-org/widgets"]).status, 1)
        XCTAssertEqual(run(["automations", "repos"]).output, AutomationCLI.automationsHelp)
    }

    func testFolderListShowsTheIndex() throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Code/widgets/.git"), withIntermediateDirectories: true)
        try Data("[remote \"origin\"]\n\turl = git@github-padina:octo-org/widgets.git\n".utf8).write(to: dir.appendingPathComponent("Code/widgets/.git/config"))
        try Data("ref: refs/heads/main\n".utf8).write(to: dir.appendingPathComponent("Code/widgets/.git/HEAD"))
        XCTAssertTrue(run(["automations", "folders", "list"]).output.contains("\nrepos scanned: 1 ("))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(run(["automations", "folders", "list", "--json"]).output.utf8)) as? [String: Any])
        let index = try XCTUnwrap(json["index"] as? [[String: Any]])
        XCTAssertEqual(index.first?["path"] as? String, dir.path + "/Code/widgets")
        XCTAssertEqual(index.first?["branch"] as? String, "main")
        XCTAssertEqual(index.first?["keys"] as? [String], ["octo-org/widgets"])
    }

    func testFindSessionsSetting() throws {
        XCTAssertFalse(store.load().findSessions)
        let set = run(["handler", "set", "--find-sessions", "on"])
        XCTAssertEqual(set.output, "Handle with Agent: off · claude in Terminal · {repo_dir} · find sessions on")
        XCTAssertTrue(store.load().findSessions)
        XCTAssertEqual(store.load().handler, Automation.defaultHandler())  // only the setting: the handler and its provenance stay
        XCTAssertTrue(run(["automations", "status"]).output.hasSuffix(" · handler off · find sessions on"))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(run(["automations", "status", "--json"]).output.utf8)) as? [String: Any])?["findSessions"] as? Bool, true)
        XCTAssertTrue(run(["handler", "show"]).output.contains("\nfind sessions   on\n"))
        XCTAssertEqual(run(["handler", "set", "--find-sessions", "yes"]).status, 2)
        run(["handler", "set", "--find-sessions", "off"])
        XCTAssertFalse(store.load().findSessions)
        XCTAssertFalse(run(["automations", "status"]).output.contains("find sessions"))
    }

    func testDefaultPromptsSuggestDiscovery() {
        for prompt in [Automation.defaultPrompt, Automation.defaultHandlerPrompt] {
            XCTAssertTrue(prompt.contains("`pullping session find --pr {pr_url} --link`"))
            XCTAssertTrue(prompt.contains("`pullping session resume --pr {pr_url}` and stop"))
        }
        XCTAssertTrue(Automation.defaultHandlerPrompt.contains("Work in {worktree_dir} (branch {branch})."))
        XCTAssertTrue(AutomationCLI.help.contains("pullping session set --pr <url> --session"))  // the literal the link helper greps
    }
}

private extension Result {
    var failureValue: Failure? { if case .failure(let error) = self { return error } else { return nil } }
}
