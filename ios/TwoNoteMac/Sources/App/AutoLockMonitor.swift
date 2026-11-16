import AppKit
import Foundation

/// Locks the Mac app on its own, following the Auto-Lock setting:
/// - after the Auto-Lock time without the app being used (no key press, click or scroll in it,
///   whether it is in front or not);
/// - "Immediately": as soon as another app comes to the front;
/// - whenever the Mac goes to sleep, its display sleeps, its screen is locked, or another user
///   takes over the screen (fast user switching) - unless Auto-Lock is Never.
///
/// Each trigger first hands everything typed to the local store; locking then closes the
/// documents, clears the in-memory search index and drops the keys.
///
/// The notification centres and the clock are parameters, so tests can post the system's
/// notifications themselves and move time forward.
@MainActor
final class AutoLockMonitor {
    /// Why the monitor locked (for tests and the log).
    enum Reason: Equatable {
        case idle
        case resignedActive
        case sleep
        case screensSlept
        case screenLocked
        case sessionResigned
    }

    /// The system's notifications this monitor listens for.
    nonisolated static let screenLockedNotification = Notification.Name("com.apple.screenIsLocked")

    private let app: AppModel
    private let workspaceCenter: NotificationCenter
    private let distributedCenter: NotificationCenter
    private let appCenter: NotificationCenter
    private let now: () -> ContinuousClock.Instant
    private var observers: [(NotificationCenter, any NSObjectProtocol)] = []
    private var eventMonitor: Any?
    private var timer: Task<Void, Never>?
    /// When the app was last used.
    private(set) var lastActivity: ContinuousClock.Instant
    /// The locks this monitor caused, most recent last.
    private(set) var locks: [Reason] = []
    /// How often the idle time is looked at.
    var checkInterval: Duration = .seconds(5)

    init(
        app: AppModel,
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        distributedCenter: NotificationCenter = DistributedNotificationCenter.default(),
        appCenter: NotificationCenter = .default,
        now: (() -> ContinuousClock.Instant)? = nil
    ) {
        self.app = app
        self.workspaceCenter = workspaceCenter
        self.distributedCenter = distributedCenter
        self.appCenter = appCenter
        let clock = now ?? app.environment.now
        self.now = clock
        lastActivity = clock()
    }

    /// Starts listening. `watchEvents` adds the local event monitor that counts key presses and
    /// clicks as use (off in tests, which call `noteActivity()`).
    func start(watchEvents: Bool = true, runTimer: Bool = true) {
        guard observers.isEmpty else { return }
        let system: [(NotificationCenter, Notification.Name, Reason)] = [
            (workspaceCenter, NSWorkspace.willSleepNotification, .sleep),
            (workspaceCenter, NSWorkspace.screensDidSleepNotification, .screensSlept),
            (workspaceCenter, NSWorkspace.sessionDidResignActiveNotification, .sessionResigned),
            (distributedCenter, Self.screenLockedNotification, .screenLocked),
        ]
        for (center, name, reason) in system {
            observe(center, name) { monitor in monitor.systemTrigger(reason) }
        }
        observe(appCenter, NSApplication.didResignActiveNotification) { monitor in monitor.resignedActive() }
        observe(appCenter, NSApplication.didBecomeActiveNotification) { monitor in monitor.becameActive() }

        if watchEvents {
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
            ) { [weak self] event in
                self?.noteActivity()
                return event
            }
        }
        if runTimer {
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: self?.checkInterval ?? .seconds(5))
                    await self?.checkIdle()
                }
            }
        }
    }

    func stop() {
        for (center, token) in observers {
            center.removeObserver(token)
        }
        observers = []
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
        timer?.cancel()
        timer = nil
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor (AutoLockMonitor) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        observers.append((center, token))
    }

    /// The app was used just now.
    func noteActivity() {
        lastActivity = now()
    }

    /// Locks if the app has not been used for the Auto-Lock time.
    func checkIdle() async {
        guard app.phase == .unlocked else { return }
        let delay = app.autoLock
        guard delay != .never, delay != .immediately else { return }
        if delay.shouldLock(after: now() - lastActivity) {
            await lock(.idle)
        }
    }

    private func systemTrigger(_ reason: Reason) {
        guard app.phase == .unlocked, app.autoLock != .never else { return }
        Task { await lock(reason) }
    }

    private func resignedActive() {
        guard app.phase == .unlocked else { return }
        Task {
            // Everything typed goes to the local store whatever the setting.
            await app.willResignActive()
            if app.autoLock == .immediately {
                await lock(.resignedActive)
            }
        }
    }

    private func becameActive() {
        Task {
            await checkIdle()
            noteActivity()
            app.refreshBiometrics()
            if app.phase == .unlocked {
                app.client?.sync.requestSync()
            }
            // What was shared from another app meanwhile (counted only, while locked).
            await app.importSharedItems()
        }
    }

    private func lock(_ reason: Reason) async {
        guard app.phase == .unlocked else { return }
        await app.willResignActive()
        await app.lock()
        locks.append(reason)
    }
}
