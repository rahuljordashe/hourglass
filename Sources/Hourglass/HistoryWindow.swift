import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers
import UsageCore

/// The History window, from History… in the ••• menu: an ordinary Mac window, not part of the notch.
@MainActor
final class HistoryWindowController {
    private let window: NSWindow
    private let model: HistoryWindowModel

    init(history: UsageHistory) {
        model = HistoryWindowModel(history: history)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 820),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Usage History"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 480)
        window.contentView = NSHostingView(rootView: HistoryView(model: model))
        window.center()
        window.setFrameAutosaveName("UsageHistory")
    }

    func show() {
        model.windowOpened()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

/// What the window shows, worked out from the history when it changes.
@MainActor
@Observable
final class HistoryWindowModel {
    let history: UsageHistory
    var selectedDay: Date?

    init(history: UsageHistory) {
        self.history = history
    }

    func windowOpened() { history.logs.windowOpened() }

    /// Claude Code totals, only while the log layer is on.
    var tokenRows: [HourlyTokens]? { history.logs.isEnabled && !history.logs.rows.isEmpty ? history.logs.rows : nil }

    /// "mostly hourglass, Fable" for a local day, from Claude Code's logs.
    func mostly(on day: Date) -> String? {
        guard let rows = tokenRows, let end = Calendar.current.date(byAdding: .day, value: 1, to: day) else { return nil }
        return TokenBreakdown.mostly(rows, in: DateInterval(start: day, end: end))
    }

    var days: [DailyUsage.Day] { DailyUsage.days(history.lines, count: 30, now: Date()) }
    var heatMap: UsageHeatMap { UsageHeatMap.make(history.lines) }
    var pastWeeks: [WeekSummary] { history.weeks.reversed() }

    // MARK: Export

    /// Asks where to put the export, then writes a folder of CSV files there.
    func exportCSV() {
        let panel = NSSavePanel()
        panel.title = "Export usage history"
        panel.prompt = "Export"
        panel.message = "Saves a folder with your readings, 5-hour windows and weeks as CSV files."
        panel.nameFieldStringValue = "Usage history \(Date().formatted(.iso8601.year().month().day()))"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let lines = history.lines, windows = history.windows, weeks = history.weeks, tokens = tokenRows
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try HistoryCSV.readings(lines).write(to: folder.appending(path: "readings.csv"), atomically: true, encoding: .utf8)
            try HistoryCSV.windows(windows).write(to: folder.appending(path: "five-hour-windows.csv"), atomically: true, encoding: .utf8)
            try HistoryCSV.weeks(weeks).write(to: folder.appending(path: "weeks.csv"), atomically: true, encoding: .utf8)
            if let tokens {
                try HistoryCSV.hourlyTokens(tokens).write(to: folder.appending(path: "claude-code-tokens.csv"), atomically: true, encoding: .utf8)
            }
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't export the history"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

// MARK: - Window content

struct HistoryView: View {
    let model: HistoryWindowModel

    var body: some View {
        ScrollView { HistoryContent(model: model) }
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Everything in the window, unscrolled (also drawn on its own for `--render-previews`).
struct HistoryContent: View {
    let model: HistoryWindowModel

    var body: some View {
            VStack(alignment: .leading, spacing: 28) {
                header
                if model.history.lines.isEmpty {
                    Text("Nothing recorded yet. Each time the app checks your usage it adds a reading here.")
                        .foregroundStyle(.secondary)
                } else {
                    ThirtyDaysSection(model: model)
                    PastWeeksSection(weeks: model.pastWeeks, tokens: model.tokenRows)
                    HeatMapSection(map: model.heatMap)
                }
                LogLayerSection(model: model)
                footer
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Usage history").font(.title2.weight(.semibold))
            Text("Kept only on this Mac. Raw readings for 90 days, weekly and 5-hour summaries for good.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            if let first = model.history.lines.first {
                Text("\(model.history.lines.count) readings since \(first.time.formatted(.dateTime.day().month(.wide)))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Export CSV…") { model.exportCSV() }
                .disabled(model.history.lines.isEmpty)
        }
    }
}

struct SectionTitle: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            if let detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
        }
    }
}

// MARK: - Last 30 days

struct ThirtyDaysSection: View {
    @Bindable var model: HistoryWindowModel

    var body: some View {
        let days = model.days
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Last 30 days", detail: "Share of the weekly limit used each day. The dashed line is an even seventh of the week.")
            Chart {
                ForEach(days) { day in
                    if !day.hasReadings && day.total == 0 {
                        RectangleMark(x: .value("Day", day.start, unit: .day), yStart: .value("Used", 0), yEnd: .value("Used", 4))
                            .foregroundStyle(.gray.opacity(0.18))
                    }
                    BarMark(x: .value("Day", day.start, unit: .day), y: .value("Used", day.points))
                        .foregroundStyle(by: .value("Kind", "Used"))
                    BarMark(x: .value("Day", day.start, unit: .day), y: .value("Used", day.gapPoints))
                        .foregroundStyle(by: .value("Kind", "Seen after a gap"))
                }
                RuleMark(y: .value("Daily budget", DailyUsage.dailyBudget))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary)
                if let selected = model.selectedDay {
                    RuleMark(x: .value("Day", selected, unit: .day))
                        .foregroundStyle(.secondary.opacity(0.4))
                }
            }
            .chartForegroundStyleScale(["Used": Color.accentColor, "Seen after a gap": Color.accentColor.opacity(0.35)])
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v))%") } }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .chartXSelection(value: $model.selectedDay)
            .frame(height: 200)

            let day = selectedOrBiggest(days)
            DayDetail(day: day, isSelected: model.selectedDay != nil, mostly: day.flatMap { model.mostly(on: $0.start) })
            if model.tokenRows != nil {
                SpikeLines(days: days, model: model)
            }
            Text("A grey block is a day with no readings. The faded top of a bar is use that only showed up after a gap in readings, such as the Mac being asleep.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func selectedOrBiggest(_ days: [DailyUsage.Day]) -> DailyUsage.Day? {
        if let selected = model.selectedDay {
            return days.first { Calendar.current.isDate($0.start, inSameDayAs: selected) }
        }
        return days.max { $0.total < $1.total }.flatMap { $0.total > 0 ? $0 : nil }
    }
}

struct DayDetail: View {
    let day: DailyUsage.Day?
    let isSelected: Bool
    var mostly: String?

    var body: some View {
        if let day {
            VStack(alignment: .leading, spacing: 2) {
                Text(headline(day)).font(.callout.weight(.medium))
                if let mostly {
                    Text("In Claude Code, \(mostly).").font(.callout).foregroundStyle(.secondary)
                }
                if day.gapPoints > 0 {
                    Text("\(LastSevenDays.percent(day.gapPoints)) of it showed up after a gap in readings, so some may be from earlier.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func headline(_ day: DailyUsage.Day) -> String {
        let date = day.start.formatted(.dateTime.weekday(.wide).day().month(.wide))
        guard day.hasReadings || day.total > 0 else { return "\(date): no readings." }
        let prefix = isSelected ? "" : "Biggest day: "
        let verdict = DailyUsage.isOverBudget(day) ? "over the daily budget" : "within the daily budget"
        return "\(prefix)\(date) used \(LastSevenDays.percent(day.total)) of the week, \(verdict)."
    }
}

/// Under the chart, with the log layer on: what the biggest days over budget were mostly spent on.
struct SpikeLines: View {
    let days: [DailyUsage.Day]
    let model: HistoryWindowModel

    var body: some View {
        let spikes = days.filter(DailyUsage.isOverBudget).sorted { $0.total > $1.total }.prefix(3)
        if !spikes.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(spikes)) { day in
                    Text("\(day.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))), \(LastSevenDays.percent(day.total)): \(model.mostly(on: day.start) ?? "no Claude Code use logged")")
                        .font(.callout)
                }
                Text("Claude Code only: the logs can't see the Claude app, web or phone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Past weeks

struct PastWeeksSection: View {
    let weeks: [WeekSummary]
    var tokens: [HourlyTokens]?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Past weeks")
            if weeks.isEmpty {
                Text("Each week shows here once it resets.").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow {
                        Text("Week")
                        Text("Final")
                        Text("Limit reached")
                        Text("5-hour limits hit")
                        Text("Credits spent")
                        if tokens != nil { Text("In Claude Code") }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    Divider()
                    ForEach(weeks, id: \.end) { week in
                        GridRow {
                            Text(range(week))
                            Text(UsageFormat.percent(week.finalPercent)).monospacedDigit()
                            Text(week.limitReachedAt.map { $0.formatted(.dateTime.weekday(.wide).hour().minute()) } ?? "No")
                            Text("\(week.windowsAtLimit)").monospacedDigit()
                            Text(credits(week)).monospacedDigit()
                            if let tokens {
                                Text(TokenBreakdown.mostly(tokens, in: DateInterval(start: week.start, end: week.end)) ?? "No use logged")
                            }
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }

    private func range(_ week: WeekSummary) -> String {
        let style = Date.FormatStyle.dateTime.day().month(.abbreviated)
        return "\(week.start.formatted(style)) to \(week.end.formatted(style))"
    }

    private func credits(_ week: WeekSummary) -> String {
        guard let spent = week.creditsSpent else { return "Not known" }
        return spent > 0 ? UsageFormat.money(spent, currency: week.currency ?? "USD") : "None"
    }
}

// MARK: - When you use it

struct HeatMapSection: View {
    let map: UsageHeatMap

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "When you use it", detail: "Average share of the weekly limit used, by weekday and two-hour slot.")
            if map.isReady {
                grid
            } else {
                Text("Shows once there are \(UsageHeatMap.minimumDays) days of readings (\(map.daysWithReadings) so far).")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var grid: some View {
        let calendar = Calendar.current
        let weekdays = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
        let highest = max(map.highest, 0.1)
        return Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            GridRow {
                Text("")
                ForEach(0..<UsageHeatMap.slots, id: \.self) { slot in
                    Text(String(format: "%02d", slot * 2)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            ForEach(weekdays, id: \.self) { weekday in
                GridRow {
                    Text(calendar.shortWeekdaySymbols[weekday - 1]).font(.caption).foregroundStyle(.secondary)
                        .gridColumnAlignment(.leading)
                    ForEach(0..<UsageHeatMap.slots, id: \.self) { slot in
                        let value = map.cells[weekday - 1][slot]
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(value.map { Color.accentColor.opacity(0.08 + 0.92 * min($0 / highest, 1)) } ?? Color.gray.opacity(0.1))
                            .frame(height: 22)
                            .help(value.map { String(format: "%.1f%% of the week on average", $0) } ?? "No readings on this day yet")
                    }
                }
            }
        }
    }
}

// MARK: - Claude Code log layer

struct LogLayerSection: View {
    let model: HistoryWindowModel

    var body: some View {
        let logs = model.history.logs
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Claude Code")
            Toggle("Explain spikes using Claude Code's session logs", isOn: Binding(
                get: { logs.isEnabled },
                set: { logs.setEnabled($0) }))
            Text("Reads only the time, model, token counts and project folder name of each reply in ~/.claude/projects, never your messages. Totals per hour stay on this Mac for 90 days. It covers Claude Code only, not the Claude app, web or phone, and Claude Code keeps about 30 days of logs, so that's as far back as it can go.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if logs.formatChanged {
                Label("Claude Code's log format changed, so this switched itself off rather than show wrong numbers.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else if logs.isEnabled {
                status(logs)
                if let rows = model.tokenRows { ThisWeek(rows: rows) }
            }
        }
    }

    private func status(_ logs: ClaudeCodeLogLayer) -> some View {
        let text: String = if logs.isReading {
            "Reading Claude Code's logs…"
        } else if let last = logs.lastScan {
            "Last read \(last.formatted(.relative(presentation: .named)))."
        } else {
            "Not read yet."
        }
        return Text(text).font(.callout).foregroundStyle(.secondary)
    }
}

/// The last seven days' top projects and models in Claude Code.
struct ThisWeek: View {
    let rows: [HourlyTokens]

    var body: some View {
        let interval = DateInterval(start: Date().addingTimeInterval(-7 * 86400), end: Date())
        let top = TokenBreakdown.top(rows, in: interval)
        if top.projects.isEmpty {
            Text("No Claude Code use in the last 7 days.").font(.callout).foregroundStyle(.secondary)
        } else {
            HStack(alignment: .top, spacing: 40) {
                column("Projects, last 7 days", top.projects)
                column("Models, last 7 days", top.models)
            }
        }
    }

    private func column(_ title: String, _ shares: [TokenBreakdown.Share]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(shares.prefix(5), id: \.name) { share in
                HStack {
                    Text(share.name)
                    Spacer(minLength: 12)
                    Text("\(Int((share.fraction * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
        .frame(maxWidth: 240)
    }
}
