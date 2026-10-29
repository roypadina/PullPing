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
}
