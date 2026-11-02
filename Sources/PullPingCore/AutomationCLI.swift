import Foundation

/// `pullping rule|hook|run|runs|automations|kinds`: everything Settings → Automations does, for agents. The file is the
/// interface, so it works while the app is not running (the app picks changes up within 30 s).
/// Exit status: 0 ok, 1 not found, ambiguous, blocked or failed, 2 usage error.
/// One manual run `pullping run` asked for, past the gates (`AutomationCLI.prepareRun`).
public struct RunRequest: Sendable {
    public var automation: Automation
    public var pr: TrackedPR
    /// "manual:<ISO date>", as the app's Run menu records it.
    public var eventID: String
    public var dryRun: Bool
    public var json: Bool
    /// A new Claude session starts with this id (`LaunchPlanner.newSessionID`); `finishRun` links it to the pull request.
    public var newSessionID: String?
    /// `{repo_dir}` and the other folders (`LaunchPlanner.plan`); `hints`: the linked session's folder.
    public var folders = RepoFolders()
    public var hints: [String] = []
    /// Appended to the run's detail: " (folder gone, resumed in …)".
    public var note = ""
    /// `session resume`: Handle with Agent's Resume Session from the shell.
    public var handoff = false
}

public enum AutomationCLI {
    /// `reviewReminder` is PullPing's own repeat, never a poll event.
    static let kinds = EventKind.allCases.filter { $0 != .reviewReminder }

    /// Keep `pullping session set` in it as one unbroken literal (no interpolation): ~/Scripts/pullping-link-pr greps the binary for it.
    public static let help = """
        Usage: pullping <command> [options]

        Everything in Settings → Automations, from the command line: rules and agent hooks start Claude Code or Codex
        in a terminal when a pull request event arrives. Works while PullPing is not running; the app picks changes up
        within 30 seconds.

        Commands:
          rule add|edit|show|list|enable|disable|rm   Rules: act on events across your pull requests.
          hook add|edit|show|list|enable|disable|rm   Hooks: follow up on one pull request or issue.
          session set|show|list|rm|find|resume        The agent session linked to a pull request (Resume Session).
          handler show|set|on|off                     The Handle with Agent button on notifications.
          run <id> [--pr <ref>] [--dry-run]           Run a rule or hook now, like the Run Automation menu.
          runs [--limit <n> | --all]                  Recent runs, newest first.
          activity [--since <time>] [--pr <ref>]      What PullPing saw and did: every event, notification and run.
          automations status|on|off|folders|repos     The Run Automations switch, and where {repo_dir} looks.
          kinds                                       The event kinds --on accepts.
          launchers                                   The terminal apps --launcher accepts.

        From inside a Claude Code session, whenever it creates, reviews or touches a pull request:
          pullping session set --pr <url> --session "$CLAUDE_CODE_SESSION_ID" --agent claude --quiet

        <id> is a unique id prefix of at least 4 characters (see rule list, hook list). Readers and writers take --json:
        the shape automations.json stores. `pullping <command> --help` has the details.

        Automations live in ~/Library/Application Support/PullPing/automations.json (PULLPING_AUTOMATIONS overrides it).
        Exit status: 0 ok, 1 not found, ambiguous, blocked or failed, 2 usage error.
        """

    /// Shared by `rule --help` and `hook --help`.
    static let options = """
        Options for add and edit (edit changes only the ones given; "" clears a list or text):
          --name <text>                       rules: required on add · hooks: default "<repo> #<n> hook"
          --on <kind,…>                       required on add (pullping kinds)
          --prompt <text>                     rules: default the prompt below · hooks: required on add
          --prompt-file <path | ->            the prompt from a file; - reads stdin
          --cwd <dir>                         rules: default {repo_dir}; ~ and placeholders stay as typed
                                              hooks: default the folder the --session Claude session started in, else
                                              the current directory; without --session {repo_dir}
          --scope any|mine|others             rules only; default any
          --repos <owner/name,owner/*,…>      rules only; default every repository
          --actors <login,…>                  only events by these logins; default anyone
          --ask | --auto                      ask first (a Run button; default) or start at once
          --agent claude|codex                default claude
          --command <exe>                     runs instead of claude/codex (a wrapper or shell function)
          --launcher <id>                     default terminal; an installed app (pullping launchers) or custom, which
                                              needs --custom-command
          --custom-command <line>             the launch line; placeholders, inserted already quoted: {script} {cwd} {title}
                                              {prompt_file} {agent_command}
          --repeat <n>                        successful runs per pull request, 1 to 10; rules default 3, hooks 1
          --pr <url | owner/repo#n>           hooks only; required on add
          --session <id> | linked             hooks: resume this session (Claude Code: $CLAUDE_CODE_SESSION_ID; Codex: the
                                              thread id) and link it to the pull request. linked (rules too): the pull
                                              request's linked session (pullping session), skipped where there is none.
                                              Without it a new session starts; edit: "" = new session
          --expires <days>                    hooks only, 1 to 365; default 14
          --enable | --disable                default enabled
          --by <text>                         who wrote it, shown in Settings; default $CLAUDE_CODE_SESSION_ID
          --json                              print the saved automation as JSON

        Prompt placeholders: {pr_url} {pr_number} {repo} {repo_owner} {repo_name} {repo_dir} {repo_root} {main_dir}
        {worktree_dir} {is_issue} {head_sha} {event} {event_label} {account} {session_id} {cwd} {automation}. Text
        written by others on GitHub (cleaned, shortened; never in --cwd): {title} {author} {actor} {summary} {branch}.
        {repo_dir}: the clone of the repository, found by its git remote under the repository folders (pullping
        automations folders, 3 levels deep; pullping automations repos overrides it), else the first <folder>/<repo
        name>, else the fallback folder. {repo_root}: the repository folder holding it. {main_dir}: its main worktree.
        {worktree_dir}: the worktree with the pull request's branch ({branch}) checked out, else {main_dir}. The
        default prompt of a rule:

        \(Automation.defaultPrompt.split(separator: "\n").map { "  " + $0 }.joined(separator: "\n"))

        PullPing never adds permission-bypass flags: the agent starts exactly as you would start it in a terminal.
        """

    public static let ruleHelp = """
        Usage: pullping rule <command> [options]

        A rule starts an agent when one of its events arrives on a pull request it covers: Any, Mine or Others,
        optionally only some repositories and logins. The same rules as Settings → Automations → Rules.

        Commands:
          add      --name <text> --on <kind,…> [options]
          edit     <id> [options]
          show     <id> [--json]
          list     [--json]
          enable   <id>, disable <id>
          rm       <id>

        \(options)

        Example:
          pullping rule add --name "Fix failing CI" --on ciFailed --scope mine --repos 'octo-org/*'
        """

    public static let hookHelp = """
        Usage: pullping hook <command> [options]

        Attach a follow-up to one pull request or issue: when one of the chosen events arrives, PullPing opens a
        terminal running your agent (Claude Code or Codex) with the prompt. By default it asks first (a Run button
        on the notification and in the pull request's menu); --auto starts it at once. One run, then the hook is
        removed (--repeat for more); an unused hook expires after 14 days.

        Commands:
          add      --pr <url | owner/repo#n> --on <kind,…> (--prompt <text> | --prompt-file <path | ->) [options]
          edit     <id> [options]
          show     <id> [--json]
          list     [--pr <ref>] [--json]
          enable   <id>, disable <id>
          rm       <id> | --pr <ref> --all
          kinds    The event kinds --on accepts.

        \(options)

        Example, from inside a Claude Code session:
          pullping hook add --pr "$(gh pr view --json url -q .url)" --on reviewApproved,reviewChangesRequested,comment \\
            --session "$CLAUDE_CODE_SESSION_ID" --prompt "Review what changed on {pr_url} since my last turn and act on it."
        """

    public static let runHelp = """
        Usage: pullping run <id> [--pr <url | owner/repo#n>] [--dry-run] [--json]

        Runs a rule or hook now on a pull request PullPing tracks, like Run Automation in its menus: Run Automations
        must be on, the automation enabled, and its runs per pull request not used up. A rule needs --pr; a hook runs
        on its own pull request. The run shows in Recent Runs (pullping runs). --dry-run prints the working directory,
        the repository folder and how it was found (override, hint, remote, name or fallback; when a folder
        placeholder is used), terminal title, launch line and prompt, and starts and records nothing.
        """

    public static let runsHelp = """
        Usage: pullping runs [--limit <n> | --all] [--json]

        Recent runs, newest first: the last 10 (as in Settings), the last <n>, or all of them (the ledger keeps 500).
        """

