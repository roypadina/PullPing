import XCTest
@testable import PullPingCore

/// Scenario prompts (`Scenario`) and Handle with Agent's menu (`HandlerMenuModel`).
final class ScenarioTests: XCTestCase {
    func event(_ kind: EventKind, summary: String = "") -> PREvent {
        PREvent(id: "E-\(kind.rawValue)", prID: "P", kind: kind, actor: "alice", at: t0, summary: summary, url: nil, isOwn: false)
    }

    func pr(_ roles: Set<Role>, _ change: (inout TrackedPR) -> Void = { _ in }) -> TrackedPR {
        var p = TrackedPR(id: "P", accountID: UUID(), firstTrackedAt: t0)
        p.roles = roles
        p.authorLogin = roles.contains(.author) ? me : "bob"
        p.headOID = "h2"
        change(&p)
        return p
    }

    /// Every row of the taxonomy: each `NeedReason` maps to one scenario, only a Remind Me reminder to `general`.
    func testEveryReasonMapsToItsScenario() {
        let expected: [NeedReason?: Scenario] = [
            .toReview: .review, .teamToReview: .review, .reReview: .reReview, .changesRequested: .changesRequested,
            .newComments: .comments, .mentioned: .comments, .ciFailed: .ciFailed, .conflicts: .conflicts,
            .readyToMerge: .readyToMerge, .assigned: .assigned, .toTriage: .issueTriage, .reminder: .general, nil: .general,
        ]
        XCTAssertEqual(Set(expected.keys.compactMap { $0 }), Set(NeedReason.allCases))
        for (reason, scenario) in expected { XCTAssertEqual(Scenario(reason), scenario, "\(String(describing: reason))") }
        XCTAssertEqual(Set(Scenario.allCases.map(\.label)).count, Scenario.allCases.count)
        XCTAssertTrue(Scenario.allCases.allSatisfy { !$0.builtIn.isEmpty && $0.builtIn.count <= Scenario.maxTaskLength })
    }

    func testDerive() {
        let mine = pr([.author]) { $0.reviewDecision = "CHANGES_REQUESTED"; $0.ci = .failure }
        // The event handed over beats the pull request's state.
        XCTAssertEqual(Scenario.derive(events: [event(.mentioned)], pr: mine), .comments)
        // Several events: the highest priority (CI failed outranks a new comment).
        XCTAssertEqual(Scenario.derive(events: [event(.comment), event(.ciFailed)], pr: mine), .ciFailed)
        XCTAssertEqual(Scenario.derive(events: [event(.reviewChangesRequested), event(.comment)], pr: mine), .changesRequested)
        // No event (a menu, pullping run): what the pull request needs now.
        XCTAssertEqual(Scenario.derive(events: [], pr: mine), Scenario(Attention.needReason(mine)))
        XCTAssertNotEqual(Scenario.derive(events: [], pr: mine), .general)
        // Events that ask nothing fall back to the state; nothing at all is general.
        XCTAssertEqual(Scenario.derive(events: [event(.labeled)], pr: pr([.reviewer])), .general)
        XCTAssertEqual(Scenario.derive(events: [event(.reviewRequested)], pr: pr([.reviewRequested])), .review)
        XCTAssertEqual(Scenario.derive(events: [event(.reviewRequested, summary: "via team core")], pr: pr([.teamReviewRequested])), .review)
    }

    /// A new issue in a repository I watch: its event, or an item still to triage, picks the New issue task.
    func testIssueTriage() {
        let watched = pr([]) { $0.isIssue = true; $0.watched = true; $0.events = [self.event(.issueOpened)] }
        XCTAssertEqual(Scenario.derive(events: [event(.issueOpened)], pr: watched), .issueTriage)
        XCTAssertEqual(Scenario.derive(events: [], pr: watched), .issueTriage)
        XCTAssertEqual(Scenario.issueTriage.label, "New issue")
        XCTAssertTrue(Scenario.issueTriage.builtIn.contains("Do not comment, label, assign or close anything on GitHub: draft the reply and wait for my OK."))
        XCTAssertTrue(Scenario.issueTriage.builtIn.contains("`gh issue view {pr_number} --repo {repo} --comments`"))
    }

    func testTaskTextOverrides() {
        var file = AutomationFile()
        XCTAssertEqual(file.task(.review), Scenario.review.builtIn)
        file.scenarioPrompts = ["review": "Mine", "ciFailed": "  \n"]
        XCTAssertEqual(file.task(.review), "Mine")
        XCTAssertEqual(file.task(.ciFailed), Scenario.ciFailed.builtIn, "blank = built-in")
    }

    // MARK: HandlerMenuModel

    let ghostex = LaunchTarget(id: "ghostex", name: "Ghostex", launcher: .ghostex)
    let terminal = LaunchTarget(id: "terminal", name: "Terminal", launcher: .terminal)

    func titles(_ sections: [HandlerMenuSection]) -> [String] {
        sections.map { ($0.title.map { "[\($0)] " } ?? "") + $0.items.map(\.title).joined(separator: " | ") }
    }

    func testMenuWithALinkedSession() {
        let two = HandlerMenuModel.sections(targets: [ghostex, terminal], linked: "1a2b3c4d", earlier: nil)
        XCTAssertEqual(titles(two), ["[Ghostex] Resume Session (1a2b…) | Resume Without Prompt | New Session",
                                     "[Terminal] Resume Session | Resume Without Prompt | New Session"])
        XCTAssertEqual(two[1].items.map(\.choice), [.resume(target: "terminal", prompt: true), .resume(target: "terminal", prompt: false), .new(target: "terminal")])
        let one = HandlerMenuModel.sections(targets: [ghostex], linked: "1a2b3c4d", earlier: nil)
        XCTAssertEqual(titles(one), ["Resume Session (1a2b…) | Resume Without Prompt | New Session"])
    }

    func testMenuWithoutASession() {
        XCTAssertEqual(titles(HandlerMenuModel.sections(targets: [ghostex, terminal], linked: nil, earlier: nil)),
                       ["Handle in Ghostex | Handle in Terminal", "Find Earlier Session…"])
        let one = HandlerMenuModel.sections(targets: [terminal], linked: nil, earlier: nil)
        XCTAssertEqual(titles(one), ["Handle with Agent", "Find Earlier Session…"])
        XCTAssertEqual(one.flatMap(\.items).map(\.choice), [.handle(target: "terminal"), .findEarlier])
        // A found, unlinked session: Resume Earlier per target, no Resume Without Prompt (nothing linked yet).
        XCTAssertEqual(titles(HandlerMenuModel.sections(targets: [ghostex, terminal], linked: nil, earlier: "9f8e…, 2 hr. ago")),
                       ["[Ghostex] Resume Earlier Session (9f8e…, 2 hr. ago) | New Session",
                        "[Terminal] Resume Earlier Session (9f8e…, 2 hr. ago) | New Session", "Find Earlier Session…"])
    }
}
