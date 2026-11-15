import Foundation

/// `{name}` placeholders in prompts, working directories and custom launch lines.
public enum PromptTemplate {
    /// One pass, so an inserted value is never expanded again; unknown tokens (and a stray `{}`) stay as typed.
    public static func render(_ template: String, _ values: [String: String]) -> String {
        template.replacing(#/\{([a-z_]+)\}/#) { match in values[String(match.1)] ?? String(match.0) }
    }

    /// Text written by others on GitHub: C0/C1 control characters (newlines too) become spaces, invisible ones go
    /// (`isInvisible`), trimmed, at most `max` characters.
    public static func clean(_ text: String, max: Int) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !scalar.isInvisible { scalars.append(scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) ? " " : scalar) }
        return String(String(scalars).trimmingCharacters(in: .whitespaces).prefix(max))
    }
}

extension Unicode.Scalar {
    /// Shows nothing but is read by a model or a parser: format characters (text direction, zero-width, soft hyphen, Unicode
    /// tags) and the rest of the default-ignorable ones (variation selectors, fillers). Text can hide in them.
    var isInvisible: Bool { properties.generalCategory == .format || properties.isDefaultIgnorableCodePoint }
}

public struct LaunchPlan: Sendable, Equatable {
    public var cwd: String
    public var title: String
    public var promptText: String
    public var promptPath: String
    public var scriptPath: String
    public var script: String
    /// Run as `/bin/zsh -lc <launchLine>` in `cwd`.
    public var launchLine: String
    /// Where `{repo_dir}` and the other folder placeholders point, and why (`source`); nil when no template uses one.
    public var repo: RepoLocation? = nil
    /// Ghostex: the line reads `$PULLPING_GHOSTEX_PROJECT`, which the launcher sets from `ghostex projects` (`GhostexProjects.pick`).
    public var needsGhostexProject = false
    /// Ghostex resume: `ghostex` arguments that focus the session when it already runs there (instead of a second copy), and
    /// that then type the draft line into it (`GhostexSessions`). nil = always a new session.
    public var focusRunning: [String]? = nil
    public var draftLine: [String]? = nil
}

/// Ghostex sessions PullPing starts, focuses or finds. Every value reaches `ghostex` as an argument, never as shell text.
public enum GhostexSessions {
    /// The run detail's suffix when a click focused a running session instead of starting one.
    public static let focusedNote = " (focused running session)"

    /// `/bin/zsh` arguments running `ghostex <args>` in a login shell (Homebrew on PATH); `args` stay argv.
    public static func shell(_ args: [String]) -> [String] { ["-lc", "ghostex \"$@\"", "zsh"] + args }

    /// `create-session`'s `{ok, session: {globalRef, …}}`: the new session's ref, nil when absent or not a plain ref (one that
    /// starts with `-` would be read as an option by `ghostex focus`).
    public static func globalRef(_ json: Data) -> String? {
        let raw = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any]
        guard let ref = (raw?["session"] as? [String: Any])?["globalRef"] as? String, ref.wholeMatch(of: #/[A-Za-z0-9][A-Za-z0-9:_-]{0,63}/#) != nil else { return nil }
        return ref
    }

    /// `focus … --if-running --json`: `{"focused": true, …}` when it focused a running session (`notRunning` is `false`).
    public static func focused(_ json: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: json)) as? [String: Any])?["focused"] as? Bool == true
    }

    /// `sessions --json` (`{ok, sessions: [{agentSessionId, …}]}`) lists a session of this agent session. Looks, never focuses.
    public static func running(_ json: Data, sessionID: String) -> Bool {
        let rows = (((try? JSONSerialization.jsonObject(with: json)) as? [String: Any])?["sessions"] as? [[String: Any]]) ?? []
        return rows.contains { $0["agentSessionId"] as? String == sessionID }
    }

    public static func focus(globalRef: String) -> [String] { ["focus", globalRef] }
    public static func focusRunning(sessionID: String, agent: AgentKind) -> [String] {
        ["focus", "--agent-session-id", sessionID, "--agent", agent.rawValue, "--if-running", "--json"]
    }
    public static let sessions = ["sessions", "--json"]
    /// Typed into the running session's input without Enter (the user presses Return): a fixed sentence and PullPing's own
    /// prompt path, no GitHub text. The agent session id is a Ghostex selector.
    public static func draft(sessionID: String, promptPath: String) -> [String] {
        ["send-text", sessionID, "Read \(promptPath) and act on it."]
    }
}

