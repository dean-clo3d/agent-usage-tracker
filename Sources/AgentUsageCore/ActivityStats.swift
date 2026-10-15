import Foundation

public struct TokenTotals: Sendable, Equatable {
    public var input = 0
    public var cacheCreate = 0
    public var cacheRead = 0
    public var output = 0
    public var thinking = 0
    public var requests = 0

    public init() {}

    public mutating func add(_ e: TokenEvent) {
        input += e.input
        cacheCreate += e.cacheCreate
        cacheRead += e.cacheRead
        output += e.output
        thinking += e.thinking
        requests += 1
    }

    /// Input-token-equivalent weight using Anthropic's public price ratios
    /// (cache write 1.25×, cache read 0.1×, output 5×). Plan limits aren't published
    /// per token, but they track cost far better than raw token counts do.
    public var weighted: Double {
        Double(input) + Double(cacheCreate) * 1.25 + Double(cacheRead) * 0.1 + Double(output) * 5
    }

    /// Share of prompt tokens served from cache.
    public var cacheHitRatio: Double? {
        let prompt = input + cacheCreate + cacheRead
        guard prompt > 0 else { return nil }
        return Double(cacheRead) / Double(prompt)
    }

    public var averageContext: Double? {
        guard requests > 0 else { return nil }
        return Double(input + cacheCreate + cacheRead) / Double(requests)
    }
}

public struct ModelShare: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let share: Double
}

public struct ActivityStats: Sendable, Equatable {
    public var today = TokenTotals()
    /// Totals since the current 5-hour session window opened.
    public var sessionWindow = TokenTotals()
    /// Weighted tokens per minute over the last 5 minutes.
    public var recentRatePerMinute: Double = 0
    /// Weighted tokens for each of the last 60 minutes, oldest first.
    public var perMinute: [Double] = Array(repeating: 0, count: 60)
    /// Weighted share per model family/version for today, largest first.
    public var modelShares: [ModelShare] = []
    /// Fraction of today's weighted tokens spent in subagents (sidechains).
    public var sidechainShare: Double = 0
    /// Fraction of today's output tokens that were thinking tokens.
    public var thinkingShare: Double = 0
    public var activeSessionsLastHour = 0
    public var lastEventAt: Date?

    public init() {}

    public static func compute(events: [TokenEvent], now: Date, sessionWindowStart: Date?,
                               calendar: Calendar = .current) -> ActivityStats {
        var stats = ActivityStats()
        let startOfDay = calendar.startOfDay(for: now)
        let fiveMinutesAgo = now.addingTimeInterval(-5 * 60)
        let hourAgo = now.addingTimeInterval(-60 * 60)

        var recentWeighted = 0.0
        var byModel: [String: Double] = [:]
        var sidechainWeighted = 0.0
        var sessionsLastHour = Set<String>()

        for e in events {
            var single = TokenTotals()
            single.add(e)
            let w = single.weighted

            if e.date >= startOfDay {
                stats.today.add(e)
                byModel[ModelName.display(e.model), default: 0] += w
                if e.isSidechain { sidechainWeighted += w }
            }
            if let start = sessionWindowStart, e.date >= start {
                stats.sessionWindow.add(e)
            }
            if e.date >= fiveMinutesAgo && e.date <= now {
                recentWeighted += w
            }
            if e.date >= hourAgo && e.date <= now {
                let minutesAgo = Int(now.timeIntervalSince(e.date) / 60)
                let bucket = 59 - min(max(minutesAgo, 0), 59)
                stats.perMinute[bucket] += w
                sessionsLastHour.insert(e.sessionId)
            }
            if stats.lastEventAt.map({ e.date > $0 }) ?? true {
                stats.lastEventAt = e.date
            }
        }

        stats.recentRatePerMinute = recentWeighted / 5
        let todayWeighted = stats.today.weighted
        if todayWeighted > 0 {
            stats.modelShares = byModel
                .map { ModelShare(name: $0.key, share: $0.value / todayWeighted) }
                .sorted { $0.share > $1.share }
            stats.sidechainShare = sidechainWeighted / todayWeighted
        }
        if stats.today.output > 0 {
            stats.thinkingShare = Double(stats.today.thinking) / Double(stats.today.output)
        }
        stats.activeSessionsLastHour = sessionsLastHour.count
        return stats
    }
}

public enum ModelName {
    /// "claude-opus-5-5" → "Opus 5.5", "claude-sonnet-4-5-20250929" → "Sonnet 4.5".
    public static func display(_ id: String) -> String {
        var parts = id.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        guard let family = parts.first else { return id }
        let version = parts.dropFirst()
            .filter { $0.count <= 2 && Int($0) != nil } // drop date stamps like 20250929
            .prefix(2)
            .joined(separator: ".")
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? name : "\(name) \(version)"
    }

    /// "Opus 5.5" → "Opus"
    public static func family(_ display: String) -> String {
        String(display.split(separator: " ").first ?? Substring(display))
    }
}
