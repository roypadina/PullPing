import Foundation

/// The HTTP seam: URLSession in the app, scripted responses in tests. Also used by `DeviceFlow`.
public protocol GraphQLTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: GraphQLTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

public struct Viewer: Sendable, Equatable {
    public var login: String
    public var avatarURL: URL?
    /// `X-OAuth-Scopes`; nil for fine-grained tokens (no header).
    public var scopes: [String]?
    /// `.ok`, or `.missingScope("repo")` when a classic token has neither `repo` nor `public_repo`.
    public var status: AccountStatus
}

/// One client per poll: it sums the GraphQL cost and keeps the last rate limit, scopes and partial-data warning.
/// Throws `AccountStatus`.
public final class GitHubClient {
    public static let endpoint = URL(string: "https://api.github.com/graphql")!
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    let transport: GraphQLTransport
    private let token: String
    public private(set) var cost = 0
    public private(set) var rateLimit: RateLimit?
    /// GitHub returned data plus errors (SAML, missing access): the data is used, this status is shown.
    public private(set) var warning: AccountStatus?
    public private(set) var scopes: [String]?

    public init(transport: GraphQLTransport, token: String) {
        self.transport = transport
        self.token = token
    }

    public func me() async throws -> Viewer {
        let data: MeData = try await run(GraphQL.me)
        return Viewer(login: data.viewer.login, avatarURL: data.viewer.avatarUrl, scopes: scopes, status: Self.scopeStatus(scopes) ?? .ok)
    }

    func run<T: Decodable>(_ query: String, _ variables: [String: Any] = [:]) async throws -> T {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let data: Data, http: HTTPURLResponse
        do { (data, http) = try await transport.send(request) } catch { throw Self.status(for: error) }
        scopes = Self.scopes(http)
        let decoded = Result { try Self.decoder.decode(GraphQLResponse<T>.self, from: data) }
        let ok = (200..<300).contains(http.statusCode)
        if case .failure(let error) = decoded, ok { throw AccountStatus.failed("Unexpected response: \(error)") }
        let body = try? decoded.get()
        let status = Self.status(http, errors: body?.errors ?? [], hasData: body?.data != nil)
        guard let payload = body?.data, ok else { throw status ?? .failed("HTTP \(http.statusCode)") }
        if let limit = (try? Self.decoder.decode(GraphQLResponse<RateLimitHolder>.self, from: data))?.data?.rateLimit {
            cost += limit.cost
            rateLimit = limit
        }
        if let status { warning = status }
        return payload
    }

    /// Maps an HTTP response and its GraphQL errors; nil = fine (partial data with unknown errors is used as is).
    public static func status(_ http: HTTPURLResponse, errors: [GraphQLError], hasData: Bool) -> AccountStatus? {
        let header = { http.value(forHTTPHeaderField: $0) }
        let resetAt = header("x-ratelimit-reset").flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:)) ?? Date().addingTimeInterval(60)
        if http.statusCode == 401 { return .badToken }
        if ([403, 429].contains(http.statusCode) && header("x-ratelimit-remaining") == "0") || errors.contains(where: { $0.type == "RATE_LIMITED" }) {
            return .rateLimited(resetAt: resetAt)
        }
        if errors.contains(where: { $0.message.contains("SAML") }) { return .ssoRequired }
        if errors.contains(where: { $0.message.contains("Resource not accessible") }) { return .missingScope("repo") }
        if !(200..<300).contains(http.statusCode) { return .failed("HTTP \(http.statusCode)") }
        if !hasData { return .failed(errors.first?.message ?? "Empty response") }
        return nil
    }

    public static func status(for error: Error) -> AccountStatus {
        if let status = error as? AccountStatus { return status }
        let offline: [URLError.Code] = [.notConnectedToInternet, .cannotFindHost, .networkConnectionLost, .timedOut]
        if let error = error as? URLError, offline.contains(error.code) { return .offline }
        return .failed(error.localizedDescription)
    }

    /// Classic and OAuth tokens list their scopes; fine-grained tokens send no header (nil).
    public static func scopes(_ http: HTTPURLResponse) -> [String]? {
        http.value(forHTTPHeaderField: "X-OAuth-Scopes").map {
            $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }

    public static func scopeStatus(_ scopes: [String]?) -> AccountStatus? {
        guard let scopes, !scopes.contains("repo"), !scopes.contains("public_repo") else { return nil }
        return .missingScope("repo")
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
