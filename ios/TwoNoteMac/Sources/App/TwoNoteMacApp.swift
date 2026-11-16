import AppKit
import notify
import SwiftUI

@main
struct TwoNoteMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // One main window, like Notes: the account has one library and one open page.
        Window("TwoNote", id: "main") {
            if let model = delegate.model {
                RootView()
                    .environment(model)
                    .environment(delegate.requests)
            } else {
                Color.clear // the unit tests' host
            }
        }
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            TwoNoteCommands(app: delegate.model, requests: delegate.requests)
        }

        Settings {
            if let model = delegate.model {
                SettingsView()
                    .environment(model)
            }
        }
    }
}

/// Owns the app model for the life of the process, and does what the Mac's app life cycle
/// asks: save before quitting, lock on the triggers `AutoLockMonitor` watches, follow
/// `twonote://` links (the widget), import what the share extension left.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel?
    let requests = WindowRequests()
    private(set) var autoLock: AutoLockMonitor?
    /// The end-to-end run, when this launch is one (DEBUG builds only).
    private var endToEnd: AnyObject?
    private var keyMonitor: Any?
    private let inboxWatch = DarwinNotificationWatch(SharedContainer.inboxChangedNotification)
    private let quitWatch = DarwinNotificationWatch(AppDelegate.quitNotification)
    /// Asks TwoNote to quit as the Quit command does (saving and locking first); posted by
    /// tools/install-mac.sh before it replaces the app. Carries nothing; anyone may post it.
    /// Named under the App Group, as a sandboxed process's notifications have to be:
    /// <team>.<prefix>.mac.quit.
    nonisolated static let quitNotification = SharedContainer.notificationPrefix + ".quit"

    /// True when the process is the host of the unit tests: then it stays out of the way (no
    /// Keychain, no store, no window content).
    static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    override init() {
        if Self.isTestHost {
            model = nil
        } else {
            let environment = AppEnvironment.live()
            #if DEBUG
            // For the UI tests: start from a Mac that has never been set up.
            if ProcessInfo.processInfo.arguments.contains("-TwoNoteResetState") {
                AppModel.wipe(environment)
                // Both Keychains, whichever one this launch uses.
                let both = MacSecretStore.live().store
                for name in MacSecretStore.names { both.remove(name) }
            }
            #endif
            model = AppModel(environment: environment)
        }
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard model != nil else { return }
        // twonote:// links (the widget's rows, `open twonote://new`). Installed before
        // launching finishes, so the link that launched the app arrives here too.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let model else { return }
        // A widget button runs an intent in this process instead of opening a URL.
        DeepLinkRelay.shared.handler = { [weak self] link in
            self?.follow(link)
        }
        // The share extension says when it has left an item (TwoNote may be open beside it).
        inboxWatch.start {
            Task { await model.importSharedItems() }
        }
        quitWatch.start {
            NSApp.terminate(nil)
        }
        #if DEBUG
        // For the UI tests' screenshots: they switch the app between light and dark with a
        // notification (the system setting is the user's, and stays untouched).
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.twonote.mac.debug.appearance"), object: nil, queue: .main
        ) { notification in
            let name = notification.object as? String
            MainActor.assumeIsolated {
                NSApp.appearance = name == "dark" ? NSAppearance(named: .darkAqua) : name == "light" ? NSAppearance(named: .aqua) : nil
            }
        }
        #endif
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.route(event) == false } ? event : nil
        }
        let monitor = AutoLockMonitor(app: model)
        monitor.start()
        autoLock = monitor
        Task { await model.start() }
        #if DEBUG
        if let run = EndToEndDriver.arguments() {
            let driver = EndToEndDriver(app: model, delegate: self, server: run.server, control: run.control)
            endToEnd = driver
            driver.start()
        }
        #endif
    }

    /// Quitting saves what was typed, gives sync a moment and locks, so that nothing of the
    /// notes is in the window when the system takes its picture of it for the next launch.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.phase == .unlocked else { return .terminateNow }
        Task {
            await model.didEnterBackground(waitForSync: .seconds(3))
            await model.lock()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: Links

    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let url = Self.url(in: event) else { return }
        open(url)
    }

    /// The address a "get URL" Apple event carries (what `open twonote://new` sends).
    nonisolated static func url(in event: NSAppleEventDescriptor) -> URL? {
        guard event.eventClass == AEEventClass(kInternetEventClass), event.eventID == AEEventID(kAEGetURL),
              let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue else { return nil }
        return URL(string: text)
    }

    /// A `twonote://` link: TwoNote comes to the front and does what it asks - at once when
    /// unlocked, after the unlock when locked (the window then shows the lock screen). Anything
    /// that is not exactly one of the app's links is ignored.
    func open(_ url: URL) {
        guard let link = DeepLink(url: url) else { return }
        follow(link)
    }

    func follow(_ link: DeepLink) {
        guard let model else { return }
        showMainWindow()
        Task { await model.open(link) }
    }

    /// The main window in front and key, opened again if it was closed.
    func showMainWindow() {
        NSApp.unhide(nil)
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }), window.isVisible {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            requests.openMainWindow?()
        }
    }

    /// The two keys the menus alone do not deliver; true when the key was used.
    /// - ⇧⌘L, Format > Checklist (as in Notes): the Services menu's "Search With…" has the same
    ///   keys and would otherwise get them first.
    /// - Delete and Forward Delete in a list: Edit > Delete, which the page list answers by
    ///   asking to delete the selected page (a list turns neither key into that command itself).
    func route(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "l",
           let editor = model?.library?.editor, MenuState(app: model).canFormat {
            editor.chooseBlock("todo")
            return true
        }
        if modifiers.isEmpty, event.keyCode == 51 || event.keyCode == 117,
           let window = event.window ?? NSApp.keyWindow, window.firstResponder is NSTableView {
            // After the key event, as a menu command would come.
            DispatchQueue.main.async {
                let sent = NSApp.sendAction(#selector(NSText.delete(_:)), to: nil, from: nil)
                if !sent { NSSound.beep() }
            }
            return true
        }
        return false
    }
}

