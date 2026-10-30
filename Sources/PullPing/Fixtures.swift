import Foundation
import PullPingCore

/// Generic sample data for `PULLPING_DEMO=1` and the README screenshots. Memory only: never saved.
@MainActor
enum Fixtures {
    static let personal = Account(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, login: "dana", label: "Personal")
    static let work = Account(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, login: "dana-work", label: "Work")

    static func sampleStore(now: Date = Date()) -> Store {
        let store = Store(state: StateStore(url: nil), accounts: [personal, work], settings: AppSettings(), persist: false)
        store.setTracked { state in
            for pr in samplePRs(now: now) { state.prs[pr.id] = pr }
            state.lastPollAt = [personal.id: now.addingTimeInterval(-120), work.id: now.addingTimeInterval(-120)]
            state.baselinedAccounts = [personal.id, work.id]
        }
        store.statuses = [personal.id: .ok, work.id: .ok]
        return store
    }

    /// One banner (approved, mine), one alert (CI failed, mine), one review request (someone else's).
    static func demoEvents(_ store: Store) -> [PREvent] {
        ["PR_1", "PR_2", "PR_3"].compactMap { store.tracked.prs[$0]?.events.last }
    }

    private static func samplePRs(now: Date) -> [TrackedPR] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func pr(_ id: String, _ account: Account, _ repo: String, _ number: Int, _ title: String, author: String,
                roles: Set<Role>, edit: (inout TrackedPR) -> Void) -> TrackedPR {
            var pr = TrackedPR(id: id, accountID: account.id, firstTrackedAt: ago(3000))
            pr.repo = repo
            pr.number = number
            pr.title = title
            pr.url = URL(string: "https://github.com/\(repo)/pull/\(number)")!
            pr.authorLogin = author
            pr.roles = roles
            pr.mergeState = "CLEAN"
            pr.lastReadAt = ago(600)
            edit(&pr)
            pr.updatedAt = pr.events.last?.at ?? ago(900)
            return pr
        }
        func event(_ id: String, _ prID: String, _ kind: EventKind, _ actor: String, _ minutes: Double, _ summary: String, own: Bool = false) -> PREvent {
            PREvent(id: id, prID: prID, kind: kind, actor: actor, at: ago(minutes), summary: summary, url: nil, isOwn: own)
        }
        return [
            pr("PR_1", personal, "octo-org/widgets", 123, "Add retry with backoff to the sync worker", author: "dana", roles: [.author]) {
                $0.reviewDecision = "APPROVED"
                $0.ci = .success
                $0.checks = [CheckSummary(name: "build", state: .success, url: nil), CheckSummary(name: "test (macos-14)", state: .success, url: nil)]
                $0.reviewers = [ReviewSummary(login: "alice", state: "APPROVED", submittedAt: ago(5), requested: false),
                                ReviewSummary(login: "bob", state: "COMMENTED", submittedAt: ago(90), requested: false)]
                $0.events = [event("E1", "PR_1", .newCommits, "dana", 240, "", own: true),
                             event("E2", "PR_1", .reviewCommented, "bob", 90, "left 2 comments"),
                             event("E3", "PR_1", .reviewApproved, "alice", 5, "Looks good, thanks for the tests.")]
            },
            pr("PR_2", personal, "octo-org/widgets", 128, "Fix flaky date parsing test on time zone change", author: "dana", roles: [.author]) {
                $0.reviewDecision = "CHANGES_REQUESTED"
                $0.ci = .failure
                $0.mergeState = "BLOCKED"
                $0.checks = [CheckSummary(name: "build", state: .success, url: nil), CheckSummary(name: "test (macos-14)", state: .failure, url: nil)]
                $0.reviewers = [ReviewSummary(login: "carol", state: "CHANGES_REQUESTED", submittedAt: ago(40), requested: false)]
                $0.events = [event("E4", "PR_2", .reviewChangesRequested, "carol", 40, "Please cover the DST edge case too."),
                             event("E5", "PR_2", .ciFailed, "CI", 2, "test (macos-14) failed")]
            },
            pr("PR_3", work, "octo-org/gadgets", 57, "Bump build tools to 2.4", author: "carol", roles: [.reviewRequested]) {
                $0.reviewDecision = "REVIEW_REQUIRED"
                $0.ci = .pending
                $0.mergeState = "BLOCKED"
                $0.checks = [CheckSummary(name: "build", state: .pending, url: nil)]
                $0.reviewers = [ReviewSummary(login: "dana-work", state: "", submittedAt: nil, requested: true)]
                $0.requestedTeams = ["platform"]
                $0.events = [event("E6", "PR_3", .reviewRequested, "carol", 1, "carol requested your review")]
            },
            pr("PR_4", personal, "octo-org/widgets", 131, "New settings layout", author: "dana", roles: [.author]) {
                $0.isDraft = true
                $0.ci = .pending
                $0.mergeState = "DRAFT"
                $0.events = [event("E7", "PR_4", .convertedToDraft, "dana", 300, "", own: true)]
            },
            pr("PR_5", work, "octo-org/docs", 12, "Clarify the install steps", author: "bob", roles: [.commenter]) {
                $0.reviewDecision = "REVIEW_REQUIRED"
                $0.ci = .success
                $0.events = [event("E8", "PR_5", .comment, "bob", 180, "Moved the Homebrew section up.")]
            },
            pr("PR_6", work, "octo-org/gadgets", 49, "Cache parsed manifests between runs", author: "alice", roles: [.commenter]) {
                $0.muted = true
                $0.ci = .success
                $0.events = [event("E9", "PR_6", .comment, "alice", 700, "Rebased on main.")]
            },
            pr("PR_7", personal, "octo-org/widgets", 119, "Remove the legacy cache", author: "dana", roles: [.author]) {
                $0.state = .merged
                $0.closedAt = ago(1500)
                $0.reviewDecision = "APPROVED"
                $0.ci = .success
                $0.events = [event("E10", "PR_7", .merged, "dana", 1500, "", own: true)]
            },
            pr("PR_8", work, "octo-org/docs", 15, "Fix typos in the FAQ", author: "erin", roles: [.reviewer]) {  // reviewed, nothing unread: Done
                $0.reviewDecision = "APPROVED"
                $0.ci = .success
                $0.reviewers = [ReviewSummary(login: "dana-work", state: "APPROVED", submittedAt: ago(400), requested: false)]
                $0.events = [event("E11", "PR_8", .reviewApproved, "dana-work", 400, "", own: true)]
            },
        ]
    }
}
