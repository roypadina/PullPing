import Foundation
import PullPingCore

let environment = ProcessInfo.processInfo.environment
if environment["PULLPING_SMOKE"] == "1" {
    Task {
        exit(await SmokeRunner.run(token: environment["PULLPING_TOKEN"] ?? "", statePath: environment["PULLPING_STATE"]))
    }
    dispatchMain()
} else {
    PullPingApp.main()
}
