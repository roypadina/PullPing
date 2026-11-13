import Foundation
import os
import PullPingCore

/// One background run's process. Foundation starts it in its own process group, so stopping it (Cancel, the 10-minute
/// timeout, quitting PullPing) signals the shell, the agent and anything they started: TERM, then KILL after 5 seconds
/// (TERM only at quit: PullPing is gone before the KILL).
final class BackgroundJob: @unchecked Sendable {
    let runID: String
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var reason: BackgroundStatus?

    init(runID: String) { self.runID = runID }

    /// Why it was stopped (cancelled, timed out, interrupted); nil while it runs on its own.
    var stopped: BackgroundStatus? { lock.withLock { reason } }

    /// The first reason wins; a process not started yet is stopped as soon as it starts.
    func stop(_ why: BackgroundStatus) {
        let pid: pid_t = lock.withLock {
            if reason == nil { reason = why }
            return self.pid
        }
        guard pid > 0 else { return }
        killpg(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [self] in
            if lock.withLock({ self.pid == pid }) { killpg(pid, SIGKILL) }  // still the same group: it ignored TERM
        }
    }

    fileprivate func started(_ pid: pid_t) {
        let pending: BackgroundStatus? = lock.withLock { self.pid = pid; return reason }
        if let pending { stop(pending) }
    }

    fileprivate func exited() { lock.withLock { pid = 0 } }
}

/// Runs one background run: fetches the context with the account's token (the agent has no network), writes the run folder
/// (0700, files 0600, the command 0700), runs the agent headless (`BackgroundPlanner.command`: read-only tools, no shell, no
/// MCP, never a permission-bypass flag), then checks its answer (`BackgroundPlanner.output`) and writes the draft. It never
/// talks to GitHub after the fetch: posting is the draft window's, on a click.
enum BackgroundRunner {
    static let log = Logger(subsystem: "com.padina.pullping", category: "background")

    struct Input: Sendable {
        var runID: String
        var action: BackgroundAction
        var pr: TrackedPR
        var login: String
        var token: String
        var file: AutomationFile
        var rule: Automation?
        var index: RepoIndex
        var runsDir: URL
    }

    struct Outcome: Sendable {
        var status: BackgroundStatus
        var error: String?
        var draft: BackgroundDraft?
        var sessionID: String?
        var head: String?
    }

