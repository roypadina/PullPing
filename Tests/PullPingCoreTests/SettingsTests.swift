import XCTest
@testable import PullPingCore

final class SettingsTests: XCTestCase {
    func testDefaultsAndStyles() throws {
        let settings = AppSettings()
        XCTAssertEqual([settings.pollIntervalMinutes, settings.retentionDays, settings.reminderMinutes, settings.autoHideSeconds], [3, 3, 60, 8])
        XCTAssertEqual(settings.style(for: .ciFailed, mine: true), .alert)
        XCTAssertEqual(settings.style(for: .comment, mine: true), .banner)
        XCTAssertEqual(settings.style(for: .mentioned, mine: false), .alert)
        XCTAssertEqual(settings.style(for: .reviewApproved, mine: false), .banner)
        XCTAssertEqual(settings.style(for: .ciPassed, mine: false), .off)
        XCTAssertEqual(settings.style(for: .reviewReminder, mine: false), .alert)  // follows reviewRequested

        var changed = settings
        changed.otherStyles[.reviewRequested] = .banner
        let data = try JSONEncoder().encode(changed)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""reviewRequested":"banner""#))  // keyed object, not a pair array
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded, changed)
        XCTAssertEqual(decoded.style(for: .reviewReminder, mine: false), .banner)
    }

    /// Every field survives a round trip: catches a key missing from the hand-written `init(from:)`.
    func testEveryFieldRoundTrips() throws {
        var settings = AppSettings()
        settings.pollIntervalMinutes = 10
        settings.retentionDays = 7
        settings.reminderMinutes = 15
        settings.autoHideSeconds = 20
        settings.playSound = false
        settings.notificationsEnabled = false
        settings.showMenuBarIcon = false
        settings.styles[.comment] = .off
        settings.otherStyles[.merged] = .alert
        settings.inboxLayout = .perAccount
        settings.badgeMode = .off
        settings.pausedUntil = t0
        settings.ntfyServer = "https://ntfy.example.com"
        settings.ntfyTopic = "team-prs"
        settings.phoneMine = [.ciFailed, .merged]
        settings.phoneOthers = [.reviewRequested]
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)), settings)
    }
}

