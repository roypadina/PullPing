import Foundation

/// One checked-out worktree of a git clone.
public struct RepoEntry: Codable, Equatable, Sendable {
    /// This worktree.
    public var path: String
    /// Its main worktree (== `path` for a main clone).
    public var main: String
    /// The checked-out branch; nil when detached.
    public var branch: String?
    /// "owner/repo" of every remote, lowercased (`RepoIndex.key`).
    public var keys: [String]
    /// The Repository folder it was found under; nil for an inspected folder.
    public var root: String?

    public init(path: String, main: String, branch: String?, keys: [String], root: String?) {
        self.path = path; self.main = main; self.branch = branch; self.keys = keys; self.root = root
    }
}

/// The clones under the Repository folders, found by their git remotes (`RepoLocator.locate`). Read from git's own files, no
/// `git` process.
// shortcut: reads git's on-disk layout (stable since git 2.5) instead of spawning `git worktree list --porcelain`; the tests
// compare both on a temp repo, so a layout change shows up there.
public struct RepoIndex: Equatable, Sendable {
    public static let maxDepth = 3, maxDirectories = 5000, maxSeconds = 2.0
    public var entries: [RepoEntry] = []
    /// The roots as given (`RepoFolders.roots`): the app rebuilds when they change.
    public var roots: [String] = []
    public var scannedAt: Date
    /// A cap stopped the walk: some clones may be missing.
    public var truncated = false

    public init(entries: [RepoEntry] = [], roots: [String] = [], scannedAt: Date, truncated: Bool = false) {
        self.entries = entries; self.roots = roots; self.scannedAt = scannedAt; self.truncated = truncated
    }

    /// Each root (`~` expanded, skipped unless an existing folder) and the folders up to 3 levels below it, in order; hidden
    /// names, `node_modules` and `.build` are skipped and a clone is a leaf (submodules and nested clones are not indexed).
    /// A main clone adds its linked worktrees, wherever they are. At most `cap` folders and 2 s.
    public static func scan(roots: [String], home: String, now: Date, cap: Int = maxDirectories) -> RepoIndex {
        var index = RepoIndex(roots: roots, scannedAt: now)
        var seen = Set<String>(), visited = 0
        let start = Date(), fm = FileManager.default
        func add(_ found: [RepoEntry]) {
            for entry in found where seen.insert(entry.path).inserted { index.entries.append(entry) }
        }
        roots: for raw in roots {
            guard let root = try? LaunchPlanner.directory(raw, home: home) else { continue }
            if let found = entries(at: root, root: root) { add(found); continue }
            var level = [root]
            for depth in 1...maxDepth {
                var next: [String] = []
                for dir in level {
                    for name in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted()
                    where !name.hasPrefix(".") && name != "node_modules" && name != ".build" {
                        let path = dir + "/" + name
                        var isDirectory: ObjCBool = false
                        guard fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                        visited += 1
                        if visited > cap || Date().timeIntervalSince(start) > maxSeconds {
                            index.truncated = true
                            break roots
                        }
                        if let found = entries(at: path, root: root) { add(found) } else if depth < maxDepth { next.append(path) }
                    }
                }
                level = next
            }
        }
        return index
    }

    /// The clone that contains `path` (walks up at most 8 levels to the nearest `.git`); nil when none.
    public static func inspect(_ path: String) -> RepoEntry? {
        var dir = URL(fileURLWithPath: path).standardizedFileURL.path
        for _ in 0...8 {
            if let entry = entries(at: dir, root: nil)?.first { return entry }
            guard dir != "/" else { return nil }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// `owner/repo`, lowercased: the last two path segments of a remote URL, `.git` and a trailing `/` dropped, the host ignored
    /// (SSH aliases, GitHub Enterprise, mirrors). nil when it doesn't end in two name segments.
    public static func key(remoteURL: String) -> String? {
        var url = remoteURL.trimmingCharacters(in: .whitespaces)
        while url.hasSuffix("/") { url.removeLast() }
        if url.hasSuffix(".git") { url.removeLast(4) }
        let parts = url.split(whereSeparator: { $0 == "/" || $0 == ":" })
        guard parts.count >= 2 else { return nil }
        let key = "\(parts[parts.count - 2])/\(parts[parts.count - 1])"
        return LaunchPlanner.isValidRepo(key) ? key.lowercased() : nil
    }

    /// The worktree at exactly `dir` (no walking up): a main clone with its linked worktrees whose folder still exists, or one
    /// linked worktree. nil = not a clone.
    static func entries(at dir: String, root: String?) -> [RepoEntry]? {
        let git = dir + "/.git", fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: git, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue {
            let keys = remoteKeys(git + "/config")
            var found = [RepoEntry(path: dir, main: dir, branch: branch(git + "/HEAD"), keys: keys, root: root)]
            let worktrees = git + "/worktrees"
            for name in ((try? fm.contentsOfDirectory(atPath: worktrees)) ?? []).sorted() {
                // `gitdir` holds `<worktree>/.git`.
                guard let target = firstLine(worktrees + "/" + name + "/gitdir").map({ resolve($0, from: worktrees + "/" + name) }),
                      fm.fileExists(atPath: target) else { continue }
                found.append(RepoEntry(path: (target as NSString).deletingLastPathComponent, main: dir,
                                       branch: branch(worktrees + "/" + name + "/HEAD"), keys: keys, root: root))
            }
            return found
        }
        // A linked worktree (or a `--separate-git-dir` clone): `gitdir: <main>/.git/worktrees/<name>`.
        guard let line = firstLine(git), line.hasPrefix("gitdir:") else { return nil }
        let gitdir = resolve(String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces), from: dir)
        var main = dir, common = gitdir
        if let commondir = firstLine(gitdir + "/commondir") {
            common = resolve(commondir, from: gitdir)
            if (common as NSString).lastPathComponent == ".git" { main = (common as NSString).deletingLastPathComponent }
        }
        return [RepoEntry(path: dir, main: main, branch: branch(gitdir + "/HEAD"), keys: remoteKeys(common + "/config"), root: root)]
    }

    /// `ref: refs/heads/<branch>` → the branch; detached → nil.
    private static func branch(_ head: String) -> String? {
        guard let line = firstLine(head), line.hasPrefix("ref: refs/heads/") else { return nil }
        return String(line.dropFirst("ref: refs/heads/".count))
    }

    /// Every `url = …` in a `[remote "…"]` section, as keys.
    private static func remoteKeys(_ config: String) -> [String] {
        guard let text = try? String(contentsOfFile: config, encoding: .utf8) else { return [] }
        var keys: [String] = [], inRemote = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inRemote = line.hasPrefix("[remote "); continue }
            guard inRemote, let eq = line.firstIndex(of: "="), line[..<eq].trimmingCharacters(in: .whitespaces) == "url",
                  let key = key(remoteURL: String(line[line.index(after: eq)...])), !keys.contains(key) else { continue }
            keys.append(key)
        }
        return keys
    }

    private static func firstLine(_ path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) }
        return line?.isEmpty == false ? line : nil
    }

    /// Absolute as is, else relative to `base` (git ≥ 2.48 can write relative worktree paths); `..` resolved.
    private static func resolve(_ path: String, from base: String) -> String {
        URL(fileURLWithPath: path.hasPrefix("/") ? path : base + "/" + path).standardizedFileURL.path
    }
}
