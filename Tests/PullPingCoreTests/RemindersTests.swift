import XCTest
@testable import PullPingCore

final class RemindersTests: XCTestCase {
    let settings = AppSettings()  // 60 min

    func requested(at: Date = t0) -> TrackedPR {
        var pr = TrackedPR(id: "PR_1", accountID: UUID(), firstTrackedAt: t0.addingTimeInterval(-7200))
        pr.roles = [.reviewRequested]
        pr.events = [PREvent(id: "rr", prID: "PR_1", kind: .reviewRequested, actor: "bob", at: at, summary: "", url: nil, isOwn: false)]
        return pr
    }

    func testFirstReminderComesOneIntervalAfterTheRequest() {
        XCTAssertEqual(Reminders.nextReminder(pr: requested(), settings: settings, now: t0), t0.addingTimeInterval(3600))
        var pr = requested()
        pr.events = []
        pr.firstTrackedAt = t0
        XCTAssertEqual(Reminders.nextReminder(pr: pr, settings: settings, now: t0), t0.addingTimeInterval(3600))  // no request event: from tracking start
    }

    func testRepeatsFromLastReminder() {
        var pr = requested()
        pr.lastReminderAt = t0.addingTimeInterval(3600)
        XCTAssertEqual(Reminders.nextReminder(pr: pr, settings: settings, now: t0), t0.addingTimeInterval(7200))
    }

    func testStops() {
        var off = settings
        off.reminderMinutes = 0
        XCTAssertNil(Reminders.nextReminder(pr: requested(), settings: off, now: t0))
        var pr = requested()
        pr.roles = [.reviewer]
        XCTAssertNil(Reminders.nextReminder(pr: pr, settings: settings, now: t0), "request gone")
        pr = requested(); pr.isDraft = true
        XCTAssertNil(Reminders.nextReminder(pr: pr, settings: settings, now: t0), "draft")
        pr = requested(); pr.state = .closed
        XCTAssertNil(Reminders.nextReminder(pr: pr, settings: settings, now: t0), "closed")
        pr = requested(); pr.muted = true
        XCTAssertNil(Reminders.nextReminder(pr: pr, settings: settings, now: t0), "muted")
        pr = requested(); pr.snoozedUntil = t0.addingTimeInterval(60)
        XCTAssertNil(Reminders.nextReminder(pr: pr, settings: settings, now: t0), "snoozed")
        XCTAssertNotNil(Reminders.nextReminder(pr: pr, settings: settings, now: t0.addingTimeInterval(61)), "snooze over")
    }

    func testReminderEvent() {
        let event = Reminders.event(for: requested(), now: t0)
        XCTAssertEqual(event.id, "reminder:\(iso(t0))")
        XCTAssertEqual(event.kind, .reviewReminder)
        XCTAssertFalse(event.isOwn)
    }
}
