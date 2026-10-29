import XCTest
@testable import PullPingCore

final class NtfyTests: XCTestCase {
    func pr(author: Bool = false) -> TrackedPR {
        var pr = TrackedPR(id: "PR_1", accountID: UUID(), firstTrackedAt: t0)
        pr.roles = author ? [.author] : [.reviewRequested]
        return pr
    }

    func event(_ kind: EventKind, own: Bool = false) -> PREvent {
        PREvent(id: "e", prID: "PR_1", kind: kind, actor: "alice", at: t0, summary: "", url: nil, isOwn: own)
    }

    var settings: AppSettings {
        var settings = AppSettings()
        settings.ntfyTopic = "team-prs"
        settings.phoneMine = [.ciFailed]
        settings.phoneOthers = [.reviewRequested]
        return settings
    }

    func testSendDecision() {
        let s = settings
        XCTAssertTrue(s.pushesToPhone(event(.ciFailed), pr: pr(author: true), now: t0))
        XCTAssertFalse(s.pushesToPhone(event(.ciFailed), pr: pr(), now: t0))  // others use their own set
        XCTAssertTrue(s.pushesToPhone(event(.reviewRequested), pr: pr(), now: t0))
        XCTAssertTrue(s.pushesToPhone(event(.reviewReminder), pr: pr(), now: t0))  // follows reviewRequested
        XCTAssertFalse(s.pushesToPhone(event(.reviewRequested, own: true), pr: pr(), now: t0))

        var offDesktop = s
        offDesktop.otherStyles[.reviewRequested] = .off
        XCTAssertTrue(offDesktop.pushesToPhone(event(.reviewRequested), pr: pr(), now: t0))  // independent of the panel style

        var hidden = pr()
        hidden.hidden = true
        XCTAssertTrue(s.pushesToPhone(event(.reviewRequested), pr: hidden, now: t0))
        var muted = pr()
        muted.muted = true
        XCTAssertFalse(s.pushesToPhone(event(.reviewRequested), pr: muted, now: t0))
        var snoozed = pr()
        snoozed.snoozedUntil = t0.addingTimeInterval(60)
        XCTAssertFalse(s.pushesToPhone(event(.reviewRequested), pr: snoozed, now: t0))
        XCTAssertTrue(s.pushesToPhone(event(.reviewRequested), pr: snoozed, now: t0.addingTimeInterval(61)))

        var paused = s
        paused.pausedUntil = t0.addingTimeInterval(60)
        XCTAssertFalse(paused.pushesToPhone(event(.reviewRequested), pr: pr(), now: t0))
        XCTAssertFalse(paused.allowsNotifications(for: pr(), now: t0))  // panels and reminders too
        XCTAssertTrue(paused.pushesToPhone(event(.reviewRequested), pr: pr(), now: t0.addingTimeInterval(61)))

        var disabled = s
        disabled.notificationsEnabled = false
        XCTAssertFalse(disabled.pushesToPhone(event(.reviewRequested), pr: pr(), now: t0))
        var noTopic = s
        noTopic.ntfyTopic = ""
        XCTAssertFalse(noTopic.pushesToPhone(event(.reviewRequested), pr: pr(), now: t0))
        XCTAssertFalse(AppSettings().pushesToPhone(event(.reviewRequested), pr: pr(), now: t0))  // nothing until opted in
    }

    func testPublishPayloadAndToken() async throws {
        let transport = FakeTransport { _ in (200, [:], Data(#"{"id":"abc"}"#.utf8)) }
        let message = Ntfy.Message(title: "CI failed: octo-org/widgets #1", body: "Add widget cache\nCI failed", priority: 4,
                                   tags: ["ciFailed"], click: URL(string: "https://github.com/octo-org/widgets/pull/1"), flow: "pr-event")
        let ok = await Ntfy.send(message, config: NtfyConfig(server: "https://ntfy.example.com", topic: "team-prs", token: "tk_1", fallbackURL: ""),
                                 transport: transport, now: t0)
        XCTAssertTrue(ok)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://ntfy.example.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tk_1")
        let body = try JSONDecoder().decode(Ntfy.Publish.self, from: XCTUnwrap(request.httpBody))
        XCTAssertEqual(body.topic, "team-prs")
        XCTAssertEqual(body.title, "CI failed: octo-org/widgets #1")
        XCTAssertEqual(body.tags, ["pullping", "ciFailed"])
        XCTAssertEqual(body.priority, 4)
        XCTAssertEqual(body.click, "https://github.com/octo-org/widgets/pull/1")
        XCTAssertTrue(body.message.hasPrefix("Add widget cache\nCI failed\n\nsender: pullping@"))
        XCTAssertTrue(body.message.contains("\nflow: pr-event\nevent: \(Ntfy.eventID(t0).prefix(15))"))
    }

    func testFallbackOnFailureWithoutToken() async throws {
        let transport = FakeTransport { $0.url?.host() == "ntfy.example.com" ? (500, [:], Data()) : (200, [:], Data()) }
        let config = NtfyConfig(server: "https://ntfy.example.com", topic: "team-prs", token: "tk_1", fallbackURL: "https://backup.example.org/backup-topic")
        let ok = await Ntfy.send(Ntfy.Message(title: "t", body: "b", priority: 3, tags: [], click: nil, flow: "test"),
                                 config: config, transport: transport)
        XCTAssertTrue(ok)
        XCTAssertEqual(transport.requests.count, 2)
        let fallback = transport.requests[1]
        XCTAssertEqual(fallback.url?.absoluteString, "https://backup.example.org")
        XCTAssertNil(fallback.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(try JSONDecoder().decode(Ntfy.Publish.self, from: XCTUnwrap(fallback.httpBody)).topic, "backup-topic")

        let noFallback = FakeTransport { _ in (500, [:], Data()) }
        let failed = await Ntfy.send(Ntfy.Message(title: "t", body: "b", priority: 3, tags: [], click: nil, flow: "test"),
                                     config: NtfyConfig(server: "https://ntfy.example.com", topic: "team-prs", token: "", fallbackURL: ""),
                                     transport: noFallback)
        XCTAssertFalse(failed)
        XCTAssertEqual(noFallback.requests.count, 1)
    }
}
