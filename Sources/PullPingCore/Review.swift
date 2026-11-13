import Foundation

/// A background run's input, fetched by PullPing with the account's token before the agent starts (it has no network).
public struct BackgroundContext: Sendable, Equatable {
    /// The head commit when the discussion was fetched: the draft is pinned to it.
    public var head: String
    public var open: Bool
    public var isDraft: Bool
    /// `discussion.md`: description, reviews with their line comments, comments; capped (`BackgroundPlanner.discussionCap`).
    public var discussion: String
}

extension GitHubClient {
    static let discussionQuery = """
    query Discussion($id: ID!) {
      node(id: $id) {
        ... on PullRequest {
          number title url state isDraft headRefOid headRefName baseRefName body createdAt
          author { login }
          reviews(last: 50) { nodes { author { login } state submittedAt body comments(first: 50) { nodes { path line body author { login } } } } }
          comments(last: 100) { nodes { author { login } createdAt body } }
        }
      }
      rateLimit { cost remaining resetAt }
    }
    """

    static let headQuery = "query Head($id: ID!) { node(id: $id) { ... on PullRequest { headRefOid state } } rateLimit { cost remaining resetAt } }"

    /// The only write PullPing makes to GitHub: one review, on a click in the draft window (`postReview`).
    static let addReviewMutation = """
    mutation AddReview($input: AddPullRequestReviewInput!) {
      addPullRequestReview(input: $input) { pullRequestReview { url state } }
    }
    """

    /// The discussion of a pull request (node id) as Markdown for `discussion.md`, and its head commit.
    public func backgroundContext(prID: String) async throws -> BackgroundContext {
        let data: DiscussionData = try await run(Self.discussionQuery, ["id": prID])
        guard let pr = data.node, let head = pr.headRefOid else { throw AccountStatus.failed("Not a pull request, or no access") }
        return BackgroundContext(head: head, open: pr.state == "OPEN", isDraft: pr.isDraft ?? false,
                                 discussion: BackgroundPlanner.capped(Data(Self.markdown(pr).utf8), cap: BackgroundPlanner.discussionCap, what: "discussion"))
    }

    /// `diff.patch`: the pull request's diff (REST, `application/vnd.github.diff`), capped (`BackgroundPlanner.diffCap`).
    public func diff(repo: String, number: Int) async throws -> String {
        guard LaunchPlanner.isValidRepo(repo), let url = URL(string: "https://api.github.com/repos/\(repo)/pulls/\(number)") else {
            throw AccountStatus.failed("Unexpected repository name: \(repo)")
        }
        var request = URLRequest(url: url)
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github.diff", forHTTPHeaderField: "Accept")
        let data: Data, http: HTTPURLResponse
        do { (data, http) = try await transport.send(request) } catch { throw Self.status(for: error) }
        if http.statusCode == 406 || http.statusCode == 422 { throw AccountStatus.failed("GitHub can't produce this diff (too large)") }
        if let status = Self.status(http, errors: [], hasData: true) { throw status }
        return BackgroundPlanner.capped(data, cap: BackgroundPlanner.diffCap, what: "diff")
    }

    /// The pull request's head commit and whether it is open, fresh, right before a post.
    public func pullRequestHead(prID: String) async throws -> (head: String, open: Bool) {
        let data: HeadData = try await run(Self.headQuery, ["id": prID])
        guard let node = data.node, let head = node.headRefOid else { throw AccountStatus.failed("Not a pull request, or no access") }
        return (head, node.state == "OPEN")
    }

    /// The request `postReview` sends (tests check it with a fake transport; nothing else builds a write).
    func reviewRequest(prID: String, commitOID: String, event: DraftPost.Event, body: String) throws -> URLRequest {
        try request(Self.addReviewMutation, ["input": ["pullRequestId": prID, "commitOID": commitOID, "event": event.rawValue, "body": body]])
    }

    /// Posts one review pinned to `commitOID`. Called only from the draft window's Post button, never from the CLI or a rule.
    /// GitHub's own refusal (a read-only token, an own pull request) comes back as the error's text.
    public func postReview(prID: String, commitOID: String, event: DraftPost.Event, body: String) async throws -> URL? {
        let request = try reviewRequest(prID: prID, commitOID: commitOID, event: event, body: body)
        let data: Data, http: HTTPURLResponse
        do { (data, http) = try await transport.send(request) } catch { throw Self.status(for: error) }
        let decoded = try? Self.decoder.decode(GraphQLResponse<AddReviewData>.self, from: data)
        if let review = decoded?.data?.addPullRequestReview?.pullRequestReview { return URL(string: review.url ?? "") }
        if http.statusCode == 401 { throw AccountStatus.badToken }
        throw AccountStatus.failed(decoded?.errors?.first.map { PromptTemplate.clean($0.message, max: 300) } ?? "HTTP \(http.statusCode)")
    }

    /// `discussion.md`. GitHub text as written (it is the agent's input), under headings that name who wrote it.
    static func markdown(_ pr: DiscussionData.PR) -> String {
        func who(_ login: Login?) -> String { "@" + (login?.login ?? "ghost") }
        var lines = ["# \(pr.title ?? "") (#\(pr.number ?? 0))",
                     "Author \(who(pr.author)) · \(pr.state ?? "") · branch \(pr.headRefName ?? "") into \(pr.baseRefName ?? "") · head \(pr.headRefOid ?? "")",
                     "", "## Description", "", (pr.body ?? "").isEmpty ? "(none)" : pr.body ?? ""]
        let reviews = pr.reviews?.items ?? []
        lines += ["", "## Reviews (\(reviews.count))"]
        for r in reviews {
            lines += ["", "### \(who(r.author)) · \(r.state ?? "") · \(r.submittedAt.map { $0.ISO8601Format() } ?? "pending")", "", r.body ?? ""]
            for c in r.comments?.items ?? [] { lines += ["", "- `\(c.path ?? ""):\(c.line.map(String.init) ?? "outdated")` \(who(c.author)): \(c.body ?? "")"] }
        }
        let comments = pr.comments?.items ?? []
        lines += ["", "## Comments (\(comments.count))"]
        for c in comments { lines += ["", "### \(who(c.author)) · \(c.createdAt?.ISO8601Format() ?? "")", "", c.body ?? ""] }
        return lines.joined(separator: "\n") + "\n"
    }
}

struct DiscussionData: Decodable {
    struct PR: Decodable {
        struct Review: Decodable {
            struct Comment: Decodable { var path: String?; var line: Int?; var body: String?; var author: Login? }
            var author: Login?; var state: String?; var submittedAt: Date?; var body: String?; var comments: Nodes<Comment>?
        }
        struct Comment: Decodable { var author: Login?; var createdAt: Date?; var body: String? }
        var number: Int?; var title: String?; var url: String?; var state: String?; var isDraft: Bool?; var headRefOid: String?
        var headRefName: String?; var baseRefName: String?; var body: String?; var author: Login?
        var reviews: Nodes<Review>?; var comments: Nodes<Comment>?
    }
    var node: PR?
}

struct HeadData: Decodable {
    struct Node: Decodable { var headRefOid: String?; var state: String? }
    var node: Node?
}

struct AddReviewData: Decodable {
    struct Payload: Decodable {
        struct Review: Decodable { var url: String?; var state: String? }
        var pullRequestReview: Review?
    }
    var addPullRequestReview: Payload?
}
