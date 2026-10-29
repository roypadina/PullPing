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
}
