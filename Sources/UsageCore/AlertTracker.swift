import Foundation

public struct UsageAlert: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case threshold(Double)
        case reset
    }

    public var window: UsageWindowKind
    public var kind: Kind
    public var percentage: Double
    public var resetsAt: Date

    public init(window: UsageWindowKind, kind: Kind, percentage: Double, resetsAt: Date) {
        self.window = window
        self.kind = kind
        self.percentage = percentage
        self.resetsAt = resetsAt
    }

    public var id: String {
        switch kind {
        case .threshold(let t): "\(window.rawValue)-\(Int(resetsAt.timeIntervalSince1970))-\(Int(t))"
        case .reset: "\(window.rawValue)-\(Int(resetsAt.timeIntervalSince1970))-reset"
        }
    }

    public var title: String {
        switch kind {
        case .threshold(100): "\(window.title) limit reached"
        case .threshold(let t): "\(window.title) usage passed \(Int(t))%"
        case .reset: "\(window.title) limit has reset"
        }
    }
}

/// Decides when to drop the notch down with an alert: once per threshold per window period,
/// never on every update, and never for crossings that happened before the app was watching.
public struct AlertTracker: Sendable {
    public static let thresholds: [Double] = [75, 90, 100]
    /// A reset only alerts if it is noticed this soon after it happens (not hours later on wake).
    public static let resetAlertWindow: TimeInterval = 5 * 60

    /// Ids of alerts already shown or deliberately skipped.
    public private(set) var fired: Set<String>
    private var seeded = false
    private var lastSeenReset: [UsageWindowKind: Bool] = [:]

    public init(fired: Set<String> = []) {
        self.fired = fired
    }

    /// Feed every new state. Returns at most one alert to show (the most important one).
    public mutating func process(_ state: UsageState, now: Date) -> UsageAlert? {
        var candidates: [UsageAlert] = []

        for kind in UsageWindowKind.allCases {
            guard let status = state.window(kind) else { continue }
            let wasReset = lastSeenReset[kind]
            lastSeenReset[kind] = status.isReset

            if status.isReset {
                let alert = UsageAlert(window: kind, kind: .reset, percentage: 0, resetsAt: status.resetsAt)
                let justHappened = now.timeIntervalSince(status.resetsAt) < Self.resetAlertWindow
                if seeded, wasReset == false, justHappened, status.reportedPercentage > 0, !fired.contains(alert.id) {
                    candidates.append(alert)
                }
                fired.insert(alert.id)
                continue
            }

            let crossed = Self.thresholds.filter { status.percentage >= $0 }
            let newlyCrossed = crossed.filter {
                !fired.contains(UsageAlert(window: kind, kind: .threshold($0), percentage: 0, resetsAt: status.resetsAt).id)
            }
            for t in newlyCrossed {
                fired.insert(UsageAlert(window: kind, kind: .threshold(t), percentage: 0, resetsAt: status.resetsAt).id)
            }
            if seeded, let top = newlyCrossed.max() {
                candidates.append(UsageAlert(window: kind, kind: .threshold(top), percentage: status.percentage, resetsAt: status.resetsAt))
            }
        }

        seeded = true
        pruneFired(now: now)
        return candidates.max { priority($0) < priority($1) }
    }

    private func priority(_ alert: UsageAlert) -> Double {
        let windowWeight = alert.window == .sevenDay ? 0.5 : 0
        switch alert.kind {
        case .threshold(let t): return t + windowWeight
        case .reset: return 1 + windowWeight
        }
    }

    /// Ids embed the window's reset time, so anything for windows that ended over a week ago is dead weight.
    private mutating func pruneFired(now: Date) {
        let cutoff = now.timeIntervalSince1970 - 8 * 24 * 3600
        fired = fired.filter { id in
            let parts = id.split(separator: "-")
            guard parts.count >= 2, let ts = Double(parts[1]) else { return false }
            return ts > cutoff
        }
    }
}
