import XCTest
@testable import PullPingCore

final class EventEngineTests: XCTestCase {
    let account = UUID()

    func diff(_ old: TrackedPR?, _ s: PRSnapshot, requestedSearch: Bool = false, reviewedSearch: Bool = false, now: Date = t0) -> (pr: TrackedPR, events: [PREvent]) {
        EventEngine.diff(old: old, snapshot: s, me: me, accountID: account, inRequestedSearch: requestedSearch, inReviewedSearch: reviewedSearch, now: now)
    }

    /// A PR tracked before `t0`.
    func tracked(_ s: PRSnapshot = snap()) -> TrackedPR { diff(nil, s, now: t0.addingTimeInterval(-3600)).pr }

    func loud(_ events: [PREvent]) -> [PREvent] { events.filter { !$0.isOwn } }

    func testNewPRSeededTimelineIsSilent() {
        let s = snap(timeline: [node("IC_1", by: "alice", at: t0.addingTimeInterval(-600), body: "Nice"),
                                node("PRR_1", "PullRequestReview", by: "carol", at: t0.addingTimeInterval(-300), review: "APPROVED")])
        let (pr, events) = diff(nil, s)
        XCTAssertEqual(events.map(\.kind), [.comment, .reviewApproved])
        XCTAssertTrue(loud(events).isEmpty)
        XCTAssertEqual(pr.firstTrackedAt, t0)
        XCTAssertEqual(pr.roles, [])
    }

    func testNewPRWithMeRequestedEmitsOneReviewRequested() {
        let (pr, events) = diff(nil, snap(requested: [me]), requestedSearch: true)
        XCTAssertEqual(loud(events).map(\.kind), [.reviewRequested])
        XCTAssertEqual(events.first?.actor, "bob")
        XCTAssertEqual(events.first?.id, "rr:dana:\(iso(t0))")
        XCTAssertTrue(pr.roles.contains(.reviewRequested))
    }

    func testNewPRAssignedAndMentioned() {
        let s = snap(assignees: [me], timeline: [
            node("IC_1", by: "alice", at: t0.addingTimeInterval(-600), body: "@dana can you look?"),
            node("IC_2", by: "carol", at: t0.addingTimeInterval(-90_000), body: "old ping @dana"),
        ], body: "Fixes it. cc @DANA")
        let (pr, events) = diff(nil, s)
        XCTAssertEqual(loud(events).map(\.id), ["IC_1", "assign:dana:\(iso(t0))", "body:PR_1"])
        XCTAssertEqual(loud(events).map(\.kind), [.mentioned, .assigned, .mentioned])
        XCTAssertTrue(events.first { $0.id == "IC_2" }!.isOwn)  // older than 24 h: seeded, silent
        XCTAssertTrue(pr.roles.isSuperset(of: [.assigned, .mentioned]))
    }

    func testMyNewPRNeverNotifiesMe() {
        let (pr, events) = diff(nil, snap(author: me, assignees: [me], body: "@dana self note"))
        XCTAssertTrue(loud(events).isEmpty)
        XCTAssertTrue(pr.roles.contains(.author))
    }

    func testOwnCommentIsOwn() {
        let (pr, events) = diff(tracked(), snap(timeline: [node("IC_1", by: "Dana", at: t0, body: "Fixed")]))
        XCTAssertEqual(events.map(\.isOwn), [true])
        XCTAssertTrue(pr.roles.contains(.commenter))
    }

    func testCommentAndMention() {
        let (pr, events) = diff(tracked(), snap(timeline: [
            node("IC_1", by: "alice", at: t0, body: "Looks good\nmore"),
            node("IC_2", by: "bob", at: t0.addingTimeInterval(1), body: "ping @Dana!"),
        ]))
        XCTAssertEqual(events.map(\.kind), [.comment, .mentioned])
        XCTAssertEqual(events.first?.summary, "Looks good")
        XCTAssertTrue(loud(events).count == 2)
        XCTAssertTrue(pr.roles.contains(.mentioned))
    }

