import Foundation

/// Which automations a poll's events start (auto) or offer (ask), and the ledger caps against loops. Pure.
public enum AutomationMatcher {
    /// No second auto run for the same automation and pull request within this.
    public static let cooldown: TimeInterval = 10 * 60
    /// Auto launches per poll report; further auto matches become offers.
    public static let autoBudget = 3
    /// Failed launches per automation and pull request after which it no longer starts there on its own (Run still works).
    public static let failureCap = 3
    /// My own events that may still trigger (when they happened after tracking began): "when I merge it, …".
    static let ownKinds: Set<EventKind> = [.merged, .closed, .reopened, .readyForReview, .convertedToDraft]

    public struct Match: Sendable, Equatable {
        public var automation: Automation
        public var pr: TrackedPR
        public var event: PREvent
    }

    /// Own events (mine, or a new pull request's seeded history) never trigger, except `ownKinds` by me after tracking began.
    public static func eligible(_ event: PREvent, pr: TrackedPR, me: String) -> Bool {
        guard event.isOwn else { return true }
        return ownKinds.contains(event.kind) && event.actor.lowercased() == me.lowercased() && event.at >= pr.firstTrackedAt
    }

    /// "owner/name" exactly or "owner/*", case-insensitive.
    public static func repoMatches(_ pattern: String, _ repo: String) -> Bool {
        let pattern = pattern.trimmingCharacters(in: .whitespaces).lowercased(), repo = repo.lowercased()
        return pattern.hasSuffix("/*") ? repo.hasPrefix(pattern.dropLast()) : pattern == repo
    }

    /// Hooks: their pull request (repo + number). Rules: scope and repositories. Kinds and actors aside. A linked-session
    /// automation fits only pull requests with a link in `sessions`.
    static func fits(_ a: Automation, _ pr: TrackedPR, sessions: [SessionLink] = []) -> Bool {
        if a.usesLinkedSession && !sessions.contains(where: { $0.pr.matches(pr.repo, pr.number) }) { return false }
        if let ref = a.pr { return ref.repo.lowercased() == pr.repo.lowercased() && ref.number == pr.number }
        let mine = pr.roles.contains(.author)
        guard a.scope == .any || (a.scope == .mine) == mine else { return false }
        return a.repos.isEmpty || a.repos.contains { repoMatches($0, pr.repo) }
    }

    /// The pull request's Run Automation menu: enabled rules that fit it plus its hooks.
    public static func applicable(_ automations: [Automation], pr: TrackedPR, sessions: [SessionLink] = []) -> [Automation] {
        automations.filter { $0.enabled && fits($0, pr, sessions: sessions) }
    }

    public static func matches(_ a: Automation, pr: TrackedPR, event: PREvent, me: String, sessions: [SessionLink] = []) -> Bool {
        a.enabled && a.kinds.contains(event.kind) && fits(a, pr, sessions: sessions) && eligible(event, pr: pr, me: me)
            && (a.actors.isEmpty || a.actors.contains { $0.lowercased() == event.actor.lowercased() })
    }

    /// Why this run may not start, or nil. `manual` (Run menu, Run button, Try) skips the cooldown and the failure cap, never the duplicate check.
    public static func blocked(_ a: Automation, prID: String, eventID: String, runs: [RunRecord], now: Date, manual: Bool = false) -> String? {
        let mine = runs.filter { $0.automationID == a.id && $0.prID == prID }
        if mine.contains(where: { $0.eventID == eventID }) { return "Already ran for this event" }
        if mine.filter(\.ok).count >= a.maxRunsPerPR { return "Already ran \(a.maxRunsPerPR) \(a.maxRunsPerPR == 1 ? "time" : "times") on this pull request" }
        if !manual, mine.filter({ !$0.ok }).count >= failureCap { return "Failed \(failureCap) times on this pull request" }
        if !manual, let last = mine.map(\.at).max(), now.timeIntervalSince(last) < cooldown { return "Ran less than \(Int(cooldown / 60)) minutes ago" }
        return nil
    }

    /// The automation as saved now, if it may still run. Offers and automatic runs launch this, not the copy they captured,
    /// so turning a rule off, removing it or a hook expiring reaches a panel that is still open.
    public static func current(_ id: UUID, in automations: [Automation], now: Date) -> Automation? {
        automations.first { $0.id == id && $0.enabled && ($0.expiresAt ?? .distantFuture) > now }
    }

    /// One match per automation and pull request (its newest matching event). Auto matches past the budget become offers;
    /// offers skip the cooldown (the user decides) but not the other caps.
    public static func plan(events: [PREvent], prs: [String: TrackedPR], automations: [Automation], runs: [RunRecord],
                            settingsEnabled: Bool, paused: Bool, accounts: [Account], now: Date, sessions: [SessionLink] = []) -> (auto: [Match], offers: [Match]) {
        guard settingsEnabled, !paused else { return ([], []) }
        var auto: [Match] = [], offers: [Match] = [], claimed = Set<String>()
        for event in events.sorted(by: { $0.at > $1.at }) {
            guard let pr = prs[event.prID], let account = accounts.first(where: { $0.id == pr.accountID }), account.enabled,
                  !pr.muted, !pr.hidden, (pr.snoozedUntil ?? .distantPast) <= now else { continue }
            for a in automations where matches(a, pr: pr, event: event, me: account.login, sessions: sessions) && (a.expiresAt ?? .distantFuture) > now {
                // New commits after this automation started an agent here may be that agent's push (the head commit's author
                // can't tell: an unlinked git identity, a cherry-pick): offer it, never start it on its own.
                let isAuto = a.mode == .auto && !(event.kind == .newCommits && runs.contains { $0.automationID == a.id && $0.prID == pr.id && $0.ok })
                guard !claimed.contains("\(a.id)|\(pr.id)"),
                      blocked(a, prID: pr.id, eventID: event.id, runs: runs, now: now, manual: !isAuto) == nil else { continue }
                claimed.insert("\(a.id)|\(pr.id)")
                let match = Match(automation: a, pr: pr, event: event)
                if isAuto && auto.count < autoBudget { auto.append(match) } else { offers.append(match) }
            }
        }
        return (auto, offers)
    }
}
