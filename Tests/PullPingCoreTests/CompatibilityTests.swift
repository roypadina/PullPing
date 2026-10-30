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

    /// Reasons saved before issue tracking gain `assigned`; a later choice to turn it off sticks.
    func testAssignedReasonMigration() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{ "badgeReasons": ["to review", "mentioned"] }"#.utf8))
        XCTAssertEqual(old.badgeReasons, [.toReview, .mentioned, .assigned])
        var mine = old
        mine.badgeReasons.remove(.assigned)
        let again = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(mine))
        XCTAssertEqual(again.badgeReasons, [.toReview, .mentioned])
        XCTAssertTrue(again.trackIssues)
    }

    func testOldAccountsLoad() throws {
        let accounts = try JSONDecoder().decode([Account].self, from: fixture("old-format-accounts"))
        XCTAssertEqual(accounts.map(\.login), ["dana"])
        XCTAssertEqual(accounts.first?.tokenService, Keychain.service(for: accounts[0].id))
    }
}
