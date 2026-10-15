import AgentUsageCore
import AppKit
import SwiftUI

@main
struct AgentUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings: AppSettings
    @State private var store: UsageStore

    init() {
        let settings = AppSettings()
        let store = UsageStore(settings: settings)
        _settings = State(initialValue: settings)
        _store = State(initialValue: store)
        // Start polling at launch, not when the label first renders.
        Task { @MainActor in store.start() }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(store: store, settings: settings)
        } label: {
            MenuBarLabel(store: store, settings: settings)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon even when run unbundled via `swift run`.
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in NotificationService.shared.configure() }
    }
}

struct MenuBarLabel: View {
    let store: UsageStore
    let settings: AppSettings

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: MenuBarIcon.ring(percent: ringPercent))
            if let text {
                Text(text).monospacedDigit()
            }
        }
    }

    /// The ring always tracks the most urgent limit; the text follows the chosen mode.
    private var ringPercent: Double? {
        store.limits.isEmpty ? nil : store.highestPercent.map { $0.rounded() }
    }

    private var text: String? {
        guard !store.limits.isEmpty else { return store.error == nil ? nil : "–" }
        let session = store.session.map { Formatting.percent($0.percent) }
        let weekly = store.weekly.map { Formatting.percent($0.percent) }
        switch settings.menuBarMode {
        case .sessionAndWeekly:
            return [session, weekly].compactMap { $0 }.joined(separator: " · ")
        case .session:
            return session
        case .weekly:
            return weekly
        case .highest:
            return store.highestPercent.map(Formatting.percent)
        case .iconOnly:
            return nil
        }
    }
}