    func testMentionIsWholeWord() {
        XCTAssertTrue(EventEngine.mentions("hi @dana.", "dana"))
        XCTAssertTrue(EventEngine.mentions("(@DANA)", "dana"))
        XCTAssertFalse(EventEngine.mentions("hi @danax", "dana"))
        XCTAssertFalse(EventEngine.mentions("hi @dana-bot", "dana"))
        XCTAssertFalse(EventEngine.mentions("mail@dana", "dana"))
    }

    func testReviews() {
        var commented = node("PRR_3", "PullRequestReview", by: "carol", at: t0.addingTimeInterval(2), review: "COMMENTED")
        commented.commentCount = 3
        commented.commentPath = "Sources/Cache.swift"
        commented.commentBody = "Rename this\nplease"
        var reply = node("PRR_4", "PullRequestReview", by: "alice", at: t0.addingTimeInterval(3), review: "COMMENTED")
        reply.commentCount = 1
        reply.commentPath = "README.md"
        reply.commentBody = "Agreed"
        let (_, events) = diff(tracked(), snap(timeline: [
            node("PRR_1", "PullRequestReview", by: "alice", at: t0, body: "LGTM", review: "APPROVED"),
            node("PRR_2", "PullRequestReview", by: "bob", at: t0.addingTimeInterval(1), review: "CHANGES_REQUESTED"),
            commented, reply,
            node("PRR_5", "PullRequestReview", by: "bob", at: t0.addingTimeInterval(4), review: "DISMISSED"),
            node("PRR_6", "PullRequestReview", by: "bob", at: t0.addingTimeInterval(5), body: "@dana see inline", review: "COMMENTED"),
        ]))
        XCTAssertEqual(events.map(\.kind), [.reviewApproved, .reviewChangesRequested, .reviewCommented, .reviewCommented, .reviewCommented, .mentioned])
        XCTAssertEqual(events.map(\.summary), ["LGTM", "", "Sources/Cache.swift: Rename this (+2 more)", "README.md: Agreed", "@dana see inline", "@dana see inline"])
        XCTAssertEqual(events.last?.id, "mention:PRR_6")
    }

    func testNewCommitsByOthersNotifyMineAreSilent() {
        let old = tracked()
        let bob = diff(old, snap(head: "bbb2222")).events
        XCTAssertEqual(bob.map(\.kind), [.newCommits])
        XCTAssertEqual(bob.first?.id, "head:bbb2222")
        XCTAssertFalse(bob[0].isOwn)
        var mine = snap(head: "ccc3333")
        mine.headAuthorLogin = me
        XCTAssertEqual(diff(old, mine).events.map(\.isOwn), [true])
    }

    func testForcePushReplacesHeadEvent() {
        var push = node("HFP_1", "HeadRefForcePushedEvent", by: "bob", at: t0)
        push.detail = "bbb2222"
        let events = diff(tracked(), snap(head: "bbb2222", timeline: [push])).events
        XCTAssertEqual(events.map(\.id), ["HFP_1"])
        XCTAssertEqual(events.first?.summary, "force-pushed bbb2222")
    }

    func testCITransitionsAndHeadReset() {
        var pr = tracked(snap(ci: .pending))
        var events: [PREvent]
        (pr, events) = diff(pr, snap(ci: .success))
        XCTAssertEqual(events.map(\.kind), [.ciPassed])
        XCTAssertEqual(events.first?.actor, "CI")
        var failing = snap(ci: .failure)
        failing.checks = [CheckSummary(name: "build", state: .success, url: nil), CheckSummary(name: "lint", state: .failure, url: URL(string: "https://ci.example.com/lint"))]
        (pr, events) = diff(pr, failing)
        XCTAssertEqual(events.map(\.kind), [.ciFailed])
        XCTAssertEqual(events.first?.summary, "lint")
        XCTAssertEqual(events.first?.url, URL(string: "https://ci.example.com/lint"))
        (pr, events) = diff(pr, failing)
        XCTAssertTrue(events.isEmpty)  // no transition
        (pr, events) = diff(pr, snap(head: "bbb2222", ci: .pending))
        XCTAssertEqual(events.map(\.kind), [.newCommits])  // head change resets CI silently
        XCTAssertEqual(pr.ci, .pending)
        (pr, events) = diff(pr, snap(head: "bbb2222", ci: .success))
        XCTAssertEqual(events.map(\.id), ["ci:bbb2222:success"])
    }

