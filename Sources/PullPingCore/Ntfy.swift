import Foundation
import os

/// Where phone notifications go. The token and the fallback URL come from the keychain, never UserDefaults or logs.
public struct NtfyConfig: Sendable {
    public var server: String
    public var topic: String
    public var token: String
    /// Full topic URL (`https://host/topic`), published to without the token when the server fails.
    public var fallbackURL: String

    public init(server: String, topic: String, token: String, fallbackURL: String) {
        self.server = server; self.topic = topic; self.token = token; self.fallbackURL = fallbackURL
    }
}

/// Phone notifications through an ntfy server, JSON publish (https://docs.ntfy.sh/publish/#publish-as-json). Adapted from MeetAlert.
public enum Ntfy {
    static let log = Logger(subsystem: "com.padina.pullping", category: "ntfy")

    public struct Message: Sendable, Equatable {
        public var title: String
        public var body: String
        public var priority: Int
        /// After the `pullping` sender tag.
        public var tags: [String]
        public var click: URL?
        /// The trace footer's `flow`.
        public var flow: String

        public init(title: String, body: String, priority: Int, tags: [String], click: URL?, flow: String) {
            self.title = title; self.body = body; self.priority = priority; self.tags = tags; self.click = click; self.flow = flow
        }
    }

    struct Publish: Codable, Equatable {
        let topic: String
        let title: String
        let message: String
        let priority: Int
        let tags: [String]
        let click: String?
    }

    /// Posts to the server root; on a timeout or non-2xx, to the fallback topic URL (no token) when one is set.
    /// true = one of them took it.
    public static func send(_ message: Message, config: NtfyConfig, transport: GraphQLTransport, now: Date = Date()) async -> Bool {
        guard !config.topic.isEmpty, let server = URL(string: config.server) else { return false }
        let event = eventID(now)
        if await post(payload(message, topic: config.topic, event: event), to: server, token: config.token,
                      event: event, logTopic: "primary", transport: transport) { return true }
        guard let fallback = fallbackTarget(config.fallbackURL) else { return false }
        // Topic names are secrets (on ntfy.sh the topic is the only key): never logged.
        return await post(payload(message, topic: fallback.topic, event: event), to: fallback.root, token: "",
                          event: event, logTopic: "fallback", transport: transport)
    }

    /// `pullping` is always the first tag; the body ends with the trace footer.
    static func payload(_ m: Message, topic: String, event: String) -> Publish {
        Publish(topic: topic, title: m.title, message: m.body + footer(flow: m.flow, event: event), priority: m.priority,
                tags: ["pullping"] + m.tags, click: m.click?.absoluteString)
    }

    /// Trace footer: sender / flow / event / log.
    static func footer(flow: String, event: String) -> String {
        "\n\nsender: pullping@\(shortHost)\nflow: \(flow)\nevent: \(event)\nlog: macOS log, subsystem com.padina.pullping"
    }

    /// Read once, off the main thread (the first send): `hostName` can wait on DNS.
    static let shortHost = String(ProcessInfo.processInfo.hostName.split(separator: ".").first ?? "mac")

    /// `YYYYMMDD-HHMMSS-<4 hex>`, local time.
    static func eventID(_ now: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(formatter.string(from: now))-\(String(format: "%04x", UInt16.random(in: 0...UInt16.max)))"
    }

    /// Splits a full topic URL (`https://host[:port]/topic`) into the server root and the topic.
    static func fallbackTarget(_ s: String) -> (root: URL, topic: String)? {
        guard let u = URL(string: s), let scheme = u.scheme, let host = u.host(), !u.lastPathComponent.isEmpty,
              u.lastPathComponent != "/",
              let root = URL(string: "\(scheme)://\(host)\(u.port.map { ":\($0)" } ?? "")") else { return nil }
        return (root, u.lastPathComponent)
    }

    /// One log line per attempt with the footer's event id. Never the token.
    private static func post(_ payload: Publish, to url: URL, token: String, event: String, logTopic: String,
                             transport: GraphQLTransport) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try? JSONEncoder().encode(payload)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let reply = try? await transport.send(request)
        let status = reply?.1.statusCode
        let id = reply.flatMap { (try? JSONDecoder().decode(Reply.self, from: $0.0))?.id } ?? "-"
        log.notice("ntfy event=\(event, privacy: .public) topic=\(logTopic, privacy: .public) http=\(status.map(String.init) ?? "timeout", privacy: .public) id=\(id, privacy: .public)")
        return status.map { (200...299).contains($0) } ?? false
    }

    private struct Reply: Decodable { let id: String? }
}
