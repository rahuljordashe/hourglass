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

/// x: the limit week from reset to reset, split at local midnights, each day labelled with its weekday
/// initial and today's stretch faintly lit. y: 0 to 100% of the weekly limit, faint lines at 0, 50 and 100.
/// Dashed diagonal: an even pace, quieter after now. Faded: the comparison.
/// Bold: this week so far over a faint fill, ending in a dot at now with a dotted hairline down to the axis.
struct WeekChart: View {
    let data: WeekChartData
    var palette: WeekChartPalette = .notch
    /// A past week drawn over this one (the History window's calendar), labelled with its date.
    var overlay: (curve: [CurvePoint], label: String)?
    /// The History window's % labels down the left. Without them, 50% and 100% are marked inside on the right.
    var showsPercentLabels = false

    var body: some View {
        Canvas { context, size in
            let left: CGFloat = showsPercentLabels ? 34 : 0
            let top: CGFloat = 5
            let bottom = size.height - palette.labelSize - 6
            let plot = CGRect(x: left, y: top, width: max(1, size.width - 1 - left), height: max(1, bottom - top))
            let length = WeekProgress.length
            let nowOffset = min(max(data.now.timeIntervalSince(data.week.start), 0), length)
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
            let color = palette.color(data.style)
            let calendar = Calendar.current
            let days = WeekProgress.chartDays(data.week, now: data.now, calendar: calendar)

            // Today's stretch, faintly lit.
            if let today = days.first(where: \.isToday) {
                let rect = CGRect(x: point(today.from, 0).x, y: plot.minY - 3,
                                  width: point(today.to, 0).x - point(today.from, 0).x, height: plot.height + 3)
                context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(ink.opacity(0.04)))
            }

            // Faint lines at 0, 50 and 100%.
            for level in [0.0, 50, 100] {
                var p = Path()
                p.move(to: point(0, level)); p.addLine(to: point(length, level))
                context.stroke(p, with: .color(ink.opacity(level == 0 ? 0.22 : 0.08)), lineWidth: 1)
                if showsPercentLabels {
                    context.draw(Text("\(Int(level))%").font(.system(size: palette.labelSize)).foregroundStyle(ink.opacity(0.5)),
                                 at: CGPoint(x: left - 6, y: point(0, level).y), anchor: .trailing)
                } else if level > 0 {
                    context.draw(Text("\(Int(level))%").font(.system(size: 8.5)).foregroundStyle(ink.opacity(0.34)),
                                 at: CGPoint(x: plot.maxX - 1, y: point(0, level).y + 3), anchor: .topTrailing)
                }
            }

            // Day ticks at local midnights, each day's initial centred on its stretch (today's brighter).
            for day in days {
                let x = point(day.from, 0).x
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: plot.maxY)); tick.addLine(to: CGPoint(x: x, y: plot.maxY + 3))
                context.stroke(tick, with: .color(ink.opacity(0.25)), lineWidth: 1)
                guard day.isLabelled else { continue }
                let initial = String(calendar.veryShortWeekdaySymbols[day.weekday - 1])
                context.draw(Text(initial).font(.system(size: palette.labelSize, weight: day.isToday ? .semibold : .regular))
                                .foregroundStyle(ink.opacity(day.isToday ? 0.9 : 0.42)),
                             at: CGPoint(x: (x + point(day.to, 0).x) / 2, y: plot.maxY + 3), anchor: .top)
            }

            // This week so far, filled faintly down to 0%.
            if let first = data.week.curve.first, let last = data.week.curve.last {
                var fill = path(data.week.curve)
                fill.addLine(to: point(last.offset, 0)); fill.addLine(to: point(first.offset, 0)); fill.closeSubpath()
                context.fill(fill, with: .color(color.opacity(0.08)))
            }

            // Even pace: firmer up to now, quieter after.
            let paceNow = point(nowOffset, nowOffset / length * 100)
            for (from, to, opacity) in [(point(0, 0), paceNow, 0.4), (paceNow, point(length, 100), 0.16)] {
                var pace = Path()
                pace.move(to: from); pace.addLine(to: to)
                context.stroke(pace, with: .color(ink.opacity(opacity)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }

            // Now: a dotted hairline from under the dot down to the axis.
            let dot = data.week.curve.last.map { point($0.offset, $0.percent) }
            if let dot, plot.maxY - (dot.y + 5) > 1 {
                var hairline = Path()
                hairline.move(to: CGPoint(x: dot.x, y: dot.y + 5)); hairline.addLine(to: CGPoint(x: dot.x, y: plot.maxY))
                context.stroke(hairline, with: .color(ink.opacity(0.28)), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1.5, 2.5]))
            }

            // The comparison, labelled inside the plot near its right end, clear of the other lines.
            let labelX = plot.minX + plot.width * 0.89
            let labelOffset = length * 0.89
            func label(_ text: String, on curve: [CurvePoint], opacity: Double) {
                guard let value = WeekProgress.value(curve, at: labelOffset) else { return }
                var others = [Double(point(labelOffset, labelOffset / length * 100).y)]
                if let last = data.week.curve.last, last.offset >= labelOffset,
                   let mine = WeekProgress.value(data.week.curve, at: labelOffset) {
                    others.append(Double(point(labelOffset, mine).y))
                }
                let baseline = WeekProgress.comparisonLabelBaseline(lineY: Double(point(labelOffset, value).y), avoiding: others,
                                                                    plotTop: Double(plot.minY), plotBottom: Double(plot.maxY),
                                                                    labelHeight: Double(palette.labelSize))
                context.draw(Text(text).font(.system(size: palette.labelSize)).foregroundStyle(ink.opacity(opacity)),
                             at: CGPoint(x: labelX, y: CGFloat(baseline)), anchor: .bottomTrailing)
            }
            switch data.comparison {
            case .line(let curve, let text):
                context.stroke(path(curve), with: .color(ink.opacity(0.32)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                label(text, on: curve, opacity: 0.5)
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
                label(text, on: middle, opacity: 0.5)
            case nil:
                break
            }
            if let overlay {
                context.stroke(path(overlay.curve), with: .color(ink.opacity(0.6)),
                               style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [5, 2.5]))
                label(overlay.label, on: overlay.curve, opacity: 0.75)
            }

            // This week so far.
            context.stroke(path(data.week.curve), with: .color(color), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            if let dot {
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