    public static let activityHelp = """
        Usage: pullping activity [--limit <n>] [--since <time>] [--pr <url | owner/repo#n>] [--json]

        The activity log, newest first (the last 20, or --limit): every event PullPing saw on a tracked pull request or
        issue and what it did with it (banner, alert, phone, or not shown and why: your own, notifications off,
        paused, muted, snoozed, off in Settings), review reminders, and every run it started. A newly tracked pull
        request's earlier history is not logged. --since: an ISO date (2026-11-01 or 2026-11-01T09:00:00Z) or a
        number with m, h or d (30m, 2d). --json prints the entries as stored.

        The log is ~/Library/Application Support/PullPing/activity.jsonl (PULLPING_ACTIVITY overrides it): one JSON
        object per line, kept for 30 days (Settings → General) and at most 5000 entries.
        """

    public static let automationsHelp = """
        Usage: pullping automations status | on | off [--json]
               pullping automations folders list [--json] | folders add <dir> | folders rm <dir>
               pullping automations fallback [<dir>]
               pullping automations repos list [--json] | repos set <owner/repo> <dir> | repos rm <owner/repo>

        status, on, off: the Run Automations switch in Settings → Automations. Off: no rule or hook starts or offers
        a run, and pullping run refuses. Prints the status: on · 2 rules (1 automatic) · 1 hook · 14 runs, last … OK.

        folders, fallback: Settings → Automations → Repository Folders. {repo_dir}, the default working directory, is
        the clone whose git remote is the repository (owner/repo, any host or SSH alias), whatever its folder is
        called, up to 3 levels below these folders in list order (main worktrees first); else the first
        <folder>/<repo name> that exists (any case); else the fallback folder, so a run never fails only because the
        repository isn't cloned. Default folders: ~/Code; fallback: ~. fallback alone prints it. folders list also
        prints how many clones PullPing finds (--json: each one). PullPing never creates worktrees.

        repos: a folder for one repository that wins over the lookup, for a clone outside these folders.
        """

    public static let sessionHelp = """
        Usage: pullping session set|show|list|rm|find|resume [options]

        A linked session is the agent session that last touched a pull request or issue: Handle with Agent then offers
        Resume Session, and a rule or hook with --session linked resumes it. One per pull request; the last writer
        wins. PullPing also links every new Claude Code session it starts on a pull request.

        Commands:
          set     --pr <url | owner/repo#n> --session <id> [--agent claude|codex] [--cwd <dir>] [--by <text>] [--quiet] [--json]
          show    --pr <ref> [--json]
          list    [--json]
          rm      --pr <ref>
          find    --pr <ref> [--link] [--days <n>] [--exclude <id>] [--json]
          resume  --pr <ref> [--prompt <text> | --prompt-file <path | ->] [--force] [--by <text>] [--json]

        Options for set:
          --session <id>     Claude Code: $CLAUDE_CODE_SESSION_ID; Codex: the thread id
          --agent            default claude
          --cwd <dir>        where the session resumes; default the folder the Claude Code session was started in (read
                             from its transcript), else the current directory
          --by <text>        who linked it; default $CLAUDE_CODE_SESSION_ID
          --quiet            print nothing on success

        Works while PullPing is not running and before it tracks the pull request. A link is dropped 30 days after
        it was set, and an hour after the pull request is merged or closed.

        find: which local session last worked on the pull request. Searches your Claude Code transcripts
        ($CLAUDE_CONFIG_DIR and ~/.claude: projects/) and Codex sessions (~/.codex/sessions) for, best first: the
        record Claude writes when a session creates the pull request (pr-link), its URL or owner/repo#n (mention),
        or a session launched on its branch that names the repository (branch). Newest first, the last 60 days
        (--days), at most 1.5 GB or 10 s of reading. Prints up to 3 with their transcript path; exit 1 when
        none. --exclude: your own session (default $CLAUDE_CODE_SESSION_ID). --link links the best one (not a mere
        mention) with source found. Reads only; nothing leaves your Mac. Runs whatever Look for earlier sessions says.

        resume: Resume Session from the shell. Starts Handle with Agent on the linked session, like the button:
        needs Run Automations and Handle with Agent on, a linked session whose transcript still exists, and
        PullPing tracking the pull request. Refuses a session whose transcript changed in the last 2 minutes (open
        in another terminal; --force starts it anyway), the calling session itself (even with --force) and a second
        hand-off on the pull request within a minute. --prompt replaces the handler's prompt for this run; --by (default
        $CLAUDE_CODE_SESSION_ID) is shown in Recent Runs. After a hand-off, say "handed off to session <id>" and
        stop: never keep editing the same worktree.

        Example, from inside a Claude Code session:
          pullping session set --pr "$(gh pr view --json url -q .url)" --session "$CLAUDE_CODE_SESSION_ID" --agent claude --quiet
          pullping session find --pr https://github.com/octo-org/widgets/pull/12 --link && pullping session resume --pr https://github.com/octo-org/widgets/pull/12
        """

    public static let handlerHelp = """
        Usage: pullping handler show | set [options] | on | off [--json]

        Handle with Agent: a button on the notifications you pick (--on) and an item in the pull request's menu that
        starts your agent on it when you click. With a linked session (pullping session) it becomes Resume Session and New
        Session. Off by default; never runs on its own.

        Options for set (only the given ones change; "" clears --command and --custom-command):
          --on <kind,…|all>                   the notifications that show the buttons (pullping kinds; reviewRequested
                                              covers its reminders); default all but ciPassed, newCommits,
                                              convertedToDraft, merged, closed, retitled, labeled
          --agent claude|codex
          --command <exe>                     runs instead of claude/codex (a wrapper or shell function)
          --launcher <id>                     an installed app (pullping launchers) or custom
          --custom-command <line>
          --cwd <dir>                         default {repo_dir}; ~ and placeholders stay as typed
          --prompt <text> | --prompt-file <path | ->
          --find-sessions on|off              with no linked session, look for an earlier one (pullping session find)
                                              for a notification or the pull request's details; default off
          --by <text>                         who wrote it, shown in Settings; default $CLAUDE_CODE_SESSION_ID

        The default prompt:

        \(Automation.defaultHandlerPrompt.split(separator: "\n").map { "  " + $0 }.joined(separator: "\n"))
        """

    private static let helps = ["rule": ruleHelp, "hook": hookHelp, "run": runHelp, "runs": runsHelp, "automations": automationsHelp,
                                "session": sessionHelp, "handler": handlerHelp, "activity": activityHelp]

    private struct Usage: Error { let message: String }
    private struct Failure: Error { let message: String }
    private struct HelpRequested: Error {}

    /// The binary is both the app and `pullping`: a first argument without a leading `-` (or `--help`, `-h`), or `pullping` alone,
    /// is a command, never a second app instance; no arguments and `-psn_…` / `-NSDocumentRevisionsDebugMode YES` launch the app.
    public static func isCLIInvocation(_ args: [String], program: String) -> Bool {
        guard let first = args.first else { return URL(fileURLWithPath: program).lastPathComponent == "pullping" }
        return !first.hasPrefix("-") || first == "--help" || first == "-h"
    }

    private static let writeOptions: Set<String> = ["name", "on", "prompt", "prompt-file", "cwd", "scope", "repos", "actors", "agent", "command",
                                                    "launcher", "custom-command", "repeat", "pr", "session", "expires", "by"]
    private static let writeFlags: Set<String> = ["ask", "auto", "enable", "disable", "json"]

    /// `args` without the program name: `["rule", "add", …]`, `["runs"]` or `["--help"]`. `run` is `prepareRun` (the app launches).
    /// An unreadable file or a failed save is one stderr line and exit 1 whatever the command printed, also with `--quiet`.
    /// `installed`: whether a launcher's app is installed (the app asks NSWorkspace); `--launcher` takes only those.
    /// `state`: the tracked pull requests, read only when a command needs them (`session find`).
    public static func run(_ args: [String], store: AutomationStore, env: [String: String], now: Date,
                           installed: (Launcher) -> Bool = { _ in true },
                           state: () -> TrackedState = { TrackedState() }) -> (output: String, error: String, status: Int32) {
        let result = dispatch(args, store: store, env: env, now: now, installed: installed, state: state)
        return store.failure.map { ("", "pullping: \($0)", 1) } ?? result
    }

