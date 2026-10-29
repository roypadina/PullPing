import Foundation
@testable import PullPingCore

let me = "dana"
let t0 = Date(timeIntervalSince1970: 1_800_000_000)  // whole seconds: survives ISO-8601 round trips

func fixture(_ name: String) -> Data {
    try! Data(contentsOf: Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!)
}

func iso(_ date: Date) -> String { date.ISO8601Format() }

/// Scripted HTTP: `handler` sees every request; `delay` keeps a request in flight.
final class FakeTransport: GraphQLTransport, @unchecked Sendable {
    typealias Reply = (status: Int, headers: [String: String], body: Data)
    private let lock = NSLock()
    private var log: [URLRequest] = []
    private let delay: UInt64
    private let handler: (URLRequest) throws -> Reply

    init(delay: UInt64 = 0, handler: @escaping (URLRequest) throws -> Reply) {
        self.delay = delay
        self.handler = handler
    }

    var requests: [URLRequest] { lock.withLock { log } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { log.append(request) }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        let reply = try handler(request)
        return (reply.body, HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!)
    }

    /// GraphQL operation name ("Discover", "Refresh", …) and variables.
    static func operation(_ request: URLRequest) -> (name: String, variables: [String: Any]) {
        let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let query = body["query"] as! String
        let name = query.split(whereSeparator: { $0 == " " || $0 == "(" || $0 == "{" })[1]
        return (String(name), body["variables"] as? [String: Any] ?? [:])
    }

    func operations() -> [String] { requests.map { Self.operation($0).name } }
}

/// A tiny GitHub: open PRs found by the involved/requested searches, node JSON per id, a rate limit.
final class FakeGitHub: @unchecked Sendable {
    struct PR { var updatedAt: Date; var state = "OPEN"; var node: String }
    var prs: [String: PR] = [:]
    var involved: [String] = []
    var requested: [String] = []
    var remaining = 4000
    var failing = false
    lazy var transport = FakeTransport { [unowned self] in self.reply($0) }

    func reply(_ request: URLRequest) -> FakeTransport.Reply {
        if failing { return (500, [:], Data("oops".utf8)) }
        let (name, variables) = FakeTransport.operation(request)
        let rate = #""rateLimit": { "cost": 1, "remaining": \#(remaining), "resetAt": "\#(iso(t0.addingTimeInterval(3600)))" }"#
        func search(_ ids: [String]) -> String {
            let nodes = ids.compactMap { id in prs[id].map { #"{ "id": "\#(id)", "updatedAt": "\#(iso($0.updatedAt))" }"# } }
            return #"{ "issueCount": \#(nodes.count), "pageInfo": { "hasNextPage": false, "endCursor": null }, "nodes": [\#(nodes.joined(separator: ","))] }"#
        }
        let ids = variables["ids"] as? [String] ?? []
        let body: String
        switch name {
        case "Discover":
            body = #"{ "data": { "viewer": { "login": "dana" }, "involved": \#(search(involved)), "requested": \#(search(requested)), "reviewed": \#(search([])), \#(rate) } }"#
        case "Stamps":
            let nodes = ids.map { id in prs[id].map { #"{ "id": "\#(id)", "updatedAt": "\#(iso($0.updatedAt))", "state": "\#($0.state)" }"# } ?? "null" }
            body = #"{ "data": { "nodes": [\#(nodes.joined(separator: ","))], \#(rate) } }"#
        case "Refresh":
            body = #"{ "data": { "nodes": [\#(ids.map { prs[$0]?.node ?? "null" }.joined(separator: ","))], \#(rate) } }"#
        default:
            return (400, [:], Data())
        }
        return (200, [:], Data(body.utf8))
    }
}

/// A `Refresh` node; `timeline` is a JSON array body.
func prNode(_ id: String, number: Int, author: String = "dana", updatedAt: Date, state: String = "OPEN", head: String = "aaa1111",
            ci: String? = nil, requested: [String] = [], timeline: String = "") -> String {
    let rollup = ci.map { #"{ "state": "\#($0)", "contexts": { "nodes": [] } }"# } ?? "null"
    let reviewRequests = requested.map { #"{ "requestedReviewer": { "__typename": "User", "login": "\#($0)" } }"# }.joined(separator: ",")
    return #"""
    { "id": "\#(id)", "number": \#(number), "title": "PR \#(number)", "url": "https://github.com/octo-org/widgets/pull/\#(number)",
      "isDraft": false, "state": "\#(state)", "merged": \#(state == "MERGED"), "mergedAt": null, "closedAt": \#(state == "OPEN" ? "null" : "\"\(iso(updatedAt))\""),
      "updatedAt": "\#(iso(updatedAt))", "headRefOid": "\#(head)", "body": "", "reviewDecision": null, "mergeStateStatus": "CLEAN",
      "author": { "login": "\#(author)" }, "repository": { "nameWithOwner": "octo-org/widgets" },
      "assignees": { "nodes": [] }, "reviewRequests": { "nodes": [\#(reviewRequests)] }, "latestReviews": { "nodes": [] },
      "commits": { "nodes": [ { "commit": { "oid": "\#(head)", "author": { "user": { "login": "\#(author)" } }, "statusCheckRollup": \#(rollup) } } ] },
      "timelineItems": { "pageInfo": { "hasNextPage": false, "endCursor": null }, "nodes": [\#(timeline)] } }
    """#
}

final class Clock: @unchecked Sendable {
    var now = t0
}

func snap(_ id: String = "PR_1", author: String = "bob", head: String = "aaa1111", ci: CIState = .none, requested: [String] = [],
          teams: [String] = [], assignees: [String] = [], timeline: [TimelineNode] = [], updatedAt: Date = t0, body: String = "",
          state: PRState = .open) -> PRSnapshot {
    var s = PRSnapshot(id: id)
    s.repo = "octo-org/widgets"
    s.number = 1
    s.title = "Add widget cache"
    s.url = URL(string: "https://github.com/octo-org/widgets/pull/1")!
    s.authorLogin = author
    s.headOID = head
    s.headAuthorLogin = author
    s.ci = ci
    s.reviewers = requested.map { ReviewSummary(login: $0, state: "", submittedAt: nil, requested: true) }
    s.requestedTeams = teams
    s.assignees = assignees
    s.timeline = timeline
    s.updatedAt = updatedAt
    s.body = body
    s.state = state
    return s
}

func node(_ id: String, _ type: String = "IssueComment", by actor: String, at: Date, body: String = "", review: String? = nil) -> TimelineNode {
    TimelineNode(id: id, type: type, at: at, actor: actor, body: body, reviewState: review)
}
