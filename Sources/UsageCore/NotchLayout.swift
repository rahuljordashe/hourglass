import CoreGraphics
import Foundation

/// What the notch shows: the two ears at rest, the hover peek's extras and the open panel's
/// sections. Chosen in the notch editor and kept in the app's defaults. The default is the
/// original fixed layout.
public struct NotchLayout: Codable, Equatable, Sendable {
    public var left: EarItem
    public var right: EarItem
    public var hover: HoverOptions
    public var open: OpenLayout

    public init(left: EarItem, right: EarItem, hover: HoverOptions = .init(), open: OpenLayout = .init()) {
        self.left = left
        self.right = right
        self.hover = hover
        self.open = open
    }

    public static let `default` = NotchLayout(left: .ringPair, right: .countdown)

    public enum Side: String, Codable, Sendable, CaseIterable {
        case left, right
    }

    public subscript(side: Side) -> EarItem {
        get { side == .left ? left : right }
        set { if side == .left { left = newValue } else { right = newValue } }
    }

    public func with(_ item: EarItem, on side: Side) -> NotchLayout {
        var copy = self
        copy[side] = item
        return copy
    }

    /// Both ears set to a face's pair; hover and open choices are kept.
    public func with(_ face: Face) -> NotchLayout {
        var copy = self
        copy.left = face.left
        copy.right = face.right
        return copy
    }

    /// The face whose ears match these, if any.
    public var face: Face? {
        Face.allCases.first { $0.left == left && $0.right == right }
    }

    /// Ear widths in points, for the window and the resting shape.
    public var leftWidth: CGFloat { left.earWidth }
    public var rightWidth: CGFloat { right.earWidth }

    // Unknown or missing values fall back to the defaults one field at a time, so a later
    // version's choices never wipe the whole layout.
    enum CodingKeys: String, CodingKey { case left, right, hover, open }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self.default
        left = (try? c.decode(EarItem.self, forKey: .left)) ?? fallback.left
        right = (try? c.decode(EarItem.self, forKey: .right)) ?? fallback.right
        hover = (try? c.decode(HoverOptions.self, forKey: .hover)) ?? fallback.hover
        open = (try? c.decode(OpenLayout.self, forKey: .open)) ?? fallback.open
    }

    /// Reads a saved layout; anything unreadable gives the default.
    public static func decode(_ data: Data?) -> NotchLayout {
        guard let data, let layout = try? JSONDecoder().decode(NotchLayout.self, from: data) else { return .default }
        return layout
    }

    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(self)
    }
}

/// One thing an ear can show. Any item can go in either ear.
public enum EarItem: String, Codable, Sendable, CaseIterable {
    case ringPair
    case fiveHourRing
    case fiveHourPercent
    case weeklyPercent
    case bothPercent
    case countdown
    case resetClock
    case miniBars
    case timeWedge
    case warningDot
    case nothing

    /// Ears are 36 pt; a clock time ("19:40") needs 46 pt, which can cover a menu bar icon.
    public var earWidth: CGFloat {
        self == .resetClock ? Self.wideEarWidth : NotchGeometry.earWidth
    }

    public static let wideEarWidth: CGFloat = 46

    public var isWide: Bool { earWidth > NotchGeometry.earWidth }

    public var title: String {
        switch self {
        case .ringPair: "Ring pair"
        case .fiveHourRing: "5-hour ring"
        case .fiveHourPercent: "5-hour %"
        case .weeklyPercent: "Weekly %"
        case .bothPercent: "Both %"
        case .countdown: "Countdown"
        case .resetClock: "Reset time"
        case .miniBars: "Mini bars"
        case .timeWedge: "Time wedge"
        case .warningDot: "Warning dot"
        case .nothing: "Nothing"
        }
    }

    /// Drawn as a ring (sits 1 pt closer to the notch than text does).
    public var isRound: Bool {
        switch self {
        case .ringPair, .fiveHourRing, .timeWedge, .warningDot: true
        default: false
        }
    }

    /// Shows the 5-hour or weekly figure, so the hover figures can grow out of it.
    public func carries(_ window: UsageWindowKind) -> Bool {
        switch self {
        case .ringPair, .bothPercent, .miniBars: true
        case .fiveHourRing, .fiveHourPercent: window == .fiveHour
        case .weeklyPercent: window == .sevenDay
        case .countdown, .resetClock, .timeWedge, .warningDot, .nothing: false
        }
    }

    /// The warning dot shows from this percentage of either limit.
    public static let warningDotThreshold = 70.0

    /// The level the warning dot shows, or nil when both limits are under 70%.
    public static func warningDotLevel(_ state: UsageState) -> UsageLevel? {
        let windows = UsageWindowKind.allCases.compactMap { kind -> WindowStatus? in
            state.isReady(kind) ? nil : state.window(kind)
        }
        guard let top = windows.max(by: { $0.percentage < $1.percentage }),
              top.percentage >= warningDotThreshold else { return nil }
        return top.level
    }