    private static func dispatch(_ args: [String], store: AutomationStore, env: [String: String], now: Date,
                                 installed: (Launcher) -> Bool, state: () -> TrackedState) -> (output: String, error: String, status: Int32) {
        let group = args.first ?? "--help"
        do {
            let command = args.dropFirst().first ?? "--help"
            let rest = Array(args.dropFirst(2))
            switch group {
            case "rule", "hook": return try automations(hook: group == "hook", command, rest, store: store, env: env, now: now, installed: installed)
            case "session": return try session(command, rest, store: store, env: env, now: now, state: state)
            case "handler": return (try handler(command, rest, store: store, env: env, now: now, installed: installed), "", 0)
            case "runs": return (try runs(Array(args.dropFirst()), store: store), "", 0)
            case "activity": return (try activity(Array(args.dropFirst()), env: env, now: now), "", 0)
            case "automations": return (try master(command, rest, store: store, env: env), "", 0)
            case "kinds": return (try kindList(Array(args.dropFirst())), "", 0)
            case "launchers": return (try launcherList(Array(args.dropFirst()), installed: installed), "", 0)
            case "--help", "help", "-h": return (help, "", 0)
            default: throw Usage(message: "unknown command '\(group)'")
            }
        } catch {
            return outcome(error, group: group)
        }
    }

    /// Output, error text and exit status for an error `run` or `prepareRun` threw.
    public static func outcome(_ error: Error, group: String) -> (output: String, error: String, status: Int32) {
        switch error {
        // `session set` promises scripts one stderr line.
        case let usage as Usage where group == "session": ("", "pullping: \(usage.message) (see pullping session --help)", 2)
        case let usage as Usage: ("", "pullping: \(usage.message)\nRun `pullping \(helps[group] == nil ? "" : group + " ")--help` for usage.", 2)
        case let failure as Failure: ("", "pullping: \(failure.message)", 1)
        case is HelpRequested: (helps[group] ?? help, "", 0)
        default: ("", "pullping: \(error.localizedDescription)", 1)
        }
    }

    /// `--key value` options and bare `--flag`s; anything else is positional. `--help` anywhere prints the help.
    private static func parse(_ args: [String], options: Set<String>, flags: Set<String>) throws -> (values: [String: String], flags: Set<String>, positional: [String]) {
        var values: [String: String] = [:], set: Set<String> = [], positional: [String] = []
        var i = 0
        while i < args.count {
            let arg = args[i]
            i += 1
            guard arg.hasPrefix("--") else { positional.append(arg); continue }
            let name = String(arg.dropFirst(2))
            if name == "help" { throw HelpRequested() }
            if flags.contains(name) { set.insert(name); continue }
            guard options.contains(name) else { throw Usage(message: "unknown option \(arg)") }
            guard i < args.count else { throw Usage(message: "\(arg) needs a value") }
            values[name] = args[i]
            i += 1
        }
        return (values, set, positional)
    }

    private static func noArguments(_ positional: [String]) throws {
        if let extra = positional.first { throw Usage(message: "unexpected argument \(extra)") }
    }

