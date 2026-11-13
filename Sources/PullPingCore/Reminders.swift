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
