import Foundation

/// Query text sent to `POST https://api.github.com/graphql`, validated against the live API.
enum GraphQL {
    static let me = "query Me { viewer { login avatarUrl } rateLimit { cost remaining resetAt } }"

    static let discover = """
    query Discover($involved: String!, $requested: String!, $reviewed: String!) {
      viewer { login }
      involved:  search(query: $involved,  type: ISSUE, first: 100) { issueCount pageInfo { hasNextPage endCursor } nodes { ... on PullRequest { id updatedAt } } }
      requested: search(query: $requested, type: ISSUE, first: 100) { issueCount pageInfo { hasNextPage endCursor } nodes { ... on PullRequest { id updatedAt } } }
      reviewed:  search(query: $reviewed,  type: ISSUE, first: 100) { issueCount pageInfo { hasNextPage endCursor } nodes { ... on PullRequest { id updatedAt } } }
      rateLimit { cost remaining resetAt }
    }
    """

    static let page = """
    query Page($q: String!, $after: String) {
      search(query: $q, type: ISSUE, first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { ... on PullRequest { id updatedAt } } }
      rateLimit { cost remaining resetAt }
    }
    """

    static let stamps = "query Stamps($ids: [ID!]!) { nodes(ids: $ids) { ... on PullRequest { id updatedAt state } } rateLimit { cost remaining resetAt } }"

    static let refresh = """
    query Refresh($ids: [ID!]!, $since: DateTime, $after: String) {
      nodes(ids: $ids) {
        ... on PullRequest {
          id number title url isDraft state merged mergedAt closedAt updatedAt headRefOid body
          reviewDecision mergeStateStatus
          author { login avatarUrl }
          repository { nameWithOwner url isPrivate }
          assignees(first: 10) { nodes { login } }
          reviewRequests(first: 20) { nodes { requestedReviewer { __typename ... on User { login } ... on Team { slug name } } } }
          latestReviews(first: 20) { nodes { author { login } state submittedAt url } }
          commits(last: 1) { nodes { commit { oid committedDate author { user { login } name }
            statusCheckRollup { state contexts(first: 30) { nodes { __typename
              ... on CheckRun { name conclusion status detailsUrl }
              ... on StatusContext { context state targetUrl } } } } } } }
          timelineItems(first: 50, since: $since, after: $after, itemTypes: [ISSUE_COMMENT, PULL_REQUEST_REVIEW, READY_FOR_REVIEW_EVENT, CONVERT_TO_DRAFT_EVENT, MERGED_EVENT, CLOSED_EVENT, REOPENED_EVENT, HEAD_REF_FORCE_PUSHED_EVENT, REVIEW_DISMISSED_EVENT, RENAMED_TITLE_EVENT]) {
            pageInfo { hasNextPage endCursor }
            nodes { __typename
              ... on IssueComment { id createdAt url body author { login } }
              ... on PullRequestReview { id submittedAt url body state author { login } comments(first: 1) { totalCount nodes { body path } } }
              ... on ReadyForReviewEvent { id createdAt actor { login } }
              ... on ConvertToDraftEvent { id createdAt actor { login } }
              ... on MergedEvent { id createdAt actor { login } }
              ... on ClosedEvent { id createdAt actor { login } }
              ... on ReopenedEvent { id createdAt actor { login } }
              ... on HeadRefForcePushedEvent { id createdAt actor { login } afterCommit { abbreviatedOid } }
              ... on ReviewDismissedEvent { id createdAt actor { login } }
              ... on RenamedTitleEvent { id createdAt actor { login } currentTitle }
            }
          }
        }
      }
      rateLimit { cost remaining resetAt }
    }
    """
}

public struct RateLimit: Codable, Sendable, Equatable {
    public var cost: Int
    public var remaining: Int
    public var resetAt: Date
}

public struct GraphQLError: Decodable, Sendable, Equatable {
    public var type: String?
    public var message: String
}

struct GraphQLResponse<T: Decodable>: Decodable {
    var data: T?
    var errors: [GraphQLError]?
}

struct RateLimitHolder: Decodable { var rateLimit: RateLimit? }

/// A GraphQL connection; list items are nullable in the schema.
struct Nodes<T: Decodable>: Decodable {
    var nodes: [T?]?
    var items: [T] { nodes?.compactMap { $0 } ?? [] }
}

struct Login: Decodable { var login: String }

struct MeData: Decodable {
    struct Viewer: Decodable { var login: String; var avatarUrl: URL? }
    var viewer: Viewer
}

struct PageInfo: Decodable {
    var hasNextPage: Bool
    var endCursor: String?
}

struct StampNode: Decodable {
    var id: String
    var updatedAt: Date
    var state: String?
}

struct SearchResult: Decodable {
    var issueCount: Int?
    var pageInfo: PageInfo
    var nodes: [StampNode?]?
    var items: [StampNode] { nodes?.compactMap { $0 } ?? [] }
}

struct DiscoverData: Decodable {
    var viewer: Login
    var involved: SearchResult
    var requested: SearchResult
    var reviewed: SearchResult
}

struct PageData: Decodable { var search: SearchResult }

/// `nodes(ids:)`: same order as the ids, `null` for a deleted or inaccessible node.
struct NodesData<T: Decodable>: Decodable { var nodes: [T?] }

struct RawPR: Decodable {
    struct Repo: Decodable { var nameWithOwner: String }
    struct Requested: Decodable {
        struct Reviewer: Decodable { var login: String?; var slug: String? }
        var requestedReviewer: Reviewer?
    }
    struct Review: Decodable { var author: Login?; var state: String; var submittedAt: Date? }
    struct CommitNode: Decodable { var commit: Commit }
    struct Commit: Decodable {
        struct Author: Decodable { var user: Login?; var name: String? }
        struct Rollup: Decodable { var state: String; var contexts: Nodes<Context> }
        var oid: String
        var author: Author?
        var statusCheckRollup: Rollup?
    }
    struct Context: Decodable {
        var __typename: String
        var name: String?, conclusion: String?, detailsUrl: String?  // CheckRun
        var context: String?, state: String?, targetUrl: String?  // StatusContext
    }
    struct Timeline: Decodable {
        var pageInfo: PageInfo
        var nodes: [Item?]?
    }
    struct Item: Decodable {
        struct Comments: Decodable {
            struct Comment: Decodable { var body: String; var path: String? }
            var totalCount: Int
            var nodes: [Comment?]?
        }
        struct AfterCommit: Decodable { var abbreviatedOid: String }
        var __typename: String
        var id: String?
        var createdAt: Date?
        var submittedAt: Date?
        var url: String?
        var body: String?
        var state: String?
        var author: Login?
        var actor: Login?
        var comments: Comments?
        var afterCommit: AfterCommit?
        var currentTitle: String?
    }

    var id: String
    var number: Int
    var title: String
    var url: URL
    var isDraft: Bool
    var state: String
    var merged: Bool
    var mergedAt: Date?
    var closedAt: Date?
    var updatedAt: Date
    var headRefOid: String
    var body: String
    var reviewDecision: String?
    var mergeStateStatus: String
    var author: Login?
    var repository: Repo
    var assignees: Nodes<Login>
    var reviewRequests: Nodes<Requested>?
    var latestReviews: Nodes<Review>?
    var commits: Nodes<CommitNode>
    var timelineItems: Timeline
}