    /// What the item says, for VoiceOver. Nil when it shows nothing right now.
    public func spoken(_ state: UsageState, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String? {
        func percent(_ kind: UsageWindowKind) -> String? {
            if state.isReady(kind) { return "\(kind.spokenTitle) limit ready" }
            guard let w = state.window(kind) else { return nil }
            return "\(kind.spokenTitle) \(Int(w.percentage.rounded())) percent used"
        }
        let five = state.fiveHour
        let fiveReady = state.isReady(.fiveHour)
        switch self {
        case .ringPair, .bothPercent, .miniBars:
            let parts = [percent(.fiveHour), percent(.sevenDay)].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        case .fiveHourRing, .fiveHourPercent:
            return percent(.fiveHour)
        case .weeklyPercent:
            return percent(.sevenDay)
        case .countdown, .timeWedge:
            if fiveReady { return "five hour limit ready" }
            return five.map { "five hour limit resets in \(UsageFormat.spokenDuration($0.timeUntilReset))" }
        case .resetClock:
            if fiveReady { return "five hour limit ready" }
            return five.map { "five hour limit resets at \(UsageFormat.clock($0.resetsAt, now: now, calendar: calendar, locale: locale))" }
        case .warningDot:
            guard let level = Self.warningDotLevel(state) else { return nil }
            return level >= .critical ? "Warning: close to a limit" : "Warning: a limit is above 70 percent"
        case .nothing:
            return nil
        }
    }
}

/// Ready-made pairs for the two ears.
public enum Face: String, Codable, Sendable, CaseIterable {
    case rings, numbers, timeFirst, bars, clock, quiet

    public var left: EarItem {
        switch self {
        case .rings: .ringPair
        case .numbers: .fiveHourPercent
        case .timeFirst: .fiveHourPercent
        case .bars: .miniBars
        case .clock: .fiveHourRing
        case .quiet: .warningDot
        }
    }

    public var right: EarItem {
        switch self {
        case .rings: .countdown
        case .numbers: .weeklyPercent
        case .timeFirst: .countdown
        case .bars: .fiveHourPercent
        case .clock: .resetClock
        case .quiet: .nothing
        }
    }

    public var title: String {
        switch self {
        case .rings: "Rings"
        case .numbers: "Numbers"
        case .timeFirst: "Time first"
        case .bars: "Bars"
        case .clock: "Clock"
        case .quiet: "Quiet"
        }
    }
}

/// Extras on the hover peek.
public struct HoverOptions: Codable, Equatable, Sendable {
    /// A tick on each bar for how much of the window's time has passed.
    public var timeTick: Bool
    /// The weekly budget ("about 14% a day") under the figures.
    public var budgetLine: Bool
    /// Reset clock times beside the countdowns.
    public var resetTimes: Bool

    public init(timeTick: Bool = true, budgetLine: Bool = false, resetTimes: Bool = false) {
        self.timeTick = timeTick
        self.budgetLine = budgetLine
        self.resetTimes = resetTimes
    }

    enum CodingKeys: String, CodingKey { case timeTick, budgetLine, resetTimes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = HoverOptions()
        timeTick = (try? c.decode(Bool.self, forKey: .timeTick)) ?? fallback.timeTick
        budgetLine = (try? c.decode(Bool.self, forKey: .budgetLine)) ?? fallback.budgetLine
        resetTimes = (try? c.decode(Bool.self, forKey: .resetTimes)) ?? fallback.resetTimes
    }
}

/// The open panel's optional sections, in order, each shown or hidden. The 5-hour and weekly
/// rows are always first and can't be moved.
public struct OpenLayout: Codable, Equatable, Sendable {
    public enum Section: String, Codable, Sendable, CaseIterable {
        case budget, byModel, credits

        public var title: String {
            switch self {
            case .budget: "Weekly budget"
            case .byModel: "Weekly by model"
            case .credits: "Usage credits"
            }
        }
    }

    public var order: [Section]
    public var hidden: Set<Section>

    public init(order: [Section] = Section.allCases, hidden: Set<Section> = []) {
        self.order = Self.normalised(order)
        self.hidden = hidden
    }

    /// The sections to draw, in order.
    public var visible: [Section] { order.filter { !hidden.contains($0) } }

    public func isShown(_ section: Section) -> Bool { !hidden.contains(section) }

    public mutating func setShown(_ section: Section, _ shown: Bool) {
        if shown { hidden.remove(section) } else { hidden.insert(section) }
    }

    public func canMove(_ section: Section, by offset: Int) -> Bool {
        guard let index = order.firstIndex(of: section) else { return false }
        return order.indices.contains(index + offset)
    }

    /// Moves a section up (-1) or down (+1); does nothing at either end.
    public mutating func move(_ section: Section, by offset: Int) {
        guard canMove(section, by: offset), let index = order.firstIndex(of: section) else { return }
        order.swapAt(index, index + offset)
    }

    /// Every section exactly once: unknown ones dropped, missing ones added at the end.
    static func normalised(_ order: [Section]) -> [Section] {
        var seen = Set<Section>()
        let known = order.filter { seen.insert($0).inserted }
        return known + Section.allCases.filter { !seen.contains($0) }
    }

    enum CodingKeys: String, CodingKey { case order, hidden }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let order = (try? c.decode([String].self, forKey: .order))?.compactMap(Section.init(rawValue:)) ?? Section.allCases
        let hidden = (try? c.decode([String].self, forKey: .hidden))?.compactMap(Section.init(rawValue:)) ?? []
        self.init(order: order, hidden: Set(hidden))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(order.map(\.rawValue), forKey: .order)
        try c.encode(hidden.map(\.rawValue).sorted(), forKey: .hidden)
    }
}
