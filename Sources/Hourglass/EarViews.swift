import SwiftUI
import UsageCore

/// One ear's content, drawn the same way at rest, in the editor's top row and on its tiles.
/// Anchored to the notch edge with the shared gap and growing outwards, so the gap never changes
/// with the content's width.
struct EarItemView: View {
    let item: EarItem
    let side: NotchLayout.Side
    let state: UsageState
    let now: Date
    let memory: NotchUIModel
    /// On a tile, the warning dot shows faintly while both limits are under 70%, so the tile
    /// doesn't look the same as "Nothing".
    var showsIdleDot = false
    /// At rest: the hover figures start from the middle of this ear's content.
    var anchors: [Figure] = []
    var context: NotchContext?

    var body: some View {
        let gap = item.isRound ? NotchGeometry.ringEarGap : NotchGeometry.earGap
        content
            .overlay {
                if let context {
                    ForEach(anchors, id: \.self) { figure in
                        FigureAnchor(figure: figure, context: context)
                    }
                }
            }
            .padding(side == .left ? .trailing : .leading, gap)
            .frame(width: item.earWidth, alignment: side == .left ? .trailing : .leading)
    }

    // At rest, "stale" includes having no reading at all.
    private var stale: Bool { state.freshness == .stale || state.freshness == .none }
    private var fiveReady: Bool { state.isReady(.fiveHour) }
    private var weekReady: Bool { state.isReady(.sevenDay) }
    private var fiveColor: Color {
        fiveReady ? Theme.ready : Shade.color(state.fiveHour?.level ?? .normal, stale: stale)
    }
    private var weekColor: Color {
        weekReady ? Theme.ready : Shade.color(state.sevenDay?.level ?? .normal, stale: stale)
    }
    private var textColor: Color { stale ? Theme.stale : Theme.normal }

    @ViewBuilder
    private var content: some View {
        let five = state.fiveHour
        switch item {
        case .ringPair:
            // 5-hour usage on the outer ring, weekly on the inner one.
            RingPair(five: fiveReady ? 0 : five?.fraction, weekly: weekReady ? 0 : state.sevenDay?.fraction,
                     outer: fiveColor, inner: stale ? Theme.stale : Theme.normal.opacity(0.55), memory: memory)
                .frame(width: 18, height: 18)
        case .fiveHourRing:
            Ring(fraction: fiveReady ? 0 : five?.fraction, color: fiveColor, radius: 7.6, key: "ring-5h", memory: memory)
                .frame(width: 18, height: 18)
        case .fiveHourPercent:
            EarPercent(text: percentText(.fiveHour), color: fiveColor, size: 11.7)
        case .weeklyPercent:
            VStack(alignment: side == .left ? .trailing : .leading, spacing: -1) {
                Text("WEEK")
                    .font(.system(size: 5.5, weight: .bold))
                    .kerning(0.5)
                    .foregroundStyle(Color.white.opacity(stale ? 0.3 : 0.5))
                EarPercent(text: percentText(.sevenDay), color: weekColor, size: 10.5)
            }
            .padding(.top, 1)
        case .bothPercent:
            VStack(alignment: side == .left ? .trailing : .leading, spacing: -1.5) {
                EarPercent(text: percentText(.fiveHour), color: fiveColor, size: 10.5)
                EarPercent(text: percentText(.sevenDay), color: weekColor, size: 8.5)
                    .opacity(0.75)
            }
        case .countdown:
            // Changes once a minute, never animated.
            EarText(text: fiveReady ? "Ready" : UsageFormat.countdown(five?.timeUntilReset), ready: fiveReady, color: textColor)
        case .resetClock:
            EarText(text: fiveReady ? "Ready" : five.map { Self.clock($0.resetsAt) } ?? "–", ready: fiveReady, color: textColor)
        case .miniBars:
            VStack(spacing: 3) {
                MiniBar(fraction: fiveReady ? 0 : five?.fraction ?? 0, color: fiveColor)
                MiniBar(fraction: weekReady ? 0 : state.sevenDay?.fraction ?? 0, color: stale ? Theme.stale : Theme.normal.opacity(0.6))
            }
            .frame(width: 22)
        case .timeWedge:
            TimeWedge(remaining: fiveReady ? nil : five.map { $0.timeUntilReset / UsageWindowKind.fiveHour.duration },
                      color: fiveReady ? Theme.ready : textColor)
                .frame(width: 15, height: 15)
        case .warningDot:
            if let level = EarItem.warningDotLevel(state) {
                Circle().fill(Shade.color(level, stale: stale)).frame(width: 7, height: 7)
            } else {
                Circle().fill(Color.white.opacity(showsIdleDot ? 0.18 : 0)).frame(width: 7, height: 7)
            }
        case .nothing:
            Color.clear.frame(width: 1, height: 1)
        }
    }

    private func percentText(_ kind: UsageWindowKind) -> EarPercent.Value {
        if state.isReady(kind) { return .word("Ready") }
        guard let w = state.window(kind) else { return .word("--") }
        return .percent(w.percentage)
    }

    /// "19:40" (or "7:40" on a 12-hour Mac): the reset is always within five hours, so the
    /// day and AM/PM are left out to fit the ear.
    static func clock(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
    }
}

/// A percentage with a smaller sign, as the hover figures draw it.
struct EarPercent: View {
    enum Value { case percent(Double), word(String) }
    let text: Value
    let color: Color
    let size: CGFloat

    var body: some View {
        Group {
            switch text {
            case .percent(let value):
                let shown = max(0, value)
                HStack(alignment: .firstTextBaseline, spacing: 0.5) {
                    Text(shown > 0 && shown < 1 ? "<1" : "\(Int(shown.rounded()))")
                        .font(.system(size: size))
                        .monospacedDigit()
                    Text("%").font(.system(size: size * 0.74)).opacity(0.7)
                }
            case .word(let word):
                Text(word).font(.system(size: size * 0.9, weight: .medium))
            }
        }
        .foregroundStyle(color)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .contentTransition(.identity)
        .transaction { $0.animation = nil }
    }
}

/// The countdown's text style: 11.7 pt is the largest at which "4h59" fits beside the gap
/// unscaled, so "1h00" and "59m" stay the same size.
struct EarText: View {
    let text: String
    let ready: Bool
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: ready ? 11 : 11.7, weight: ready ? .medium : .regular))
            .monospacedDigit()
            .foregroundStyle(ready ? Theme.ready : color)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .contentTransition(.identity)
            .transaction { $0.animation = nil }
            .padding(.top, 1)
    }
}

struct MiniBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(color)
                    .frame(width: fraction > 0 ? max(3, geo.size.width * min(fraction, 1)) : 0)
            }
        }
        .frame(height: 3)
        .animation(Motion.value, value: fraction)
    }
}

/// Time left in the 5-hour window as a wedge that shrinks towards the reset, like a kitchen timer.
struct TimeWedge: View {
    /// 0 to 1, or nil when no window is open.
    let remaining: Double?
    let color: Color

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(remaining == nil ? 1 : 0.35), lineWidth: 1.2)
            if let remaining {
                Wedge(fraction: min(max(remaining, 0), 1))
                    .fill(color)
                    .padding(2.2)
            }
        }
    }
}

struct Wedge: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        guard fraction > 0 else { return path }
        path.move(to: center)
        path.addArc(center: center, radius: min(rect.width, rect.height) / 2,
                    startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * fraction), clockwise: false)
        path.closeSubpath()
        return path
    }
}
