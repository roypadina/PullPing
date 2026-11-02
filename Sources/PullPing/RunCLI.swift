import Foundation
import PullPingCore

/// `pullping run` and `pullping session resume`: one manual run in this process, with the Run Automation menu's (or Resume
/// Session's) gates and ledger, whether or not the app runs. `args` include the command.
enum RunCLI {
    static func run(_ args: [String], env: [String: String]) async -> (output: String, error: String, status: Int32) {
        let store = AutomationStore(url: AutomationStore.defaultURL, repair: false), now = Date()
        let handoff = args.first == "session"
        let request: RunRequest
        do {
            request = handoff ? try AutomationCLI.prepareHandlerRun(Array(args.dropFirst(2)), store: store, state: trackedState(env), env: env, now: now)
                : try AutomationCLI.prepareRun(Array(args.dropFirst()), store: store, state: trackedState(env), env: env, now: now)
        } catch {
            return AutomationCLI.outcome(error, group: handoff ? "session" : "run")
        }
        let runID = UUID().uuidString
        do {
            let plan = try LaunchPlanner.plan(request.automation, pr: request.pr, event: nil, account: login(request.pr.accountID), runID: runID,
                                              runsDir: AgentLauncher.runsDir, home: NSHomeDirectory(), newSessionID: request.newSessionID,
                                              folders: request.folders, hints: request.hints, installed: { $0.isInstalled })
            if request.dryRun { return (AutomationCLI.dryRun(plan, json: request.json), "", 0) }
            return AutomationCLI.finishRun(request, runID: runID, error: await AgentLauncher.launch(plan), store: store, now: now, cwd: plan.cwd)
        } catch {
            if request.dryRun { return ("", "pullping: \(error.localizedDescription)", 1) }
            return AutomationCLI.finishRun(request, runID: runID, error: error.localizedDescription, store: store, now: now)
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
