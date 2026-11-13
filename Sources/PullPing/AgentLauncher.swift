import AppKit
import os
import PullPingCore

extension Launcher {
    /// The Open in picker, `pullping launchers` and every launch: is the launcher's app installed (Custom: always)?
    var isInstalled: Bool { bundleIDs.isEmpty || bundleIDs.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil } }
}

/// Writes a run's prompt (0600) and script (0700) under `runs/`, then runs the launch line and stops: PullPing never talks
/// to the agent. The prompt text never reaches a shell line or the log.
enum AgentLauncher {
    static let log = Logger(subsystem: "com.padina.pullping", category: "automation")
    static var runsDir: URL { AutomationStore.defaultURL.deletingLastPathComponent().appendingPathComponent("runs") }
    private static let keep: TimeInterval = 7 * 86_400
    private static let timeout: TimeInterval = 10

    /// nil = launched; else the error text (exit status and stderr tail, or the timeout).
    static func launch(_ plan: LaunchPlan) async -> String? {
        let error = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: run(plan)) }
        }
        if let error {
            log.error("launch failed: \(plan.title, privacy: .public): \(error, privacy: .public)")
        } else {
            log.info("launched \(plan.title, privacy: .public)")
        }
        return error
    }

    private static func run(_ plan: LaunchPlan) -> String? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: runsDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            removeOldRuns()
            try write(plan.promptText, to: plan.promptPath, mode: 0o600)
            try write(plan.script, to: plan.scriptPath, mode: 0o700)
        } catch {
            return "Couldn't write the run files: \(error.localizedDescription)"
        }
        // stderr to a file, not a pipe: a launcher that leaves a child holding the pipe open would block the read.
        let stderrPath = plan.scriptPath + ".stderr"
        guard fm.createFile(atPath: stderrPath, contents: nil), let stderr = FileHandle(forWritingAtPath: stderrPath) else {
            return "Couldn't write the run files"
        }
        defer { try? stderr.close(); try? fm.removeItem(atPath: stderrPath) }
        var environment = LaunchPlanner.launchEnvironment(ProcessInfo.processInfo.environment)
        if plan.needsGhostexProject {
            guard let projects = output(of: "ghostex projects --json", environment: environment),
                  let project = GhostexProjects.pick(projects, cwd: plan.cwd) else {
                return "Ghostex listed no project; open a folder in Ghostex once, then try again"
            }
            environment["PULLPING_GHOSTEX_PROJECT"] = project
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", plan.launchLine]  // login shell: Homebrew and ~/.local/bin on PATH
        process.currentDirectoryURL = URL(fileURLWithPath: plan.cwd)
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return "Couldn't start the launcher: \(error.localizedDescription)" }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return "The launcher did not finish within \(Int(timeout)) seconds"
        }
        guard process.terminationStatus != 0 else { return nil }
        let tail = ((try? String(contentsOfFile: stderrPath, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).suffix(300)
        return "The launcher exited with status \(process.terminationStatus)" + (tail.isEmpty ? "" : ": \(tail)")
    }

    /// stdout of a short `zsh -lc` line (same timeout as a launch), via a file like stderr above; nil on failure.
    private static func output(of line: String, environment: [String: String]) -> Data? {
        let path = runsDir.appendingPathComponent(UUID().uuidString + ".out").path
        guard FileManager.default.createFile(atPath: path, contents: nil), let out = FileHandle(forWritingAtPath: path) else { return nil }
        defer { try? out.close(); try? FileManager.default.removeItem(atPath: path) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", line]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        guard (try? process.run()) != nil else { return nil }
        if done.wait(timeout: .now() + timeout) == .timedOut { process.terminate(); return nil }
        return process.terminationStatus == 0 ? FileManager.default.contents(atPath: path) : nil
    }

    private static func write(_ text: String, to path: String, mode: Int) throws {
        guard FileManager.default.createFile(atPath: path, contents: Data(text.utf8), attributes: [.posixPermissions: mode]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Prompts and scripts older than 7 days.
    private static func removeOldRuns() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-keep)
        for url in (try? fm.contentsOfDirectory(at: runsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }
}
