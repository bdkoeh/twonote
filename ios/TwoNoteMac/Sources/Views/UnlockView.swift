import AppKit
import SwiftUI

/// The locked app, in the main window: nothing decrypted is in memory. Touch ID brings it back
/// if that is turned on (asked for once as soon as the window is in front); the password
/// always does. Works offline. Same wording as on the iPhone.
struct UnlockView: View {
    @Environment(AppModel.self) private var app

    @State private var password = ""
    @State private var working = false
    @State private var wrongPassword = false
    @State private var failure: UserMessage?
    @State private var keysMissing = false
    @State private var askedBiometrics = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.fill")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text("TwoNote Is Locked")
                    .font(.title2.bold())
                if let username = app.client?.account?.username {
                    Text("Enter the password for \(username).")
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 6) {
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .textContentType(.password)
                    .focused($focused)
                    .onSubmit(unlock)
                    .accessibilityIdentifier("unlock-password")

                if wrongPassword {
                    Text("Incorrect password.")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("unlock-error")
                } else if let notice = app.biometricNotice {
                    Text(notice)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("unlock-notice")
                }
            }

            VStack(spacing: 10) {
                Button(action: unlock) {
                    Group {
                        if working {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Unlock")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty || working)
                .accessibilityIdentifier("unlock-submit")

                if app.biometricUnlockEnabled {
                    Button(action: unlockWithBiometrics) {
                        Label("Unlock with \(app.biometry.name)", systemImage: app.biometry.symbol)
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .disabled(working)
                    .accessibilityIdentifier("unlock-biometrics")
                }
            }
        }
        .frame(width: 300)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            // With Touch ID on, its prompt comes first; the password field waits behind it.
            focused = true
            askBiometricsOnce()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            askBiometricsOnce()
        }
        .messageAlert($failure)
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
        guard NSApplication.shared.isActive, !askedBiometrics, app.biometricUnlockEnabled else { return }
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
                // Cancelled, not recognised, "Enter Password", or switched off (the window
                // then says why): the password field is the way in.
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
