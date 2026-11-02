import Foundation

/// A local agent session that worked on a pull request (`SessionFinder.find`).
public struct SessionCandidate: Codable, Equatable, Sendable {
    public var agent: AgentKind
    public var sessionID: String
    public var transcript: String
    /// The first and the last working folder in the transcript.
    public var launchDir: String
    public var workDir: String
    /// Claude's own title (`aiTitle`), cleaned, ≤ 80; "" when none.
    public var title: String
    /// The branch Claude was launched on; "" when unknown.
    public var branch: String
    /// "pr-link" | "mention" | "branch", best first.
    public var tier: String
    /// The last activity: the transcript's last record timestamp, else its modification date.
    public var modifiedAt: Date
    /// The transcript changed less than `SessionFinder.openWithin` ago: likely open in a terminal.
    public var mayBeOpen: Bool
}

/// "Which local agent session last worked on this pull request?": a byte search over Claude Code transcripts
/// (`<config>/projects/*/<id>.jsonl`, `$CLAUDE_CONFIG_DIR` and `~/.claude`, one `projects/` once) and Codex rollouts
/// (`$CODEX_HOME|~/.codex/sessions/**`), newest first. Reads only; nothing leaves the Mac.
public enum SessionFinder {
    /// Bytes and time bound a search; `maxFiles` is only a rail.
    public static let maxFiles = 5000, maxBytes = 1_500_000_000, maxSeconds = 10.0, openWithin: TimeInterval = 120
    /// Head branches too common to say anything about a session.
    static let commonBranches: Set<String> = ["main", "master", "dev", "develop", "HEAD"]
    static let tiers = ["pr-link", "mention", "branch"]

