import SwiftUI

/// The locked app: nothing decrypted is in memory. The fingerprint or face brings it back if
/// that is turned on (asked for as soon as the screen appears); the password always does.
/// Works offline.
struct UnlockView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    @State private var password = ""
    @State private var working = false
    @State private var wrongPassword = false
    @State private var failure: UserMessage?
    @State private var keysMissing = false
    @State private var askedBiometrics = false
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                    .padding(.top, 48)
                    .accessibilityHidden(true)

                VStack(spacing: 4) {
                    Text("TwoNote Is Locked")
                        .font(.title2.bold())
                    if let username = app.client?.account?.username {
                        Text("Enter the password for \(username).")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 8) {
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .focused($focused)
                        .onSubmit(unlock)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
                        .accessibilityIdentifier("unlock-password")

                    if wrongPassword {
                        Text("Incorrect password.")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("unlock-error")
                    } else if let notice = app.biometricNotice {
                        Text(notice)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("unlock-notice")
                    }
                }

                VStack(spacing: 12) {
                    Button(action: unlock) {
                        Group {
                            if working {
                                ProgressView()
                            } else {
                                Text("Unlock")
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(password.isEmpty || working)
                    .accessibilityIdentifier("unlock-submit")

                    if app.biometricUnlockEnabled {
                        Button(action: unlockWithBiometrics) {
                            Label("Unlock with \(app.biometry.name)", systemImage: app.biometry.symbol)
                                .frame(maxWidth: .infinity, minHeight: 28)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(working)
                        .accessibilityIdentifier("unlock-biometrics")
                    }
                }
            }
            .frame(maxWidth: 360)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color(.systemBackground))
        .onAppear {
            // With biometrics on, the sensor's prompt comes first; the keyboard would only be in its way.
            if !app.biometricUnlockEnabled {
                focused = true
            }
            askBiometricsOnce()
        }
        .onChange(of: scenePhase) {
            askBiometricsOnce()
        }
        .alert(failure?.title ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure?.detail ?? "")
        }
        .alert("Set Up This Device Again", isPresented: $keysMissing) {
            Button("Set Up Again", role: .destructive) {
                Task { await app.removeAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This device’s keys are no longer in the Keychain, so the notes stored here can’t be opened. Setting up again downloads your notes from the server; changes that never synced from this device are lost.")
        }
    }

    /// The prompt appears by itself once per lock, when the app is in front. After that the
    /// button asks again; a prompt that keeps coming back would be in the way of the password.
    private func askBiometricsOnce() {
        guard scenePhase == .active, !askedBiometrics, app.biometricUnlockEnabled else { return }
        askedBiometrics = true
        unlockWithBiometrics()
    }

    private func unlockWithBiometrics() {
        guard !working else { return }
        working = true
        wrongPassword = false
        Task {
            do {
                try await app.unlockWithBiometrics()
            } catch UnlockFailure.keysMissing {
                keysMissing = true
            } catch UnlockFailure.other(let message) {
                failure = message
            } catch {
                // Cancelled, not recognised, "Enter Password", or switched off (the screen then
                // says why): the password field is the way in.
                focused = true
            }
            working = false
        }
    }

    private func unlock() {
        guard !password.isEmpty, !working else { return }
        working = true
        wrongPassword = false
        let attempt = password
        Task {
            do {
                try await app.unlock(password: attempt)
            } catch UnlockFailure.wrongPassword {
                wrongPassword = true
                password = ""
                focused = true
            } catch UnlockFailure.keysMissing {
                keysMissing = true
            } catch UnlockFailure.other(let message) {
                failure = message
            } catch {
                failure = .generic(error)
            }
            working = false
        }
    }
}
