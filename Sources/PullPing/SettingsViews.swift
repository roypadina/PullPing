import AppKit
import PullPingCore
import SwiftUI

extension View {
    /// System Settings footer look.
    func formFooter() -> some View {
        font(.subheadline).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Accounts

struct AccountsTab: View {
    static let height: CGFloat = 300
    @Bindable var store: Store
    @State private var adding = false
    @State private var removing: Account?

    var body: some View {
        Form {
            Section {
                if store.accounts.isEmpty {
                    Text("No accounts yet.").foregroundStyle(.secondary)
                }
                ForEach($store.accounts) { $account in
                    AccountRow(account: $account, status: store.statuses[account.id]) { removing = account }
                }
            } header: {
                Text("Accounts")
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Tokens are stored in your login keychain.").formFooter()
                    Button("Add Account…") { adding = true }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $adding) { AddAccountSheet(store: store) }
        .confirmationDialog(removing.map { "Remove \($0.displayName)?" } ?? "", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) { if let removing { store.removeAccount(removing.id) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its token is deleted from the keychain and its pull requests leave the list. This can't be undone.")
        }
    }
}

private struct AccountRow: View {
    @Binding var account: Account
    let status: AccountStatus?
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Avatar(url: account.avatarURL).scaleEffect(1.5).frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "@\(account.login)").lineLimit(1)
                HStack(spacing: 3) {
                    Image(systemName: statusSymbol).accessibilityHidden(true)
                    Text(statusWord).lineLimit(1)
                }
                .font(.caption).foregroundStyle(.secondary)
                .help(statusWord)
            }
            Spacer(minLength: 8)
            TextField("Label", text: $account.label, prompt: Text("Work"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 96)
            Toggle("Enabled", isOn: $account.enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(account.enabled ? "Checking this account" : "Not checking this account")
            Button("Remove…", role: .destructive, action: onRemove)
        }
    }

    private var statusWord: String {
        guard account.enabled else { return "Off" }
        return status?.word ?? "Not checked yet"
    }

    private var statusSymbol: String {
        guard account.enabled, let status else { return "clock" }
        return status.isError ? "exclamationmark.triangle" : status == .offline ? "wifi.slash" : "checkmark.circle"
    }
}

/// PAT (first-class) or, when an OAuth client id is set, GitHub device flow. Add stays off until a token verifies.
struct AddAccountSheet: View {
    let store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var method = AuthKind.pat
    @State private var token = ""
    @State private var verifying = false
    @State private var viewer: Viewer?
    @State private var error: String?
    @State private var deviceCode: DeviceCode?
    @State private var signedIn: OAuthTokens?
    @State private var flow: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Account").font(.headline)
            if GitHubOAuth.isAvailable {
                Picker("Sign-in method", selection: $method) {
                    Text("Personal Access Token").tag(AuthKind.pat)
                    Text("Sign in with GitHub").tag(AuthKind.oauth)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if method == .pat { tokenForm } else { deviceForm }
            result
            HStack {
                Spacer()
                Button("Cancel") { flow?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { add() }.keyboardShortcut(.defaultAction).disabled(viewer == nil)
            }
        }
        .padding(20)
        .frame(width: 500)
        .onChange(of: token) { viewer = nil; error = nil }
    }

    private var tokenForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SecureField("Token", text: $token, prompt: Text("Personal access token"))
                Button("Verify") { verify() }.disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || verifying)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("**Classic token:** scopes `repo` (private repositories) and `read:org` (team review requests). Public repositories only: `public_repo`. Organizations with SAML SSO: click \"Configure SSO\" on the token and authorize each organization.")
                Text("**Fine-grained token:** Resource owner = your user or the organization (one token per organization); Repository access = All repositories (or select); Permissions: Pull requests: Read, Issues: Read, Commit statuses: Read, Checks: Read (Metadata: Read is implied). Organizations may require admin approval; until approved the token sees only public data. CI status may be incomplete with fine-grained tokens (GitHub lists the Checks API as a gap); use a classic token when CI matters.")
            }
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var deviceForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let code = deviceCode {
                Text(code.userCode).font(.system(.largeTitle, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                Button("Copy Code and Open GitHub") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code.userCode, forType: .string)
                    NSWorkspace.shared.open(code.verificationURI)
                }
                if viewer == nil && error == nil {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Waiting for approval…") }
                }
            } else {
                Button("Sign in with GitHub") { startDeviceFlow() }
            }
            Text("Organizations that restrict OAuth apps block this token until an owner approves PullPing. Use a personal access token if a repository stays invisible.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var result: some View {
        if verifying {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Verifying…") }
        } else if let error {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.bad)
        } else if let viewer {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Avatar(url: viewer.avatarURL)
                    Text(verbatim: "Signed in as @\(viewer.login)").fontWeight(.semibold)
                }
                Text(viewer.scopes.map { "Scopes: \($0.isEmpty ? "none" : $0.joined(separator: ", "))" } ?? "Fine-grained token (GitHub lists no scopes)")
                    .font(.callout).foregroundStyle(.secondary)
                if viewer.status != .ok {
                    Label(viewer.status.word, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.needsYou)
                }
                if let existing = store.accounts.first(where: { $0.login.lowercased() == viewer.login.lowercased() }) {
                    Text("Already added as \(existing.label.isEmpty ? "@\(existing.login)" : existing.label); this adds a second token.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func verify() {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        verifying = true
        error = nil
        Task {
            do { viewer = try await GitHubClient(transport: URLSessionTransport(), token: token).me() } catch {
                self.error = GitHubClient.status(for: error).word
            }
            verifying = false
        }
    }

    private func startDeviceFlow() {
        error = nil
        flow = Task {
            do {
                let code = try await DeviceFlow.start(transport: URLSessionTransport())
                deviceCode = code
                let tokens = try await DeviceFlow.poll(code: code, transport: URLSessionTransport())
                signedIn = tokens
                token = tokens.access
                verify()
            } catch let failure as DeviceFlowError {
                error = failure.message
            } catch is CancellationError {
            } catch {
                self.error = GitHubClient.status(for: error).word
            }
        }
    }

    private func add() {
        guard let viewer else { return }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        // Kind and refresh token follow where the token came from (not the picker): only the signed-in access token is OAuth.
        let oauth = signedIn?.access == token
        store.addAccount(viewer, token: token, refreshToken: oauth ? signedIn?.refresh ?? "" : "", kind: oauth ? .oauth : .pat)
        dismiss()
    }
}

// MARK: Notifications

struct NotificationsTab: View {
    @Bindable var store: Store
    static let height: CGFloat = 860  // the whole tab, no scrolling

    var body: some View {
        Form {
            Section {
                Toggle("Show Notifications", isOn: $store.settings.notificationsEnabled)  // master: regular switch (SET-7)
                Picker("Auto-hide banners after", selection: $store.settings.autoHideSeconds) {
                    ForEach(AppSettings.autoHideOptions, id: \.self) { Text("\($0) seconds").tag($0) }
                }
                .disabled(!store.settings.notificationsEnabled)
                Toggle("Play Sound", isOn: $store.settings.playSound)
                    .controlSize(.mini)
                    .disabled(!store.settings.notificationsEnabled)
            } header: {
                Text("General")
            } footer: {
                if !store.settings.notificationsEnabled {
                    Text("Notifications are off: no panels and no reminders. The menu bar count still updates.").formFooter()
                }
            }
            Section {
                ForEach(NeedReason.notifyOrder, id: \.self) { reason in
                    Picker(reason.notifyLabel, selection: Binding(get: { store.settings.needStyle(reason) }, set: { store.settings.needStyles[reason] = $0 })) {
                        Text("Off").tag(NotificationStyle.off)
                        Text("Banner").tag(NotificationStyle.banner)
                        Text("Alert").tag(NotificationStyle.alert)
                    }
                }
            } header: {
                Text("Notify Me When")
            } footer: {
                Text("A notification means something needs you. Everything else (merges, CI passed, new commits, labels…) is listed in Activity without a notification. A banner hides after a few seconds; an alert stays until you act on it.").formFooter()
            }
            .disabled(!store.settings.notificationsEnabled)
            Section {
                Picker("Remind me every", selection: $store.settings.reminderMinutes) {
                    ForEach(AppSettings.reminderOptions, id: \.self) { Text($0 == 0 ? "Off" : "\($0) minutes").tag($0) }
                }
            } header: {
                Text("Review Reminders")
            } footer: {
                Text("For reviews and re-reviews asked of you (team requests while their notification is on). Repeats until you review, the request is removed, or the pull request is merged or closed.").formFooter()
            }
            .disabled(!store.settings.notificationsEnabled)
        }
        .formStyle(.grouped)
    }
}

// MARK: Phone

/// ntfy pushes (MeetAlert pattern): server and topic in settings, access token and fallback URL in the keychain.
struct PhoneTab: View {
    static let height: CGFloat = 640  // plan height; the 22-row table scrolls
    @Bindable var store: Store
    @State private var sending = false
    @State private var testResult: Bool?
    private static let kinds = EventKind.allCases.filter { $0 != .reviewReminder }
    private static let column: CGFloat = 112

    var body: some View {
        Form {
            Section {
                TextField("Server", text: $store.settings.ntfyServer)
                TextField("Topic", text: $store.settings.ntfyTopic, prompt: Text("Empty = phone notifications off"))
                SecureField("Access token (optional)", text: $store.ntfyToken)
                SecureField("Fallback topic URL (optional)", text: $store.ntfyFallbackURL, prompt: Text(verbatim: "https://ntfy.sh/…"))
                HStack {
                    Button("Send Test Notification") { test() }
                        .disabled(store.settings.ntfyTopic.isEmpty || sending)
                    if sending {
                        ProgressView().controlSize(.small)
                    } else if let ok = testResult {
                        Label {
                            Text(ok ? "Sent. Check your phone." : "Couldn't send. Check the server, topic and token, then try again.")
                        } icon: {
                            Image(systemName: ok ? "checkmark.circle" : "exclamationmark.triangle.fill").foregroundStyle(ok ? Theme.good : Theme.bad)
                        }
                        .font(.callout)
                    }
                }
            } header: {
                Text("ntfy")
            } footer: {
                Text("Subscribe to the same topic in the ntfy phone app. Keep the topic private: anyone who knows it can read it. The access token (for a protected server) and the fallback topic URL (used when the server can't be reached) are kept in your login keychain.").formFooter()
            }
            Section {
                ForEach(Self.kinds, id: \.self) { kind in
                    LabeledContent(kind.label) {
                        HStack(spacing: 8) {
                            checkbox(kind, mine: true)
                            checkbox(kind, mine: false)
                        }
                    }
                }
            } header: {
                HStack(spacing: 8) {
                    Text("Send to Phone")
                    Spacer()
                    Text("Mine").frame(width: Self.column, alignment: .trailing)
                    Text("Others").frame(width: Self.column, alignment: .trailing)
                }
            } footer: {
                Text(!store.settings.notificationsEnabled ? "Notifications are off in Settings > Notifications, so nothing is sent."
                     : store.settings.ntfyTopic.isEmpty ? "Add a topic to choose what goes to your phone."
                     : "Mine: pull requests and issues you opened. Others: ones you review, are assigned to, are mentioned in or comment on. Sent whatever the desktop style, except for your own actions and muted, snoozed or paused ones. Review reminders follow Review requested.").formFooter()
            }
            .disabled(!store.settings.notificationsEnabled || store.settings.ntfyTopic.isEmpty)
        }
        .formStyle(.grouped)
    }

    private func checkbox(_ kind: EventKind, mine: Bool) -> some View {
        let kinds = mine ? \AppSettings.phoneMine : \AppSettings.phoneOthers
        return Toggle("\(kind.label), \(mine ? "mine" : "others")", isOn: Binding(
            get: { store.settings[keyPath: kinds].contains(kind) },
            set: { if $0 { store.settings[keyPath: kinds].insert(kind) } else { store.settings[keyPath: kinds].remove(kind) } }))
        .toggleStyle(.checkbox)
        .labelsHidden()
        .frame(width: Self.column, alignment: .trailing)
    }

    private func test() {
        sending = true
        testResult = nil
        Task {
            testResult = await store.sendTestPush()
            sending = false
        }
    }
}

// MARK: Menu Bar

/// The icon, its count and dot, and what the count counts (was part of General; split so neither pane scrolls, SET-8).
struct MenuBarTab: View {
    static let height: CGFloat = 740
    @Bindable var store: Store
    @AppStorage(DefaultsKey.showMenuBarIcon) private var showIcon = true

    var body: some View {
        Form {
            Section {
                Toggle("Show in the Menu Bar", isOn: $showIcon).controlSize(.mini)
                    .onChange(of: showIcon) { StatusItem.shared.setVisible(showIcon) }
                Picker("Menu bar count", selection: $store.settings.badgeMode) {
                    Text("Pull requests that need me").tag(BadgeMode.needsMe)
                    Text("All unread").tag(BadgeMode.allUnread)
                    Text("Off").tag(BadgeMode.off)
                }
                .pickerStyle(.radioGroup)
                Toggle(isOn: $store.settings.menuBarDot) {
                    Text("Show a dot for new activity")
                    if store.settings.badgeMode == .allUnread { Text("The count already shows unread") }
                }
                .controlSize(.mini)
                .disabled(store.settings.badgeMode == .allUnread)
            } footer: {
                Text("Icon missing? Check System Settings > Menu Bar. Opening PullPing again from Applications shows the window.").formFooter()
            }
            if store.settings.badgeMode == .needsMe {
                Section {
                    ForEach(NeedReason.notifyOrder, id: \.self) { reason in  // the order of Settings > Notifications
                        Toggle(reason.settingsLabel, isOn: Binding(
                            get: { store.settings.badgeReasons.contains(reason) },
                            set: { on in
                                if on { store.settings.badgeReasons.insert(reason) } else { store.settings.badgeReasons.remove(reason) }
                            }))
                        .controlSize(.mini)
                    }
                } header: {
                    Text("Count in the Menu Bar")
                } footer: {
                    Text("Each pull request or issue counts once. Muted, hidden, merged and closed ones never count. A dot marks new activity you have not opened yet. Reminders you set always count.").formFooter()
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Shortcuts

/// Every shortcut, read-only (KBD-1). Menu shortcuts are changed in System Settings (App Shortcuts), so no recorder here;
/// single keys only switch off.
struct ShortcutsTab: View {
    static let height: CGFloat = 820
    @Bindable var store: Store

    /// Command, menu shortcut, single key: mirrors `AppCommands`' Pull Request menu and `prKeys`.
    private static let pullRequest = [("Open in Browser", "⇧⌘O", "O or ↩"), ("Mark as Read / Unread", "⇧⌘U", "U"), ("Mark All as Read", "⌥⇧⌘U", ""),
                                      ("Mute / Unmute", "⌃⌘M", "M"), ("Hide / Unhide", "⌃⌘H", "H"), ("Remind Me ▸ Custom…", "⌃⌘R", "R"),
                                      ("Stop Tracking", "⌘⌫", "")]
    private static let app = [("Refresh Now", "⌘R"), ("Open Window", "⌘1"), ("Settings", "⌘,"), ("Select All", "⌘A"),
                              ("Open in Main Window (panel)", "⌘↩")]

    var body: some View {
        Form {
            Section {
                Toggle("Single-key shortcuts", isOn: $store.settings.singleKeyShortcuts).controlSize(.mini)
            } footer: {
                Text("While a pull request list has keyboard focus, in the window and the menu-bar panel: the keys in the Key column, without ⌘.").formFooter()
            }
            Section("Pull Request") {
                LabeledContent("") { columns("Menu", "Key", keyStyle: AnyShapeStyle(.secondary)) }
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)  // a header: each row below reads its own shortcuts
                ForEach(Self.pullRequest, id: \.0) { command, menu, key in
                    let keys = store.settings.singleKeyShortcuts
                    LabeledContent(command) {
                        columns(menu, key, keyStyle: keys ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    }
                    // Says which is which ("menu ⌃⌘M, key M"); no key while single keys are off.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(command)
                    .accessibilityValue([menu.isEmpty ? nil : "menu \(menu)", keys && !key.isEmpty ? "key \(key)" : nil]
                        .compactMap { $0 }.joined(separator: ", "))
                }
            }
            Section("App") {
                ForEach(Self.app, id: \.0) { command, menu in
                    LabeledContent(command) { columns(menu, "") }.accessibilityElement(children: .combine)
                }
            }
            Section {
                Button("Open Keyboard Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                }
            } footer: {
                Text("To change a menu shortcut, add PullPing under Keyboard Shortcuts › App Shortcuts and type the menu title exactly, for example Mark as Read. Single keys cannot be changed.").formFooter()
            }
        }
        .formStyle(.grouped)
    }

    /// Two right-aligned fixed-width columns: the menu shortcut, the single key.
    private func columns(_ menu: String, _ key: String, keyStyle: AnyShapeStyle = AnyShapeStyle(.primary)) -> some View {
        HStack(spacing: 0) {
            Text(verbatim: menu).frame(width: 64, alignment: .trailing)
            // A blank, not an empty Text: an empty cell dropped the row's shortcut to a second line.
            Text(verbatim: key.isEmpty ? " " : key).frame(width: 64, alignment: .trailing).foregroundStyle(keyStyle)
        }
    }
}

// MARK: Repositories

/// Every repository-level setting on one pane: which repositories' issues are tracked, and the muted repositories.
struct RepositoriesTab: View {
    static let height: CGFloat = 630  // five muted repositories and the footer (render); more scroll
    @Bindable var store: Store
    /// Other Repositories and Excluded Repositories as typed; parsed and saved on Return, when the field loses focus (SET-4)
    /// and when Settings closes.
    @State private var repos: String
    @State private var rejected: [String] = []
    @FocusState private var reposFocused: Bool
    @State private var excluded: String
    @State private var rejectedExcluded: [String] = []
    @FocusState private var excludedFocused: Bool

    init(store: Store) {
        self.store = store
        _repos = State(initialValue: store.settings.watchedIssueRepos.joined(separator: ", "))
        _excluded = State(initialValue: store.settings.excludedIssueRepos.joined(separator: ", "))
    }

    var body: some View {
        Form {
            Section {
                Toggle("Track Issues", isOn: $store.settings.trackIssues).controlSize(.mini)
                    .onChange(of: store.settings.trackIssues) { store.refresh() }  // the next poll adds or drops them
                Toggle("Track Issues in My Repositories", isOn: $store.settings.watchOwnedIssues).controlSize(.mini)
                    .disabled(!store.settings.trackIssues)
                    .onChange(of: store.settings.watchOwnedIssues) { store.refresh() }
                TextField("Other Repositories", text: $repos, prompt: Text(verbatim: "owner/name, owner/*"))  // a format, not repositories already watched
                    .disabled(!store.settings.trackIssues)
                    .focused($reposFocused)
                    .onSubmit(commitRepos)
                    .onChange(of: reposFocused) { if !reposFocused { commitRepos() } }
                    // Closing Settings (red button, ⌘W) ends no editing and keeps this view: commit what was typed.
                    .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
                        if (note.object as? NSWindow)?.contentViewController is SettingsTabs { commitRepos(); commitExcluded() }
                    }
                if !rejected.isEmpty {
                    Text(verbatim: "Not added: \(rejected.joined(separator: ", ")). Use owner/name, or owner/* for every repository of an owner (at most \(IssueWatch.maxRepos)).")
                        .font(.subheadline).foregroundStyle(Theme.bad)
                }
                TextField("Excluded Repositories", text: $excluded, prompt: Text(verbatim: "owner/name"))
                    .disabled(!store.settings.trackIssues)
                    .focused($excludedFocused)
                    .onSubmit(commitExcluded)
                    .onChange(of: excludedFocused) { if !excludedFocused { commitExcluded() } }
                if !rejectedExcluded.isEmpty {
                    Text(verbatim: "Not excluded: \(rejectedExcluded.joined(separator: ", ")). Use owner/name (at most \(IssueWatch.maxRepos)).")
                        .font(.subheadline).foregroundStyle(Theme.bad)
                }
            } header: {
                Text("Issues")
            } footer: {
                Text("Track Issues adds open issues you opened, are assigned to, are mentioned in or comment on. Track Issues in My Repositories adds every open issue in repositories your accounts own, and tells you when someone opens a new one; Other Repositories adds more. Excluded Repositories leaves repositories out of both. To watch only some of your own, exclude the rest, or turn Track Issues in My Repositories off and list them under Other Repositories. All three need Track Issues. Issues you are part of stay tracked.").formFooter()
            }
            Section {
                let muted = store.mutedRepos
                if muted.isEmpty { Text("No Muted Repositories").foregroundStyle(.secondary) }
                ForEach(muted, id: \.self) { repo in
                    LabeledContent {
                        Button("Unmute") { store.setReposMuted([repo], false) }.accessibilityLabel("Unmute \(repo)")
                    } label: {
                        Text(verbatim: repo)
                    }
                }
            } header: {
                Text("Muted Repositories")
            } footer: {
                Text("Pull requests and issues in a muted repository stay listed, but never notify, never count and never start automations on their own, new ones included. To mute one, right-click a pull request or issue and choose Mute owner/name. Edit > Undo reverses it.").formFooter()
            }
        }
        .formStyle(.grouped)
    }

    private func commitRepos() {
        let parsed = IssueWatch.parse(repos)
        rejected = parsed.rejected
        repos = parsed.patterns.joined(separator: ", ")
        guard parsed.patterns != store.settings.watchedIssueRepos else { return }
        store.settings.watchedIssueRepos = parsed.patterns
        store.refresh()
    }

    private func commitExcluded() {
        let parsed = IssueWatch.parse(excluded, wildcards: false)
        rejectedExcluded = parsed.rejected
        excluded = parsed.patterns.joined(separator: ", ")
        guard parsed.patterns != store.settings.excludedIssueRepos else { return }
        store.settings.excludedIssueRepos = parsed.patterns
        store.refresh()
    }
}

// MARK: General

struct GeneralTab: View {
    static let height: CGFloat = 660
    @Bindable var store: Store

    var body: some View {
        Form {
            Section {
                Picker("Check GitHub every", selection: $store.settings.pollIntervalMinutes) {
                    ForEach(AppSettings.pollIntervalOptions, id: \.self) { Text($0 == 1 ? "1 minute" : "\($0) minutes").tag($0) }
                }
                LaunchAtLoginToggle()
            }
            Section {
                Picker("Layout", selection: $store.settings.inboxLayout) {
                    Text("Unified").tag(InboxLayout.unified)
                    Text("Per account").tag(InboxLayout.perAccount)
                }
                .pickerStyle(.radioGroup)
                Picker("Mark as read when selected", selection: $store.settings.markReadSeconds) {
                    ForEach(AppSettings.markReadOptions, id: \.self) { seconds in
                        Text(seconds < 0 ? "Never" : seconds == 0 ? "Immediately" : seconds == 1 ? "After 1 second" : "After \(seconds) seconds").tag(seconds)
                    }
                }
            } header: {
                Text("Inbox")
            } footer: {
                Text("Unified lists all accounts together, then each account. Per account lists each account on its own. Selecting a pull request in the window marks it read; with Never, use Mark as Read (⇧⌘U).").formFooter()
            }
            Section {
                Picker("Keep merged and closed pull requests for", selection: $store.settings.retentionDays) {
                    ForEach(AppSettings.retentionOptions, id: \.self) { Text($0 == 1 ? "1 day" : "\($0) days").tag($0) }
                }
                Picker("Keep activity for", selection: $store.settings.activityDays) {
                    ForEach(AppSettings.activityOptions, id: \.self) { Text("\($0) days").tag($0) }
                }
                .onChange(of: store.settings.activityDays) { store.compactActivity() }
                // Last row of the section (SET-9); Edit > Undo reverses it (UND-4).
                Button("Reset Ignored Pull Requests (\(store.ignoredCount))", role: .destructive) { store.resetIgnored() }
                    .disabled(store.ignoredCount == 0)
            } header: {
                Text("Tracking")
            } footer: {
                Text("Activity, in the window's sidebar, lists every event and run, at most 5000.").formFooter()
            }
            Section("About") {
                // Two per row: four in one row truncated at 520 pt.
                HStack {
                    Button("About PullPing…") { AboutWindow.show() }
                    Button("Check for Updates…") { Updates.check() }
                }
                HStack {
                    Button("Welcome Guide…") { WelcomeWindow.show() }
                    Button("Support on Ko-fi ☕") { NSWorkspace.shared.open(AboutInfo.kofi) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

extension NeedReason {
    /// Settings > Notifications, in this order (0.7.0 design §4.2).
    static let notifyOrder: [NeedReason] = [.toReview, .reReview, .teamToReview, .changesRequested, .ciFailed, .conflicts, .mentioned, .assigned,
                                            .toTriage, .newComments, .readyToMerge]

    /// Settings > Notifications.
    var notifyLabel: String {
        switch self {
        case .toReview: "Review requested"
        case .reReview: "Re-review: requested again or updated"
        case .teamToReview: "Team review requested"
        case .changesRequested: "Changes requested on your pull request"
        case .ciFailed: "CI failed on your pull request"
        case .conflicts: "Conflicts on your pull request"
        case .toTriage: "New issue in your repositories"
        case .mentioned: "Mentioned"
        case .assigned: "Assigned to you"
        case .newComments: "New comments on your pull requests and issues"
        case .readyToMerge: "Your pull request is ready to merge"
        case .reminder: "Reminders you set"
        }
    }

    /// Settings > Menu Bar > Count in the Menu Bar.
    var settingsLabel: String {
        switch self {
        case .toReview: "Review requested from me"
        case .reReview: "Re-review: re-requested, or updated after I requested changes"
        case .conflicts: "Conflicts on my pull requests"
        case .teamToReview: "Review requested from my team"
        case .assigned: "Assigned to me"
        case .toTriage: "New issues in my repositories"
        case .changesRequested: "Changes requested on my pull requests"
        case .ciFailed: "CI failed on my pull requests"
        case .mentioned: "Unread mentions of me"
        case .newComments: "New comments or reviews on my pull requests and issues"
        case .readyToMerge: "My pull requests ready to merge"
        case .reminder: "Reminders you set"
        }
    }
}

// MARK: Automations

extension AgentKind {
    var title: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

/// Handle with Agent, rules (written here), agent hooks (added by `pullping hook add`) and linked sessions, all in automations.json.
struct AutomationsTab: View {
    static let height: CGFloat = 640
    @Bindable var store: Store
    @State private var editing: Automation?
    @State private var newOverride = ""
    @State private var editingTarget: LaunchTarget?
    @State private var removingTarget: LaunchTarget?
    @State private var removingRule: Automation?
    @State private var editingScenario: Scenario?
    @State private var copied = false

    /// Homebrew links `pullping` itself; from source the user makes the link.
    private var installLine: String {
        let path = Bundle.main.executablePath ?? "/Applications/PullPing.app/Contents/MacOS/PullPing"
        return "ln -s \(path.contains(" ") ? LaunchPlanner.shellQuote(path) : path) /usr/local/bin/pullping"
    }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    (Text("Easiest: let your agent set this up.").bold()
                     + Text(" Copy the prompt, paste it into Claude Code or Codex, and it walks you through every option below."))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(copied ? "Copied" : "Copy Setup Prompt") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(AgentSetup.prompt, forType: .string)
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                    }
                    .help("Copies the text of `pullping setup prompt`")
                }
                Toggle("Run Automations", isOn: Binding(get: { store.automationsEnabled }, set: { store.setAutomationsEnabled($0) }))  // master: regular switch (SET-7)
            } header: {
                Text("Automations")
            } footer: {
                Text("An automation starts an agent in a terminal when a matching pull request event arrives. Ask puts a Run button on the notification and in the pull request's menu; Run automatically starts it at once.").formFooter()
            }
            Section {
                HStack(spacing: 10) {  // RuleRow's layout
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Handle with Agent").fontWeight(.semibold)
                        Text(verbatim: "\(AutomationCLI.agentWord(store.handler)) in \(store.automationFile.defaultTarget.name) · \(store.handler.workingDirectory)"
                             + (store.handler.source == "cli" ? " · CLI" : ""))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .help(store.handler.source == "cli" ? "Written from the command line" + (store.handler.by.isEmpty ? "" : " by \(store.handler.by)") : "")
                    }
                    Spacer(minLength: 8)
                    Toggle("Handle with Agent", isOn: Binding(get: { store.handler.enabled }, set: { store.setEnabled(Automation.handlerID, $0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                    Button("Edit…") { editing = store.handler }
                }
                Toggle("Look for earlier sessions", isOn: Binding(get: { store.automationFile.findSessions }, set: { store.setFindSessions($0) }))
                    .controlSize(.mini)
            } header: {
                Text("Handle with Agent")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Adds Handle with Agent to the notifications you pick in Edit… and to the pull request's menu. With a linked session (`pullping session set`, or one PullPing started) it becomes Resume Session and New Session. It opens with the default under Open With; the menu and the notification's chevron offer the others.").formFooter()
                    Text("Look for earlier sessions: with nothing linked, PullPing searches your Claude Code and Codex transcripts (`~/.claude/projects`, `~/.codex/sessions`) for the pull request's URL or branch. Only file names and folders are read; nothing leaves your Mac.").formFooter()
                }
            }
            .disabled(!store.automationsEnabled)
            // By use: what you turn on and edit first, then where runs open and what they say, then folders and status lists.
            Section {
                if store.rules.isEmpty { Text("No rules yet.").foregroundStyle(.secondary) }
                ForEach(store.rules) { rule in
                    RuleRow(store: store, rule: rule, onEdit: { editing = rule }, onRemove: { removingRule = rule })
                }
            } header: {
                Text("Rules")
            } footer: {
                HStack {
                    Spacer()
                    Button("Add Rule…") { editing = Automation(name: "", kinds: [], workingDirectory: Automation.defaultDirectory) }
                }
            }
            .disabled(!store.automationsEnabled)
            openWith
            backgroundRuns
            prompts
            Section {
                let folders = store.automationFile.repoFolders
                if folders.roots.isEmpty { Text("No folders.").foregroundStyle(.secondary) }
                ForEach(folders.roots, id: \.self) { root in
                    HStack {
                        Text(verbatim: root).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Button("Remove", role: .destructive) { store.mutateRepoFolders { $0.roots.removeAll { $0 == root } } }
                    }
                }
                LabeledContent("Fallback folder") {
                    HStack {
                        Text(verbatim: folders.fallback).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { if let dir = Self.chooseFolder() { store.mutateRepoFolders { $0.fallback = dir } } }
                    }
                }
            } header: {
                Text("Repository Folders")
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text("{repo_dir}, the default working directory, is the clone whose git remote matches the pull request's owner/repo, searched 3 levels deep in these folders. Not cloned: the fallback folder. Somewhere else: add an override below.").formFooter()
                    Button("Add Folder…") {
                        func expanded(_ path: String) -> String { (path as NSString).expandingTildeInPath }
                        if let dir = Self.chooseFolder() {
                            store.mutateRepoFolders { f in if !f.roots.contains(where: { expanded($0) == expanded(dir) }) { f.roots.append(dir) } }
                        }
                    }
                }
            }
            .disabled(!store.automationsEnabled)
            Section {
                let overrides = store.automationFile.repoFolders.overrides.sorted { $0.key < $1.key }
                ForEach(overrides, id: \.key) { repo, dir in
                    HStack {
                        Text(verbatim: "\(repo) → \(dir)").lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Button("Remove", role: .destructive) { store.mutateRepoFolders { $0.overrides[repo] = nil } }
                    }
                }
                HStack {
                    TextField("Repository", text: $newOverride, prompt: Text(verbatim: "owner/repo")).labelsHidden()
                    Button("Choose Folder…") {
                        let repo = newOverride.trimmingCharacters(in: .whitespaces).lowercased()
                        if let dir = Self.chooseFolder() {
                            store.mutateRepoFolders { $0.overrides[repo] = dir }
                            newOverride = ""
                        }
                    }
                    .disabled(!LaunchPlanner.isValidRepo(newOverride.trimmingCharacters(in: .whitespaces)))
                }
            } header: {
                Text("Repository Overrides")
            } footer: {
                Text("A folder for one repository, used instead of the lookup above (`pullping automations repos`).").formFooter()
            }
            .disabled(!store.automationsEnabled)
            Section {
                if store.hooks.isEmpty { Text("No hooks. Agents add them from the command line.").foregroundStyle(.secondary) }
                ForEach(store.hooks) { hook in
                    HStack {
                        Text(verbatim: Self.line(hook)).lineLimit(2)
                        Spacer(minLength: 8)
                        Button("Remove", role: .destructive) { store.removeAutomation(hook.id) }
                    }
                }
            } header: {
                Text("Agent Hooks")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(verbatim: installLine).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Spacer(minLength: 4)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(installLine, forType: .string)
                        }
                    }
                    Text("Puts `pullping` on your PATH when PullPing isn't installed with Homebrew. Then see `pullping --help`.").formFooter()
                }
            }
            .disabled(!store.automationsEnabled)
            Section {
                if store.links.isEmpty { Text("No linked sessions. Agents link themselves with `pullping session set`.").foregroundStyle(.secondary) }
                ForEach(store.links, id: \.pr) { link in  // one session may link several pull requests
                    HStack {
                        Text(verbatim: Self.line(link, now: store.now, pr: true)).lineLimit(2).help(link.by.isEmpty ? "" : "Linked by \(link.by)")
                        Spacer(minLength: 8)
                        Button("Remove", role: .destructive) { store.removeLink(link) }
                    }
                }
            } header: {
                Text("Linked Sessions")
            } footer: {
                Text("A link is dropped an hour after the pull request is merged or closed, and 30 days after it was set.").formFooter()
            }
            .disabled(!store.automationsEnabled)
            Section("Recent Runs") {
                let runs = Array(store.automationFile.runs.suffix(10).reversed())
                if runs.isEmpty { Text("No runs yet.").foregroundStyle(.secondary) }
                ForEach(runs, id: \.self) { run in
                    Label {
                        Text(verbatim: "\(run.at.formatted(date: .numeric, time: .shortened)) · \(run.label) · \(run.ok ? "OK" : run.detail)")
                            .lineLimit(2).help(run.detail)
                    } icon: {
                        Image(systemName: run.ok ? "checkmark.circle" : "exclamationmark.triangle").foregroundStyle(run.ok ? Theme.good : Theme.bad)
                    }
                }
            }
            .disabled(!store.automationsEnabled)
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { RuleEditorSheet(store: store, rule: $0, handler: $0.id == Automation.handlerID).frame(width: 560, height: 640) }
        .sheet(item: $editingTarget) { TargetEditorSheet(store: store, target: $0).frame(width: 460) }
        .sheet(item: $editingScenario) { ScenarioPromptSheet(store: store, scenario: $0).frame(width: 560, height: 600) }
        .confirmationDialog(removingRule.map { "Remove \($0.name.isEmpty ? "this rule" : "\u{201C}\($0.name)\u{201D}")?" } ?? "",
                            isPresented: Binding(get: { removingRule != nil }, set: { if !$0 { removingRule = nil } })) {
            Button("Remove", role: .destructive) { if let r = removingRule { store.removeAutomation(r.id) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its events, prompt and settings are deleted.")
        }
        .alert(removingTarget.map { "Remove \($0.name)?" } ?? "", isPresented: Binding(get: { removingTarget != nil }, set: { if !$0 { removingTarget = nil } })) {
            Button("Remove", role: .destructive) { if let t = removingTarget { store.mutateAutomationFile { $0.removeTarget(t.id) } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removingTarget.map { Self.users($0, in: store) }.map { "\($0) \($0 == 1 ? "rule uses" : "rules use") it and will use the default." } ?? "")
        }
    }

    /// Settings → Automations → Open With: where agent sessions open; the first is the default.
    private var openWith: some View {
        Section {
            let targets = store.automationFile.targets
            ForEach(Array(targets.enumerated()), id: \.element.id) { i, t in
                HStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: t.name).fontWeight(.semibold).lineLimit(1)
                        Text(verbatim: t.summary + (t.source == "cli" ? " · CLI" : "")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .help(t.source == "cli" ? "Written from the command line" + (t.by.isEmpty ? "" : " by \(t.by)") : "")
                    }
                    Spacer(minLength: 8)
                    if i == 0 { Text("Default").font(.caption).foregroundStyle(.secondary) }
                    Button("Edit…") { editingTarget = t }
                    Button("Remove", role: .destructive) { if Self.users(t, in: store) > 0 { removingTarget = t } else { store.mutateAutomationFile { $0.removeTarget(t.id) } } }
                        .disabled(targets.count == 1)
                }
                .contextMenu {  // the keyboard and VoiceOver way to reorder (A11Y-8)
                    Button("Move Up") { store.mutateAutomationFile { $0.targets.swapAt(i, i - 1) } }.disabled(i == 0)
                    Button("Move Down") { store.mutateAutomationFile { $0.targets.swapAt(i, i + 1) } }.disabled(i == targets.count - 1)
                    Button("Make Default") { store.mutateAutomationFile { $0.makeDefault(t.id) } }.disabled(i == 0)
                }
            }
            .onMove { from, to in store.mutateAutomationFile { $0.targets.move(fromOffsets: from, toOffset: to) } }
        } header: {
            Text("Open With")
        } footer: {
            HStack(alignment: .firstTextBaseline) {
                Text("Notification buttons use the first one. Drag to reorder, or right-click a row. Terminal, iTerm2 and Ghostty always open a new window.").formFooter()
                Button("Add…") {
                    let file = store.automationFile
                    editingTarget = file.newTarget(Launcher.allCases.first { $0.isInstalled && !file.targets.map(\.launcher).contains($0) } ?? .terminal)
                }
                .disabled(store.automationFile.targets.count >= LaunchTarget.maxCount)
            }
        }
        .disabled(!store.automationsEnabled)
    }

    /// Settings → Automations → Prompts: each scenario's task text, built-in or the user's.
    private var prompts: some View {
        Section {
            // Collapsed: nine rows most people never change (the summary says whether any is custom).
            DisclosureGroup {
                ForEach(Scenario.allCases, id: \.self) { s in
                    HStack {
                        Text(s.label)
                        Spacer(minLength: 8)
                        Text(store.automationFile.task(s) == s.builtIn ? "Built-in" : "Custom").font(.caption).foregroundStyle(.secondary)
                        Button("Edit…") { editingScenario = s }
                    }
                }
            } label: {
                let custom = Scenario.allCases.filter { store.automationFile.task($0) != $0.builtIn }.count
                LabeledContent("Scenario prompts", value: custom == 0 ? "All built-in" : "\(custom) custom")
            }
        } header: {
            Text("Prompts")
        } footer: {
            Text("`{task}` in the Handle with Agent prompt (and in a rule's) becomes the task of the run's scenario: what the pull request needs from you. The built-in tasks explain and propose, then wait for your OK.").formFooter()
        }
        .disabled(!store.automationsEnabled)
    }

    /// Settings → Automations → Background Runs: off by default; the daily cap.
    private var backgroundRuns: some View {
        Section {
            Toggle("Background Runs", isOn: Binding(get: { store.automationFile.background.enabled },
                                                    set: { on in store.mutateAutomationFile { $0.background.enabled = on } }))
            Stepper(value: Binding(get: { store.automationFile.background.dailyCap }, set: { cap in store.mutateAutomationFile { $0.background.dailyCap = cap } }),
                    in: BackgroundSettings.dailyCapRange) {
                Text("At most \(store.automationFile.background.dailyCap) runs a day")
            }
            .disabled(!store.automationFile.background.enabled)
        } header: {
            Text("Background Runs")
        } footer: {
            Text("Claude Code runs without a terminal and can only read the repository folder and the pull request's diff and discussion; the result is a draft, and PullPing posts nothing until you click Post. Start one from a pull request's Handle with Agent menu or from a rule. At most 2 at once, 10 minutes each. Codex can't run in the background yet.").formFooter()
        }
        .disabled(!store.automationsEnabled)
    }

    /// Rules and hooks that open with `t` (they fall back to the default when it goes).
    static func users(_ t: LaunchTarget, in store: Store) -> Int { store.automationFile.automations.filter { $0.target == t.id }.count }

    /// A folder from an open panel, `~` abbreviated; nil on Cancel.
    static func chooseFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return (url.path as NSString).abbreviatingWithTildeInPath
    }

    /// "octo-org/widgets #12 · claude · 1a2b3c4d… · ~/Code/widgets · 2 hr. ago · cli"; `pr` false: without the pull request.
    static func line(_ link: SessionLink, now: Date, pr: Bool) -> String {
        ((pr ? ["\(link.pr.repo) #\(link.pr.number)"] : []) + [link.agent.rawValue, "\(link.sessionID.prefix(8))…",
            (link.cwd as NSString).abbreviatingWithTildeInPath, relativeAge(link.setAt, now: now), link.source]).joined(separator: " · ")
    }

    /// "octo-org/widgets #12 · reviewApproved, comment · claude · resume 0f3c…"
    static func line(_ hook: Automation) -> String {
        let kinds = EventKind.allCases.filter(hook.kinds.contains).map(\.rawValue).joined(separator: ", ")
        return [hook.pr.map { "\($0.repo) #\($0.number)" } ?? "", kinds, AutomationCLI.agentWord(hook), AutomationCLI.sessionWord(hook),
                hook.mode == .auto ? "auto" : "ask"].joined(separator: " · ") + (hook.source == "cli" ? " · cli" : "")
    }
}

private struct RuleRow: View {
    let store: Store
    let rule: Automation
    let onEdit: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name).fontWeight(.semibold).lineLimit(1)
                Text(verbatim: summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(summary + (rule.source == "cli" ? "\nWritten from the command line" + (rule.by.isEmpty ? "" : " by \(rule.by)") : ""))  // whole, as it truncates (A11Y-15)
            }
            Spacer(minLength: 8)
            Toggle("Enabled", isOn: Binding(get: { rule.enabled }, set: { store.setEnabled(rule.id, $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(rule.enabled ? "On" : "Off")
            Button("Edit…", action: onEdit)
            Button("Remove…", role: .destructive, action: onRemove)
        }
    }

    /// "3 events · Mine · Ask · Claude in Terminal · CLI"
    private var summary: String {
        let scope = switch rule.scope { case .any: "Any"; case .mine: "Mine"; case .others: "Others" }
        return "\(rule.kinds.count) \(rule.kinds.count == 1 ? "event" : "events") · \(scope) · \(rule.mode == .auto ? "Automatic" : "Ask") · "
            + "\(rule.agent.title) " + (rule.background.map { "· background " + ($0 == .review ? "review" : $0 == .triage ? "triage" : "summary") } ?? "in \(store.automationFile.target(for: rule).target.name)")
            + (rule.source == "cli" ? " · CLI" : "")
    }
}

struct RuleEditorSheet: View {
    let store: Store
    /// Handle with Agent: only the events, the agent, where it opens, the folder and the prompt; saved with `setHandler`.
    let handler: Bool
    @State private var rule: Automation
    /// Comma lists as typed: a binding that re-joins would eat the comma being typed.
    @State private var repos: String
    @State private var actors: String
    /// The stored value it opened with (nil: a new rule): Save writes only while the file still holds it.
    @State private var original: Automation?
    /// Save found the file changed underneath (`pullping` meanwhile): Reload or Save Anyway.
    @State private var conflict = false
    @Environment(\.dismiss) private var dismiss
    private static let kinds = EventKind.allCases.filter { $0 != .reviewReminder && $0 != .reminder }

    init(store: Store, rule: Automation, handler: Bool = false) {
        self.store = store
        self.handler = handler
        _rule = State(initialValue: Self.shown(rule, handler: handler))
        _repos = State(initialValue: rule.repos.joined(separator: ", "))
        _actors = State(initialValue: rule.actors.joined(separator: ", "))
        _original = State(initialValue: handler || store.automationFile.automations.contains { $0.id == rule.id } ? rule : nil)
    }

    /// The handler's empty kinds (every kind) as every box checked; `original` keeps the stored value for the conflict check.
    private static func shown(_ rule: Automation, handler: Bool) -> Automation {
        var rule = rule
        if handler && rule.kinds.isEmpty { rule.kinds = Set(kinds) }
        return rule
    }

    private func save(expecting: Automation?) {
        if handler ? store.setHandler(edited, expecting: expecting) : store.saveAutomation(edited, expecting: expecting) { dismiss() } else { conflict = true }
    }

    /// The stored value as it is now; a rule removed meanwhile keeps the edits and saves as new.
    private func reload() {
        let current = handler ? store.handler : store.automationFile.automations.first { $0.id == rule.id }
        if let current {
            rule = Self.shown(current, handler: handler)
            repos = current.repos.joined(separator: ", ")
            actors = current.actors.joined(separator: ", ")
        }
        original = current
        conflict = false
    }

    private var edited: Automation {
        var rule = rule
        func list(_ text: String) -> [String] { text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        rule.name = rule.name.trimmingCharacters(in: .whitespaces)
        rule.repos = list(repos)
        rule.actors = list(actors)
        return rule
    }

    private var valid: Bool {
        let rule = edited
        func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return (handler || !blank(rule.name)) && !rule.kinds.isEmpty && !blank(rule.prompt) && !blank(rule.workingDirectory)
            && (rule.background == nil || BackgroundPlanner.unsupported(rule.agent) == nil)
    }

    /// The "Use the scenario's prompt" checkbox: a `{task}` line before the safety line (else at the end), or none.
    static func withTask(_ prompt: String, _ on: Bool) -> String {
        guard on else {
            return prompt.components(separatedBy: "\n").filter { $0.trimmingCharacters(in: .whitespaces) != "{task}" }.joined(separator: "\n")
                .replacingOccurrences(of: "{task}", with: "")
        }
        guard !prompt.contains("{task}") else { return prompt }
        var lines = prompt.components(separatedBy: "\n")
        lines.insert("{task}", at: lines.lastIndex { $0.hasPrefix("Text quoted from GitHub") } ?? lines.count)
        return lines.joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(handler ? "Handle with Agent" : original == nil ? "New Rule" : "Edit Rule").font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.top, 16)
            Form {
                if !handler {
                    Section {
                        TextField("Name", text: $rule.name, prompt: Text("Fix failing CI"))
                    }
                }
                Section {
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading) {
                        ForEach(Self.kinds, id: \.self) { kind in
                            Toggle(kind.label, isOn: Binding(get: { rule.kinds.contains(kind) },
                                                             set: { if $0 { rule.kinds.insert(kind) } else { rule.kinds.remove(kind) } }))
                                .toggleStyle(.checkbox)
                        }
                    }
                } header: {
                    Text("Events")
                } footer: {
                    if handler { Text("Show the buttons on these notifications.").formFooter() }
                }
                if !handler {  // which pull requests, mode: rules only
                    Section {
                        Picker("Pull requests", selection: $rule.scope) {
                            Text("Any").tag(AutomationScope.any)
                            Text("Mine").tag(AutomationScope.mine)
                            Text("Others").tag(AutomationScope.others)
                        }
                        .pickerStyle(.radioGroup)
                        TextField("Repositories", text: $repos, prompt: Text(verbatim: "owner/name, owner/*"))
                        TextField("Only from", text: $actors, prompt: Text("login, login"))
                    } footer: {
                        Text("Mine: pull requests and issues you opened. Others: ones you review, are assigned to, are mentioned in or comment on. Empty repositories: all of them. Empty Only from: anyone.").formFooter()
                    }
                    Section {
                        Picker("Mode", selection: $rule.mode) {
                            Text("Ask").tag(RunMode.ask)
                            Text("Run automatically").tag(RunMode.auto)
                        }
                        .pickerStyle(.radioGroup)
                    } footer: {
                        if rule.mode == .auto && edited.actors.isEmpty {
                            Text("Runs for events by anyone who can comment on the repository. Add logins to limit it.").formFooter()
                        }
                    }
                }
                Section {
                    Picker("Agent", selection: $rule.agent) {
                        ForEach(AgentKind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    TextField("Command", text: $rule.agentCommand, prompt: Text(verbatim: rule.agent.rawValue))
                    if !handler && (store.automationFile.background.enabled || rule.background != nil) {
                        Picker("Run", selection: $rule.background) {
                            Text("In a terminal").tag(BackgroundAction?.none)
                            Text("Review in the background (a draft)").tag(BackgroundAction?.some(.review))
                            Text("Summarize in the background").tag(BackgroundAction?.some(.summarize))
                            Text("Triage a new issue in the background (a draft reply)").tag(BackgroundAction?.some(.triage))
                        }
                    }
                    if !handler {  // the handler opens with the default
                        let targets = store.automationFile.targets
                        Picker("Open in", selection: $rule.target) {
                            Text(verbatim: "Default (\(store.automationFile.defaultTarget.name))").tag(String?.none)
                            ForEach(targets) { Text(verbatim: $0.name).tag(String?.some($0.id)) }
                            if let gone = rule.target, !targets.contains(where: { $0.id == gone }) {
                                Text(verbatim: "\(gone) (removed: opens with the default)").tag(String?.some(gone))
                            }
                        }
                    }
                    TextField("Working directory", text: $rule.workingDirectory, prompt: Text(verbatim: Automation.defaultDirectory))
                    if !handler {
                        Picker("Session", selection: Binding(get: { rule.usesLinkedSession }, set: { rule.sessionID = $0 ? Automation.linkedSession : nil })) {
                            Text("New session").tag(false)
                            Text("The pull request's linked session").tag(true)
                        }
                    }
                } footer: {
                    if rule.background != nil {
                        if let reason = BackgroundPlanner.unsupported(rule.agent) {
                            Text(verbatim: "\(reason): choose Claude to save this rule.").font(.subheadline).foregroundStyle(Theme.bad)
                        }
                        Text("In the background Claude Code only reads (no shell, network or write tools) and the run ends in a draft you post yourself; Open in, Session, Working directory and Prompt are not used.").formFooter()
                    }
                    if rule.usesLinkedSession {
                        Text("Runs only on pull requests with a linked session, in that session's agent and folder; Command still applies. Pull requests without a link are skipped.").formFooter()
                    }
                    Text("Command replaces `\(rule.agent.rawValue)`, for example a wrapper function. \(handler ? "Opens with the default in Open With. " : "")The working directory must exist when \(handler ? "it" : "the rule") runs; {repo_dir} is the repository's clone under Repository Folders (found by its git remote), else the fallback folder; {repo_root} the folder holding it; {main_dir} its main worktree; {worktree_dir} the worktree with the pull request's branch.").formFooter()
                }
                Section {
                    TextEditor(text: $rule.prompt).font(.body.monospaced()).frame(height: 110)
                    if handler {
                        if !rule.prompt.contains("{task}") {
                            Text("This prompt does not use scenario prompts. Add `{task}` where the task belongs.").font(.callout).foregroundStyle(.secondary)
                        }
                    } else {
                        Toggle("Use the scenario's prompt", isOn: Binding(get: { rule.prompt.contains("{task}") }, set: { rule.prompt = Self.withTask(rule.prompt, $0) }))
                            .toggleStyle(.checkbox)
                            .help("Adds or removes the {task} line: the task of the scenario (Settings → Automations → Prompts)")
                        Stepper("Runs per \(rule.itemNoun): \(rule.maxRunsPerPR)", value: $rule.maxRunsPerPR, in: 1...10)
                    }
                } header: {
                    Text("Prompt")
                } footer: {
                    Text("`{task}` is replaced by the prompt of the scenario (Prompts section). Placeholders: {pr_url} {pr_number} {repo} {repo_owner} {repo_name} {repo_dir} {repo_root} {main_dir} {worktree_dir} {is_issue} {head_sha} {event} {event_label} {account} {cwd} {automation} {scenario} {scenario_label} {resume_note} {event_url} {reviewed_sha}. Text written by others on GitHub: {title} {author} {actor} {summary} {branch}. PullPing starts the agent exactly as you would in a terminal; permission prompts are the agent's own.").formFooter()
                }
            }
            .formStyle(.grouped)
            if conflict {
                HStack(alignment: .firstTextBaseline) {
                    Text("Changed elsewhere since you opened this (from the command line).").font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Reload", action: reload)
                    Button("Save Anyway") { save(expecting: nil) }
                }
                .padding(.horizontal, 16).padding(.top, 12)
            }
            let blocked = handler ? nil : store.prs.first.flatMap { store.runBlocked(edited, $0) }  // the handler has no caps
            let last = store.automationFile.runs.last(where: { $0.automationID == rule.id })
            // Above the buttons, whole: an error names the folder it tried.
            // A block names the pull request Try would use ("octo-org/widgets #12: No linked session").
            if let status = blocked.flatMap({ b in store.prs.first.map { "\($0.repo) #\($0.number): \(b)" } }) ?? last.map({ $0.ok ? "Started" : $0.detail }) {
                Text(verbatim: status).font(.callout).foregroundStyle(blocked != nil ? .secondary : last?.ok == true ? Theme.good : Theme.bad)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.top, 12)
            }
            HStack {
                Button("Try with Latest Pull Request") {
                    guard let pr = store.prs.first else { return }
                    if handler { store.runHandler(prID: pr.id, mode: .new, event: nil, edited: edited) } else { store.run(edited, prID: pr.id, event: nil) }
                }
                .disabled(store.prs.isEmpty || !valid || blocked != nil)
                .help(store.prs.first.map { "Runs this \(handler ? "in a new session" : "rule") now on \($0.repo) #\($0.number)" } ?? "No pull requests yet")
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(expecting: original) }
                .keyboardShortcut(.defaultAction).disabled(!valid)
            }
            .padding(16)
        }
    }
}

/// Open With › Add… / Edit…: a target's name, app, custom line and Ghostex reuse. A new target gets an id from its app.
struct TargetEditorSheet: View {
    let store: Store
    @State private var target: LaunchTarget
    @Environment(\.dismiss) private var dismiss

    init(store: Store, target: LaunchTarget) {
        self.store = store
        _target = State(initialValue: target)
    }

    private var isNew: Bool { !store.automationFile.targets.contains { $0.id == target.id } }
    private var valid: Bool { target.launcher != .custom || !target.customCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            Text(isNew ? "Add to Open With" : "Edit Open With").font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.top, 16)
            Form {
                Section {
                    TextField("Name", text: $target.name, prompt: Text(verbatim: target.launcher.title))
                    Picker("Open in", selection: $target.launcher) {
                        // Installed apps and Custom; a saved app that's gone stays listed so the picker shows it.
                        ForEach(Launcher.allCases.filter { $0.isInstalled || $0 == target.launcher }, id: \.self) { launcher in
                            Text(verbatim: launcher.isInstalled ? launcher.title : "\(launcher.title) (not installed)").tag(launcher)
                        }
                    }
                    if target.launcher == .custom {
                        TextField("Custom command", text: $target.customCommand, prompt: Text(verbatim: "open -a iTerm {script}"))
                    }
                    if target.launcher == .ghostex {
                        Toggle("Focus the session if it is already running", isOn: $target.reuseRunning).controlSize(.mini)
                    }
                } footer: {
                    Text(target.launcher == .custom
                         ? "The launch line for any other terminal. Placeholders, inserted already quoted: {script} {cwd} {title} {prompt_file} {agent_command}."
                         : target.launcher == .ghostex
                         ? "Resume Session then focuses the session when it already runs in Ghostex and types a line pointing at the prompt, without pressing Return."
                         : "Opens a new window for every run.").formFooter()
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") { save() }.keyboardShortcut(.defaultAction).disabled(!valid)
            }
            .padding(16)
        }
    }

    private func save() {
        var t = target
        t.name = PromptTemplate.clean(t.name, max: 40)
        if t.name.isEmpty { t.name = t.launcher.title }
        if t.launcher != .custom { t.customCommand = "" }
        (t.source, t.by) = ("ui", "")
        store.mutateAutomationFile { file in
            if let i = file.targets.firstIndex(where: { $0.id == t.id }) {
                file.targets[i] = t
            } else if file.targets.count < LaunchTarget.maxCount {
                t.id = file.newTargetID(t.launcher.rawValue)  // from the app it ended up with
                file.targets.append(t)
            }
        }
        dismiss()
    }
}

/// Prompts › Edit…: one scenario's task text, the placeholders, Reset to Built-in, and the whole prompt it makes.
struct ScenarioPromptSheet: View {
    let store: Store
    let scenario: Scenario
    @State private var text: String
    @Environment(\.dismiss) private var dismiss

    init(store: Store, scenario: Scenario) {
        self.store = store
        self.scenario = scenario
        _text = State(initialValue: store.automationFile.task(scenario))
    }

    private var blank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextEditor(text: $text).font(.body.monospaced()).frame(height: 130)
                } header: {
                    Text(scenario.label)
                } footer: {
                    Text("Placeholders as in the prompt, for example {pr_url} {head_sha} {event_url} (the comment or review) {reviewed_sha} (the commit of your last review). At most \(Scenario.maxTaskLength) characters\(text.count > Scenario.maxTaskLength ? " (now \(text.count))" : "").").formFooter()
                }
                Section {
                    Text(verbatim: preview).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                } header: {
                    Text("Preview")
                } footer: {
                    if !store.handler.prompt.contains("{task}") {
                        Text("The Handle with Agent prompt has no `{task}`, so it doesn't use this text yet.").formFooter()
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Reset to Built-in") { text = scenario.builtIn }.disabled(text == scenario.builtIn)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    store.mutateAutomationFile { $0.scenarioPrompts[scenario.rawValue] = text == scenario.builtIn ? nil : text }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).disabled(blank || text.count > Scenario.maxTaskLength)
            }
            .padding(16)
        }
    }

    /// The Handle with Agent prompt with this text, on the latest pull request (a placeholder one without any). Writes nothing.
    private var preview: String {
        let file = store.automationFile
        var handler = file.handler
        handler.workingDirectory = "~"  // the preview is about the prompt; the folder is checked when it runs
        let pr = store.prs.first ?? {
            var pr = TrackedPR(id: "PREVIEW", accountID: UUID(), firstTrackedAt: Date())
            (pr.repo, pr.number, pr.title, pr.url) = ("octo-org/widgets", 12, "Add a widget cache", URL(string: "https://github.com/octo-org/widgets/pull/12")!)
            return pr
        }()
        do {
            return try LaunchPlanner.plan(handler, pr: pr, event: nil, account: store.account(pr.accountID)?.login ?? "", runID: "preview",
                                          runsDir: FileManager.default.temporaryDirectory, home: NSHomeDirectory(), folders: file.repoFolders,
                                          index: store.index(file.repoFolders), scenario: scenario, task: blank ? nil : text).promptText
                .trimmingCharacters(in: .newlines)
        } catch {
            return error.localizedDescription
        }
    }
}
