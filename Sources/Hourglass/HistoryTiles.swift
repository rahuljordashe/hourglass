import SwiftUI
import UsageCore

// The History window's weeks: a summary row, this week against a chosen comparison, and a calendar
// of tiles (one row per limit week), with a side panel for the selected day.

/// What the weeks part of the window draws.
@MainActor
struct WeeksSnapshot {
    let now: Date
    let calendar = Calendar.current
    /// Newest first, the current week (if a weekly window is open) at the top.
    let weeks: [LimitWeek]
    let days: [String: DaySummary]
    let fullPastWeeks: [LimitWeek]
    let comparison: WeekProgress.Comparison
    /// The chosen comparison, or nil until there's enough history for it.
    let band: WeekProgress.Band?
    let thisWeek: WeekChartData?
    let historyStart: Date?

    init(history: UsageHistory, state: UsageState, comparison: WeekProgress.Comparison, now: Date) {
        self.now = now
        self.comparison = comparison
        let allDays = DaySummaries.merge(existing: history.days, rebuilt: DaySummaries.build(from: history.lines))
        days = Dictionary(uniqueKeysWithValues: allDays.map { ($0.date, $0) })
        historyStart = history.historyStart
        let current = state.sevenDay.flatMap { $0.isReset ? nil : ($0.reportedPercentage, $0.resetsAt) }
        weeks = WeekProgress.weeks(lines: history.lines, summaries: history.weeks, days: allDays, current: current, now: now)
        fullPastWeeks = WeekProgress.fullPastWeeks(weeks, historyStart: historyStart)
        band = WeekProgress.band(comparison, fullPastWeeks: fullPastWeeks)

        if let week = weeks.first(where: \.isCurrent), let current {
            var data = WeekChartData(week: week, now: now, percent: current.0,
                                     style: WeekProgress.lineStyle(percent: current.0, now: now, weekEnd: week.end))
            if let band {
                let offset = now.timeIntervalSince(week.start)
                switch comparison {
                case .lastWeek:
                    data.comparison = .line(fullPastWeeks[0].curve, label: "last week")
                case .fourWeeks:
                    data.comparison = .band(band, label: "4 weeks")
                case .threeMonths:
                    data.comparison = .band(band, label: "\(band.weeks) weeks")
                }
                data.comparisonByNow = band.at(offset)?.middle
            }
            thisWeek = data
        } else {
            thisWeek = nil
        }
    }

    func isAvailable(_ comparison: WeekProgress.Comparison) -> Bool {
        fullPastWeeks.count >= comparison.minimumWeeks
    }

    func day(_ start: Date) -> DaySummary? { days[DaySummaries.key(start, calendar: calendar)] }

    func dayStarts(_ week: LimitWeek) -> [Date] { WeekProgress.dayStarts(week, calendar: calendar) }

    var today: Date { calendar.startOfDay(for: now) }
}

// MARK: - Layout

struct WeeksSection: View {
    @Bindable var model: HistoryWindowModel

    var body: some View {
        let snapshot = model.snapshot(now: Date())
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Weeks").font(.title2.weight(.semibold))
                    Text("How each limit week went, from reset to reset. Kept only on this Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                SummaryRow(snapshot: snapshot)
                ComparisonPicker(model: model, snapshot: snapshot)
                if let data = snapshot.thisWeek {
                    WeekChart(data: data, palette: .window, overlay: overlay(snapshot), showsPercentLabels: true)
                        .frame(height: 200)
                } else {
                    Text("No weekly limit open right now. The chart comes back with your next message.")
                        .foregroundStyle(.secondary)
                }
                WeekCalendar(model: model, snapshot: snapshot)
                TileKey()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            DayPanel(model: model, snapshot: snapshot)
                .frame(width: 270)
        }
    }

    private func overlay(_ snapshot: WeeksSnapshot) -> (curve: [CurvePoint], label: String)? {
        guard let end = model.overlayWeek, let week = snapshot.weeks.first(where: { $0.end == end }), !week.isCurrent else { return nil }
        return (week.curve, week.start.formatted(.dateTime.day().month(.abbreviated)))
    }
}

// MARK: - Summary

