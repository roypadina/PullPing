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
        XCTAssertEqual(Attention.breakdown([pr("R", roles: [.reviewRequested]), review2, changes, ready, hidden]), "1 to review · 1 changes requested · 1 team review")
        XCTAssertEqual(Attention.breakdown([]), "")
    }

    func testAssignedAndIssueReasons() {
        func event(_ kind: EventKind) -> PREvent { PREvent(id: kind.rawValue, prID: "X", kind: kind, actor: "alice", at: t0, summary: "", url: nil, isOwn: false) }
        func issue(_ roles: Set<Role>, _ kinds: [EventKind]) -> TrackedPR {
            var p = pr("X", roles: roles)
            p.isIssue = true
            p.events = kinds.map(event)
            return p
        }
        // An unread assignment needs me, on an issue or a pull request; once read it doesn't, but it isn't Done either.
        var assigned = issue([.assigned], [.assigned])
        XCTAssertEqual(Attention.needReason(assigned), .assigned)
        XCTAssertNil(Attention.needReason(assigned, counting: [.mentioned]))
        var assignedPR = pr("P", roles: [.assigned])
        assignedPR.events = [event(.assigned)]
        XCTAssertEqual(Attention.needReason(assignedPR), .assigned)
        assigned.lastReadAt = t0
        XCTAssertNil(Attention.needReason(assigned))
        XCTAssertEqual(Attention.bucket(assigned), .issueAssigned)

        // New comments by others: my issue, or an issue assigned to me; not a pull request I'm only assigned to.
        XCTAssertEqual(Attention.needReason(issue([.author], [.comment])), .newComments)
        XCTAssertEqual(Attention.needReason(issue([.assigned], [.comment])), .newComments)
        XCTAssertNil(Attention.needReason(pr("Q", roles: [.assigned], events: [(t0, false)])))
        XCTAssertEqual(Attention.needReason(issue([.commenter], [.mentioned])), .mentioned)
        XCTAssertNil(Attention.needReason(issue([.commenter], [.comment, .labeled])))

        var involved = issue([.commenter], [.comment])
        involved.lastReadAt = t0
        XCTAssertNil(Attention.needReason(involved))
        XCTAssertEqual(Attention.breakdown([pr("R", roles: [.reviewRequested]), issue([.assigned], [.assigned])]), "1 to review · 1 assigned")
    }

    func testSortedOrder() {
        func at(_ p: TrackedPR, _ seconds: Double, number: Int) -> TrackedPR {
            var p = p
            p.updatedAt = t0.addingTimeInterval(seconds)
            p.number = number
            return p
        }
        let review = at(pr("review", roles: [.reviewRequested]), 0, number: 1)  // needs me, oldest
        let unread = at(pr("unread", roles: [.commenter], events: [(t0, false)]), 10, number: 2)
        let recent = at(pr("recent", roles: [.commenter]), 30, number: 3)
        let older = at(pr("older", roles: [.commenter]), 20, number: 4)
        let tieLow = at(pr("tieLow", roles: [.commenter]), 5, number: 5), tieHigh = at(pr("tieHigh", roles: [.commenter]), 5, number: 6)
        let ids = Attention.sorted([tieLow, older, recent, unread, tieHigh, review]).map(\.id)
        XCTAssertEqual(ids, ["review", "recent", "older", "unread", "tieHigh", "tieLow"])  // unread is no rank of its own

        // A reason switched off in Settings no longer ranks first.
        XCTAssertEqual(Attention.sorted([unread, review], counting: [.ciFailed]).map(\.id), ["unread", "review"])

        // Done: latest activity (closed or updated) first, unread or not.
        var mergedOld = at(pr("mergedOld", roles: [.author], events: [(t0.addingTimeInterval(100), false)]), 0, number: 7)
        mergedOld.state = .merged
        var closedNew = at(pr("closedNew", roles: [.author]), 0, number: 8)
        closedNew.state = .closed
        closedNew.closedAt = t0.addingTimeInterval(200)
        XCTAssertEqual(Attention.sorted([mergedOld, closedNew]).map(\.id), ["closedNew", "mergedOld"])
    }

    // MARK: 0.7.0 buckets (design §3.3), reasons (§3.4), edge cases (§3.5)

    /// My open pull request: approved, CI green, clean, on head h2, no auto-merge. Each test bends one field.
    func minePR(_ id: String = "M", _ change: (inout TrackedPR) -> Void = { _ in }) -> TrackedPR {
        var p = pr(id, roles: [.author])
        p.headOID = "h2"
        p.reviewDecision = "APPROVED"
        p.ci = .success
        p.mergeState = "CLEAN"
        p.autoMerge = false
        change(&p)
        return p
    }

    /// Someone else's open pull request on head h2.
    func theirs(_ roles: Set<Role>, id: String = "T", review: String? = nil, on commit: String? = "h1",
                _ change: (inout TrackedPR) -> Void = { _ in }) -> TrackedPR {
        var p = pr(id, roles: roles)
        p.authorLogin = "bob"
        p.headOID = "h2"
        p.autoMerge = false
        p.myReview = review.map { MyReview(state: $0, commitOID: commit, submittedAt: t0) }
        change(&p)
        return p
    }

    func issue(_ roles: Set<Role>) -> TrackedPR {
        var p = pr("I", roles: roles)
        p.isIssue = true
        return p
    }

    func testBucketsOfMyPullRequests() {
        XCTAssertEqual(Attention.bucket(minePR()), .merge)  // rule 6
        XCTAssertEqual(Attention.bucket(minePR { $0.ci = .none }), .merge, "no CI at all: ready to merge (was never ready)")
        XCTAssertEqual(Attention.bucket(minePR { $0.mergeState = "HAS_HOOKS" }), .merge)
        XCTAssertEqual(Attention.bucket(minePR { $0.state = .merged }), .closed)  // rule 1
        XCTAssertEqual(Attention.bucket(minePR { $0.isDraft = true; $0.ci = .failure }), .draft)  // rule 3 before 4
        // Rule 4: changes requested, CI failed, conflicts, approved and green but behind under strict protection.
        XCTAssertEqual(Attention.bucket(minePR { $0.reviewDecision = "CHANGES_REQUESTED" }), .fix)
        XCTAssertEqual(Attention.bucket(minePR { $0.ci = .failure }), .fix)
        XCTAssertEqual(Attention.bucket(minePR { $0.reviewDecision = "REVIEW_REQUIRED"; $0.mergeState = "DIRTY" }), .fix)
        XCTAssertEqual(Attention.bucket(minePR { $0.mergeState = "BEHIND" }), .fix)
        XCTAssertEqual(Attention.bucket(minePR { $0.mergeState = "BEHIND"; $0.reviewDecision = "REVIEW_REQUIRED" }), .waitingReview, "unapproved behind waits")
        XCTAssertEqual(Attention.bucket(minePR { $0.autoMerge = true; $0.ci = .failure }), .fix, "rule 4 before 5")
        XCTAssertEqual(Attention.bucket(minePR { $0.autoMerge = true; $0.mergeState = "BEHIND" }), .waitingMerge, "the queue updates the branch itself")
        XCTAssertEqual(Attention.bucket(minePR { $0.autoMerge = true; $0.mergeState = "DIRTY" }), .fix, "a conflict is still mine")
        XCTAssertEqual(Attention.bucket(minePR { $0.autoMerge = true; $0.ci = .pending }), .waitingMerge)  // rule 5
        XCTAssertEqual(Attention.bucket(minePR { $0.autoMerge = true }), .waitingMerge, "auto-merge on: nothing for me to do")
        // Rule 7: CI running, approved or no review asked.
        XCTAssertEqual(Attention.bucket(minePR { $0.ci = .pending }), .waitingCI)
        XCTAssertEqual(Attention.bucket(minePR { $0.ci = .pending; $0.reviewDecision = nil }), .waitingCI)
        XCTAssertEqual(Attention.bucket(minePR { $0.ci = .pending; $0.reviewDecision = nil
            $0.reviewers = [ReviewSummary(login: "alice", state: "", submittedAt: nil, requested: true)] }), .waitingReview)
        XCTAssertEqual(Attention.bucket(minePR { $0.ci = .pending; $0.reviewDecision = nil; $0.requestedTeams = ["core"] }), .waitingReview)
        XCTAssertEqual(Attention.bucket(minePR { $0.ci = .pending; $0.reviewDecision = "REVIEW_REQUIRED" }), .waitingReview)
        // Rule 8: no deciding review yet, or approved but still blocked; merge state not computed yet.
        XCTAssertEqual(Attention.bucket(minePR { $0.reviewDecision = "REVIEW_REQUIRED" }), .waitingReview)
        XCTAssertEqual(Attention.bucket(minePR { $0.mergeState = "BLOCKED" }), .waitingReview)
        XCTAssertEqual(Attention.bucket(minePR { $0.mergeState = "UNKNOWN" }), .waitingReview, "UNKNOWN: neither conflict nor mergeable")
        XCTAssertEqual(Attention.bucket(minePR { $0.autoMerge = nil }), .merge, "not yet backfilled reads as no auto-merge")
        // My own (comment) review on my pull request is ignored.
        XCTAssertEqual(Attention.bucket(minePR { $0.myReview = MyReview(state: "COMMENTED", commitOID: "h1", submittedAt: t0) }), .merge)
    }

    /// No required reviews (`reviewDecision` nil): the reviewers' latest deciding reviews decide.
    func testDecisionFallsBackToReviewers() {
        func reviewed(_ states: [String]) -> TrackedPR {
            minePR { p in
                p.reviewDecision = nil
                p.reviewers = states.enumerated().map { ReviewSummary(login: "r\($0)", state: $1, submittedAt: t0, requested: false) }
            }
        }
        XCTAssertEqual(Attention.bucket(reviewed(["APPROVED"])), .merge)
        XCTAssertEqual(Attention.bucket(reviewed(["APPROVED", "CHANGES_REQUESTED"])), .fix)
        XCTAssertEqual(Attention.bucket(reviewed(["COMMENTED"])), .waitingReview)
        XCTAssertEqual(Attention.decision(reviewed([])), nil)
        XCTAssertEqual(Attention.decision(minePR { $0.reviewDecision = "REVIEW_REQUIRED" }), "REVIEW_REQUIRED")  // GitHub's own wins
    }

    func testBucketsOfOthersPullRequests() {
        XCTAssertEqual(Attention.bucket(theirs([.reviewRequested])), .review)  // rule 9
        XCTAssertEqual(Attention.bucket(theirs([.reviewRequested], review: "APPROVED", on: "h2")), .reReview, "rule 10: re-requested after I approved")
        XCTAssertEqual(Attention.bucket(theirs([.reviewRequested, .teamReviewRequested])), .review, "direct beats team")
        // Rule 11: I requested changes, or my review was dismissed, and the head moved; no re-request needed.
        XCTAssertEqual(Attention.bucket(theirs([.reviewer], review: "CHANGES_REQUESTED")), .reReview)
        XCTAssertEqual(Attention.bucket(theirs([.reviewer], review: "DISMISSED")), .reReview)
        XCTAssertEqual(Attention.bucket(theirs([.reviewer], review: "CHANGES_REQUESTED", on: nil)), .reReview, "force-push removed my commit")
        XCTAssertEqual(Attention.bucket(theirs([.reviewer], review: "CHANGES_REQUESTED", on: "h2")), .reviewed, "not moved: their turn")
        XCTAssertEqual(Attention.bucket(theirs([.reviewer], review: "DISMISSED", on: "h2")), .reviewed, "dismissed, head not moved yet")
        XCTAssertEqual(Attention.bucket(theirs([.reviewer], review: "APPROVED")), .reviewed, "approved, they pushed: a chip, not a to-do")
        XCTAssertEqual(Attention.bucket(theirs([.reviewer], review: "COMMENTED")), .reviewed, "commented only, they pushed")
        XCTAssertEqual(Attention.bucket(theirs([.teamReviewRequested])), .teamReview)  // rule 12
        XCTAssertEqual(Attention.bucket(theirs([.teamReviewRequested], review: "CHANGES_REQUESTED")), .reReview, "rule 11 before 12")
        XCTAssertEqual(Attention.bucket(theirs([.reviewer])), .reviewed, "rule 13: reviewed before 0.7.0 (no myReview yet)")
        XCTAssertEqual(Attention.bucket(theirs([], review: "COMMENTED", on: "h2")), .reviewed)
        XCTAssertEqual(Attention.bucket(theirs([.commenter, .mentioned])), .watching)  // rule 14
        XCTAssertEqual(Attention.bucket(theirs([.assigned])), .watching, "someone else's pull request assigned to me")
        // Team request satisfied by a teammate: GitHub drops it.
        XCTAssertEqual(Attention.bucket(theirs([.commenter])), .watching)
        // Drafts can't be reviewed: requests wait for Ready for review.
        XCTAssertEqual(Attention.bucket(theirs([.reviewRequested]) { $0.isDraft = true }), .watching)
        XCTAssertEqual(Attention.bucket(theirs([.reviewRequested], review: "CHANGES_REQUESTED") { $0.isDraft = true }), .reviewed)
        XCTAssertEqual(Attention.bucket(theirs([.teamReviewRequested]) { $0.isDraft = true }), .watching)
        XCTAssertEqual(Attention.bucket(theirs([.reviewRequested]) { $0.state = .closed }), .closed)
    }

    func testBucketsOfIssues() {
        XCTAssertEqual(Attention.bucket(issue([.assigned, .author])), .issueAssigned)
        XCTAssertEqual(Attention.bucket(issue([.author])), .issueMine)
        XCTAssertEqual(Attention.bucket(issue([.mentioned])), .issueMentioned)
        var closed = issue([.assigned])
        closed.state = .closed
        XCTAssertEqual(Attention.bucket(closed), .closed)
    }

    func testNeedReasonsFollowTheBucket() {
        func unread(_ p: TrackedPR, _ kinds: EventKind...) -> TrackedPR {
            var p = p
            p.events = kinds.enumerated().map { PREvent(id: "u\($0)", prID: p.id, kind: $1, actor: "alice", at: t0, summary: "", url: nil, isOwn: false) }
            return p
        }
        XCTAssertEqual(Attention.needReason(theirs([.reviewRequested])), .toReview)  // 1
        XCTAssertEqual(Attention.needReason(theirs([.reviewer], review: "CHANGES_REQUESTED")), .reReview)  // 2
        XCTAssertEqual(Attention.needReason(minePR { $0.reviewDecision = "CHANGES_REQUESTED"; $0.ci = .failure }), .changesRequested)  // 3
        XCTAssertEqual(Attention.needReason(minePR { $0.ci = .failure; $0.mergeState = "DIRTY" }), .ciFailed)  // 4
        XCTAssertEqual(Attention.needReason(minePR { $0.mergeState = "DIRTY" }), .conflicts)  // 5
        XCTAssertEqual(Attention.needReason(minePR { $0.mergeState = "BEHIND" }), .conflicts, "approved and behind: update branch")
        XCTAssertEqual(Attention.needReason(unread(theirs([.commenter]), .comment, .mentioned)), .mentioned)  // 6
        XCTAssertEqual(Attention.needReason(unread(theirs([.assigned]), .assigned)), .assigned)  // 7
        XCTAssertEqual(Attention.needReason(unread(minePR { $0.reviewDecision = "REVIEW_REQUIRED" }, .comment)), .newComments)  // 8: waiting, unread
        XCTAssertEqual(Attention.needReason(unread(minePR { $0.autoMerge = true }, .reviewCommented)), .newComments)
        XCTAssertNil(Attention.needReason(unread(theirs([.commenter]), .comment)), "others' chatter")
        XCTAssertEqual(Attention.needReason(minePR()), .readyToMerge)  // 9
        XCTAssertEqual(Attention.needReason(theirs([.teamReviewRequested])), .teamToReview)  // 10
        // Waiting on others, Reviewed, Watching and drafts need nothing until something unread arrives.
        for p in [minePR { $0.reviewDecision = "REVIEW_REQUIRED" }, minePR { $0.ci = .pending }, minePR { $0.autoMerge = true },
                  minePR { $0.isDraft = true; $0.reviewDecision = "CHANGES_REQUESTED" }, theirs([.reviewer], review: "APPROVED"), theirs([.commenter])] {
            XCTAssertNil(Attention.needReason(p), "\(Attention.bucket(p))")
        }
        // Precedence: direct review beats a mention; a new comment beats ready to merge; switched-off reasons fall through.
        XCTAssertEqual(Attention.needReason(unread(theirs([.reviewRequested]), .mentioned)), .toReview)
        XCTAssertEqual(Attention.needReason(unread(minePR(), .comment)), .newComments)
        let both = minePR { $0.reviewDecision = "CHANGES_REQUESTED"; $0.ci = .failure }
        XCTAssertEqual(Attention.needReason(both, counting: [.ciFailed, .conflicts]), .ciFailed)
        XCTAssertNil(Attention.needReason(both, counting: [.conflicts]), "conflicts only when the branch really conflicts")
        XCTAssertNil(Attention.needReason(theirs([.teamReviewRequested]), counting: [.toReview]))
        // Muted, hidden and closed never need me.
        XCTAssertNil(Attention.needReason(minePR { $0.muted = true }))
        XCTAssertNil(Attention.needReason(minePR { $0.hidden = true }))
        XCTAssertNil(Attention.needReason(theirs([.reviewRequested]) { $0.state = .merged }))
    }

    func testNeedsMeQueuesOldestFirstByReason() {
        func at(_ p: TrackedPR, number: Int, event kind: EventKind? = nil, _ seconds: Double) -> TrackedPR {
            var p = p
            p.number = number
            p.updatedAt = t0.addingTimeInterval(1000)  // fresher than every event: the event decides when it started waiting
            p.events = kind.map { [PREvent(id: "e", prID: p.id, kind: $0, actor: "alice", at: t0.addingTimeInterval(seconds), summary: "", url: nil, isOwn: true)] } ?? []
            return p
        }
        let newReview = at(theirs([.reviewRequested], id: "newReview"), number: 1, event: .reviewRequested, 300)
        let oldReview = at(theirs([.reviewRequested], id: "oldReview"), number: 2, event: .reviewRequested, 100)
        let reReview = at(theirs([.reviewer], id: "reReview", review: "CHANGES_REQUESTED"), number: 3, event: .newCommits, 50)
        let ready = at(minePR("ready"), number: 4, event: .ciPassed, 0)
        let ciFailed = at(minePR("ciFailed") { $0.ci = .failure }, number: 5, event: .ciFailed, 200)
        let waiting = at(minePR("waiting") { $0.reviewDecision = "REVIEW_REQUIRED" }, number: 6, 0)
        let ids = Attention.sorted([ready, waiting, reReview, ciFailed, newReview, oldReview]).map(\.id)
        XCTAssertEqual(ids, ["oldReview", "newReview", "reReview", "ciFailed", "ready", "waiting"])
        XCTAssertEqual(Attention.waitingSince(ciFailed, .ciFailed), t0.addingTimeInterval(200))
        XCTAssertEqual(Attention.waitingSince(waiting, .ciFailed), t0.addingTimeInterval(1000), "no causing event: updatedAt")
        XCTAssertEqual(Attention.breakdown([ready, waiting, reReview, ciFailed, newReview, oldReview]),
                       "2 to review · 1 to re-review · 1 CI failed · 1 ready to merge")
    }

    func testBadgeCountsTheNewReasons() {
        let id = UUID()
        func on(_ p: TrackedPR) -> TrackedPR { var p = p; p.accountID = id; return p }
        let prs = [on(theirs([.reviewer], review: "CHANGES_REQUESTED")), on(minePR { $0.mergeState = "DIRTY" }),
                   on(minePR { $0.ci = .pending }), on(theirs([.reviewer], review: "APPROVED"))]
        XCTAssertEqual(Attention.badgeCount(prs, enabledAccounts: [id], mode: .needsMe), 2)
        XCTAssertEqual(Attention.badgeCount(prs, enabledAccounts: [id], mode: .needsMe, counting: [.reReview]), 1)
        XCTAssertEqual(Attention.breakdown(prs), "1 to re-review · 1 with conflicts")
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

    func event(_ kind: EventKind, own: Bool = false, at: Date = t0) -> PREvent {
        PREvent(id: "\(kind)", prID: "X", kind: kind, actor: own ? "dana" : "alice", at: at, summary: "", url: nil, isOwn: own)
    }

    func testIsNew() {
        XCTAssertTrue(Attention.isNew(pr(events: [(t0, false)]), now: t0))
        XCTAssertFalse(Attention.isNew(pr(events: [(t0, true)]), now: t0), "my own actions are never new")
        var seeded = pr(events: [(t0, false)])
        seeded.lastReadAt = t0  // seeded history and the account baseline: read
        XCTAssertFalse(Attention.isNew(seeded, now: t0))
        var p = pr(events: [(t0, false)])
        p.muted = true
        XCTAssertFalse(Attention.isNew(p, now: t0))
        p.muted = false
        p.hidden = true
        XCTAssertFalse(Attention.isNew(p, now: t0))
        p.hidden = false
        p.snoozedUntil = t0.addingTimeInterval(60)
        XCTAssertFalse(Attention.isNew(p, now: t0), "snoozed: no group dot")
        XCTAssertTrue(Attention.isNew(p, now: t0.addingTimeInterval(60)), "the snooze ended: back without a new event")
        XCTAssertTrue(Attention.unread(p) > 0, "the row's own dot ignores the snooze")
        var merged = minePR { $0.state = .merged }
        merged.events = [event(.merged)]
        XCTAssertTrue(Attention.isNew(merged, now: t0), "merged by someone else is news")
    }

    /// Every bucket keys its own items; a neutral unread event adds `new` without changing `needs`.
    func testSignalsPerBucket() {
        let fixtures: [(Bucket, TrackedPR, needs: Bool)] = [
            (.fix, minePR("1") { $0.ci = .failure }, true), (.merge, minePR("2"), true),
            (.waitingReview, minePR("3") { $0.reviewDecision = "REVIEW_REQUIRED" }, false),
            (.waitingCI, minePR("4") { $0.ci = .pending }, false), (.waitingMerge, minePR("5") { $0.autoMerge = true }, false),
            (.draft, minePR("6") { $0.isDraft = true }, false),
            (.review, theirs([.reviewRequested], id: "7"), true), (.reReview, theirs([.reviewer], id: "8", review: "CHANGES_REQUESTED"), true),
            (.teamReview, theirs([.teamReviewRequested], id: "9"), true), (.reviewed, theirs([.reviewer], id: "10", review: "APPROVED"), false),
            (.issueAssigned, issue([.assigned]), false), (.issueMine, issue([.author]), false), (.issueMentioned, issue([.mentioned]), false),
            (.watching, theirs([.commenter], id: "14"), false), (.closed, theirs([.commenter], id: "15") { $0.state = .closed }, false),
        ]
        XCTAssertEqual(Set(fixtures.map(\.0)), Set(Bucket.allCases))
        for (bucket, read, needs) in fixtures {
            XCTAssertEqual(Attention.bucket(read), bucket)
            XCTAssertEqual(Attention.signals([read], now: t0), needs ? [bucket: Signal(needs: 1)] : [:], "\(bucket) read")
            var labeled = read
            labeled.events = [event(.labeled)]
            XCTAssertEqual(Attention.signals([labeled], now: t0), [bucket: Signal(needs: needs ? 1 : 0, new: 1, newNeeds: needs ? 1 : 0)], "\(bucket) new")
        }
    }

    func testSignalsNeedAndNewAreIndependent() {
        var newReview = theirs([.reviewRequested], id: "R2")
        newReview.events = [event(.reviewRequested)]
        var watching = theirs([.commenter], id: "W")
        watching.events = [event(.comment)]
        var waiting = minePR("C") { $0.reviewDecision = "REVIEW_REQUIRED" }
        waiting.events = [event(.comment)]  // my pull request, someone commented: counts (new comments) and is new
        var muted = newReview
        muted.muted = true
        var snoozed = watching
        snoozed.snoozedUntil = t0.addingTimeInterval(60)
        let all = [theirs([.reviewRequested], id: "R"), newReview, watching, waiting, muted, snoozed, minePR("F") { $0.ci = .failure }]
        XCTAssertEqual(Attention.signals(all, now: t0), [.review: Signal(needs: 2, new: 1, newNeeds: 1), .watching: Signal(new: 1),
                                                          .waitingReview: Signal(needs: 1, new: 1, newNeeds: 1), .fix: Signal(needs: 1)])
        XCTAssertEqual(Attention.signals(all, counting: [.ciFailed], now: t0), [.review: Signal(new: 1), .watching: Signal(new: 1),
                                                                                 .waitingReview: Signal(new: 1), .fix: Signal(needs: 1)],
                       "a reason switched off lowers needs only")
        XCTAssertEqual(Attention.signals(all, now: t0.addingTimeInterval(60))[.watching], Signal(new: 2), "the snooze ended")
    }

    func testSignalBadgeSpokenAndSum() {
        XCTAssertEqual([Signal(needs: 3, new: 2), Signal(needs: 3), Signal(new: 2), Signal()].map(\.badge), ["3 •", "3", "•", nil])
        XCTAssertEqual([Signal(needs: 3, new: 2), Signal(needs: 3), Signal(new: 2), Signal()].map(\.spoken),
                       ["3 need you, 2 new", "3 need you", "2 new", ""])
        XCTAssertEqual(Signal(needs: 1, new: 2, newNeeds: 1) + Signal(needs: 2, new: 0), Signal(needs: 3, new: 2, newNeeds: 1))
    }

    // MARK: Mark as Unread, Remind Me, sticky rows

    func event(_ kind: EventKind, at: Date, own: Bool = false, id: String = UUID().uuidString) -> PREvent {
        PREvent(id: id, prID: "PR_1", kind: kind, actor: own ? me : "alice", at: at, summary: "", url: nil, isOwn: own)
    }

    func testMarkedUnreadLightsTheItem() {
        var p = pr()
        p.markedUnread = true
        XCTAssertEqual(Attention.unread(p), 1)
        XCTAssertTrue(Attention.isNew(p, now: t0))
        XCTAssertEqual(Attention.badgeCount([p], enabledAccounts: [p.accountID], mode: .allUnread), 1)
        XCTAssertNil(Attention.needReason(p), "the flag alone adds no reason")
        Attention.markRead(&p, now: t0)
        XCTAssertFalse(p.markedUnread)
        XCTAssertEqual(p.lastReadAt, t0)
        XCTAssertEqual(Attention.unread(p), 0)
    }

    func testMarkUnreadBringsBackAReadMention() {
        var p = pr()
        p.events = [event(.mentioned, at: t0), event(.comment, at: t0.addingTimeInterval(60), own: true)]
        Attention.markRead(&p, now: t0.addingTimeInterval(120))
        XCTAssertNil(Attention.needReason(p))
        Attention.markUnread(&p)
        XCTAssertTrue(p.markedUnread)
        XCTAssertEqual(p.lastReadAt, t0.addingTimeInterval(-1), "just before the newest event by someone else")
        XCTAssertEqual(Attention.needReason(p), .mentioned)
        XCTAssertEqual(Attention.unread(p), 1)
    }

    func testMarkUnreadBringsBackAMentionFollowedByACommentAndCI() {
        var p = pr(roles: [.commenter])
        var ci = event(.ciFailed, at: t0.addingTimeInterval(120))
        ci.actor = "CI"
        p.events = [event(.mentioned, at: t0), event(.comment, at: t0.addingTimeInterval(60)), ci]
        Attention.markRead(&p, now: t0.addingTimeInterval(180))
        XCTAssertNil(Attention.needReason(p))
        Attention.markUnread(&p)
        XCTAssertEqual(p.lastReadAt, t0.addingTimeInterval(-1), "just before the mention, not the later comment or CI")
        XCTAssertEqual(Attention.needReason(p), .mentioned)
        XCTAssertEqual(Attention.unread(p), 3)
    }

    func testMarkUnreadOnMineRewindsToTheCommentNotTheLaterPush() {
        var p = pr(roles: [.author])
        p.events = [event(.comment, at: t0), event(.newCommits, at: t0.addingTimeInterval(60))]
        Attention.markRead(&p, now: t0.addingTimeInterval(120))
        Attention.markUnread(&p)
        XCTAssertEqual(p.lastReadAt, t0.addingTimeInterval(-1))
        XCTAssertEqual(Attention.needReason(p), .newComments)
    }

    func testMarkUnreadWithoutAReasonEventRewindsToTheNewestByOthers() {
        var p = pr(roles: [.commenter])
        p.events = [event(.comment, at: t0), event(.newCommits, at: t0.addingTimeInterval(60))]
        Attention.markRead(&p, now: t0.addingTimeInterval(120))
        Attention.markUnread(&p)
        XCTAssertEqual(p.lastReadAt, t0.addingTimeInterval(59), "a comment on someone else's item gives no reason")
        XCTAssertNil(Attention.needReason(p))
        XCTAssertEqual(Attention.unread(p), 1)
    }

    func testMarkUnreadLeavesAnUnreadItemsReadMarkAlone() {
        var p = pr()
        p.events = [event(.comment, at: t0), event(.mentioned, at: t0.addingTimeInterval(60))]
        p.lastReadAt = t0.addingTimeInterval(30)
        Attention.markUnread(&p)
        XCTAssertEqual(p.lastReadAt, t0.addingTimeInterval(30))
        XCTAssertTrue(p.markedUnread)
    }

    func testMarkUnreadOnOwnEventsOnlySetsTheFlag() {
        var p = pr(roles: [.author])
        p.events = [event(.comment, at: t0, own: true)]
        p.lastReadAt = t0.addingTimeInterval(10)
        Attention.markUnread(&p)
        XCTAssertEqual(p.lastReadAt, t0.addingTimeInterval(10))
        XCTAssertTrue(p.markedUnread)
        XCTAssertEqual(Attention.unread(p), 1)
    }

    func testReminderReason() {
        var p = pr(roles: [.commenter])
        p.events = [event(.reminder, at: t0)]
        XCTAssertTrue(Attention.reminderDue(p))
        XCTAssertEqual(Attention.needReason(p), .reminder)
        XCTAssertEqual(Attention.breakdown([p]), "1 reminder due")
        XCTAssertEqual(Attention.waitingSince(p, .reminder), t0)
        var muted = p
        muted.muted = true
        XCTAssertNil(Attention.needReason(muted))
        var review = p
        review.roles = [.reviewRequested]
        XCTAssertEqual(Attention.needReason(review), .toReview, "a higher reason wins")
        Attention.markRead(&p, now: t0.addingTimeInterval(1))
        XCTAssertFalse(Attention.reminderDue(p))
        XCTAssertNil(Attention.needReason(p))
        Attention.markUnread(&p)
        XCTAssertEqual(Attention.needReason(p), .reminder, "Mark as Unread brings it back")
    }

    func testKeeping() {
        let a = pr("A"), b = pr("B"), c = pr("C"), d = pr("D")
        let order = ["A", "B", "C"]
        XCTAssertEqual(Attention.keeping([a, c], [b], order: order).map(\.id), ["A", "B", "C"], "middle row stays in place")
        XCTAssertEqual(Attention.keeping([b, c], [a], order: order).map(\.id), ["A", "B", "C"], "first row stays first")
        XCTAssertEqual(Attention.keeping([a, b, c], [b], order: order).map(\.id), ["A", "B", "C"], "no duplicate")
        XCTAssertEqual(Attention.keeping([a, c], [d], order: order).map(\.id), ["D", "A", "C"], "unknown id goes first")
        XCTAssertEqual(Attention.keeping([a], [c, b], order: order).map(\.id), ["A", "B", "C"], "two kept, any order")
    }
}
