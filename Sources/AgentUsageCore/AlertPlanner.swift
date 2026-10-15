import Foundation

public struct AlertSettings: Sendable, Equatable {
    public var enabled: Bool
    /// Percent thresholds to alert on, e.g. [50, 75, 90].
    public var thresholds: [Int]
    /// Percentage points before a threshold at which an "approaching" alert fires (0 = off).
    public var approachMargin: Int
    /// Alert once per window when the current pace would exhaust the limit before it resets.
    public var predictive: Bool
    /// Alert when a limit that crossed the highest threshold resets.
    public var notifyOnReset: Bool
    public var watchedKinds: Set<UsageLimit.Kind>

    public init(enabled: Bool = true, thresholds: [Int] = [50, 75, 90], approachMargin: Int = 5,
                predictive: Bool = true, notifyOnReset: Bool = true,
                watchedKinds: Set<UsageLimit.Kind> = Set(UsageLimit.Kind.allCases)) {
        self.enabled = enabled
        self.thresholds = thresholds
        self.approachMargin = approachMargin
        self.predictive = predictive
        self.notifyOnReset = notifyOnReset
        self.watchedKinds = watchedKinds
    }
}

public struct UsageAlert: Sendable, Equatable {
    public enum Level: Sendable { case info, warning, critical }

    /// Unique per (limit window, condition) so each alert fires at most once.
    public let key: String
    public let title: String
    public let body: String
    public let level: Level
}

public enum AlertPlanner {
    /// Predictive alerts before this much usage are mostly rate noise.
    static let predictiveMinimumPercent = 20.0

    public static func plan(
        limits: [UsageLimit],
        previous: [UsageLimit],
        projections: [String: Projection],
        settings: AlertSettings,
        alreadyFired: Set<String>,
        now: Date
    ) -> [UsageAlert] {
        guard settings.enabled else { return [] }
        let thresholds = Array(Set(settings.thresholds.filter { (1...100).contains($0) })).sorted()
        var alerts: [UsageAlert] = []

        for limit in limits where settings.watchedKinds.contains(limit.kind) {
            let resetText = limit.resetsAt.map { "\(Formatting.clock($0, now: now))에 재설정 (\(Formatting.duration($0.timeIntervalSince(now))) 후)" }
            let p = limit.percent

            // Reached: only the highest crossed threshold, so a jump from 40% → 95% sends one alert.
            if let crossed = thresholds.last(where: { p >= Double($0) }) {
                let key = "\(limit.windowKey)|reached|\(crossed)"
                if !alreadyFired.contains(key) {
                    let isFull = crossed >= 100 || p >= 100
                    alerts.append(UsageAlert(
                        key: key,
                        title: isFull ? "\(limit.title) 한도 도달" : "\(limit.title) \(crossed)% 도달",
                        body: ["현재 \(Formatting.percent(p)) 사용됨.", resetText].compactMap { $0 }.joined(separator: " "),
                        level: crossed >= 90 ? .critical : .warning
                    ))
                    continue
                }
            }

            // Approaching: the next threshold above the current value, within the margin.
            if settings.approachMargin > 0,
               let next = thresholds.first(where: { Double($0) > p }),
               p >= Double(next - settings.approachMargin) {
                let key = "\(limit.windowKey)|near|\(next)"
                let reachedKeyForNext = "\(limit.windowKey)|reached|\(next)"
                if !alreadyFired.contains(key) && !alreadyFired.contains(reachedKeyForNext) {
                    alerts.append(UsageAlert(
                        key: key,
                        title: "\(limit.title) \(next)% 근접",
                        body: ["현재 \(Formatting.percent(p)) — \(next)%까지 \(Int((Double(next) - p).rounded()))%p 남았어요.", resetText]
                            .compactMap { $0 }.joined(separator: " "),
                        level: .info
                    ))
                    continue
                }
            }

            // Predictive: the current pace runs out before the reset.
            if settings.predictive, p >= predictiveMinimumPercent, p < 100,
               let projection = projections[limit.id], projection.exhaustsBeforeReset,
               let fullAt = projection.fullAt {
                let key = "\(limit.windowKey)|predict"
                if !alreadyFired.contains(key) {
                    var body = "지금 속도(시간당 +\(String(format: "%.1f", projection.ratePerHour))%p)면 \(Formatting.clock(fullAt, now: now))쯤 소진돼요."
                    if let resetsAt = limit.resetsAt {
                        body += " 재설정은 \(Formatting.clock(resetsAt, now: now))."
                    }
                    alerts.append(UsageAlert(key: key, title: "\(limit.title): 재설정 전 소진 예상", body: body, level: .warning))
                }
            }
        }

        // Reset: a limit that had crossed the top threshold started a new window.
        if settings.notifyOnReset, let top = thresholds.last {
            let currentById = Dictionary(limits.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for old in previous where settings.watchedKinds.contains(old.kind) && old.percent >= Double(top) {
                guard let current = currentById[old.id],
                      current.windowKey != old.windowKey,
                      current.percent < old.percent
                else { continue }
                let key = "\(old.windowKey)|reset"
                if !alreadyFired.contains(key) {
                    alerts.append(UsageAlert(
                        key: key,
                        title: "\(old.title) 한도 재설정됨",
                        body: "현재 \(Formatting.percent(current.percent)) 사용 중. 다시 마음껏 쓰셔도 돼요.",
                        level: .info
                    ))
                }
            }
        }

        return alerts
    }

    /// Fired keys embed the window's reset minute; drop ones whose window ended over a day ago.
    public static func prune(firedKeys: Set<String>, now: Date) -> Set<String> {
        let cutoffMinute = Int(now.addingTimeInterval(-24 * 3600).timeIntervalSince1970 / 60)
        return firedKeys.filter { key in
            guard let at = key.firstIndex(of: "@"),
                  let bar = key[at...].firstIndex(of: "|"),
                  let minute = Int(key[key.index(after: at)..<bar])
            else { return false }
            return minute >= cutoffMinute
        }
    }
}
