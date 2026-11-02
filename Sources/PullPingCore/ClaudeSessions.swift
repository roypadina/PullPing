import Foundation

/// Where a Claude Code session was started. `claude --resume <id>` finds a session only from that folder, and the agent
/// that links itself can't know it (its shell may have moved); the transcript records it.
public enum ClaudeSessions {
    static let maxBytes = 256 * 1024
    static let maxLines = 20

    /// The first `cwd` in the first lines of `<config>/projects/*/<id>.jsonl`, for `$CLAUDE_CONFIG_DIR` then `~/.claude`.
    /// nil = no transcript, or none of those lines has one.
    public static func launchDirectory(sessionID: String, env: [String: String]) -> String? {
        guard LaunchPlanner.isValidSessionID(sessionID) else { return nil }  // never a path
        let fm = FileManager.default
        for projects in projectDirectories(env: env).map(URL.init(fileURLWithPath:)) {
            for entry in (try? fm.contentsOfDirectory(atPath: projects.path)) ?? [] {
                guard let handle = FileHandle(forReadingAtPath: projects.appendingPathComponent(entry).appendingPathComponent("\(sessionID).jsonl").path)
                else { continue }
                let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
                try? handle.close()
                for line in data.split(separator: UInt8(ascii: "\n")).prefix(maxLines) {
                    if let cwd = (try? JSONDecoder().decode(Line.self, from: line))?.cwd, !cwd.isEmpty { return cwd }
                }
            }
        }
        return nil
    }

    /// `<config>/projects/*/<id>.jsonl` for `$CLAUDE_CONFIG_DIR` then `~/.claude`; nil when no transcript has that id.
    public static func transcriptPath(sessionID: String, env: [String: String]) -> String? {
        guard LaunchPlanner.isValidSessionID(sessionID) else { return nil }
        for projects in projectDirectories(env: env) {
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: projects)) ?? [] {
                let path = projects + "/" + entry + "/" + sessionID + ".jsonl"
                if FileManager.default.fileExists(atPath: path) { return path }
            }
        }
        return nil
    }

    /// The existing `projects` folders of `$CLAUDE_CONFIG_DIR` and `~/.claude`, one per real folder (profiles may share one).
    public static func projectDirectories(env: [String: String]) -> [String] {
        var seen = Set<String>(), dirs: [String] = []
        for config in [env["CLAUDE_CONFIG_DIR"] ?? "", (env["HOME"] ?? NSHomeDirectory()) + "/.claude"] where !config.isEmpty {
            let projects = config + "/projects"
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: projects, isDirectory: &isDirectory), isDirectory.boolValue,
                  seen.insert(URL(fileURLWithPath: projects).resolvingSymlinksInPath().path).inserted else { continue }
            dirs.append(projects)
        }
        return dirs
    }

    private struct Line: Decodable { var cwd: String? }
}
