import SwiftUI

/// First run: add this device to the account that already exists on the server.
struct EnrolView: View {
    @Environment(AppModel.self) private var app

    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var secretKey = ""
    @State private var deviceName = ""
    @State private var working = false
    @State private var failure: UserMessage?
    @FocusState private var focus: Field?

    private enum Field {
        case server, username, password, secretKey, deviceName
    }

    private var canSubmit: Bool {
        !working && ![server, username, secretKey, deviceName].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty } && !password.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://192.168.1.20:8080", text: $server)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .server)
                        .submitLabel(.next)
                        .onSubmit { focus = .username }
                        .accessibilityIdentifier("enrol-server")
                } header: {
                    Text("Server")
                } footer: {
                    Text("The address of your TwoNote server on your network or over Tailscale.")
                }

                Section {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                        .accessibilityIdentifier("enrol-username")
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .submitLabel(.next)
                        .onSubmit { focus = .secretKey }
                        .accessibilityIdentifier("enrol-password")
                    TextField("Secret Key", text: $secretKey)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .secretKey)
                        .submitLabel(.next)
                        .onSubmit { focus = .deviceName }
                        .accessibilityIdentifier("enrol-secret-key")
                } header: {
                    Text("Account")
                } footer: {
                    Text("The Secret Key starts with T2 and is in your Emergency Kit. TwoNote on another device also shows it in Settings.")
                }

                Section {
                    TextField("Device Name", text: $deviceName)
                        .focused($focus, equals: .deviceName)
                        .submitLabel(.done)
                        .accessibilityIdentifier("enrol-device-name")
                } header: {
                    Text("This Device")
                } footer: {
                    Text("Shown in the list of devices that can open your notes.")
                }
            }
            .navigationTitle("Set Up TwoNote")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Sign In", action: submit)
                            .disabled(!canSubmit)
                            .accessibilityIdentifier("enrol-submit")
                    }
                }
            }
            .disabled(working)
            .alert(failure?.title ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure?.detail ?? "")
            }
        }
        .onAppear {
            if deviceName.isEmpty {
                deviceName = app.suggestedDeviceName
            }
        }
    }

    private func submit() {
        guard canSubmit else { return }
        focus = nil
        working = true
        Task {
            do {
                try await app.enrol(server: server, username: username, password: password, secretKey: secretKey, deviceName: deviceName)
            } catch let message as UserMessage {
                failure = message
            } catch {
                failure = .generic(error)
            }
            working = false
        }
    }
}
