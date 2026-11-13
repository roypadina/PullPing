import XCTest
@testable import PullPingCore

/// Files written by the first build (before hide, phone, inbox and badge settings) must still load as-is.
final class CompatibilityTests: XCTestCase {
    func testOldStateFileLoads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        try fixture("old-format-state").write(to: url)

        let state = StateStore(url: url).state
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("state.broken.json").path))
        let pr = try XCTUnwrap(state.prs["PR_1"])
        XCTAssertFalse(pr.hidden)
        XCTAssertFalse(pr.isIssue)
        XCTAssertNil(pr.stateReason)
        XCTAssertNil(pr.headRef)  // until the next refresh
        XCTAssertNil(state.baselinedIssueAccounts)  // issue baseline still to come
        XCTAssertTrue(pr.muted)
        XCTAssertEqual(pr.events.count, 1)
        XCTAssertEqual(state.ignoredIDs, ["PR_9"])
        XCTAssertEqual(state.lastPollAt.values.first, t0)
    }

    func testOldSettingsKeepValuesAndTakeNewDefaults() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: fixture("old-format-settings"))
        XCTAssertEqual(settings.pollIntervalMinutes, 5)
        XCTAssertEqual(settings.otherStyles[.ciPassed], .banner)
        XCTAssertEqual(settings.inboxLayout, .unified)
        XCTAssertEqual(settings.badgeMode, .needsMe)
        XCTAssertNil(settings.pausedUntil)
        XCTAssertEqual(settings.ntfyServer, "https://ntfy.sh")
        XCTAssertEqual(settings.ntfyTopic, "")
        XCTAssertEqual(settings.phoneMine, [])
        XCTAssertEqual(settings.phoneOthers, [])
        XCTAssertTrue(settings.trackIssues)
        XCTAssertEqual(settings.style(for: .labeled, mine: true), .banner)
        XCTAssertEqual(settings.style(for: .labeled, mine: false), .off)
    }

    /// Reasons saved before issue tracking gain `assigned`, before 0.7.0 `reReview` and `conflicts`; a later choice to turn
    /// them off sticks.
    func testAssignedReasonMigration() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{ "badgeReasons": ["to review", "mentioned"] }"#.utf8))
        XCTAssertEqual(old.badgeReasons, [.toReview, .mentioned, .assigned, .reReview, .conflicts])
        var mine = old
        mine.badgeReasons.subtract([.assigned, .conflicts])
        let again = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(mine))
        XCTAssertEqual(again.badgeReasons, [.toReview, .mentioned, .reReview])
        XCTAssertTrue(again.trackIssues)
    }

    /// 0.6.1 files: pull requests load without `myReview` / `autoMerge` (the Poller refreshes them once); panel styles move
    /// from kinds to reasons, the new reasons start counted.
    func testV061FilesLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        try fixture("v061-state").write(to: url)
        let state = StateStore(url: url).state
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("state.broken.json").path))
        let mine = try XCTUnwrap(state.prs["PR_1"]), theirs = try XCTUnwrap(state.prs["PR_2"]), issue = try XCTUnwrap(state.prs["I_1"])
        XCTAssertEqual([mine.autoMerge, theirs.autoMerge, issue.autoMerge], [nil, nil, nil])
        XCTAssertNil(theirs.myReview)
        XCTAssertNil(theirs.reviewers.first?.commitOID)
        XCTAssertEqual(mine.events.first?.seeded, true)
        XCTAssertEqual(Attention.bucket(mine), .merge)
        XCTAssertEqual(Attention.bucket(theirs), .reviewed)  // re-review needs `myReview`: after the backfill refresh
        XCTAssertEqual(Attention.bucket(issue), .issueAssigned)

        let settings = try JSONDecoder().decode(AppSettings.self, from: fixture("v061-settings"))
        XCTAssertEqual(settings.needStyles, AppSettings.defaultNeedStyles)
        XCTAssertEqual(settings.badgeReasons, Set(NeedReason.allCases))
        XCTAssertEqual(settings.phoneMine, [.merged, .ciFailed])
        XCTAssertEqual(settings.style(for: .comment, mine: false), .off)  // kept for a downgrade and phone priority
    }

    /// A 0.7 automations file shaped like a real one (handler in Ghostex with a wrapper, `{repo_root}`, its own prompt, Look
    /// for earlier sessions on, links and runs): it loads unchanged but for the new keys, and saves back the same.
    func testV07AutomationsFileMigrates() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("automations.json")
        try fixture("v07-automations").write(to: url)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("v07-automations")) as? [String: Any])
        let store = AutomationStore(url: url)
        let file = store.load()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("automations.broken.json").path))
        XCTAssertEqual(file.targets, [LaunchTarget(id: "ghostex", name: "Ghostex", launcher: .ghostex)])
        XCTAssertTrue(file.targets[0].reuseRunning, "Ghostex keeps focusing a running session")
        let h = file.handler
        XCTAssertEqual([h.agentCommand, h.workingDirectory, h.launcher.rawValue], ["wrapper", "{repo_root}", "ghostex"])
        XCTAssertEqual(h.prompt, (original["handler"] as? [String: Any])?["prompt"] as? String, "a custom prompt is untouched")
        XCTAssertFalse(h.prompt.contains("{task}"))
        XCTAssertTrue(h.enabled && file.findSessions && file.enabled)
        XCTAssertEqual(h.kinds.count, 11)
        XCTAssertEqual(file.sessions.map(\.sessionID), ["0f3c2a1e-5b7d-4c9e-8a10-2b4d6f8e1c3a"])
        XCTAssertEqual(file.runs.count, 1)
        XCTAssertEqual(file.repoFolders.overrides, ["octo-org/widgets": "~/src/widgets-main"])
        XCTAssertEqual(file.scenarioPrompts, [:])
        XCTAssertEqual(file.target(for: h).target.id, "ghostex")
        // The first save writes the targets and keeps every old key as it was.
        store.mutate { $0.findSessions = false; $0.findSessions = true; $0.runs.append($0.runs[0]) }
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual((saved["targets"] as? [[String: Any]])?.map { $0["id"] as? String }, ["ghostex"])
        func handler(_ json: [String: Any]) -> (NSDictionary, Set<String>) {  // kinds: a set, written in any order
            var h = json["handler"] as? [String: Any] ?? [:]
            let kinds = Set(h.removeValue(forKey: "kinds") as? [String] ?? [])
            return (h as NSDictionary, kinds)
        }
        XCTAssertEqual(handler(saved).0, handler(original).0, "0.7 reads the same handler")
        XCTAssertEqual(handler(saved).1, handler(original).1)
        XCTAssertEqual(saved["sessions"] as? NSArray, original["sessions"] as? NSArray)
        XCTAssertEqual(saved["repoFolders"] as? NSDictionary, original["repoFolders"] as? NSDictionary)
        XCTAssertEqual(AutomationStore(url: url).load().targets, file.targets)
    }

    func testOldAccountsLoad() throws {
        let accounts = try JSONDecoder().decode([Account].self, from: fixture("old-format-accounts"))
        XCTAssertEqual(accounts.map(\.login), ["dana"])
        XCTAssertEqual(accounts.first?.tokenService, Keychain.service(for: accounts[0].id))
    }
}
