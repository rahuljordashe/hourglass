import SwiftUI
import UsageCore

@MainActor
@Observable
final class NotchUIModel {
    enum Mode: Equatable {
        case compact, peek, expanded
        case alert(UsageAlert)
    }

    var mode: Mode = .compact
    var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    /// The camera housing's size, for laying out around it. Nil in the menu bar popover.
    var geometry: NotchGeometry?
    /// Resting indicators stepped aside: a video is playing, or "Hide for 1 hour".
    var earsHidden = false
    /// "Hide for 1 hour" is on until then.
    var hiddenUntil: Date?

    /// The pointer is over the notch: an instant small response before the peek's dwell ends.
    var isHovered = false
    /// Where the 5-hour and weekly figures sit in each mode, measured from the layout. The
    /// figures are drawn once, above every mode, and travel between these.
    private(set) var slots: [FigureSlotKey: CGRect] = [:]

    /// The visible panel in window coordinates (origin top-left), for hover and click tracking.
    /// Not observed: drawing never depends on it.
    @ObservationIgnored var panelFrame: CGRect = .zero
    /// Bar values as last shown, so bars move from what you last saw instead of sweeping from 0.
    @ObservationIgnored var lastSeen: [String: Double] = [:]

    var slotTag: SlotTag {
        switch mode {
        case .compact: .rest
        case .peek: .peek
        case .expanded: .open
        case .alert: .alert
        }
    }

    func setSlot(_ rect: CGRect, for figure: Figure, in tag: SlotTag) {
        let key = FigureSlotKey(figure: figure, tag: tag)
        guard slots[key] != rect else { return }
        if slots[key] == nil, tag == slotTag, !reduceMotion {
            // First time this mode is shown: let the figure fly in rather than appear.
            withAnimation(Motion.open) { slots[key] = rect }
        } else {
            slots[key] = rect
        }
    }

    var notchWidth: CGFloat { geometry?.notchWidth ?? 185 }
    var notchHeight: CGFloat { geometry?.notchHeight ?? 32 }
}

/// The figures that travel between modes.
enum Figure: CaseIterable, Hashable {
    case fiveHour, weekly

    var window: UsageWindowKind { self == .fiveHour ? .fiveHour : .sevenDay }
}

enum SlotTag: Hashable {
    case rest, peek, open, alert
}

struct FigureSlotKey: Hashable {
    var figure: Figure
    var tag: SlotTag
}

/// Everything a notch view needs, passed as one bundle.
struct NotchContext {
    let store: UsageStore
    let ui: NotchUIModel
    let connection: ConnectionManager
    let loginItem: LoginItem
    let refresher: RefreshController
    let actions: NotchActions
}

@MainActor
struct NotchActions {
    var openUsagePage: () -> Void
    var expand: () -> Void
    var collapse: () -> Void
    var toggleHideForAnHour: () -> Void
    var quit: () -> Void
}

// MARK: - Motion

extension EnvironmentValues {
    /// Rendering to an image (`--render-previews`): show the settled state, skip entrances.
    @Entry var isStaticRender = false
}

enum Motion {
    /// The panel grows out of the notch with a light spring.
    static let open = Animation.spring(response: 0.44, dampingFraction: 0.74)
    /// Closing is quicker and doesn't overshoot.
    static let close = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.26)
    /// Values move from where they were.
    static let value = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.6)
    /// Reduce Motion: cross-fades only.
    static let fade = Animation.easeInOut(duration: 0.15)
}

/// Rows arrive just after the shape starts to grow, sharpening from a soft blur, ~34 ms apart.
/// With `soft`, a plain quick fade with no blur or drop: for parts that carry on from the previous
/// mode (the 5-hour and weekly rows), so opening reads as an expansion, not a reload.
struct Entrance: ViewModifier {
    let index: Int
    let reduceMotion: Bool
    var soft = false
    @State private var shown = false
    @Environment(\.isStaticRender) private var isStatic

    func body(content: Content) -> some View {
        let shown = shown || isStatic
        let plain = reduceMotion || soft
        return content
            .opacity(shown ? 1 : 0)
            .blur(radius: shown || plain ? 0 : 5)
            .offset(y: shown || plain ? 0 : -5)
            .onAppear {
                guard !isStatic else { return }
                let animation = reduceMotion ? Motion.fade
                    : soft ? Animation.easeOut(duration: 0.2).delay(0.05)
                    : Animation.easeOut(duration: 0.34).delay(0.07 + Double(index) * 0.034)
                withAnimation(animation) { self.shown = true }
            }
    }
}

