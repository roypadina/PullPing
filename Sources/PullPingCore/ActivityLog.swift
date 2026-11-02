import Foundation
import os

/// One line of the activity log: an event PullPing saw and what it did with it, or a run it started.
public struct ActivityEntry: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case event, run, handler }
    /// What the notification panel did with an event; `notShown` comes with a `quiet` reason.
    public enum Panel: String, Codable, Sendable { case banner, alert, notShown }

    /// Why an event showed no panel, in the order `Store.show` checks.
    public enum Quiet: String, Codable, Sendable, CaseIterable {
        case own, notificationsOff, paused, muted, snoozed, styleOff

        /// "Not shown: muted" (app) and the CLI.
        public var label: String {
            switch self {
            case .own: "your own"
            case .notificationsOff: "notifications off"
            case .paused: "paused"
            case .muted: "muted"
            case .snoozed: "snoozed"
            case .styleOff: "off in Settings"
            }
        }

        /// nil = the event gets a panel. `offered`: an ask-mode automation offers a Run button on it, which shows the panel
        /// whatever the kind's style, also for an own event. Hidden pull requests still notify, so hidden is no reason.
        public static func reason(_ event: PREvent, pr: TrackedPR, settings: AppSettings, offered: Bool, now: Date) -> Quiet? {
            if event.isOwn && !offered { return .own }
            if !settings.notificationsEnabled { return .notificationsOff }
            if settings.isPaused(now) { return .paused }
            if pr.muted { return .muted }
            if (pr.snoozedUntil ?? .distantPast) > now { return .snoozed }
            if !offered && settings.style(for: event.kind, mine: pr.roles.contains(.author)) == .off { return .styleOff }
            return nil
        }
    }

    public var at: Date
    public var kind: Kind
    /// The account's login, kept after the account is removed.
    public var account = ""
    public var accountID: UUID?
    public var prID: String?
    public var repo = ""
    public var number = 0
    /// Written by others on GitHub: cleaned, at most 200 characters.
    public var title = ""
    public var url: URL?
    // Events (runs: the event that started them, if any).
    public var event: EventKind?
    public var actor: String?
    public var summary: String?
    public var panel: Panel?
    public var quiet: Quiet?
    public var phone: Bool?
    public var own: Bool?
    // Runs and Handle with Agent launches.
    public var automation: String?
    public var ok: Bool?
    public var error: String?

    public init(at: Date, kind: Kind, pr: TrackedPR, account: String) {
        self.at = at
        self.kind = kind
        self.account = account
        accountID = pr.accountID
        prID = pr.id
        repo = pr.repo
        number = pr.number
        title = PromptTemplate.clean(pr.title, max: 200)
        url = pr.url
    }

    /// A poll event or reminder and what PullPing did with it.
    public init(event e: PREvent, pr: TrackedPR, account: String, panel: Panel, quiet: Quiet?, phone: Bool, at: Date) {
        self.init(at: at, kind: .event, pr: pr, account: account)
        url = e.url ?? pr.url
        event = e.kind
        actor = e.actor
        summary = e.summary.isEmpty ? nil : e.summary
        self.panel = panel
        self.quiet = quiet
        self.phone = phone
        own = e.isOwn ? true : nil
    }

    /// A launch PullPing started (app or `pullping run`); `error` nil = it started.
    public init(run a: Automation, pr: TrackedPR, account: String, event: EventKind?, error: String?, at: Date) {
        let handler = a.id == Automation.handlerID
        self.init(at: at, kind: handler ? .handler : .run, pr: pr, account: account)
        self.event = event
        automation = handler ? "\(a.name) (\(AutomationCLI.sessionWord(a)))" : a.name
        ok = error == nil
        self.error = error
    }

    /// Lenient: a missing or unreadable field takes its default; only `at` and `kind` are required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys) -> T? { (try? c.decodeIfPresent(T.self, forKey: key)) ?? nil }
        at = try c.decode(Date.self, forKey: .at)
        kind = try c.decode(Kind.self, forKey: .kind)
        account = value(.account) ?? ""
        accountID = value(.accountID)
        prID = value(.prID)
        repo = value(.repo) ?? ""
        number = value(.number) ?? 0
        title = value(.title) ?? ""
        url = value(.url)
        event = value(.event)
        actor = value(.actor)
        summary = value(.summary)
        panel = value(.panel)
        quiet = value(.quiet)
        phone = value(.phone)
        own = value(.own)
        automation = value(.automation)
        ok = value(.ok)
        error = value(.error)
    }

    /// "Review approved · alice", "Ran Fix CI", "Failed: Fix CI": the app row and `pullping activity`.
    public var what: String {
        guard kind == .event else { return (ok == false ? "Failed: " : "Ran ") + (automation ?? "") }
        let label = event?.label ?? ""
        return actor.map { $0.isEmpty || $0 == "CI" ? label : "\(label) · \($0)" } ?? label
    }

    /// "banner, phone", "not shown: muted", "OK", "failed: <error>".
    public var outcome: String {
        guard kind == .event else { return ok == false ? "failed: \(error ?? "")" : "OK" }
        let panel = quiet.map { "not shown: \($0.label)" } ?? self.panel?.rawValue ?? "not shown"
        return phone == true ? "\(panel), phone" : panel
    }
}

