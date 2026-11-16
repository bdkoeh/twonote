import Foundation
import Observation
import TwoNoteCrypto
import YrsKit

/// One device's view of a TwoNote account: account flows (register, enrol, unlock, lock,
/// password change), the notebooks and pages, and the sync engine. One instance per local
/// database. Works with the server unreachable once enrolled; only register, enrol, password
/// change, sign-in, device management and deleting things for good need the network.
///
/// Main-actor object for SwiftUI: `state` and `account` are observable, the documents it hands
/// out are main-actor objects the editor uses directly. Its own heavy work (key derivation,
/// HTTP, SQLite) runs on background actors; every method that needs any is `async`.
@MainActor
@Observable
public final class TwoNoteClient {
    /// Where this device stands.
    public private(set) var state: ClientState
    /// The enrolled account, or nil.
    public private(set) var account: AccountInfo?

    /// The typed HTTP client, for calls the UI makes directly (server status).
    public let api: TwoNoteApi
    /// The sync engine. Usable while `state` is `.unlocked`.
    public let sync: SyncEngine
    /// The sync status for SwiftUI (same object as `sync.monitor`).
    public let syncMonitor: SyncMonitor

    @ObservationIgnored private let options: ClientOptions
    @ObservationIgnored private let store: LocalStore
    @ObservationIgnored private let worker: AccountWorker
    @ObservationIgnored private let accountLock = AsyncLock()
    @ObservationIgnored private var vault: Vault?
    @ObservationIgnored private var closed = false

    private init(options: ClientOptions, store: LocalStore, account: AccountRecord?) {
        self.options = options
        self.store = store
        api = TwoNoteApi(serverURL: options.serverURL, transport: options.transport, timeout: options.httpTimeout.timeInterval)
        syncMonitor = SyncMonitor()
        sync = SyncEngine(api: api, store: store, options: options, monitor: syncMonitor)
        worker = AccountWorker(api: api, store: store, secrets: options.secretStore, options: options)
        self.account = account.map(Self.info)
        state = account == nil ? .noAccount : .locked
    }

    /// Opens the local database (creating it if needed). No network access happens here.
    public static func open(_ options: ClientOptions) async throws -> TwoNoteClient {
        guard options.kdfParams.isSupported else {
            throw ClientError.invalidArgument("Unsupported KDF parameters.")
        }
        let (store, account) = try await Task.detached {
            let store = try LocalStore.open(path: options.databasePath)
            do {
                return (store, try store.account())
            } catch {
                store.close()
                throw error
            }
        }.value
        let client = TwoNoteClient(options: options, store: store, account: account)
        client.api.token = options.secretStore.get(SecretNames.sessionToken)
        return client
    }

    // MARK: Account flows

    /// Creates the account on a fresh server from this, its first, device: generates the Secret
    /// Key, account id and salt, derives the keys, creates and wraps the vault key, registers.
    /// Leaves the client unlocked and returns the Secret Key in its display form, to be shown
    /// once for the Emergency Kit (it is also kept in the secret store).
    /// - Throws: `ApiError` `registration_closed` when the server already has an account.
    public func register(username: String, password: String, deviceName: String) async throws -> String {
        let username = try Self.nonBlank(username), deviceName = try Self.nonBlank(deviceName)
        await accountLock.lock()
        defer { accountLock.unlock() }
        try require(.noAccount)
        let result = try await worker.register(username: username, password: password, deviceName: deviceName)
        try await becomeUnlocked(result.record, result.vaultKey)
        return result.secretKeyDisplay
    }

    /// Adds this device to an existing account: username, password and the Secret Key from
    /// another device or the Emergency Kit. Leaves the client unlocked; the first sync then
    /// downloads everything.
    /// - Throws: `ClientError.malformedSecretKey`; `ClientError.wrongCredentials` when the server rejected the login.
    public func enrol(username: String, password: String, secretKey: String, deviceName: String) async throws {
        let username = try Self.nonBlank(username), deviceName = try Self.nonBlank(deviceName)
        await accountLock.lock()
        defer { accountLock.unlock() }
        try require(.noAccount)
        let result = try await worker.enrol(username: username, password: password, secretKeyText: secretKey, deviceName: deviceName)
        try await becomeUnlocked(result.record, result.vaultKey)
    }

