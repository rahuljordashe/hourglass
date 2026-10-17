import SwiftUI
import UsageCore

/// This limit week against an even pace and a comparison: what the open panel's "This week" card
/// and the History window's chart both draw.
struct WeekChartData {
    enum Comparison {
        /// One past week's running total, labelled at its end ("last week", "8 Oct").
        case line([CurvePoint], label: String)
        /// A band with its middle line (average or median).
        case band(WeekProgress.Band, label: String)
    }

    var week: LimitWeek
    var now: Date
    var percent: Double
    var style: WeekProgress.LineStyle
    var comparison: Comparison?
    /// The comparison's value at this point of the week, for the sentences.
    var comparisonByNow: Double?

    /// The current week (if a weekly window is open) and how it compares with the week before.
    @MainActor
    static func thisWeek(history: UsageHistory, state: UsageState, now: Date) -> (data: WeekChartData, weeks: [LimitWeek])? {
        guard let weekly = state.sevenDay, !weekly.isReset else { return nil }
        let weeks = WeekProgress.weeks(lines: history.lines, summaries: history.weeks, days: history.days,
                                       current: (weekly.reportedPercentage, weekly.resetsAt), now: now)
        guard let week = weeks.first(where: \.isCurrent) else { return nil }
        var data = WeekChartData(week: week, now: now, percent: weekly.reportedPercentage,
                                 style: WeekProgress.lineStyle(percent: weekly.reportedPercentage, now: now, weekEnd: week.end))
        // Last week, only once there's a whole one recorded.
        let full = WeekProgress.fullPastWeeks(weeks, historyStart: history.historyStart)
        if let last = full.first, abs(last.end.timeIntervalSince(week.start)) < 300 {
            data.comparison = .line(last.curve, label: "last week")
            data.comparisonByNow = WeekProgress.value(last.curve, at: now.timeIntervalSince(week.start))
        }
        return (data, weeks)
    }
}

/// Colours for the chart, so the same drawing works in the dark notch and a light or dark window.
struct WeekChartPalette {
    var ink: Color
    var line: Color
    var ahead: Color
    var limit: Color
    var labelSize: CGFloat = 9.5

    static let notch = WeekChartPalette(ink: .white, line: Theme.normal, ahead: Theme.warning, limit: Theme.critical)
    static let window = WeekChartPalette(ink: .primary, line: .primary, ahead: .orange, limit: .red, labelSize: 11)

    func color(_ style: WeekProgress.LineStyle) -> Color {
        switch style {
        case .normal: line
        case .ahead: ahead
        case .limit: limit
        }
    }
}

/// x: the limit week from reset to reset, a tick per day labelled with its weekday initial (today's
/// brighter). y: 0 to 100% of the weekly limit, faint lines at 0, 50 and 100. Dashed diagonal: an
/// even pace. Faded: the comparison. Bold: this week so far, ending in a dot at now.
struct WeekChart: View {
    let data: WeekChartData
    var palette: WeekChartPalette = .notch
    /// A past week drawn over this one (the History window's calendar), labelled with its date.
    var overlay: (curve: [CurvePoint], label: String)?
    var showsPercentLabels = false

    var body: some View {
        Canvas { context, size in
            let left: CGFloat = showsPercentLabels ? 34 : 0
            let right: CGFloat = palette.labelSize * 6 // room for "last week"
            let bottom: CGFloat = palette.labelSize + 6
            let plot = CGRect(x: left, y: 4, width: max(1, size.width - left - right), height: max(1, size.height - bottom - 4))
            let length = WeekProgress.length
            func point(_ offset: TimeInterval, _ percent: Double) -> CGPoint {
                CGPoint(x: plot.minX + plot.width * min(max(offset / length, 0), 1),
                        y: plot.maxY - plot.height * min(max(percent / 100, 0), 1.0))
            }
            func path(_ curve: [CurvePoint]) -> Path {
                var p = Path()
                for (i, c) in curve.enumerated() {
                    if i == 0 { p.move(to: point(c.offset, c.percent)) } else { p.addLine(to: point(c.offset, c.percent)) }
                }
                return p
            }
            let ink = palette.ink

            // Faint lines at 0, 50 and 100%.
            for level in [0.0, 50, 100] {
                var p = Path()
                p.move(to: point(0, level)); p.addLine(to: point(length, level))
                context.stroke(p, with: .color(ink.opacity(level == 0 ? 0.22 : 0.1)), lineWidth: 1)
                if showsPercentLabels {
                    context.draw(Text("\(Int(level))%").font(.system(size: palette.labelSize)).foregroundStyle(ink.opacity(0.5)),
                                 at: CGPoint(x: left - 6, y: point(0, level).y), anchor: .trailing)
                }
            }

            // Day ticks.
            let calendar = Calendar.current
            for day in 0..<7 {
                let offset = Double(day) * 86400
                let start = data.week.start.addingTimeInterval(offset)
                let isToday = start <= data.now && data.now < start.addingTimeInterval(86400)
                let x = point(offset, 0).x
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: plot.maxY)); tick.addLine(to: CGPoint(x: x, y: plot.maxY + 3))
                context.stroke(tick, with: .color(ink.opacity(0.25)), lineWidth: 1)
                // Each 24 hours from the reset is labelled with the weekday at its middle.
                let middle = start.addingTimeInterval(43200)
                let initial = String(calendar.veryShortWeekdaySymbols[calendar.component(.weekday, from: middle) - 1])
                context.draw(Text(initial).font(.system(size: palette.labelSize, weight: isToday ? .semibold : .regular))
                                .foregroundStyle(ink.opacity(isToday ? 0.9 : 0.42)),
                             at: CGPoint(x: x + plot.width / 14, y: plot.maxY + 3), anchor: .top)
            }