/// Chooses the window's content for the app's phase. Locked, set-up and starting show nothing
/// of the notes, and the window is called just "TwoNote" (its title is also what the Window
/// menu, Mission Control and the Dock's window list show).
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowRequests.self) private var requests
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            switch app.phase {
            case .starting:
                Color(nsColor: .windowBackgroundColor)
                    .navigationTitle("TwoNote")
            case .setUp:
                EnrolView()
                    .navigationTitle("TwoNote")
            case .locked:
                UnlockView()
                    .navigationTitle("TwoNote")
            case .unlocked:
                if let library = app.library {
                    LibraryView(library: library)
                } else {
                    Color(nsColor: .windowBackgroundColor)
                        .navigationTitle("TwoNote")
                }
            case .unavailable:
                ContentUnavailableView(
                    "TwoNote Can’t Open Its Data",
                    systemImage: "exclamationmark.triangle",
                    description: Text("The notes stored on this Mac could not be opened. Restart your Mac and try again."))
                    .navigationTitle("TwoNote")
            }
        }
        .frame(minWidth: 760, minHeight: 460)
        .task {
            await app.start()
        }
        .onAppear {
            let openWindow = openWindow
            requests.openMainWindow = { openWindow(id: "main") }
        }
    }
}

/// Listens for a Darwin notification (the kind that crosses process boundaries; it carries
/// nothing but its name): the share extension's "an item is waiting", the installer's "quit".
final class DarwinNotificationWatch {
    private let name: String
    private var token: Int32 = NOTIFY_TOKEN_INVALID

    init(_ name: String) {
        self.name = name
    }

    func start(_ onChange: @escaping @MainActor () -> Void) {
        guard token == NOTIFY_TOKEN_INVALID else { return }
        notify_register_dispatch(name, &token, .main) { _ in
            MainActor.assumeIsolated(onChange)
        }
    }

    deinit {
        if token != NOTIFY_TOKEN_INVALID {
            notify_cancel(token)
        }
    }
}
