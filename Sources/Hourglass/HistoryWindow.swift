import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UsageCore

/// The History window, from History… in the ••• menu: an ordinary Mac window, not part of the notch.
@MainActor
final class HistoryWindowController {
    private let window: NSWindow
    private let model: HistoryWindowModel

    init(history: UsageHistory, store: UsageStore) {
        model = HistoryWindowModel(history: history, store: store)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 860),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Usage History"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 860, height: 520)
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
    let store: UsageStore
    /// The day in the side panel; today until another is clicked.
    var selectedDay: Date?
    /// A past week drawn over this one, chosen by clicking its date in the calendar.
    var overlayWeek: Date?
    /// What this week is compared against, remembered between launches.
    var comparison: WeekProgress.Comparison {
        didSet { AppEnvironment.defaults.set(comparison.rawValue, forKey: Self.comparisonKey) }
    }

    static let comparisonKey = "historyComparison"

    init(history: UsageHistory, store: UsageStore) {
        self.history = history
        self.store = store
        comparison = AppEnvironment.defaults.string(forKey: Self.comparisonKey).flatMap(WeekProgress.Comparison.init(rawValue:)) ?? .lastWeek
    }

    /// Everything the weeks part of the window draws, worked out once per change.
    func snapshot(now: Date) -> WeeksSnapshot {
        WeeksSnapshot(history: history, state: store.state, comparison: comparison, now: now)
    }

    func windowOpened() { history.logs.windowOpened() }

    /// Claude Code totals, only while the log layer is on.
    var tokenRows: [HourlyTokens]? { history.logs.isEnabled && !history.logs.rows.isEmpty ? history.logs.rows : nil }

    /// "mostly hourglass, Fable" for a local day, from Claude Code's logs.
    func mostly(on day: Date) -> String? {
        guard let rows = tokenRows, let end = Calendar.current.date(byAdding: .day, value: 1, to: day) else { return nil }
        return TokenBreakdown.mostly(rows, in: DateInterval(start: day, end: end))
    }

    var heatMap: UsageHeatMap { UsageHeatMap.make(history.lines) }

    // MARK: Export

    /// Asks where to put the export, then writes a folder of CSV files there.
    func exportCSV() {
        let panel = NSSavePanel()
        panel.title = "Export usage history"
        panel.prompt = "Export"
        panel.message = "Saves a folder with your readings, days, 5-hour windows and weeks as CSV files."
        panel.nameFieldStringValue = "Usage history \(Date().formatted(.iso8601.year().month().day()))"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let lines = history.lines, windows = history.windows, weeks = history.weeks, tokens = tokenRows
        let days = DaySummaries.merge(existing: history.days, rebuilt: DaySummaries.build(from: lines))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try HistoryCSV.readings(lines).write(to: folder.appending(path: "readings.csv"), atomically: true, encoding: .utf8)
            try HistoryCSV.windows(windows).write(to: folder.appending(path: "five-hour-windows.csv"), atomically: true, encoding: .utf8)
            try HistoryCSV.weeks(weeks).write(to: folder.appending(path: "weeks.csv"), atomically: true, encoding: .utf8)
            try HistoryCSV.days(days).write(to: folder.appending(path: "days.csv"), atomically: true, encoding: .utf8)
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
                if model.history.lines.isEmpty && model.history.days.isEmpty {
                    header
                    Text("Nothing recorded yet. Each time the app checks your usage it adds a reading here.")
                        .foregroundStyle(.secondary)
                } else {
                    WeeksSection(model: model)
                    Divider()
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
            Text("Weeks").font(.title2.weight(.semibold))
            Text("How each limit week went, from reset to reset. Kept only on this Mac.")
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