    /// `https://github.com/o/r/pull/12`, `…/issues/12`, or `o/r#12`.
    static func parseRef(_ text: String) -> PRRef? {
        let text = text.trimmingCharacters(in: .whitespaces)
        var repo = "", number: Int?
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            let parts = url.path.split(separator: "/").map(String.init)
            guard parts.count >= 4, ["pull", "issues"].contains(parts[2]) else { return nil }
            repo = "\(parts[0])/\(parts[1])"
            number = Int(parts[3])
        } else if let hash = text.lastIndex(of: "#") {
            repo = String(text[..<hash])
            number = Int(text[text.index(after: hash)...])
        }
        guard let number, number > 0, LaunchPlanner.isValidRepo(repo) else { return nil }
        return PRRef(repo: repo, number: number)
    }

    private static func ref(_ value: String?) throws -> PRRef? {
        guard let value else { return nil }
        guard let ref = parseRef(value) else { throw Usage(message: "--pr: expected a pull request URL or owner/repo#number, got \(value)") }
        return ref
    }

    private static func list(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Relative to `$PWD`, `~` expanded, `..` resolved.
    private static func path(_ raw: String, env: [String: String]) -> String {
        let home = env["HOME"] ?? NSHomeDirectory()
        var path = raw
        if path == "~" { path = home } else if path.hasPrefix("~/") { path = home + path.dropFirst() }
        if !path.hasPrefix("/") { path = (env["PWD"] ?? FileManager.default.currentDirectoryPath) + "/" + path }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    // MARK: rule / hook

    private static func automations(hook: Bool, _ command: String, _ args: [String], store: AutomationStore, env: [String: String],
                                    now: Date, installed: (Launcher) -> Bool) throws -> (output: String, error: String, status: Int32) {
        let noun = hook ? "hook" : "rule"
        switch command {
        case "add", "edit", "enable", "disable":
            let (parsed, flags, positional) = try parse(["add", "edit"].contains(command) ? args : args + ["--\(command)"],
                                                        options: writeOptions, flags: writeFlags)
            var values = parsed
            try readPromptFile(&values, env: env)
            let saved: Automation
            if command == "add" {
                try noArguments(positional)
                var a = try defaults(values, hook: hook, env: env, now: now)
                try apply(values, flags, to: &a, hook: hook, env: env, now: now, installed: installed)
                store.mutate { file in
                    file.automations.append(a)
                    if let link = sessionLink(a, values, now: now) { file.setLink(link) }
                }
                saved = a
            } else {
                guard positional.count == 1 else { throw Usage(message: "\(command) takes one id prefix") }
                guard !values.isEmpty || !flags.subtracting(["json"]).isEmpty else { throw Usage(message: "edit needs an option to change") }
                saved = try store.mutate { file in
                    Result {
                        var a = try resolve(positional[0], in: file.automations, hook: hook)
                        try apply(values, flags, to: &a, hook: hook, env: env, now: now, installed: installed)  // on a copy: a failed check changes nothing
                        file.automations[file.automations.firstIndex { $0.id == a.id }!] = a
                        if let link = sessionLink(a, values, now: now) { file.setLink(link) }
                        return a
                    }
                }.get()
            }
            let output = flags.contains("json") ? try encode(saved) : summary(saved, verb: command == "add" ? "Added" : "Updated", on: values["on"])
            // The rule editor's warning.
            let note = saved.mode == .auto && saved.actors.isEmpty
                ? "note: \(saved.usesLinkedSession ? "resumes the pull request's linked session" : "runs") for events by anyone who can comment on the repository; add --actors to limit it" : ""
            return (output, note, 0)
        case "show":
            let (_, flags, positional) = try parse(args, options: [], flags: ["json"])
            guard positional.count == 1 else { throw Usage(message: "show takes one id prefix") }
            let a = try resolve(positional[0], in: store.load().automations, hook: hook)
            return (flags.contains("json") ? try encode(a) : show(a), "", 0)
        case "list":
            let (values, flags, positional) = try parse(args, options: hook ? ["pr"] : [], flags: ["json"])
            try noArguments(positional)
            let filter = try ref(values["pr"])
            let items = store.load().automations.filter { a in
                guard a.isHook == hook else { return false }
                return filter.map { f in a.pr.map { f.repo.lowercased() == $0.repo.lowercased() && f.number == $0.number } ?? false } ?? true
            }
            if flags.contains("json") { return (try encode(items), "", 0) }
            guard !items.isEmpty else { return ("No \(noun)s.", "", 0) }
            return (items.map(row).joined(separator: "\n"), "", 0)
        case "rm":
            return (try remove(args, hook: hook, store: store), "", 0)
        case "kinds" where hook:
            return (try kindList(args), "", 0)
        case "--help", "help":
            throw HelpRequested()
        default:
            throw Usage(message: "unknown \(noun) command \(command)")
        }
    }

    /// `--prompt-file` becomes `--prompt`; read before the lock: stdin may take its time.
    private static func readPromptFile(_ values: inout [String: String], env: [String: String]) throws {
        guard let file = values.removeValue(forKey: "prompt-file") else { return }
        guard values["prompt"] == nil else { throw Usage(message: "use --prompt or --prompt-file, not both") }
        let data = file == "-" ? FileHandle.standardInput.readDataToEndOfFile() : FileManager.default.contents(atPath: path(file, env: env))
        guard let data, let text = String(data: data, encoding: .utf8) else { throw Usage(message: "can't read --prompt-file \(file)") }
        values["prompt"] = text
    }

    /// `hook add|edit --session <id>` also links the session to the hook's pull request, in the hook's folder.
    private static func sessionLink(_ a: Automation, _ values: [String: String], now: Date) -> SessionLink? {
        guard values["session"] != nil, let pr = a.pr, let id = a.sessionID, !a.usesLinkedSession else { return nil }
        return SessionLink(pr: pr, agent: a.agent, sessionID: id, cwd: a.workingDirectory, setAt: now, source: "cli", by: a.by)
    }

    /// What `add` starts from (the rule editor's new rule, or a hook's defaults), after checking what add requires.
    private static func defaults(_ values: [String: String], hook: Bool, env: [String: String], now: Date) throws -> Automation {
        for key in hook ? ["pr", "on", "prompt"] : ["name", "on"] where values[key] == nil {
            throw Usage(message: key == "prompt" ? "--prompt or --prompt-file is required" : key == "on" ? "--on is required (see pullping kinds)" : "--\(key) is required")
        }
        var a = Automation(name: "", kinds: [], workingDirectory: Automation.defaultDirectory, createdAt: now)
        guard hook, let pr = try ref(values["pr"]) else { return a }
        if values["session"] == "" {
            throw Usage(message: "--session is empty ($CLAUDE_CODE_SESSION_ID is set only inside Claude Code); leave it out for a new session")
        }
        a.name = "\(pr.repo) #\(pr.number) hook"
        a.maxRunsPerPR = 1
        a.expiresAt = now.addingTimeInterval(14 * 86_400)
        // Resuming needs the session's folder (`apply` looks it up; else here); a new session runs in the repository's folder.
        if values["cwd"] == nil, let session = values["session"], session != Automation.linkedSession {
            a.workingDirectory = try directory(env["PWD"] ?? FileManager.default.currentDirectoryPath, hook: true, env: env)
        }
        return a
    }

    /// Sets the given options on `a` and checks the result like the rule editor's Save. Every write is the CLI's: `source`, `by`,
    /// and a due notice when this write makes the automation run automatically.
    static func apply(_ values: [String: String], _ flags: Set<String>, to a: inout Automation, hook: Bool, env: [String: String], now: Date,
                      installed: (Launcher) -> Bool = { _ in true }) throws {
        let wasAutomatic = a.mode == .auto && a.enabled
        if let other = (hook ? ["scope", "repos"] : ["pr", "expires"]).first(where: { values[$0] != nil }) {
            throw Usage(message: hook ? "--\(other) is for rules only: a hook matches its one pull request"
                                      : other == "expires" ? "--expires is for hooks only: rules don't expire" : "--\(other) is for hooks only")
        }
        if !hook, let session = values["session"], !["", Automation.linkedSession].contains(session) {
            throw Usage(message: "--session on a rule can only be linked (the pull request's linked session): a rule covers many pull requests")
        }
        for (one, two) in [("ask", "auto"), ("enable", "disable")] where flags.contains(one) && flags.contains(two) {
            throw Usage(message: "use --\(one) or --\(two), not both")
        }
        if let name = values["name"] { a.name = PromptTemplate.clean(name, max: 200) }
        if let on = values["on"] { a.kinds = try a.id == Automation.handlerID && on == "all" ? [] : kindSet(on) }  // the handler's [] = every kind
        if let prompt = values["prompt"] { a.prompt = prompt }
        if let cwd = values["cwd"] { a.workingDirectory = try directory(cwd, hook: hook, env: env) }
        if let scope = values["scope"] { a.scope = try choice(scope, "--scope") }
        if let repos = values["repos"] {
            a.repos = list(repos)
            if let bad = a.repos.first(where: { $0.wholeMatch(of: #/[A-Za-z0-9_.-]+\/([A-Za-z0-9_.-]+|\*)/#) == nil }) {
                throw Usage(message: "--repos: expected owner/name or owner/*, got \(bad)")
            }
        }
        if let actors = values["actors"] { a.actors = list(actors) }
        if flags.contains("ask") { a.mode = .ask }
        if flags.contains("auto") { a.mode = .auto }
        if let agent = values["agent"] { a.agent = try choice(agent, "--agent") }
        if let command = values["command"] { a.agentCommand = command }
        if let launcher = values["launcher"] {
            a.launcher = try choice(launcher, "--launcher")
            guard installed(a.launcher) else { throw Usage(message: "--launcher \(launcher): \(a.launcher.title) is not installed (see pullping launchers)") }
        }
        if let custom = values["custom-command"] { a.customCommand = custom }
        if let raw = values["repeat"] {
            guard let repeats = Int(raw), (1...10).contains(repeats) else { throw Usage(message: "--repeat must be 1 to 10") }
            a.maxRunsPerPR = repeats
        }
        if let pr = try ref(values["pr"]) { a.pr = pr }
        if let session = values["session"] {
            guard session.isEmpty || LaunchPlanner.isValidSessionID(session) else {
                throw Usage(message: "--session may only contain letters, digits, '.', '_' and '-' (at most 128)")
            }
            a.sessionID = session.isEmpty ? nil : session
            // `claude --resume` finds a session only from the folder it was started in.
            if hook, values["cwd"] == nil, a.agent == .claude, !session.isEmpty, !a.usesLinkedSession,
               let found = ClaudeSessions.launchDirectory(sessionID: session, env: env), let dir = try? directory(found, hook: true, env: env) {
                a.workingDirectory = dir
            }
        }
        if let raw = values["expires"] {
            guard let days = Int(raw), (1...365).contains(days) else { throw Usage(message: "--expires must be 1 to 365 days") }
            a.expiresAt = now.addingTimeInterval(Double(days) * 86_400)
        }
        if flags.contains("enable") { a.enabled = true }
        if flags.contains("disable") { a.enabled = false }
        func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if blank(a.name) { throw Usage(message: "the name is empty") }
        if blank(a.prompt) { throw Usage(message: "the prompt is empty") }
        if a.launcher == .custom && blank(a.customCommand) { throw Usage(message: "--launcher custom needs --custom-command") }
        if wasAutomatic && a.source != "cli" { a.autoNoticeAt = a.autoNoticeAt ?? now }  // made automatic in Settings: no CLI notice
        a.source = "cli"
        a.by = PromptTemplate.clean(values["by"] ?? env["CLAUDE_CODE_SESSION_ID"] ?? "", max: 64)
        if !wasAutomatic && a.mode == .auto && a.enabled { a.autoNoticeAt = nil }
    }

    private static func kindSet(_ text: String) throws -> Set<EventKind> {
        let names = list(text)
        guard !names.isEmpty else { throw Usage(message: "--on needs at least one kind (see pullping kinds)") }
        return Set(try names.map { raw in
            guard let kind = EventKind(rawValue: raw), kinds.contains(kind) else { throw Usage(message: "unknown event kind \(raw) (see pullping kinds)") }
            return kind
        })
    }

    private static func choice<T: CaseIterable & RawRepresentable>(_ raw: String, _ option: String) throws -> T where T.RawValue == String {
        guard let value = T(rawValue: raw) else {
            let names = T.allCases.map(\.rawValue)
            throw Usage(message: "\(option) must be \(names.dropLast().joined(separator: ", ")) or \(names.last!)")
        }
        return value
    }

    /// Hooks: resolved against `$PWD`. Rules: `/…`, `~…` and anything with a placeholder stay as typed (as in the rule editor),
    /// the rest resolves against `$PWD`. Without a placeholder it must be a folder PullPing can start the agent in.
    private static func directory(_ raw: String, hook: Bool, env: [String: String]) throws -> String {
        if !hook && raw.contains("{") { return raw }
        let path = !hook && (raw.hasPrefix("/") || raw.hasPrefix("~")) ? raw : path(raw, env: env)
        guard (try? LaunchPlanner.directory(path, home: env["HOME"] ?? NSHomeDirectory())) != nil else {
            throw Usage(message: "--cwd is not an existing directory: \(path)")
        }
        return path
    }

    /// A unique id prefix (at least 4 characters, any case) among hooks (`hook` true), rules (false) or both (nil).
    static func resolve(_ prefix: String, in automations: [Automation], hook: Bool?) throws -> Automation {
        let noun = hook.map { $0 ? "hook" : "rule" } ?? "automation"
        guard prefix.count >= 4 else { throw Usage(message: "the id prefix needs at least 4 characters") }
        let found = automations.filter { a in (hook.map { $0 == a.isHook } ?? true) && a.id.uuidString.lowercased().hasPrefix(prefix.lowercased()) }
        guard !found.isEmpty else { throw Failure(message: "no \(noun) matches \(prefix)") }
        guard found.count == 1 else { throw Failure(message: "\(prefix) matches \(found.count) \(noun)s; use more characters") }
        return found[0]
    }

    private static func remove(_ args: [String], hook: Bool, store: AutomationStore) throws -> String {
        let (values, flags, positional) = try parse(args, options: hook ? ["pr"] : [], flags: hook ? ["all"] : [])
        if let pr = try ref(values["pr"]) {
            guard flags.contains("all"), positional.isEmpty else { throw Usage(message: "rm --pr needs --all, and no id") }
            let count = store.mutate { file -> Int in
                let before = file.automations.count
                file.automations.removeAll { $0.pr.map { $0.repo.lowercased() == pr.repo.lowercased() && $0.number == pr.number } ?? false }
                return before - file.automations.count
            }
            return "Removed \(count) \(count == 1 ? "hook" : "hooks") on \(pr.repo) #\(pr.number)."
        }
        guard positional.count == 1, !flags.contains("all") else { throw Usage(message: hook ? "rm takes one id prefix, or --pr <ref> --all" : "rm takes one id prefix") }
        let removed = try store.mutate { file in
            Result {
                let a = try resolve(positional[0], in: file.automations, hook: hook)
                file.automations.removeAll { $0.id == a.id }
                return a
            }
        }.get()
        guard let pr = removed.pr else { return "Removed rule \(shortID(removed)) (\(removed.name))." }
        return "Removed hook \(shortID(removed)) on \(pr.repo) #\(pr.number)."
    }

    // MARK: Output

    private static func encode(_ value: some Encodable) throws -> String { String(decoding: try AutomationStore.encoder.encode(value), as: UTF8.self) }

    private static func json(_ object: Any) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data(), as: UTF8.self)
    }

    private static func kindNames(_ a: Automation) -> [String] { kinds.filter(a.kinds.contains).map(\.rawValue) }

    /// One line per automation, two-space separated.
    private static func row(_ a: Automation) -> String {
        let tail = [a.enabled ? "on" : "off", a.source.isEmpty ? "-" : a.source]
        if let pr = a.pr {
            return ([shortID(a), "\(pr.repo) #\(pr.number)", kindNames(a).joined(separator: ","), agentWord(a), sessionWord(a), a.mode.rawValue,
                     a.expiresAt.map { "expires \($0.formatted(.iso8601.year().month().day()))" } ?? ""] + tail).joined(separator: "  ")
        }
        return ([shortID(a), a.name, kindNames(a).joined(separator: ","), a.scope.rawValue, a.repos.isEmpty ? "all" : a.repos.joined(separator: ","),
                 a.mode.rawValue, agentWord(a), sessionWord(a), a.launcher.title, "\(a.maxRunsPerPR)/pr"] + tail).joined(separator: "  ")
    }

    /// `key  value` lines in field order (then `extra`), then the prompt indented.
    private static func show(_ a: Automation, extra: [(String, String)] = []) -> String {
        let rows = [
            ("id", a.id.uuidString.lowercased()), ("name", a.name), ("enabled", a.enabled ? "on" : "off"), ("kinds", a.kinds.isEmpty && a.id == Automation.handlerID ? "all" : kindNames(a).joined(separator: ",")),
            ("scope", a.scope.rawValue), ("repos", a.repos.joined(separator: ",")), ("actors", a.actors.joined(separator: ",")),
            ("mode", a.mode.rawValue), ("agent", a.agent.rawValue), ("command", a.agentCommand), ("launcher", a.launcher.rawValue),
            ("custom command", a.customCommand), ("cwd", a.workingDirectory), ("runs per PR", "\(a.maxRunsPerPR)"),
            ("pr", a.pr.map { "\($0.repo)#\($0.number)" } ?? ""), ("session", a.sessionID ?? ""), ("expires", a.expiresAt?.ISO8601Format() ?? ""),
            ("source", a.source), ("by", a.by), ("created", a.createdAt.ISO8601Format()),
        ] + extra
        return (table(rows) + ["prompt:"] + a.prompt.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }).joined(separator: "\n")
    }

    private static func table(_ rows: [(String, String)]) -> [String] {
        rows.map { key, value in (key.padding(toLength: 16, withPad: " ", startingAt: 0) + value).trimmingCharacters(in: .whitespaces) }
    }

    /// "Added rule 1a2b3c4d: Fix failing CI — ciFailed on mine (octo-org/*) → claude in Terminal, ask, 3 runs per pull request."
    /// `on`: the kinds in the order given.
    private static func summary(_ a: Automation, verb: String, on: String?) -> String {
        var seen = Set<String>()
        let names = on.map { list($0).filter { seen.insert($0).inserted } } ?? kindNames(a)
        let end = a.enabled ? "." : ", off."
        if let pr = a.pr {
            return "\(verb) hook \(shortID(a)): \(names.joined(separator: ", ")) on \(pr.repo) #\(pr.number) → "
                + "\(agentWord(a)) (\(sessionWord(a))) in \(a.launcher.title), \(a.mode.rawValue)" + end
        }
        let repos = a.repos.isEmpty ? "" : " (\(a.repos.joined(separator: ", ")))"
        return "\(verb) rule \(shortID(a)): \(a.name) — \(names.joined(separator: ", ")) on \(a.scope.rawValue)\(repos) → \(agentWord(a))"
            + "\(a.usesLinkedSession ? " (linked session)" : "") in \(a.launcher.title), \(a.mode.rawValue), \(a.maxRunsPerPR) \(a.maxRunsPerPR == 1 ? "run" : "runs") per pull request" + end
    }

    private static func kindList(_ args: [String]) throws -> String {
        let (_, flags, positional) = try parse(args, options: [], flags: ["json"])
        try noArguments(positional)
        if flags.contains("json") { return json(kinds.map { ["kind": $0.rawValue, "label": $0.label] }) }
        return kinds.map { $0.rawValue.padding(toLength: 24, withPad: " ", startingAt: 0) + $0.label }.joined(separator: "\n")
    }

    /// Every launcher, the ones whose app is missing marked; `--launcher` refuses those.
    private static func launcherList(_ args: [String], installed: (Launcher) -> Bool) throws -> String {
        let (_, flags, positional) = try parse(args, options: [], flags: ["json"])
        try noArguments(positional)
        if flags.contains("json") { return json(Launcher.allCases.map { ["id": $0.rawValue, "title": $0.title, "installed": installed($0)] as [String: Any] }) }
        return Launcher.allCases.map { $0.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0) + $0.title + (installed($0) ? "" : " (not installed)") }
            .joined(separator: "\n")
    }

    // MARK: run

    /// `args` after `run`. Resolves the id among rules and hooks and the pull request among the tracked ones, then the Run Automation
    /// menu's gates in its order and words: Run Automations, enabled and unexpired (read fresh by id), then duplicate and runs per pull
    /// request. Like every manual run it skips the cooldown and the failure cap, and pause, mute, snooze and hidden.
    /// A linked-session automation resumes the pull request's link (none: refused), as in the app.
    public static func prepareRun(_ args: [String], store: AutomationStore, state: TrackedState, env: [String: String], now: Date) throws -> RunRequest {
        guard !args.isEmpty else { throw HelpRequested() }
        let (values, flags, positional) = try parse(args, options: ["pr"], flags: ["dry-run", "json"])
        guard positional.count == 1 else { throw Usage(message: "run takes one id prefix") }
        let file = store.load()
        if let failure = store.failure { throw Failure(message: failure) }
        let a = try resolve(positional[0], in: file.automations, hook: nil)
        guard let target = try ref(values["pr"]) ?? a.pr else { throw Usage(message: "--pr is required to run a rule") }
        guard let pr = tracked(target, in: state) else {
            throw Failure(message: "PullPing is not tracking \(target.repo) #\(target.number) yet")
        }
        guard file.enabled else { throw Failure(message: "Automations are off (pullping automations on)") }
        guard AutomationMatcher.current(a.id, in: file.automations, now: now) != nil else {
            throw Failure(message: a.enabled ? "\(a.name) has expired" : "\(a.name) is off (pullping \(a.isHook ? "hook" : "rule") enable \(shortID(a)))")
        }
        let eventID = "manual:\(now.ISO8601Format())"
        if let reason = AutomationMatcher.blocked(a, prID: pr.id, eventID: eventID, runs: file.runs, now: now, manual: true) {
            throw Failure(message: reason)
        }
        let resolved = try file.resolved(a, repo: pr.repo, number: pr.number, headRef: pr.headRef, env: env)
        return RunRequest(automation: resolved.automation, pr: pr, eventID: eventID, dryRun: flags.contains("dry-run"), json: flags.contains("json"),
                          newSessionID: LaunchPlanner.newSessionID(for: resolved.automation), folders: file.repoFolders,
                          hints: file.link(for: pr.repo, number: pr.number).map { [$0.cwd] } ?? [], note: resolved.note)
    }

    /// `session resume` (args after it): the panel's Resume Session from the shell, as a handler run with the same gates and
    /// ledger, one line each, in this order: Run Automations, Handle with Agent, a link, a tracked pull request, the transcript,
    /// not open elsewhere (changed < 2 min; `--force`), no hand-off on this pull request in the last minute.
    public static func prepareHandlerRun(_ args: [String], store: AutomationStore, state: TrackedState, env: [String: String], now: Date) throws -> RunRequest {
        let (parsed, flags, positional) = try parse(args, options: ["pr", "prompt", "prompt-file", "by"], flags: ["force", "json"])
        try noArguments(positional)
        var values = parsed
        try readPromptFile(&values, env: env)
        guard let target = try ref(values["pr"]) else { throw Usage(message: "--pr is required") }
        let file = store.load()
        if let failure = store.failure { throw Failure(message: failure) }
        guard file.enabled else { throw Failure(message: "Automations are off (pullping automations on)") }
        guard file.handler.enabled else { throw Failure(message: "Handle with Agent is off (pullping handler on)") }
        guard let link = file.link(for: target.repo, number: target.number) else {
            throw Failure(message: "No session linked to \(target.repo) #\(target.number) (pullping session find --pr <url> --link)")
        }
        // Never a hand-off to the caller itself, even with --force: that would be a second terminal on this very session.
        if link.sessionID == env["CLAUDE_CODE_SESSION_ID"] { throw Failure(message: "Session \(link.sessionID.prefix(8))… is this session; continue here") }
        guard let pr = tracked(target, in: state) else {
            throw Failure(message: "PullPing is not tracking \(target.repo) #\(target.number) yet")
        }
        let transcript = SessionFinder.transcript(agent: link.agent, sessionID: link.sessionID, env: env)
        if transcript == nil, link.agent == .claude, !ClaudeSessions.projectDirectories(env: env).isEmpty { throw LaunchError.sessionGone(link.sessionID) }
        let changed = transcript.flatMap { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date }
        if !flags.contains("force"), let changed, now.timeIntervalSince(changed) < SessionFinder.openWithin {
            throw Failure(message: "Session \(link.sessionID.prefix(8))… appears to be open in another terminal (changed \(max(0, Int(now.timeIntervalSince(changed)))) s ago); continue there, or add --force")
        }
        // shortcut: a hand-off is a handler run labelled "(resume …)" (Store and finishRun both write it); a field on RunRecord if that label ever changes.
        if let last = file.runs.last(where: { $0.automationID == Automation.handlerID && $0.prID == pr.id && $0.ok && $0.label.contains(" (resume ") }),
           now.timeIntervalSince(last.at) < 60 {
            throw Failure(message: "Handed off \(max(0, Int(now.timeIntervalSince(last.at)))) s ago")
        }
        var handler = file.handler
        handler.sessionID = Automation.linkedSession
        if let prompt = values["prompt"] { handler.prompt = prompt }
        let resolved = try file.resolved(handler, repo: pr.repo, number: pr.number, headRef: pr.headRef, env: env)
        let by = PromptTemplate.clean(values["by"] ?? env["CLAUDE_CODE_SESSION_ID"] ?? "", max: 64)
        return RunRequest(automation: resolved.automation, pr: pr, eventID: "manual:\(now.ISO8601Format())", dryRun: false, json: flags.contains("json"),
                          newSessionID: nil, folders: file.repoFolders, hints: [link.cwd], note: resolved.note + (by.isEmpty ? "" : " · by \(by)"), handoff: true)
    }

    /// Records the run as the app's Run menu does (Recent Runs, runs per pull request and the failure cap count it) and reports it.
    /// `error` nil = started, in `cwd`: a new Claude session (`request.newSessionID`) becomes the pull request's linked session.
    public static func finishRun(_ request: RunRequest, runID: String, error: String?, store: AutomationStore, now: Date,
                                 cwd: String? = nil) -> (output: String, error: String, status: Int32) {
        let a = request.automation, pr = request.pr, detail = error ?? a.launcher.title + request.note
        let name = a.id == Automation.handlerID ? "\(a.name) (\(sessionWord(a)))" : a.name  // as the app records it
        store.mutate {
            $0.runs.append(RunRecord(automationID: a.id, prID: pr.id, eventID: request.eventID, at: now, ok: error == nil, detail: detail,
                                     label: "\(name) · \(pr.repo) #\(pr.number)"))
            if error == nil, let id = request.newSessionID, let cwd {
                $0.setLink(SessionLink(pr: PRRef(repo: pr.repo, number: pr.number), agent: .claude, sessionID: id, cwd: cwd, setAt: now, source: "cli", by: ""))
            }
        }
        var object: [String: Any] = ["ok": error == nil, "runID": runID, "automation": a.id.uuidString, "pr": "\(pr.repo)#\(pr.number)", "detail": detail]
        if request.handoff { object["session"] = a.sessionID ?? "" }
        let started = request.handoff
            ? "Resumed \(agentWord(a)) \((a.sessionID ?? "").prefix(8))… on \(pr.repo) #\(pr.number) in \(a.launcher.title) (\(tilde(cwd ?? a.workingDirectory, home: NSHomeDirectory())))."
            : "Started \(a.name) on \(pr.repo) #\(pr.number) in \(a.launcher.title)."
        let output = request.json ? json(object) : error == nil ? started : ""
        let failure = error ?? store.failure  // started but not recorded is a failure too
        return (output, failure.map { "pullping: \($0)" } ?? "", failure == nil ? 0 : 1)
    }

    /// `run --dry-run`: what the run would do. Nothing is written, started or recorded.
    public static func dryRun(_ plan: LaunchPlan, json asJSON: Bool) -> String {
        let repo = plan.repo.map { ["repo         \($0.repoDir) (\($0.source))"] } ?? []
        if asJSON {
            return json(["cwd": plan.cwd, "title": plan.title, "launchLine": plan.launchLine, "prompt": plan.promptText]
                .merging(plan.repo.map { ["repo": $0.repoDir, "repoSource": $0.source] } ?? [:]) { $1 })
        }
        return (["cwd          \(plan.cwd)"] + repo + ["title        \(plan.title)", "launch line  \(plan.launchLine)", "prompt:"]
            + plan.promptText.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }).joined(separator: "\n")
    }

    // MARK: runs / automations

    private static func runs(_ args: [String], store: AutomationStore) throws -> String {
        let (values, flags, positional) = try parse(args, options: ["limit"], flags: ["all", "json"])
        try noArguments(positional)
        if values["limit"] != nil && flags.contains("all") { throw Usage(message: "use --limit or --all, not both") }
        let limit = try values["limit"].map { raw in
            guard let n = Int(raw), n >= 1 else { throw Usage(message: "--limit must be a number from 1") }
            return n
        } ?? 10
        let all = store.load().runs
        let runs = Array((flags.contains("all") ? all[...] : all.suffix(limit)).reversed())
        if flags.contains("json") { return try encode(runs) }
        guard !runs.isEmpty else { return "No runs yet." }
        return runs.map { run in
            [stamp(run.at), run.ok ? "OK  " : "FAIL", run.label.isEmpty ? String(run.automationID.uuidString.lowercased().prefix(8)) : run.label, run.detail]
                .joined(separator: "  ")
        }.joined(separator: "\n")
    }

    private static func activity(_ args: [String], env: [String: String], now: Date) throws -> String {
        let (values, flags, positional) = try parse(args, options: ["limit", "since", "pr"], flags: ["json"])
        try noArguments(positional)
        let limit = try values["limit"].map { raw in
            guard let n = Int(raw), n >= 1 else { throw Usage(message: "--limit must be a number from 1") }
            return n
        } ?? 20
        let since = try values["since"].map { raw in
            guard let date = sinceDate(raw, now: now) else { throw Usage(message: "--since: expected an ISO date or a number with m, h or d (30m, 2d), got \(raw)") }
            return date
        }
        let pr = try ref(values["pr"])
        let entries = Array(ActivityLog.read(ActivityLog.defaultURL(env)).reversed()
            .filter { e in (since.map { e.at >= $0 } ?? true) && (pr.map { $0.matches(e.repo, e.number) } ?? true) }.prefix(limit))
        if flags.contains("json") { return try encode(entries) }
        guard !entries.isEmpty else { return "No activity." }
        return entries.map { e in [stamp(e.at), "\(e.repo) #\(e.number)", e.what, "→ \(e.outcome)", e.title].joined(separator: "  ") }.joined(separator: "\n")
    }

    /// `30m`, `1h`, `2d`, `2026-11-01` (local midnight) or a full ISO-8601 date.
    static func sinceDate(_ text: String, now: Date) -> Date? {
        let units: [Character: Double] = ["m": 60, "h": 3600, "d": 86_400]
        if let unit = text.last.flatMap({ units[$0] }), let n = Int(text.dropLast()), n >= 0 { return now.addingTimeInterval(-Double(n) * unit) }
        if let date = try? Date(text, strategy: .iso8601) { return date }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        return day.date(from: text)
    }

    /// Local time, minutes: "2026-11-01 14:02".
    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func master(_ command: String, _ args: [String], store: AutomationStore, env: [String: String]) throws -> String {
        if ["folders", "fallback", "repos"].contains(command) { return try folders(command, args, store: store, env: env) }
        let (_, flags, positional) = try parse(args, options: [], flags: ["json"])
        try noArguments(positional)
        let file: AutomationFile
        switch command {
        case "status": file = store.load()
        case "on", "off": file = store.mutate { $0.enabled = command == "on"; return $0 }
        case "--help", "help": throw HelpRequested()
        default: throw Usage(message: "unknown automations command \(command)")
        }
        let rules = file.automations.filter { !$0.isHook }
        if flags.contains("json") {
            return json(["enabled": file.enabled, "rules": rules.count, "hooks": file.automations.count - rules.count, "runs": file.runs.count,
                         "handler": file.handler.enabled, "sessions": file.sessions.count, "findSessions": file.findSessions])
        }
        func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
        let automatic = rules.filter { $0.enabled && $0.mode == .auto }.count
        return "\(file.enabled ? "on" : "off") · \(count(rules.count, "rule"))" + (automatic > 0 ? " (\(automatic) automatic)" : "")
            + " · \(count(file.automations.count - rules.count, "hook")) · \(count(file.runs.count, "run"))"
            + (file.runs.last.map { ", last \(stamp($0.at)) \($0.ok ? "OK" : "FAIL")" } ?? "") + " · handler \(file.handler.enabled ? "on" : "off")"
            + (file.findSessions ? " · find sessions on" : "")
    }

    /// `folders list|add <dir>|rm <dir>`, `fallback [<dir>]`, `repos list|set|rm`: where `{repo_dir}` looks (`RepoFolders`).
    private static func folders(_ command: String, _ args: [String], store: AutomationStore, env: [String: String]) throws -> String {
        let (_, flags, positional) = try parse(args, options: [], flags: ["json"])
        /// As --cwd: `~…` and `/…` stay as typed, the rest resolves against $PWD; an existing folder, no `..`.
        func folder(_ raw: String) throws -> String {
            guard !raw.contains("{") else { throw Usage(message: "a folder can't hold placeholders: \(raw)") }
            return try directory(raw, hook: false, env: env)
        }
        func same(_ a: String, _ b: String) -> Bool { path(a, env: env) == path(b, env: env) }
        if command == "repos" { return try repos(positional, json: flags.contains("json"), store: store, env: env, folder: folder) }
        if command == "fallback" {
            guard positional.count <= 1 else { throw Usage(message: "fallback takes one folder") }
            guard let raw = positional.first else { return store.load().repoFolders.fallback }
            let dir = try folder(raw)
            store.mutate { $0.repoFolders.fallback = dir }
            return "Fallback folder: \(dir)."
        }
        switch (positional.first ?? "--help", positional.count) {
        case ("list", 1):
            let folders = store.load().repoFolders, started = Date()
            let index = RepoIndex.scan(roots: folders.roots, home: env["HOME"] ?? NSHomeDirectory(), now: started)
            if flags.contains("json") {
                return json(["folders": folders.roots, "fallback": folders.fallback, "truncated": index.truncated,
                             "index": index.entries.map { ["path": $0.path, "main": $0.main, "branch": $0.branch ?? NSNull(), "keys": $0.keys] as [String: Any] }])
            }
            let scanned = "repos scanned: \(index.entries.count) (\(Int(Date().timeIntervalSince(started) * 1000)) ms\(index.truncated ? ", stopped at the limit" : ""))"
            return (folders.roots + ["fallback: \(folders.fallback)", scanned]).joined(separator: "\n")
        case ("add", 2):
            let dir = try folder(positional[1])
            let added = store.mutate { file -> Bool in
                guard !file.repoFolders.roots.contains(where: { same($0, dir) }) else { return false }
                file.repoFolders.roots.append(dir)
                return true
            }
            return added ? "Added \(dir) to the repository folders." : "\(dir) is already a repository folder."
        case ("rm", 2):
            let removed = store.mutate { file -> Bool in
                let before = file.repoFolders.roots.count
                file.repoFolders.roots.removeAll { same($0, positional[1]) }
                return file.repoFolders.roots.count < before
            }
            guard removed else { throw Failure(message: "\(positional[1]) is not a repository folder") }
            return "Removed \(positional[1]) from the repository folders."
        case ("--help", _), ("help", _): throw HelpRequested()
        default: throw Usage(message: "expected folders list, folders add <dir> or folders rm <dir>")
        }
    }

    /// `repos list | set <owner/repo> <dir> | rm <owner/repo>`: `RepoFolders.overrides`, keys lowercased.
    private static func repos(_ positional: [String], json asJSON: Bool, store: AutomationStore, env: [String: String],
                              folder: (String) throws -> String) throws -> String {
        func key(_ raw: String) throws -> String {
            guard LaunchPlanner.isValidRepo(raw) else { throw Usage(message: "expected owner/repo, got \(raw)") }
            return raw.lowercased()
        }
        switch (positional.first ?? "--help", positional.count) {
        case ("list", 1):
            let overrides = store.load().repoFolders.overrides
            if asJSON { return json(overrides) }
            guard !overrides.isEmpty else { return "No repository overrides." }
            let home = env["HOME"] ?? NSHomeDirectory()
            return overrides.sorted { $0.key < $1.key }.map { repo, dir in
                "\(repo)  \(dir)" + ((try? LaunchPlanner.directory(dir, home: home)) == nil ? "  (missing)" : "")
            }.joined(separator: "\n")
        case ("set", 3):
            let repo = try key(positional[1]), dir = try folder(positional[2])
            store.mutate { $0.repoFolders.overrides[repo] = dir }
            return "\(repo) → \(dir)."
        case ("rm", 2):
            let repo = try key(positional[1])
            guard store.mutate({ $0.repoFolders.overrides.removeValue(forKey: repo) != nil }) else { throw Failure(message: "No override for \(repo)") }
            return "Removed the override for \(repo)."
        case ("--help", _), ("help", _): throw HelpRequested()
        default: throw Usage(message: "expected repos list, repos set <owner/repo> <dir> or repos rm <owner/repo>")
        }
    }

    // MARK: session / handler

    private static func session(_ command: String, _ args: [String], store: AutomationStore, env: [String: String], now: Date,
                                state: () -> TrackedState) throws -> (output: String, error: String, status: Int32) {
        let options: Set<String> = switch command {
        case "set": ["pr", "session", "agent", "cwd", "by"]
        case "find": ["pr", "days", "exclude", "by"]
        default: ["pr"]
        }
        let (values, flags, positional) = try parse(args, options: options,
                                                    flags: command == "set" ? ["quiet", "json"] : command == "find" ? ["link", "json"] : command == "rm" ? [] : ["json"])
        try noArguments(positional)
        func required() throws -> PRRef {
            guard let pr = try ref(values["pr"]) else { throw Usage(message: "--pr is required") }
            return pr
        }
        switch command {
        case "set":
            let pr = try required()
            guard let id = values["session"] else { throw Usage(message: "--session is required") }
            guard !id.isEmpty else { throw Usage(message: "--session is empty ($CLAUDE_CODE_SESSION_ID is set only inside Claude Code)") }
            guard LaunchPlanner.isValidSessionID(id), id != Automation.linkedSession else {
                throw Usage(message: "--session may only contain letters, digits, '.', '_' and '-' (at most 128)")
            }
            let agent: AgentKind = try values["agent"].map { try choice($0, "--agent") } ?? .claude
            let found = values["cwd"] == nil && agent == .claude ? ClaudeSessions.launchDirectory(sessionID: id, env: env) : nil
            let cwd = try directory(values["cwd"] ?? found ?? env["PWD"] ?? FileManager.default.currentDirectoryPath, hook: true, env: env)
            let link = SessionLink(pr: pr, agent: agent, sessionID: id, cwd: cwd, setAt: now, source: "cli",
                                   by: PromptTemplate.clean(values["by"] ?? env["CLAUDE_CODE_SESSION_ID"] ?? "", max: 64))
            store.mutate { $0.setLink(link) }
            if flags.contains("quiet") { return ("", "", 0) }
            return (flags.contains("json") ? try encode(link) : "Linked \(pr.repo) #\(pr.number) → \(agent.rawValue) \(id.prefix(8))… in \(cwd).", "", 0)
        case "show":
            let pr = try required()
            guard let link = store.load().link(for: pr.repo, number: pr.number) else { throw Failure(message: "No session linked to \(pr.repo) #\(pr.number)") }
            if flags.contains("json") { return (try encode(link), "", 0) }
            return (table([("repo", link.pr.repo), ("number", "\(link.pr.number)"), ("agent", link.agent.rawValue), ("session", link.sessionID),
                           ("cwd", link.cwd), ("set", link.setAt.ISO8601Format()), ("source", link.source), ("by", link.by)]).joined(separator: "\n"), "", 0)
        case "list":
            let links = store.load().sessions.sorted { $0.setAt > $1.setAt }
            if flags.contains("json") { return (try encode(links), "", 0) }
            guard !links.isEmpty else { return ("No linked sessions.", "", 0) }
            let home = env["HOME"] ?? NSHomeDirectory()
            return (links.map { link in
                ["\(link.pr.repo) #\(link.pr.number)", link.agent.rawValue, "\(link.sessionID.prefix(8))…", tilde(link.cwd, home: home), stamp(link.setAt), link.source]
                    .joined(separator: "  ")
            }.joined(separator: "\n"), "", 0)
        case "rm":
            let pr = try required()
            let removed = store.mutate { file -> Bool in
                let before = file.sessions.count
                file.sessions.removeAll { $0.pr.matches(pr.repo, pr.number) }
                return file.sessions.count < before
            }
            guard removed else { throw Failure(message: "No session linked to \(pr.repo) #\(pr.number)") }
            return ("Unlinked \(pr.repo) #\(pr.number).", "", 0)
        case "find":
            return try find(required(), raw: values["pr"] ?? "", values: values, link: flags.contains("link"), json: flags.contains("json"),
                            store: store, env: env, now: now, state: state())
        case "--help", "help": throw HelpRequested()
        default: throw Usage(message: "unknown session command \(command)")
        }
    }

    /// `session find`: `SessionFinder` on the pull request (its tracked URL and branch, else the URL given or built), then `--link`.
    private static func find(_ target: PRRef, raw: String, values: [String: String], link: Bool, json asJSON: Bool, store: AutomationStore,
                             env: [String: String], now: Date, state: TrackedState) throws -> (output: String, error: String, status: Int32) {
        let days = try values["days"].map { raw in
            guard let n = Int(raw), (1...365).contains(n) else { throw Usage(message: "--days must be 1 to 365") }
            return n
        } ?? 60
        let tracked = Self.tracked(target, in: state)
        let pr = PRRef(repo: tracked?.repo ?? target.repo, number: target.number)
        let url = tracked?.url ?? pageURL(raw) ?? URL(string: "https://github.com/\(pr.repo)/pull/\(pr.number)")!
        let exclude = (values["exclude"] ?? env["CLAUDE_CODE_SESSION_ID"]).flatMap { $0.isEmpty ? nil : $0 }
        let started = Date()
        let found = SessionFinder.find(url: url, repo: pr.repo, number: pr.number, headRef: tracked?.isIssue == false ? tracked?.headRef : nil, env: env,
                                       exclude: exclude, days: days, now: now)
        let seconds = Date().timeIntervalSince(started)
        // A plain mention may be a session that only listed the pull request: shown, never linked by itself.
        let best = found.candidates.first.flatMap { $0.tier == "mention" ? nil : $0 }
        let made = link ? best?.link(pr: pr, now: now, by: PromptTemplate.clean(values["by"] ?? env["CLAUDE_CODE_SESSION_ID"] ?? "", max: 64)) : nil
        if let made { store.mutate { $0.setLink(made) } }
        let linked = made != nil, status: Int32 = found.candidates.isEmpty ? 1 : 0
        if asJSON {
            struct Result: Encodable { var candidates: [SessionCandidate], scanned: Int, truncated: Bool, linked: Bool }
            return (try encode(Result(candidates: found.candidates, scanned: found.scanned, truncated: found.truncated, linked: linked)), "", status)
        }
        guard !found.candidates.isEmpty else {
            return ("No earlier session found for \(pr.repo) #\(pr.number) (scanned \(found.scanned) transcripts\(found.truncated ? ", stopped at the limit" : "")).", "", 1)
        }
        let home = env["HOME"] ?? NSHomeDirectory()
        var lines = found.candidates.flatMap { c -> [String] in
            let notes = [c.tier, ago(now.timeIntervalSince(c.modifiedAt))] + (c.mayBeOpen ? ["may be open"] : [])
            let title = c.title.isEmpty ? "" : " \"\(c.title)\""
            return ["Found \(c.agent.rawValue) \(c.sessionID.prefix(8))… (\(notes.joined(separator: ", ")))\(title) launched in \(tilde(c.launchDir, home: home)), last in \(tilde(c.workDir, home: home))",
                    "  \(c.transcript)"]
        }
        lines.append(String(format: "Scanned %d transcripts in %.1f s%@.", found.scanned, seconds, found.truncated ? ", stopped at the limit" : ""))
        if linked {
            lines += ["Linked.", "Continue it: pullping session resume --pr \(url.absoluteString)"]
        } else if link, best != nil {
            lines.append("Not linked: its folders are gone.")
        } else if link, let first = found.candidates.first {
            lines.append("Not linked: it only mentions the pull request. If it is the one: pullping session set --pr \(url.absoluteString) --session \(first.sessionID) --agent \(first.agent.rawValue)")
        }
        return (lines.joined(separator: "\n"), "", status)
    }

    /// The tracked pull request `ref` names (any case of the repository); nil when PullPing doesn't track it.
    static func tracked(_ ref: PRRef, in state: TrackedState) -> TrackedPR? { state.prs.values.first { ref.matches($0.repo, $0.number) } }

    /// `https://host/owner/repo/pull/12/files` → `https://host/owner/repo/pull/12`; nil when `text` is not such a URL.
    private static func pageURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)), let scheme = url.scheme, let host = url.host else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count >= 4 else { return nil }
        return URL(string: "\(scheme)://\(host)/\(parts[0...3].joined(separator: "/"))")
    }

    /// "40 s ago", "12 min ago", "2 h ago", "3 d ago".
    static func ago(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s < 60 ? "\(s) s ago" : s < 3600 ? "\(s / 60) min ago" : s < 86_400 ? "\(s / 3600) h ago" : "\(s / 86_400) d ago"
    }

    /// `~/…` for paths under `home`.
    static func tilde(_ path: String, home: String) -> String {
        path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// `set` takes the handler editor's options only (a usage error for the others) and checks them like a rule's.
    private static func handler(_ command: String, _ args: [String], store: AutomationStore, env: [String: String], now: Date,
                                installed: (Launcher) -> Bool) throws -> String {
        let options: Set<String> = command == "set" ? ["on", "agent", "command", "launcher", "custom-command", "cwd", "prompt", "prompt-file", "find-sessions", "by"] : []
        let parsed = try parse(args, options: options, flags: ["json"])
        var values = parsed.values
        try noArguments(parsed.positional)
        let saved: Automation, find: Bool
        switch command {
        case "show": (saved, find) = { ($0.handler, $0.findSessions) }(store.load())
        case "set", "on", "off":
            try readPromptFile(&values, env: env)
            if command == "set" && values.isEmpty { throw Usage(message: "set needs an option to change") }
            let findSessions = try values.removeValue(forKey: "find-sessions").map { raw in
                guard ["on", "off"].contains(raw) else { throw Usage(message: "--find-sessions must be on or off") }
                return raw == "on"
            }
            let toggle: Set<String> = command == "set" ? [] : [command == "on" ? "enable" : "disable"]
            (saved, find) = try store.mutate { file in
                Result {
                    var h = file.handler
                    // on a copy: a failed check changes nothing; only --find-sessions leaves the handler and its provenance alone
                    if !values.isEmpty || !toggle.isEmpty { try apply(values, toggle, to: &h, hook: false, env: env, now: now, installed: installed) }
                    file.handler = h
                    if let findSessions { file.findSessions = findSessions }
                    return (h, file.findSessions)
                }
            }.get()
        case "--help", "help": throw HelpRequested()
        default: throw Usage(message: "unknown handler command \(command)")
        }
        if parsed.flags.contains("json") { return try encode(saved) }
        return command == "show" ? show(saved, extra: [("find sessions", find ? "on" : "off")]) : handlerLine(saved) + (find ? " · find sessions on" : "")
    }

    /// "Handle with Agent: on · claude in Terminal · ~/Code/{repo_name}"
    public static func handlerLine(_ h: Automation) -> String {
        "\(h.name): \(h.enabled ? "on" : "off") · \(agentWord(h)) in \(h.launcher.title) · \(h.workingDirectory)"
    }

    private static func shortID(_ a: Automation) -> String { String(a.id.uuidString.lowercased().prefix(8)) }
    public static func agentWord(_ a: Automation) -> String { a.agentCommand.isEmpty ? a.agent.rawValue : a.agentCommand }
    public static func sessionWord(_ a: Automation) -> String {
        a.usesLinkedSession ? "linked session" : a.sessionID.map { "resume \($0.prefix(4))…" } ?? "new session"
    }
}
