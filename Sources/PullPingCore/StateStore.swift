import Foundation
import os

/// `TrackedState` as JSON (ISO-8601 dates): atomic writes, debounced 1 s. Thread-safe.
public final class StateStore: @unchecked Sendable {
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PullPing/state.json")
    }

    private static let log = Logger(subsystem: "com.padina.pullping", category: "state")
    /// nil = memory only.
    public let url: URL?
    private let lock = NSLock()
    private var value: TrackedState
    private var saveScheduled = false

    /// A corrupt file is renamed to `state.broken.json` and the store starts empty.
    public init(url: URL?) {
        self.url = url
        value = TrackedState()
        guard let url, let data = try? Data(contentsOf: url) else { return }
        do {
            value = try Self.decoder.decode(TrackedState.self, from: data)
        } catch {
            let broken = url.deletingLastPathComponent().appendingPathComponent("state.broken.json")
            try? FileManager.default.removeItem(at: broken)
            try? FileManager.default.moveItem(at: url, to: broken)
            Self.log.error("state file unreadable, moved to state.broken.json")
        }
    }

    public var state: TrackedState { lock.withLock { value } }

    /// Mutates under the lock, then schedules a save.
    @discardableResult
    public func update<R>(_ body: (inout TrackedState) -> R) -> R {
        let result = lock.withLock { body(&value) }
        scheduleSave()
        return result
    }

    /// Writes now (on quit, at the end of smoke mode).
    public func save() {
        guard let url else { return }
        let snapshot = lock.withLock { saveScheduled = false; return value }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(snapshot).write(to: url, options: .atomic)
        } catch {
            Self.log.error("state save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Drops closed/merged PRs past retention (by `closedAt`) and ignored ids. Open PRs never expire.
    public static func prune(_ state: inout TrackedState, retentionDays: Int, now: Date) {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        let ignored = state.ignoredIDs
        state.prs = state.prs.filter { id, pr in !ignored.contains(id) && (pr.state == .open || (pr.closedAt ?? now) > cutoff) }
    }

    private func scheduleSave() {
        guard url != nil else { return }
        let alreadyScheduled = lock.withLock { () -> Bool in
            defer { saveScheduled = true }
            return saveScheduled
        }
        guard !alreadyScheduled else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { self.save() }  // strong: a pending write outlives the last reference
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
