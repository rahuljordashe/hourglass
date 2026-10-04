import AppKit
import UsageCore

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// The Mac's own display (not an external one, whatever its name or order).
    var isBuiltIn: Bool {
        displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false
    }

    /// The camera housing on this screen, if it has one.
    var notchGeometry: NotchGeometry? {
        NotchGeometry(
            screenFrame: frame,
            auxiliaryTopLeft: auxiliaryTopLeftArea,
            auxiliaryTopRight: auxiliaryTopRightArea,
            safeAreaTop: safeAreaInsets.top
        )
    }

    /// The built-in display with a camera housing. `NSScreen.main`, `screens[0]` and screen names
    /// are all unreliable for this.
    static var notchScreen: NSScreen? {
        screens.first { $0.isBuiltIn && $0.notchGeometry != nil }
    }
}
