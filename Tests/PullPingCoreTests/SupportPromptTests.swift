import XCTest
@testable import PullPingCore

final class SupportPromptTests: XCTestCase {
    private let day = SupportPromptState.day

    private func mayAsk(_ s: SupportPromptState, day d: Double, updates: Int = 80, version: String = "0.7.0") -> Bool {
        s.mayAsk(now: t0.addingTimeInterval(d * day), installDate: t0, updates: updates, appVersion: version)
    }

    func testFirstAskNeedsSevenDaysAndMoreThan50Updates() {
        let s = SupportPromptState()
        XCTAssertFalse(mayAsk(s, day: 6.9))
        XCTAssertFalse(mayAsk(s, day: 60, updates: 50), "never at 50 or fewer, however long installed")
        XCTAssertTrue(mayAsk(s, day: 7, updates: 51))
    }

    func testSnoozeHidesFourteenDays() {
        var s = SupportPromptState()
        s.record(.snooze, now: t0.addingTimeInterval(10 * day), appVersion: "0.7.0")
        XCTAssertFalse(mayAsk(s, day: 23.9))
        XCTAssertTrue(mayAsk(s, day: 24))
    }

    func testSupportQuietFor180Days() {
        var s = SupportPromptState()
        s.record(.support, now: t0.addingTimeInterval(10 * day), appVersion: "0.7.0")
        XCTAssertFalse(mayAsk(s, day: 189))
        XCTAssertTrue(mayAsk(s, day: 190))
    }

    func testNeverLastsUntilNextMajorAndNinetyDays() {
        var s = SupportPromptState()
        s.record(.never, now: t0.addingTimeInterval(10 * day), appVersion: "0.7.0")
        XCTAssertFalse(mayAsk(s, day: 300, version: "0.9.0"), "a feature release must not undo 'never'")
        XCTAssertFalse(mayAsk(s, day: 50, version: "1.0.0"), "a major release within 90 days must not undo it")
        XCTAssertTrue(mayAsk(s, day: 100, version: "1.0.0"))
    }

    func testAtMostThreeAsksPerRolling365Days() {
        var s = SupportPromptState()
        for d in [10.0, 40, 70] { s.recordShown(t0.addingTimeInterval(d * day)) }
        XCTAssertFalse(mayAsk(s, day: 300))
        XCTAssertTrue(mayAsk(s, day: 376), "the first ask has rolled out of the window")
    }

    func testOldOrPartialStateDecodes() throws {
        XCTAssertEqual(try JSONDecoder().decode(SupportPromptState.self, from: Data("{}".utf8)), SupportPromptState())
        let snoozed = try JSONDecoder().decode(SupportPromptState.self, from: Data(#"{"snoozedUntil":0}"#.utf8))
        XCTAssertEqual(snoozed.snoozedUntil, Date(timeIntervalSinceReferenceDate: 0), "known keys survive missing ones")
        XCTAssertEqual(snoozed.shownAt, [])
    }

    private func pr(roles: Set<Role> = [.author]) -> TrackedPR {
        var pr = TrackedPR(id: "PR_1", accountID: UUID(), firstTrackedAt: t0)
        pr.roles = roles
        return pr
    }

    private func event(_ kind: EventKind, own: Bool = false) -> PREvent {
        PREvent(id: "e", prID: "PR_1", kind: kind, actor: own ? me : "alice", at: t0, summary: "", url: nil, isOwn: own)
    }

    func testMomentIsAMergeOrApprovalOfYours() {
        XCTAssertEqual(SupportPromptState.moment(event(.merged), pr: pr()), .success)
        XCTAssertEqual(SupportPromptState.moment(event(.merged, own: true), pr: pr()), .success, "you merged it yourself")
        XCTAssertEqual(SupportPromptState.moment(event(.reviewApproved), pr: pr()), .success)
        XCTAssertNil(SupportPromptState.moment(event(.merged), pr: pr(roles: [.reviewer])), "someone else's pull request")
        XCTAssertNil(SupportPromptState.moment(event(.comment), pr: pr()))
        var seeded = event(.merged)
        seeded.seeded = true
        XCTAssertNil(SupportPromptState.moment(seeded, pr: pr()), "history of a newly tracked pull request")
        var issue = pr()
        issue.isIssue = true
        XCTAssertNil(SupportPromptState.moment(event(.closed), pr: issue))
    }

    func testTroubleOnYoursIsStress() {
        var failing = pr()
        failing.ci = .failure
        XCTAssertEqual(SupportPromptState.moment(event(.ciFailed), pr: failing), .stress)
        XCTAssertEqual(SupportPromptState.moment(event(.reviewChangesRequested), pr: pr()), .stress)
        XCTAssertNil(SupportPromptState.moment(event(.ciFailed), pr: pr(roles: [.reviewRequested])), "CI on someone else's")
        XCTAssertEqual(SupportPromptState.moment(event(.conflicts), pr: pr()), .stress, "conflicts on yours (0.7.0)")
        XCTAssertNil(SupportPromptState.moment(event(.reviewChangesRequested, own: true), pr: pr()), "your own event")
    }

    func testCalmMeansNoReviewAskedAndNothingToFix() {
        XCTAssertTrue(SupportPromptState.calm([]))
        XCTAssertTrue(SupportPromptState.calm([pr(), pr(roles: [.teamReviewRequested])]), "a team request is not yours alone")
        XCTAssertFalse(SupportPromptState.calm([pr(roles: [.reviewRequested])]), "a review is asked of you")
        var failing = pr()
        failing.ci = .failure
        XCTAssertFalse(SupportPromptState.calm([failing]), "CI failed on yours")
        failing.muted = true
        XCTAssertTrue(SupportPromptState.calm([failing]), "muted items are out of mind")
        var reminded = pr()
        reminded.events = [event(.reminder)]
        XCTAssertFalse(SupportPromptState.calm([reminded]), "a reminder you set is due")
    }
}
