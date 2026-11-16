import Foundation
import TwoNoteCrypto
#if canImport(Security)
import Security
#endif

/// Where the two device secrets live: the Secret Key (display form) and the session token.
/// The app backs this with the Keychain; tests use `InMemorySecretStore`. Nothing handed to
/// this protocol is ever written to the local database or to a log.
public protocol SecretStore: Sendable {
    /// Returns the stored value, or nil.
    func get(_ name: String) -> String?
    /// Stores or replaces a value.
    func set(_ name: String, _ value: String) throws
    /// Removes a value; does nothing if it is not there.
    func remove(_ name: String)
}

/// The names `TwoNoteClient` uses in its `SecretStore`.
public enum SecretNames {
    /// The Secret Key in its display form (`T2-…`).
    public static let secretKey = "secret-key"
    /// The session token issued by the server for this device.
    public static let sessionToken = "session-token"
}

/// A `SecretStore` that forgets everything when the process ends.
public final class InMemorySecretStore: SecretStore {
    private let values = Locked<[String: String]>([:])

    public init() {}

    public func get(_ name: String) -> String? {
        values.withLock { $0[name] }
    }

    public func set(_ name: String, _ value: String) {
        values.withLock { $0[name] = value }
    }

    public func remove(_ name: String) {
        values.withLock { $0[name] = nil }
    }
}

#if canImport(Security)
/// The Keychain could not store a secret.
public struct KeychainError: Error, Equatable, Sendable {
    public let status: Int32
}

/// A `SecretStore` on the Keychain: generic-password items under one service name, readable
/// after the first unlock and never leaving this device (no iCloud Keychain, no backups).
///
/// NOT covered by the package tests: on the build host the data-protection keychain needs an
/// entitled, signed app. It is to be verified inside the iOS app.
public struct KeychainSecretStore: SecretStore {
    private let service: String
    private let dataProtection: Bool

    /// `dataProtection`: the data-protection keychain (iOS, and a Mac app signed with a
    /// provisioning profile). False uses the Mac's file-based login keychain instead, which a
    /// sandboxed app can use without a profile; its items are readable by this app's signature
    /// only, and the login keychain is locked whenever the user is logged out.
    public init(service: String = "TwoNote", dataProtection: Bool = true) {
        self.service = service
        self.dataProtection = dataProtection
    }

    private func query(_ name: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecUseDataProtectionKeychain as String: dataProtection,
        ]
        return query
    }

    public func get(_ name: String) -> String? {
        var query = query(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func set(_ name: String, _ value: String) throws {
        let data = Data(value.utf8)
        var status = SecItemUpdate(query(name) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(name)
            item[kSecValueData as String] = data
            if dataProtection {
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
    }

    public func remove(_ name: String) {
        SecItemDelete(query(name) as CFDictionary)
    }
}
#endif

/// Everything a `TwoNoteClient` needs to know about its surroundings.
public struct ClientOptions: Sendable {
    /// The server, e.g. `http://nas.local:8080`.
    public var serverURL: URL
    /// Path of this device's SQLite file. Created on first use.
    public var databasePath: String
    /// Holds the Secret Key and the session token.
    public var secretStore: any SecretStore

    /// HTTP transport override (tests).
    public var transport: (any HTTPTransport)?
    /// WebSocket transport override (tests).
    public var webSocketConnector: (any WebSocketConnector)?
    /// KDF parameters for a new account or a password change.
    public var kdfParams: KdfParams = .default
    /// A document is snapshotted once it has more than this many acknowledged updates (PROTOCOL.md section 4 step 4).
    public var compactionThreshold = 200
    /// How often the background loop syncs when nothing wakes it earlier.
    public var pollInterval: Duration = .seconds(60)
    /// How long the background loop waits after a local edit before pushing, so a burst of typing travels together.
    public var pushDebounce: Duration = .milliseconds(300)
    /// First retry delay after a failed sync; doubles up to `maxRetryDelay` (or `maxOfflineRetryDelay`).
    public var initialRetryDelay: Duration = .seconds(1)
    /// Longest delay between retries after an error answer from the server.
    public var maxRetryDelay: Duration = .seconds(30)
    /// Longest delay between attempts while the server is unreachable, for sync and for the
    /// WebSocket. Being away from the server is the normal state of a phone, so this is slower
    /// than `maxRetryDelay`; a network change or `SyncEngine.requestSync()` retries at once.
    public var maxOfflineRetryDelay: Duration = .seconds(60)
    /// Per-request HTTP timeout.
    public var httpTimeout: Duration = .seconds(30)
    /// Events requested per page (server maximum 2000).
    public var eventsPageSize = 500
    /// Most updates sent in one push (server maximum 1000).
    public var pushBatchSize = 200
    /// False disables the WebSocket; the loop then relies on `pollInterval`.
    public var useWebSocket = true
    /// True wakes the loop when the system reports that a network path became usable (joining
    /// the home Wi-Fi, Tailscale coming up).
    public var wakeOnNetworkChange = true
    /// Edits to a page closer together than this merge into one undo step.
    public var undoCaptureMilliseconds = 500

    public init(serverURL: URL, databasePath: String, secretStore: any SecretStore) {
        self.serverURL = serverURL
        self.databasePath = databasePath
        self.secretStore = secretStore
    }
}

/// Where a device stands with its account.
public enum ClientState: Equatable, Sendable {
    /// No account on this device yet: register or enrol.
    case noAccount
    /// An account is enrolled but the keys are not in memory: unlock with the password.
    case locked
    /// Notebooks can be opened, edited and synced.
    case unlocked
}

/// The non-secret identity of the enrolled account on this device.
public struct AccountInfo: Equatable, Sendable {
    public var username: String
    public var accountId: String
    public var deviceId: String
    public var deviceName: String
}

/// What the client refuses or cannot do, other than server and network failures.
public enum ClientError: Error, Equatable, Sendable {
    /// The password or the Secret Key is wrong (they cannot be told apart, by design).
    case wrongCredentials
    /// The text is not a well-formed Secret Key.
    case malformedSecretKey
    /// The account is locked.
    case locked
    /// The operation needs a different `ClientState`.
    case wrongState(expected: ClientState, actual: ClientState)
    /// The Secret Key is missing from the secret store; enrol this device again.
    case secretKeyMissing
    /// The notebook is not on this device.
    case unknownNotebook
    /// The document was closed, deleted or locked away while it was being opened.
    case documentUnavailable
    /// A caller mistake.
    case invalidArgument(String)
}
