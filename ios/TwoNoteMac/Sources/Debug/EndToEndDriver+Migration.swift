#if DEBUG
import AppKit
import Foundation
import TwoNoteCore

// The Keychain migration, end to end, with the real Keychains of this Mac and a scratch account
// on the run's own server container. Two launches of the app (tools/e2e-mac.sh migration):
//
//   1. -TwoNoteE2EMode legacy-enrol -TwoNoteLoginKeychainOnly: the app behaves as a stage M1
//      build did - secrets in the login keychain, nothing else - and signs in. It quits leaving
//      everything in place, as a user updating from M1 would.
//   2. -TwoNoteE2EMode migrate-check: an ordinary launch of this build. Its environment has
//      already moved the secrets; the account must still be there, unlock with the password,
//      and sync with the token that was moved.
//
// Nothing secret is logged: only whether items exist.
extension EndToEndDriver {
    static let migrationNotebook = "Migrated Notebook"

    private var loginKeychain: KeychainSecretStore { KeychainSecretStore(dataProtection: false) }
    private var protectedKeychain: KeychainSecretStore { KeychainSecretStore(dataProtection: true) }

    private func present(_ store: KeychainSecretStore) -> [String] {
        MacSecretStore.names.filter { store.get($0) != nil }
    }

    func legacyEnrol() async throws {
        await log("M1. as a stage M1 build: sign in with the secrets in the login keychain")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("twonote-peer-\(UUID().uuidString)")
        let peer = try await TwoNoteClient.open(ClientOptions(
            serverURL: server, databasePath: folder.appendingPathComponent("store.db").path, secretStore: InMemorySecretStore()))
        defer { try? FileManager.default.removeItem(at: folder) }
        let secretKey = try await peer.register(username: Self.username, password: Self.password, deviceName: "Desk PC")
        let notebook = try await peer.createNotebook(title: Self.migrationNotebook)
        _ = notebook.addSection(title: "Before the update")
        try await peer.sync.syncNow()
        await peer.close()

        await check(app.biometry == .none && !(app.environment.biometrics is KeychainBiometricStore), "no Touch ID store, as in M1")
        try await eventually("the set-up screen") { app.phase == .setUp }
        try await app.enrol(server: server.absoluteString, username: Self.username, password: Self.password,
                            secretKey: secretKey, deviceName: "Migration Mac")
        try await eventually("the notebook arrives", timeout: 40) {
            app.library?.notebooks.contains { $0.title == Self.migrationNotebook } == true
        }
        await check(present(loginKeychain) == MacSecretStore.names, "both secrets are in the login keychain: \(present(loginKeychain))")
        await check(present(protectedKeychain).isEmpty, "nothing in the data-protection Keychain yet: \(present(protectedKeychain))")
        await log("M1 state written: login keychain items \(present(loginKeychain))")
        await app.willResignActive()
        await app.lock()
    }

    func migrateCheck() async throws {
        await log("M2. an ordinary launch of this build: the secrets have moved and the account is still signed in")
        await check(present(loginKeychain).isEmpty, "the login keychain items are gone: \(present(loginKeychain))")
        await check(present(protectedKeychain) == MacSecretStore.names, "both are in the data-protection Keychain: \(present(protectedKeychain))")
        await check(app.environment.biometrics is KeychainBiometricStore, "the real Touch ID store is in use")
        await check(app.biometry == .none, "this Mac reports no usable Touch ID")
        try await eventually("the lock screen (not set-up)", timeout: 20) { app.phase == .locked && window != nil }
        front()
        await pump(1)
        try await fillSecure("unlock-password", Self.password, submit: true)
        try await eventually("unlocked with the password", timeout: 30) { app.phase == .unlocked }
        try await eventually("the notebook is there", timeout: 20) {
            app.library?.notebooks.contains { $0.title == Self.migrationNotebook } == true
        }
        try await eventually("synced with the moved session token", timeout: 60) {
            app.client?.sync.requestSync()
            return app.client.map { SyncSummary($0.syncMonitor.status).kind == .synced } ?? false
        }
        await check(app.client?.syncMonitor.status.state != .authRequired, "the server still accepts this Mac")
        await shot("27-after-migration")
        await check(present(loginKeychain).isEmpty, "still nothing in the login keychain")
    }
}
#endif