extension View {
    func entrance(_ index: Int, _ reduceMotion: Bool, soft: Bool = false) -> some View {
        modifier(Entrance(index: index, reduceMotion: reduceMotion, soft: soft))
    }
}

// MARK: - Root

/// The notch shape and whatever it holds. The window is at least as large as the shape; the shape
/// is top-centred and animates between sizes as the mode changes.
struct NotchRootView: View {
    let context: NotchContext
    @Environment(\.isStaticRender) private var isStatic

    nonisolated static let space = "notchPanel"

    var body: some View {
        let ui = context.ui
        let isOpen = ui.mode != .compact
        let top: CGFloat = isOpen ? NotchGeometry.flare : 6
        let bottom: CGFloat = isOpen ? 20 : 10
        // Travelling figures, unless Reduce Motion asks for cross-fades (or we're drawing a still).
        let overlaid = !ui.reduceMotion && !isStatic

        content
            .environment(\.figuresOverlaid, overlaid)
            .frame(width: width, alignment: .top)
            .frame(minHeight: ui.notchHeight, alignment: .top)
            .coordinateSpace(.named(Self.space))
            .overlay {
                if overlaid { FiguresLayer(context: context) }
            }
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: bottom, bottomTrailingRadius: bottom, style: .continuous))
            .background(alignment: .top) {
                NotchShape(topCornerRadius: top, bottomCornerRadius: bottom)
                    .fill(Color.black)
                    .padding(.horizontal, -top)
                    .shadow(color: .black.opacity(isOpen ? 0.45 : 0), radius: 18, y: 10)
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { ui.panelFrame = $0 }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .foregroundStyle(Theme.normal)
            .environment(\.colorScheme, .dark)
    }

    private var width: CGFloat {
        let ui = context.ui
        switch ui.mode {
        case .compact:
            let rest = ui.earsHidden ? ui.notchWidth : ui.notchWidth + 2 * NotchGeometry.earWidth
            // The instant hover response: a 1.5 pt swell each side (within the window's flare room).
            return rest + (ui.isHovered && !ui.reduceMotion ? 3 : 0)
        case .peek: return 320
        case .expanded: return 400
        case .alert: return 340
        }
    }

    @ViewBuilder
    private var content: some View {
        switch context.ui.mode {
        case .compact:
            // Closing runs in sequence: open content fades out at once, the shape shrinks, and the
            // ear content fades in only over the last part of the shrink.
            RestingView(context: context)
                .transition(.asymmetric(
                    insertion: .opacity.animation(.easeOut(duration: 0.1).delay(context.ui.reduceMotion ? 0 : 0.17)),
                    removal: .opacity.animation(.easeOut(duration: 0.08))))
        case .peek:
            PeekView(context: context).transition(Self.modeTransition)
        case .expanded:
            ExpandedView(context: context, showsNotchGap: true).transition(Self.modeTransition)
        case .alert(let alert):
            AlertView(context: context, alert: alert).transition(Self.modeTransition)
        }
    }

    static let modeTransition = AnyTransition.asymmetric(
        insertion: .opacity.animation(.easeOut(duration: 0.12)),
        removal: .opacity.animation(.easeOut(duration: 0.08)))
}

// MARK: - Travelling figures

extension EnvironmentValues {
    /// The 5-hour and weekly figures are drawn by `FiguresLayer` above the modes, so the slots in
    /// each mode only reserve space. False in the menu bar popover, with Reduce Motion, and when
    /// drawing stills: the slots then draw the figures themselves.
    @Entry var figuresOverlaid = false
}

/// How a figure looks in a given mode.
struct FigureSpec: Equatable {
    enum Content: Equatable {
        case percent(Double)
        case word(String)
    }

    var content: Content
    var size: CGFloat
    var weight: Font.Weight
    var signScale: CGFloat
    var color: Color

    @MainActor
    static func make(_ figure: Figure, _ tag: SlotTag, state: UsageState, now: Date) -> FigureSpec {
        let kind = figure.window
        let status = state.window(kind)
        let ready = state.isReady(kind)
        let stale = tag == .rest ? (state.freshness == .stale || state.freshness == .none) : state.freshness == .stale
        let color = ready ? Theme.ready : status.map { Shade.color($0.level, stale: stale) } ?? Theme.stale
        let content: Content = ready ? .word("Ready") : status.map { .percent($0.percentage) } ?? .word("--")
        switch tag {
        case .rest, .alert:
            // Not shown at rest: the figures sit small inside the ring pair and grow out of it on hover.
            return FigureSpec(content: content, size: 7, weight: .regular, signScale: 0.74, color: color)
        case .peek:
            return FigureSpec(content: content, size: ready ? 26 : 34, weight: ready ? .regular : .light, signScale: 0.6, color: color)
        case .open:
            return FigureSpec(content: content, size: ready ? 20 : 28, weight: ready ? .regular : .light, signScale: 0.57, color: color)
        }
    }
}