struct SummaryRow: View {
    let snapshot: WeeksSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 36) {
            figure(snapshot.thisWeek.map { UsageFormat.percent($0.percent) } ?? "Ready", caption: "this week so far")
            comparison
            let past = snapshot.weeks
            let hit = past.filter { $0.limitReachedAt != nil }.count
            figure("\(hit) of \(past.count)", caption: past.count == 1 ? "week hit the limit" : "weeks hit the limit")
        }
    }

    @ViewBuilder
    private var comparison: some View {
        let by = "by \(snapshot.now.formatted(.dateTime.weekday(.wide)))"
        if let band = snapshot.band, let week = snapshot.thisWeek?.week,
           let at = band.at(snapshot.now.timeIntervalSince(week.start)) {
            switch snapshot.comparison {
            case .lastWeek:
                figure(UsageFormat.percent(at.middle), caption: "last week \(by)")
            case .fourWeeks:
                figure(range(at.lower, at.upper), caption: "your last 4 weeks \(by)")
            case .threeMonths:
                figure(range(at.lower, at.upper), caption: "most of your last \(band.weeks) weeks \(by)")
            }
        } else {
            figure("Not yet", caption: "needs \(snapshot.comparison.minimumWeeks == 1 ? "a full week" : "\(snapshot.comparison.minimumWeeks) full weeks") of readings")
        }
    }

    private func range(_ low: Double, _ high: Double) -> String {
        Int(low.rounded()) == Int(high.rounded()) ? UsageFormat.percent(low) : "\(Int(low.rounded())) to \(UsageFormat.percent(high))"
    }

    private func figure(_ value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 30, weight: .light)).monospacedDigit()
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// "This week against" Last week, 4 weeks or 3 months. A choice stays greyed until there's enough history.
struct ComparisonPicker: View {
    @Bindable var model: HistoryWindowModel
    let snapshot: WeeksSnapshot

