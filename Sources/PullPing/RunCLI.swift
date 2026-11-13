import Foundation
import PullPingCore

/// `pullping run`, `pullping session resume` and `pullping handler run --dry-run`: one manual run in this process, with the
/// Run Automation menu's (or Resume Session's) gates and ledger, whether or not the app runs. `args` include the command.
enum RunCLI {
    static func run(_ args: [String], env: [String: String]) async -> (output: String, error: String, status: Int32) {
        let store = AutomationStore(url: AutomationStore.defaultURL, repair: false), now = Date()
        let handoff = args.first == "session", handler = args.first == "handler"
        var request: RunRequest
        do {
            request = handoff ? try AutomationCLI.prepareHandlerRun(Array(args.dropFirst(2)), store: store, state: trackedState(env), env: env, now: now,
                                                                     focusRunning: { AgentLauncher.focusRunning(sessionID: $0.sessionID, agent: $0.agent) })
                : handler ? try AutomationCLI.prepareHandlerDryRun(Array(args.dropFirst(2)), store: store, state: trackedState(env), env: env, now: now)
                : try AutomationCLI.prepareRun(Array(args.dropFirst()), store: store, state: trackedState(env), env: env, now: now)
        } catch {
            return AutomationCLI.outcome(error, group: args.first ?? "run")
        }
        let runID = UUID().uuidString
        // Recorded like the app's runs, then logged in the activity log (the app reads it back).
        func finish(_ error: String?, cwd: String? = nil) -> (output: String, error: String, status: Int32) {
            let result = AutomationCLI.finishRun(request, runID: runID, error: error, store: store, now: now, cwd: cwd)
            ActivityLog.write([ActivityEntry(run: request.automation, pr: request.pr, account: login(request.pr.accountID), event: nil, error: error, at: now,
                                             scenario: request.scenario, prompt: request.prompt)],
                              appendingTo: ActivityLog.defaultURL(env))
            return result
        }
        do {
            let plan = try LaunchPlanner.plan(request.automation, pr: request.pr, event: nil, account: login(request.pr.accountID), runID: runID,
                                              runsDir: AgentLauncher.runsDir, home: NSHomeDirectory(), newSessionID: request.newSessionID,
                                              folders: request.folders, hints: request.hints, installed: { $0.isInstalled }, target: request.target,
                                              prompt: request.prompt, scenario: request.scenario, task: request.task)
            if request.dryRun { return (AutomationCLI.dryRun(plan, json: request.json, request: request), "", 0) }
            let launched = request.focused ? AgentLauncher.draft(plan) : await AgentLauncher.launch(plan)
            request.note += launched.note
            return finish(launched.error, cwd: plan.cwd)
        } catch {
            if request.dryRun { return ("", "pullping: \(error.localizedDescription)", 1) }
            return finish(error.localizedDescription)
        }
    }

    /// Read only: the CLI never moves a state file it can't read aside (the app does). `PULLPING_STATE` as in smoke mode.
    static func trackedState(_ env: [String: String]) -> TrackedState {
        let url = env["PULLPING_STATE"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? StateStore.defaultURL
        return (try? Data(contentsOf: url)).flatMap { try? StateStore.decoder.decode(TrackedState.self, from: $0) } ?? TrackedState()
    }

    /// `{account}`: read from the app's domain by name, since through the `pullping` symlink `Bundle.main` has no identifier. Unreadable = "".
    private static func login(_ accountID: UUID) -> String {
        let data = CFPreferencesCopyAppValue(DefaultsKey.accounts as CFString, "com.padina.pullping" as CFString) as? Data
        return data.flatMap { try? JSONDecoder().decode([Account].self, from: $0) }?.first { $0.id == accountID }?.login ?? ""
    }
}

/// `pullping --version` and `setup status`: Bundle.main's, else the Info.plist beside the real executable (through the cask's
/// `pullping` symlink Bundle.main may be the link's folder); "" in a development build.
enum AppVersion {
    static var current: String {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String { return version }
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return "" }
        let plist = exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        return NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String ?? ""
    }
}