    static func run(_ input: Input, job: BackgroundJob) async -> Outcome {
        let fm = FileManager.default
        let dir = input.runsDir.appendingPathComponent(input.runID)
        func failed(_ message: String, session: String? = nil, head: String? = nil) -> Outcome {
            log.error("background run \(input.runID, privacy: .public) failed: \(message, privacy: .public)")
            return Outcome(status: .failed, error: message, sessionID: session, head: head)
        }
        // The id names a folder: a hand-edited record with `../` must not create one outside `runs/`.
        guard BackgroundDraft.url(runID: input.runID, runsDir: input.runsDir) != nil else { return failed("Not a plain run id (an edited record)") }
        do {
            try fm.createDirectory(at: input.runsDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            AgentLauncher.removeOldRuns()  // drafts live 7 days, like every run's files
            try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            return failed("Couldn't create the run folder: \(error.localizedDescription)")
        }
        // 1. The input, fetched by PullPing.
        let client = GitHubClient(transport: URLSessionTransport(), token: input.token)
        let context: BackgroundContext, diff: String, diffCut: BackgroundDraft.Cut?
        do {
            context = try await client.backgroundContext(prID: input.pr.id)
            (diff, diffCut) = try await client.diff(repo: input.pr.repo, number: input.pr.number)
        } catch {
            return failed("Couldn't fetch the pull request: \((error as? AccountStatus)?.word ?? error.localizedDescription)")
        }
        if let stop = job.stopped { return Outcome(status: stop, error: stop.word.capitalized, head: context.head) }
        // 2. The run folder.
        var pr = input.pr
        pr.headOID = context.head
        let plan: BackgroundPlan
        do {
            plan = try BackgroundPlanner.plan(input.action, pr: pr, file: input.file, rule: input.rule, runDir: dir, sessionID: UUID().uuidString.lowercased(),
                                              home: NSHomeDirectory(), index: input.index)
            for (name, text) in [("diff.patch", diff), ("discussion.md", context.discussion), ("prompt.md", plan.prompt), ("schema.json", BackgroundPlanner.schema)] {
                try write(text, to: dir.appendingPathComponent(name).path, mode: 0o600)
            }
            try write(plan.script, to: dir.appendingPathComponent("command").path, mode: 0o700)
        } catch {
            return failed("Couldn't plan the run: \(error.localizedDescription)", head: context.head)
        }
        // 3. The agent, headless.
        let exit = await execute(dir.appendingPathComponent("command").path, cwd: plan.cwd, log: dir.appendingPathComponent("shell.log").path, job: job)
        if let stop = job.stopped {
            return Outcome(status: stop, error: stop == .timedOut ? "Timed out after \(Int(BackgroundSettings.timeout / 60)) minutes" : stop.word.capitalized,
                           sessionID: plan.sessionID, head: context.head)
        }
        let agent = (input.rule ?? input.file.handler).agent
        guard exit == 0 else {
            let tail = [dir.appendingPathComponent("stderr.txt"), dir.appendingPathComponent("shell.log")].lazy
                .compactMap { try? String(contentsOf: $0, encoding: .utf8) }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
            return failed((exit.map { "The agent exited with status \($0)" } ?? "The agent didn't start") + (tail.isEmpty ? "" : ": " + PromptTemplate.clean(String(tail.suffix(300)), max: 300)),
                          session: plan.sessionID, head: context.head)
        }
        // 4. Its answer: untrusted input, checked before anything shows it.
        let out = fm.contents(atPath: dir.appendingPathComponent(agent == .claude ? "out.json" : "out.jsonl").path) ?? Data()
        let output: BackgroundPlanner.Output
        do {
            output = try BackgroundPlanner.output(input.action, agent: agent, out: out, last: fm.contents(atPath: dir.appendingPathComponent("last.json").path),
                                                  sessionID: plan.sessionID, diff: diff)
        } catch {
            return failed(error.localizedDescription, session: plan.sessionID ?? BackgroundPlanner.codexThread(out), head: context.head)
        }
        let draft = BackgroundDraft(runID: input.runID, action: input.action, prID: pr.id, repo: pr.repo, number: pr.number, url: pr.url,
                                    title: PromptTemplate.clean(pr.title, max: 200), accountID: pr.accountID, login: input.login, head: context.head,
                                    agent: agent, sessionID: output.sessionID, cwd: plan.cwd, notCloned: plan.notCloned, createdAt: Date(),
                                    summary: output.summary, verdict: output.verdict, body: output.body, diffCut: diffCut, discussionCut: context.discussionCut)
        do {
            try write(String(decoding: try AutomationStore.encoder.encode(draft), as: UTF8.self), to: dir.appendingPathComponent("draft.json").path, mode: 0o600)
        } catch {
            return failed("Couldn't save the draft: \(error.localizedDescription)", session: output.sessionID, head: context.head)
        }
        return Outcome(status: .done, draft: draft, sessionID: output.sessionID, head: context.head)
    }

    /// `/bin/zsh -il <command>` in `cwd` (the user's PATH and wrapper functions apply), stdin closed, the shell's own output to
    /// `log`; stopped after `BackgroundSettings.timeout`. The exit status, nil when it didn't start.
    private static func execute(_ script: String, cwd: String, log: String, job: BackgroundJob) async -> Int32? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                guard FileManager.default.createFile(atPath: log, contents: nil, attributes: [.posixPermissions: 0o600]),
                      let output = FileHandle(forWritingAtPath: log) else { return continuation.resume(returning: nil) }
                defer { try? output.close() }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-il", script]
                process.currentDirectoryURL = URL(fileURLWithPath: cwd)
                process.environment = LaunchPlanner.launchEnvironment(ProcessInfo.processInfo.environment)
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = output
                process.standardError = output
                let done = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in done.signal() }
                do { try process.run() } catch { return continuation.resume(returning: nil) }
                job.started(process.processIdentifier)
                if done.wait(timeout: .now() + BackgroundSettings.timeout) == .timedOut {
                    job.stop(.timedOut)
                    done.wait()
                }
                job.exited()
                continuation.resume(returning: process.terminationStatus)
            }
        }
    }

    private static func write(_ text: String, to path: String, mode: Int) throws {
        guard FileManager.default.createFile(atPath: path, contents: Data(text.utf8), attributes: [.posixPermissions: mode]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
