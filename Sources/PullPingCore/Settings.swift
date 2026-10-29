import Foundation

public enum NotificationStyle: String, Codable, Sendable, CaseIterable { case off, banner, alert }

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

    public init() {}

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
}

extension Account {
    public static func load(_ defaults: UserDefaults = .standard) -> [Account] {
        defaults.data(forKey: DefaultsKey.accounts).flatMap { try? JSONDecoder().decode([Account].self, from: $0) } ?? []
    }

    public static func save(_ accounts: [Account], _ defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(accounts), forKey: DefaultsKey.accounts)
    }
}
