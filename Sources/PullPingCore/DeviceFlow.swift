import Foundation

/// OAuth App for "Sign in with GitHub". Empty client id hides the option; no client secret is needed.
public enum GitHubOAuth {
    public static let clientID = "Ov23lixF3eKwgYprABzQ"
    public static let scopes = "repo read:org"
    public static var isAvailable: Bool { !clientID.isEmpty }
}

public struct DeviceCode: Decodable, Sendable, Equatable {
    public var deviceCode: String
    public var userCode: String
    public var verificationURI: URL
    public var expiresIn: Int
    public var interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code", userCode = "user_code", verificationURI = "verification_uri", expiresIn = "expires_in", interval
    }
}

public enum DeviceFlowError: Error, Equatable {
    case expired, denied, disabled, badClient, badRefreshToken, failed(String)

    public var message: String {
        switch self {
        case .expired: "The code expired. Start again."
        case .denied: "Access was denied on GitHub."
        case .disabled: "Device flow is not enabled for this OAuth app."
        case .badClient: "The OAuth app client ID is not valid."
        case .badRefreshToken: "The GitHub sign-in expired. Sign in again."
        case .failed(let message): message
        }
    }
}

/// `refresh` is empty unless the OAuth app issues expiring tokens (access 8 h, refresh 6 months).
public struct OAuthTokens: Sendable, Equatable {
    public var access: String
    public var refresh: String
}

/// GitHub device flow: `start` gets the user code, `poll` waits for approval and returns the tokens.
public enum DeviceFlow {
    public static func start(clientID: String = GitHubOAuth.clientID, transport: GraphQLTransport) async throws -> DeviceCode {
        let data = try await post("https://github.com/login/device/code", ["client_id": clientID, "scope": GitHubOAuth.scopes], transport)
        if let code = try? JSONDecoder().decode(DeviceCode.self, from: data) { return code }
        throw error(try? JSONDecoder().decode(TokenResponse.self, from: data))
    }

    /// Sleeps `interval` seconds before each request; `slow_down` adds 5 s. Cancel the task to stop.
    public static func poll(code: DeviceCode, clientID: String = GitHubOAuth.clientID, transport: GraphQLTransport,
                            sleep: @Sendable (Int) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0) * 1_000_000_000) }) async throws -> OAuthTokens {
        var interval = code.interval
        while true {
            try await sleep(interval)
            let data = try await post("https://github.com/login/oauth/access_token", [
                "client_id": clientID, "device_code": code.deviceCode, "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ], transport)
            let response = try? JSONDecoder().decode(TokenResponse.self, from: data)
            if let token = response?.access_token, !token.isEmpty { return OAuthTokens(access: token, refresh: response?.refresh_token ?? "") }
            switch response?.error {
            case "authorization_pending": continue
            case "slow_down": interval = response?.interval ?? interval + 5
            default: throw error(response)
            }
        }
    }

    /// Trades a refresh token for new tokens. Both old ones stop working, so save the new pair at once.
    /// No client secret: GitHub does not need one for tokens from the device flow.
    public static func refresh(_ refreshToken: String, clientID: String = GitHubOAuth.clientID, transport: GraphQLTransport) async throws -> OAuthTokens {
        let data = try await post("https://github.com/login/oauth/access_token", [
            "client_id": clientID, "grant_type": "refresh_token", "refresh_token": refreshToken,
        ], transport)
        let response = try? JSONDecoder().decode(TokenResponse.self, from: data)
        guard let token = response?.access_token, !token.isEmpty else { throw error(response) }
        return OAuthTokens(access: token, refresh: response?.refresh_token ?? "")
    }

    struct TokenResponse: Decodable {
        var access_token: String?
        var refresh_token: String?
        var error: String?
        var error_description: String?
        var interval: Int?
    }

    static func error(_ response: TokenResponse?) -> DeviceFlowError {
        switch response?.error {
        case "expired_token", "token_expired": .expired
        case "access_denied": .denied
        case "device_flow_disabled": .disabled
        case "incorrect_client_credentials": .badClient
        case "bad_refresh_token": .badRefreshToken
        default: .failed(response?.error_description ?? response?.error ?? "Unexpected response from GitHub.")
        }
    }

    /// Errors come back as HTTP 200 with an `error` field, so the status code is not checked.
    private static func post(_ url: String, _ form: [String: String], _ transport: GraphQLTransport) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = form.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        return try await transport.send(request).0
    }
}
