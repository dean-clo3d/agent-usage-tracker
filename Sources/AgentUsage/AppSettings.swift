import AgentUsageCore
import Foundation
import Observation

enum MenuBarMode: String, CaseIterable, Identifiable {
    case sessionAndWeekly, session, weekly, highest, iconOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sessionAndWeekly: return "세션 · 주간"
        case .session: return "세션만"
        case .weekly: return "주간만"
        case .highest: return "가장 높은 값"
        case .iconOnly: return "아이콘만"
        }
    }
}

/// User preferences, persisted to UserDefaults on every change.
@MainActor
@Observable
final class AppSettings {
    static let thresholdPresets = [25, 50, 60, 70, 75, 80, 85, 90, 95, 100]
    static let refreshPresets = [30, 60, 120, 300]

    var menuBarMode: MenuBarMode { didSet { save() } }
    var refreshInterval: Int { didSet { save() } }
    var showActivity: Bool { didSet { save() } }

    var alertsEnabled: Bool { didSet { save() } }
    var thresholds: [Int] { didSet { save() } }
    var approachMargin: Int { didSet { save() } }
    var predictiveAlerts: Bool { didSet { save() } }
    var resetAlerts: Bool { didSet { save() } }
    var watchSession: Bool { didSet { save() } }
    var watchWeekly: Bool { didSet { save() } }
    var watchScoped: Bool { didSet { save() } }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        menuBarMode = MenuBarMode(rawValue: defaults.string(forKey: Keys.menuBarMode) ?? "") ?? .sessionAndWeekly
        refreshInterval = defaults.object(forKey: Keys.refreshInterval) as? Int ?? 60
        showActivity = defaults.object(forKey: Keys.showActivity) as? Bool ?? true
        alertsEnabled = defaults.object(forKey: Keys.alertsEnabled) as? Bool ?? true
        thresholds = defaults.array(forKey: Keys.thresholds) as? [Int] ?? [50, 75, 90]
        approachMargin = defaults.object(forKey: Keys.approachMargin) as? Int ?? 5
        predictiveAlerts = defaults.object(forKey: Keys.predictiveAlerts) as? Bool ?? true
        resetAlerts = defaults.object(forKey: Keys.resetAlerts) as? Bool ?? true
        watchSession = defaults.object(forKey: Keys.watchSession) as? Bool ?? true
        watchWeekly = defaults.object(forKey: Keys.watchWeekly) as? Bool ?? true
        watchScoped = defaults.object(forKey: Keys.watchScoped) as? Bool ?? true
    }

    var alertSettings: AlertSettings {
        var kinds: Set<UsageLimit.Kind> = [.other]
        if watchSession { kinds.insert(.session) }
        if watchWeekly { kinds.insert(.weeklyAll) }
        if watchScoped { kinds.insert(.weeklyScoped) }
        return AlertSettings(
            enabled: alertsEnabled,
            thresholds: thresholds,
            approachMargin: approachMargin,
            predictive: predictiveAlerts,
            notifyOnReset: resetAlerts,
            watchedKinds: kinds
        )
    }

    func toggleThreshold(_ value: Int) {
        if thresholds.contains(value) {
            thresholds.removeAll { $0 == value }
        } else {
            thresholds = (thresholds + [value]).sorted()
        }
    }

    private func save() {
        defaults.set(menuBarMode.rawValue, forKey: Keys.menuBarMode)
        defaults.set(refreshInterval, forKey: Keys.refreshInterval)
        defaults.set(showActivity, forKey: Keys.showActivity)
        defaults.set(alertsEnabled, forKey: Keys.alertsEnabled)
        defaults.set(thresholds, forKey: Keys.thresholds)
        defaults.set(approachMargin, forKey: Keys.approachMargin)
        defaults.set(predictiveAlerts, forKey: Keys.predictiveAlerts)
        defaults.set(resetAlerts, forKey: Keys.resetAlerts)
        defaults.set(watchSession, forKey: Keys.watchSession)
        defaults.set(watchWeekly, forKey: Keys.watchWeekly)
        defaults.set(watchScoped, forKey: Keys.watchScoped)
    }

    private enum Keys {
        static let menuBarMode = "menuBarMode"
        static let refreshInterval = "refreshInterval"
        static let showActivity = "showActivity"
        static let alertsEnabled = "alertsEnabled"
        static let thresholds = "alertThresholds"
        static let approachMargin = "approachMargin"
        static let predictiveAlerts = "predictiveAlerts"
        static let resetAlerts = "resetAlerts"
        static let watchSession = "watchSession"
        static let watchWeekly = "watchWeekly"
        static let watchScoped = "watchScoped"
    }
}
