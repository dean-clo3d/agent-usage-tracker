import AgentUsageCore
import SwiftUI

/// RunCat-style row: large icon on the left, headline + detail lines + bar on the right.
struct SectionRow<Content: View>: View {
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .frame(width: 40, height: 40)
                .foregroundStyle(.primary.opacity(0.85))
            VStack(alignment: .leading, spacing: 3) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

struct DetailText: View {
    let text: String
    var color: Color = .secondary

    init(_ text: String, color: Color = .secondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Limits

struct LimitSection: View {
    let limit: UsageLimit
    let projection: Projection?
    let thresholds: [Int]
    let now: Date

    var body: some View {
        SectionRow(symbol: symbol) {
            Text(verbatim: "\(limit.title): \(Formatting.percent(limit.percent))")
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
            if let resetsAt = limit.resetsAt {
                DetailText("\(Formatting.duration(resetsAt.timeIntervalSince(now))) 후 재설정 · \(Formatting.clock(resetsAt, now: now))")
            }
            if let projectionText {
                DetailText(projectionText.text, color: projectionText.color)
            }
            if let used = limit.usedOfWeekly, let allowance = limit.allowanceOfWeekly {
                DetailText("주간 전체 중 \(Formatting.percent(used)) 사용 · 최대 \(Formatting.percent(allowance))까지")
            }
            UsageBar(percent: limit.percent, thresholds: thresholds)
                .padding(.top, 4)
        }
    }

    private var symbol: String {
        switch limit.kind {
        case .session: return "timer"
        case .weeklyAll: return "calendar"
        case .weeklyScoped: return "sparkles"
        case .other: return "gauge.with.dots.needle.33percent"
        }
    }

    private var projectionText: (text: String, color: Color)? {
        guard limit.percent < 100 else { return ("한도에 도달했어요", .red) }
        guard let projection else { return nil }
        if projection.exhaustsBeforeReset, let fullAt = projection.fullAt {
            return ("이 속도면 \(Formatting.clock(fullAt, now: now))쯤 소진 (시간당 +\(String(format: "%.1f", projection.ratePerHour))%p)", .orange)
        }
        if projection.ratePerHour > 0 {
            let basis = projection.isRecent ? "최근" : "평균"
            return ("\(basis) 시간당 +\(String(format: "%.1f", projection.ratePerHour))%p · 재설정 전 여유", .secondary)
        }
        return nil
    }
}

struct UsageBar: View {
    let percent: Double
    var thresholds: [Int] = []

    var body: some View {
        GeometryReader { geo in
            let fraction = min(max(percent / 100, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(UsageColor.forPercent(percent))
                    .frame(width: max(fraction * geo.size.width, percent > 0 ? 6 : 0))
                ForEach(thresholds.filter { $0 > 0 && $0 < 100 }, id: \.self) { t in
                    Rectangle()
                        .fill(Color.primary.opacity(0.35))
                        .frame(width: 1, height: geo.size.height + 4)
                        .offset(x: geo.size.width * CGFloat(t) / 100 - 0.5)
                }
            }
        }
        .frame(height: 7)
        .help(thresholds.isEmpty ? "" : "알림 기준: \(thresholds.map { "\($0)%" }.joined(separator: ", "))")
    }
}

// MARK: - Live activity (local Claude Code logs)

struct ActivitySection: View {
    let activity: ActivityStats

    var body: some View {
        SectionRow(symbol: "waveform.path.ecg") {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: "실시간: \(Formatting.tokens(activity.recentRatePerMinute))/분")
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .help("이 Mac의 Claude Code 로그 기준, 최근 5분 평균.\n가중 토큰 = 입력 1× + 캐시 쓰기 1.25× + 캐시 읽기 0.1× + 출력 5× (API 단가 비율).\n웹/데스크톱 앱 사용량은 포함되지 않아요.")
            }
            DetailText(todayLine)
            if let cacheLine { DetailText(cacheLine) }
            Sparkline(values: activity.perMinute)
                .frame(height: 22)
                .padding(.top, 4)
            if !activity.modelShares.isEmpty {
                ModelMixBar(shares: activity.modelShares)
                    .padding(.top, 4)
            }
        }
    }

    private var todayLine: String {
        let t = activity.today
        return "오늘 \(t.requests)회 요청 · 출력 \(Formatting.tokens(Double(t.output))) · 가중 \(Formatting.tokens(t.weighted))"
    }

    private var cacheLine: String? {
        var parts: [String] = []
        if let hit = activity.today.cacheHitRatio { parts.append("캐시 적중 \(Formatting.percent(hit * 100))") }
        if let avg = activity.today.averageContext { parts.append("컨텍스트 \(Formatting.tokens(avg))") }
        if activity.activeSessionsLastHour > 0 { parts.append("세션 \(activity.activeSessionsLastHour)개") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Bars for the last 60 minutes, drawn in a single Canvas pass (no per-bar views).
struct Sparkline: View {
    let values: [Double]

    var body: some View {
        Canvas { context, size in
            guard let peak = values.max(), peak > 0, !values.isEmpty else {
                let baseline = Path(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1))
                context.fill(baseline, with: .color(.secondary.opacity(0.3)))
                return
            }
            let step = size.width / CGFloat(values.count)
            let barWidth = max(step - 1, 1)
            for (i, v) in values.enumerated() {
                let h = max(CGFloat(v / peak) * size.height, v > 0 ? 1.5 : 0.5)
                let rect = CGRect(x: CGFloat(i) * step, y: size.height - h, width: barWidth, height: h)
                context.fill(Path(rect), with: .color(Color.accentColor.opacity(v > 0 ? 0.85 : 0.2)))
            }
        }
        .help("최근 60분, 분당 가중 토큰")
    }
}

struct ModelMixBar: View {
    let shares: [ModelShare]
    private static let palette: [Color] = [.blue, .purple, .teal, .orange, .pink, .gray]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(Array(shares.enumerated()), id: \.element.id) { i, share in
                        Rectangle()
                            .fill(color(i))
                            .frame(width: max(geo.size.width * share.share - 1, 1))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 5)
            HStack(spacing: 8) {
                ForEach(Array(shares.prefix(4).enumerated()), id: \.element.id) { i, share in
                    HStack(spacing: 3) {
                        Circle().fill(color(i)).frame(width: 6, height: 6)
                        Text(verbatim: "\(share.name) \(Formatting.percent(share.share * 100))")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func color(_ index: Int) -> Color {
        Self.palette[min(index, Self.palette.count - 1)]
    }
}

// MARK: - Tips

struct TipsSection: View {
    let contextual: [Tip]
    @State private var generalIndex = Int.random(in: 0..<TipEngine.generalTips.count)

    var body: some View {
        SectionRow(symbol: "lightbulb") {
            HStack {
                Text("토큰 절약 팁")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button {
                    generalIndex = (generalIndex + 1) % TipEngine.generalTips.count
                } label: {
                    HStack(spacing: 2) {
                        Text("다음 팁")
                        Image(systemName: "chevron.right")
                    }
                    .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            ForEach(contextual.prefix(2)) { tip in
                TipRow(tip: tip, highlighted: true)
            }
            TipRow(tip: TipEngine.generalTips[generalIndex], highlighted: false)
        }
    }
}

private struct TipRow: View {
    let tip: Tip
    let highlighted: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: tip.symbol)
                .font(.system(size: 12))
                .foregroundStyle(highlighted ? Color.orange : Color.accentColor)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(tip.title)
                    .font(.system(size: 12, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(tip.body)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill((highlighted ? Color.orange : Color.secondary).opacity(0.08))
        )
        .padding(.top, 4)
    }
}
