import Foundation

/// What an agent run is about, from the `NeedReason` of the pull request: picks the task text that fills a prompt's `{task}`
/// (Settings → Automations → Prompts, `pullping prompts`).
public enum Scenario: String, CaseIterable, Codable, Sendable, Identifiable {
    case review, reReview, changesRequested, comments, ciFailed, conflicts, readyToMerge, assigned, issueTriage, general

    public var id: String { rawValue }

    /// Settings and `{scenario_label}`.
    public var label: String {
        switch self {
        case .review: "Review requested"
        case .reReview: "Re-review"
        case .changesRequested: "Changes requested"
        case .comments: "New comments or a mention"
        case .ciFailed: "CI failed"
        case .conflicts: "Conflicts or behind base"
        case .readyToMerge: "Ready to merge"
        case .assigned: "Assigned to me"
        case .issueTriage: "New issue"
        case .general: "Anything else"
        }
    }

    /// Team review shares `review`, a mention shares `comments`; no reason = `general`.
    public init(_ reason: NeedReason?) {
        switch reason {
        case .toReview, .teamToReview: self = .review
        case .reReview: self = .reReview
        case .changesRequested: self = .changesRequested
        case .newComments, .mentioned: self = .comments
        case .ciFailed: self = .ciFailed
        case .conflicts: self = .conflicts
        case .readyToMerge: self = .readyToMerge
        case .assigned: self = .assigned
        case .toTriage: self = .issueTriage
        case .reminder, nil: self = .general
        }
    }

    /// The highest-priority reason among `events` (a panel's, a rule's triggering event), else the pull request's own
    /// (`Attention.needReason`: menus, `pullping run`, `session resume`), else `general`.
    public static func derive(events: [PREvent], pr: TrackedPR) -> Scenario {
        let rank = { (r: NeedReason) in NeedReason.allCases.firstIndex(of: r) ?? NeedReason.allCases.count }
        return Scenario(events.compactMap { Notify.reason($0, pr: pr) }.min { rank($0) < rank($1) } ?? Attention.needReason(pr))
    }

    /// `{resume_note}` on a resume (empty for a new session).
    public static let resumeNote = "You are resumed in the session that worked on this pull request before; start from what changed since your last turn."

    /// The built-in task texts: explain and propose, then wait for my OK. Tool-neutral (the frame names the commands).
    public var builtIn: String {
        switch self {
        case .review:
            "I was asked to review this pull request. Read the description, the whole diff and the code around it where needed. Give me: what it does in three lines; findings by severity, each with file and line; your verdict (approve, request changes or comment). Do not post anything on GitHub: draft the review and wait for my OK."
        case .reReview:
            "I reviewed this pull request before and it changed since (my review was on commit {reviewed_sha}; when that commit is gone, use the commits pushed after my review). Show me what changed, whether each of my earlier comments was addressed, and anything new that needs a comment. Do not post anything on GitHub: draft the review and wait for my OK."
        case .changesRequested:
            "A reviewer requested changes on my pull request. Read every review and open thread, starting at {event_url}. For each request: explain it in one or two lines, say whether you agree, and propose the fix. Then stop and ask me which fixes to make. Do not push or reply on GitHub before I say so."
        case .comments:
            "There are new comments or a mention for me, starting at {event_url}. For each one: explain what is asked, and propose a code change or a reply. Then stop and ask me what to do. Do not push or post before I say so."
        case .ciFailed:
            "CI failed on my pull request at {head_sha}. Find the failing checks, read the failing job's log and tell me the root cause in a few lines. Propose the smallest fix; when the failure is flaky or unrelated to my change, say that instead. Change code only after I agree; do not push before I say so."
        case .conflicts:
            "My pull request conflicts with its base branch or is behind it. Show me which files conflict and why, and how you would resolve each. Resolve locally only after I agree, with the method this repository uses (merge or rebase). Never force-push without asking."
        case .readyToMerge:
            "My pull request is approved and its checks pass. Do a last check: open threads, leftover TODOs or debug code in the diff, a stale title or description, the repository's merge method. Report what you find. Do not merge."
        case .assigned:
            "This was assigned to me. Read it and its discussion, find the code it is about, and give me a short plan: what is asked, where the change goes, open questions. Do not change code before I agree."
        case .issueTriage:
            "Someone opened this issue in a repository I maintain. Read it and its discussion (in a terminal: `gh issue view {pr_number} --repo {repo} --comments`), look for duplicates among open and closed issues when you can search them, and find the code it is about. Tell me: what is asked or reported, in three lines; whether it is a bug, a feature request, a question or spam; what is missing to act on it; the labels you would add; then a reply I could post. Do not comment, label, assign or close anything on GitHub: draft the reply and wait for my OK."
        case .general:
            "Work out what this needs from me and tell me. Ask before you change, push or post anything."
        }
    }

    /// A task text's limit (`pullping prompts set`, the Prompts editor).
    public static let maxTaskLength = 4000
}
