import Foundation
import SwiftUI
import Testing
import UIKit
import YrsKit
@testable import TwoNote
@testable import TwoNoteCore

// The app's models against the in-memory protocol server of the sync core's tests
// (FakeServer.swift and Harness.swift are compiled into this bundle from ../TwoNoteCore/Tests).

let fakeServerAddress = "fake.test:8080"

/// One installation of the app: its settings, store, secrets and connection. Making a second
/// `AppModel` from the same installation is an app relaunch.
@MainActor
final class Installation {
    let server: FakeServer
    let transport: FakeTransport
    let secrets = InMemorySecretStore()
    let defaults: UserDefaults
    let databasePath = temporaryDatabasePath()
    var networkAvailable = true
    /// The device's sensor and its Keychain item; survives relaunches like the secrets do.
    let biometrics = FakeBiometricStore()
    /// How far the fake clock is ahead of the real one.
    var clockOffset: Duration = .zero
    /// Stands in for the App Group container the app shares with its extensions.
    let shared = SharedContainer(root: FileManager.default.temporaryDirectory.appendingPathComponent("twonote-group-\(UUID().uuidString)"))
    /// How often the app told the system to redraw the widget.
    var widgetReloads = 0

    init(_ server: FakeServer, name: String = "Phone") {
        self.server = server
        transport = FakeTransport(server: server, name: name)
        defaults = UserDefaults(suiteName: "twonote-tests-\(UUID().uuidString)")!
    }

    var environment: AppEnvironment {
        let transport = transport
        var environment = AppEnvironment(defaults: defaults, databasePath: databasePath, secretStore: secrets, deviceName: "Test Phone")
        environment.configure = { options in
            options.transport = transport
            options.webSocketConnector = transport
            options.kdfParams = fastKdf
            options.useWebSocket = false
            options.wakeOnNetworkChange = false
            options.pollInterval = .milliseconds(60)
            options.pushDebounce = .milliseconds(20)
            options.initialRetryDelay = .milliseconds(40)
            options.maxRetryDelay = .milliseconds(200)
            options.maxOfflineRetryDelay = .milliseconds(200)
        }
        environment.networkAvailable = { [unowned self] in self.networkAvailable }
        environment.biometrics = biometrics
        environment.now = { [unowned self] in ContinuousClock.now + self.clockOffset }
        environment.sharedContainer = shared
        environment.reloadWidgets = { [unowned self] in self.widgetReloads += 1 }
        return environment
    }

    /// Launches the app.
    func launch() async -> AppModel {
        let app = AppModel(environment: environment)
        await app.start()
        return app
    }

    /// Launches the app and signs in to the seeded account; returns once the seeded notebook is there.
    func launchEnrolled(_ seed: Seed) async throws -> (AppModel, LibraryModel) {
        let app = await launch()
        try await app.enrol(
            server: fakeServerAddress, username: testUsername, password: testPassword, secretKey: seed.secretKey, deviceName: "Phone")
        let library = try #require(app.library)
        try await eventually("the seeded notebook arrives") {
            library.notebook(seed.notebookId)?.page(seed.pageId) != nil
        }
        return (app, library)
    }
}

/// A sensor that matches or not as told, and a Keychain item that can be invalidated.
final class FakeBiometricStore: BiometricKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var _biometry = BiometryKind.none
    private var _stored: Data?
    private var _outcome: BiometricFailure?
    private var _prompts = 0

    /// The sensor the device has (`.none`: no sensor, or nothing enrolled).
    var biometry: BiometryKind {
        get { lock.withLock { _biometry } }
        set { lock.withLock { _biometry = newValue } }
    }

    /// What the Keychain item holds.
    var stored: Data? { lock.withLock { _stored } }

    /// What the next prompts end with: nil is a match.
    var outcome: BiometricFailure? {
        get { lock.withLock { _outcome } }
        set { lock.withLock { _outcome = newValue } }
    }

    /// How many prompts were shown.
    var prompts: Int { lock.withLock { _prompts } }

    /// A fingerprint was added or removed: the system throws the item away.
    func changeEnrolledFingerprints() {
        lock.withLock { _stored = nil }
    }

    func hasKey() -> Bool { stored != nil }

    func save(_ key: Data) throws {
        guard biometry != .none else { throw BiometricFailure.unavailable }
        lock.withLock { _stored = key }
    }

    func read(reason: String) async throws -> Data {
        try await authenticate(reason: reason)
        guard let stored else { throw BiometricFailure.invalidated }
        return stored
    }

    func remove() {
        lock.withLock { _stored = nil }
    }

    func authenticate(reason: String) async throws {
        lock.withLock { _prompts += 1 }
        guard biometry != .none else { throw BiometricFailure.unavailable }
        if let outcome { throw outcome }
    }
}

extension LibraryModel {
    /// Selects a page and waits until its editor is up.
    func open(_ ref: PageRef) async throws -> EditorSession {
        select(ref)
        try await eventually("the page opens") { self.editor?.ref == ref }
        return try #require(editor)
    }
}

/// A window to put views in, as the app's own scene would.
@MainActor
final class Stage {
    let window: UIWindow

    init() throws {
        var scene: UIWindowScene?
        let deadline = Date().addingTimeInterval(15)
        while scene == nil && Date() < deadline {
            scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            if scene == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        }
        window = UIWindow(windowScene: try #require(scene, "the host app has no window scene"))
        window.makeKeyAndVisible()
    }

    /// Shows a SwiftUI view full-window.
    func show(_ view: some View) {
        window.rootViewController = UIHostingController(rootView: view)
        window.layoutIfNeeded()
    }

    /// Shows a UIKit view full-window.
    func show(_ view: UIView) {
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        window.rootViewController = controller
        view.frame = controller.view.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(view)
        controller.view.layoutIfNeeded()
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
    }
}