    func testDuplicateNodeAcrossDiffsIsOneEvent() {
        let s = snap(timeline: [node("IC_1", by: "alice", at: t0, body: "Hi")])
        let first = diff(tracked(), s)
        XCTAssertEqual(first.events.count, 1)
        XCTAssertTrue(diff(first.pr, s).events.isEmpty)
    }

    func testMergedAndClosedSameMinuteIsOnlyMerged() {
        let (pr, events) = diff(tracked(), snap(timeline: [
            node("ME_1", "MergedEvent", by: "carol", at: t0),
            node("CE_1", "ClosedEvent", by: "carol", at: t0.addingTimeInterval(5)),
        ], state: .merged))
        XCTAssertEqual(events.map(\.kind), [.merged])
        XCTAssertTrue(pr.seenEventIDs.contains("CE_1"))
        XCTAssertEqual(pr.state, .merged)
    }

    func testOtherTimelineKinds() {
        var rename = node("RT_1", "RenamedTitleEvent", by: "bob", at: t0.addingTimeInterval(5))
        rename.detail = "New title"
        let kinds = diff(tracked(), snap(timeline: [
            node("RFR_1", "ReadyForReviewEvent", by: "bob", at: t0),
            node("CTD_1", "ConvertToDraftEvent", by: "bob", at: t0.addingTimeInterval(1)),
            node("CE_1", "ClosedEvent", by: "bob", at: t0.addingTimeInterval(2)),
            node("RE_1", "ReopenedEvent", by: "bob", at: t0.addingTimeInterval(3)),
            node("RD_1", "ReviewDismissedEvent", by: "bob", at: t0.addingTimeInterval(4)),
            rename,
        ])).events.map(\.kind)
        XCTAssertEqual(kinds, [.readyForReview, .convertedToDraft, .closed, .reopened, .reviewDismissed, .retitled])
    }

    func testRequestRemovedDropsRoleWithoutEvent() {
        let old = diff(tracked(), snap(requested: [me]), requestedSearch: true).pr
        XCTAssertTrue(old.roles.contains(.reviewRequested))
        let (pr, events) = diff(old, snap())
        XCTAssertTrue(events.isEmpty)
        XCTAssertFalse(pr.roles.contains(.reviewRequested))
    }

    func testTeamRequestNeedsRequestedSearch() {
        let old = tracked()
        let silent = diff(old, snap(teams: ["core"]), requestedSearch: false)
        XCTAssertTrue(silent.events.isEmpty)
        XCTAssertFalse(silent.pr.roles.contains(.teamReviewRequested))
        let (pr, events) = diff(old, snap(teams: ["core"]), requestedSearch: true)
        XCTAssertEqual(events.map(\.kind), [.reviewRequested])
        XCTAssertEqual(events.first?.summary, "via team core")
        XCTAssertTrue(pr.roles.contains(.teamReviewRequested))
    }

    func testReviewerRoleAndWatermark() {
        let (pr, _) = diff(tracked(), snap(timeline: [node("IC_1", by: "alice", at: t0.addingTimeInterval(500))], updatedAt: t0), reviewedSearch: true)
        XCTAssertTrue(pr.roles.contains(.reviewer))
        XCTAssertEqual(pr.lastSeenAt, t0.addingTimeInterval(500))
    }

    func testCaps() {
        var old = tracked()
        old.seenEventIDs = (0..<300).map { "old-\($0)" }
        old.events = (0..<50).map { PREvent(id: "old-\($0)", prID: "PR_1", kind: .comment, actor: "alice", at: t0, summary: "", url: nil, isOwn: false) }
        let timeline = (0..<5).map { node("IC_new_\($0)", by: "bob", at: t0.addingTimeInterval(Double($0))) }
        let pr = diff(old, snap(timeline: timeline)).pr
        XCTAssertEqual(pr.seenEventIDs.count, 300)
        XCTAssertEqual(pr.seenEventIDs.last, "IC_new_4")
        XCTAssertEqual(pr.events.count, 50)
        XCTAssertEqual(pr.events.last?.id, "IC_new_4")
        XCTAssertEqual(pr.events.first?.id, "old-5")
    }
}
