import XCTest
@testable import PullPingCore

final class SearchQueriesTests: XCTestCase {
    func testQueryStrings() {
        XCTAssertEqual(SearchQueries.involved, "is:pr is:open archived:false involves:@me")
        XCTAssertEqual(SearchQueries.requested, "is:pr is:open archived:false review-requested:@me")
        XCTAssertEqual(SearchQueries.reviewed, "is:pr is:open archived:false reviewed-by:@me")
        XCTAssertEqual(SearchQueries.issues, "is:issue is:open archived:false involves:@me")
    }
}
