import AppKit
import SwiftUI
import UsageCore

/// The borderless panel the notch is drawn in, set up per the recipe verified on macOS 27.0.1:
/// - level `.mainMenu + 2`, assigned last (anything set afterwards can reset it);
/// - `isFloatingPanel` never set (it silently drops the level to 3);
/// - `ignoresMouseEvents` never assigned, so clicks pass through transparent pixels;
/// - non-activating, on every Space, including full-screen ones;
/// - frame never clamped below the menu bar.
final class NotchPanel: NSPanel {
    static let level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)

    init<Content: View>(rootView: Content) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        // The SwiftUI canvas has a fixed size and is never re-laid out when the window changes;
        // `place` only moves it within the window so it stays put on screen.
        let host = FirstMouseHostingView(rootView: rootView)
        host.sizingOptions = []
        host.autoresizingMask = []
        host.frame = CGRect(origin: .zero, size: NotchGeometry.canvasSize)
        let container = TrackingView()
        container.autoresizesSubviews = false
        container.addSubview(host)
        contentView = container
        self.host = host

        level = Self.level // last
    }

    private var host: NSView?

    /// Called when the pointer enters or leaves the window. At rest the window is exactly the
    /// hover zone, so this replaces listening to every mouse move on the screen.
    var onPointerChange: (() -> Void)? {
        get { (contentView as? TrackingView)?.onChange }
        set { (contentView as? TrackingView)?.onChange = newValue }
    }

    /// The canvas's frame in the window, for converting SwiftUI coordinates to the screen.
    var canvasFrame: CGRect { host?.frame ?? .zero }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Stay over the menu bar: never let AppKit push the frame below it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Resizes the window without animating, keeping the canvas exactly where it is on screen.
    func place(_ frame: CGRect, geometry: NotchGeometry) {
        let origin = geometry.canvasOrigin(in: frame)
        guard frame != self.frame || host?.frame.origin != origin else { return }
        disableScreenUpdatesUntilFlush()
        setFrame(frame, display: false, animate: false)
        host?.setFrameOrigin(origin)
        displayIfNeeded()
    }
}

/// Buttons in the panel work on the first click, without the panel having to become key first.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Reports the pointer entering and leaving its bounds, whether or not the app is active.
final class TrackingView: NSView {
    var onChange: (() -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        self.area = area
    }

    override func mouseEntered(with event: NSEvent) { onChange?() }
    override func mouseExited(with event: NSEvent) { onChange?() }
}