/// `ghostex create-session` needs a project id; `--cwd` still opens the folder, so any project works, the closest one reads best.
public enum GhostexProjects {
    /// The project whose path is `cwd` or its nearest parent, else the first one; nil when Ghostex lists none.
    public static func pick(_ json: Data, cwd: String) -> String? {
        let raw = try? JSONSerialization.jsonObject(with: json)
        let rows = (raw as? [[String: Any]]) ?? ((raw as? [String: Any])?["projects"] as? [[String: Any]]) ?? []
        let projects: [(id: String, path: String)] = rows.compactMap { row in
            guard let id = (row["projectId"] ?? row["id"]) as? String, !id.isEmpty else { return nil }
            return (id, ((row["path"] ?? row["projectPath"]) as? String ?? "").replacingOccurrences(of: "/+$", with: "", options: .regularExpression))
        }
        let containing = projects.filter { !$0.path.isEmpty && (cwd == $0.path || cwd.hasPrefix($0.path + "/")) }
        return (containing.max { $0.path.count < $1.path.count } ?? projects.first)?.id
    }
}

public enum LaunchError: Error, Equatable, LocalizedError {
    case badWorkingDirectory(String), badSessionID, emptyCustomCommand, badRepository(String), noLinkedSession, sessionFolderGone(String),
         notInstalled(String), sessionGone(String)

    public var errorDescription: String? {
        switch self {
        case .badWorkingDirectory(let path): "Working directory is not an existing folder: \(path)"
        case .badSessionID: "Session id may only contain letters, digits, '.', '_' and '-' (at most 128)"
        case .emptyCustomCommand: "The custom command is empty"
        case .badRepository(let repo): "Unexpected repository name: \(repo)"
        case .noLinkedSession: "No linked session on this pull request"
        case .sessionFolderGone(let path): "The session's folder is gone: \(path)"
        case .sessionGone(let id): "The session's transcript is gone: \(id)"
        case .notInstalled(let app): "\(app) is not installed; choose another app under Open in (--launcher)"
        }
    }
}