/// `activity.jsonl` beside state.json: one JSON object per line, oldest first. Appends never rewrite the file; `compact` drops
/// entries past the kept days or `maxEntries` with one atomic rewrite. File work runs on a background queue, never the caller's.
public final class ActivityLog: @unchecked Sendable {
    public static let maxEntries = 5000
    private static let log = Logger(subsystem: "com.padina.pullping", category: "activity")

    /// `PULLPING_ACTIVITY=<path>` points the app and the CLI at another file (tests, scratch runs).
    public static func defaultURL(_ env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = env["PULLPING_ACTIVITY"], !path.isEmpty { return URL(fileURLWithPath: path) }
        return StateStore.defaultURL.deletingLastPathComponent().appendingPathComponent("activity.jsonl")
    }

    /// nil = memory only (demo, screenshots).
    public let url: URL?
    private let queue = DispatchQueue(label: "com.padina.pullping.activity", qos: .utility)
    /// The queue's copy of the log, oldest first.
    private var entries: [ActivityEntry] = []

    public init(url: URL?) { self.url = url }

    /// Appends to the file and the copy, then hands the whole log, oldest first, to `done` (on the background queue).
    public func append(_ new: [ActivityEntry], done: @escaping @Sendable ([ActivityEntry]) -> Void = { _ in }) {
        guard !new.isEmpty else { return }
        queue.async { [self] in
            if let url { Self.write(new, appendingTo: url) }
            entries += new
            if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }  // the file waits for `compact`
            done(entries)
        }
    }

    /// Re-reads the file (`pullping run` appends too), keeps the last `days` days and at most `maxEntries`, and rewrites the file
    /// when that dropped any. Launch, daily, and when the Activity list appears.
    public func compact(days: Int, now: Date, done: @escaping @Sendable ([ActivityEntry]) -> Void = { _ in }) {
        queue.async { [self] in
            if let url { entries = Self.read(url) }
            let kept = Self.compacted(entries, days: days, now: now)
            // shortcut: a `pullping run` line appended between this read and the rewrite is lost; rare (CLI runs only), fine for a log.
            if kept.count < entries.count, let url { Self.rewrite(kept, to: url) }
            entries = kept
            done(entries)
        }
    }

    /// Waits for the queued file work (tests).
    public func flush() { queue.sync {} }

    public static func compacted(_ entries: [ActivityEntry], days: Int, now: Date) -> [ActivityEntry] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return Array(entries.filter { $0.at >= cutoff }.suffix(maxEntries))
    }

    /// Every line that decodes, oldest first; a missing file is empty, a corrupt line is skipped.
    public static func read(_ url: URL) -> [ActivityEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(ActivityEntry.self, from: Data($0)) }
    }

    /// One `O_APPEND` write, so the app and `pullping run` can both append. Synchronous: the CLI's path.
    public static func write(_ entries: [ActivityEntry], appendingTo url: URL) {
        let data = lines(entries)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return log.error("activity append failed: errno \(errno)") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try handle.write(contentsOf: data) } catch { log.error("activity append failed: \(error.localizedDescription, privacy: .public)") }
    }

    private static func rewrite(_ entries: [ActivityEntry], to url: URL) {
        do { try lines(entries).write(to: url, options: .atomic) } catch {
            log.error("activity compaction failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func lines(_ entries: [ActivityEntry]) -> Data {
        var data = Data()
        for entry in entries {
            guard let line = try? encoder.encode(entry) else { continue }
            data.append(line)
            data.append(UInt8(ascii: "\n"))
        }
        return data
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]  // one line per entry
        return encoder
    }()

    static let decoder = StateStore.decoder
}
