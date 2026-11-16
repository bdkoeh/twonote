import AppKit
import SwiftUI
import TwoNoteCore

/// Settings (⌘,): a Mac settings window with a tab per topic - the account, sync, security,
/// the account's devices, and sharing (the Share menu and the widget). The same contents and
/// wording as the iPhone's settings sheet.
/// While TwoNote is locked it shows nothing but that.
struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if app.phase == .unlocked, let client = app.client {
                TabView {
                    Tab("Account", systemImage: "person.crop.circle") {
                        AccountSettings(client: client)
                    }
                    Tab("Sync", systemImage: "arrow.triangle.2.circlepath") {
                        SyncSettings(client: client)
                    }
                    Tab("Security", systemImage: "lock") {
                        SecuritySettings()
                    }
                    Tab("Devices", systemImage: "laptopcomputer.and.iphone") {
                        DevicesView()
                    }
                    if let library = app.library {
                        Tab("Sharing", systemImage: "square.and.arrow.up") {
                            SharingSettings(library: library)
                        }
                    }
                }
                .scenePadding()
            } else {
                ContentUnavailableView(
                    app.phase == .setUp ? "TwoNote Isn’t Set Up" : "TwoNote Is Locked",
                    systemImage: "lock",
                    description: Text(app.phase == .setUp
                        ? "Set up TwoNote in its window first."
                        : "Unlock TwoNote to see its settings."))
                .padding(40)
            }
        }
        .frame(width: 520)
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return "\(version) (\(build))"
    }
}

private struct AccountSettings: View {
    let client: TwoNoteClient
    @Environment(AppModel.self) private var app
    @State private var confirmSignOut = false