    /// At most 3 candidates, best tier first, newest first within one. Tiers: A `"prUrl":"<url>"` (Claude's `pr-link` record),
    /// B the URL or `owner/repo#n` (not followed by a digit), C `"gitBranch":"<headRef>"` plus the repository named in the file
    /// (only for an uncommon branch). Stops at the first tier-A file, else after `days`, 1.5 GB, 10 s or `cap` files (`truncated`).
    /// `exclude`: the caller's own session.
    public static func find(url: URL, repo: String, number: Int, headRef: String?, env: [String: String], exclude: String?,
                            days: Int = 60, now: Date, cap: Int = maxFiles) -> (candidates: [SessionCandidate], scanned: Int, truncated: Bool) {
        let started = Date()
        let link = Data(#""prUrl":"\#(url.absoluteString)""#.utf8)
        let mentions = [Data(url.absoluteString.utf8), Data("\(repo)#\(number)".utf8)]
        let branch = headRef.flatMap { $0.isEmpty || commonBranches.contains($0) ? nil : Data(#""gitBranch":"\#($0)""#.utf8) }
        let names = [Data(repo.utf8), Data("/\(repo.split(separator: "/").last ?? "")".utf8)]
        var best: [String: SessionCandidate] = [:], scanned = 0, bytes = 0, truncated = false
        for file in files(env: env, since: now.addingTimeInterval(-Double(days) * 86_400)) {
            if let exclude, file.path.hasSuffix("/\(exclude).jsonl") || file.path.hasSuffix("-\(exclude).jsonl") { continue }  // never itself
            if scanned >= cap || bytes + file.size > maxBytes || Date().timeIntervalSince(started) > maxSeconds { truncated = true; break }
            // A plain read, never mapped: a transcript truncated or rewritten while mapped would SIGBUS the app.
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: file.path)) else { continue }
            scanned += 1
            bytes += data.count
            let tier: String
            if file.agent == .claude && data.includes(link) {
                tier = "pr-link"
            } else if best["mention"] == nil, mentions.contains(where: { data.includes($0, notFollowedByDigit: true) }) {
                tier = "mention"
            } else if file.agent == .claude, best["branch"] == nil, let branch, data.includes(branch), names.contains(where: { data.includes($0) }) {
                tier = "branch"
            } else {
                continue
            }
            guard best[tier] == nil, var candidate = describe(file, data, now: now), candidate.sessionID != exclude else { continue }
            candidate.tier = tier
            best[tier] = candidate
            if tier == "pr-link" { break }
        }
        return (tiers.compactMap { best[$0] }, scanned, truncated)
    }

    /// Where a session's transcript is (Claude: `ClaudeSessions`; Codex: the rollout named with the id); nil when none is found.
    public static func transcript(agent: AgentKind, sessionID: String, env: [String: String]) -> String? {
        guard LaunchPlanner.isValidSessionID(sessionID) else { return nil }
        if agent == .claude { return ClaudeSessions.transcriptPath(sessionID: sessionID, env: env) }
        return codexFiles(env: env).first { $0.hasSuffix("-\(sessionID).jsonl") }
    }

    /// `active`: the last activity (`lastTimestamp`, else `modified`); orders the search and is the candidate's `modifiedAt`.
    struct File { var agent: AgentKind, path: String, size: Int, modified: Date, active: Date }

    /// Top-level Claude transcripts (sub-agent folders are never entered) and Codex rollouts active since `since`, newest first.
    /// By the last record's timestamp, not the modification date: a restore or copy resets that for a whole batch.
    static func files(env: [String: String], since: Date) -> [File] {
        let fm = FileManager.default
        var found: [File] = []
        func add(_ agent: AgentKind, _ path: String) {
            guard let attributes = try? fm.attributesOfItem(atPath: path), attributes[.type] as? FileAttributeType == .typeRegular,
                  let modified = attributes[.modificationDate] as? Date, modified >= since else { return }
            let size = (attributes[.size] as? Int) ?? 0, active = lastTimestamp(path, size: size) ?? modified
            if active >= since { found.append(File(agent: agent, path: path, size: size, modified: modified, active: active)) }
        }
        for projects in ClaudeSessions.projectDirectories(env: env) {
            for project in (try? fm.contentsOfDirectory(atPath: projects)) ?? [] {
                for name in (try? fm.contentsOfDirectory(atPath: projects + "/" + project)) ?? [] where name.hasSuffix(".jsonl") {
                    add(.claude, projects + "/" + project + "/" + name)
                }
            }
        }
        for path in codexFiles(env: env) { add(.codex, path) }
        return found.sorted { $0.active > $1.active }
    }

    /// The last `"timestamp":"<ISO 8601>"` in the file's final 4 KB (one read); nil when none.
    // shortcut: a last record over 4 KB with its timestamp first (Codex) falls back to the modification date; read more if that misorders.
    static func lastTimestamp(_ path: String, size: Int) -> Date? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(max(0, size - 4096)))) != nil, let tail = try? handle.read(upToCount: 4096),
              let text = tail.jsonString(after: #""timestamp":""#, last: true) else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)) ?? (try? Date.ISO8601FormatStyle().parse(text))
    }

    static func codexFiles(env: [String: String]) -> [String] {
        let home = env["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? (env["HOME"] ?? NSHomeDirectory()) + "/.codex"
        let sessions = home + "/sessions"
        guard let walk = FileManager.default.enumerator(atPath: sessions) else { return [] }
        return walk.compactMap { ($0 as? String).flatMap { $0.hasSuffix(".jsonl") ? sessions + "/" + $0 : nil } }
    }

    /// The candidate's ids, folders and title from bounded passes over its bytes. Codex: line 1 (`session_meta`) only, plus the
    /// last `cwd`. nil when it has no valid session id.
    static func describe(_ file: File, _ data: Data, now: Date) -> SessionCandidate? {
        var id = "", launch = ""
        if file.agent == .claude {
            id = ((file.path as NSString).lastPathComponent as NSString).deletingPathExtension
            launch = data.jsonString(after: #""cwd":""#, last: false) ?? ""
        } else {
            struct Meta: Decodable { struct Payload: Decodable { var id: String?; var cwd: String? }; var payload: Payload? }
            let first = data.prefix { $0 != UInt8(ascii: "\n") }
            let meta = try? JSONDecoder().decode(Meta.self, from: first)
            id = meta?.payload?.id ?? ""
            launch = meta?.payload?.cwd ?? ""
        }
        guard LaunchPlanner.isValidSessionID(id) else { return nil }
        let title = file.agent == .claude ? data.jsonString(after: #""aiTitle":""#, last: true) ?? "" : ""
        return SessionCandidate(agent: file.agent, sessionID: id, transcript: file.path, launchDir: launch,
                                workDir: data.jsonString(after: #""cwd":""#, last: true) ?? launch, title: PromptTemplate.clean(title, max: 80),
                                branch: file.agent == .claude ? data.jsonString(after: #""gitBranch":""#, last: false) ?? "" : "", tier: "",
                                modifiedAt: file.active, mayBeOpen: now.timeIntervalSince(file.modified) < openWithin)
    }
}

extension SessionCandidate {
    /// The link `find --link` and Resume Earlier write: in the launch folder, else the last one, whichever still exists
    /// (`LaunchPlanner.directory`: absolute, no `..`); nil when neither does.
    public func link(pr: PRRef, now: Date, by: String) -> SessionLink? {
        guard let cwd = [launchDir, workDir].lazy.compactMap({ try? LaunchPlanner.directory($0, home: NSHomeDirectory()) }).first else { return nil }
        return SessionLink(pr: pr, agent: agent, sessionID: sessionID, cwd: cwd, setAt: now, source: "found", by: by)
    }
}

extension Data {
    /// `memmem`; `notFollowedByDigit`: `#12` must not match `#123`.
    func includes(_ needle: Data, notFollowedByDigit: Bool = false) -> Bool { firstOffset(of: needle, from: 0, notFollowedByDigit: notFollowedByDigit) != nil }

    func firstOffset(of needle: Data, from start: Int, notFollowedByDigit: Bool = false) -> Int? {
        withUnsafeBytes { hay in
            needle.withUnsafeBytes { pin -> Int? in
                guard let base = hay.baseAddress, let pinBase = pin.baseAddress, pin.count > 0 else { return nil }
                var from = start
                while from < hay.count, let hit = memmem(base + from, hay.count - from, pinBase, pin.count) {
                    let offset = base.distance(to: hit), end = offset + pin.count
                    if !notFollowedByDigit || end >= hay.count || !(48...57).contains(hay[end]) { return offset }
                    from = offset + 1
                }
                return nil
            }
        }
    }

    /// The JSON string value right after `key` (e.g. `"cwd":"`), first or last occurrence; escapes decoded. nil when none.
    func jsonString(after key: String, last: Bool) -> String? {
        let needle = Data(key.utf8)
        var at: Int?, from = 0
        while let hit = firstOffset(of: needle, from: from) {
            at = hit
            if !last { break }
            from = hit + 1
        }
        guard let at else { return nil }
        let start = at + needle.count
        var end = start, escaped = false
        while end < count {
            let byte = self[startIndex + end]
            if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") { break }
            end += 1
        }
        guard end < count else { return nil }
        let quoted = Data("\"".utf8) + self[(startIndex + start)..<(startIndex + end)] + Data("\"".utf8)
        return (try? JSONSerialization.jsonObject(with: quoted, options: .fragmentsAllowed)) as? String
    }
}
