import XCTest
@testable import PullPingCore

/// Mute a repository (`RepoMute`) and the lists' Repository choice (`RepoFilter`).
final class ReposTests: XCTestCase {
    let account = UUID()

    func item(_ id: String, _ repo: String, muted: Bool = false) -> TrackedPR {
        var pr = TrackedPR(id: id, accountID: account, firstTrackedAt: t0)
        pr.repo = repo
        pr.muted = muted
        return pr
    }

    /// PR_1, PR_2: octo-org/widgets (PR_2 muted one by one); PR_3: octo-org/gadgets.
    func state() -> TrackedState {
        var state = TrackedState()
        for pr in [item("PR_1", "Octo-Org/Widgets"), item("PR_2", "octo-org/widgets", muted: true), item("PR_3", "octo-org/gadgets")] {
            state.prs[pr.id] = pr
        }
        return state
    }

    func testMute() {
        var state = state()
        XCTAssertEqual(RepoMute.mute(["octo-org/WIDGETS"], in: &state), ["PR_1"], "only items not muted yet")
        XCTAssertEqual(state.mutedRepos, ["octo-org/widgets"])
        XCTAssertEqual([state.prs["PR_1"]?.muted, state.prs["PR_1"]?.mutedByRepo], [true, true])
        XCTAssertEqual([state.prs["PR_2"]?.muted, state.prs["PR_2"]?.mutedByRepo], [true, false], "muted one by one before")
        XCTAssertEqual(state.prs["PR_3"]?.muted, false)
        XCTAssertTrue(RepoMute.isMuted("Octo-Org/Widgets", state.mutedRepos))
        XCTAssertFalse(RepoMute.isMuted("octo-org/gadgets", state.mutedRepos))
        XCTAssertFalse(RepoMute.isMuted("octo-org/widgets", nil))

        var limited = self.state()
        limited.prs["PR_4"] = item("PR_4", "octo-org/widgets")
        XCTAssertEqual(RepoMute.mute(["octo-org/widgets"], in: &limited, only: ["PR_4"]), ["PR_4"], "only: just these ids")
        XCTAssertEqual(limited.prs["PR_1"]?.muted, false)
    }

    func testUnmute() {
        var state = state()
        state.prs["PR_4"] = item("PR_4", "octo-org/widgets")
        RepoMute.mute(["octo-org/widgets", "octo-org/gadgets"], in: &state)
        state.prs["PR_4"]?.muted = false  // unmuted by hand in between (`Store.setMuted` clears the flag too)
        state.prs["PR_4"]?.mutedByRepo = false
        XCTAssertEqual(RepoMute.unmute(["Octo-Org/Widgets"], in: &state), ["PR_1"])
        XCTAssertEqual(state.mutedRepos, ["octo-org/gadgets"])
        XCTAssertEqual([state.prs["PR_1"]?.muted, state.prs["PR_1"]?.mutedByRepo], [false, false])
        XCTAssertEqual(state.prs["PR_2"]?.muted, true, "muted one by one: stays")
        XCTAssertEqual(state.prs["PR_4"]?.muted, false, "untouched")
        XCTAssertEqual(state.prs["PR_3"]?.muted, true, "another repository")
        var empty = TrackedState()
        XCTAssertEqual(RepoMute.unmute(["octo-org/widgets"], in: &empty), [])
        XCTAssertNil(empty.mutedRepos)
    }

    /// Undo of a mute = unmute; undo of an unmute = mute `only` the ids it unmuted: exactly the changed items go back.
    func testUndoRestoresExactlyTheChangedItems() {
        var state = state()
        let before = state
        let muted = RepoMute.mute(["octo-org/widgets"], in: &state)
        RepoMute.unmute(["octo-org/widgets"], in: &state)
        XCTAssertEqual(state.prs, before.prs)
        XCTAssertEqual(state.mutedRepos, [])
        RepoMute.mute(["octo-org/widgets"], in: &state, only: muted)  // redo
        let afterMute = state
        state.prs["PR_5"] = item("PR_5", "octo-org/widgets")  // tracked meanwhile, not by this mute
        let unmuted = RepoMute.unmute(["octo-org/widgets"], in: &state)
        XCTAssertEqual(RepoMute.mute(["octo-org/widgets"], in: &state, only: unmuted), ["PR_1"])
        XCTAssertEqual(state.prs["PR_5"]?.muted, false)
        state.prs["PR_5"] = nil
        XCTAssertEqual(state, afterMute)
    }

    func testApply() {
        var new = item("PR_9", "Octo-Org/Widgets")
        RepoMute.apply(&new, muted: ["octo-org/widgets"])
        XCTAssertEqual([new.muted, new.mutedByRepo], [true, true])
        var other = item("PR_9", "octo-org/gadgets")
        RepoMute.apply(&other, muted: ["octo-org/widgets"])
        XCTAssertEqual([other.muted, other.mutedByRepo], [false, false])
        var none = item("PR_9", "octo-org/widgets")
        RepoMute.apply(&none, muted: nil)
        XCTAssertFalse(none.muted)
        var already = item("PR_9", "octo-org/widgets", muted: true)
        RepoMute.apply(&already, muted: ["octo-org/widgets"])
        XCTAssertFalse(already.mutedByRepo, "muted one by one stays so")
    }

    func testTitle() {
        XCTAssertEqual(RepoMute.title(repos: ["octo-org/widgets"], muted: false), "Mute octo-org/widgets")
        XCTAssertEqual(RepoMute.title(repos: ["octo-org/widgets"], muted: true), "Unmute octo-org/widgets")
        XCTAssertEqual(RepoMute.title(repos: ["a/b", "c/d", "e/f"], muted: false), "Mute 3 Repositories")
        XCTAssertEqual(RepoMute.title(repos: ["a/b", "c/d", "e/f"], muted: true), "Unmute 3 Repositories")
        XCTAssertEqual(RepoMute.title(repos: [], muted: false), "Mute Repository")
    }

    func testRepoFilter() {
        let prs = [item("1", "octo-org/widgets"), item("2", "Alice/Dotfiles"), item("3", "Octo-Org/Widgets"), item("4", "octo-org/docs"), item("5", "")]
        let repos = RepoFilter.repos(prs)
        XCTAssertEqual(repos, ["Alice/Dotfiles", "octo-org/docs", "octo-org/widgets"], "once, first casing, sorted case-insensitively")
        XCTAssertNil(RepoFilter.active("", in: repos))
        XCTAssertNil(RepoFilter.active("octo-org/legacy", in: repos), "not in the scope: All Repositories")
        XCTAssertEqual(RepoFilter.active("OCTO-ORG/widgets", in: repos), "octo-org/widgets")
        XCTAssertTrue(RepoFilter.matches("Octo-Org/Widgets", "octo-org/widgets"))
        XCTAssertFalse(RepoFilter.matches("octo-org/docs", "octo-org/widgets"))
        XCTAssertTrue(RepoFilter.matches("octo-org/docs", nil))
    }
}