    var body: some View {
        HStack(spacing: 10) {
            Text("This week against").font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 0) {
                ForEach(WeekProgress.Comparison.allCases, id: \.self) { choice in
                    let available = snapshot.isAvailable(choice)
                    let selected = model.comparison == choice
                    Button {
                        model.comparison = choice
                        model.overlayWeek = nil
                    } label: {
                        Text(choice.title)
                            .font(.callout.weight(selected ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .foregroundStyle(available ? (selected ? Color.primary : .secondary) : Color.secondary.opacity(0.45))
                            .background(selected ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!available)
                    .help(available ? "" : "Needs \(choice.minimumWeeks == 1 ? "a full week" : "\(choice.minimumWeeks) full weeks") of readings")
                }
            }
            .padding(2)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

// MARK: - Calendar

struct WeekCalendar: View {
    @Bindable var model: HistoryWindowModel
    let snapshot: WeeksSnapshot

    static let tile: CGFloat = 30

    var body: some View {
        let calendar = snapshot.calendar
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 8) {
            if let first = snapshot.weeks.first {
                GridRow {
                    Text("")
                    ForEach(snapshot.dayStarts(first), id: \.self) { day in
                        Text(calendar.veryShortWeekdaySymbols[calendar.component(.weekday, from: day) - 1])
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: Self.tile)
                    }
                    Text("Total").font(.caption2).foregroundStyle(.secondary)
                }
            }
            ForEach(snapshot.weeks) { week in
                GridRow(alignment: .top) {
                    weekLabel(week)
                    ForEach(snapshot.dayStarts(week), id: \.self) { day in
                        DayTile(state: tileState(day, week: week), day: day, share: snapshot.day(day)?.share,
                                isToday: day == snapshot.today, isSelected: day == (model.selectedDay ?? snapshot.today),
                                gapDot: (snapshot.day(day)?.gapShare ?? 0) > 0) {
                            model.selectedDay = day
                        }
                    }
                    WeekTotal(week: week)
                }
            }
        }
    }

    private func weekLabel(_ week: LimitWeek) -> some View {
        let overlaid = model.overlayWeek == week.end
        return Button {
            model.overlayWeek = overlaid || week.isCurrent ? nil : week.end
        } label: {
            Text(week.start.formatted(.dateTime.day().month(.abbreviated)))
                .font(.callout.weight(overlaid ? .semibold : .regular))
                .foregroundStyle(overlaid ? Color.primary : .secondary)
                .underline(overlaid)
                .frame(width: 58, height: Self.tile, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(week.isCurrent ? "This week" : overlaid ? "Back to the comparison" : "Draw this week over this one")
    }

    private func tileState(_ day: Date, week: LimitWeek) -> DayTile.State {
        let calendar = snapshot.calendar
        if day > snapshot.today { return .toCome }
        if let hit = week.limitReachedAt {
            let hitDay = calendar.startOfDay(for: hit)
            if day == hitDay { return .limitReached }
            if day > hitDay { return .afterLimit }
        }
        guard let summary = snapshot.day(day) else { return .noReadings }
        return .used(summary.share)
    }
}

struct DayTile: View {
    enum State: Equatable {
        case used(Double)
        case limitReached, afterLimit, noReadings, toCome
    }

    let state: State
    let day: Date
    let share: Double?
    let isToday: Bool
    let isSelected: Bool
    let gapDot: Bool
    let select: () -> Void
    @SwiftUI.State private var hovering = false

    /// A day using this much of the week draws in full ink.
    static let fullInk = 25.0

    var body: some View {
        let size = WeekCalendar.tile
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        VStack(spacing: 3) {
            ZStack {
                switch state {
                case .used(let share):
                    shape.fill(Color.primary.opacity(Self.ink(share)))
                case .limitReached:
                    shape.fill(Color.red)
                case .afterLimit:
                    shape.fill(Color.primary.opacity(0.05))
                case .noReadings:
                    Stripes().clipShape(shape).overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                case .toCome:
                    shape.strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                }
                if (hovering || isSelected), let share, state != .toCome {
                    Text(UsageFormat.percent(share))
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(textOnTile)
                }
            }
            .frame(width: size, height: size)
            .overlay(alignment: .topTrailing) {
                if gapDot {
                    Circle().fill(Color.orange).frame(width: 6, height: 6).offset(x: 2, y: -2)
                }
            }
            .overlay {
                if isSelected { shape.strokeBorder(Color.accentColor, lineWidth: 2).padding(-3) }
            }
            Circle().fill(isToday ? Color.primary : .clear).frame(width: 4, height: 4)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: select)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, select)
    }

    static func ink(_ share: Double) -> Double { 0.08 + 0.82 * min(max(share, 0) / fullInk, 1) }

    private var textOnTile: Color {
        switch state {
        case .used(let share): Self.ink(share) > 0.5 ? Color(nsColor: .windowBackgroundColor) : .primary
        case .limitReached: .white
        default: .primary
        }
    }

    private var accessibilityText: String {
        let date = day.formatted(.dateTime.weekday(.wide).day().month(.wide))
        switch state {
        case .used(let share): return "\(date): \(UsageFormat.percent(share)) of the week"
        case .limitReached: return "\(date): weekly limit reached"
        case .afterLimit: return "\(date): after the limit was reached"
        case .noReadings: return "\(date): no readings"
        case .toCome: return "\(date): still to come"
        }
    }
}

/// Diagonal stripes, for a day with no readings.
struct Stripes: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 5
            }
            context.stroke(path, with: .color(.primary.opacity(0.22)), lineWidth: 1)
        }
    }
}

/// The week's final % in light numerals, and "so far", "limit Fri" or "two 5-hour hits" under it.
struct WeekTotal: View {
    let week: LimitWeek

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(week.finalPercent.map(UsageFormat.percent) ?? "?")
                .font(.system(size: 17, weight: .light))
                .monospacedDigit()
            if let note {
                Text(note.text).font(.caption2).foregroundStyle(note.red ? Color.red : .secondary)
            }
        }
        .frame(width: 92, alignment: .leading)
    }

    private var note: (text: String, red: Bool)? {
        if let hit = week.limitReachedAt { return ("limit \(hit.formatted(.dateTime.weekday(.abbreviated)))", true) }
        if week.isCurrent { return ("so far", false) }
        if week.windowsAtLimit > 0 {
            let words = ["", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
            let n = week.windowsAtLimit < words.count ? words[week.windowsAtLimit] : "\(week.windowsAtLimit)"
            return ("\(n) 5-hour \(week.windowsAtLimit == 1 ? "hit" : "hits")", false)
        }
        return nil
    }
}