    /// Unlocks from local state only - no network: derives the keys from the password and the
    /// stored Secret Key and opens the locally stored wrapped vault key.
    /// - Throws: `ClientError.wrongCredentials` when the password is wrong (or the Secret Key in
    ///   the secret store is not this account's).
    public func unlock(password: String) async throws {
        await accountLock.lock()
        defer { accountLock.unlock() }
        try require(.locked)
        let result = try await worker.openLocal(password: password)
        api.token = options.secretStore.get(SecretNames.sessionToken)
        try await becomeUnlocked(result.record, result.vaultKey)
    }

    /// The unlock key for `password`: the key (derived from the password and the Secret Key,
    /// PROTOCOL.md section 1.2) that opens the locally stored wrapped vault key. For a caller
    /// that keeps it somewhere at least as well guarded as the password - a biometry-protected
    /// Keychain item - so that `unlock(unlockKey:)` can stand in for typing the password. It
    /// opens nothing without this device's local store, and a password change replaces it.
    /// No network.
    /// - Throws: `ClientError.wrongCredentials` when the password is wrong.
    public func unlockKey(password: String) async throws -> Data {
        await accountLock.lock()
        defer { accountLock.unlock() }
        guard state != .noAccount else { throw ClientError.wrongState(expected: .locked, actual: .noAccount) }
        return try await worker.unlockKey(password: password)
    }

    /// Unlocks with a key obtained from `unlockKey(password:)` instead of the password. Local
    /// only, and without the key derivation.
    /// - Throws: `ClientError.wrongCredentials` when the key does not open the stored vault key
    ///   any more (the password was changed since).
    public func unlock(unlockKey: Data) async throws {
        await accountLock.lock()
        defer { accountLock.unlock() }
        try require(.locked)
        let result = try await worker.openLocal(unlockKey: unlockKey)
        api.token = options.secretStore.get(SecretNames.sessionToken)
        try await becomeUnlocked(result.record, result.vaultKey)
    }

    /// Stops syncing, closes every open document and drops the keys from memory.
    public func lock() async {
        await accountLock.lock()
        defer { accountLock.unlock() }
        await lockCore()
    }

    /// Changes the password: re-wraps the vault key under keys derived from the new password and
    /// a new salt and replaces the credentials on the server (`POST /account/rekey`). The
    /// Secret Key and all data stay as they are. Every other device is signed out and must call
    /// `signInAgain(password:)` with the new password.
    /// - Throws: `ClientError.wrongCredentials` when `currentPassword` is wrong.
    public func changePassword(currentPassword: String, newPassword: String) async throws {
        await accountLock.lock()
        defer { accountLock.unlock() }
        try require(.unlocked)
        guard let vaultKey = vault?.vaultKey else { throw ClientError.locked }
        account = Self.info(try await worker.changePassword(current: currentPassword, new: newPassword, vaultKey: vaultKey))
    }

    /// Logs this already enrolled device in again, keeping its device id: needed when the server
    /// answers 401 (`SyncState.authRequired`) because the token was revoked or the password was
    /// changed on another device. Fetches the current salt and wrapped vault key, so afterwards
    /// `password` is also the one that unlocks locally. Leaves the client unlocked.
    /// - Throws: `ClientError.wrongCredentials` when the server rejected the login.
    public func signInAgain(password: String) async throws {
        await accountLock.lock()
        defer { accountLock.unlock() }
        guard state != .noAccount else { throw ClientError.wrongState(expected: .locked, actual: .noAccount) }
        let result = try await worker.signInAgain(password: password, newDeviceName: nil)
        if vault == nil {
            try await becomeUnlocked(result.record, result.vaultKey)
        } else {
            account = Self.info(result.record)
        }
        sync.requestSync() // a loop that was waiting for credentials carries on
    }

    /// Checks a password against the locally stored wrapped vault key, without the network and
    /// without changing any state. For re-asking the password before something sensitive is shown.
    public func verifyPassword(_ password: String) async throws -> Bool {
        await accountLock.lock()
        defer { accountLock.unlock() }
        guard state != .noAccount else { throw ClientError.wrongState(expected: .locked, actual: .noAccount) }
        do {
            _ = try await worker.openLocal(password: password)
            return true
        } catch ClientError.wrongCredentials {
            return false
        }
    }

    /// Renames this device. The protocol renames a device when it logs in again under its id
    /// (PROTOCOL.md section 3, "Devices"), so this needs the password and the server. The
    /// session token is replaced; everything else stays as it is.
    public func renameDevice(password: String, newName: String) async throws {
        let newName = try Self.nonBlank(newName)
        await accountLock.lock()
        defer { accountLock.unlock() }
        try require(.unlocked)
        account = Self.info(try await worker.signInAgain(password: password, newDeviceName: newName).record)
        sync.requestSync()
    }

