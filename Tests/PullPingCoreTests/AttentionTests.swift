import XCTest
@testable import PullPingCore

final class AttentionTests: XCTestCase {
    func pr(_ id: String = "PR_1", account: UUID = UUID(), roles: Set<Role> = [], events: [(Date, Bool)] = []) -> TrackedPR {
        var pr = TrackedPR(id: id, accountID: account, firstTrackedAt: t0)
        pr.roles = roles
        pr.events = events.enumerated().map { PREvent(id: "e\($0)", prID: id, kind: .comment, actor: "alice", at: $1.0, summary: "", url: nil, isOwn: $1.1) }
        return pr
    }

    func testUnread() {
        var p = pr(events: [(t0, false), (t0.addingTimeInterval(10), true), (t0.addingTimeInterval(20), false)])
        XCTAssertEqual(Attention.unread(p), 2)
        p.lastReadAt = t0.addingTimeInterval(10)
        XCTAssertEqual(Attention.unread(p), 1)
        XCTAssertTrue(Attention.isAttention(p))
        p.lastReadAt = t0.addingTimeInterval(20)
        XCTAssertFalse(Attention.isAttention(p))
    }

    func testAwaitingReview() {
        var p = pr(roles: [.teamReviewRequested])
        XCTAssertTrue(Attention.awaitingMyReview(p))
        XCTAssertTrue(Attention.isAttention(p))
        p.isDraft = true
        XCTAssertFalse(Attention.awaitingMyReview(p))
        p.isDraft = false
        p.state = .merged
        XCTAssertFalse(Attention.awaitingMyReview(p))
    }

    func testMutedExcluded() {
        var p = pr(roles: [.reviewRequested], events: [(t0, false)])
        p.muted = true
        XCTAssertFalse(Attention.isAttention(p))
    }

    func testBadgeCountAcrossAccounts() {
        let work = UUID(), home = UUID(), off = UUID()
        let prs = [pr("A", account: work, roles: [.reviewRequested]), pr("B", account: home, events: [(t0, false)]),
                   pr("C", account: home), pr("D", account: off, roles: [.reviewRequested])]
        XCTAssertEqual(Attention.badgeCount(prs, enabledAccounts: [work, home]), 2)
    }

    func testGroups() {
        XCTAssertEqual(Attention.group(pr(roles: [.author, .reviewRequested])), .mine)
        XCTAssertEqual(Attention.group(pr(roles: [.reviewRequested])), .toReview)
        XCTAssertEqual(Attention.group(pr(roles: [.commenter])), .involved)
        var draft = pr(roles: [.reviewRequested])
        draft.isDraft = true
        XCTAssertEqual(Attention.group(draft), .involved)
    }

    func testNeedsMeAndBreakdown() {
        var review = pr("R", roles: [.reviewRequested])
        XCTAssertEqual(Attention.needReason(review), .toReview)
        XCTAssertNil(Attention.needReason(review, counting: [.ciFailed]))  // reason switched off in Settings
        XCTAssertEqual(Attention.needReason(pr("T", roles: [.teamReviewRequested])), .teamToReview)
        review.isDraft = true
        XCTAssertNil(Attention.needReason(review))

        var changes = pr("C", roles: [.author])
        changes.reviewDecision = "CHANGES_REQUESTED"
        XCTAssertEqual(Attention.needReason(changes), .changesRequested)

        var ci = pr("F", roles: [.author])
        ci.ci = .failure
        XCTAssertEqual(Attention.needReason(ci), .ciFailed)

        var ready = pr("M", roles: [.author])
        ready.reviewDecision = "APPROVED"
        ready.ci = .success
        ready.mergeState = "CLEAN"
        XCTAssertEqual(Attention.needReason(ready), .readyToMerge)
        ready.mergeState = "BLOCKED"
        XCTAssertNil(Attention.needReason(ready))

        let comments = pr("N", roles: [.author], events: [(t0, false)])
        XCTAssertEqual(Attention.needReason(comments), .newComments)
        XCTAssertNil(Attention.needReason(pr("O", roles: [.author], events: [(t0, true)])))  // own comment
        XCTAssertNil(Attention.needReason(pr("I", roles: [.commenter], events: [(t0, false)])))  // others' chatter isn't "needs me"

        var mention = pr("X", roles: [.commenter])
        mention.events = [PREvent(id: "m", prID: "X", kind: .mentioned, actor: "alice", at: t0, summary: "", url: nil, isOwn: false)]
        XCTAssertEqual(Attention.needReason(mention), .mentioned)
        mention.lastReadAt = t0
        XCTAssertNil(Attention.needReason(mention))

        var hidden = changes, muted = changes, merged = changes
        hidden.hidden = true
        muted.muted = true
        merged.state = .merged
        XCTAssertFalse([hidden, muted, merged].contains { Attention.needsMe($0) })

        let review2 = pr("R2", roles: [.teamReviewRequested])
        XCTAssertEqual(Attention.breakdown([pr("R", roles: [.reviewRequested]), review2, changes, ready, hidden]), "1 to review · 1 team review · 1 changes requested")
        XCTAssertEqual(Attention.breakdown([]), "")
    }

    func testBadgeModesAndHidden() {
        let id = UUID()
        var hidden = pr("H", account: id, roles: [.reviewRequested])
        hidden.hidden = true
        let prs = [pr("A", account: id, roles: [.reviewRequested]), pr("B", account: id, roles: [.commenter], events: [(t0, false)]), hidden]
        XCTAssertFalse(Attention.isAttention(hidden))
        XCTAssertEqual(Attention.badgeCount(prs, enabledAccounts: [id], mode: .allUnread), 2)
        XCTAssertEqual(Attention.badgeCount(prs, enabledAccounts: [id], mode: .needsMe), 1)
        XCTAssertEqual(Attention.badgeCount(prs, enabledAccounts: [id], mode: .off), 0)
    }
}