/// Font size as an animatable value, so a figure grows and shrinks smoothly as it travels.
struct AnimatableFont: ViewModifier, Animatable {
    var size: CGFloat
    var weight: Font.Weight

    nonisolated var animatableData: CGFloat {
        get { size }
        set { size = newValue }
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight))
    }
}

struct FigureText: View {
    let spec: FigureSpec

    var body: some View {
        Group {
            switch spec.content {
            case .percent(let value):
                let shown = max(0, value)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(shown > 0 && shown < 1 ? "<1" : "\(Int(shown.rounded()))")
                        .monospacedDigit()
                        .contentTransition(.numericText(value: shown))
                        .modifier(AnimatableFont(size: spec.size, weight: spec.weight))
                    Text("%")
                        .modifier(AnimatableFont(size: spec.size * spec.signScale, weight: spec.weight))
                        .opacity(0.7)
                }
                .kerning(-0.2)
                .animation(Motion.value, value: shown)
            case .word(let word):
                Text(word).modifier(AnimatableFont(size: spec.size, weight: spec.weight))
            }
        }
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(spec.color)
    }
}

/// Where a figure goes in a mode. Reserves exactly its space and reports where that is; draws the
/// figure itself only when the overlay isn't used.
struct FigureSlot: View {
    let figure: Figure
    let tag: SlotTag
    let context: NotchContext
    @Environment(\.figuresOverlaid) private var overlaid

    var body: some View {
        let spec = FigureSpec.make(figure, tag, state: context.store.state, now: context.store.now)
        FigureText(spec: spec)
            .opacity(overlaid ? 0 : 1)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(NotchRootView.space)) } action: { rect in
                if overlaid { context.ui.setSlot(rect, for: figure, in: tag) }
            }
    }
}

/// The 5-hour and weekly figures, drawn once above every mode. Changing mode moves them to the new
/// mode's slots and resizes them in the same spring as the shape, so the 5-hour figure slides and
/// grows out of the ear into the hover cells and then into the open list, and back on close.
struct FiguresLayer: View {
    let context: NotchContext

    var body: some View {
        let ui = context.ui
        let tag = ui.slotTag
        let state = context.store.state
        ZStack(alignment: .topLeading) {
            ForEach(Figure.allCases, id: \.self) { figure in
                let slot = ui.slots[FigureSlotKey(figure: figure, tag: tag)]
                // At rest both figures wait inside the ring pair (or behind the camera while the
                // ears are hidden) and grow out of it on hover.
                let hidden = tag == .alert || tag == .rest || slot == nil
                let target = tag == .rest && ui.earsHidden ? behindCamera : slot ?? behindCamera
                FigureText(spec: FigureSpec.make(figure, tag == .alert ? .rest : tag, state: state, now: context.store.now))
                    .position(x: target.midX, y: target.midY)
                    .opacity(hidden ? 0 : (tag == .rest && !ui.isHovered ? 0.88 : 1))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var behindCamera: CGRect {
        let ui = context.ui
        let width = ui.earsHidden ? ui.notchWidth : ui.notchWidth + 2 * NotchGeometry.earWidth
        return CGRect(x: width / 2 - 10, y: ui.notchHeight / 2 - 8, width: 20, height: 16)
    }
}

// MARK: - Shared pieces

enum Shade {
    static func color(_ level: UsageLevel, stale: Bool) -> Color {
        stale ? Theme.stale : Theme.color(for: level)
    }
}

/// A hairline bar. Starts from the value last shown under its `key` (so re-created bars never
/// sweep up from empty, and the ear line doesn't move at rest), then moves to the current value.
struct HairBar: View {
    let fraction: Double
    var color: Color = Theme.normal
    var height: CGFloat = 5
    var track: Color = Theme.track
    /// Where an even burn would be by now (0 to 1), drawn as a small tick.
    var paceMark: Double?
    var reduceMotion = false
    var key: String?
    var memory: NotchUIModel?
    @State private var shown: Double?
    @Environment(\.isStaticRender) private var isStatic

    var body: some View {
        let target = min(max(fraction, 0), 1)
        let start = key.flatMap { memory?.lastSeen[$0] } ?? target
        let value = isStatic ? target : (shown ?? start)
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(color)
                    .frame(width: value > 0 ? max(height, width * value) : 0)
                if let paceMark {
                    Rectangle()
                        .fill(Color.white.opacity(0.8))
                        .frame(width: 1, height: height + 4)
                        .padding(.horizontal, 0.5)
                        .background(Color.black)
                        .offset(x: min(max(0, width * paceMark - 1), width - 2))
                        .accessibilityHidden(true)
                }
            }
            .frame(height: height)
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: height + 4)
        .onAppear {
            guard !isStatic else { return }
            shown = start
            remember(target)
            if start != target {
                withAnimation(reduceMotion ? Motion.fade : Motion.value.delay(0.1)) { shown = target }
            }
        }
        .onChange(of: target) { _, new in
            remember(new)
            withAnimation(reduceMotion ? Motion.fade : Motion.value) { shown = new }
        }
    }

    private func remember(_ value: Double) {
        if let key { memory?.lastSeen[key] = value }
    }
}

/// "Checked 3 min ago", "Next refresh in 6 min", "Checking…", with a status dot.
struct StatusLine: View {
    let context: NotchContext

