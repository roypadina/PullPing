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
}
