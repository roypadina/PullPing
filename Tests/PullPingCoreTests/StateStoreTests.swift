import XCTest
@testable import PullPingCore

final class StateStoreTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func pr(_ id: String, state: PRState = .open, closedDaysAgo: Double? = nil) -> TrackedPR {
        var pr = TrackedPR(id: id, accountID: UUID(), firstTrackedAt: t0)
        pr.state = state
        pr.closedAt = closedDaysAgo.map { t0.addingTimeInterval(-$0 * 86_400) }
        pr.roles = [.author]
        pr.events = [PREvent(id: "IC_1", prID: id, kind: .comment, actor: "alice", at: t0, summary: "Hi", url: nil, isOwn: false)]
        return pr
    }

    func testRoundTrip() {
        let url = dir.appendingPathComponent("state.json")
        let store = StateStore(url: url)
        let account = UUID()
        store.update {
            $0.prs["PR_1"] = pr("PR_1")
            $0.ignoredIDs = ["PR_9"]
            $0.baselinedAccounts = [account]
            $0.lastPollAt[account] = t0
        }
        store.save()
        XCTAssertEqual(StateStore(url: url).state, store.state)
    }

    func testDebouncedSaveWrites() {
        let url = dir.appendingPathComponent("state.json")
        StateStore(url: url).update { $0.prs["PR_1"] = pr("PR_1") }
        let written = expectation(description: "debounced write")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
            if FileManager.default.fileExists(atPath: url.path) { written.fulfill() }
        }
        wait(for: [written], timeout: 3)
    }

    func testPruneByRetentionAndIgnored() {
        var state = TrackedState()
        state.prs = ["open": pr("open"), "old": pr("old", state: .merged, closedDaysAgo: 4), "recent": pr("recent", state: .closed, closedDaysAgo: 1),
                     "ignored": pr("ignored")]
        state.ignoredIDs = ["ignored"]
        StateStore.prune(&state, retentionDays: 3, now: t0)
        XCTAssertEqual(Set(state.prs.keys), ["open", "recent"])
    }

    func testCorruptFileIsMovedAside() throws {
        let url = dir.appendingPathComponent("state.json")
        try Data("not json".utf8).write(to: url)
        let store = StateStore(url: url)
        XCTAssertEqual(store.state, TrackedState())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("state.broken.json"), encoding: .utf8), "not json")
    }
}