    var body: some View {
        let state = context.store.state
        let refresher = context.refresher
        let now = context.store.now
        HStack(spacing: 6) {
            if refresher.isReading {
                Spinner()
                Text("Checking…")
            } else if let notice = refresher.notice {
                dot(Theme.ready)
                Text(notice)
            } else if let wait = refresher.waitDescription(now: now) {
                dot(Theme.warning)
                Text(wait)
            } else if let problem = refresher.problem, state.hasData {
                dot(Theme.warning)
                Text(problem).help(problem)
            } else if let age = state.age {
                dot(age > 15 * 60 ? Theme.stale : Theme.ready)
                Text(state.isSeeded ? "\(UsageFormat.checked(age)) · last known" : UsageFormat.checked(age))
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Color.white.opacity(0.5))
        .lineLimit(1)
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 6, height: 6)
    }
}

/// Exists only while a read runs.
struct Spinner: View {
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: 8, height: 8)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { spinning = true }
            }
    }
}

enum WindowText {
    /// "resets in 2h 30m", "back at 19:40" at the limit, "No active window" when ready.
    static func short(_ status: WindowStatus?, ready: Bool, now: Date) -> String {
        if ready { return "No active window" }
        guard let status else { return "no reading" }
        if status.level == .exhausted { return "back at \(UsageFormat.clock(status.resetsAt, now: now))" }
        return "resets in \(UsageFormat.duration(status.timeUntilReset))"
    }
}

// MARK: - Resting

/// Two concentric rings: outer for the 5-hour window, inner for the week. Both start at 12 o'clock
/// and fill clockwise; anything above 0% shows at least a short arc. Values move from the last
/// ones shown, so nothing sweeps at rest.
struct RingPair: View {
    let five: Double?
    let weekly: Double?
    let outer: Color
    let inner: Color
    let memory: NotchUIModel

    var body: some View {
        ZStack {
            Ring(fraction: five, color: outer, radius: 7.6, key: "ring-5h", memory: memory)
            Ring(fraction: weekly, color: inner, radius: 4, key: "ring-weekly", memory: memory)
        }
    }
}

struct Ring: View {
    let fraction: Double?
    let color: Color
    let radius: CGFloat
    let key: String
    let memory: NotchUIModel
    @State private var shown: Double?

    static let lineWidth: CGFloat = 2.2
    /// So 1 to 3% still reads as a mark rather than nothing.
    static let minimumArc = 0.06

    var body: some View {
        let target = Self.arc(fraction)
        let value = shown ?? memory.lastSeen[key] ?? target
        ZStack {
            Circle().stroke(Theme.track, lineWidth: Self.lineWidth)
            Circle()
                .trim(from: 0, to: value)
                .stroke(color, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(value > 0 ? 1 : 0)
        }
        .frame(width: radius * 2, height: radius * 2)
        .onAppear {
            shown = memory.lastSeen[key] ?? target
            memory.lastSeen[key] = target
            if shown != target { withAnimation(memory.reduceMotion ? Motion.fade : Motion.value) { shown = target } }
        }
        .onChange(of: target) { _, new in
            memory.lastSeen[key] = new
            withAnimation(memory.reduceMotion ? Motion.fade : Motion.value) { shown = new }
        }
    }

    static func arc(_ fraction: Double?) -> Double {
        guard let fraction, fraction > 0 else { return 0 }
        return min(max(fraction, minimumArc), 1)
    }
}

/// Reports the ring pair's centre as the resting place of a travelling figure. Draws nothing.
struct FigureAnchor: View {
    let figure: Figure
    let context: NotchContext
    @Environment(\.figuresOverlaid) private var overlaid

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(NotchRootView.space)) } action: { rect in
                if overlaid { context.ui.setSlot(rect, for: figure, in: .rest) }
            }
    }
}

