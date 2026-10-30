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
                token = try await DeviceFlow.poll(code: code, transport: URLSessionTransport())
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
        store.addAccount(viewer, token: token.trimmingCharacters(in: .whitespacesAndNewlines), kind: method)
        dismiss()
    }
}

// MARK: Notifications

struct NotificationsTab: View {
    @Bindable var store: Store
    static let height: CGFloat = 640  // plan height; the 18-row table scrolls
    private static let kinds = EventKind.allCases.filter { $0 != .reviewReminder }
    private static let column: CGFloat = 112

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
                ForEach(Self.kinds, id: \.self) { kind in
                    LabeledContent(kind.label) {
                        HStack(spacing: 8) {
                            stylePicker(kind, mine: true)
                            stylePicker(kind, mine: false)
                        }
                    }
                }
            } header: {
                HStack(spacing: 8) {
                    Text("Notify Me About")
                    Spacer()
                    Text("Mine").frame(width: Self.column, alignment: .trailing)
                    Text("Others").frame(width: Self.column, alignment: .trailing)
                }
            } footer: {
                Text("Mine: pull requests and issues you opened. Others: ones you review, are assigned to, are mentioned in or comment on. A banner hides after a few seconds; an alert stays until you act on it.").formFooter()
            }
            .disabled(!store.settings.notificationsEnabled)
            Section {
                Picker("Remind me every", selection: $store.settings.reminderMinutes) {
                    ForEach(AppSettings.reminderOptions, id: \.self) { Text($0 == 0 ? "Off" : "\($0) minutes").tag($0) }
                }
            } header: {
                Text("Review Reminders")
            } footer: {
                Text("Repeats until you review, the request is removed, or the pull request is merged or closed.").formFooter()
            }
            .disabled(!store.settings.notificationsEnabled)
        }
        .formStyle(.grouped)
    }

    private func stylePicker(_ kind: EventKind, mine: Bool) -> some View {
        Picker("\(kind.label), \(mine ? "mine" : "others")", selection: Binding(
            get: { store.settings.style(for: kind, mine: mine) },
            set: { if mine { store.settings.styles[kind] = $0 } else { store.settings.otherStyles[kind] = $0 } })) {
            Text("Off").tag(NotificationStyle.off)
            Text("Banner").tag(NotificationStyle.banner)
            Text("Alert").tag(NotificationStyle.alert)
        }
        .labelsHidden()
        .fixedSize()
        .frame(width: Self.column, alignment: .trailing)
    }
}

// MARK: Phone

/// ntfy pushes (MeetAlert pattern): server and topic in settings, access token and fallback URL in the keychain.
struct PhoneTab: View {
    static let height: CGFloat = 640  // plan height; the 18-row table scrolls
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

// MARK: General

struct GeneralTab: View {
    static let height: CGFloat = 640
    @Bindable var store: Store
    @AppStorage(DefaultsKey.showMenuBarIcon) private var showIcon = true

    var body: some View {
        Form {
            Section {
                Picker("Check GitHub every", selection: $store.settings.pollIntervalMinutes) {
                    ForEach(AppSettings.pollIntervalOptions, id: \.self) { Text($0 == 1 ? "1 minute" : "\($0) minutes").tag($0) }
                }
                LaunchAtLoginToggle()
                Toggle("Show in the Menu Bar", isOn: $showIcon).controlSize(.mini)
                    .onChange(of: showIcon) { StatusItem.shared.setVisible(showIcon) }
                Picker("Menu bar count", selection: $store.settings.badgeMode) {
                    Text("Pull requests that need me").tag(BadgeMode.needsMe)
                    Text("All unread").tag(BadgeMode.allUnread)
                    Text("Off").tag(BadgeMode.off)
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text("Icon missing? Check System Settings > Menu Bar. Opening PullPing again from Applications shows the window.").formFooter()
            }
            if store.settings.badgeMode == .needsMe {
                Section {
                    ForEach(NeedReason.allCases, id: \.self) { reason in
                        Toggle(reason.settingsLabel, isOn: Binding(
                            get: { store.settings.badgeReasons.contains(reason) },
                            set: { on in
                                if on { store.settings.badgeReasons.insert(reason) } else { store.settings.badgeReasons.remove(reason) }
                            }))
                    }
                } header: {
                    Text("Count in the Menu Bar")
                } footer: {
                    Text("Each pull request or issue counts once. Muted, hidden, merged and closed ones never count.").formFooter()
                }
            }
            Section {
                Picker("Layout", selection: $store.settings.inboxLayout) {
                    Text("Unified").tag(InboxLayout.unified)
                    Text("Per account").tag(InboxLayout.perAccount)
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Inbox")
            } footer: {
                Text("Unified lists all accounts together, then each account. Per account lists each account on its own.").formFooter()
            }
            Section {
                Toggle("Track Issues", isOn: $store.settings.trackIssues).controlSize(.mini)
                    .onChange(of: store.settings.trackIssues) { store.refresh() }  // the next poll adds or drops them
                Picker("Keep merged and closed pull requests for", selection: $store.settings.retentionDays) {
                    ForEach(AppSettings.retentionOptions, id: \.self) { Text($0 == 1 ? "1 day" : "\($0) days").tag($0) }
                }
                // Last row of the section (SET-9); Edit > Undo reverses it (UND-4).
                Button("Reset Ignored Pull Requests (\(store.ignoredCount))", role: .destructive) { store.resetIgnored() }
                    .disabled(store.ignoredCount == 0)
            } header: {
                Text("Tracking")
            } footer: {
                Text("Track Issues adds open issues you opened, are assigned to, are mentioned in or comment on. Turning it off removes them from the lists.").formFooter()
            }
            Section("About") {
                HStack {
                    Button("About PullPing…") { AboutWindow.show() }
                    Button("Welcome Guide…") { WelcomeWindow.show() }
                    Button("Support on Ko-fi ☕") { NSWorkspace.shared.open(AboutInfo.kofi) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

extension NeedReason {
    /// Settings > General > Count in the Menu Bar.
    var settingsLabel: String {
        switch self {
        case .toReview: "Review requested from me"
        case .teamToReview: "Review requested from my team"
        case .assigned: "Assigned to me"
        case .changesRequested: "Changes requested on my pull requests"
        case .ciFailed: "CI failed on my pull requests"
        case .mentioned: "Unread mentions of me"
        case .newComments: "New comments or reviews on my pull requests and issues"
        case .readyToMerge: "My pull requests ready to merge"
        }
    }
}