    /// The Secret Key in its display form, for showing or printing the Emergency Kit. Requires an unlocked client.
    public func secretKeyForDisplay() throws -> String {
        try require(.unlocked)
        guard let text = options.secretStore.get(SecretNames.secretKey), let key = SecretKey.parse(text) else {
            throw ClientError.secretKeyMissing
        }
        return key.formatted()
    }

    /// `GET /devices`: the devices of the account. Needs the server.
    public func devices() async throws -> [DeviceInfo] {
        try await api.devices()
    }

    /// `DELETE /devices/{id}`: revokes a device's token. Needs the server.
    public func revokeDevice(_ deviceId: String) async throws {
        try await api.deleteDevice(deviceId)
    }

    // MARK: Notebooks and pages

    /// Ids of the notebooks usable on this device, in a stable order.
    public var notebookIds: [String] {
        vault?.notebookIds ?? []
    }

    /// Creates a notebook (works offline): a new notebook key wrapped under the vault key, and a
    /// tree document with the given title. The next sync sends both.
    public func createNotebook(title: String) async throws -> YrsNotebookTree {
        let tree = try await requireVault().createNotebook(title: title)
        sync.raiseNotebooksChanged()
        return tree
    }

    /// The tree of a notebook, loaded from the local store on first use and kept up to date by
    /// sync from then on. The same instance is returned until the client is locked.
    /// - Throws: `ClientError.unknownNotebook` when the notebook is not on this device.
    public func openNotebook(_ notebookId: String) async throws -> YrsNotebookTree {
        try await requireVault().openNotebook(notebookId)
    }

    /// Adds a page to a section of a notebook and creates its (initialised) page document. Works offline.
    /// - Parameter pageId: the id the page gets instead of a new random one (32 lowercase hex
    ///   characters, drawn at random by the caller): lets a caller that may be interrupted
    ///   between creating the page and noting that it did find the page again.
    /// - Throws: `ClientError.invalidArgument` when `pageId` is malformed or already in use in the notebook.
    public func createPage(
        notebookId: String, sectionId: String, title: String, at index: Int? = nil, pageId: String? = nil
    ) async throws -> YrsPageDocument {
        try await requireVault().createPage(notebookId: notebookId, sectionId: sectionId, title: title, at: index, pageId: pageId)
    }

    /// The document of an existing page, loaded from the local store on first use and kept up
    /// to date by sync until `closePage`. The same instance is returned while open. A page whose
    /// content has not been synced to this device yet opens empty and fills in later.
    public func openPage(notebookId: String, pageId: String) async throws -> YrsPageDocument {
        try await requireVault().openPage(notebookId: notebookId, pageId: pageId)
    }

    /// Releases an open page document. Its content stays in the local store.
    public func closePage(_ pageId: String) {
        vault?.close(pageId)
    }

    /// Deletes a notebook with everything in it, on the server and locally. Needs the server
    /// (unless the notebook was never synced). Cannot be undone.
    public func deleteNotebook(_ notebookId: String) async throws {
        _ = try requireVault()
        try await sync.deleteNotebook(notebookId)
    }

    /// False for a notebook that was created on this device and has not reached the server yet:
    /// deleting it needs no connection. True for every other notebook.
    public func isNotebookOnServer(_ notebookId: String) async -> Bool {
        guard let vault else { return true }
        return await vault.isNotebookOnServer(notebookId)
    }

    /// The plain text of a page as it is in the local store right now, without opening the page
    /// for editing; nil when nothing is stored for it yet. For searching: the text exists in
    /// memory only, and only while the account is unlocked.
    public func pageText(notebookId: String, pageId: String) async throws -> String? {
        try await requireVault().pageText(notebookId: notebookId, pageId: pageId)
    }

    /// A stamp per locally stored document that changes whenever its stored content changes
    /// (an edit here, an update or snapshot from the server). Lets a search index re-read only
    /// what changed.
    public func documentVersions() async throws -> [String: DocumentVersion] {
        try await requireVault().documentVersions()
    }

    /// Removes the document of a page for good (`DELETE /docs`), on the server and locally.
    /// Meant for pages whose `deleted` flag has been set in the tree for a while. Needs the server.
    public func purgePage(notebookId: String, pageId: String) async throws {
        _ = try requireVault()
        try await sync.purgePage(notebookId: notebookId, pageId: pageId)
    }

