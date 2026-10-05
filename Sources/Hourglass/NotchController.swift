import AppKit
import SwiftUI
import UsageCore

/// Owns the notch panel and its interaction model:
/// rest (indicators beside the notch) → peek (hover, after a short dwell) → open (click),
/// plus brief alerts, and stepping aside while a video plays or for an hour on request.
///
/// The window is only as big as what's drawn at rest (the notch and its two ears), so the rest of
/// the menu bar stays clickable. It grows to the open size just before the shape animates out,
/// and shrinks back once the shape has closed.
@MainActor
final class NotchController {
    private let context: NotchContext
    private var ui: NotchUIModel { context.ui }
    private var panel: NotchPanel?
    private(set) var geometry: NotchGeometry?
    private var mouseMonitors: [Any] = []
    /// The screen-wide pointer listener: only while the panel is open (see `startMouseTracking`).
    private var moveMonitor: Any?
    private var menuObservers: [NSObjectProtocol] = []
    private var isMenuOpen = false
    private var exitPoll: Timer?
    private var isHovering = false
    private var pendingTransition: Task<Void, Never>?
    private var alertDismissal: Task<Void, Never>?
    private var shrinkTask: Task<Void, Never>?
    private var hideTimer: Timer?
    private var isWatchingVideo = false
    /// An alert that arrived while hidden, shown once the indicators return.
    private var heldAlert: UsageAlert?

    /// Hover needs intent: this long over the notch before peeking.
    static let peekDwell: Duration = .milliseconds(260)
    /// Grace when the pointer leaves a peek.
    static let peekGrace: Duration = .milliseconds(180)
    /// Grace when the pointer leaves the open panel (room to reach its menu).
    static let openGrace: Duration = .milliseconds(380)
    static let alertDuration: Duration = .seconds(5)
    static let hideForAnHour: TimeInterval = 3600

    init(context: NotchContext) {
        self.context = context
    }

    var isShowing: Bool { panel != nil }

    // MARK: Presentation

    /// Shows the resting notch for `geometry`, rebuilding only if the geometry changed.
    func show(_ geometry: NotchGeometry) {
        if panel != nil, self.geometry == geometry { return }
        teardown()
        self.geometry = geometry
        ui.geometry = geometry
        ui.mode = .compact

        let panel = NotchPanel(rootView: NotchRootView(context: context))
        panel.onPointerChange = { [weak self] in self?.updateMouseState() }
        panel.place(geometry.restingWindowFrame(earsHidden: ui.earsHidden), geometry: geometry)
        panel.orderFrontRegardless()
        self.panel = panel
        startMouseTracking()
        Log.ui.info("Notch shown: \(Int(geometry.notchWidth))×\(Int(geometry.notchHeight)) pt")
    }

    func teardown() {
        pendingTransition?.cancel()
        alertDismissal?.cancel()
        shrinkTask?.cancel()
        stopMouseTracking()
        panel?.orderOut(nil)
        panel = nil
        geometry = nil
        isHovering = false
    }

    func reduceMotionChanged() {
        ui.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: Stepping aside

    func setWatchingVideo(_ watching: Bool) {
        isWatchingVideo = watching
        updateEarsHidden()
    }

    func toggleHideForAnHour() {
        hideTimer?.invalidate()
        if ui.hiddenUntil != nil {
            ui.hiddenUntil = nil
        } else {
            let until = Date().addingTimeInterval(Self.hideForAnHour)
            ui.hiddenUntil = until
            let timer = Timer(fire: until, interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.ui.hiddenUntil = nil
                    self?.updateEarsHidden()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            hideTimer = timer
        }
        updateEarsHidden()
        collapse()
    }

    /// Fades the ears out (0.3 s) and shrinks the window to the notch, or brings them back.
    /// Hover still works either way.
    private func updateEarsHidden() {
        let hidden = isWatchingVideo || ui.hiddenUntil != nil
        guard hidden != ui.earsHidden else { return }
        if !hidden, ui.mode == .compact, let geometry {
            panel?.place(geometry.restingWindowFrame(earsHidden: false), geometry: geometry) // grow before fading in
        }
        withAnimation(ui.reduceMotion ? Motion.fade : .easeOut(duration: 0.3)) { ui.earsHidden = hidden }
        if hidden {
            scheduleShrink(after: 0.32)
        } else if let alert = heldAlert {
            heldAlert = nil
            present(alert)
        }
    }

    // MARK: Mouse

    /// At rest the window is exactly the hover zone, so its own tracking area reports the pointer
    /// arriving; nothing listens to pointer moves elsewhere on the screen (measured: that cost
    /// 0.3 to 0.7% CPU whenever the mouse moved). While the panel is peeking or open, a
    /// screen-wide listener (no permission needed) follows the pointer, and a 10 Hz check runs
    /// while it's over the notch.
    private func startMouseTracking() {
        stopMouseTracking()
        let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseEntered, .mouseExited, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated { self?.updateMouseState() }
            return event
        }
        // A click anywhere else closes the open panel.
        let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.ui.mode != .compact, !self.isMenuOpen else { return }
                if !self.hotRect().contains(NSEvent.mouseLocation) {
                    // The same soft close as the pointer leaving, unless macOS is about to sweep
                    // windows aside for "Click wallpaper to reveal desktop".
                    if Self.clickRevealsDesktop { self.closeAtOnce() } else { self.go(.compact, because: "click outside") }
                }
            }
        }
        mouseMonitors = [local, outside].compactMap { $0 }

