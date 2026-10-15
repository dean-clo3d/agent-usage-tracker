import AgentUsageCore
import Foundation
import Observation

enum StoreError: Equatable {
    case notLoggedIn
    case tokenExpired
    case rateLimited(until: Date)
    case network(String)
    case server(Int)
    case unexpectedResponse

    var title: String {
        switch self {
        case .notLoggedIn: return "Claude Code 로그인 정보를 찾을 수 없어요"
        case .tokenExpired: return "Claude Code 토큰이 만료됐어요"
        case .rateLimited: return "요청이 많아 잠시 대기 중"
        case .network: return "네트워크 오류"
        case .server(let status): return "서버 오류 (\(status))"
        case .unexpectedResponse: return "응답 형식을 해석하지 못했어요"
        }
    }

    var hint: String {
        switch self {
        case .notLoggedIn:
            return "터미널에서 claude 를 실행하고 /login 으로 회사 계정에 로그인하세요."
        case .tokenExpired:
            return "터미널에서 Claude Code를 한 번 사용하면 토큰이 자동 갱신되고, 여기도 곧 따라옵니다."
        case .rateLimited(let until):
            return "\(Formatting.clock(until))에 다시 시도합니다."
        case .network(let message):
            return message
        case .server, .unexpectedResponse:
            return "잠시 후 자동으로 다시 시도합니다."
        }
    }
}

/// Owns all polling. Designed to stay near-idle in the background:
/// - Panel closed: one small HTTPS request per refresh interval, nothing else.
/// - Panel open: local logs are tailed every few seconds for the live activity view.
@MainActor
@Observable
final class UsageStore {
    private(set) var limits: [UsageLimit] = []
    private(set) var projections: [String: Projection] = [:]
    private(set) var activity: ActivityStats?
    private(set) var contextualTips: [Tip] = []
    private(set) var fetchedAt: Date?
    private(set) var error: StoreError?
    private(set) var isRefreshing = false
    private(set) var planLabel: String?
    /// Refreshed only while the panel is visible, so countdowns stay current there.
    private(set) var now = Date()

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let api = UsageAPI()
    @ObservationIgnored private let scanner = LocalLogScanner()
    @ObservationIgnored private var credential: OAuthCredential?
    @ObservationIgnored private var samples: [String: [UsageSample]] = [:]
    @ObservationIgnored private var sampleWindow: [String: String] = [:]
    @ObservationIgnored private var nextFetchAllowed = Date.distantPast
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var panelTask: Task<Void, Never>?
    @ObservationIgnored private var firedAlertKeys: Set<String>

    private static let firedKeysDefaultsKey = "firedAlertKeys"
    private static let panelTickInterval: Duration = .seconds(5)

    init(settings: AppSettings) {
        self.settings = settings
        let stored = UserDefaults.standard.stringArray(forKey: Self.firedKeysDefaultsKey) ?? []
        firedAlertKeys = AlertPlanner.prune(firedKeys: Set(stored), now: Date())
    }

