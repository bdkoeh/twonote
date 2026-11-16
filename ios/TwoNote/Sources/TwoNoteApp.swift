import notify
import SwiftUI
import UIKit

@main
struct TwoNoteApp: App {
    @State private var model: AppModel?
    @State private var cover = PrivacyCover()
    private let inboxWatch = InboxWatch()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // As the host of the unit tests the app stays out of the way: no Keychain, no store.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let environment = AppEnvironment.live()
        #if DEBUG
        // For the UI tests: start from a device that has never been set up.
        if ProcessInfo.processInfo.arguments.contains("-TwoNoteResetState") {
            AppModel.wipe(environment)
        }
        #endif
        let model = AppModel(environment: environment)
        _model = State(initialValue: model)
        // A widget button runs an intent in this process instead of opening a URL.
        DeepLinkRelay.shared.handler = { link in
            Task { await model.open(link) }
        }
        // The share extension says when it has left an item (the app may be on screen beside it).
        inboxWatch.start {
            Task { await model.importSharedItems() }
        }
    }

    var body: some Scene {
        WindowGroup {
            if let model {
                RootView()
                    .environment(model)
                    .onAppear { cover.start() }
                    .onOpenURL { url in
                        if let link = DeepLink(url: url) {
                            Task { await model.open(link) }
                        }
                    }
            }
        }
        .onChange(of: scenePhase) { old, phase in
            guard let model else { return }
            switch phase {
            case .active:
                Task {
                    // Lock first if the app was away too long, then show what is underneath.
                    await model.didBecomeActive()
                    cover.hide()
                }
            case .inactive:
                if old == .background {
                    Task { await model.willEnterForeground() }
                } else {
                    Task { await model.willResignActive() }
                }
            case .background:
                // Edits reach the local store a few milliseconds after they are made; make sure
                // they are there, and give sync a moment, before the process can be suspended.
                let application = UIApplication.shared
                let task = application.beginBackgroundTask(withName: "Save and sync")
                Task {
                    await model.didEnterBackground()
                    application.endBackgroundTask(task)
                }
            @unknown default:
                break
            }
        }
    }
}

/// Listens for the share extension's "an item is waiting" (a Darwin notification, the kind
/// that crosses process boundaries; it carries nothing but its name).
final class InboxWatch {
    private var token: Int32 = NOTIFY_TOKEN_INVALID

    func start(_ onChange: @escaping @MainActor () -> Void) {
        guard token == NOTIFY_TOKEN_INVALID else { return }
        notify_register_dispatch(SharedContainer.inboxChangedNotification, &token, .main) { _ in
            MainActor.assumeIsolated(onChange)
        }
    }

    deinit {
        if token != NOTIFY_TOKEN_INVALID {
            notify_cancel(token)
        }
    }
}

/// Keeps note content out of the app switcher: while the app is in the background a plain
/// window lies over everything (sheets and alerts included), so the snapshot the system takes
/// for the switcher shows that instead.
///
/// It goes up when the scene enters the background - the snapshot is taken after that - and
/// not already when the app merely becomes inactive, which also happens while the device is
/// being folded and for system prompts, where a flash of the cover would be wrong.
@MainActor
final class PrivacyCover {
    private var window: UIWindow?
    private var observer: (any NSObjectProtocol)?

    /// Starts watching for the scene going to the background. Safe to call again.
    func start() {
        guard observer == nil else { return }
        // Delivered synchronously on the main thread, before the system takes its snapshot.
        observer = NotificationCenter.default.addObserver(
            forName: UIScene.didEnterBackgroundNotification, object: nil, queue: nil
        ) { [weak self] notification in
            let scene = notification.object as? UIWindowScene
            MainActor.assumeIsolated {
                self?.show(in: scene)
            }
        }
    }

    func show(in scene: UIWindowScene?) {
        guard window == nil, let scene else { return }
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground

        let symbol = UIImageView(image: UIImage(systemName: "lock.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 44)))
        symbol.tintColor = .secondaryLabel
        let name = UILabel()
        name.text = "TwoNote"
        name.font = .preferredFont(forTextStyle: .title2)
        name.textColor = .secondaryLabel
        let stack = UIStackView(arrangedSubviews: [symbol, name])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor),
        ])

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.rootViewController = controller
        window.accessibilityIdentifier = "privacy-cover"
        window.isHidden = false // shown without becoming key: the keyboard stays where it is
        window.layoutIfNeeded()
        self.window = window
    }

    func hide() {
        window?.isHidden = true
        window = nil
    }
}

/// Chooses the screen for the app's phase.
struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            switch app.phase {
            case .starting:
                Color(.systemBackground)
                    .ignoresSafeArea()
            case .setUp:
                EnrolView()
            case .locked:
                UnlockView()
            case .unlocked:
                if let library = app.library {
                    LibraryView(library: library)
                }
            case .unavailable:
                ContentUnavailableView(
                    "TwoNote Can’t Open Its Data",
                    systemImage: "exclamationmark.triangle",
                    description: Text("The notes stored on this device could not be opened. Restart the device and try again."))
            }
        }
        .task {
            await app.start()
        }
    }
}
