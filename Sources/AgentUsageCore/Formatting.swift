import Foundation

public enum Formatting {
    /// "3시간 8분", "12분", "2일 4시간", "1분 미만"
    public static func duration(_ interval: TimeInterval) -> String {
        guard interval.isFinite else { return "–" }
        let totalMinutes = Int(min(max(interval, 0), 10 * 365 * 86_400) / 60)
        let days = totalMinutes / (60 * 24)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60
        if days > 0 { return hours > 0 ? "\(days)일 \(hours)시간" : "\(days)일" }
        if hours > 0 { return minutes > 0 ? "\(hours)시간 \(minutes)분" : "\(hours)시간" }
        if minutes > 0 { return "\(minutes)분" }
        return "1분 미만"
    }

    /// "14:29" today, "내일 14:29", "10/15(목) 14:29" further out. Always 24-hour.
    public static func clock(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = timeFormatter.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "내일 \(time)"
        }
        return dayTimeFormatter.string(from: date)
    }

    private static let timeFormatter = makeFormatter("HH:mm")
    private static let dayTimeFormatter = makeFormatter("M/d(E) HH:mm")

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = format
        return formatter
    }

    /// "1.2M", "34.5K", "812"
    public static func tokens(_ value: Double) -> String {
        guard value.isFinite else { return "–" }
        switch value {
        case 1_000_000...: return String(format: "%.1fM", value / 1_000_000)
        case 1_000...: return String(format: "%.1fK", value / 1_000)
        default: return String(format: "%.0f", value)
        }
    }

    public static func percent(_ value: Double) -> String {
        "\(Int(Sanitize.percent(value).rounded()))%"
    }
}
