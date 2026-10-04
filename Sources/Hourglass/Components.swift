import SwiftUI
import UsageCore

/// A small progress ring for the compact notch.
struct UsageRing: View {
    var fraction: Double
    var color: Color
    var lineWidth: CGFloat = 2.6
    var isDimmed = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, fraction))
                .stroke(isDimmed ? Theme.tertiary : color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
    }
}

/// The app's mark: a two-thirds usage ring, matching the app icon.
struct UsageGlyph: View {
    var size: CGFloat = 13
    var color: Color = Theme.normal

    var body: some View {
        let lineWidth = size * 0.2
        ZStack {
            Circle()
                .stroke(Theme.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: 0.68)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Applies an animation unless Reduce Motion is on.
    func motionAware<V: Equatable>(_ animation: Animation?, value: V, reduceMotion: Bool) -> some View {
        self.animation(reduceMotion ? .easeInOut(duration: 0.12) : animation, value: value)
    }
}
