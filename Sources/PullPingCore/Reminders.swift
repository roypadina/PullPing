import Foundation

/// Local review reminders: repeat while an open, unmuted, unsnoozed pull request waits on my review or re-review (bucket
/// `review` / `reReview`), or on my team's while the Team review style isn't Off.
public enum Reminders {
    /// The first reminder comes `reminderMinutes` after the request (the request itself already notified).
    public static func nextReminder(pr: TrackedPR, settings: AppSettings, now: Date) -> Date? {
        guard settings.reminderMinutes > 0, !pr.muted, (pr.snoozedUntil ?? .distantPast) <= now, let reason = reason(pr),
              reason != .teamToReview || settings.needStyle(.teamToReview) != .off else { return nil }
        let requestedAt = requested(pr, reason)
        // A re-request after the last reminder restarts the interval: no reminder right behind the new request.
        return max(pr.lastReminderAt ?? requestedAt, requestedAt, pr.firstTrackedAt).addingTimeInterval(Double(settings.reminderMinutes) * 60)
    }

    /// Not stored in `events`, never unread. The caller sets `lastReminderAt = now`.
    public static func event(for pr: TrackedPR, now: Date) -> PREvent {
        let reason = reason(pr) ?? .toReview
        let minutes = Int(now.timeIntervalSince(requested(pr, reason)) / 60)
        let summary = reason == .reReview ? "Still waiting on your re-review"
            : "Still waiting on your review (requested \(minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h") ago)"
        return PREvent(id: "reminder:\(now.ISO8601Format())", prID: pr.id, kind: .reviewReminder, actor: pr.authorLogin,
                       at: now, summary: summary, url: pr.url, isOwn: false)
    }

    static func reason(_ pr: TrackedPR) -> NeedReason? {
        switch Attention.bucket(pr) {
        case .review: .toReview
        case .reReview: .reReview
        case .teamReview: .teamToReview
        default: nil
        }
    }

    /// The newest event that put it in the reason, else when tracking started.
    static func requested(_ pr: TrackedPR, _ reason: NeedReason) -> Date { Attention.causedAt(pr, reason) ?? pr.firstTrackedAt }
}

/// A reminder the user set on one item (Remind Me ▸, `TrackedPR.remindAt`). Not `Reminders` (automatic review reminders).
public enum Remind {
    public enum Option: CaseIterable, Sendable {
        case hour1, hours3, tomorrow, week

        public var title: String {
            switch self {
            case .hour1: "In 1 Hour"
            case .hours3: "In 3 Hours"
            case .tomorrow: "Tomorrow at 9:00"
            case .week: "Next Week at 9:00"
            }
        }

        /// Next Week = 7 days from today, 9:00.
        public func date(from now: Date, calendar: Calendar = .current) -> Date {
            func nine(_ days: Int) -> Date {
                calendar.date(bySettingHour: 9, minute: 0, second: 0, of: calendar.date(byAdding: .day, value: days, to: now) ?? now)
                    ?? now.addingTimeInterval(Double(days) * 86_400)
            }
            return switch self {
            case .hour1: now.addingTimeInterval(3600)
            case .hours3: now.addingTimeInterval(3 * 3600)
            case .tomorrow: nine(1)
            case .week: nine(7)
            }
        }
    }

    /// A due reminder becomes a stored unread event (cap `EventEngine.eventCap`) and `remindAt` is cleared. nil = not due.
    public static func fire(_ pr: inout TrackedPR, now: Date) -> PREvent? {
        guard let at = pr.remindAt, at <= now else { return nil }
        let event = PREvent(id: "remind:\(now.ISO8601Format())", prID: pr.id, kind: .reminder, actor: "PullPing", at: now,
                            summary: "You asked to be reminded", url: pr.url, isOwn: false)
        pr.events = Array((pr.events + [event]).suffix(EventEngine.eventCap))
        pr.remindAt = nil
        return event
    }

    /// "Today, 3:00 PM", "Tomorrow, 9:00 AM", "Mon, 9:00 AM" (within 7 days), "Nov 24, 9:00 AM".
    public static func label(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let time = date.formatted(style.hour().minute())
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: return "Today, \(time)"
        case 1: return "Tomorrow, \(time)"
        case 2..<7: style = style.weekday(.abbreviated)
        default: style = style.month(.abbreviated).day()
        }
        return "\(date.formatted(style)), \(time)"
    }
}
