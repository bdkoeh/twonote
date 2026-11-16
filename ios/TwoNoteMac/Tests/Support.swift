import AppKit
import Foundation
import SwiftUI
import Testing
import Vision
import YrsKit
@testable import TwoNote
@testable import TwoNoteCore

// The Mac app's models against the in-memory protocol server of the sync core's tests
// (FakeServer.swift and Harness.swift are compiled into this bundle from ../TwoNoteCore/Tests),
// exactly as the iPhone app's tests use them.

let fakeServerAddress = "fake.test:8080"

/// One installation of the app on a Mac: its settings, store, secrets and connection. Making a
/// second `AppModel` from the same installation is a relaunch.
@MainActor
final class Installation {
    let server: FakeServer
    let transport: FakeTransport
    let secrets = InMemorySecretStore()
    let defaults: UserDefaults
    let databasePath = temporaryDatabasePath()
    var networkAvailable = true
    /// The Mac's sensor and its Keychain item; survives relaunches like the secrets do.
    let biometrics = FakeBiometricStore()
    /// How far the fake clock is ahead of the real one.
    var clockOffset: Duration = .zero
    /// Stands in for the App Group container the app shares with its extensions.
    let shared = SharedContainer(root: FileManager.default.temporaryDirectory.appendingPathComponent("twonote-mac-group-\(UUID().uuidString)"))
    /// How often the app told the system to redraw the widget.
    var widgetReloads = 0
    /// Replaces `secrets` as the Keychain (the migration tests); nil uses `secrets`.
    var secretStore: (any SecretStore)?

    init(_ server: FakeServer, name: String = "Mac") {
        self.server = server
        transport = FakeTransport(server: server, name: name)
        defaults = UserDefaults(suiteName: "twonote-mac-tests-\(UUID().uuidString)")!
    }

    var now: ContinuousClock.Instant { ContinuousClock.now + clockOffset }

    var environment: AppEnvironment {
        let transport = transport
        var environment = AppEnvironment(defaults: defaults, databasePath: databasePath, secretStore: secretStore ?? secrets, deviceName: "Test Mac")
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
        environment.now = { [unowned self] in self.now }
        environment.sharedContainer = shared
        environment.reloadWidgets = { [unowned self] in self.widgetReloads += 1 }
        return environment
    }

    func launch() async -> AppModel {
        let app = AppModel(environment: environment)
        await app.start()
        return app
    }

    /// Launches the app and signs in to the seeded account; returns once the seeded notebook is there.
    func launchEnrolled(_ seed: Seed) async throws -> (AppModel, LibraryModel) {
        let app = await launch()
        try await app.enrol(
            server: fakeServerAddress, username: testUsername, password: testPassword, secretKey: seed.secretKey, deviceName: "Mac")
        let library = try #require(app.library)
        try await eventually("the seeded notebook arrives") {
            library.notebook(seed.notebookId)?.page(seed.pageId) != nil
        }
        return (app, library)
    }
}

/// A sensor that matches or not as told, and a Keychain item that can be invalidated: the
/// stand-in for Touch ID (the build Mac has none).
final class FakeBiometricStore: BiometricKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var _biometry = BiometryKind.none
    private var _stored: Data?
    private var _outcome: BiometricFailure?
    private var _prompts = 0
    private var _reasons: [String] = []

    var biometry: BiometryKind {
        get { lock.withLock { _biometry } }
        set { lock.withLock { _biometry = newValue } }
    }

    var stored: Data? { lock.withLock { _stored } }

    /// What the next prompts end with: nil is a match.
    var outcome: BiometricFailure? {
        get { lock.withLock { _outcome } }
        set { lock.withLock { _outcome = newValue } }
    }

    var prompts: Int { lock.withLock { _prompts } }
    /// What each prompt said.
    var reasons: [String] { lock.withLock { _reasons } }

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
        lock.withLock {
            _prompts += 1
            _reasons.append(reason)
        }
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

/// A real window to put views in, as the app's own scene would.
@MainActor
final class Stage {
    let window: NSWindow

    init(width: CGFloat = 1100, height: CGFloat = 700) {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: width, height: height),
                          styleMask: [.titled, .resizable, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Stage"
    }

    func show(_ view: some View) {
        window.contentView = NSHostingView(rootView: view)
        window.orderFront(nil)
        pump()
    }

    func show(_ view: NSView) {
        let content = NSView(frame: NSRect(origin: .zero, size: window.contentRect(forFrameRect: window.frame).size))
        view.frame = content.bounds
        view.autoresizingMask = [.width, .height]
        content.addSubview(view)
        window.contentView = content
        window.orderFront(nil)
        pump()
    }

    func pump(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Every string the window's views show (labels, fields, text views), for privacy checks.
    func visibleStrings() -> [String] {
        var strings: [String] = [window.title]
        func walk(_ view: NSView) {
            if let text = view as? NSTextView {
                strings.append(text.string)
            } else if let field = view as? NSTextField {
                strings.append(field.stringValue)
            }
            if let label = view.accessibilityLabel() { strings.append(label) }
            if let value = view.accessibilityValue() as? String { strings.append(value) }
            view.subviews.forEach(walk)
        }
        if let content = window.contentView { walk(content) }
        // SwiftUI draws its text itself; what it shows is in the accessibility tree.
        var seen = 0
        func walkAccessibility(_ element: Any, depth: Int) {
            guard depth < 40, seen < 5000, let element = element as? NSObject else { return }
            seen += 1
            for attribute in [NSAccessibility.Attribute.title, .value, .description] {
                if let text = element.accessibilityAttributeValue(attribute) as? String, !text.isEmpty {
                    strings.append(text)
                }
            }
            for child in element.accessibilityAttributeValue(.children) as? [Any] ?? [] {
                walkAccessibility(child, depth: depth + 1)
            }
        }
        walkAccessibility(window, depth: 0)
        return strings
    }

    /// The words that can be read in the window right now: its views drawn into an image and
    /// read back with the system's text recognition, so SwiftUI's own text counts too.
    func recognizedText() throws -> [String] {
        guard let view = window.contentView else { return [] }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return [] }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard var image = rep.cgImage else { return [] }
        // A view without a background of its own draws on transparent pixels, which the text
        // recognition reads as black: put the window's background under it. And on a display
        // at 1x (this build Mac's), small text is too few pixels: read a 3x enlargement.
        let scale = image.width < 2 * Int(view.bounds.width) ? 3 : 1
        if let context = CGContext(
            data: nil, width: image.width * scale, height: image.height * scale, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            var background = CGColor(gray: 1, alpha: 1)
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                background = NSColor.windowBackgroundColor.cgColor
            }
            context.setFillColor(background)
            context.fill(CGRect(x: 0, y: 0, width: image.width * scale, height: image.height * scale))
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width * scale, height: image.height * scale))
            if let composed = context.makeImage() { image = composed }
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }
}
