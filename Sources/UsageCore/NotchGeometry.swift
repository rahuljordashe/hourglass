import CoreGraphics
import Foundation

/// Where the camera housing is on a screen, and the window frames the notch panel uses.
///
/// AppKit screen coordinates (origin bottom-left). The notch's size comes from the screen's
/// auxiliary top areas (the menu bar either side of the housing) and its top safe-area inset;
/// macOS has no notch API. Frames are snapped to whole points, as the window server does.
public struct NotchGeometry: Equatable, Sendable {
    public var screenFrame: CGRect
    public var notchWidth: CGFloat
    public var notchHeight: CGFloat
    public var notchMidX: CGFloat

    /// The resting indicators sit beside the notch, this wide on each side, never below it.
    public static let earWidth: CGFloat = 36
    /// Distance from the notch's edge to the ear content, the same on both sides, with the content
    /// growing outwards from there (never centred in the ear, or the gap changes with its width).
    /// The ring sits 1 pt closer: a round edge looks further away than the straight edge of text.
    public static let earGap: CGFloat = 7
    public static let ringEarGap: CGFloat = 6

    /// Room for the concave "flare" at the panel's top corners, outside the content.
    public static let flare: CGFloat = 8
    /// The largest the open panel gets; the window takes this size whenever it isn't at rest.
    public static let openSize = CGSize(width: 440, height: 600)

    public init(screenFrame: CGRect, notchWidth: CGFloat, notchHeight: CGFloat, notchMidX: CGFloat) {
        self.screenFrame = screenFrame
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
        self.notchMidX = notchMidX
    }

    /// From a screen's frame, its auxiliary top-left and top-right areas and its top safe-area
    /// inset. Nil when the screen has no camera housing.
    public init?(screenFrame: CGRect, auxiliaryTopLeft: CGRect?, auxiliaryTopRight: CGRect?, safeAreaTop: CGFloat) {
        guard let left = auxiliaryTopLeft, let right = auxiliaryTopRight, safeAreaTop > 0 else { return nil }
        let width = right.minX - left.maxX
        guard width > 40, width < screenFrame.width / 2 else { return nil }
        self.init(screenFrame: screenFrame, notchWidth: width, notchHeight: safeAreaTop, notchMidX: left.maxX + width / 2)
    }

    /// The camera housing itself.
    public var notchRect: CGRect {
        CGRect(x: notchMidX - notchWidth / 2, y: screenFrame.maxY - notchHeight, width: notchWidth, height: notchHeight)
    }

    /// Notch plus both ears: what the resting state covers. Each ear is 36 pt unless its item
    /// needs more (a clock time takes 46 pt), so the two sides can differ.
    public func restingRect(left: CGFloat = earWidth, right: CGFloat = earWidth) -> CGRect {
        let notch = notchRect
        return CGRect(x: notch.minX - left, y: notch.minY, width: notch.width + left + right, height: notch.height)
    }

    public var restingRect: CGRect { restingRect() }

    /// The window at rest: exactly the resting shape plus its corner flares, so nothing else of
    /// the menu bar is covered. With `earsHidden` (watching video) it shrinks to the notch.
    public func restingWindowFrame(earsHidden: Bool, left: CGFloat = earWidth, right: CGFloat = earWidth) -> CGRect {
        let base = earsHidden ? notchRect : restingRect(left: left, right: right)
        return snapped(base.insetBy(dx: -Self.flare, dy: 0))
    }

    /// The window whenever the panel is peeking, open or showing an alert: top-centred on the notch.
    public var openWindowFrame: CGRect {
        let size = Self.openSize
        let width = size.width + Self.flare * 2
        return snapped(CGRect(x: notchMidX - width / 2, y: screenFrame.maxY - size.height, width: width, height: size.height))
    }

    /// The SwiftUI canvas inside the window. It never changes size and is always centred on the
    /// notch, top-aligned to the screen, whatever the window's frame. Resizing the window only
    /// changes how much of it is visible, so nothing drawn ever moves when the window grows or
    /// shrinks (re-centring a resized canvas is what made the resting line jump on hover).
    public static var canvasSize: CGSize {
        CGSize(width: openSize.width + flare * 2, height: openSize.height)
    }

    /// Where the canvas goes inside a window with `windowFrame` (window coordinates, origin
    /// bottom-left). Parts outside the window are simply clipped.
    public func canvasOrigin(in windowFrame: CGRect) -> CGPoint {
        let size = Self.canvasSize
        return CGPoint(x: notchMidX - size.width / 2 - windowFrame.minX,
                       y: screenFrame.maxY - size.height - windowFrame.minY)
    }

    /// The canvas in screen coordinates. The same for every window frame.
    public func canvasScreenFrame(in windowFrame: CGRect) -> CGRect {
        let origin = canvasOrigin(in: windowFrame)
        return CGRect(origin: CGPoint(x: windowFrame.minX + origin.x, y: windowFrame.minY + origin.y), size: Self.canvasSize)
    }

    /// Grows the rect outwards to whole points, so it always covers what it was asked to.
    func snapped(_ rect: CGRect) -> CGRect {
        let minX = rect.minX.rounded(.down), maxX = rect.maxX.rounded(.up)
        let minY = rect.minY.rounded(.down), maxY = rect.maxY.rounded(.up)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