/// At rest: a short usage line in the left ear and the 5-hour figure in the right ear, nothing
/// below the notch. Nothing animates unless a reading changes it.
struct RestingView: View {
    let context: NotchContext

    var body: some View {
        let ui = context.ui
        let state = context.store.state
        let five = state.fiveHour
        let ready = state.isReady(.fiveHour)
        let stale = state.freshness == .stale || state.freshness == .none
        let color = ready ? Theme.ready : Shade.color(five?.level ?? .normal, stale: stale)

        return HStack(spacing: 0) {
            if !ui.earsHidden {
                // Left ear: 5-hour usage on the outer ring, weekly on the inner one.
                RingPair(five: ready ? 0 : five?.fraction, weekly: state.isReady(.sevenDay) ? 0 : state.sevenDay?.fraction,
                         outer: color, inner: stale ? Theme.stale : Theme.normal.opacity(0.55), memory: ui)
                    .frame(width: 18, height: 18)
                    .overlay {
                        // Where the hover figures start from.
                        ForEach(Figure.allCases, id: \.self) { figure in
                            FigureAnchor(figure: figure, context: context)
                        }
                    }
                    // Anchored to the notch edge, like the countdown on the other side.
                    .padding(.trailing, NotchGeometry.ringEarGap)
                    .frame(width: NotchGeometry.earWidth, alignment: .trailing)
                    .opacity(ui.isHovered ? 1 : 0.88)
                    .transition(.opacity)
            }
            Color.clear.frame(width: ui.notchWidth)
            if !ui.earsHidden {
                // Right ear: time until the 5-hour reset. Changes once a minute, never animated.
                Text(ready ? "Ready" : UsageFormat.countdown(five?.timeUntilReset))
                    // 11.7 pt is the largest at which "4h59" fits beside the gap unscaled, so "1h00"
                    // and "59m" stay the same size (scaling only the wider form made the text jump).
                    .font(.system(size: ready ? 11 : 11.7, weight: ready ? .medium : .regular))
                    .monospacedDigit()
                    .foregroundStyle(ready ? Theme.ready : stale ? Theme.stale : Theme.normal)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .contentTransition(.identity)
                    .transaction { $0.animation = nil }
                    .opacity(ui.isHovered ? 1 : 0.88)
                    .padding(.leading, NotchGeometry.earGap)
                    .frame(width: NotchGeometry.earWidth, alignment: .leading)
                    .padding(.top, 1)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, ui.isHovered && !ui.reduceMotion ? 1.5 : 0)
        .frame(height: ui.notchHeight)
        .contentShape(Rectangle())
        .onTapGesture { context.actions.expand() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CompactAccessibility.label(state))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { context.actions.expand() }
    }
}

enum CompactAccessibility {
    static func label(_ state: UsageState) -> String {
        guard state.hasData else { return "Claude usage. No reading yet." }
        var parts = ["Claude usage."]
        for kind in UsageWindowKind.allCases {
            if state.isReady(kind) {
                parts.append("\(kind.spokenTitle.capitalized) limit is ready.")
                continue
            }
            guard let w = state.window(kind) else { continue }
            parts.append("\(kind.spokenTitle.capitalized) limit \(Int(w.percentage.rounded())) percent used, resets in \(UsageFormat.spokenDuration(w.timeUntilReset)).")
        }
        if let age = state.age { parts.append("Updated \(UsageFormat.age(age)).") }
        return parts.joined(separator: " ")
    }
}

// MARK: - Peek (hover)

struct PeekView: View {
    let context: NotchContext

    var body: some View {
        let state = context.store.state
        let rm = context.ui.reduceMotion
        VStack(alignment: .leading, spacing: 12) {
            if state.hasData {
                HStack(alignment: .center, spacing: 18) {
                    PeekCell(figure: .fiveHour, context: context)
                    Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1).entrance(0, rm)
                    PeekCell(figure: .weekly, context: context)
                }
                .fixedSize(horizontal: false, vertical: true)
                StatusLine(context: context).entrance(1, rm)
            } else {
                EmptyStateView(refresher: context.refresher, compact: true).entrance(0, rm)
            }
        }
        .padding(.top, context.ui.notchHeight + 8)
        .padding(.horizontal, 22)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { context.actions.expand() }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Click for details")
    }
}

struct PeekCell: View {
    let figure: Figure
    let context: NotchContext

