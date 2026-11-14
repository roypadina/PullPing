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

    func testReRequestAfterLastReminderRestartsTheInterval() {
        var pr = requested(at: t0.addingTimeInterval(86_400))  // re-requested a day after the last reminder
        pr.lastReminderAt = t0
        let now = t0.addingTimeInterval(86_400 + 30)
        XCTAssertEqual(Reminders.nextReminder(pr: pr, settings: settings, now: now), t0.addingTimeInterval(86_400 + 3600))
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
        XCTAssertEqual(event.summary, "Still waiting on your review (requested 0 min ago)")
        XCTAssertEqual(Reminders.event(for: requested(), now: t0.addingTimeInterval(3 * 3600 + 600)).summary,
                       "Still waiting on your review (requested 3 h ago)")
    }

    /// 0.7.0: also while a re-review waits (updated after my change request, no re-request), and team requests only while
    /// their style isn't Off.
    func testReReviewAndTeamScope() {
        var pr = requested()
        pr.roles = [.reviewer]
        pr.headOID = "h2"
        pr.myReview = MyReview(state: "CHANGES_REQUESTED", commitOID: "h1", submittedAt: t0.addingTimeInterval(-600))
        pr.events = [PREvent(id: "head:h2", prID: "PR_1", kind: .newCommits, actor: "bob", at: t0, summary: "", url: nil, isOwn: false)]
        XCTAssertEqual(Reminders.nextReminder(pr: pr, settings: settings, now: t0), t0.addingTimeInterval(3600))  // from the push
        XCTAssertEqual(Reminders.event(for: pr, now: t0).summary, "Still waiting on your re-review")
        pr.myReview?.state = "APPROVED"
        XCTAssertNil(Reminders.nextReminder(pr: pr, settings: settings, now: t0), "approved, they pushed: not my turn")

        var team = requested()
        team.roles = [.teamReviewRequested]
        XCTAssertEqual(Reminders.nextReminder(pr: team, settings: settings, now: t0), t0.addingTimeInterval(3600))
        var quiet = settings
        quiet.needStyles[.teamToReview] = .off
        XCTAssertNil(Reminders.nextReminder(pr: team, settings: quiet, now: t0))
    }

    // MARK: Remind Me

    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testRemindOptionDates() {
        let now = t0  // 2027-01-15 08:00 UTC
        XCTAssertEqual(Remind.Option.hour1.date(from: now, calendar: utc), now.addingTimeInterval(3600))
        XCTAssertEqual(Remind.Option.hours3.date(from: now, calendar: utc), now.addingTimeInterval(3 * 3600))
        XCTAssertEqual(iso(Remind.Option.tomorrow.date(from: now, calendar: utc)), "2027-01-16T09:00:00Z")
        XCTAssertEqual(iso(Remind.Option.week.date(from: now, calendar: utc)), "2027-01-22T09:00:00Z")
        XCTAssertEqual(Remind.Option.allCases.map(\.title), ["In 1 Hour", "In 3 Hours", "Tomorrow at 9:00", "Next Week at 9:00"])
    }

    func testRemindFire() {
        var pr = requested()
        XCTAssertNil(Remind.fire(&pr, now: t0))
        pr.remindAt = t0.addingTimeInterval(60)
        let before = pr
        XCTAssertNil(Remind.fire(&pr, now: t0), "not due")
        XCTAssertEqual(pr, before)
        pr.events = (0..<50).map { PREvent(id: "e\($0)", prID: "PR_1", kind: .comment, actor: "bob", at: t0, summary: "", url: nil, isOwn: false) }
        let event = try! XCTUnwrap(Remind.fire(&pr, now: t0.addingTimeInterval(90)))
        XCTAssertEqual(event.kind, .reminder)
        XCTAssertTrue(event.id.hasPrefix("remind:"))
        XCTAssertFalse(event.isOwn)
        XCTAssertEqual(event.at, t0.addingTimeInterval(90))
        XCTAssertNil(pr.remindAt)
        XCTAssertEqual(pr.events.count, 50, "event cap held")
        XCTAssertEqual(pr.events.last, event)
    }

    func testRemindLabel() {
        let now = t0, en = Locale(identifier: "en_US")
        func label(_ date: Date) -> String {
            Remind.label(date, now: now, calendar: utc, locale: en).replacingOccurrences(of: "\u{202F}", with: " ")
        }
        XCTAssertEqual(label(now.addingTimeInterval(7 * 3600)), "Today, 3:00 PM")
        XCTAssertEqual(label(Remind.Option.tomorrow.date(from: now, calendar: utc)), "Tomorrow, 9:00 AM")
        XCTAssertEqual(label(now.addingTimeInterval(3 * 86_400 + 3600)), "Mon, 9:00 AM")
        XCTAssertEqual(label(Remind.Option.week.date(from: now, calendar: utc)), "Jan 22, 9:00 AM")
    }
}