/// What to write and run for one automation run. Pure but for the working-directory check. Prompt text never enters a shell line.
public enum LaunchPlanner {
    public static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Claude: a UUID; Codex: a UUID or a thread name.
    public static func isValidSessionID(_ id: String) -> Bool { id.wholeMatch(of: #/[A-Za-z0-9._-]{1,128}/#) != nil }

    public static func isValidRepo(_ repo: String) -> Bool { repo.wholeMatch(of: #/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+/#) != nil }

    /// The launch line's environment: the app's own minus the agent-session variables it inherits when opened from an agent's
    /// terminal (a session id, a child-session flag, a messaging token), so a launched agent starts as a fresh session. The
    /// script's `zsh -il` profile sets anything the user wants again.
    public static func launchEnvironment(_ env: [String: String]) -> [String: String] {
        // SESSIONHOPPER_ / AGENTCTL_: session-switching tools that wrap claude and export their own session ids.
        env.filter { key, _ in !["CLAUDE", "SESSIONHOPPER_", "CODEX_", "AGENTCTL_"].contains { key.hasPrefix($0) } }
    }

    /// The id to start a new Claude session with (`--session-id`), so its pull request can link it; nil for Codex (no way to
    /// choose one) and for a resume.
    public static func newSessionID(for a: Automation) -> String? {
        a.agent == .claude && (a.sessionID ?? "").isEmpty ? UUID().uuidString.lowercased() : nil
    }

    /// `event` nil = a manual run (Run menu, Try). `home` expands a leading `~`. `newSessionID` (a UUID): a new Claude session
    /// starts with this id; ignored for Codex and resumes. `folders`, `index`, `hints`: `RepoLocator.locate`, only when a template
    /// uses one of its placeholders (nil `index`: scanned here). `installed`: the app checks the launcher's app.
    /// `target`: where it opens (app, custom line, Ghostex reuse); nil = the automation's own `launcher` / `customCommand`.
    /// `prompt` false (Resume Without Prompt): no prompt file and no prompt argument; Ghostex reuse focuses only.
    /// `scenario` and `task` (nil = its built-in text) fill `{task}` first, then the values fill everything in one pass.
    public static func plan(_ a: Automation, pr: TrackedPR, event: PREvent?, account: String, runID: String, runsDir: URL,
                            home: String, newSessionID: String? = nil, folders: RepoFolders = RepoFolders(), index: RepoIndex? = nil,
                            hints: [String] = [], installed: (Launcher) -> Bool = { _ in true }, target: LaunchTarget? = nil,
                            prompt: Bool = true, scenario: Scenario = .general, task: String? = nil) throws -> LaunchPlan {
        let launcher = target?.launcher ?? a.launcher, customCommand = target?.customCommand ?? a.customCommand
        guard isValidRepo(pr.repo) else { throw LaunchError.badRepository(pr.repo) }
        guard installed(launcher) else { throw LaunchError.notInstalled(launcher.title) }
        let session = a.sessionID.flatMap { $0.isEmpty ? nil : $0 }
        if let session, !isValidSessionID(session) { throw LaunchError.badSessionID }
        let newSession = session == nil && a.agent == .claude ? newSessionID : nil
        if let newSession, UUID(uuidString: newSession) == nil { throw LaunchError.badSessionID }
        let parts = pr.repo.split(separator: "/").map(String.init)
        var values = [
            "pr_url": pr.url.absoluteString, "pr_number": "\(pr.number)", "repo": pr.repo, "repo_owner": parts[0], "repo_name": parts[1],
            "is_issue": pr.isIssue ? "true" : "false", "head_sha": pr.headOID,
            "event": event?.kind.rawValue ?? "manual", "event_label": event?.kind.label ?? "Manual run",
            "account": account, "session_id": session ?? "", "automation": a.name,
            "title": PromptTemplate.clean(pr.title, max: 200), "author": PromptTemplate.clean(pr.authorLogin, max: 64),
            "actor": PromptTemplate.clean(event?.actor ?? account, max: 64), "summary": PromptTemplate.clean(event?.summary ?? "", max: 120),
            "branch": pr.isIssue ? "" : PromptTemplate.clean(pr.headRef ?? "", max: 255),
            "scenario": scenario.rawValue, "scenario_label": scenario.label, "resume_note": session == nil ? "" : Scenario.resumeNote,
            "event_url": eventURL(event, pr: pr), "reviewed_sha": pr.myReview?.commitOID.flatMap { $0.wholeMatch(of: #/[0-9a-f]{40}/#) == nil ? nil : $0 } ?? "",
        ]
        // Config into config first: GitHub values below are inserted once and never expanded again.
        let template = PromptTemplate.render(a.prompt, ["task": task ?? scenario.builtIn])
        let folderKeys = ["repo_dir", "repo_root", "main_dir", "worktree_dir"]
        var location: RepoLocation?
        if folderKeys.contains(where: { a.workingDirectory.contains("{\($0)}") || template.contains("{\($0)}") }) {
            let at = RepoLocator.locate(repo: pr.repo, headRef: pr.isIssue ? nil : pr.headRef, hints: hints, folders: folders,
                                        index: index ?? RepoIndex.scan(roots: folders.roots, home: home, now: Date()), home: home)
            for (key, value) in zip(folderKeys, [at.repoDir, at.repoRoot, at.mainDir, at.worktreeDir]) { values[key] = value }
            location = at
        }
        // GitHub text never picks the folder the agent runs in.
        let promptOnly = ["title", "author", "actor", "summary", "branch", "scenario", "scenario_label", "resume_note", "event_url", "reviewed_sha"]
        let cwd = try directory(PromptTemplate.render(a.workingDirectory, values.filter { !promptOnly.contains($0.key) }), home: home)
        values["cwd"] = cwd
        let title = PromptTemplate.clean("PullPing: \(pr.repo) #\(pr.number)", max: 200)
        let promptPath = prompt ? runsDir.appendingPathComponent("\(runID).prompt.md").path : ""
        let scriptPath = runsDir.appendingPathComponent("\(runID).command").path
        let command = agentCommand(a, session: session, newSession: newSession, promptPath: promptPath)
        // -il: interactive login shell, so the user's PATH, functions and aliases apply; the exec keeps the window open.
        let script = """
            #!/bin/zsh -il
            # PullPing automation "\(PromptTemplate.clean(a.name, max: 200))" — \(pr.repo) #\(pr.number) — \(values["event"]!)
            cd \(shellQuote(cwd)) || exit 1
            \(command)
            exec /bin/zsh -il

            """
        let q = shellQuote
        let line: String
        switch launcher {
        case .terminal: line = "open -a Terminal \(q(scriptPath))"
        // iTerm2 runs a script file it is asked to open, in a new window (or tab: its OpenFileInNewWindows setting).
        case .iterm2: line = "open -b com.googlecode.iterm2 \(q(scriptPath))"
        // Ghostty's AppleScript dictionary (in 1.4): a new window in cwd running the script. argv keeps both values out of the
        // AppleScript text; Ghostty runs the command line through /bin/sh, and zsh runs the script as its shebang would.
        case .ghostty:
            line = "osascript -e 'on run argv' -e 'tell application id \"com.mitchellh.ghostty\"' -e 'set cfg to new surface configuration' "
                + "-e 'set initial working directory of cfg to item 1 of argv' -e 'set command of cfg to item 2 of argv' "
                + "-e 'new window with configuration cfg' -e 'activate' -e 'end tell' -e 'end run' \(q(cwd)) \(q("/bin/zsh -il " + q(scriptPath)))"
        // Ghostex 11.5: `ghostex terminal` only records a session that never starts; create-session --start runs it and types
        // --input (the quoted script path, submitted). The project id comes from the launcher at run time.
        case .ghostex: line = "ghostex create-session \(q(title)) --start --project-id \"$PULLPING_GHOSTEX_PROJECT\" --cwd \(q(cwd)) --input \(q(q(scriptPath)))"
        case .custom:
            let custom = customCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !custom.isEmpty else { throw LaunchError.emptyCustomCommand }
            line = PromptTemplate.render(custom, ["script": q(scriptPath), "cwd": q(cwd), "title": q(title), "prompt_file": q(promptPath),
                                                  "agent_command": q(command)])
        }
        var promptText = prompt ? PromptTemplate.render(template, values) : ""
        // The prompt is the agent's positional argument: starting with "-" it would be an option (`{summary}` = "--settings=…"),
        // and a bare placeholder could be a subcommand (`logout`). A leading newline makes it plain text for claude and codex alike.
        if prompt, promptText.first == "-" || template.first == "{" { promptText = "\n" + promptText }
        // Only Ghostex can find the window of an agent session; the target can turn that off.
        let reuse = launcher == .ghostex && target?.reuseRunning != false ? session : nil
        return LaunchPlan(cwd: cwd, title: title, promptText: promptText, promptPath: promptPath,
                          scriptPath: scriptPath, script: script, launchLine: line, repo: location, needsGhostexProject: launcher == .ghostex,
                          focusRunning: reuse.map { GhostexSessions.focusRunning(sessionID: $0, agent: a.agent) },
                          draftLine: prompt ? reuse.map { GhostexSessions.draft(sessionID: $0, promptPath: promptPath) } : nil)
    }

    /// `{event_url}`: the triggering comment's or review's URL when it is `https` on the pull request's own host, else the
    /// pull request's URL.
    static func eventURL(_ event: PREvent?, pr: TrackedPR) -> String {
        guard let url = event?.url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), host == pr.url.host?.lowercased()
        else { return pr.url.absoluteString }
        return url.absoluteString
    }

    /// Interactive sessions: the user watches and steers. The command override replaces the leading word; no permission flags ever.
    /// `promptPath` empty: no prompt argument (Resume Without Prompt).
    static func agentCommand(_ a: Automation, session: String?, newSession: String?, promptPath: String) -> String {
        let override = a.agentCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        // `\claude` skips shell aliases (e.g. one adding a permission-bypass flag) but keeps functions; the override is the user's own.
        let exe = override.isEmpty ? "\\" + a.agent.rawValue : override
        let prompt = promptPath.isEmpty ? "" : " \"$(< \(shellQuote(promptPath)))\""
        if let newSession { return "\(exe) --session-id \(shellQuote(newSession))\(prompt)" }
        guard let session else { return "\(exe)\(prompt)" }
        switch a.agent {
        case .claude: return "\(exe) --resume \(shellQuote(session))\(prompt)"
        case .codex: return "\(exe) resume \(shellQuote(session))\(prompt)"
        }
    }

    /// Trimmed, a leading `~` expanded.
    static func expand(_ raw: String, home: String) -> String {
        let path = raw.trimmingCharacters(in: .whitespaces)
        if path == "~" { return home }
        return path.hasPrefix("~/") ? home + path.dropFirst() : path
    }

    /// Absolute, existing, no `..` segment, after `~` expansion.
    static func directory(_ raw: String, home: String) throws -> String {
        let path = expand(raw, home: home)
        var isDirectory: ObjCBool = false
        guard path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
              FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw LaunchError.badWorkingDirectory(path) }
        return path
    }
}