struct TileKey: View {
    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 3) {
                Text("less").foregroundStyle(.secondary)
                ForEach([2.0, 8, 15, 25], id: \.self) { share in
                    swatch { RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(DayTile.ink(share))) }
                }
                Text("more of the week").foregroundStyle(.secondary)
            }
            item("limit reached") { RoundedRectangle(cornerRadius: 3).fill(Color.red) }
            item("no readings") {
                Stripes().clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.primary.opacity(0.12)))
            }
            item("some use seen after a gap") { Circle().fill(Color.orange).padding(3) }
        }
        .font(.caption)
    }

    private func swatch<S: View>(@ViewBuilder _ content: () -> S) -> some View {
        content().frame(width: 12, height: 12)
    }

    private func item<S: View>(_ text: String, @ViewBuilder _ content: () -> S) -> some View {
        HStack(spacing: 5) {
            swatch(content)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Selected day

struct DayPanel: View {
    let model: HistoryWindowModel
    let snapshot: WeeksSnapshot

    var body: some View {
        let start = model.selectedDay ?? snapshot.today
        let summary = snapshot.day(start)
        let isToday = start == snapshot.today
        VStack(alignment: .leading, spacing: 14) {
            Text(start.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
                .font(.headline)
            if let summary {
                VStack(alignment: .leading, spacing: 0) {
                    Text(UsageFormat.percent(summary.share)).font(.system(size: 44, weight: .light)).monospacedDigit()
                    Text(isToday ? "of the week so far today" : "of the week used that day").font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("5-hour windows").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    FiveHourStrip(day: start, windows: summary.fiveHourWindows)
                        .frame(height: 46)
                }
                VStack(alignment: .leading, spacing: 8) {
                    row("5-hour limit", fiveHourText(summary, day: start))
                    row(isToday ? "Week so far" : "Week by end of day", summary.weekTotalAtEnd.map(UsageFormat.percent) ?? "Not known")
                    row("Seen after a gap", summary.gapShare > 0 ? UsageFormat.percent(summary.gapShare) : "None")
                    if model.tokenRows != nil {
                        row("Claude Code", model.mostly(on: start).map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "No use logged")
                    }
                }
            } else {
                Text(start > snapshot.today ? "Still to come." : "No readings that day.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func fiveHourText(_ summary: DaySummary, day: Date) -> String {
        let end = day.addingTimeInterval(86400)
        if let hit = summary.fiveHourWindows.compactMap(\.reachedLimitAt).first(where: { $0 >= day && $0 < end }) {
            return "Hit at \(hit.formatted(.dateTime.hour().minute()))"
        }
        return "Not hit"
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }
}

/// The day's 24 hours with each 5-hour window as a block: as wide as the window, as tall as its
/// peak, red where it reached 100%.
struct FiveHourStrip: View {
    let day: Date
    let windows: [DaySummary.FiveHourWindow]

    var body: some View {
        Canvas { context, size in
            let labelHeight: CGFloat = 12
            let plot = CGRect(x: 0, y: 0, width: size.width, height: size.height - labelHeight)
            context.fill(Path(roundedRect: plot, cornerRadius: 4), with: .color(.primary.opacity(0.05)))
            for window in windows {
                let from = max(window.start.timeIntervalSince(day), 0) / 86400
                let to = min(window.end.timeIntervalSince(day), 86400) / 86400
                guard to > from else { continue }
                let height = plot.height * min(max(window.peakPercent, 3) / 100, 1)
                let rect = CGRect(x: plot.width * from, y: plot.maxY - height, width: max(2, plot.width * (to - from) - 1), height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 2),
                             with: .color(window.peakPercent >= 100 ? .red : .primary.opacity(0.55)))
            }
            for hour in [0, 6, 12, 18, 24] {
                let x = size.width * CGFloat(hour) / 24
                context.draw(Text(String(format: "%02d", hour)).font(.system(size: 9)).foregroundStyle(.secondary),
                             at: CGPoint(x: min(max(x, 7), size.width - 7), y: size.height), anchor: .bottom)
            }
        }
        .accessibilityLabel("\(windows.count) five-hour windows that day")
    }
}
