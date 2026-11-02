import XCTest
@testable import PullPingCore

final class ActivityLogTests: XCTestCase {
    var dir: URL!
    var url: URL { dir.appendingPathComponent("activity.jsonl") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    let accountID = UUID()

    func pr(_ number: Int = 12) -> TrackedPR {
        var pr = TrackedPR(id: "PR_\(number)", accountID: accountID, firstTrackedAt: t0)
        pr.repo = "octo-org/widgets"
        pr.number = number
        pr.title = "Add\nwidget cache"
        pr.url = URL(string: "https://github.com/octo-org/widgets/pull/\(number)")!
        return pr
    }

    func event(_ kind: EventKind = .comment, actor: String = "alice", own: Bool = false) -> PREvent {
        PREvent(id: "E", prID: "PR_12", kind: kind, actor: actor, at: t0, summary: "Looks good", url: nil, isOwn: own)
    }

    func entry(_ at: Date, number: Int = 12) -> ActivityEntry {
        ActivityEntry(event: event(), pr: pr(number), account: "dana", panel: .banner, quiet: nil, phone: false, at: at)
    }

    func testAppendThenReadRoundTrips() {
        let log = ActivityLog(url: url)
        let entries = [entry(t0), ActivityEntry(run: Automation(name: "Fix CI", kinds: [.ciFailed], workingDirectory: "~"), pr: pr(), account: "dana", event: .ciFailed,
                                                error: "Working directory is not an existing folder: /x", at: t0.addingTimeInterval(1))]
        let seen = Box()
        log.append(entries) { seen.value = $0 }
        log.append([entry(t0.addingTimeInterval(2))])
        log.flush()
        XCTAssertEqual(seen.value, entries)
        let read = ActivityLog.read(url)
        XCTAssertEqual(read, entries + [entry(t0.addingTimeInterval(2))])
        XCTAssertEqual(read[0].title, "Add widget cache")  // cleaned
        XCTAssertEqual(read[0].url, URL(string: "https://github.com/octo-org/widgets/pull/12"))
        XCTAssertEqual(read[1].kind, .run)
        XCTAssertEqual(read[1].what, "Failed: Fix CI")
        XCTAssertEqual(read[1].outcome, "failed: Working directory is not an existing folder: /x")
        let lines = String(decoding: try! Data(contentsOf: url), as: UTF8.self).split(separator: "\n")
        XCTAssertEqual(lines.count, 3)  // one JSON object per line
    }

    func testCorruptAndPartialLinesAreSkippedOrLenient() throws {
        let good = String(decoding: try ActivityLog.encoder.encode(entry(t0)), as: UTF8.self)
        let text = [good, "{not json", #"{"at":"2027-01-15T08:00:00Z"}"#,  // no kind: skipped
                    #"{"at":"2027-01-15T08:00:00Z","kind":"event","quiet":"someday","number":"x"}"#].joined(separator: "\n")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        let read = ActivityLog.read(url)
        XCTAssertEqual(read.count, 2)
        XCTAssertEqual(read[0], entry(t0))
        XCTAssertNil(read[1].quiet)  // an unknown value takes the default
        XCTAssertEqual(read[1].number, 0)
        XCTAssertEqual(ActivityLog.read(dir.appendingPathComponent("missing.jsonl")), [])
    }

    func testCompactKeepsDaysAndCapAndRewritesTheFile() {
        let old = (0..<3).map { entry(t0.addingTimeInterval(-40 * 86_400 + Double($0))) }
        let recent = (0..<(ActivityLog.maxEntries + 2)).map { entry(t0.addingTimeInterval(-86_400 + Double($0))) }
        ActivityLog.write(old + recent, appendingTo: url)
        let log = ActivityLog(url: url)
        let seen = Box()
        log.compact(days: 30, now: t0) { seen.value = $0 }
        log.flush()
        XCTAssertEqual(seen.value.count, ActivityLog.maxEntries)
        XCTAssertEqual(seen.value.first, recent[2])  // the oldest two of the recent ones went over the cap
        XCTAssertEqual(ActivityLog.read(url), seen.value)
        XCTAssertEqual(ActivityLog.compacted(old + [entry(t0)], days: 7, now: t0), [entry(t0)])
    }

    func testMemoryOnlyLogKeepsEntries() {
        let log = ActivityLog(url: nil)
        let seen = Box()
        log.append([entry(t0)]) { seen.value = $0 }
        log.flush()
        XCTAssertEqual(seen.value, [entry(t0)])
    }

    func testQuietReasons() {
        var settings = AppSettings()
        var pr = pr()
        func reason(_ e: PREvent = event(), offered: Bool = false) -> ActivityEntry.Quiet? {
            ActivityEntry.Quiet.reason(e, pr: pr, settings: settings, offered: offered, now: t0)
        }
        XCTAssertNil(reason())  // others' comment: banner by default
        XCTAssertEqual(reason(event(actor: me, own: true)), .own)
        XCTAssertNil(reason(event(.merged, actor: me, own: true), offered: true))  // a Run button shows it
        XCTAssertEqual(reason(event(.labeled)), .styleOff)  // others' labels: Off by default
        XCTAssertNil(reason(event(.labeled), offered: true))
        pr.snoozedUntil = t0.addingTimeInterval(60)
        XCTAssertEqual(reason(), .snoozed)
        pr.muted = true
        XCTAssertEqual(reason(), .muted)
        settings.pausedUntil = t0.addingTimeInterval(60)
        XCTAssertEqual(reason(), .paused)
        settings.notificationsEnabled = false
        XCTAssertEqual(reason(), .notificationsOff)
        XCTAssertEqual(reason(event(own: true)), .own)
        pr.hidden = true  // hidden still notifies
        pr.muted = false
        pr.snoozedUntil = nil
        settings = AppSettings()
        XCTAssertNil(reason())
    }

    func testEventEntryRecordsWhatHappened() {
        let shown = ActivityEntry(event: event(.ciFailed, actor: "CI"), pr: pr(), account: "dana", panel: .alert, quiet: nil, phone: true, at: t0)
        XCTAssertEqual(shown.what, "CI failed")
        XCTAssertEqual(shown.outcome, "alert, phone")
        XCTAssertNil(shown.own)
        let mine = ActivityEntry(event: event(actor: me, own: true), pr: pr(), account: "dana", panel: .notShown, quiet: .own, phone: false, at: t0)
        XCTAssertEqual(mine.what, "Comment added · dana")
        XCTAssertEqual(mine.outcome, "not shown: your own")
        XCTAssertEqual(mine.own, true)
        let handler = ActivityEntry(run: Automation.defaultHandler(), pr: pr(), account: "dana", event: nil, error: nil, at: t0)
        XCTAssertEqual(handler.kind, .handler)
        XCTAssertEqual(handler.what, "Ran Handle with Agent (new session)")
        XCTAssertEqual(handler.outcome, "OK")
    }

    /// Seeded history of a newly tracked pull request is flagged (and skipped by the app); live events and own events later are not.
    func testSeededFlag() {
        let account = UUID()
        let s = snap(timeline: [node("IC_1", by: "alice", at: t0.addingTimeInterval(-600), body: "Nice"),
                                node("IC_2", by: me, at: t0.addingTimeInterval(-500), body: "Thanks"),
                                node("IC_3", by: "carol", at: t0.addingTimeInterval(-60), body: "@dana look")])
        let (pr, seededEvents) = EventEngine.diff(old: nil, snapshot: s, me: me, accountID: account, inRequestedSearch: false, inReviewedSearch: false, now: t0)
        XCTAssertEqual(seededEvents.filter { $0.seeded == true }.map(\.id), ["IC_1", "IC_2"])
        XCTAssertNil(seededEvents.first { $0.id == "IC_3" }?.seeded)  // a recent mention notifies: logged
        let later = snap(timeline: s.timeline + [node("IC_4", by: me, at: t0.addingTimeInterval(60), body: "Done")], updatedAt: t0.addingTimeInterval(60))
        let (_, events) = EventEngine.diff(old: pr, snapshot: later, me: me, accountID: account, inRequestedSearch: false, inReviewedSearch: false,
                                           now: t0.addingTimeInterval(120))
        XCTAssertEqual(events.map(\.id), ["IC_4"])
        XCTAssertTrue(events[0].isOwn)
        XCTAssertNil(events[0].seeded)  // own, logged as own
    }

    // MARK: pullping activity

    func cli(_ args: [String]) -> (output: String, error: String, status: Int32) {
        AutomationCLI.run(["activity"] + args, store: AutomationStore(url: dir.appendingPathComponent("automations.json")),
                          env: ["PULLPING_ACTIVITY": url.path], now: t0)
    }

    func testCLIFiltersAndJSON() throws {
        XCTAssertEqual(cli([]).output, "No activity.")
        let muted = ActivityEntry(event: event(.reviewApproved), pr: pr(), account: "dana", panel: .notShown, quiet: .muted, phone: false,
                                  at: t0.addingTimeInterval(-7200))
        ActivityLog.write([muted, entry(t0.addingTimeInterval(-1800), number: 7), entry(t0.addingTimeInterval(-60))], appendingTo: url)

        let all = cli([])
        XCTAssertEqual(all.status, 0)
        let lines = all.output.split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasSuffix("  octo-org/widgets #12  Comment added · alice  → banner  Add widget cache"), String(lines[0]))  // newest first
        XCTAssertTrue(lines[2].contains("Review approved · alice  → not shown: muted"), String(lines[2]))

        XCTAssertEqual(cli(["--limit", "1"]).output.split(separator: "\n").count, 1)
        XCTAssertEqual(cli(["--since", "1h"]).output.split(separator: "\n").count, 2)
        XCTAssertEqual(cli(["--since", iso(t0.addingTimeInterval(-120))]).output.split(separator: "\n").count, 1)
        XCTAssertEqual(cli(["--pr", "https://github.com/octo-org/widgets/pull/7"]).output.split(separator: "\n").count, 1)
        XCTAssertEqual(cli(["--pr", "OCTO-org/widgets#12", "--since", "3h"]).output.split(separator: "\n").count, 2)

        let json = cli(["--json", "--limit", "2"])
        XCTAssertEqual(json.status, 0)
        let decoded = try StateStore.decoder.decode([ActivityEntry].self, from: Data(json.output.utf8))
        XCTAssertEqual(decoded.map(\.number), [12, 7])

        XCTAssertEqual(cli(["--since", "yesterday"]).status, 2)
        XCTAssertEqual(cli(["--limit", "0"]).status, 2)
        XCTAssertEqual(cli(["--pr", "nope"]).status, 2)
        XCTAssertTrue(cli(["--help"]).output.hasPrefix("Usage: pullping activity"))
        XCTAssertTrue(AutomationCLI.help.contains("pullping session set"))
    }

    func testSinceParsing() {
        XCTAssertEqual(AutomationCLI.sinceDate("30m", now: t0), t0.addingTimeInterval(-1800))
        XCTAssertEqual(AutomationCLI.sinceDate("2d", now: t0), t0.addingTimeInterval(-172_800))
        XCTAssertEqual(AutomationCLI.sinceDate(iso(t0), now: t0), t0)
        let day = AutomationCLI.sinceDate("2026-11-01", now: t0)
        XCTAssertEqual(day.map { Calendar.current.dateComponents([.year, .month, .day, .hour], from: $0) },
                       DateComponents(year: 2026, month: 11, day: 1, hour: 0))
        XCTAssertNil(AutomationCLI.sinceDate("-1h", now: t0))
        XCTAssertNil(AutomationCLI.sinceDate("h", now: t0))
    }
}

/// A value a `@Sendable` completion sets; read after `flush()`.
private final class Box: @unchecked Sendable {
    var value: [ActivityEntry] = []
}
