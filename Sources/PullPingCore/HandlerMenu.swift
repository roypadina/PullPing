import Foundation

/// One of Handle with Agent's choices on a pull request; `target` is an Open With id.
public enum HandlerChoice: Equatable, Sendable {
    case handle(target: String), resume(target: String, prompt: Bool), new(target: String), resumeEarlier(target: String), findEarlier
    /// In Background: start a headless run, or cancel the pull request's running one.
    case background(BackgroundAction), cancelBackground
}

public struct HandlerMenuItem: Equatable, Sendable {
    public var title: String
    public var choice: HandlerChoice
}

/// A group of items: titled with the target's name when there is more than one target.
public struct HandlerMenuSection: Equatable, Sendable {
    public var title: String?
    public var items: [HandlerMenuItem]
}

/// What the panel's chevron, the row's Handle with Agent ▸ submenu, the detail toolbar and the Pull Request menu list.
public enum HandlerMenuModel {
    /// `linked`: the pull request's linked session id; `earlier`: a found session's "1a2b…, 2 hr. ago" (no link only).
    /// The default target comes first, as in `targets`.
    public static func sections(targets: [LaunchTarget], linked: String?, earlier: String?) -> [HandlerMenuSection] {
        let several = targets.count > 1
        let find = HandlerMenuSection(title: nil, items: [HandlerMenuItem(title: "Find Earlier Session…", choice: .findEarlier)])
        if let linked {
            return targets.enumerated().map { i, t in
                HandlerMenuSection(title: several ? t.name : nil, items: [
                    HandlerMenuItem(title: i == 0 ? "Resume Session (\(linked.prefix(4))…)" : "Resume Session", choice: .resume(target: t.id, prompt: true)),
                    HandlerMenuItem(title: "Resume Without Prompt", choice: .resume(target: t.id, prompt: false)),
                    HandlerMenuItem(title: "New Session", choice: .new(target: t.id)),
                ])
            }
        }
        if let earlier {
            return targets.map { t in
                HandlerMenuSection(title: several ? t.name : nil, items: [
                    HandlerMenuItem(title: "Resume Earlier Session (\(earlier))", choice: .resumeEarlier(target: t.id)),
                    HandlerMenuItem(title: "New Session", choice: .new(target: t.id)),
                ])
            } + [find]
        }
        let items = targets.map { HandlerMenuItem(title: several ? "Handle in \($0.name)" : "Handle with Agent", choice: .handle(target: $0.id)) }
        return [HandlerMenuSection(title: nil, items: items), find]
    }

    /// The last section, "In Background" (Background Runs on): the actions this pull request allows, or Cancel Background
    /// Review while one runs on it. Empty when there is neither.
    public static func background(actions: [BackgroundAction], running: BackgroundAction?) -> [HandlerMenuSection] {
        let items = running.map { r in
            [HandlerMenuItem(title: r == .review ? "Cancel Background Review" : r == .triage ? "Cancel Background Triage" : "Cancel Summary", choice: .cancelBackground)]
        }
            ?? actions.map { HandlerMenuItem(title: $0.title, choice: .background($0)) }
        return items.isEmpty ? [] : [HandlerMenuSection(title: "In Background", items: items)]
    }
}