    var body: some View {
        Form {
            Section("Account") {
                LabeledContent("Username", value: client.account?.username ?? "")
                LabeledContent("Server", value: app.serverURL?.absoluteString ?? "")
                LabeledContent("This Mac", value: client.account?.deviceName ?? "")
                LabeledContent("Version", value: SettingsView.version)
            }
            Section {
                HStack {
                    Text("Removes your account and its notes from this Mac. Your notes stay on your server and your other devices.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Sign Out…", role: .destructive) {
                        confirmSignOut = true
                    }
                    .accessibilityIdentifier("settings-sign-out")
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .alert("Sign out of TwoNote on this Mac?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) {
                Task { await app.removeAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your notes stay on the server and your other devices. Changes on this device that have not synced are lost. This device is removed from your account’s devices if the server is in reach. To use TwoNote here again you need your Secret Key.")
        }
        .dialogSeverity(.critical)
    }
}

private struct SyncSettings: View {
    let client: TwoNoteClient
    @Environment(AppModel.self) private var app
    @State private var askPassword = false
    @State private var password = ""
    @State private var working = false
    @State private var failure: UserMessage?

    var body: some View {
        let status = client.syncMonitor.status
        let summary = SyncSummary(status)
        Form {
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Image(systemName: summary.symbol)
                            .imageScale(.small)
                        Text(summary.title)
                    }
                    .foregroundStyle(summary.wantsAttention ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .accessibilityIdentifier("settings-sync-status")
                }
                if let last = status.lastSyncedAt {
                    LabeledContent("Last Synced", value: last.formatted(date: .abbreviated, time: .shortened))
                }
                if let waiting = summary.waiting {
                    LabeledContent("Waiting to Sync", value: waiting)
                }
                LabeledContent("Server", value: app.serverURL?.absoluteString ?? "")
            } footer: {
                Text(summary.kind == .problem ? [summary.explanation, status.lastError].compactMap { $0 }.joined(separator: " ") : summary.explanation)
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Spacer()
                    if summary.kind == .needsSignIn {
                        Button("Sign In Again…") {
                            password = ""
                            askPassword = true
                        }
                        .disabled(working)
                    } else {
                        Button("Sync Now") {
                            client.sync.requestSync()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .alert("Sign In Again", isPresented: $askPassword) {
            SecureField("Password", text: $password)
            Button("Cancel", role: .cancel) {}
            Button("Sign In") { signIn() }
        } message: {
            Text("Enter the account’s current password.")
        }
        .messageAlert($failure)
    }

    private func signIn() {
        let attempt = password
        password = ""
        guard !attempt.isEmpty else { return }
        working = true
        Task {
            do {
                try await app.signInAgain(password: attempt)
            } catch let message as UserMessage {
                failure = message
            } catch {
                failure = .generic(error)
            }
            working = false
        }
    }
}

private struct SecuritySettings: View {
    @Environment(AppModel.self) private var app
    @State private var askBiometricsPassword = false
    @State private var password = ""
    @State private var working = false
    @State private var failure: UserMessage?
    @State private var changingPassword = false
    @State private var showingSecretKey = false

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                if app.biometry != .none || app.biometricUnlockEnabled {
                    Toggle(isOn: Binding(get: { app.biometricUnlockEnabled }, set: { setBiometrics($0) })) {
                        Label("Unlock with \(app.biometry.name)", systemImage: app.biometry.symbol)
                    }
                    .disabled(working)
                    .accessibilityIdentifier("settings-biometrics")
                } else {
                    LabeledContent {
                        Text("Not available on this Mac")
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("Unlock with Touch ID", systemImage: "touchid")
                    }
                    .accessibilityIdentifier("settings-biometrics-unavailable")
                }
                Picker(selection: $app.autoLock) {
                    ForEach(AutoLockDelay.allCases) { delay in
                        Text(delay.title).tag(delay)
                    }
                } label: {
                    Label("Auto-Lock", systemImage: "lock.rotation")
                }
                .accessibilityIdentifier("settings-autolock")
            } footer: {
                Text(Self.autoLockFooter)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent {
                    Button("Change…") { changingPassword = true }
                        .accessibilityIdentifier("settings-change-password")
                } label: {
                    Label("Password", systemImage: "key")
                }
                LabeledContent {
                    Button("Show…") { showingSecretKey = true }
                        .accessibilityIdentifier("settings-secret-key")
                } label: {
                    Label("Secret Key", systemImage: "key.viewfinder")
                }
                LabeledContent {
                    Button("Lock Now") {
                        Task {
                            await app.willResignActive()
                            await app.lock()
                        }
                    }
                    .accessibilityIdentifier("settings-lock")
                } label: {
                    Label("Lock TwoNote", systemImage: "lock")
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $changingPassword) {
            ChangePasswordView()
        }
        .sheet(isPresented: $showingSecretKey) {
            SecretKeyView()
        }
        .alert("Turn On \(app.biometry.name)", isPresented: $askBiometricsPassword) {
            SecureField("Password", text: $password)
                .accessibilityIdentifier("settings-biometrics-password")
            Button("Cancel", role: .cancel) {}
            Button("Turn On") { turnOnBiometrics() }
        } message: {
            Text("Enter your password to let \(app.biometry.name) unlock TwoNote on this Mac.")
        }
        .messageAlert($failure)
    }

    static let autoLockFooter = "TwoNote locks when you haven’t used it for the Auto-Lock time, and when your Mac sleeps or its screen locks (unless Auto-Lock is Never). Locking closes your notes and removes their keys from memory."

    private func setBiometrics(_ on: Bool) {
        if on {
            password = ""
            askBiometricsPassword = true
        } else {
            Task { try? await app.setBiometricUnlock(false) }
        }
    }

    private func turnOnBiometrics() {
        let attempt = password
        password = ""
        guard !attempt.isEmpty else { return }
        working = true
        Task {
            do {
                try await app.setBiometricUnlock(true, password: attempt)
            } catch let message as UserMessage {
                failure = message
            } catch {
                failure = .generic(error)
            }
            working = false
        }
    }
}

/// The devices signed in to the account, with a way to sign another one out. Needs the server.
struct DevicesView: View {
    @Environment(AppModel.self) private var app

    @State private var devices: [DeviceInfo]?
    @State private var loadFailure: UserMessage?
    @State private var failure: UserMessage?
    @State private var revoking: DeviceInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            List {
                if let devices {
                    ForEach(devices) { device in
                        row(device)
                    }
                }
            }
            .listStyle(.bordered)
            .alternatingRowBackgrounds()
            .frame(height: 220)
            .overlay {
                if let loadFailure {
                    ContentUnavailableView {
                        Label(loadFailure.title, systemImage: "wifi.slash")
                    } description: {
                        Text(loadFailure.detail)
                    } actions: {
                        Button("Try Again") { Task { await load() } }
                    }
                } else if devices == nil {
                    ProgressView()
                }
            }
            Text("Revoking a device signs it out: it can no longer sync. Notes already on it stay readable there until it is signed out or erased; to shut it out completely, also change your password.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Refresh") { Task { await load() } }
            }
        }
        .padding(8)
        .task { await load() }
        .alert(
            "Revoke “\(revoking?.name ?? "")”?",
            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
            presenting: revoking
        ) { device in
            Button("Revoke Device", role: .destructive) { revoke(device) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It is signed out and can no longer sync until someone signs in on it again with your password.")
        }
        .messageAlert($failure)
    }

    @ViewBuilder
    private func row(_ device: DeviceInfo) -> some View {
        HStack {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name.isEmpty ? "Unnamed Device" : device.name)
                Text(device.current ? "This Device" : "Last used \(Self.date(device.lastSeenAt))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !device.current {
                Button("Revoke…") { revoking = device }
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if !device.current {
                Button("Revoke…", role: .destructive) { revoking = device }
            }
        }
    }

    static func date(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? "today at \(date.formatted(date: .omitted, time: .shortened))"
            : date.formatted(date: .abbreviated, time: .omitted)
    }

    private func load() async {
        do {
            devices = try await app.devices()
            loadFailure = nil
        } catch let message as UserMessage {
            devices = nil
            loadFailure = message
        } catch {
            devices = nil
            loadFailure = .generic(error)
        }
    }

    private func revoke(_ device: DeviceInfo) {
        Task {
            do {
                try await app.revokeDevice(device.deviceId)
            } catch let message as UserMessage {
                failure = message
            } catch {
                failure = .generic(error)
            }
            await load()
        }
    }
}

/// Changing the account password, in a sheet over Settings. Needs the server.
struct ChangePasswordView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var current = ""
    @State private var new = ""
    @State private var verify = ""
    @State private var working = false
    @State private var failure: UserMessage?
    @State private var changed = false
    @FocusState private var focus: Field?

    private enum Field {
        case current, new, verify
    }

    static let minimumLength = 8

    /// What is still wrong with the form, or nil when it can be sent. (The iPhone's rule.)
    static func problem(current: String, new: String, verify: String) -> String? {
        if current.isEmpty || new.isEmpty { return "" }
        if new.count < minimumLength { return "The new password needs at least \(minimumLength) characters." }
        if new == current { return "The new password is the same as the current one." }
        if verify.isEmpty { return "" }
        if new != verify { return "The new passwords don’t match." }
        return nil
    }

    var body: some View {
        let problem = Self.problem(current: current, new: new, verify: verify)
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    SecureField("Current Password", text: $current)
                        .textContentType(.password)
                        .focused($focus, equals: .current)
                        .onSubmit { focus = .new }
                        .accessibilityIdentifier("password-current")
                }
                Section {
                    SecureField("New Password", text: $new)
                        .textContentType(.newPassword)
                        .focused($focus, equals: .new)
                        .onSubmit { focus = .verify }
                        .accessibilityIdentifier("password-new")
                    SecureField("Verify", text: $verify)
                        .textContentType(.newPassword)
                        .focused($focus, equals: .verify)
                        .onSubmit(submit)
                        .accessibilityIdentifier("password-verify")
                } footer: {
                    if let problem, !problem.isEmpty {
                        Text(problem)
                            .foregroundStyle(.red)
                    } else {
                        Text("At least \(Self.minimumLength) characters. A few unrelated words make a strong password that is easy to type.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text("Changing the password needs your server. Your other devices are signed out and ask for the new password the next time they sync. Your Secret Key and your notes stay as they are.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            HStack {
                if working {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Change Password", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil || working)
                    .accessibilityIdentifier("password-submit")
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460, height: 430)
        .onAppear { focus = .current }
        .messageAlert($failure)
        .alert("Password Changed", isPresented: $changed) {
            Button("OK") { dismiss() }
        } message: {
            Text("Use the new password to unlock TwoNote from now on, here and on your other devices.")
        }
    }

    private func submit() {
        guard Self.problem(current: current, new: new, verify: verify) == nil, !working else { return }
        working = true
        Task {
            do {
                try await app.changePassword(current: current, new: new)
                (current, new, verify) = ("", "", "")
                changed = true
            } catch let message as UserMessage {
                failure = message
            } catch {
                failure = .generic(error)
            }
            working = false
        }
    }
}

/// The Secret Key, shown only after Touch ID (if that unlocks the app) or the password was
/// checked, and hidden again when the sheet closes or the app locks.
struct SecretKeyView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var key: String?
    @State private var askPassword = false
    @State private var password = ""
    @State private var working = false
    @State private var failure: UserMessage?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Secret Key")
                .font(.headline)
            Group {
                if let key {
                    Text(key)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: .rect(cornerRadius: 6))
                        .accessibilityIdentifier("secret-key-text")
                } else {
                    Button("Show Secret Key…", systemImage: "eye") {
                        reveal()
                    }
                    .disabled(working)
                    .accessibilityIdentifier("secret-key-show")
                }
            }
            Text("Your Secret Key and your password together open your notes. You need both to set up TwoNote on another device. Keep the Secret Key somewhere safe and never share it; your server does not have it and cannot restore it.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if let key {
                    Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        copy(key)
                    }
                    Button("Hide", systemImage: "eye.slash") { hide() }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onDisappear(perform: hide)
        .onChange(of: app.phase) { hide(); dismiss() }
        .alert("Show Secret Key", isPresented: $askPassword) {
            SecureField("Password", text: $password)
                .accessibilityIdentifier("secret-key-password")
            Button("Cancel", role: .cancel) {}
            Button("Show") { revealWithPassword() }
        } message: {
            Text("Enter your password to show the Secret Key.")
        }
        .messageAlert($failure)
    }

    /// Onto the pasteboard of this Mac only (not Universal Clipboard), and off it again after
    /// two minutes if nothing else was copied since.
    private func copy(_ key: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(key, forType: .string)
        let count = pasteboard.changeCount
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(120))
            if pasteboard.changeCount == count {
                pasteboard.clearContents()
            }
        }
    }

    private func hide() {
        key = nil
        copied = false
    }

    private func reveal() {
        guard app.biometricUnlockEnabled else {
            password = ""
            askPassword = true
            return
        }
        working = true
        Task {
            do {
                key = try await app.secretKeyAfterBiometricCheck()
            } catch BiometricFailure.cancelled {
                // Nothing to say.
            } catch is BiometricFailure {
                password = ""
                askPassword = true // not recognised, or "Enter Password"
            } catch let message as UserMessage {
                failure = message
            } catch {
                failure = .generic(error)
            }
            working = false
        }
    }

    private func revealWithPassword() {
        let attempt = password
        password = ""
        guard !attempt.isEmpty else { return }
        working = true
        Task {
            do {
                key = try await app.secretKey(password: attempt)
            } catch let message as UserMessage {
                failure = message
            } catch {
                failure = .generic(error)
            }
            working = false
        }
    }
}
