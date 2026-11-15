import Foundation

/// Issues in repositories I watch (Settings → General → Track Issues in My Repositories, Other Repositories). Pure.
public enum IssueWatch {
    public static let maxRepos = 20

    /// "Octo-Org/widgets, octo-org/*  foo" → patterns ["octo-org/widgets", "octo-org/*"], rejected ["foo"].
    /// Split on commas, spaces and newlines; lowercased; duplicates dropped; valid = `LaunchPlanner.isValidRepo("owner/name")`,
    /// or "owner/*" with `isValidRepo("owner/x")`; entries past `maxRepos` are rejected.
    public static func parse(_ text: String) -> (patterns: [String], rejected: [String]) {
        var patterns: [String] = [], rejected: [String] = []
        for entry in text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init) {
            let pattern = entry.lowercased()
            if patterns.contains(pattern) { continue }
            let valid = pattern.hasSuffix("/*") ? LaunchPlanner.isValidRepo(String(pattern.dropLast()) + "x") : LaunchPlanner.isValidRepo(pattern)
            if valid && patterns.count < maxRepos { patterns.append(pattern) } else { rejected.append(entry) }
        }
        return (patterns, rejected)
    }

    /// The watched-issues search; nil when there is nothing to watch. `user:` matches organizations too; several `user:` and
    /// `repo:` qualifiers are a union. Newest first, so new issues are on page 1 whatever the repository size.
    public static func query(owned: Bool, extra: [String]) -> String? {
        let scopes = (owned ? ["user:@me"] : []) + extra.map { $0.hasSuffix("/*") ? "user:" + $0.dropLast(2) : "repo:" + $0 }
        return scopes.isEmpty ? nil : "is:issue is:open archived:false sort:created-desc " + scopes.joined(separator: " ")
    }

    /// What the account watches: `(owned ? ["<login>/*"] : []) + extra`, lowercased, no duplicates.
    public static func patterns(login: String, owned: Bool, extra: [String]) -> [String] {
        var result: [String] = []
        for p in ((owned ? ["\(login)/*"] : []) + extra).map({ $0.lowercased() }) where !result.contains(p) { result.append(p) }
        return result
    }

    /// `AutomationMatcher.repoMatches` against any pattern.
    public static func matches(_ repo: String, _ patterns: [String]) -> Bool {
        patterns.contains { AutomationMatcher.repoMatches($0, repo) }
    }

    /// When watching `repo` began: the earliest date among its matching patterns (`since[pattern] ?? now`); nil = not watched.
    public static func since(_ repo: String, patterns: [String], since: [String: Date], now: Date) -> Date? {
        patterns.filter { AutomationMatcher.repoMatches($0, repo) }.map { since[$0] ?? now }.min()
    }
}
