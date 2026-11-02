import Foundation
import PullPingCore

let environment = ProcessInfo.processInfo.environment
let arguments = Array(CommandLine.arguments.dropFirst())

func finish(_ result: (output: String, error: String, status: Int32)) -> Never {
    if !result.output.isEmpty { print(result.output) }
    if !result.error.isEmpty { FileHandle.standardError.write(Data((result.error + "\n").utf8)) }
    exit(result.status)
}

if AutomationCLI.isCLIInvocation(arguments, program: CommandLine.arguments[0]) {
    // `pullping …` (the cask symlinks this binary as `pullping`): no app, just the shared automations file.
    if arguments.first == "run" || arguments.starts(with: ["session", "resume"]) {
        Task { finish(await RunCLI.run(arguments, env: environment)) }
        dispatchMain()
    }
    finish(AutomationCLI.run(arguments, store: AutomationStore(url: AutomationStore.defaultURL, repair: false), env: environment, now: Date(),
                             installed: { $0.isInstalled }, state: { RunCLI.trackedState(environment) }))
} else if environment["PULLPING_SMOKE"] == "1" {
    Task {
        exit(await SmokeRunner.run(token: environment["PULLPING_TOKEN"] ?? "", statePath: environment["PULLPING_STATE"]))
    }
    dispatchMain()
} else {
    PullPingApp.main()
}
