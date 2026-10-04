import AppKit
import UsageCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let paths = NotchPaths()
    private lazy var store = UsageStore(paths: paths)
    private lazy var connection = ConnectionManager(paths: paths)
    private let loginItem = LoginItem()
    private lazy var refresher = RefreshController(paths: paths, store: store)
    private let ui = NotchUIModel()
    private let video = VideoWatcher()
    private var alerts: AlertTracker = AlertTracker()

    private var notchController: NotchController!
    private var statusItemController: StatusItemController!
    private var observers: [NSObjectProtocol] = []
    private var screenChangeTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--render-previews"), index + 1 < CommandLine.arguments.count {
            store.start()
            let actions = NotchActions(openUsagePage: {}, expand: {}, collapse: {}, toggleHideForAnHour: {}, quit: {})
            let context = NotchContext(store: store, ui: ui, connection: connection, loginItem: loginItem, refresher: refresher, actions: actions)
            PreviewRenderer.run(context: context, into: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot-live"), index + 1 < CommandLine.arguments.count {
            store.start()
            let actions = NotchActions(openUsagePage: {}, expand: {}, collapse: {}, toggleHideForAnHour: {}, quit: {})
            let context = NotchContext(store: store, ui: ui, connection: connection, loginItem: loginItem, refresher: refresher, actions: actions)
            PreviewRenderer.snapshotLive(context: context, into: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            return
        }
        if terminateIfAlreadyRunning() { return }
        Log.app.info("Launching Hourglass")

        let actions = NotchActions(
            openUsagePage: { [weak self] in
                NSWorkspace.shared.open(Links.usageSettings)
                self?.notchController.collapse()
            },
            expand: { [weak self] in self?.notchController.expand() },
            collapse: { [weak self] in self?.notchController.collapse() },
            toggleHideForAnHour: { [weak self] in self?.notchController.toggleHideForAnHour() },
            quit: { NSApp.terminate(nil) }
        )
        let context = NotchContext(store: store, ui: ui, connection: connection, loginItem: loginItem, refresher: refresher, actions: actions)
        notchController = NotchController(context: context)
        statusItemController = StatusItemController(context: context)

        connection.setUpOnLaunch()
        loginItem.enableOnFirstRun()

        store.onChange = { [weak self] state in self?.stateChanged(state) }
        store.start()
        _ = alerts.process(store.state, now: store.now) // seed silently with what's already known
        refresher.start()
        video.onChange = { [weak self] watching in self?.notchController.setWatchingVideo(watching) }
        video.start()

        updatePresentation()
        observeSystem()
        if AppEnvironment.isSandboxed { observeDebugCommands() }
    }

    /// Sandbox only: lets a test script switch modes, e.g. to take screenshots without a mouse.
    private func observeDebugCommands() {
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("io.github.rahuljordashe.hourglass.debug"), object: nil, queue: .main
        ) { [weak self] note in
            let command = note.object as? String
            MainActor.assumeIsolated {
                guard let self else { return }
                switch command {
                case "compact": self.notchController.debugGo(.compact)
                case "peek": self.notchController.debugGo(.peek)
                case "expanded": self.notchController.debugGo(.expanded)
                case "refresh": self.refresher.request(.manual)
                case "alert":
                    let state = self.store.state
                    if let five = state.fiveHour {
                        self.notchController.present(UsageAlert(window: .fiveHour, kind: .threshold(75), percentage: five.percentage, resetsAt: five.resetsAt))
                    }
                default: break
                }
            }
        })
    }

    func applicationWillTerminate(_ notification: Notification) {
        notchController?.teardown()
    }

    // MARK: State

    private func stateChanged(_ state: UsageState) {
        if let alert = alerts.process(state, now: store.now) {
            notchController.present(alert)
        }
    }

    // MARK: Screens and spaces

    /// Notch on the built-in display when it has one; menu bar pill otherwise.
    private func updatePresentation() {
        if let geometry = NSScreen.notchScreen?.notchGeometry {
            statusItemController.hide()
            notchController.show(geometry)
        } else {
            notchController.teardown()
            statusItemController.show()
        }
    }

    private func observeSystem() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.notchController.reduceMotionChanged() }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.connection.refresh()
                self?.screensChanged()
            }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.connection.refresh()
                self?.loginItem.refresh()
            }
        })
    }

    /// Display changes arrive in bursts (lid, resolution, arrangement); act once they've settled
    /// for half a second. Nothing is rebuilt if the notch geometry didn't change.
    private func screensChanged() {
        screenChangeTask?.cancel()
        screenChangeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            self.updatePresentation()
        }
    }

    // MARK: Single instance

    private func terminateIfAlreadyRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0 != NSRunningApplication.current }
        guard !others.isEmpty else { return false }
        Log.app.info("Another instance is running; exiting")
        NSApp.terminate(nil)
        return true
    }
}
