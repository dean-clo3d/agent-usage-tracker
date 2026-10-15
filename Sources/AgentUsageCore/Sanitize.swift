import Foundation

/// Clamps values that come from the network or from log files before they are used in
/// arithmetic or `Int` conversions, which trap on NaN, infinity and overflow.
public enum Sanitize {
    /// 0...1000 (a little headroom above 100 for overage); non-finite becomes 0.
    public static func percent(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 0 }
        return min(max(value, 0), 1000)
    }

    /// Token counts are clamped to 0...2^40 so summing a day of them can't overflow.
    public static func tokenCount(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(max(value, 0), Double(1 << 40)))
    }

    /// Seconds to wait from a Retry-After header: finite, positive, at most `cap`.
    public static func retryAfter(_ value: TimeInterval?, default fallback: TimeInterval, cap: TimeInterval) -> TimeInterval {
        guard let value, value.isFinite, value > 0 else { return fallback }
        return min(value, cap)
    }
}
