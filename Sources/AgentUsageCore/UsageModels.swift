import Foundation

// MARK: - Wire format of GET https://api.anthropic.com/api/oauth/usage
//
// The endpoint returns many nullable, code-named fields. Only the ones we use are
// decoded; everything is optional so unknown/renamed fields never break decoding.

public struct UsageResponse: Decodable, Sendable {
    public var fiveHour: Window?
    public var sevenDay: Window?
    public var limits: [LimitEntry]?
    public var weeklyScopedShares: [ScopedShare]?

    public struct Window: Decodable, Sendable {
        public var utilization: Double?
        public var resetsAt: String?
    }

    public struct LimitEntry: Decodable, Sendable {
        public var kind: String
        public var group: String?
        public var percent: Double?
        public var severity: String?
        public var resetsAt: String?
        public var scope: Scope?
        public var isActive: Bool?
    }

    public struct Scope: Decodable, Sendable {
        public var model: Named?
        public var surface: Named?
    }

    /// `{ "display_name": "Fable" }`, or a bare string in case the API ever flattens it.
    public struct Named: Decodable, Sendable {
        public var displayName: String?

        enum CodingKeys: String, CodingKey { case displayName, id }

        public init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(), let s = try? single.decode(String.self) {
                displayName = s
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            displayName = (try? c.decodeIfPresent(String.self, forKey: .displayName))
                ?? (try? c.decodeIfPresent(String.self, forKey: .id))
        }
    }

    public struct ScopedShare: Decodable, Sendable {
        public var limitIndex: Int
        public var usedPercentOfWeekly: Double?
        public var allowancePercentOfWeekly: Double?
    }

    public static func decode(_ data: Data) throws -> UsageResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(UsageResponse.self, from: data)
    }
}

// MARK: - Domain model

public struct UsageLimit: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case session        // rolling 5-hour window
        case weeklyAll      // 7-day, all models
        case weeklyScoped   // 7-day, a specific model/surface (e.g. Fable)
        case other
    }

    public let id: String
    public let kind: Kind
    /// Long label for the panel, e.g. "현재 세션", "주간 · 모든 모델", "주간 · Fable".
    public let title: String
    /// Compact label for the menu bar / notifications, e.g. "세션", "주간", "Fable".
    public let shortTitle: String
    public let percent: Double
    public let resetsAt: Date?
    public let severity: String?
    /// Share of the weekly-all budget this scoped limit has used / may use (scoped limits only).
    public let usedOfWeekly: Double?
    public let allowanceOfWeekly: Double?

    public init(
        id: String, kind: Kind, title: String, shortTitle: String, percent: Double,
        resetsAt: Date?, severity: String? = nil, usedOfWeekly: Double? = nil, allowanceOfWeekly: Double? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.shortTitle = shortTitle
        self.percent = percent
        self.resetsAt = resetsAt
        self.severity = severity
        self.usedOfWeekly = usedOfWeekly
        self.allowanceOfWeekly = allowanceOfWeekly
    }

    /// Length of the rolling window this limit measures, when known.
    public var windowLength: TimeInterval? {
        switch kind {
        case .session: return 5 * 3600
        case .weeklyAll, .weeklyScoped: return 7 * 24 * 3600
        case .other: return nil
        }
    }

    public var windowStart: Date? {
        guard let resetsAt, let windowLength else { return nil }
        return resetsAt.addingTimeInterval(-windowLength)
    }

    /// Stable per-window identifier. `resets_at` carries request-time sub-second noise,
    /// so it is rounded to the minute.
    public var windowKey: String {
        let minute = resetsAt.map { Int(($0.timeIntervalSince1970 / 60).rounded()) } ?? 0
        return "\(id)@\(minute)"
    }
}

public enum UsageMapper {
    public static func limits(from response: UsageResponse) -> [UsageLimit] {
        if let entries = response.limits, !entries.isEmpty {
            let shares = Dictionary(
                (response.weeklyScopedShares ?? []).map { ($0.limitIndex, $0) },
                uniquingKeysWith: { a, _ in a }
            )
            return entries.enumerated().map { index, entry in
                limit(from: entry, share: shares[index])
            }
        }

        // Older response shape: flat five_hour / seven_day fields only.
        var result: [UsageLimit] = []
        if let w = response.fiveHour, let u = w.utilization {
            result.append(UsageLimit(id: "session", kind: .session, title: "현재 세션", shortTitle: "세션",
                                     percent: Sanitize.percent(u), resetsAt: w.resetsAt.flatMap(DateParsing.parse)))
        }
        if let w = response.sevenDay, let u = w.utilization {
            result.append(UsageLimit(id: "weekly_all", kind: .weeklyAll, title: "주간 · 모든 모델", shortTitle: "주간",
                                     percent: Sanitize.percent(u), resetsAt: w.resetsAt.flatMap(DateParsing.parse)))
        }
        return result
    }

    static func limit(from entry: UsageResponse.LimitEntry, share: UsageResponse.ScopedShare?) -> UsageLimit {
        let scopeName = entry.scope?.model?.displayName ?? entry.scope?.surface?.displayName
        let kind: UsageLimit.Kind
        let title: String
        let shortTitle: String

        switch entry.kind {
        case "session":
            kind = .session; title = "현재 세션"; shortTitle = "세션"
        case "weekly_all":
            kind = .weeklyAll; title = "주간 · 모든 모델"; shortTitle = "주간"
        case "weekly_scoped":
            kind = .weeklyScoped
            title = "주간 · \(scopeName ?? "제한 범위")"
            shortTitle = scopeName ?? "주간(범위)"
        default:
            kind = .other
            let readable = entry.kind.replacingOccurrences(of: "_", with: " ").capitalized
            title = scopeName.map { "\(readable) · \($0)" } ?? readable
            shortTitle = scopeName ?? readable
        }

        let id = [entry.kind, scopeName].compactMap { $0 }.joined(separator: ":")
        return UsageLimit(
            id: id, kind: kind, title: title, shortTitle: shortTitle,
            percent: Sanitize.percent(entry.percent),
            resetsAt: entry.resetsAt.flatMap(DateParsing.parse),
            severity: entry.severity,
            usedOfWeekly: share?.usedPercentOfWeekly.map(Sanitize.percent),
            allowanceOfWeekly: share?.allowancePercentOfWeekly.map(Sanitize.percent)
        )
    }
}

public enum DateParsing {
    /// Parses ISO-8601 timestamps with any number of fractional digits
    /// (the API emits microseconds, e.g. `2026-10-12T05:29:59.953021+00:00`).
    public static func parse(_ string: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]

        guard let dot = string.firstIndex(of: "."),
              let fractionEnd = string[dot...].dropFirst().firstIndex(where: { !$0.isNumber })
        else {
            return plain.date(from: string)
        }
        let fractionDigits = string[string.index(after: dot)..<fractionEnd]
        let withoutFraction = String(string[..<dot] + string[fractionEnd...])
        guard let base = plain.date(from: withoutFraction) else { return nil }
        let fraction = Double("0." + fractionDigits) ?? 0
        return base.addingTimeInterval(fraction)
    }
}
