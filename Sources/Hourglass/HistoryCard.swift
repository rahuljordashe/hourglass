import SwiftUI
import UsageCore

/// The open panel's "Last 7 days" card: one bar per day for the share of the weekly limit used
/// that day, a dashed line at the daily budget (an even seventh of the week), and one line on the
/// biggest day. Days over budget are amber. Use that only showed up after a gap is drawn paler,
/// and a day with no readings at all is an outline, not an empty bar.
struct LastSevenDaysCard: View {
    let days: [DailyUsage.Day]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Last 7 days").font(.system(size: 12, weight: .medium))
                Spacer(minLength: 6)
                Text("dashed line: an even \(Int(DailyUsage.dailyBudget.rounded()))% a day")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.48))
            }
            DayBars(days: days, now: now)
            Text(LastSevenDays.summary(days, now: now))
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.62))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let perDay = days.map { day -> String in
            let name = LastSevenDays.dayName(day, now: now)
            guard day.hasReadings || day.total > 0 else { return "\(name): no readings" }
            return "\(name): \(Int(day.total.rounded())) percent"
        }
        return (["Last 7 days."] + perDay + [LastSevenDays.summary(days, now: now)]).joined(separator: " ")
    }
}

/// Seven bars on a shared scale, with the daily budget as a dashed line.
struct DayBars: View {
    let days: [DailyUsage.Day]
    let now: Date

    static let height: CGFloat = 46

    var body: some View {
        let scale = max(DailyUsage.dailyBudget * 1.5, days.map(\.total).max() ?? 0)
        VStack(spacing: 4) {
            ZStack(alignment: .bottom) {
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(days) { day in
                        DayBar(day: day, scale: scale)
                            .frame(maxWidth: .infinity)
                    }
                }
                GeometryReader { geo in
                    let y = geo.size.height * (1 - DailyUsage.dailyBudget / scale)
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    .stroke(Color.white.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                .allowsHitTesting(false)
            }
            .frame(height: Self.height)
            HStack(spacing: 6) {
                ForEach(days) { day in
                    Text(day.isToday ? "Today" : day.start.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color.white.opacity(day.isToday ? 0.7 : day.hasReadings ? 0.45 : 0.28))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

struct DayBar: View {
    let day: DailyUsage.Day
    let scale: Double

    var body: some View {
        let over = DailyUsage.isOverBudget(day)
        let color = over ? Theme.warning : Theme.normal.opacity(0.85)
        GeometryReader { geo in
            let h = geo.size.height
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                if day.gapPoints > 0 {
                    // Used while the app wasn't reading: by this day, but not necessarily on it.
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .strokeBorder(color.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 2, style: .continuous))
                        .frame(height: max(3, h * day.gapPoints / scale))
                }
                if day.points > 0 {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(color)
                        .frame(height: max(2, h * day.points / scale))
                } else if !day.hasReadings && day.gapPoints == 0 {
                    // No readings that day: a gap, not zero.
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        .frame(height: 8)
                } else {
                    Capsule().fill(Color.white.opacity(0.16)).frame(height: 2)
                }
            }
        }
    }
}
