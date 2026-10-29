import XCTest
@testable import PullPingCore

final class KeychainTests: XCTestCase {
    func testPasswordParsesSecurityOutput() {
        XCTAssertEqual(Keychain.password("password: \"tk_abc\"\n"), "tk_abc")
        XCTAssertEqual(Keychain.password("password: \"deadbeef\"\n"), "deadbeef")  // hex-looking text stays text
        XCTAssertEqual(Keychain.password("password: \"a\"b c\"\n"), "a\"b c")
        XCTAssertEqual(Keychain.password("password: 0xD7A9D79CD795D79D \n"), "שלום")
        XCTAssertNil(Keychain.password("security: SecKeychainSearchCopyNext: not found\n"))
    }

    func testServiceName() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
        XCTAssertEqual(Keychain.service(for: id), "com.padina.pullping.token.00000000-0000-0000-0000-00000000000A")
        XCTAssertEqual(Account(id: id, login: "dana").tokenService, Keychain.service(for: id))
    }
}