        let center = NotificationCenter.default
        menuObservers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isMenuOpen = true
                    self?.pendingTransition?.cancel()
                }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isMenuOpen = false
                    self?.isHovering = false
                    self?.updateMouseState()
                }
            }
        ]
    }

    private func stopMouseTracking() {
        exitPoll?.invalidate()
        exitPoll = nil
        mouseMonitors.forEach(NSEvent.removeMonitor)
        mouseMonitors = []
        setScreenWideTracking(false)
        menuObservers.forEach(NotificationCenter.default.removeObserver)
        menuObservers = []
    }

    func updateMouseState() {
        guard panel != nil else { updateExitPoll(false); return }
        let inside = hotRect().contains(NSEvent.mouseLocation)
        if !isMenuOpen, inside != isHovering { handleHover(inside) }
        updateExitPoll(inside || ui.mode != .compact)
        setScreenWideTracking(ui.mode != .compact)
    }

    private func setScreenWideTracking(_ on: Bool) {
        if on, moveMonitor == nil {
            moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateMouseState() }
            }
        } else if !on, let monitor = moveMonitor {
            NSEvent.removeMonitor(monitor)
            moveMonitor = nil
        }
    }

    /// While the pointer is over the notch, mouse-move events can go to our own panel instead of
    /// the monitors, so a light 10 Hz check catches it leaving. Runs only while hovered or open.
    private func updateExitPoll(_ needed: Bool) {
        if needed, exitPoll == nil {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateMouseState() }
            }
            timer.tolerance = 0.05
            RunLoop.main.add(timer, forMode: .common)
            exitPoll = timer
        } else if !needed, let timer = exitPoll {
            timer.invalidate()
            exitPoll = nil
        }
    }

    /// What counts as "over the notch", in screen coordinates.
    private func hotRect() -> CGRect {
        guard let geometry, let panel else { return .zero }
        switch ui.mode {
        case .compact:
            let base = ui.earsHidden ? geometry.notchRect : geometry.restingRect
            return base.insetBy(dx: -4, dy: 0).offsetBy(dx: 0, dy: -2).union(base)
        case .peek, .expanded, .alert:
            // SwiftUI reports the panel in canvas coordinates (origin top-left).
            let canvas = geometry.canvasScreenFrame(in: panel.frame), p = ui.panelFrame
            guard !p.isEmpty else { return geometry.restingRect }
            let rect = CGRect(x: canvas.minX + p.minX, y: canvas.maxY - p.maxY, width: p.width, height: p.height)
            return rect.insetBy(dx: -6, dy: -6).union(geometry.restingRect)
        }
    }

    private func handleHover(_ hovering: Bool) {
        isHovering = hovering
        pendingTransition?.cancel()
        // Respond the moment the pointer arrives: the ears brighten and the shape swells slightly.
        // The peek still waits for the dwell.
        withAnimation(ui.reduceMotion ? Motion.fade : .spring(response: 0.18, dampingFraction: 0.8)) {
            ui.isHovered = hovering
        }
        if hovering {
            alertDismissal?.cancel()
            switch ui.mode {
            case .compact:
                pendingTransition = Task { [weak self] in
                    try? await Task.sleep(for: Self.peekDwell)
                    // A click during the dwell already opened the panel: don't drop it to a peek.
                    guard !Task.isCancelled, self?.ui.mode == .compact else { return }
                    self?.go(.peek, because: "hover") // hover never reads; it shows the cached numbers and their age
                }
            case .alert:
                go(.peek, because: "hover over alert")
            case .peek, .expanded:
                break
            }
        } else if ui.mode != .compact, !isMenuOpen {
            let grace = ui.mode == .expanded ? Self.openGrace : Self.peekGrace
            pendingTransition = Task { [weak self] in
                try? await Task.sleep(for: grace)
                guard let self, !Task.isCancelled, !self.isMenuOpen else { return }
                self.go(.compact, because: "pointer left")
            }
        }
    }

    func expand() { go(.expanded, because: "click") }
    func collapse() { go(.compact, because: "collapse") }

    // MARK: Alerts

    func present(_ alert: UsageAlert) {
        guard panel != nil else { return }
        // Held while watching video (limit reached included) and shown when the indicators return.
        if ui.earsHidden {
            heldAlert = alert
            return
        }
        // Never interrupt someone reading the open panel.
        guard ui.mode == .compact else { return }
        Log.ui.info("Alert: \(alert.title, privacy: .public)")
        go(.alert(alert), because: "alert")
        alertDismissal?.cancel()
        alertDismissal = Task { [weak self] in
            try? await Task.sleep(for: Self.alertDuration)
            guard let self, !Task.isCancelled, case .alert = self.ui.mode else { return }
            self.go(self.isHovering ? .peek : .compact, because: "alert ended")
        }
    }

    /// System Settings › Desktop & Dock › "Click wallpaper to reveal desktop" set to Always
    /// (macOS's default when the setting has never been changed).
    static var clickRevealsDesktop: Bool {
        let value = CFPreferencesCopyAppValue("EnableStandardClickToShowDesktop" as CFString, "com.apple.WindowManager" as CFString)
        return (value as? Bool) ?? true
    }

    /// With that setting on, a click elsewhere closes the panel instantly and shrinks the window
    /// back into the menu bar band in the same moment. macOS sweeps every window that reaches into
    /// the desktop aside on that click; if the open window was still there for the close
    /// animation, it got swept too, which showed as a stretched pop.
    private func closeAtOnce() {
        guard let panel, let geometry, ui.mode != .compact else { return }
        Log.ui.info("Mode \(String(describing: self.ui.mode), privacy: .public) → compact (click outside)")
        pendingTransition?.cancel()
        shrinkTask?.cancel()
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { ui.mode = .compact }
        panel.place(geometry.restingWindowFrame(earsHidden: ui.earsHidden), geometry: geometry)
        updateMouseState()
    }

    /// Drives the notch from outside (sandbox debugging).
    func debugGo(_ mode: NotchUIModel.Mode) { go(mode, because: "debug") }

    // MARK: Transitions

    private func go(_ mode: NotchUIModel.Mode, because reason: String) {
        guard let panel, let geometry else { return }
        let previous = ui.mode
        guard previous != mode else { return }
        // Whatever was pending (a hover dwell, a close after the pointer left) is now stale.
        if reason != "hover" && reason != "pointer left" { pendingTransition?.cancel() }
        Log.ui.info("Mode \(String(describing: previous), privacy: .public) → \(String(describing: mode), privacy: .public) (\(reason, privacy: .public))")
        // Expanding shows cached numbers at once and reads if they're over two minutes old.
        if mode == .expanded { context.refresher.request(.expand) }

        if mode == .compact {
            withAnimation(ui.reduceMotion ? Motion.fade : Motion.close) { ui.mode = .compact }
            scheduleShrink(after: ui.reduceMotion ? 0.17 : 0.3)
        } else {
            shrinkTask?.cancel()
            panel.place(geometry.openWindowFrame, geometry: geometry) // the canvas stays put; only the window grows
            withAnimation(ui.reduceMotion ? Motion.fade : Motion.open) { ui.mode = mode }
        }
        updateMouseState()
    }

    /// Shrinks the window to the resting shape once the close animation has finished.
    private func scheduleShrink(after seconds: Double) {
        shrinkTask?.cancel()
        shrinkTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, self.ui.mode == .compact, let geometry = self.geometry else { return }
            self.panel?.place(geometry.restingWindowFrame(earsHidden: self.ui.earsHidden), geometry: geometry)
        }
    }
}
