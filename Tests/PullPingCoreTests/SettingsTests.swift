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
        settings.needStyles[.teamToReview] = .off
        settings.badgeReasons = [.toReview]
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testNeedStyles() throws {
        let settings = AppSettings()
        XCTAssertEqual(NeedReason.allCases.map(settings.needStyle),
                       [.alert, .alert, .alert, .alert, .banner, .alert, .alert, .banner, .banner, .banner])  // NeedReason order
        XCTAssertEqual(AppSettings.needStyles(mine: AppSettings.defaultStyles, others: AppSettings.defaultOtherStyles),
                       AppSettings.defaultNeedStyles, "an untouched 0.6 setup gets exactly the new defaults")
        let data = try JSONEncoder().encode(settings)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""to re-review":"alert""#))  // keyed object
    }

    /// Before 0.7.0 panels were styled per kind: each reason takes the stronger style of its kinds, Off stays Off.
    func testNeedStylesMigrateFromKindStyles() throws {
        let json = #"""
        { "styles": { "reviewChangesRequested": "banner", "ciFailed": "off", "comment": "alert", "reviewApproved": "off", "ciPassed": "off" },
          "otherStyles": { "reviewRequested": "off", "mentioned": "banner", "assigned": "off" },
          "badgeReasons": ["to review", "CI failed"], "trackIssues": true }
        """#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.needStyles, [.toReview: .off, .reReview: .off, .teamToReview: .off, .changesRequested: .banner, .ciFailed: .off,
                                      .conflicts: .banner, .mentioned: .banner, .assigned: .banner, .newComments: .alert, .readyToMerge: .off])
        XCTAssertEqual(s.badgeReasons, [.toReview, .ciFailed, .reReview, .conflicts])  // new reasons start counted
        // New comments fire on my pull requests only: others' comment style doesn't turn it back on.
        XCTAssertEqual(AppSettings.needStyles(mine: [.comment: .off, .reviewCommented: .off], others: [.comment: .alert])[.newComments], .off)
        XCTAssertEqual(AppSettings.needStyles(mine: [.comment: .off, .reviewCommented: .alert], others: [:])[.newComments], .alert)
        var later = s
        later.badgeReasons.remove(.reReview)
        later.needStyles[.toReview] = .alert
        let again = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(later))
        XCTAssertEqual(again.badgeReasons, [.toReview, .ciFailed, .conflicts], "migrates once")
        XCTAssertEqual(again.needStyle(.toReview), .alert)
        XCTAssertEqual(again.needStyle(.reReview), .off)
    }
}

