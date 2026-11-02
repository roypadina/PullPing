import XCTest
@testable import PullPingCore

final class DeviceFlowTests: XCTestCase {
    let code = DeviceCode(deviceCode: "dev-1", userCode: "WDJB-MJHT", verificationURI: URL(string: "https://github.com/login/device")!, expiresIn: 900, interval: 5)

    final class Sleeps: @unchecked Sendable { var values: [Int] = [] }

    func transport(_ bodies: [String]) -> FakeTransport {
        var queue = bodies
        return FakeTransport { _ in (200, [:], Data(queue.removeFirst().utf8)) }
    }

    func testStart() async throws {
        let fake = transport([#"{"device_code":"dev-1","user_code":"WDJB-MJHT","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#])
        let started = try await DeviceFlow.start(clientID: "client-1", transport: fake)
        XCTAssertEqual(started, code)
        let request = fake.requests[0]
        XCTAssertEqual(request.url?.absoluteString, "https://github.com/login/device/code")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(String(decoding: request.httpBody!, as: UTF8.self), "client_id=client-1&scope=repo%20read:org")
    }

    func testPendingThenToken() async throws {
        let sleeps = Sleeps()
        let fake = transport([#"{"error":"authorization_pending"}"#, #"{"access_token":"gho_test","token_type":"bearer","scope":"repo"}"#])
        let tokens = try await DeviceFlow.poll(code: code, clientID: "client-1", transport: fake) { sleeps.values.append($0) }
        XCTAssertEqual(tokens, OAuthTokens(access: "gho_test", refresh: ""))
        XCTAssertEqual(sleeps.values, [5, 5])
        XCTAssertTrue(String(decoding: fake.requests[0].httpBody!, as: UTF8.self).contains("grant_type=urn:ietf:params:oauth:grant-type:device_code"))
    }

    func testSlowDownAddsFiveSeconds() async throws {
        let sleeps = Sleeps()
        let fake = transport([#"{"error":"slow_down"}"#, #"{"error":"slow_down","interval":20}"#, #"{"access_token":"gho_test"}"#])
        _ = try await DeviceFlow.poll(code: code, clientID: "client-1", transport: fake) { sleeps.values.append($0) }
        XCTAssertEqual(sleeps.values, [5, 10, 20])
    }

    func testErrorsThrow() async {
        for (body, expected) in [(#"{"error":"expired_token"}"#, DeviceFlowError.expired), (#"{"error":"access_denied"}"#, .denied),
                                 (#"{"error":"device_flow_disabled"}"#, .disabled), (#"{"error":"incorrect_client_credentials"}"#, .badClient)] {
            do {
                _ = try await DeviceFlow.poll(code: code, clientID: "client-1", transport: transport([body])) { _ in }
                XCTFail("expected \(expected)")
            } catch {
                XCTAssertEqual(error as? DeviceFlowError, expected)
            }
        }
    }

    /// OAuth apps with expiring tokens also send a refresh token; it must not be dropped.
    func testExpiringTokensKeepTheRefreshToken() async throws {
        let fake = transport([#"{"access_token":"gho_test","expires_in":28800,"refresh_token":"ghr_test","refresh_token_expires_in":15897600,"token_type":"bearer","scope":""}"#])
        let tokens = try await DeviceFlow.poll(code: code, clientID: "client-1", transport: fake) { _ in }
        XCTAssertEqual(tokens, OAuthTokens(access: "gho_test", refresh: "ghr_test"))
    }

    func testRefresh() async throws {
        let fake = transport([#"{"access_token":"gho_new","expires_in":28800,"refresh_token":"ghr_new","refresh_token_expires_in":15897600,"token_type":"bearer"}"#])
        let tokens = try await DeviceFlow.refresh("ghr_old", clientID: "client-1", transport: fake)
        XCTAssertEqual(tokens, OAuthTokens(access: "gho_new", refresh: "ghr_new"))
        let request = fake.requests[0]
        XCTAssertEqual(request.url?.absoluteString, "https://github.com/login/oauth/access_token")
        XCTAssertEqual(request.httpMethod, "POST")
        // No client_secret: device-flow tokens refresh without one.
        XCTAssertEqual(String(decoding: request.httpBody!, as: UTF8.self), "client_id=client-1&grant_type=refresh_token&refresh_token=ghr_old")
    }

    func testBadRefreshTokenThrows() async {
        let fake = transport([#"{"error":"bad_refresh_token","error_description":"The refresh token passed is incorrect or expired."}"#])
        do {
            _ = try await DeviceFlow.refresh("ghr_old", clientID: "client-1", transport: fake)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? DeviceFlowError, .badRefreshToken)
        }
    }

    func testAvailableWithClientID() {
        XCTAssertFalse(GitHubOAuth.clientID.isEmpty)
        XCTAssertTrue(GitHubOAuth.isAvailable)
    }
}
