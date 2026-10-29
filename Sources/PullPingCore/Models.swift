import Foundation

public enum AuthKind: String, Codable, Sendable { case pat, oauth }

public struct Account: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var login: String
    public var avatarURL: URL?
    public var label: String
    public var enabled: Bool
    public var authKind: AuthKind
    public var tokenService: String

    public init(id: UUID = UUID(), login: String, avatarURL: URL? = nil, label: String = "", enabled: Bool = true, authKind: AuthKind = .pat) {
        self.id = id
        self.login = login
        self.avatarURL = avatarURL
        self.label = label
        self.enabled = enabled
        self.authKind = authKind
        self.tokenService = Keychain.service(for: id)
    }
}

/// Also the error type thrown by `GitHubClient`.
public enum AccountStatus: Error, Codable, Sendable, Equatable {
    case ok, syncing, badToken, missingScope(String), ssoRequired, rateLimited(resetAt: Date), offline, failed(String)
}

public enum Role: String, Codable, Sendable, CaseIterable {
    case author, reviewRequested, teamReviewRequested, assigned, mentioned, commenter, reviewer
}

public enum PRState: String, Codable, Sendable { case open, merged, closed }

/// failure = FAILURE or ERROR; EXPECTED → pending.
public enum CIState: String, Codable, Sendable { case none, pending, success, failure }

public struct CheckSummary: Codable, Sendable, Equatable {
    public var name: String
    public var state: CIState
    public var url: URL?
    public init(name: String, state: CIState, url: URL?) { self.name = name; self.state = state; self.url = url }
}

public struct ReviewSummary: Codable, Sendable, Equatable {
    public var login: String
    /// APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED; empty when only requested.
    public var state: String
    public var submittedAt: Date?
    public var requested: Bool
    public init(login: String, state: String, submittedAt: Date?, requested: Bool) {
        self.login = login; self.state = state; self.submittedAt = submittedAt; self.requested = requested
    }
}

/// One `timelineItems` node, normalized.
public struct TimelineNode: Codable, Sendable, Equatable {
    public var id: String
    public var type: String  // GraphQL __typename
    public var at: Date
    public var actor: String
    public var body = ""
    public var url: URL?
    public var reviewState: String?
    public var commentCount = 0
    public var commentPath: String?
    public var commentBody: String?
    /// HeadRefForcePushedEvent: abbreviated oid; RenamedTitleEvent: the new title.
    public var detail: String?
}

/// Normalized output of `Refresh` for one PR.
public struct PRSnapshot: Codable, Sendable, Equatable {
    public let id: String
    public var repo = ""
    public var number = 0
    public var title = ""
    public var url = URL(string: "https://github.com")!
    public var authorLogin = ""
    public var body = ""
    public var isDraft = false
    public var state = PRState.open
    public var reviewDecision: String?
    public var mergeState = ""
    public var ci = CIState.none
    public var checks: [CheckSummary] = []
    public var headOID = ""
    public var headAuthorLogin: String?
    public var reviewers: [ReviewSummary] = []
    public var requestedTeams: [String] = []
    public var assignees: [String] = []
    public var updatedAt = Date.distantPast
    public var closedAt: Date?
    public var timeline: [TimelineNode] = []

    public init(id: String) { self.id = id }
}

public struct TrackedPR: Identifiable, Codable, Sendable, Equatable {
    public let id: String  // GraphQL node id
    public var accountID: UUID
    public var repo = ""  // owner/name
    public var number = 0
    public var title = ""
    public var url = URL(string: "https://github.com")!
    public var authorLogin = ""
    public var isDraft = false
    public var state = PRState.open
    public var reviewDecision: String?
    public var mergeState = ""
    public var ci = CIState.none
    public var checks: [CheckSummary] = []
    public var headOID = ""
    public var reviewers: [ReviewSummary] = []
    public var requestedTeams: [String] = []
    public var assignees: [String] = []
    public var roles: Set<Role> = []
    public var updatedAt = Date.distantPast
    public var closedAt: Date?
    public var lastSeenAt = Date.distantPast  // timeline watermark
    public var seenEventIDs: [String] = []  // FIFO, cap 300
    public var events: [PREvent] = []  // newest last, cap 50
    public var lastReadAt: Date?
    public var muted = false
    public var snoozedUntil: Date?
    public var lastReminderAt: Date?
    public var firstTrackedAt: Date
    /// Only under the Hidden filter, never counted; still notifies unless muted.
    @FalseIfMissing public var hidden = false

    public init(id: String, accountID: UUID, firstTrackedAt: Date) {
        self.id = id
        self.accountID = accountID
        self.firstTrackedAt = firstTrackedAt
    }
}

/// A Bool that decodes as false when its key is missing, so state files from before the field still load.
@propertyWrapper
public struct FalseIfMissing: Codable, Sendable, Equatable {
    public var wrappedValue: Bool
    public init(wrappedValue: Bool) { self.wrappedValue = wrappedValue }
    public init(from decoder: Decoder) throws { wrappedValue = try decoder.singleValueContainer().decode(Bool.self) }
    public func encode(to encoder: Encoder) throws { try wrappedValue.encode(to: encoder) }
}

extension KeyedDecodingContainer {
    /// Picked by the synthesized `init(from:)` over the generic `decode`: a missing key is false, not an error.
    func decode(_ type: FalseIfMissing.Type, forKey key: Key) throws -> FalseIfMissing {
        try decodeIfPresent(type, forKey: key) ?? FalseIfMissing(wrappedValue: false)
    }
}

public enum EventKind: String, Codable, Sendable, CaseIterable, CodingKeyRepresentable {
    case comment, mentioned, reviewApproved, reviewChangesRequested, reviewCommented, reviewRequested, assigned, newCommits,
         ciPassed, ciFailed, readyForReview, convertedToDraft, merged, closed, reopened, reviewDismissed, retitled, reviewReminder
}

public struct PREvent: Identifiable, Codable, Sendable, Equatable {
    /// GitHub node id, or "ci:<oid>:<state>", "head:<oid>", "rr:<login>:<date>", "assign:<login>:<date>", "reminder:<date>".
    /// Unique per PR only: key lists that mix PRs by `prID` + `id`.
    public let id: String
    public var prID: String
    public var kind: EventKind
    public var actor: String
    public var at: Date
    public var summary: String  // ≤ 120 chars, first line of the body
    public var url: URL?
    /// Silent: my own action, or seeded history of a newly tracked PR. Never notified, never unread.
    public var isOwn: Bool

    public init(id: String, prID: String, kind: EventKind, actor: String, at: Date, summary: String, url: URL?, isOwn: Bool) {
        self.id = id; self.prID = prID; self.kind = kind; self.actor = actor
        self.at = at; self.summary = summary; self.url = url; self.isOwn = isOwn
    }
}

public struct TrackedState: Codable, Sendable, Equatable {
    public var prs: [String: TrackedPR] = [:]
    public var ignoredIDs: Set<String> = []
    public var baselinedAccounts: Set<UUID> = []
    public var lastPollAt: [UUID: Date] = [:]
    public init() {}
}
