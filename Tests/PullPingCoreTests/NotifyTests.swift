import XCTest
@testable import PullPingCore

/// The 0.7.0 rule: an event pops a panel only when it puts (or keeps) the item in Needs Me.
final class NotifyTests: XCTestCase {
    func event(_ kind: EventKind, summary: String = "", own: Bool = false) -> PREvent {
        PREvent(id: "E", prID: "P", kind: kind, actor: own ? me : "alice", at: t0, summary: summary, url: nil, isOwn: own)
    }

    /// My open pull request on head h2: approved, CI green, clean.
    func mine(_ change: (inout TrackedPR) -> Void = { _ in }) -> TrackedPR {
        var p = TrackedPR(id: "P", accountID: UUID(), firstTrackedAt: t0)
        p.roles = [.author]
        p.headOID = "h2"
        p.reviewDecision = "APPROVED"
        p.ci = .success
        p.mergeState = "CLEAN"
        p.autoMerge = false
        change(&p)
        return p
    }

    func theirs(_ roles: Set<Role>, review: String? = nil, on commit: String = "h1") -> TrackedPR {
        var p = TrackedPR(id: "P", accountID: UUID(), firstTrackedAt: t0)
        p.roles = roles
        p.authorLogin = "bob"
        p.headOID = "h2"
        p.myReview = review.map { MyReview(state: $0, commitOID: commit, submittedAt: t0) }
        return p
    }

    func reason(_ e: PREvent, _ pr: TrackedPR) -> NeedReason? { Notify.reason(e, pr: pr) }

    func testReviewRequests() {
        XCTAssertEqual(reason(event(.reviewRequested), theirs([.reviewRequested])), .toReview)
        XCTAssertEqual(reason(event(.reviewRequested), theirs([.reviewRequested], review: "APPROVED", on: "h2")), .reReview)
        XCTAssertEqual(reason(event(.reviewRequested, summary: "via team core"), theirs([.teamReviewRequested])), .teamToReview)
        XCTAssertEqual(reason(event(.reviewReminder), theirs([.reviewRequested])), .toReview)
        XCTAssertEqual(reason(event(.reviewReminder), theirs([.reviewer], review: "CHANGES_REQUESTED")), .reReview)
        XCTAssertEqual(reason(event(.reviewReminder), theirs([.teamReviewRequested])), .teamToReview)
        XCTAssertEqual(reason(event(.readyForReview), theirs([.reviewRequested])), .toReview)
        XCTAssertNil(reason(event(.readyForReview), theirs([.commenter])))
    }

    /// A new issue in a repository I watch is to triage; comments on it are mine to answer, as on my own issues.
    func testIssuesInMyRepositories() {
        var watched = theirs([])
        (watched.isIssue, watched.watched) = (true, true)
        XCTAssertEqual(reason(event(.issueOpened), watched), .toTriage)
        XCTAssertEqual(reason(event(.comment), watched), .newComments)
        XCTAssertNil(reason(event(.issueOpened, own: true), watched))
        watched.watched = false
        XCTAssertNil(reason(event(.comment), watched), "an issue I only follow: Activity only")
    }

    func testPushesAndDismissalsOnlyForReReview() {
        XCTAssertEqual(reason(event(.newCommits), theirs([.reviewer], review: "CHANGES_REQUESTED")), .reReview)  // pushed since my review
        XCTAssertEqual(reason(event(.reviewDismissed), theirs([.reviewer], review: "DISMISSED")), .reReview)
        XCTAssertNil(reason(event(.newCommits), theirs([.reviewer], review: "APPROVED")), "approved, they pushed")
        XCTAssertNil(reason(event(.newCommits), theirs([.reviewer], review: "COMMENTED")), "commented only, they pushed")
        XCTAssertNil(reason(event(.newCommits), mine { $0.reviewDecision = "REVIEW_REQUIRED" }))
        XCTAssertNil(reason(event(.reviewDismissed), theirs([.commenter])), "a review dismissed elsewhere")
    }

    func testMyPullRequest() {
        XCTAssertEqual(reason(event(.reviewChangesRequested), mine { $0.reviewDecision = "CHANGES_REQUESTED" }), .changesRequested)
        XCTAssertEqual(reason(event(.ciFailed), mine { $0.ci = .failure }), .ciFailed)
        XCTAssertEqual(reason(event(.conflicts), mine { $0.mergeState = "DIRTY" }), .conflicts)
        XCTAssertEqual(reason(event(.comment), mine()), .newComments)
        XCTAssertEqual(reason(event(.reviewCommented), mine()), .newComments)
        XCTAssertEqual(reason(event(.ciPassed), mine()), .readyToMerge)
        XCTAssertEqual(reason(event(.reviewApproved), mine()), .readyToMerge)
        XCTAssertNil(reason(event(.reviewApproved), mine { $0.ci = .pending }), "approved while CI is still running")
        XCTAssertNil(reason(event(.ciPassed), mine { $0.reviewDecision = "REVIEW_REQUIRED" }), "CI passed, not mergeable yet")
        XCTAssertNil(reason(event(.ciPassed), mine { $0.autoMerge = true }), "auto-merge on")
        for kind in [EventKind.merged, .closed, .reopened, .labeled, .retitled, .convertedToDraft, .newCommits] {
            XCTAssertNil(reason(event(kind), mine()), kind.rawValue)
        }
    }

    func testOthersPullRequestsAndMentions() {
        for kind in [EventKind.comment, .reviewCommented, .reviewChangesRequested, .ciFailed, .conflicts, .ciPassed, .merged] {
            XCTAssertNil(reason(event(kind), theirs([.reviewer], review: "APPROVED", on: "h2")), kind.rawValue)
        }
        XCTAssertEqual(reason(event(.mentioned), theirs([.commenter])), .mentioned)
        XCTAssertEqual(reason(event(.assigned), theirs([.assigned])), .assigned)
        var issue = theirs([.assigned])
        issue.isIssue = true
        XCTAssertEqual(reason(event(.comment), issue), .newComments, "an issue assigned to me")
    }

    func testOwnEventsNeverAsk() {
        XCTAssertNil(reason(event(.comment, own: true), mine()))
        XCTAssertNil(reason(event(.reviewRequested, own: true), theirs([.reviewRequested])))
    }

    /// A Remind Me reminder asks for me on any item; it never chooses an agent task of its own.
    func testReminder() {
        XCTAssertEqual(reason(event(.reminder), mine()), .reminder)
        XCTAssertEqual(reason(event(.reminder), theirs([.commenter])), .reminder)
        XCTAssertEqual(Scenario.derive(events: [event(.reminder)], pr: theirs([.commenter])), .general)
    }
}
