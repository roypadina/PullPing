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

    /// `error` nil = launched (or, resuming in Ghostex, the running session focused); else the exit status and stderr tail, or
    /// the timeout. `note` goes after the launcher's name in the run detail: " (focused running session)", " (not focused)".
    static func launch(_ plan: LaunchPlan) async -> (error: String?, note: String) {
        let result = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: run(plan)) }
        }
        if let error = result.error {
            log.error("launch failed: \(plan.title, privacy: .public): \(error, privacy: .public)")
        } else {
            log.info("launched \(plan.title, privacy: .public)\(result.note, privacy: .public)")
        }
        return result
    }

    private static func run(_ plan: LaunchPlan) -> (error: String?, note: String) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: runsDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return ("Couldn't write the run files: \(error.localizedDescription)", "")
        }
        var environment = LaunchPlanner.launchEnvironment(ProcessInfo.processInfo.environment)
        // A resume whose session already runs in Ghostex: focus it and type the draft line, no second copy on one transcript.
        if let focus = plan.focusRunning, ghostex(focus, environment: environment).map(GhostexSessions.focused) == true {
            return draft(plan, environment: environment)
        }
        do {
            removeOldRuns()
            if !plan.promptPath.isEmpty { try write(plan.promptText, to: plan.promptPath, mode: 0o600) }
            try write(plan.script, to: plan.scriptPath, mode: 0o700)
        } catch {
            return ("Couldn't write the run files: \(error.localizedDescription)", "")
        }
        // stderr (and Ghostex's stdout) to a file, not a pipe: a launcher that leaves a child holding the pipe open would block the read.
        let stderrPath = plan.scriptPath + ".stderr", stdoutPath = plan.scriptPath + ".stdout"
        guard fm.createFile(atPath: stderrPath, contents: nil), let stderr = FileHandle(forWritingAtPath: stderrPath),
              fm.createFile(atPath: stdoutPath, contents: nil), let stdout = FileHandle(forWritingAtPath: stdoutPath) else {
            return ("Couldn't write the run files", "")
        }
        defer {
            try? stderr.close(); try? fm.removeItem(atPath: stderrPath)
            try? stdout.close(); try? fm.removeItem(atPath: stdoutPath)
        }
        if plan.needsGhostexProject {
            guard let projects = ghostex(["projects", "--json"], environment: environment),
                  let project = GhostexProjects.pick(projects, cwd: plan.cwd) else {
                return ("Ghostex listed no project; open a folder in Ghostex once, then try again", "")
            }
            environment["PULLPING_GHOSTEX_PROJECT"] = project
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", plan.launchLine]  // login shell: Homebrew and ~/.local/bin on PATH
        process.currentDirectoryURL = URL(fileURLWithPath: plan.cwd)
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = plan.needsGhostexProject ? stdout : FileHandle.nullDevice
        process.standardError = stderr
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return ("Couldn't start the launcher: \(error.localizedDescription)", "") }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return ("The launcher did not finish within \(Int(timeout)) seconds", "")
        }
        guard process.terminationStatus == 0 else {
            let tail = ((try? String(contentsOfFile: stderrPath, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).suffix(300)
            return ("The launcher exited with status \(process.terminationStatus)" + (tail.isEmpty ? "" : ": \(tail)"), "")
        }
        // Ghostex starts the new session off-screen: bring it forward by the ref create-session printed. A miss is no failure.
        guard plan.needsGhostexProject else { return (nil, "") }
        let ref = fm.contents(atPath: stdoutPath).flatMap(GhostexSessions.globalRef)
        return (nil, ref.flatMap { ghostex(GhostexSessions.focus(globalRef: $0), environment: environment) } != nil ? "" : " (not focused)")
    }

    /// The running session was focused: writes the prompt (0600) and types the draft line into it, without Enter. Resume
    /// Without Prompt (no prompt path): nothing more.
    static func draft(_ plan: LaunchPlan, environment: [String: String] = LaunchPlanner.launchEnvironment(ProcessInfo.processInfo.environment))
        -> (error: String?, note: String) {
        guard !plan.promptPath.isEmpty else { return (nil, GhostexSessions.focusedNote) }
        do {
            try FileManager.default.createDirectory(at: runsDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            removeOldRuns()
            try write(plan.promptText, to: plan.promptPath, mode: 0o600)
        } catch {
            return ("Couldn't write the run files: \(error.localizedDescription)", "")
        }
        let typed = plan.draftLine.flatMap { ghostex($0, environment: environment) } != nil
        return (nil, GhostexSessions.focusedNote + (typed ? "" : " (prompt not typed)"))
    }

    /// `pullping session resume` on a session open in Ghostex: focus it (no draft yet); false = not running there or no Ghostex.
    static func focusRunning(sessionID: String, agent: AgentKind) -> Bool {
        ghostex(GhostexSessions.focusRunning(sessionID: sessionID, agent: agent),
                environment: LaunchPlanner.launchEnvironment(ProcessInfo.processInfo.environment)).map(GhostexSessions.focused) == true
    }

    /// Does an automatic run's session run in Ghostex now? Looks only (`ghostex sessions`), never focuses; false without Ghostex.
    static func runsInGhostex(sessionID: String) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let list = ghostex(GhostexSessions.sessions, environment: LaunchPlanner.launchEnvironment(ProcessInfo.processInfo.environment))
                continuation.resume(returning: list.map { GhostexSessions.running($0, sessionID: sessionID) } ?? false)
            }
        }
    }

    /// stdout of `ghostex <args>` in a login shell (same timeout as a launch), via a file like stderr above; nil on failure.
    private static func ghostex(_ args: [String], environment: [String: String]) -> Data? {
        try? FileManager.default.createDirectory(at: runsDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = runsDir.appendingPathComponent(UUID().uuidString + ".out").path
        guard FileManager.default.createFile(atPath: path, contents: nil), let out = FileHandle(forWritingAtPath: path) else { return nil }
        defer { try? out.close(); try? FileManager.default.removeItem(atPath: path) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = GhostexSessions.shell(args)
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