    var session: UsageLimit? { limits.first { $0.kind == .session } }
    var weekly: UsageLimit? { limits.first { $0.kind == .weeklyAll } }
    var highestPercent: Double? { limits.map(\.percent).max() }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let interval = self?.settings.refreshInterval ?? 60
                // Generous tolerance lets macOS coalesce our wakeups with other timers.
                try? await Task.sleep(for: .seconds(max(interval, 15)), tolerance: .seconds(10))
            }
        }
    }

    /// Called when the menu bar panel opens/closes.
    func setPanelVisible(_ visible: Bool) {
        panelTask?.cancel()
        panelTask = nil
        guard visible else { return }
        now = Date()
        panelTask = Task { [weak self] in
            // Catch up immediately if the last fetch is older than one interval.
            if let self, let fetchedAt = self.fetchedAt,
               Date().timeIntervalSince(fetchedAt) > Double(self.settings.refreshInterval) {
                await self.refresh()
            }
            while !Task.isCancelled {
                await self?.scanLogs()
                self?.now = Date()
                try? await Task.sleep(for: Self.panelTickInterval, tolerance: .seconds(1))
            }
        }
    }

    /// Fetches limits from the API. `force` skips the rate-limit backoff (manual refresh).
    func refresh(force: Bool = false) async {
        guard !isRefreshing else { return }
        guard force || Date() >= nextFetchAllowed else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            now = Date()
        }

        guard let credential = await currentCredential(forceReload: force) else {
            error = .notLoggedIn
            return
        }
        planLabel = Self.planLabel(subscription: credential.subscriptionType, tier: credential.rateLimitTier)
        if credential.isExpired() {
            error = .tokenExpired
            return
        }

        do {
            let response = try await api.fetch(accessToken: credential.accessToken)
            apply(UsageMapper.limits(from: response), at: Date())
            error = nil
        } catch let apiError as UsageAPIError {
            switch apiError {
            case .unauthorized:
                // Claude Code may have rotated the token; re-read the keychain next time.
                self.credential = nil
                error = .tokenExpired
            case .rateLimited(let retryAfter):
                let until = Date().addingTimeInterval(Sanitize.retryAfter(retryAfter, default: 120, cap: 900))
                nextFetchAllowed = until
                error = .rateLimited(until: until)
            case .network(let message):
                error = .network(message)
            case .http(let status):
                error = .server(status)
            case .decoding:
                error = .unexpectedResponse
            }
        } catch {
            self.error = .network(error.localizedDescription)
        }
    }

    /// Cached credential; the keychain is re-read only when missing, expired, rejected,
    /// or on a manual refresh — not on every poll.
    private func currentCredential(forceReload: Bool) async -> OAuthCredential? {
        if !forceReload, let credential, !credential.isExpired() {
            return credential
        }
        credential = try? await Task.detached(priority: .utility) { try CredentialStore.load() }.value
        return credential
    }

    private func apply(_ newLimits: [UsageLimit], at date: Date) {
        let previous = limits
        if newLimits != limits { limits = newLimits }
        fetchedAt = date

        for limit in newLimits {
            if sampleWindow[limit.id] != limit.windowKey {
                sampleWindow[limit.id] = limit.windowKey
                samples[limit.id] = []
            }
            samples[limit.id, default: []].append(UsageSample(date: date, percent: limit.percent))
            samples[limit.id]?.removeAll { date.timeIntervalSince($0.date) > 2 * 3600 }
        }
        projections = Dictionary(uniqueKeysWithValues: newLimits.compactMap { limit in
            Projector.project(limit: limit, samples: samples[limit.id] ?? [], now: date).map { (limit.id, $0) }
        })

        let alerts = AlertPlanner.plan(
            limits: newLimits, previous: previous, projections: projections,
            settings: settings.alertSettings, alreadyFired: firedAlertKeys, now: date
        )
        if !alerts.isEmpty {
            for alert in alerts {
                NotificationService.shared.post(alert)
                firedAlertKeys.insert(alert.key)
            }
            firedAlertKeys = AlertPlanner.prune(firedKeys: firedAlertKeys, now: date)
            UserDefaults.standard.set(Array(firedAlertKeys), forKey: Self.firedKeysDefaultsKey)
        }

        rebuildTips()
    }

    private func scanLogs() async {
        guard settings.showActivity else { return }
        let now = Date()
        // Keep enough history for today's totals and the whole current 5-hour window.
        let sessionStart = session?.windowStart ?? now.addingTimeInterval(-5 * 3600)
        let since = min(Calendar.current.startOfDay(for: now), sessionStart, now.addingTimeInterval(-3600))
        let events = await scanner.scan(since: since)
        let stats = ActivityStats.compute(events: events, now: now, sessionWindowStart: session?.windowStart)
        if stats != activity { activity = stats }
        rebuildTips()
    }

    private func rebuildTips() {
        let tips = TipEngine.contextualTips(limits: limits, projections: projections, activity: activity, now: Date())
        if tips != contextualTips { contextualTips = tips }
    }

    /// "Team · Max 5x" from credential metadata.
    static func planLabel(subscription: String?, tier: String?) -> String? {
        let plan = subscription.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        var tierLabel: String?
        if let tier {
            if tier.contains("max_20x") { tierLabel = "Max 20x" }
            else if tier.contains("max_5x") { tierLabel = "Max 5x" }
        }
        let parts = [plan, tierLabel].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
