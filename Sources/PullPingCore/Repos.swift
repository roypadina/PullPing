import Foundation

/// Mute a whole repository: its items are muted items (`TrackedPR.muted`), the ones tracked later too. Repositories are
/// stored lowercased and compared with `pr.repo.lowercased()`.
public enum RepoMute {
    public static func isMuted(_ repo: String, _ muted: Set<String>?) -> Bool { muted?.contains(repo.lowercased()) ?? false }

    /// A newly tracked item of a muted repository starts muted (Poller).
    public static func apply(_ pr: inout TrackedPR, muted: Set<String>?) {
        guard !pr.muted, isMuted(pr.repo, muted) else { return }
        pr.muted = true
        pr.mutedByRepo = true
    }

    /// Remembers the repositories and mutes their items that are not muted yet (`only`: just these ids, for Undo).
    /// Returns the ids it muted.
    @discardableResult public static func mute(_ repos: Set<String>, in state: inout TrackedState, only: Set<String>? = nil) -> Set<String> {
        let repos = Set(repos.map { $0.lowercased() })
        state.mutedRepos = (state.mutedRepos ?? []).union(repos)
        var changed: Set<String> = []
        for (id, pr) in state.prs where !pr.muted && repos.contains(pr.repo.lowercased()) && only?.contains(id) != false {
            state.prs[id]?.muted = true
            state.prs[id]?.mutedByRepo = true
            changed.insert(id)
        }
        return changed
    }

    /// Forgets them and unmutes the items they muted (`mutedByRepo`); items muted one by one stay. Returns the ids it unmuted.
    @discardableResult public static func unmute(_ repos: Set<String>, in state: inout TrackedState) -> Set<String> {
        let repos = Set(repos.map { $0.lowercased() })
        state.mutedRepos?.subtract(repos)
        var changed: Set<String> = []
        for (id, pr) in state.prs where pr.mutedByRepo && repos.contains(pr.repo.lowercased()) {
            state.prs[id]?.mutedByRepo = false
            guard pr.muted else { continue }
            state.prs[id]?.muted = false
            changed.insert(id)
        }
        return changed
    }

    /// "Mute octo-org/widgets", "Unmute 3 Repositories"; no repository: "Mute Repository". `muted`: all of them are muted.
    public static func title(repos: [String], muted: Bool) -> String {
        let verb = muted ? "Unmute" : "Mute"
        switch repos.count {
        case 0: return "Mute Repository"
        case 1: return "\(verb) \(repos[0])"
        default: return "\(verb) \(repos.count) Repositories"
        }
    }
}

/// The lists' Repository choice: a view filter, nothing else (counts, dots and notifications never follow it).
public enum RepoFilter {
    /// Each repository once (first casing seen), sorted case-insensitively.
    public static func repos(_ prs: some Sequence<TrackedPR>) -> [String] {
        var seen: [String: String] = [:]
        for pr in prs where !pr.repo.isEmpty && seen[pr.repo.lowercased()] == nil { seen[pr.repo.lowercased()] = pr.repo }
        return seen.sorted { $0.key < $1.key }.map(\.value)
    }

    /// The choice as `repos` spells it, or nil (= All Repositories) when it is empty or not among them.
    public static func active(_ stored: String, in repos: [String]) -> String? {
        stored.isEmpty ? nil : repos.first { $0.caseInsensitiveCompare(stored) == .orderedSame }
    }

    /// nil filter matches everything; else case-insensitive equality.
    public static func matches(_ repo: String, _ filter: String?) -> Bool {
        filter.map { $0.caseInsensitiveCompare(repo) == .orderedSame } ?? true
    }
}
