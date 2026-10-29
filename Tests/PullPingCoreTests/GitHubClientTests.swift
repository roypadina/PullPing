import XCTest
@testable import PullPingCore

final class GitHubClientTests: XCTestCase {
    func response(_ code: Int, _ headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: GitHubClient.endpoint, statusCode: code, httpVersion: nil, headerFields: headers)!
    }

    func testErrorMapping() {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(GitHubClient.status(response(401), errors: [], hasData: false), .badToken)
        XCTAssertEqual(GitHubClient.status(response(403, ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1800000000"]), errors: [], hasData: false),
                       .rateLimited(resetAt: reset))
        XCTAssertEqual(GitHubClient.status(response(200, ["x-ratelimit-reset": "1800000000"]), errors: [GraphQLError(type: "RATE_LIMITED", message: "API rate limit exceeded")], hasData: false),
                       .rateLimited(resetAt: reset))
        XCTAssertEqual(GitHubClient.status(response(403), errors: [], hasData: false), .failed("HTTP 403"))  // not a rate limit
        XCTAssertEqual(GitHubClient.status(response(200), errors: [GraphQLError(type: "FORBIDDEN", message: "Resource protected by organization SAML enforcement.")], hasData: true),
                       .ssoRequired)
        XCTAssertEqual(GitHubClient.status(response(200), errors: [GraphQLError(type: "FORBIDDEN", message: "Resource not accessible by integration")], hasData: true),
                       .missingScope("repo"))
        XCTAssertEqual(GitHubClient.status(response(502), errors: [], hasData: false), .failed("HTTP 502"))
        XCTAssertEqual(GitHubClient.status(response(200), errors: [GraphQLError(type: "SOMETHING", message: "Boom")], hasData: false), .failed("Boom"))
        XCTAssertNil(GitHubClient.status(response(200), errors: [GraphQLError(type: "NOT_FOUND", message: "Could not resolve")], hasData: true))
        XCTAssertEqual(GitHubClient.status(for: URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(GitHubClient.status(for: URLError(.timedOut)), .offline)
        XCTAssertEqual(GitHubClient.status(for: AccountStatus.badToken), .badToken)
        if case .failed = GitHubClient.status(for: URLError(.badURL)) {} else { XCTFail("badURL should be .failed") }
    }

    func testClientThrowsMappedStatus() async {
        let client = GitHubClient(transport: FakeTransport { _ in (401, [:], Data(#"{"message":"Bad credentials"}"#.utf8)) }, token: "t")
        do {
            _ = try await client.me()
            XCTFail("expected badToken")
        } catch {
            XCTAssertEqual(error as? AccountStatus, .badToken)
        }
        let offline = GitHubClient(transport: FakeTransport { _ in throw URLError(.networkConnectionLost) }, token: "t")
        do {
            _ = try await offline.discover()
            XCTFail("expected offline")
        } catch {
            XCTAssertEqual(error as? AccountStatus, .offline)
        }
    }

    func testScopes() async throws {
        XCTAssertEqual(GitHubClient.scopes(response(200, ["X-OAuth-Scopes": "repo, read:org"])), ["repo", "read:org"])
        XCTAssertEqual(GitHubClient.scopes(response(200, ["X-OAuth-Scopes": ""])), [])
        XCTAssertNil(GitHubClient.scopes(response(200)))
        XCTAssertEqual(GitHubClient.scopeStatus(["read:org"]), .missingScope("repo"))
        XCTAssertEqual(GitHubClient.scopeStatus([]), .missingScope("repo"))
        XCTAssertNil(GitHubClient.scopeStatus(["public_repo"]))
        XCTAssertNil(GitHubClient.scopeStatus(nil))  // fine-grained token

        let body = #"{"data":{"viewer":{"login":"dana","avatarUrl":"https://avatars.githubusercontent.com/u/1"},"rateLimit":{"cost":1,"remaining":4999,"resetAt":"2026-10-29T11:00:00Z"}}}"#
        let client = GitHubClient(transport: FakeTransport { _ in (200, ["X-OAuth-Scopes": "gist, read:org"], Data(body.utf8)) }, token: "t")
        let viewer = try await client.me()
        XCTAssertEqual(viewer.login, "dana")
        XCTAssertEqual(viewer.scopes, ["gist", "read:org"])
        XCTAssertEqual(viewer.status, .missingScope("repo"))
    }

    func testBatching() async throws {
        XCTAssertEqual([Int](0..<45).chunked(20).map(\.count), [20, 20, 5])
        XCTAssertTrue([Int]().chunked(20).isEmpty)
        let transport = FakeTransport { request in
            let ids = FakeTransport.operation(request).variables["ids"] as! [String]
            let nodes = ids.map { _ in "null" }.joined(separator: ",")
            return (200, [:], Data(#"{"data":{"nodes":[\#(nodes)]}}"#.utf8))
        }
        let (stamps, dropped) = try await GitHubClient(transport: transport, token: "t").stamps((0..<250).map { "PR_\($0)" })
        XCTAssertTrue(stamps.isEmpty)
        XCTAssertEqual(dropped.count, 250)
        XCTAssertEqual(transport.requests.map { (FakeTransport.operation($0).variables["ids"] as! [String]).count }, [100, 100, 50])
        XCTAssertEqual(GitHubClient.refreshBatch, 20)
    }
}
