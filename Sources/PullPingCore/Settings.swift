import Foundation

public enum NotificationStyle: String, Codable, Sendable, CaseIterable { case off, banner, alert }

/// Unified: All Accounts first, then each account. Per account: each account on its own.
public enum InboxLayout: String, Codable, Sendable, CaseIterable { case unified, perAccount }

/// The menu-bar number: pull requests that need me (`Attention.needsMe`), every attention one, or none.
public enum BadgeMode: String, Codable, Sendable, CaseIterable { case needsMe, allUnread, off }

public struct AppSettings: Codable, Sendable, Equatable {
    public static let pollIntervalOptions = [1, 2, 3, 5, 10, 15]
    public static let retentionOptions = [1, 3, 7, 14]
    public static let reminderOptions = [0, 15, 30, 60, 120, 240]
    public static let autoHideOptions = [5, 8, 12, 20]

    public static let defaultStyles: [EventKind: NotificationStyle] = Dictionary(uniqueKeysWithValues: EventKind.allCases.map {
        ($0, [.reviewChangesRequested, .ciFailed, .merged].contains($0) ? .alert : .banner)
    })
    public static let defaultOtherStyles: [EventKind: NotificationStyle] = Dictionary(uniqueKeysWithValues: EventKind.allCases.map {
        let style: NotificationStyle = [.reviewRequested, .assigned, .mentioned].contains($0) ? .alert
            : [.comment, .reviewApproved, .reviewChangesRequested, .reviewCommented, .merged, .closed].contains($0) ? .banner : .off
        return ($0, style)
    })

    public var pollIntervalMinutes = 3
    public var retentionDays = 3
    public var reminderMinutes = 60  // 0 = off
    public var autoHideSeconds = 8
    public var playSound = true
    public var notificationsEnabled = true
    public var showMenuBarIcon = true
    /// Pull requests I authored.
    public var styles = AppSettings.defaultStyles
    /// Everything else.
    public var otherStyles = AppSettings.defaultOtherStyles
    public var inboxLayout = InboxLayout.unified
    public var badgeMode = BadgeMode.needsMe
    /// What "Pull requests that need me" counts (Settings > General); all reasons by default.
    public var badgeReasons = Set(NeedReason.allCases)
    /// Panels, phone pushes and reminders stay quiet until then.
    public var pausedUntil: Date?
    /// ntfy server and topic; the access token and the fallback topic URL live in the keychain.
    public var ntfyServer = "https://ntfy.sh"
    public var ntfyTopic = ""
    /// Kinds pushed to the phone, for my pull requests and for others. Empty until the user opts in.
    public var phoneMine: Set<EventKind> = []
    public var phoneOthers: Set<EventKind> = []
    /// Open issues I'm involved in are tracked alongside pull requests (Settings > General > Tracking).
    public var trackIssues = true

    public init() {}

    /// Every key is optional: settings saved by an older build keep their values, newer keys take the defaults.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T { try c.decodeIfPresent(T.self, forKey: key) ?? fallback }
        pollIntervalMinutes = try value(.pollIntervalMinutes, pollIntervalMinutes)
        retentionDays = try value(.retentionDays, retentionDays)
        reminderMinutes = try value(.reminderMinutes, reminderMinutes)
        autoHideSeconds = try value(.autoHideSeconds, autoHideSeconds)
        playSound = try value(.playSound, playSound)
        notificationsEnabled = try value(.notificationsEnabled, notificationsEnabled)
        showMenuBarIcon = try value(.showMenuBarIcon, showMenuBarIcon)
        styles = try value(.styles, styles)
        otherStyles = try value(.otherStyles, otherStyles)
        inboxLayout = try value(.inboxLayout, inboxLayout)
        badgeMode = try value(.badgeMode, badgeMode)
        badgeReasons = try value(.badgeReasons, badgeReasons)
        pausedUntil = try c.decodeIfPresent(Date.self, forKey: .pausedUntil)
        ntfyServer = try value(.ntfyServer, ntfyServer)
        ntfyTopic = try value(.ntfyTopic, ntfyTopic)
        phoneMine = try value(.phoneMine, phoneMine)
        phoneOthers = try value(.phoneOthers, phoneOthers)
        trackIssues = try value(.trackIssues, trackIssues)
        // Saved before issue tracking (no trackIssues key): the newer `assigned` reason starts on, like the rest.
        if !c.contains(.trackIssues) { badgeReasons.insert(.assigned) }
    }

    public func isPaused(_ now: Date) -> Bool { (pausedUntil ?? .distantPast) > now }

    /// Panels, phone pushes and reminders alike: master switch, Pause, and the pull request's mute and snooze. Hidden still notifies.
    public func allowsNotifications(for pr: TrackedPR, now: Date) -> Bool {
        notificationsEnabled && !isPaused(now) && !pr.muted && (pr.snoozedUntil ?? .distantPast) <= now
    }

    /// One push per opted-in event, whatever its panel style (Off included). `reviewReminder` follows `reviewRequested`.
    public func pushesToPhone(_ event: PREvent, pr: TrackedPR, now: Date) -> Bool {
        let kind = event.kind == .reviewReminder ? .reviewRequested : event.kind
        return !ntfyTopic.isEmpty && !event.isOwn && allowsNotifications(for: pr, now: now)
            && (pr.roles.contains(.author) ? phoneMine : phoneOthers).contains(kind)
    }

    /// `reviewReminder` follows the `reviewRequested` style.
    public func style(for kind: EventKind, mine: Bool) -> NotificationStyle {
        let kind = kind == .reviewReminder ? .reviewRequested : kind
        return (mine ? styles : otherStyles)[kind] ?? (mine ? Self.defaultStyles : Self.defaultOtherStyles)[kind] ?? .off
    }

    public static func load(_ defaults: UserDefaults = .standard) -> AppSettings {
        defaults.data(forKey: DefaultsKey.settings).flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) } ?? AppSettings()
    }

    public func save(_ defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: DefaultsKey.settings)
    }
}

public enum DefaultsKey {
    public static let settings = "settings"
    public static let accounts = "accounts"  // [Account] JSON, no secrets
    public static let didShowWelcome = "didShowWelcome"
    public static let settingsTab = "settingsTab"
    public static let showMenuBarIcon = "showMenuBarIcon"
    /// Status panel: last filter and account (empty = All Accounts).
    public static let panelFilter = "panelFilter"
    public static let panelAccount = "panelAccount"
    /// Main window: the Done section is expanded.
    public static let showDone = "showDone"
}

extension Account {
    public static func load(_ defaults: UserDefaults = .standard) -> [Account] {
        defaults.data(forKey: DefaultsKey.accounts).flatMap { try? JSONDecoder().decode([Account].self, from: $0) } ?? []
    }

    public static func save(_ accounts: [Account], _ defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(accounts), forKey: DefaultsKey.accounts)
    }
}