    var body: some View {
        let state = context.store.state
        let now = context.store.now
        let kind = figure.window
        let status = state.window(kind)
        let ready = state.isReady(kind)
        let rm = context.ui.reduceMotion
        VStack(alignment: .leading, spacing: 2) {
            Text(kind.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.55))
                .entrance(0, rm)
            // The figure itself flies in from the ear (or from behind the camera).
            FigureSlot(figure: figure, tag: .peek, context: context)
                .padding(.vertical, ready ? 4 : 0)
            Text(kind == .sevenDay && !ready && status != nil
                 ? "resets \(UsageFormat.clock(status!.resetsAt, now: now))"
                 : WindowText.short(status, ready: ready, now: now))
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.48))
                .entrance(1, rm)
            // Fill = usage. Tick = how much of the window's time has passed.
            HairBar(fraction: ready ? 0 : status?.fraction ?? 0,
                    color: ready ? Theme.ready : Shade.color(status?.level ?? .normal, stale: state.freshness == .stale),
                    paceMark: (ready || status?.isReset != false) ? nil : status?.elapsedFraction,
                    reduceMotion: rm, key: "bar-\(kind.rawValue)", memory: context.ui)
                .padding(.top, 6)
                .entrance(1, rm, soft: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EmptyStateView: View {
    let refresher: RefreshController
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(refresher.isReading ? "Asking Claude Code…" : "No reading yet")
                .font(.system(size: compact ? 13 : 14, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, compact ? 4 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var detail: String {
        if refresher.isReading { return "Fetching your 5-hour and weekly usage." }
        if let problem = refresher.problem { return problem }
        return "Click the notch to fetch your usage."
    }
}

// MARK: - Expanded (open)

/// A calm list: 5-hour and weekly with pace marks and the run-out line, per-model rows, credits,
/// then status. Header controls sit in the band beside the camera.
struct ExpandedView: View {
    let context: NotchContext
    /// In the notch the header leaves a gap for the camera; in the menu bar popover it doesn't.
    var showsNotchGap: Bool

    var body: some View {
        let state = context.store.state
        let now = context.store.now
        let rm = context.ui.reduceMotion
        VStack(alignment: .leading, spacing: 0) {
            header.entrance(0, rm)
            VStack(alignment: .leading, spacing: 16) {
                if state.hasData {
                    // These two carry on from the hover view: their figures travel, the rest fades.
                    LimitRow(figure: .fiveHour, context: context)
                    LimitRow(figure: .weekly, context: context)
                    if let budget = WeeklyBudget.make(weekly: state.sevenDay, now: now) {
                        BudgetCard(budget: budget, now: now).entrance(3, rm)
                    }
                    // New on opening: these get the staggered entrance.
                    if !state.scoped.isEmpty {
                        ModelSection(rows: state.scoped, stale: state.freshness == .stale, ui: context.ui).entrance(4, rm)
                    }
                    if state.credits != nil || !state.promos.isEmpty {
                        CreditsSection(credits: state.credits, promos: state.promos, now: now, ui: context.ui).entrance(5, rm)
                    }
                } else {
                    EmptyStateView(refresher: context.refresher).entrance(1, rm)
                }
                footer.entrance(6, rm)
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                UsageGlyph(size: 13)
                Text("Usage").font(.system(size: 12.5, weight: .semibold))
            }
            .padding(.leading, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { context.actions.collapse() }

            if showsNotchGap { Color.clear.frame(width: context.ui.notchWidth) }

            HStack(spacing: 2) {
                RefreshButton(refresher: context.refresher)
                SettingsMenu(context: context)
            }
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: showsNotchGap ? context.ui.notchHeight : 30)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            StatusLine(context: context)
            Spacer(minLength: 6)
            Button(action: context.actions.openUsagePage) {
                Text("claude.ai usage ↗")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
    }
}

struct LimitRow: View {
    let figure: Figure
    let context: NotchContext

    var body: some View {
        let state = context.store.state
        let now = context.store.now
        let kind = figure.window
        let status = state.window(kind)
        let ready = state.isReady(kind)
        let stale = state.freshness == .stale
        let rm = context.ui.reduceMotion
        let color = ready ? Theme.ready : Shade.color(status?.level ?? .normal, stale: stale)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind == .fiveHour ? "5-hour limit" : "Weekly limit")
                        .font(.system(size: 12.5, weight: .medium))
                    Text(subtitle(status, ready: ready, now: now))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.48))
                }
                .entrance(1, rm, soft: true)
                Spacer(minLength: 4)
                FigureSlot(figure: figure, tag: .open, context: context)
            }
            HairBar(fraction: ready ? 0 : status?.fraction ?? 0, color: color,
                    paceMark: (ready || status?.isReset != false) ? nil : status?.elapsedFraction,
                    reduceMotion: rm, key: "bar-\(kind.rawValue)", memory: context.ui)
                .entrance(1, rm, soft: true)
            if !ready, let status {
                Group {
                    if status.level == .exhausted {
                        Text("Limit reached. Back at \(UsageFormat.clock(status.resetsAt, now: now)).")
                            .foregroundStyle(Theme.critical)
                    } else if let hit = status.projectedLimitAt {
                        Text("At this rate you'll hit the limit around \(UsageFormat.clock(hit, now: now)).")
                            .foregroundStyle(Theme.warning)
                    }
                }
                .font(.system(size: 11))
                .entrance(2, rm)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func subtitle(_ status: WindowStatus?, ready: Bool, now: Date) -> String {
        if ready { return "No active window. The next message starts one." }
        guard let status else { return "No reading for this window yet" }
        return "resets in \(UsageFormat.duration(status.timeUntilReset)) · \(UsageFormat.clock(status.resetsAt, now: now))"
    }
}

/// How much of the weekly limit is left per remaining day, with a strip of the remaining days.
struct BudgetCard: View {
    let budget: WeeklyBudget
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Weekly budget").font(.system(size: 12, weight: .medium))
                Spacer(minLength: 6)
                Text("\(Int(budget.percentLeft.rounded()))% left · \(UsageFormat.longDuration(budget.timeLeft))")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.48))
            }
            HStack(alignment: .firstTextBaseline) {
                Text(mainLine)
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(budget.line == .exhausted ? Theme.critical : Theme.normal)
                Spacer(minLength: 6)
                Text("\(budget.line == .exhausted ? "resets" : "until") \(UsageFormat.clock(budget.resetsAt, now: now))")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.48))
            }
            DayStrip(days: budget.days)
        }
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var mainLine: String {
        switch budget.line {
        case .perDay(let n): "about \(n)% a day"
        case .leftUntilReset(let n): "\(n)% left until reset"
        case .exhausted: "No weekly budget left"
        }
    }
}

