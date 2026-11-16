import SwiftUI
import TwoNoteCore

/// Settings: the account, how sync is doing, security (biometric unlock, auto-lock, password,
/// Secret Key), the account's devices, and signing out. One sheet, reached from the More menu
/// and from the sync status.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var askSignInPassword = false
    @State private var askBiometricsPassword = false
    @State private var password = ""
    @State private var working = false
    @State private var failure: UserMessage?
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            Form {
                if let client = app.client {
                    accountSection(client)
                    syncSection(client)
                    securitySection
                    Section {
                        NavigationLink {
                            DevicesView()
                        } label: {
                            Label("Devices", systemImage: "laptopcomputer.and.iphone")
                        }
                        .accessibilityIdentifier("settings-devices")
                    } footer: {
                        Text("The devices that are signed in to your account.")
                    }
                    SharedItemsSection()
                    WidgetSection()
                    Section {
                        Button("Sign Out…", role: .destructive) {
                            confirmSignOut = true
                        }
                        .accessibilityIdentifier("settings-sign-out")
                    } footer: {
                        Text("Removes your account and its notes from this device. Your notes stay on your server and your other devices.")
                    }
                    Section {
                        LabeledContent("Version", value: Self.version)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Sign In Again", isPresented: $askSignInPassword) {
                SecureField("Password", text: $password)
                Button("Cancel", role: .cancel) {}
                Button("Sign In") { signIn() }
            } message: {
                Text("Enter the account’s current password.")
            }
            .alert("Turn On \(app.biometry.name)", isPresented: $askBiometricsPassword) {
                SecureField("Password", text: $password)
                    .accessibilityIdentifier("settings-biometrics-password")
                Button("Cancel", role: .cancel) {}
                Button("Turn On") { turnOnBiometrics() }
            } message: {
                Text("Enter your password to let \(app.biometry.name) unlock TwoNote on this device.")
            }
            .alert(failure?.title ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure?.detail ?? "")
            }
            .confirmationDialog("Sign out of TwoNote on this device?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) {
                    dismiss()
                    Task { await app.removeAccount() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your notes stay on the server and your other devices. Changes on this device that have not synced are lost. This device is removed from your account’s devices if the server is in reach. To use TwoNote here again you need your Secret Key.")
            }
        }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return "\(version) (\(build))"
    }

    // MARK: Sections

    private func accountSection(_ client: TwoNoteClient) -> some View {
        Section("Account") {
            LabeledContent("Username", value: client.account?.username ?? "")
            LabeledContent("Server", value: app.serverURL?.absoluteString ?? "")
            LabeledContent("This Device", value: client.account?.deviceName ?? "")
        }
    }

    @ViewBuilder
    private func syncSection(_ client: TwoNoteClient) -> some View {
        let status = client.syncMonitor.status
        let summary = SyncSummary(status)
        Section {
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Image(systemName: summary.symbol)
                        .imageScale(.small)
                    Text(summary.title)
                }
                .foregroundStyle(summary.wantsAttention ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            if let last = status.lastSyncedAt {
                LabeledContent("Last Synced", value: last.formatted(date: .abbreviated, time: .shortened))
            }
            if let waiting = summary.waiting {
                LabeledContent("Waiting to Sync", value: waiting)
            }
            if summary.kind == .needsSignIn {
                Button("Sign In Again…") {
                    password = ""
                    askSignInPassword = true
                }
                .disabled(working)
            } else {
                Button("Sync Now") {
                    client.sync.requestSync()
                }
            }
        } header: {
            Text("Sync")
        } footer: {
            Text(summary.kind == .problem ? [summary.explanation, status.lastError].compactMap { $0 }.joined(separator: " ") : summary.explanation)
        }
    }

    @ViewBuilder
    private var securitySection: some View {
        @Bindable var app = app
        Section {
            if app.biometry != .none || app.biometricUnlockEnabled {
                Toggle(isOn: Binding(get: { app.biometricUnlockEnabled }, set: { setBiometrics($0) })) {
                    Label("Unlock with \(app.biometry.name)", systemImage: app.biometry.symbol)
                }
                .disabled(working)
                .accessibilityIdentifier("settings-biometrics")
            }
            Picker(selection: $app.autoLock) {
                ForEach(AutoLockDelay.allCases) { delay in
                    Text(delay.title).tag(delay)
                }
            } label: {
                Label("Auto-Lock", systemImage: "lock.rotation")
            }
            .accessibilityIdentifier("settings-autolock")
            NavigationLink {
                ChangePasswordView()
            } label: {
                Label("Change Password", systemImage: "key")
            }
            .accessibilityIdentifier("settings-change-password")
            NavigationLink {
                SecretKeyView()
            } label: {
                Label("Secret Key", systemImage: "key.viewfinder")
            }
            .accessibilityIdentifier("settings-secret-key")
            Button {
                dismiss()
                Task { await app.lock() }
            } label: {
                Label("Lock TwoNote Now", systemImage: "lock")
            }
            .accessibilityIdentifier("settings-lock")
        } header: {
            Text("Security")
        } footer: {
            Text("TwoNote locks when it has been in the background for the Auto-Lock time. Locking closes your notes and removes their keys from memory.")
        }
    }

    // MARK: Actions

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
        run { try await app.setBiometricUnlock(true, password: attempt) }
    }

    private func signIn() {
        let attempt = password
        password = ""
        guard !attempt.isEmpty else { return }
        run { try await app.signInAgain(password: attempt) }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        working = true
        Task {
            do {
                try await action()
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
        List {
            if let devices {
                Section {
                    ForEach(devices) { device in
                        row(device)
                    }
                } footer: {
                    Text("Revoking a device signs it out: it can no longer sync. Notes already on it stay readable there until it is signed out or erased; to shut it out completely, also change your password.")
                }
            }
        }
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
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog(
            "Revoke “\(revoking?.name ?? "")”?",
            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
            titleVisibility: .visible,
            presenting: revoking
        ) { device in
            Button("Revoke Device", role: .destructive) { revoke(device) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It is signed out and can no longer sync until someone signs in on it again with your password.")
        }
        .alert(failure?.title ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure?.detail ?? "")
        }
    }

    @ViewBuilder
    private func row(_ device: DeviceInfo) -> some View {
        let label = VStack(alignment: .leading, spacing: 2) {
            Text(device.name.isEmpty ? "Unnamed Device" : device.name)
            Text(device.current ? "This Device" : "Last used \(Self.date(device.lastSeenAt))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        if device.current {
            label
        } else {
            label
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Revoke") { revoking = device }
                        .tint(.red)
                }
                .contextMenu {
                    Button("Revoke", systemImage: "xmark.circle", role: .destructive) { revoking = device }
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

/// Changing the account password. Needs the server.
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

    /// What is still wrong with the form, or nil when it can be sent.
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
        Form {
            Section {
                SecureField("Current Password", text: $current)
                    .textContentType(.password)
                    .focused($focus, equals: .current)
                    .submitLabel(.next)
                    .onSubmit { focus = .new }
                    .accessibilityIdentifier("password-current")
            }
            Section {
                SecureField("New Password", text: $new)
                    .textContentType(.newPassword)
                    .focused($focus, equals: .new)
                    .submitLabel(.next)
                    .onSubmit { focus = .verify }
                    .accessibilityIdentifier("password-new")
                SecureField("Verify", text: $verify)
                    .textContentType(.newPassword)
                    .focused($focus, equals: .verify)
                    .submitLabel(.done)
                    .onSubmit(submit)
                    .accessibilityIdentifier("password-verify")
            } footer: {
                if let problem, !problem.isEmpty {
                    Text(problem)
                        .foregroundStyle(.red)
                } else {
                    Text("At least \(Self.minimumLength) characters. A few unrelated words make a strong password that is easy to type.")
                }
            }
            Section {
                Button(action: submit) {
                    HStack {
                        Text("Change Password")
                        if working {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(problem != nil || working)
                .accessibilityIdentifier("password-submit")
            } footer: {
                Text("Changing the password needs your server. Your other devices are signed out and ask for the new password the next time they sync. Your Secret Key and your notes stay as they are.")
            }
        }
        .navigationTitle("Change Password")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focus = .current }
        .alert(failure?.title ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure?.detail ?? "")
        }
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

/// The Secret Key, shown only after the fingerprint or face (if that unlocks the app) or the
/// password was checked, and hidden again as soon as the screen is left.
struct SecretKeyView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    @State private var key: String?
    @State private var askPassword = false
    @State private var password = ""
    @State private var working = false
    @State private var failure: UserMessage?
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                if let key {
                    Text(key)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .accessibilityIdentifier("secret-key-text")
                    Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        // Stays on this device and leaves the pasteboard after two minutes.
                        UIPasteboard.general.setItems(
                            [[UIPasteboard.typeAutomatic: key]],
                            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
                        copied = true
                    }
                    Button("Hide", systemImage: "eye.slash") {
                        hide()
                    }
                } else {
                    Button("Show Secret Key", systemImage: "eye") {
                        reveal()
                    }
                    .disabled(working)
                    .accessibilityIdentifier("secret-key-show")
                }
            } footer: {
                Text("Your Secret Key and your password together open your notes. You need both to set up TwoNote on another device. Keep the Secret Key somewhere safe and never share it; your server does not have it and cannot restore it.")
            }
        }
        .navigationTitle("Secret Key")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear(perform: hide)
        .onChange(of: scenePhase) {
            if scenePhase == .background { hide() }
        }
        .alert("Show Secret Key", isPresented: $askPassword) {
            SecureField("Password", text: $password)
                .accessibilityIdentifier("secret-key-password")
            Button("Cancel", role: .cancel) {}
            Button("Show") { revealWithPassword() }
        } message: {
            Text("Enter your password to show the Secret Key.")
        }
        .alert(failure?.title ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure?.detail ?? "")
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
