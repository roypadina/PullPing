import Foundation

/// Local review reminders: repeat while I am requested on an open, non-draft, unmuted, unsnoozed PR.
public enum Reminders {
    /// The first reminder comes `reminderMinutes` after the request (the request itself already notified).
    public static func nextReminder(pr: TrackedPR, settings: AppSettings, now: Date) -> Date? {
        guard settings.reminderMinutes > 0, !pr.muted, (pr.snoozedUntil ?? .distantPast) <= now, Attention.awaitingMyReview(pr) else { return nil }
        let requestedAt = pr.events.last { $0.kind == .reviewRequested }?.at ?? pr.firstTrackedAt
        return max(pr.lastReminderAt ?? requestedAt, pr.firstTrackedAt).addingTimeInterval(Double(settings.reminderMinutes) * 60)
    }

    /// Shown with the `reviewRequested` style; not stored in `events`, never unread. The caller sets `lastReminderAt = now`.
    public static func event(for pr: TrackedPR, now: Date) -> PREvent {
        PREvent(id: "reminder:\(now.ISO8601Format())", prID: pr.id, kind: .reviewReminder, actor: pr.authorLogin,
                at: now, summary: "Reminder: review requested", url: pr.url, isOwn: false)
    }
}