/// Today through the reset day, each as wide as the hours left in it. Today is highlighted.
struct DayStrip: View {
    let days: [WeeklyBudget.Day]

    var body: some View {
        GeometryReader { geo in
            let total = max(days.map(\.hours).reduce(0, +), 0.001)
            let gaps = CGFloat(max(days.count - 1, 0)) * 2
            HStack(alignment: .top, spacing: 2) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    let width = max(1, (geo.size.width - gaps) * day.hours / total)
                    VStack(alignment: .leading, spacing: 3) {
                        Capsule()
                            .fill(day.isToday ? Theme.normal.opacity(0.85) : Color.white.opacity(0.18))
                            .frame(height: 4)
                        if width >= (day.isToday ? 36 : 24) {
                            Text(day.isToday ? "Today" : day.start.formatted(.dateTime.weekday(.abbreviated)))
                                .font(.system(size: 9.5))
                                .foregroundStyle(Color.white.opacity(day.isToday ? 0.7 : 0.4))
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .frame(width: width, alignment: .leading)
                }
            }
        }
        .frame(height: 20)
    }
}

struct SectionCaption: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .kerning(0.7)
            .foregroundStyle(Color.white.opacity(0.4))
    }
}

/// Per-model (or per-surface) weekly limits, such as Fable.
struct ModelSection: View {
    let rows: [ScopedWindowStatus]
    let stale: Bool
    let ui: NotchUIModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionCaption(text: "Weekly, by model")
            ForEach(rows) { row in
                let color = row.isReady ? Theme.ready : Shade.color(row.level, stale: stale)
                HStack(spacing: 10) {
                    Text(row.name).font(.system(size: 12)).lineLimit(1).frame(width: 62, alignment: .leading)
                    HairBar(fraction: row.fraction, color: color, height: 3, reduceMotion: ui.reduceMotion,
                            key: "model-\(row.name)", memory: ui)
                    Text(row.isReady ? "Ready" : row.percent.map(UsageFormat.percent) ?? "--")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(Color.white.opacity(0.85))
                        .frame(width: 40, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.top, 12)
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
    }
}

/// Usage credits (on or off, and this month's spend) and any promotional credit.
struct CreditsSection: View {
    let credits: PlanUsage.Credits?
    let promos: [PlanUsage.Promo]
    let now: Date
    let ui: NotchUIModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Usage credits").font(.system(size: 12))
                Spacer()
                creditsValue
            }
            if let fraction = spendFraction {
                HairBar(fraction: fraction, height: 3, reduceMotion: ui.reduceMotion, key: "credits", memory: ui)
            }
            ForEach(promos, id: \.key) { promo in
                HStack {
                    Text(UsageFormat.promoTitle(promo.key)).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    Spacer()
                    Text(promoValue(promo)).font(.system(size: 11.5)).monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.top, 12)
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
    }

