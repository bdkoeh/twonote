import Foundation
import Security
import TwoNoteCore

/// The Secret Key and the session token on the Mac: in the data-protection Keychain, as on the
/// iPhone ("after first unlock, this device only", readable by this app's application
/// identifier alone).
///
/// Builds of stage M1 were signed without a provisioning profile, had no application identifier
/// and so kept both in the login keychain instead. `migrate()` moves what such a build left
/// there, once: each value is copied into the data-protection Keychain, read back, and only
/// then deleted from the login keychain. Until a value has been moved it is still read from
/// where it is, so a move that fails half-way (or not at all) never signs anyone out; the
/// next launch tries again.
struct MacSecretStore: SecretStore {
    /// Where the secrets are kept.
    let primary: any SecretStore
    /// Where an earlier build kept them; nil when there is nothing to move from.
    let legacy: (any SecretStore)?

    /// What the store holds.
    static let names = [SecretNames.secretKey, SecretNames.sessionToken]

    /// What a migration did, name by name.
    struct Migration: Equatable {
        /// Copied into the data-protection Keychain and removed from the login keychain.
        var moved: [String] = []
        /// Already in the data-protection Keychain; the login keychain's copy was removed.
        var discarded: [String] = []
        /// Could not be copied; left where it was, still in use, for the next launch.
        var failed: [String] = []

        var isEmpty: Bool { moved.isEmpty && discarded.isEmpty && failed.isEmpty }
    }

    func get(_ name: String) -> String? {
        primary.get(name) ?? legacy?.get(name)
    }

    func set(_ name: String, _ value: String) throws {
        try primary.set(name, value)
        // A newer value than the one an earlier build left: that one must not come back.
        legacy?.remove(name)
    }

    func remove(_ name: String) {
        primary.remove(name)
        legacy?.remove(name)
    }

    /// Moves the values an earlier build left in the login keychain. Cheap when there are none.
    @discardableResult
    func migrate() -> Migration {
        var result = Migration()
        guard let legacy else { return result }
        for name in Self.names {
            guard let old = legacy.get(name) else { continue }
            if primary.get(name) != nil {
                // Moved before (the deletion did not happen) or replaced since: the
                // data-protection Keychain has the value in use.
                legacy.remove(name)
                result.discarded.append(name)
                continue
            }
            do {
                try primary.set(name, old)
            } catch {
                result.failed.append(name)
                continue
            }
            guard primary.get(name) == old else {
                primary.remove(name)
                result.failed.append(name)
                continue
            }
            legacy.remove(name)
            result.moved.append(name)
        }
        return result
    }

    /// The real stores. The data-protection Keychain needs the application identifier that the
    /// provisioning profile grants; a build signed without one (as stage M1 was) keeps using
    /// the login keychain and has nothing to migrate.
    static func live(service: String = "TwoNote") -> (store: MacSecretStore, dataProtection: Bool) {
        let login = KeychainSecretStore(service: service, dataProtection: false)
        guard dataProtectionKeychainAvailable else {
            return (MacSecretStore(primary: login, legacy: nil), false)
        }
        return (MacSecretStore(primary: KeychainSecretStore(service: service, dataProtection: true), legacy: login), true)
    }

    /// Whether this signature may use the data-protection Keychain: a lookup of an item that
    /// does not exist says "not found" if so, errSecMissingEntitlement if not.
    static var dataProtectionKeychainAvailable: Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "TwoNote.probe",
            kSecAttrAccount as String: "probe",
            kSecUseDataProtectionKeychain as String: true,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) != errSecMissingEntitlement
    }
}
