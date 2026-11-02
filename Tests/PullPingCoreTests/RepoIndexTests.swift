import XCTest
@testable import PullPingCore

/// Temp roots with real clones (`git init`, `git remote add`, `git worktree add`): never the user's own folders.
final class RepoIndexTests: XCTestCase {
    var home: URL!
    var path: String { home.path }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    /// git without the user's global or system config (signing, hooks, templates).
    @discardableResult
    func git(_ args: [String], in dir: String) throws -> String {
        let process = Process(), out = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", dir, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"] + args
        process.environment = ["HOME": path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "PATH": "/usr/bin:/bin"]
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "git \(args.joined(separator: " "))", code: Int(process.terminationStatus)) }
        return String(decoding: data, as: UTF8.self)
    }

    /// A clone at `rel` on main with one commit and these remotes.
    @discardableResult
    func clone(_ rel: String, remotes: [String] = []) throws -> String {
        let dir = home.appendingPathComponent(rel).path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: dir)
        try git(["commit", "-q", "--allow-empty", "-m", "init"], in: dir)
        for (i, url) in remotes.enumerated() { try git(["remote", "add", i == 0 ? "origin" : "r\(i)", url], in: dir) }
        return dir
    }

    func mkdir(_ rel: String) throws { try FileManager.default.createDirectory(at: home.appendingPathComponent(rel), withIntermediateDirectories: true) }

    func testKeyFromEveryRemoteForm() {
        for url in ["git@github-padina:roypadina/PullPing.git", "https://github.com/roypadina/PullPing.git", "github-work:roypadina/PullPing.git",
                    "github-padina:roypadina/PullPing", "git@github.com:roypadina/PullPing.git", "git@github-work:roypadina/PullPing.git",
                    "https://github.com/roypadina/PullPing/", "ssh://git@host/roypadina/PullPing", "gh:roypadina/PullPing", " git@x:roypadina/PullPing.git/ "] {
            XCTAssertEqual(RepoIndex.key(remoteURL: url), "roypadina/pullping", url)
        }
        XCTAssertNil(RepoIndex.key(remoteURL: "git@host:repo.git"))  // no owner
        XCTAssertNil(RepoIndex.key(remoteURL: ""))
    }

    func testScanFindsClonesWorktreesAndSkipsLeavesAndJunk() throws {
        let widgets = try clone("Code/Padina/widgets", remotes: ["git@github-padina:octo-org/Widgets.git", "https://github.com/fork/widgets"])
        try git(["worktree", "add", "-q", "-b", "feature/cache", path + "/Code/Padina/widgets-cache"], in: widgets)
        try git(["worktree", "add", "-q", "-b", "outside", path + "/Elsewhere/widgets-out"], in: widgets)  // outside every root
        try clone("Code/Padina/widgets/vendor/inner", remotes: ["git@x:a/inner.git"])  // inside a clone: never reached
        try clone("Code/src/github.com/octo-org/gadgets", remotes: ["https://github.com/octo-org/gadgets.git"])  // ghq style, depth 3 + 1: too deep
        try clone("Code/src/octo-org/gizmo", remotes: ["https://github.com/octo-org/gizmo.git"])  // depth 3
        try clone("Code/.hidden/x", remotes: ["git@x:a/hidden.git"])
        try clone("Code/node_modules/y", remotes: ["git@x:a/nm.git"])
        try clone("Code/norem")
        let index = RepoIndex.scan(roots: ["~/Code", "~/Missing"], home: path, now: t0)
        XCTAssertFalse(index.truncated)
        XCTAssertEqual(index.roots, ["~/Code", "~/Missing"])
        XCTAssertEqual(index.entries.map(\.path).sorted(), [path + "/Code/Padina/widgets", path + "/Code/Padina/widgets-cache", path + "/Code/norem",
                                                            path + "/Code/src/octo-org/gizmo", path + "/Elsewhere/widgets-out"].sorted())
        let main = try XCTUnwrap(index.entries.first { $0.path == widgets })
        XCTAssertEqual(main, RepoEntry(path: widgets, main: widgets, branch: "main", keys: ["octo-org/widgets", "fork/widgets"], root: path + "/Code"))
        let cache = try XCTUnwrap(index.entries.first { $0.path.hasSuffix("widgets-cache") })
        XCTAssertEqual([cache.main, cache.branch], [widgets, "feature/cache"])
        XCTAssertEqual(cache.keys, main.keys)
        XCTAssertEqual(index.entries.first { $0.path.hasSuffix("norem") }?.keys, [])

        try git(["checkout", "-q", "--detach"], in: path + "/Code/Padina/widgets-cache")
        XCTAssertNil(RepoIndex.scan(roots: ["~/Code"], home: path, now: t0).entries.first { $0.path.hasSuffix("widgets-cache") }?.branch)
        try FileManager.default.removeItem(atPath: path + "/Elsewhere/widgets-out")  // a pruned-later worktree whose folder is gone
        XCTAssertNil(RepoIndex.scan(roots: ["~/Code"], home: path, now: t0).entries.first { $0.path.hasSuffix("widgets-out") })
    }

    /// The files PullPing reads say what `git worktree list --porcelain` says.
    func testMatchesGitWorktreeList() throws {
        let repo = try clone("Code/repo", remotes: ["git@github.com:o/r.git"])
        try git(["worktree", "add", "-q", "-b", "topic/one", path + "/Code/repo-one"], in: repo)
        try git(["worktree", "add", "-q", "--detach", path + "/Code/repo-two"], in: repo)
        var porcelain: [[String]] = [], current: [String] = []
        for line in try git(["worktree", "list", "--porcelain"], in: repo).split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            // git prints real paths (/private/var/…); the test folder is spelled /var/…, as git stored it.
            if line.hasPrefix("worktree ") { current = [URL(fileURLWithPath: String(line.dropFirst(9))).resolvingSymlinksInPath().path] }
            if line.hasPrefix("branch refs/heads/") { current.append(String(line.dropFirst(18))) }
            if line.isEmpty, !current.isEmpty { porcelain.append(current); current = [] }
        }
        if !current.isEmpty { porcelain.append(current) }
        let index = RepoIndex.scan(roots: ["~/Code"], home: path, now: t0)
        let ours = index.entries.map { [$0.path] + ($0.branch.map { [$0] } ?? []) }
        XCTAssertEqual(ours.first, porcelain.first)  // the main worktree first
        XCTAssertEqual(Set(ours), Set(porcelain))
        XCTAssertEqual(ours.count, 3)
        XCTAssertEqual(Set(index.entries.map(\.main)), [repo])
    }

    func testInspectWalksUpFromASubfolder() throws {
        let repo = try clone("Code/repo", remotes: ["git@github.com:o/r.git"])
        try git(["worktree", "add", "-q", "-b", "wt", path + "/Code/repo-wt"], in: repo)
        try mkdir("Code/repo-wt/Sources/Deep")
        let entry = try XCTUnwrap(RepoIndex.inspect(path + "/Code/repo-wt/Sources/Deep"))
        XCTAssertEqual(entry, RepoEntry(path: path + "/Code/repo-wt", main: repo, branch: "wt", keys: ["o/r"], root: nil))
        XCTAssertNil(RepoIndex.inspect(path + "/Code"))
    }

    /// `git init --separate-git-dir`: `.git` is a file, its git dir has no `commondir`, so the folder is its own main.
    /// Relative `gitdir`/`commondir` (git ≥ 2.48 `--relative-paths`) are written by hand so any git can run the test.
    func testSeparateGitDirAndRelativePaths() throws {
        try mkdir("Code/sep")
        try mkdir("GitDirs")
        let sep = path + "/Code/sep"
        try git(["init", "-q", "-b", "main", "--separate-git-dir", path + "/GitDirs/sep.git"], in: sep)
        try git(["remote", "add", "origin", "git@github.com:o/sep.git"], in: sep)
        XCTAssertEqual(RepoIndex.entries(at: sep, root: nil), [RepoEntry(path: sep, main: sep, branch: "main", keys: ["o/sep"], root: nil)])

        let repo = try clone("Code/repo", remotes: ["git@github.com:o/r.git"])
        let linked = path + "/Code/repo-rel"
        try git(["worktree", "add", "-q", "-b", "rel", linked], in: repo)
        try Data("gitdir: ../repo/.git/worktrees/repo-rel\n".utf8).write(to: URL(fileURLWithPath: linked + "/.git"))
        try Data("../../../../repo-rel/.git\n".utf8).write(to: URL(fileURLWithPath: repo + "/.git/worktrees/repo-rel/gitdir"))
        XCTAssertEqual(RepoIndex.entries(at: linked, root: nil), [RepoEntry(path: linked, main: repo, branch: "rel", keys: ["o/r"], root: nil)])
        XCTAssertEqual(RepoIndex.entries(at: repo, root: nil)?.map(\.path), [repo, linked])
    }

    func testFolderCap() throws {
        for i in 0..<30 { try mkdir("Code/d\(i)") }
        try clone("Code/zz", remotes: ["git@x:o/zz.git"])
        let full = RepoIndex.scan(roots: ["~/Code"], home: path, now: t0)
        XCTAssertEqual([full.entries.count, full.truncated ? 1 : 0], [1, 0])
        let capped = RepoIndex.scan(roots: ["~/Code"], home: path, now: t0, cap: 30)  // zz is the 31st folder
        XCTAssertEqual([capped.entries.count, capped.truncated ? 1 : 0], [0, 1])
    }

    // MARK: RepoLocator.locate

    func locate(_ repo: String = "octo-org/widgets", headRef: String? = nil, hints: [String] = [], folders: RepoFolders) -> RepoLocation {
        RepoLocator.locate(repo: repo, headRef: headRef, hints: hints, folders: folders, index: RepoIndex.scan(roots: folders.roots, home: path, now: t0),
                           home: path)
    }

    func testEachSourceInOrder() throws {
        try mkdir("Fallback")
        var folders = RepoFolders()
        folders.roots = ["~/Code/Padina", "~/Code/Work"]
        folders.fallback = "~/Fallback"
        XCTAssertEqual(locate(folders: folders), RepoLocation(repoDir: path + "/Fallback", repoRoot: path + "/Fallback", mainDir: path + "/Fallback",
                                                              worktreeDir: path + "/Fallback", source: "fallback"))
        try mkdir("Code/Work/Widgets")  // not a clone: the name lookup
        XCTAssertEqual(locate(folders: folders).source, "name")
        XCTAssertEqual(locate(folders: folders).repoDir, path + "/Code/Work/Widgets")
        XCTAssertEqual(locate(folders: folders).repoRoot, path + "/Code/Work")
        let renamed = try clone("Code/Work/my-widgets-clone", remotes: ["https://github.com/octo-org/widgets.git"])
        XCTAssertEqual(locate(folders: folders).source, "remote")  // a renamed clone, by its remote
        XCTAssertEqual(locate(folders: folders).repoDir, renamed)
        let hinted = try clone("Hinted/w", remotes: ["github-padina:octo-org/widgets"])
        try mkdir("Hinted/w/sub")
        let unrelated = try clone("Other", remotes: ["git@x:someone/else.git"])
        let hint = locate(hints: [path + "/Code/Padina", unrelated, path + "/Hinted/w/sub"], folders: folders)
        XCTAssertEqual([hint.source, hint.repoDir, hint.repoRoot], ["hint", hinted, hinted])  // outside every root: itself
        folders.overrides["octo-org/widgets"] = "~/Code/Work/Widgets"
        let override = locate(hints: [hinted], folders: folders)
        XCTAssertEqual([override.source, override.repoDir, override.mainDir], ["override", path + "/Code/Work/Widgets", path + "/Code/Work/Widgets"])
        folders.overrides["octo-org/widgets"] = "~/Gone"
        XCTAssertEqual(locate(hints: [hinted], folders: folders).source, "hint")  // a missing override folder is skipped
    }

    func testRemoteMatchOrderAndWorktrees() throws {
        var folders = RepoFolders()
        folders.roots = ["~/Code/Padina", "~/Code/Work"]
        let work = try clone("Code/Work/widgets", remotes: ["github-work:octo-org/widgets.git"])
        let padina = try clone("Code/Padina/b-widgets", remotes: ["git@github-padina:octo-org/widgets.git"])
        try git(["worktree", "add", "-q", "-b", "feature/cache", path + "/Code/Padina/a-widgets-cache"], in: padina)
        try git(["worktree", "add", "-q", "-b", "far", path + "/Far/widgets-far"], in: padina)
        let found = locate(headRef: "feature/cache", folders: folders)
        XCTAssertEqual([found.source, found.repoDir, found.mainDir, found.worktreeDir, found.repoRoot],
                       ["remote", padina, padina, path + "/Code/Padina/a-widgets-cache", path + "/Code/Padina"])  // first root, main before linked
        XCTAssertEqual(locate(headRef: "far", folders: folders).worktreeDir, path + "/Far/widgets-far")  // outside every root, via the main
        XCTAssertEqual(locate(headRef: "nope", folders: folders).worktreeDir, padina)
        XCTAssertEqual(locate(headRef: nil, folders: folders).worktreeDir, padina)
        folders.roots.reverse()
        XCTAssertEqual(locate(folders: folders).repoDir, work)
        XCTAssertEqual(locate(headRef: "feature/cache", folders: folders).worktreeDir, path + "/Code/Padina/a-widgets-cache")  // another clone with the key
    }

    func testNameUnderRootRejectsAnotherRepository() throws {
        var folders = RepoFolders()
        folders.roots = ["~/Code"]
        try clone("Code/widgets", remotes: ["git@github.com:someone/widgets.git"])
        XCTAssertEqual(locate(folders: folders).source, "fallback")
        try FileManager.default.removeItem(atPath: path + "/Code/widgets")
        let bare = try clone("Code/widgets")  // no remote: still the name lookup
        XCTAssertEqual([locate(folders: folders).source, locate(folders: folders).repoDir], ["name", bare])
    }

    func testPlanScansOnlyForFolderPlaceholders() throws {
        try clone("Code/w", remotes: ["git@github.com:octo-org/widgets.git"])
        var pr = TrackedPR(id: "PR_1", accountID: UUID(), firstTrackedAt: t0)
        pr.repo = "octo-org/widgets"
        pr.number = 12
        pr.headRef = "main"
        var a = Automation(name: "R", kinds: [.comment], prompt: "{repo_dir}|{repo_root}|{main_dir}|{worktree_dir}|{branch}", workingDirectory: "{worktree_dir}",
                           createdAt: t0)
        let runs = home.appendingPathComponent("runs")
        let p = try LaunchPlanner.plan(a, pr: pr, event: nil, account: "", runID: "R", runsDir: runs, home: path)
        XCTAssertEqual(p.promptText, "\n\(path)/Code/w|\(path)/Code|\(path)/Code/w|\(path)/Code/w|main")
        // A given index is used as is, no scan (else the clone would be found by its remote): `Code/widgets` isn't there either.
        a.workingDirectory = "~"
        var folders = RepoFolders()
        folders.fallback = "/"
        let given = try LaunchPlanner.plan(a, pr: pr, event: nil, account: "", runID: "R", runsDir: runs, home: path, folders: folders,
                                           index: RepoIndex(scannedAt: t0))
        XCTAssertEqual(given.promptText, "\n/|/|/|/|main")
        a.prompt = "{repo_name}"
        a.workingDirectory = "~"
        XCTAssertEqual(try LaunchPlanner.plan(a, pr: pr, event: nil, account: "", runID: "R", runsDir: runs, home: path).promptText, "\nwidgets")
    }
}
