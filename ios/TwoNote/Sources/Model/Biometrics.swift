import Foundation
import LocalAuthentication
import Security

/// The biometric sensor this device has and can use right now.
enum BiometryKind: Equatable, Sendable {
    /// No sensor, nothing enrolled, or biometrics are not allowed for this app.
    case none
    case touchID
    case faceID
    case opticID

    /// The sensor's name, the way the system spells it.
    var name: String {
        switch self {
        case .none: "Biometrics"
        case .touchID: "Touch ID"
        case .faceID: "Face ID"
        case .opticID: "Optic ID"
        }
    }

    var symbol: String {
        switch self {
        case .none: "lock"
        case .touchID: "touchid"
        case .faceID: "faceid"
        case .opticID: "opticid"
        }
    }
}

/// Why a biometric check did not produce what was asked for.
enum BiometricFailure: Error, Equatable {
    /// The user (or the system) dismissed the prompt.
    case cancelled
    /// The user chose "Enter Password" in the prompt.
    case fallback
    /// Biometrics cannot be used right now (locked out after failed attempts, switched off).
    case unavailable
    /// The stored key is gone: the fingerprints or the face enrolled on the device changed.
    case invalidated
    /// The finger or face was not recognised, or the Keychain refused for another reason.
    case failed
}

/// Where the unlock key lives while biometric unlock is on, and the biometric check itself.
///
/// What is stored is the *unlock key* of PROTOCOL.md section 1.2 - 32 bytes derived from the
/// password and the Secret Key - never the password. It opens the wrapped vault key in this
/// device's local store and nothing else: it is not sent to the server, cannot log in, and
/// stops working when the password is changed (the vault key is then wrapped under a new one).
protocol BiometricKeyStore: Sendable {
    /// The usable sensor, or `.none`.
    var biometry: BiometryKind { get }
    /// Whether a key is stored and still valid for the enrolled fingerprints or face. No prompt.
    func hasKey() -> Bool
    /// Stores the key, replacing any earlier one.
    func save(_ key: Data) throws
    /// Shows the biometric prompt and returns the key.
    /// - Throws: `BiometricFailure`.
    func read(reason: String) async throws -> Data
    /// Removes the key; does nothing if there is none.
    func remove()
    /// Shows the biometric prompt without reading anything (before showing the Secret Key).
    /// - Throws: `BiometricFailure`.
    func authenticate(reason: String) async throws
}

/// A device without biometrics. The default of an `AppEnvironment`.
struct NoBiometrics: BiometricKeyStore {
    var biometry: BiometryKind { .none }
    func hasKey() -> Bool { false }
    func save(_ key: Data) throws { throw BiometricFailure.unavailable }
    func read(reason: String) async throws -> Data { throw BiometricFailure.unavailable }
    func remove() {}
    func authenticate(reason: String) async throws { throw BiometricFailure.unavailable }
}

/// The real thing: one Keychain item that only the currently enrolled fingerprints or face can
/// release.
///
/// The item's access control is `.biometryCurrentSet` with "when unlocked, this device only":
/// - the Secure Enclave releases it only after a successful match; there is no passcode fallback;
/// - adding or removing a fingerprint (or re-enrolling Face ID) invalidates it, after which the
///   password is asked again and biometric unlock has to be turned on anew;
/// - it is never part of a backup and never leaves the device.
struct KeychainBiometricStore: BiometricKeyStore {
    private let service: String
    private let account = "biometric-unlock-key"

    init(service: String = "TwoNote") {
        self.service = service
    }

    var biometry: BiometryKind {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return .none }
        switch context.biometryType {
        case .touchID: return .touchID
        case .faceID: return .faceID
        case .opticID: return .opticID
        default: return .none
        }
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    func hasKey() -> Bool {
        // A context that may not show UI: "interaction not allowed" then means "there, behind the sensor".
        let context = LAContext()
        context.interactionNotAllowed = true
        var query = query
        query[kSecUseAuthenticationContext as String] = context
        query[kSecReturnAttributes as String] = true
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    func save(_ key: Data) throws {
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .biometryCurrentSet, nil) else {
            throw BiometricFailure.unavailable
        }
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = key
        item[kSecAttrAccessControl as String] = access
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainFailure(status: status)
        }
    }

    func read(reason: String) async throws -> Data {
        let context = LAContext()
        context.localizedFallbackTitle = "Enter Password"
        try await Self.evaluate(context, reason: reason)

        // The context that has just matched satisfies the item's access control: no second prompt.
        var query = query
        query[kSecUseAuthenticationContext as String] = context
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, !data.isEmpty else { throw BiometricFailure.invalidated }
            return data
        case errSecItemNotFound, errSecAuthFailed:
            throw BiometricFailure.invalidated
        case errSecUserCanceled:
            throw BiometricFailure.cancelled
        default:
            throw BiometricFailure.failed
        }
    }

    func remove() {
        SecItemDelete(query as CFDictionary)
    }

    func authenticate(reason: String) async throws {
        let context = LAContext()
        context.localizedFallbackTitle = "Enter Password"
        try await Self.evaluate(context, reason: reason)
    }

    private static func evaluate(_ context: LAContext, reason: String) async throws {
        do {
            _ = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .systemCancel, .appCancel:
                throw BiometricFailure.cancelled
            case .userFallback:
                throw BiometricFailure.fallback
            case .biometryNotAvailable, .biometryNotEnrolled, .biometryLockout, .passcodeNotSet:
                throw BiometricFailure.unavailable
            default:
                throw BiometricFailure.failed
            }
        } catch {
            throw BiometricFailure.failed
        }
    }
}

/// The Keychain refused to store the biometric item.
struct KeychainFailure: Error, Equatable {
    let status: Int32
}