    @ViewBuilder
    private var creditsValue: some View {
        if credits?.isEnabled == true, let used = credits?.used {
            let currency = credits?.currency ?? "USD"
            HStack(spacing: 4) {
                Text(UsageFormat.money(used, currency: currency)).monospacedDigit()
                if let limit = credits?.monthlyLimit, limit > 0 {
                    Text("of \(UsageFormat.money(limit, currency: currency))").foregroundStyle(Color.white.opacity(0.45))
                } else {
                    Text("this month, no cap").foregroundStyle(Color.white.opacity(0.45))
                }
            }
            .font(.system(size: 12))
        } else {
            Text(credits?.isEnabled == true ? "On" : credits?.isEnabled == false ? "Off" : "Unknown")
                .font(.system(size: 10.5, weight: .semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.1), in: Capsule())
                .foregroundStyle(Color.white.opacity(0.65))
        }
    }

    private var spendFraction: Double? {
        guard let credits, credits.isEnabled == true, let used = credits.used, let limit = credits.monthlyLimit, limit > 0 else { return nil }
        return used / limit
    }

    private func promoValue(_ promo: PlanUsage.Promo) -> String {
        var text = promo.remainingDollars.map { "\(UsageFormat.money($0, currency: "USD")) left" } ?? "--"
        if let expires = promo.expiresAt { text += " · until \(UsageFormat.clock(expires, now: now))" }
        return text
    }
}

struct RefreshButton: View {
    let refresher: RefreshController

    var body: some View {
        Button { refresher.request(.manual) } label: {
            Group {
                if refresher.isReading {
                    Spinner()
                } else {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                }
            }
            .foregroundStyle(Color.white.opacity(0.7))
            .frame(width: 26, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(refresher.isReading)
        .help("Ask Claude Code for fresh numbers. No model turn, so it doesn't use your limit.")
        .accessibilityLabel(refresher.isReading ? "Refreshing usage" : "Refresh usage")
    }
}

struct SettingsMenu: View {
    let context: NotchContext

    var body: some View {
        Menu {
            Button("Refresh now") { context.refresher.request(.manual) }
                .disabled(context.refresher.isReading)
            Text("\(context.refresher.readsInLastHour(now: context.store.now)) of \(context.refresher.hourlyCap) reads used this hour")
            Divider()
            Button(context.ui.hiddenUntil == nil ? "Hide for 1 hour" : "Show again") { context.actions.toggleHideForAnHour() }
            Toggle("Launch at login", isOn: Binding(
                get: { context.loginItem.isEnabled },
                set: { context.loginItem.set($0) }
            ))
            if context.connection.isConnected {
                Divider()
                Button("Disconnect old status line bridge") { context.connection.disconnect() }
                Button("Show bridge log") { context.connection.revealLog() }
            }
            Divider()
            Button("Quit Hourglass") { context.actions.quit() }
        } label: {
            Text("···")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.7))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More")
    }
}

// MARK: - Alert

struct AlertView: View {
    let context: NotchContext
    let alert: UsageAlert

    var body: some View {
        let status = context.store.state.window(alert.window)
        let color = alert.kind == .reset ? Theme.ready : Theme.color(for: status?.level ?? .normal)
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(color, lineWidth: 2.5)
                Image(systemName: icon).font(.system(size: 12, weight: .bold)).foregroundStyle(color)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.title).font(.system(size: 13, weight: .semibold))
                Text(subtitle(status))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.48))
            }
            Spacer(minLength: 0)
        }
        .padding(.top, context.ui.notchHeight + 6)
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .entrance(0, context.ui.reduceMotion)
        .contentShape(Rectangle())
        .onTapGesture { context.actions.expand() }
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch alert.kind {
        case .reset: "arrow.counterclockwise"
        case .threshold(100): "xmark"
        case .threshold: "exclamationmark"
        }
    }

    private func subtitle(_ status: WindowStatus?) -> String {
        switch alert.kind {
        case .reset:
            return "Fresh \(alert.window == .fiveHour ? "5-hour" : "weekly") allowance"
        case .threshold(100):
            guard let status else { return "" }
            return "Back at \(UsageFormat.clock(status.resetsAt, now: context.store.now))"
        case .threshold:
            guard let status else { return "" }
            return "\(UsageFormat.percent(status.percentage)) used · resets in \(UsageFormat.duration(status.timeUntilReset))"
        }
    }
}