    // MARK: Secrets of this device

    /// Seals a secret that stays on this device under the vault key, so that it can only be
    /// read while the account is unlocked. Not part of the protocol: the result is for the
    /// caller to keep on this device and is never sent anywhere. `label` names the secret and
    /// must be given again to open it. No network.
    /// - Throws: `ClientError.locked` while locked.
    public func sealForThisDevice(_ secret: SecretBytes, label: String) throws -> Data {
        guard let vaultKey = vault?.vaultKey else { throw ClientError.locked }
        return try SealedBlob.sealLocal(key: vaultKey, label: label, secret: secret)
    }

    /// Opens what `sealForThisDevice` made.
    /// - Throws: `ClientError.locked` while locked; `SealedBlobError` when the blob was not
    ///   sealed under this account's vault key and this label, or is damaged.
    public func openForThisDevice(_ blob: Data, label: String) throws -> SecretBytes {
        guard let vaultKey = vault?.vaultKey else { throw ClientError.locked }
        return try SealedBlob.openLocal(key: vaultKey, label: label, blob: blob)
    }

    /// Returns once every edit made so far is in the local outbox (SQLite). An edit is sealed and
    /// written a few milliseconds after the editing call returns; call this before the process
    /// may be suspended or killed (the app going to the background). No network. Does nothing
    /// while locked.
    public func flushPendingEdits() async {
        await vault?.flush()
    }

    /// Locks the client and closes the local database. The instance is unusable afterwards.
    public func close() async {
        guard !closed else { return }
        await accountLock.lock()
        defer { accountLock.unlock() }
        closed = true
        await lockCore()
        store.close()
    }

    // MARK: Internals

    private static func info(_ record: AccountRecord) -> AccountInfo {
        AccountInfo(username: record.username, accountId: record.accountId, deviceId: record.deviceId, deviceName: record.deviceName)
    }

    private static func nonBlank(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ClientError.invalidArgument("A name must not be blank.") }
        return trimmed
    }

    private func becomeUnlocked(_ record: AccountRecord, _ vaultKey: SecretBytes) async throws {
        let vault = Vault(
            store: store, vaultKey: vaultKey, undoCaptureMilliseconds: options.undoCaptureMilliseconds,
            report: { [sync] in sync.report($0) },
            localChange: { [sync] in sync.notifyLocalChange() })
        try await vault.loadStoredKeys()
        await sync.attach(vault, deviceId: record.deviceId)
        self.vault = vault
        account = Self.info(record)
        state = .unlocked
    }

    private func lockCore() async {
        guard let vault else { return }
        await sync.detach()
        await vault.shutdown()
        self.vault = nil
        state = account == nil ? .noAccount : .locked
    }

    private func requireVault() throws -> Vault {
        guard let vault else { throw ClientError.locked }
        return vault
    }

    private func require(_ expected: ClientState) throws {
        guard !closed, state == expected else {
            throw ClientError.wrongState(expected: expected, actual: state)
        }
    }
}

