import Foundation

public struct UsageSample: Sendable, Equatable {
    public let date: Date
    public let percent: Double

    public init(date: Date, percent: Double) {
        self.date = date
        self.percent = percent
    }
}

public struct Projection: Sendable, Equatable {
    /// Percentage points per hour.
    public let ratePerHour: Double
    /// When the limit would hit 100% at the current pace (nil if pace is ~zero).
    public let fullAt: Date?
    /// True when `fullAt` comes before the window resets.
    public let exhaustsBeforeReset: Bool
    /// Whether the rate came from recent samples (true) or the window-wide average (false).
    public let isRecent: Bool
}

public enum Projector {
    /// Minimum span of recent samples needed before trusting a short-term rate.
    /// The API reports whole percents, so shorter spans are dominated by rounding.
    static let minimumRecentSpan: TimeInterval = 15 * 60
    static let recentLookback: TimeInterval = 60 * 60
    static let minimumWindowElapsed: TimeInterval = 10 * 60

    public static func project(limit: UsageLimit, samples: [UsageSample], now: Date) -> Projection? {
        guard limit.percent < 100 else {
            return Projection(ratePerHour: 0, fullAt: now, exhaustsBeforeReset: true, isRecent: false)
        }

        var rate: Double?
        var isRecent = false

        // 1) Recent pace: oldest vs newest sample in the last hour of this window.
        let recent = samples.filter { now.timeIntervalSince($0.date) <= recentLookback }
        if let first = recent.first, let last = recent.last {
            let span = last.date.timeIntervalSince(first.date)
            if span >= minimumRecentSpan, last.percent >= first.percent {
                rate = (last.percent - first.percent) / (span / 3600)
                isRecent = true
            }
        }

        // 2) Fallback: average pace since the window opened.
        if rate == nil, let start = limit.windowStart {
            let elapsed = now.timeIntervalSince(start)
            if elapsed >= minimumWindowElapsed {
                rate = limit.percent / (elapsed / 3600)
            }
        }

        guard let rate else { return nil }
        guard rate > 0.01 else {
            return Projection(ratePerHour: 0, fullAt: nil, exhaustsBeforeReset: false, isRecent: isRecent)
        }
        let fullAt = now.addingTimeInterval((100 - limit.percent) / rate * 3600)
        let beforeReset = limit.resetsAt.map { fullAt < $0 } ?? false
        return Projection(ratePerHour: rate, fullAt: fullAt, exhaustsBeforeReset: beforeReset, isRecent: isRecent)
    }
}
