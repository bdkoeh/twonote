import Foundation
import Observation
import TwoNoteCore

/// Why unlocking did not work.
enum UnlockFailure: Error, Equatable {
    case wrongPassword
    /// The Secret Key is not in the Keychain (restored backup, Keychain reset): set up again.
    case keysMissing
    /// The biometric check did not produce the key; the password still works.
    case biometry(BiometricFailure)
    case other(UserMessage)
}

/// The app's top-level state: which screen is showing and the objects behind it.
///
/// `starting` → `setUp` (no account on this device) or `locked` → `unlocked` (a `LibraryModel`
/// exists) → `locked` again on Lock. All decrypted state hangs off `library`; locking drops it.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case starting
        case setUp
        case locked
        case unlocked
        /// The local store could not be opened.
        case unavailable
    }

    private(set) var phase: Phase = .starting
    /// The sync core. Exists from the moment a server address is known.
    private(set) var client: TwoNoteClient?
    /// The notebooks and the open page. Exists only while unlocked.
    private(set) var library: LibraryModel?
    private(set) var serverURL: URL?

    /// The biometric sensor that can be used right now.
    private(set) var biometry: BiometryKind = .none
    /// Whether the fingerprint or face unlocks the app on this device.
    private(set) var biometricUnlockEnabled = false
    /// True while the question "use Touch ID from now on?" is waiting for an answer.
    var biometricOffer = false
    /// Something the unlock screen should say about biometric unlock (it was switched off).
    private(set) var biometricNotice: String?
    /// How long the app may be in the background before it locks.
    var autoLock: AutoLockDelay {
        didSet {
            environment.defaults.set(autoLock.rawValue, forKey: Keys.autoLock)
        }
    }

    /// Items from the share sheet that are waiting to become pages (they do when the app is
    /// unlocked and has a notebook to put them in).
    private(set) var waitingSharedItems = 0
    /// What a `twonote://` link asked for while the app was locked; done after the next unlock.
    private(set) var pendingLink: DeepLink?
    /// Whether the widget may show the titles of recent pages (off unless the user turns it on).
    private(set) var showsRecentPagesInWidget: Bool

    @ObservationIgnored let environment: AppEnvironment
    @ObservationIgnored private var importingShared = false
    @ObservationIgnored private var importSharedAgain = false
    @ObservationIgnored private var recentPagesTask: Task<Void, Never>?
    /// The unlock key of the password just typed, kept until the offer above is answered.
    @ObservationIgnored private var offeredUnlockKey: Data?
    @ObservationIgnored private var backgroundedAt: ContinuousClock.Instant?

    private enum Keys {
        static let server = "server.url"
        static let autoLock = "security.autoLock"
        static let biometrics = "security.biometricUnlock"
        static let biometricsOffered = "security.biometricUnlockOffered"
        static let widgetRecentPages = "widget.recentPages"
        static let all = [
            server, autoLock, biometrics, biometricsOffered, widgetRecentPages,
            ShareDestination.notebookKey, ShareDestination.sectionKey,
        ]
    }

    /// What the biometric prompt says. On the Mac it completes the system's sentence
    /// "TwoNote is trying to …".
    #if os(macOS)
    static let unlockReason = "unlock your notes"
    static let secretKeyReason = "show your Secret Key"
    #else
    static let unlockReason = "Unlock TwoNote"
    static let secretKeyReason = "Show your Secret Key"
    #endif

    init(environment: AppEnvironment) {
        self.environment = environment
        autoLock = (environment.defaults.object(forKey: Keys.autoLock) as? Int).flatMap(AutoLockDelay.init(rawValue:)) ?? .standard
        showsRecentPagesInWidget = environment.defaults.bool(forKey: Keys.widgetRecentPages)
    }

    /// Suggested device name for the set-up screen.
    var suggestedDeviceName: String { environment.deviceName }

    // MARK: Launch

    /// Opens the local store, if this device was set up before. No network.
    func start() async {
        guard phase == .starting else { return }
        if !showsRecentPagesInWidget {
            removeRecentPages() // none should be there; make sure
        }
        guard let text = environment.defaults.string(forKey: Keys.server), let url = URL(string: text) else {
            pendingLink = nil
            phase = .setUp
            return
        }
        do {
            let client = try await open(url)
            self.client = client
            serverURL = url
            refreshBiometrics()
            refreshWaitingSharedItems()
            phase = client.state == .noAccount ? .setUp : .locked
        } catch {
            phase = .unavailable
        }
        if phase != .locked {
            pendingLink = nil
        }
    }

    private func open(_ url: URL) async throws -> TwoNoteClient {
        var options = ClientOptions(serverURL: url, databasePath: environment.databasePath, secretStore: environment.secretStore)
        environment.configure(&options)
        return try await TwoNoteClient.open(options)
    }

    // MARK: Set-up

    /// Adds this device to the account. Needs the server.
    /// - Throws: `UserMessage` describing what to fix.
    func enrol(server: String, username: String, password: String, secretKey: String, deviceName: String) async throws {
        guard phase == .setUp else { return }
        guard let url = ServerAddress.parse(server) else {
            throw UserMessage(
                title: "Check the Server Address",
                detail: "Enter the address of your TwoNote server, for example http://192.168.1.20:8080.")
        }
        if let old = client {
            client = nil
            await old.close()
        }
        do {
            var client = try await open(url)
            if client.state != .noAccount {
                // A store left over from an account whose settings are gone: start clean.
                await client.close()
                Self.wipe(environment)
                client = try await open(url)
            }
            do {
                try await client.enrol(username: username, password: password, secretKey: secretKey, deviceName: deviceName)
            } catch {
                await client.close()
                throw error
            }
            environment.defaults.set(url.absoluteString, forKey: Keys.server)
            self.client = client
            serverURL = url
        } catch {
            throw UserMessage.enrolFailure(error, server: url, networkAvailable: environment.networkAvailable())
        }
        await prepareBiometricOffer(password: password)
        await becomeUnlocked()
    }

    // MARK: Unlock and lock

    /// Unlocks with the account password. Local only: works offline. The key derivation (about
    /// 0.1 s) runs on the client's background actor, not on the main thread.
    /// - Throws: `UnlockFailure`.
    func unlock(password: String) async throws {
        guard phase == .locked, let client else { return }
        do {
            try await client.unlock(password: password)
        } catch ClientError.wrongCredentials {
            throw UnlockFailure.wrongPassword
        } catch ClientError.secretKeyMissing {
            throw UnlockFailure.keysMissing
        } catch {
            throw UnlockFailure.other(.generic(error))
        }
        await prepareBiometricOffer(password: password)
        await becomeUnlocked()
    }

    /// Unlocks with the fingerprint or face: the sensor releases the unlock key from the
    /// Keychain and the key opens the local store. The password is not involved and remains
    /// the way in whenever this fails.
    /// - Throws: `UnlockFailure`.
    func unlockWithBiometrics() async throws {
        guard phase == .locked, let client, biometricUnlockEnabled else { return }
        let key: Data
        do {
            key = try await environment.biometrics.read(reason: Self.unlockReason)
        } catch BiometricFailure.invalidated {
            let name = biometry == .none ? "Biometric unlock" : biometry.name
            turnBiometricsOff(notice: "\(name) was turned off because the fingerprints or face set up on this device changed. Enter your password to unlock.", offerAgain: true)
            throw UnlockFailure.biometry(.invalidated)
        } catch let failure as BiometricFailure {
            throw UnlockFailure.biometry(failure)
        } catch {
            throw UnlockFailure.biometry(.failed)
        }
        guard phase == .locked else { return }
        do {
            try await client.unlock(unlockKey: key)
        } catch ClientError.wrongCredentials {
            // The vault key is wrapped under a newer password than the one this key came from.
            turnBiometricsOff(notice: "Your password has changed since \(biometry.name) was turned on. Enter your password to unlock.", offerAgain: true)
            throw UnlockFailure.biometry(.invalidated)
        } catch ClientError.secretKeyMissing {
            throw UnlockFailure.keysMissing
        } catch {
            throw UnlockFailure.other(.generic(error))
        }
        await becomeUnlocked()
    }

    private func becomeUnlocked() async {
        guard let client, client.state == .unlocked else { return }
        let library = LibraryModel(client: client, defaults: environment.defaults)
        await library.load() // local: the lists and the last open page are there when the screen appears
        guard client.state == .unlocked else { return }
        self.library = library
        biometricNotice = nil
        backgroundedAt = nil
        phase = .unlocked
        library.onNotebooksChanged = { [weak self] in self?.notebooksChanged() }
        if let link = pendingLink {
            pendingLink = nil
            await library.perform(link)
        }
        await importSharedItems()
        publishRecentPages()
        try? await client.sync.start()
    }

    /// Takes the content off the screen, closes every document and drops the keys from memory.
    func lock() async {
        guard phase == .unlocked, let client else { return }
        phase = .locked
        forgetBiometricOffer()
        library?.shutdown()
        library = nil
        await client.lock()
    }

    /// Logs this device in again after the server stopped accepting its token.
    /// - Throws: `UserMessage`.
    func signInAgain(password: String) async throws {
        guard let client else { return }
        do {
            try await client.signInAgain(password: password)
        } catch {
            throw UserMessage.signInFailure(error)
        }
        await renewBiometricKey(password: password)
    }

    /// Forgets the account on this device: the local store, the keys in the Keychain and the
    /// settings. Edits that have not synced are lost. The account's notes stay on the server;
    /// this device is taken off the account's device list if the server can be reached.
    func removeAccount() async {
        library?.shutdown()
        library = nil
        forgetBiometricOffer()
        if let client {
            if let deviceId = client.account?.deviceId, client.api.token != nil {
                await attempt(for: .seconds(4)) { try? await client.revokeDevice(deviceId) }
            }
            self.client = nil
            await client.close()
        }
        Self.wipe(environment)
        serverURL = nil
        waitingSharedItems = 0
        pendingLink = nil
        showsRecentPagesInWidget = false
        biometricUnlockEnabled = false
        biometricNotice = nil
        autoLock = .standard
        environment.defaults.removeObject(forKey: Keys.autoLock)
        phase = .setUp
    }

    /// Runs `work`, but does not wait longer than `limit` for it.
    private func attempt(for limit: Duration, _ work: @escaping @MainActor () async -> Void) async {
        final class Once: @unchecked Sendable {
            var continuation: CheckedContinuation<Void, Never>?
        }
        let once = Once()
        await withCheckedContinuation { continuation in
            once.continuation = continuation
            Task { @MainActor in
                await work()
                once.continuation?.resume()
                once.continuation = nil
            }
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                once.continuation?.resume()
                once.continuation = nil
            }
        }
    }

    /// Removes everything this app keeps on the device.
    static func wipe(_ environment: AppEnvironment) {
        environment.secretStore.remove(SecretNames.secretKey)
        environment.secretStore.remove(SecretNames.sessionToken)
        environment.biometrics.remove()
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: environment.databasePath + suffix)
        }
        for key in Keys.all {
            environment.defaults.removeObject(forKey: key)
        }
        LibraryModel.forgetLocation(in: environment.defaults)
        // What the extensions could see: the share inbox with its keys, and the widget's titles.
        try? FileManager.default.removeItem(at: shareKeyURL(environment))
        if let container = environment.sharedContainer {
            ShareImporter(container: container, privateKeyURL: shareKeyURL(environment), defaults: environment.defaults).removeEverything()
            _ = RecentPagesFile.remove(from: container)
            environment.reloadWidgets()
        }
    }

    // MARK: Shared items

    /// Where the share inbox's private key is kept, sealed under the vault key: next to the
    /// local store, in the app's own container.
    static func shareKeyURL(_ environment: AppEnvironment) -> URL {
        URL(fileURLWithPath: environment.databasePath).deletingLastPathComponent().appendingPathComponent("share-inbox.key")
    }

    private var importer: ShareImporter? {
        guard let container = environment.sharedContainer else { return nil }
        return ShareImporter(container: container, privateKeyURL: Self.shareKeyURL(environment), defaults: environment.defaults)
    }

    /// Counts what is waiting in the share inbox. Works while locked: it only counts files.
    func refreshWaitingSharedItems() {
        let count = importer?.inbox.waitingItems().count ?? 0
        if count != waitingSharedItems { // untouched when the same: Settings redraws on every change
            waitingSharedItems = count
        }
    }

    /// Makes pages of the items the share extension left, if the app is unlocked; says so in
    /// passing when it did. Called after unlocking, on coming to the front, and when the
    /// extension says it has left something.
    func importSharedItems() async {
        guard phase == .unlocked, let library, let importer else {
            refreshWaitingSharedItems()
            return
        }
        if importingShared {
            importSharedAgain = true
            return
        }
        importingShared = true
        defer { importingShared = false }
        var added = 0
        repeat {
            importSharedAgain = false
            let outcome = await importer.importWaiting(into: library)
            guard self.library === library else { return }
            waitingSharedItems = outcome.waiting
            added += outcome.added
            if added > 0 {
                library.notice = .init(
                    text: added == 1 ? "1 Shared Item Added" : "\(added) Shared Items Added",
                    notebookId: outcome.notebookId ?? library.notice?.notebookId,
                    sectionId: outcome.sectionId ?? library.notice?.sectionId)
            }
        } while importSharedAgain && phase == .unlocked
    }

    private func notebooksChanged() {
        guard phase == .unlocked else { return }
        if waitingSharedItems > 0, !importingShared {
            // Items that were waiting for a notebook to arrive.
            Task { await importSharedItems() }
        }
        guard showsRecentPagesInWidget else { return }
        recentPagesTask?.cancel()
        recentPagesTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.publishRecentPages()
        }
    }

    // MARK: Links

    /// A `twonote://` link (a widget button): done at once when unlocked, after the next
    /// unlock when locked, not at all on a device that is not set up.
    func open(_ link: DeepLink) async {
        switch phase {
        case .unlocked:
            await library?.perform(link)
        case .starting, .locked:
            pendingLink = link
        case .setUp, .unavailable:
            break
        }
    }

    // MARK: Widget

    /// The switch in Settings. Off: nothing from the notes is outside the encrypted store.
    /// On: the titles of the most recently edited pages are written, in the clear, where the
    /// widget can read them, and kept up to date while the app is unlocked.
    func setShowsRecentPagesInWidget(_ on: Bool) {
        showsRecentPagesInWidget = on
        environment.defaults.set(on, forKey: Keys.widgetRecentPages)
        if on {
            publishRecentPages()
        } else {
            recentPagesTask?.cancel()
            removeRecentPages()
        }
    }

    /// Brings the widget's titles up to date, if the setting is on and the app unlocked.
    func publishRecentPages() {
        guard showsRecentPagesInWidget, phase == .unlocked, let library, let container = environment.sharedContainer else { return }
        if RecentPagesFile.write(RecentPagesFile.recent(in: library.notebooks), to: container) {
            environment.reloadWidgets()
        }
    }

    private func removeRecentPages() {
        if let container = environment.sharedContainer, RecentPagesFile.remove(from: container) {
            environment.reloadWidgets()
        }
    }

    // MARK: Biometric unlock

    /// Reads what the device can do and whether the stored key is still there.
    func refreshBiometrics() {
        let store = environment.biometrics
        biometry = store.biometry
        let wanted = environment.defaults.bool(forKey: Keys.biometrics)
        if wanted && !store.hasKey() {
            // Switched on, but the key is gone: the enrolled fingerprints or face changed.
            environment.defaults.set(false, forKey: Keys.biometrics)
            environment.defaults.set(false, forKey: Keys.biometricsOffered)
            biometricUnlockEnabled = false
            if phase != .unlocked {
                biometricNotice = "Biometric unlock was turned off because the fingerprints or face set up on this device changed. Enter your password to unlock."
            }
        } else {
            biometricUnlockEnabled = wanted && biometry != .none
        }
    }

    /// After the password was typed: if the device has a sensor and the question was never
    /// answered, get the unlock key ready and ask.
    private func prepareBiometricOffer(password: String) async {
        refreshBiometrics()
        guard let client, client.state == .unlocked, biometry != .none, !biometricUnlockEnabled,
              !environment.defaults.bool(forKey: Keys.biometricsOffered) else { return }
        guard let key = try? await client.unlockKey(password: password) else { return }
        offeredUnlockKey = key
        biometricOffer = true
    }

    /// The answer to the offer. Either way it is not asked again; Settings has the switch.
    func answerBiometricOffer(enable: Bool) {
        defer { forgetBiometricOffer() }
        guard let key = offeredUnlockKey else { return }
        environment.defaults.set(true, forKey: Keys.biometricsOffered)
        guard enable else { return }
        do {
            try store(key)
        } catch {
            library?.alert = .biometricsFailure(error, biometry)
        }
    }

    private func forgetBiometricOffer() {
        offeredUnlockKey = nil
        biometricOffer = false
    }

    private func store(_ key: Data) throws {
        try environment.biometrics.save(key)
        environment.defaults.set(true, forKey: Keys.biometrics)
        environment.defaults.set(true, forKey: Keys.biometricsOffered)
        biometricUnlockEnabled = true
        biometricNotice = nil
    }

    /// - Parameter offerAgain: the user did not choose this; ask again after the next password.
    private func turnBiometricsOff(notice: String?, offerAgain: Bool = false) {
        environment.biometrics.remove()
        environment.defaults.set(false, forKey: Keys.biometrics)
        if offerAgain {
            environment.defaults.set(false, forKey: Keys.biometricsOffered)
        }
        biometricUnlockEnabled = false
        biometricNotice = notice
    }

    /// The switch in Settings. Turning it on needs the password: the key that is stored is
    /// derived from it.
    /// - Throws: `UserMessage`.
    func setBiometricUnlock(_ enabled: Bool, password: String = "") async throws {
        guard enabled else {
            turnBiometricsOff(notice: nil)
            return
        }
        guard let client, phase == .unlocked else { return }
        refreshBiometrics()
        do {
            guard biometry != .none else { throw BiometricFailure.unavailable }
            try store(try await client.unlockKey(password: password))
        } catch {
            throw UserMessage.biometricsFailure(error, biometry)
        }
    }

    /// The password changed: the stored key no longer opens anything. Store the new one.
    private func renewBiometricKey(password: String) async {
        guard biometricUnlockEnabled, let client else { return }
        do {
            try store(try await client.unlockKey(password: password))
        } catch {
            turnBiometricsOff(notice: nil)
        }
    }

    // MARK: Settings

    /// The devices of the account, this one first, then the most recently used. Needs the server.
    /// - Throws: `UserMessage`.
    func devices() async throws -> [DeviceInfo] {
        guard let client else { return [] }
        do {
            return try await client.devices().sorted {
                $0.current != $1.current ? $0.current : $0.lastSeenAt > $1.lastSeenAt
            }
        } catch {
            throw UserMessage.serverActionFailure(error, action: "Showing your devices")
        }
    }

    /// Signs another device out: the server stops accepting its token. Needs the server.
    /// - Throws: `UserMessage`.
    func revokeDevice(_ deviceId: String) async throws {
        guard let client else { return }
        do {
            try await client.revokeDevice(deviceId)
        } catch {
            throw UserMessage.serverActionFailure(error, action: "Revoking a device")
        }
    }

    /// Changes the account password. Needs the server; every other device has to sign in again.
    /// - Throws: `UserMessage`.
    func changePassword(current: String, new: String) async throws {
        guard let client, phase == .unlocked else { return }
        do {
            try await client.changePassword(currentPassword: current, newPassword: new)
        } catch ClientError.wrongCredentials {
            throw UserMessage(title: "Incorrect Password", detail: "That is not your current password.")
        } catch {
            throw UserMessage.serverActionFailure(error, action: "Changing the password")
        }
        await renewBiometricKey(password: new)
    }

    /// The Secret Key for display, after the password was checked.
    /// - Throws: `UserMessage`.
    func secretKey(password: String) async throws -> String {
        guard let client, phase == .unlocked else { throw UserMessage.generic(ClientError.locked) }
        guard (try? await client.verifyPassword(password)) == true else {
            throw UserMessage(title: "Incorrect Password", detail: "That is not your password.")
        }
        return try secretKeyForDisplay(client)
    }

    /// The Secret Key for display, after the fingerprint or face was checked. Only offered
    /// while biometric unlock is on.
    /// - Throws: `BiometricFailure` when the check did not pass; `UserMessage` otherwise.
    func secretKeyAfterBiometricCheck() async throws -> String {
        guard let client, phase == .unlocked, biometricUnlockEnabled else { throw BiometricFailure.unavailable }
        try await environment.biometrics.authenticate(reason: Self.secretKeyReason)
        guard phase == .unlocked else { throw BiometricFailure.cancelled }
        return try secretKeyForDisplay(client)
    }

    private func secretKeyForDisplay(_ client: TwoNoteClient) throws -> String {
        do {
            return try client.secretKeyForDisplay()
        } catch {
            throw UserMessage(
                title: "Secret Key Not Found",
                detail: "This device’s Secret Key is no longer in the Keychain. Look for it in your Emergency Kit or on another device.")
        }
    }

    // MARK: App life cycle

    /// The app is no longer in front (app switcher, a call, the device folding mid-gesture):
    /// everything typed so far goes to the local store now.
    func willResignActive() async {
        guard phase == .unlocked, let client else { return }
        library?.flush()
        await client.flushPendingEdits()
    }

    /// The app went to the background and may be suspended at any moment: save, then give the
    /// sync loop a few seconds to send what is waiting. Returns when that is done or given up.
    /// With auto-lock set to Immediately the app then locks.
    func didEnterBackground(waitForSync: Duration = .seconds(8)) async {
        guard phase == .unlocked, let client else {
            pendingLink = nil // a link was followed, but the app was left without unlocking
            return
        }
        let entered = environment.now()
        backgroundedAt = entered
        library?.flush()
        await client.flushPendingEdits()
        client.sync.requestSync()
        let deadline = ContinuousClock.now + waitForSync
        while ContinuousClock.now < deadline {
            let status = client.sync.status
            if status.pendingUpdates == 0 && status.state != .syncing { break }
            if status.state == .offline || status.state == .authRequired { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if autoLock == .immediately, backgroundedAt == entered {
            await lock()
        }
    }

    /// On the way back to the front, before anything is shown: lock if the app was away for
    /// longer than the auto-lock time.
    func willEnterForeground() async {
        guard phase == .unlocked, let since = backgroundedAt else { return }
        if autoLock.shouldLock(after: environment.now() - since) {
            await lock()
        }
    }

    /// Back in front: lock if it is time, otherwise look for news at once instead of waiting
    /// for the next poll.
    func didBecomeActive() async {
        await willEnterForeground()
        backgroundedAt = nil
        refreshBiometrics()
        guard phase == .unlocked else {
            refreshWaitingSharedItems()
            return
        }
        client?.sync.requestSync()
        await importSharedItems()
    }
}
