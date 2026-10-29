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
        let token = try await DeviceFlow.poll(code: code, clientID: "client-1", transport: fake) { sleeps.values.append($0) }
        XCTAssertEqual(token, "gho_test")
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

    func testHiddenWithoutClientID() {
        XCTAssertEqual(GitHubOAuth.clientID, "")
        XCTAssertFalse(GitHubOAuth.isAvailable)
    }
}
