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

    /// Homebrew links `pullping` itself; from source the user makes the link.
    private var installLine: String {
        let path = Bundle.main.executablePath ?? "/Applications/PullPing.app/Contents/MacOS/PullPing"
        return "ln -s \(path.contains(" ") ? LaunchPlanner.shellQuote(path) : path) /usr/local/bin/pullping"
    }

    var body: some View {
        Form {
            Section {
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
                        Text(verbatim: "\(AutomationCLI.agentWord(store.handler)) in \(store.handler.launcher.title) · \(store.handler.workingDirectory)"
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
            } header: {
                Text("Handle with Agent")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Adds a Handle with Agent button to the notifications you pick in Edit… and to the pull request's menu. When an agent has linked its session to the pull request (`pullping session set`, or one PullPing started), the button becomes Resume Session and New Session.").formFooter()
                    Text("When a pull request has no linked session, PullPing searches your local Claude Code and Codex transcripts (`~/.claude/projects`, `~/.codex/sessions`) for the pull request's URL or branch. Only file names and folders are read into PullPing; nothing leaves your Mac.").formFooter()
                }
            }
            .disabled(!store.automationsEnabled)
            Section {
                if store.rules.isEmpty { Text("No rules yet.").foregroundStyle(.secondary) }
                ForEach(store.rules) { rule in
                    RuleRow(store: store, rule: rule) { editing = rule }
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
                    Text("{repo_dir}, the default working directory: PullPing finds a repository by the owner/repo of its git remotes in these folders (3 levels deep), whatever the clone is called; without one, the fallback folder, so a run never fails only because the repository isn't cloned. Add an override when it lives elsewhere.").formFooter()
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
    }

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

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name).fontWeight(.semibold).lineLimit(1)
                Text(verbatim: summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(rule.source == "cli" ? "Written from the command line" + (rule.by.isEmpty ? "" : " by \(rule.by)") : "")
            }
            Spacer(minLength: 8)
            Toggle("Enabled", isOn: Binding(get: { rule.enabled }, set: { store.setEnabled(rule.id, $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(rule.enabled ? "On" : "Off")
            Button("Edit…", action: onEdit)
            Button("Remove", role: .destructive) { store.removeAutomation(rule.id) }
        }
    }

    /// "3 events · Mine · Ask · Claude in Terminal · CLI"
    private var summary: String {
        let scope = switch rule.scope { case .any: "Any"; case .mine: "Mine"; case .others: "Others" }
        return "\(rule.kinds.count) \(rule.kinds.count == 1 ? "event" : "events") · \(scope) · \(rule.mode == .auto ? "Automatic" : "Ask") · "
            + "\(rule.agent.title) in \(rule.launcher.title)" + (rule.source == "cli" ? " · CLI" : "")
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
    private static let kinds = EventKind.allCases.filter { $0 != .reviewReminder }

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
            && !(rule.launcher == .custom && blank(rule.customCommand))
    }

    var body: some View {
        VStack(spacing: 0) {
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
                    Picker("Open in", selection: $rule.launcher) {
                        // Installed apps and Custom; a saved app that's gone stays listed so the picker shows it.
                        ForEach(Launcher.allCases.filter { $0.isInstalled || $0 == rule.launcher }, id: \.self) { launcher in
                            Text(verbatim: launcher.isInstalled ? launcher.title : "\(launcher.title) (not installed)").tag(launcher)
                        }
                    }
                    if rule.launcher == .custom {
                        TextField("Custom command", text: $rule.customCommand, prompt: Text(verbatim: "open -a iTerm {script}"))
                    }
                    TextField("Working directory", text: $rule.workingDirectory, prompt: Text(verbatim: Automation.defaultDirectory))
                    if !handler {
                        Picker("Session", selection: Binding(get: { rule.usesLinkedSession }, set: { rule.sessionID = $0 ? Automation.linkedSession : nil })) {
                            Text("New session").tag(false)
                            Text("The pull request's linked session").tag(true)
                        }
                    }
                } footer: {
                    if rule.usesLinkedSession {
                        Text("Runs only on pull requests with a linked session, in that session's agent and folder; Command still applies. Pull requests without a link are skipped.").formFooter()
                    }
                    Text(rule.launcher == .custom
                         ? "Command replaces `\(rule.agent.rawValue)`, for example a wrapper function. Custom command placeholders, inserted already quoted: {script} {cwd} {title} {prompt_file} {agent_command}. iTerm: `open -a iTerm {script}`."
                         : "Command replaces `\(rule.agent.rawValue)`, for example a wrapper function. The working directory must exist when \(handler ? "it" : "the rule") runs; {repo_dir} is the repository's clone under Repository Folders (found by its git remote), else the fallback folder; {repo_root} the folder holding it; {main_dir} its main worktree; {worktree_dir} the worktree with the pull request's branch.").formFooter()
                }
                Section {
                    TextEditor(text: $rule.prompt).font(.body.monospaced()).frame(height: 110)
                    if !handler { Stepper("Runs per pull request: \(rule.maxRunsPerPR)", value: $rule.maxRunsPerPR, in: 1...10) }
                } header: {
                    Text("Prompt")
                } footer: {
                    Text("Placeholders: {pr_url} {pr_number} {repo} {repo_owner} {repo_name} {repo_dir} {repo_root} {main_dir} {worktree_dir} {is_issue} {head_sha} {event} {event_label} {account} {cwd} {automation}. Text written by others on GitHub: {title} {author} {actor} {summary} {branch}. PullPing starts the agent exactly as you would in a terminal; permission prompts are the agent's own.").formFooter()
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
            if let status = blocked ?? last.map({ $0.ok ? "Started" : $0.detail }) {
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
