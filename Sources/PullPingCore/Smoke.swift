import Foundation

/// `PULLPING_SMOKE=1 PULLPING_TOKEN=<token> [PULLPING_STATE=<path>] PullPing`: one real poll, printed. Never prints the token.
public enum SmokeRunner {
    /// Fixed so a state file carries over between runs.
    static let accountID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// Exit code: 0 success, 2 auth/scope error, 3 network error, 1 anything else.
    public static func run(token: String, statePath: String?) async -> Int32 {
        guard !token.isEmpty else { print("error: PULLPING_TOKEN is empty"); return 2 }
        let transport = URLSessionTransport()
        let viewer: Viewer
        do {
            viewer = try await GitHubClient(transport: transport, token: token).me()
        } catch {
            return fail(GitHubClient.status(for: error))
        }
        print("login: \(viewer.login)   accounts: 1")
        if viewer.status != .ok { print("status: \(viewer.status)") }

        let store = StateStore(url: statePath.map { URL(fileURLWithPath: $0) })
        let poller = Poller(transport: transport, tokenProvider: { _ in token }, state: store, settings: { AppSettings() })
        guard let result = await poller.poll(account: Account(id: accountID, login: viewer.login)) else { return 1 }
        let s = result.stats
        print("discover: involved=\(s.involved) requested=\(s.requested) reviewed=\(s.reviewed) issues=\(s.issues)  pages=\(s.pages)  cost=\(s.discoverCost)")
        print("stamps: tracked=\(s.tracked) changed=\(s.changed) new=\(s.new) dropped=\(s.dropped)")
        print("refresh: batches=\(s.batches) prs=\(s.refreshed) cost=\(s.refreshCost) remaining=\(s.rateLimit.map { "\($0.remaining)" } ?? "?") resetAt=\(s.rateLimit?.resetAt.ISO8601Format() ?? "?")")
        switch result.status {
        case .ok: break
        case .ssoRequired, .missingScope: print("status: \(result.status) (partial data)")
        default: return fail(result.status)
        }

        let prs = store.state.prs.values.filter { $0.accountID == accountID }
        let open = prs.filter { $0.state == .open }
        func count(_ group: PRGroup) -> Int { open.filter { Attention.group($0) == group }.count }
        print("groups: mine=\(count(.mine)) toReview=\(count(.toReview)) involved=\(count(.involved)) closedKept=\(prs.count - open.count)")
        let notify = result.events.filter { !$0.isOwn }.count
        print("events (would notify = \(notify), own/silent = \(result.events.count - notify)):")
        for event in result.events {
            let pr = store.state.prs[event.prID]
            let kind = event.kind.rawValue.padding(toLength: 22, withPad: " ", startingAt: 0)
            print("  [\(event.isOwn ? "silent" : "notify")] \(kind) \(pr?.repo ?? "?")#\(pr?.number ?? 0)  \(event.actor)  \(event.at.ISO8601Format())  \"\(event.summary)\"")
        }
        if s.baseline { print("first run with empty state: baseline, 0 notifications") }
        store.save()
        return 0
    }

    private static func fail(_ status: AccountStatus) -> Int32 {
        print("status: \(status)")
        switch status {
        case .badToken, .missingScope, .ssoRequired: return 2
        case .offline: return 3
        default: return 1
        }
    }
}
