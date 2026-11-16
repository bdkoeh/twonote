import AppKit
import Foundation
import TwoNoteCore
import WidgetKit

extension AppEnvironment {
    /// The real thing on the Mac: the sandbox container's Application Support, the
    /// data-protection Keychain (as on the iPhone), Touch ID where the Mac has it, the App Group
    /// container shared with the share extension and the widget, the standard defaults.
    @MainActor
    static func live() -> AppEnvironment {
        // Inside the sandbox this is ~/Library/Containers/<prefix>.mac/Data/Library/Application Support.
        let folder = URL.applicationSupportDirectory.appending(path: "TwoNote", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The store is useless without the Secret Key, and the Keychain items never leave this
        // Mac; a Time Machine restore elsewhere would hold an account that cannot be unlocked.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = folder
        try? url.setResourceValues(values)

        var (secrets, dataProtection) = MacSecretStore.live()
        #if DEBUG
        // For the end-to-end run of the migration: behave as a stage M1 build did (login
        // keychain only, no migration, no Touch ID).
        if ProcessInfo.processInfo.arguments.contains("-TwoNoteLoginKeychainOnly") {
            (secrets, dataProtection) = (MacSecretStore(primary: KeychainSecretStore(dataProtection: false), legacy: nil), false)
        }
        #endif
        // What a stage M1 build left in the login keychain moves over before anything reads it.
        secrets.migrate()

        let reachability = NetworkReachability.shared
        return AppEnvironment(
            defaults: .standard,
            databasePath: folder.appending(path: "store.db").path,
            secretStore: secrets,
            deviceName: Host.current().localizedName ?? "Mac",
            networkAvailable: { reachability.isSatisfied },
            // The Touch ID item is a data-protection Keychain item (Secure Enclave access
            // control); a build without that Keychain treats the Mac as one without Touch ID
            // rather than offering something that would fail. Whether the Mac has a sensor (built
            // in or a Magic Keyboard with Touch ID) is the store's own question to LocalAuthentication.
            biometrics: dataProtection ? KeychainBiometricStore() : NoBiometrics(),
            sharedContainer: .appGroup,
            reloadWidgets: { WidgetCenter.shared.reloadAllTimelines() })
    }
}
