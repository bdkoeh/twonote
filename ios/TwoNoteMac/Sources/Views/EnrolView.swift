import SwiftUI

/// First run: add this Mac to the account that already exists on the server. The same fields
/// and wording as on the iPhone, laid out as a Mac form in the middle of the window.
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
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 6) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 72, height: 72)
                        .accessibilityHidden(true)
                    Text("Set Up TwoNote")
                        .font(.title.bold())
                    Text("Sign in to the account on your TwoNote server.")
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 28)

                Form {
                    Section {
                        TextField("Server", text: $server, prompt: Text(verbatim: "http://192.168.1.20:8080"))
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                            .focused($focus, equals: .server)
                            .onSubmit { focus = .username }
                            .accessibilityIdentifier("enrol-server")
                    } header: {
                        Text("Server")
                    } footer: {
                        Text("The address of your TwoNote server on your network or over Tailscale.")
                            .foregroundStyle(.secondary)
                    }

                    Section {
                        TextField("Username", text: $username)
                            .textContentType(.username)
                            .autocorrectionDisabled()
                            .focused($focus, equals: .username)
                            .onSubmit { focus = .password }
                            .accessibilityIdentifier("enrol-username")
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .focused($focus, equals: .password)
                            .onSubmit { focus = .secretKey }
                            .accessibilityIdentifier("enrol-password")
                        TextField("Secret Key", text: $secretKey)
                            .font(.body.monospaced())
                            .autocorrectionDisabled()
                            .focused($focus, equals: .secretKey)
                            .onSubmit { focus = .deviceName }
                            .accessibilityIdentifier("enrol-secret-key")
                    } header: {
                        Text("Account")
                    } footer: {
                        Text("The Secret Key starts with T2 and is in your Emergency Kit. TwoNote on another device also shows it in Settings.")
                            .foregroundStyle(.secondary)
                    }

                    Section {
                        TextField("Device Name", text: $deviceName)
                            .focused($focus, equals: .deviceName)
                            .onSubmit(submit)
                            .accessibilityIdentifier("enrol-device-name")
                    } header: {
                        Text("This Mac")
                    } footer: {
                        Text("Shown in the list of devices that can open your notes.")
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .frame(height: 470)

                HStack {
                    if working {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Spacer()
                    Button("Sign In", action: submit)
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                        .disabled(!canSubmit)
                        .accessibilityIdentifier("enrol-submit")
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
            .frame(width: 520)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .disabled(working)
        .messageAlert($failure)
        .onAppear {
            if deviceName.isEmpty {
                deviceName = app.suggestedDeviceName
            }
            focus = .server
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