/// The account flows off the main actor: Argon2 (about 0.1 s and 64 MiB), the login exchange,
/// the secret store and the account row of the local store.
actor AccountWorker {
    struct Unlocked: Sendable {
        var record: AccountRecord
        var vaultKey: SecretBytes
        var secretKeyDisplay = ""
    }

    private let api: TwoNoteApi
    private let store: LocalStore
    private let secrets: any SecretStore
    private let options: ClientOptions

    init(api: TwoNoteApi, store: LocalStore, secrets: any SecretStore, options: ClientOptions) {
        self.api = api
        self.store = store
        self.secrets = secrets
        self.options = options
    }

    func register(username: String, password: String, deviceName: String) async throws -> Unlocked {
        let secretKey = SecretKey.generate()
        let accountId = WireEncoding.newId()
        let accountHex = try WireEncoding.hexString(id: accountId)
        let salt = KeyDerivation.newSalt()
        let keys = try KeyDerivation.derive(
            password: password, secretKey: secretKey, accountId: accountId, kdfSalt: salt, kdfParams: options.kdfParams)
        let vaultKey = KeyHierarchy.createVaultKey()
        let wrapped = try KeyHierarchy.wrapVaultKey(unlockKey: keys.unlockKey, accountId: accountId, vaultKey: vaultKey)
        let display = secretKey.formatted()

        // The Secret Key is stored before the server learns of the account: once the
        // registration exists, losing the key would lose the account.
        try secrets.set(SecretNames.secretKey, display)
        let session: DeviceSession
        do {
            session = try await api.register(RegisterRequest(
                username: username, accountId: accountHex, kdfSalt: salt, kdfParams: options.kdfParams,
                authPublicKey: keys.authPublicKey, wrappedVaultKey: wrapped, deviceName: deviceName))
        } catch let error as ApiError {
            secrets.remove(SecretNames.secretKey) // the server refused: no account uses this key
            throw error
        }

        try secrets.set(SecretNames.sessionToken, session.token)
        api.token = session.token
        let record = AccountRecord(
            username: username, accountId: accountHex, deviceId: session.deviceId, deviceName: deviceName, kdfSalt: salt,
            kdfParams: options.kdfParams, wrappedVaultKey: wrapped)
        try store.saveAccount(record)
        return Unlocked(record: record, vaultKey: vaultKey, secretKeyDisplay: display)
    }

    func enrol(username: String, password: String, secretKeyText: String, deviceName: String) async throws -> Unlocked {
        guard let secretKey = SecretKey.parse(secretKeyText) else { throw ClientError.malformedSecretKey }
        let (challenge, result, vaultKey) = try await login(
            username: username, password: password, secretKey: secretKey, deviceName: deviceName, deviceId: nil)
        try secrets.set(SecretNames.secretKey, secretKey.formatted())
        try secrets.set(SecretNames.sessionToken, result.token)
        api.token = result.token
        let record = AccountRecord(
            username: username, accountId: challenge.accountId, deviceId: result.deviceId, deviceName: deviceName,
            kdfSalt: challenge.kdfSalt, kdfParams: challenge.kdfParams, wrappedVaultKey: result.wrappedVaultKey)
        try store.saveAccount(record)
        return Unlocked(record: record, vaultKey: vaultKey)
    }

    /// Derives the keys from the password and opens the locally stored wrapped vault key. No network.
    func openLocal(password: String) throws -> Unlocked {
        let record = try requireAccount()
        return Unlocked(record: record, vaultKey: try openLocalVaultKey(record, password: password))
    }

    /// Derives the unlock key from the password and checks that it opens the stored vault key.
    func unlockKey(password: String) throws -> Data {
        let record = try requireAccount()
        let secretKey = try loadSecretKey()
        guard let accountId = WireEncoding.id(hex: record.accountId) else { throw ClientError.invalidArgument("Bad account id.") }
        let keys = try KeyDerivation.derive(
            password: password, secretKey: secretKey, accountId: accountId, kdfSalt: record.kdfSalt, kdfParams: record.kdfParams)
        guard (try? KeyHierarchy.unwrapVaultKey(
            unlockKey: keys.unlockKey, accountId: accountId, wrappedVaultKey: record.wrappedVaultKey)) != nil else {
            throw ClientError.wrongCredentials
        }
        return keys.unlockKey.withUnsafeBytes { Data($0) }
    }

    /// Opens the locally stored wrapped vault key with an unlock key. No key derivation, no network.
    func openLocal(unlockKey: Data) throws -> Unlocked {
        let record = try requireAccount()
        guard let accountId = WireEncoding.id(hex: record.accountId) else { throw ClientError.invalidArgument("Bad account id.") }
        guard unlockKey.count == 32, let vaultKey = try? KeyHierarchy.unwrapVaultKey(
            unlockKey: SecretBytes(copying: unlockKey), accountId: accountId, wrappedVaultKey: record.wrappedVaultKey) else {
            throw ClientError.wrongCredentials
        }
        return Unlocked(record: record, vaultKey: vaultKey)
    }

    func changePassword(current: String, new: String, vaultKey: SecretBytes) async throws -> AccountRecord {
        var record = try requireAccount()
        _ = try openLocalVaultKey(record, password: current) // opening it proves the caller knows the current password
        let secretKey = try loadSecretKey()
        guard let accountId = WireEncoding.id(hex: record.accountId) else { throw ClientError.invalidArgument("Bad account id.") }
        let salt = KeyDerivation.newSalt()
        let keys = try KeyDerivation.derive(
            password: new, secretKey: secretKey, accountId: accountId, kdfSalt: salt, kdfParams: options.kdfParams)
        let wrapped = try KeyHierarchy.wrapVaultKey(unlockKey: keys.unlockKey, accountId: accountId, vaultKey: vaultKey)
        try await api.rekey(RekeyRequest(kdfSalt: salt, kdfParams: options.kdfParams, authPublicKey: keys.authPublicKey, wrappedVaultKey: wrapped))
        record.kdfSalt = salt
        record.kdfParams = options.kdfParams
        record.wrappedVaultKey = wrapped
        try store.saveAccount(record)
        return record
    }

    /// Logs the enrolled device in again under its id, optionally renaming it.
    func signInAgain(password: String, newDeviceName: String?) async throws -> Unlocked {
        var record = try requireAccount()
        let secretKey = try loadSecretKey()
        let name = newDeviceName ?? record.deviceName
        let (challenge, result, vaultKey) = try await login(
            username: record.username, password: password, secretKey: secretKey, deviceName: name, deviceId: record.deviceId)
        guard challenge.accountId == record.accountId, result.deviceId == record.deviceId else {
            throw ProtocolViolationError("The server answered for a different account or device.")
        }
        try secrets.set(SecretNames.sessionToken, result.token)
        api.token = result.token
        record.deviceName = name
        record.kdfSalt = challenge.kdfSalt
        record.kdfParams = challenge.kdfParams
        record.wrappedVaultKey = result.wrappedVaultKey
        try store.saveAccount(record)
        return Unlocked(record: record, vaultKey: vaultKey)
    }

    private func requireAccount() throws -> AccountRecord {
        guard let record = try store.account() else {
            throw ClientError.wrongState(expected: .locked, actual: .noAccount)
        }
        return record
    }

    private func loadSecretKey() throws -> SecretKey {
        guard let text = secrets.get(SecretNames.secretKey), let key = SecretKey.parse(text) else {
            throw ClientError.secretKeyMissing
        }
        return key
    }

    private func openLocalVaultKey(_ record: AccountRecord, password: String) throws -> SecretBytes {
        let secretKey = try loadSecretKey()
        guard let accountId = WireEncoding.id(hex: record.accountId) else { throw ClientError.invalidArgument("Bad account id.") }
        let keys = try KeyDerivation.derive(
            password: password, secretKey: secretKey, accountId: accountId, kdfSalt: record.kdfSalt, kdfParams: record.kdfParams)
        guard let vaultKey = try? KeyHierarchy.unwrapVaultKey(
            unlockKey: keys.unlockKey, accountId: accountId, wrappedVaultKey: record.wrappedVaultKey) else {
            throw ClientError.wrongCredentials
        }
        return vaultKey
    }

    /// auth/start, derive, sign, auth/finish, unwrap (PROTOCOL.md section 3 and 1.2-1.4).
    private func login(
        username: String, password: String, secretKey: SecretKey, deviceName: String, deviceId: String?
    ) async throws -> (AuthChallenge, AuthResult, SecretBytes) {
        let challenge = try await api.authStart(username: username)

        // The server chooses these; refuse anything that would make this device do unbounded work.
        guard challenge.kdfParams.isSupported,
              let accountId = WireEncoding.id(hex: challenge.accountId),
              challenge.kdfSalt.count == KeyDerivation.saltLength,
              challenge.nonce.count == LoginSignature.nonceLength,
              WireEncoding.id(hex: challenge.challengeId) != nil else {
            throw ProtocolViolationError("The server sent a login challenge this client refuses to use.")
        }

        let keys = try KeyDerivation.derive(
            password: password, secretKey: secretKey, accountId: accountId, kdfSalt: challenge.kdfSalt, kdfParams: challenge.kdfParams)
        let signature = try LoginSignature.sign(authPrivateKey: keys.authPrivateKey, nonce: challenge.nonce)
        let result: AuthResult
        do {
            result = try await api.authFinish(
                challengeId: challenge.challengeId, signature: signature, deviceName: deviceName, deviceId: deviceId)
        } catch let error as ApiError where error.code == ErrorCodes.badSignature {
            throw ClientError.wrongCredentials
        }

        guard WireEncoding.id(hex: result.deviceId) != nil,
              let vaultKey = try? KeyHierarchy.unwrapVaultKey(
                  unlockKey: keys.unlockKey, accountId: accountId, wrappedVaultKey: result.wrappedVaultKey) else {
            // The signature was accepted, so the credentials are right; the stored vault key is not theirs.
            throw ProtocolViolationError("The server's wrapped vault key does not open with this account's keys.")
        }
        return (challenge, result, vaultKey)
    }
}
