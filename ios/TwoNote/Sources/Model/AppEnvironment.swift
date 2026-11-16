import Foundation
import Network
import TwoNoteCore
#if os(iOS)
import UIKit
import WidgetKit
#endif

/// Everything the app model takes from its surroundings, so tests can substitute each piece.
struct AppEnvironment {
    /// Small non-secret settings: the server address and where the user last was.
    var defaults: UserDefaults
    /// Path of the local SQLite store.
    var databasePath: String
    /// Holds the Secret Key and the session token (the Keychain in the app).
    var secretStore: any SecretStore
    /// Suggested name for this device on the set-up screen.
    var deviceName: String
    /// Last word on the client options (tests inject a transport and faster timings).
    var configure: (inout ClientOptions) -> Void = { _ in }
    /// Whether the device has any usable network path right now.
    var networkAvailable: () -> Bool = { true }
    /// The biometric sensor and the Keychain item it guards.
    var biometrics: any BiometricKeyStore = NoBiometrics()
    /// A clock that keeps running while the app is suspended (auto-lock measures with it).
    var now: () -> ContinuousClock.Instant = { ContinuousClock.now }
    /// The folder the app shares with its share extension and its widget (the App Group
    /// container); nil when there is none, which turns sharing and the widget's titles off.
    var sharedContainer: SharedContainer?
    /// Tells the system that what the widget shows has changed.
    var reloadWidgets: @MainActor () -> Void = {}

    #if os(iOS)
    /// The real thing: Application Support, the Keychain, the standard defaults. (The Mac
    /// app's is in TwoNoteMac/Sources/App/MacEnvironment.swift.)
    @MainActor
    static func live() -> AppEnvironment {
        var folder = URL.applicationSupportDirectory.appending(path: "TwoNote", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The store is useless without the Secret Key, and the Keychain items never leave this
        // device; a restored backup would hold an account that cannot be unlocked.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)

        let reachability = NetworkReachability.shared
        return AppEnvironment(
            defaults: .standard,
            databasePath: folder.appending(path: "store.db").path,
            secretStore: KeychainSecretStore(),
            deviceName: UIDevice.current.name,
            networkAvailable: { reachability.isSatisfied },
            biometrics: KeychainBiometricStore(),
            sharedContainer: .appGroup,
            reloadWidgets: { WidgetCenter.shared.reloadAllTimelines() })
    }
    #endif
}

/// Whether the system currently has a usable network path. Only used to word the message when
/// set-up cannot reach the server ("you're offline" versus "nothing answered at that address").
final class NetworkReachability: @unchecked Sendable {
    static let shared = NetworkReachability()

    private let lock = NSLock()
    private var satisfied = true
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.satisfied = path.status == .satisfied
            self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "twonote.reachability", qos: .utility))
    }

    var isSatisfied: Bool {
        lock.lock()
        defer { lock.unlock() }
        return satisfied
    }
}