            // Even pace.
            var pace = Path()
            pace.move(to: point(0, 0)); pace.addLine(to: point(length, 100))
            context.stroke(pace, with: .color(ink.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            // The comparison.
            func label(_ text: String, at end: CGPoint, opacity: Double) {
                context.draw(Text(text).font(.system(size: palette.labelSize)).foregroundStyle(ink.opacity(opacity)),
                             at: CGPoint(x: end.x + 4, y: end.y), anchor: .leading)
            }
            switch data.comparison {
            case .line(let curve, let text):
                context.stroke(path(curve), with: .color(ink.opacity(0.32)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                if let last = curve.last { label(text, at: point(length, WeekProgress.value(curve, at: length) ?? last.percent), opacity: 0.5) }
            case .band(let band, let text):
                var area = Path()
                for (i, o) in band.offsets.enumerated() {
                    if i == 0 { area.move(to: point(o, band.upper[i])) } else { area.addLine(to: point(o, band.upper[i])) }
                }
                for (i, o) in band.offsets.enumerated().reversed() { area.addLine(to: point(o, band.lower[i])) }
                area.closeSubpath()
                context.fill(area, with: .color(ink.opacity(0.1)))
                let middle = zip(band.offsets, band.middle).map { CurvePoint(offset: $0, percent: $1) }
                context.stroke(path(middle), with: .color(ink.opacity(0.32)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                if let end = band.middle.last { label(text, at: point(length, end), opacity: 0.5) }
            case nil:
                break
            }
            if let overlay {
                context.stroke(path(overlay.curve), with: .color(ink.opacity(0.6)),
                               style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [5, 2.5]))
                label(overlay.label, at: point(length, WeekProgress.value(overlay.curve, at: length) ?? 0), opacity: 0.75)
            }

            // This week so far.
            let color = palette.color(data.style)
            context.stroke(path(data.week.curve), with: .color(color), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            if let last = data.week.curve.last {
                let dot = point(last.offset, last.percent)
                context.fill(Path(ellipseIn: CGRect(x: dot.x - 3.5, y: dot.y - 3.5, width: 7, height: 7)), with: .color(color))
            }
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = ["This week \(UsageFormat.percent(data.percent)) of the weekly limit."]
        if let by = data.comparisonByNow { parts.append("Last week was at \(UsageFormat.percent(by)) by now.") }
        return parts.joined(separator: " ")
    }
}

/// The open panel's "This week" card: header with the pace, the chart, and one line under it.
struct ThisWeekCard: View {
    let data: WeekChartData

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("This week").font(.system(size: 12, weight: .medium))
                Spacer(minLength: 6)
                Text(WeekProgress.header(percent: data.percent, now: data.now, weekEnd: data.week.end))
                    .font(.system(size: 11))
                    .foregroundStyle(data.style == .limit ? Theme.critical : Color.white.opacity(0.55))
            }
            WeekChart(data: data)
                .frame(height: 92)
            if let sentence = WeekProgress.sentence(limitReachedAt: data.percent >= 100 ? data.week.limitReachedAt ?? data.now : nil,
                                                    weekEnd: data.week.end, lastWeekByNow: data.comparisonByNow) {
                Text(sentence)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
