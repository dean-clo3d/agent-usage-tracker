import AgentUsageCore
import AppKit
import SwiftUI

struct PanelView: View {
    let store: UsageStore
    let settings: AppSettings
    let updates: UpdateChecker
    @State private var showingSettings = false
    @State private var contentHeight: CGFloat = 0

    static let width: CGFloat = 360

    var body: some View {
        VStack(spacing: 10) {
            header
            if showingSettings {
                SettingsView(settings: settings, updates: updates)
            } else {
                content
            }
            footer
        }
        .padding(12)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        .background(PanelWindowBridge(contentHeight: contentHeight) { store.setPanelVisible($0) })
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(showingSettings ? "설정" : "Claude 사용량")
                .font(.system(size: 17, weight: .semibold))
            if let plan = store.planLabel, !showingSettings {
                Text(plan)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showingSettings.toggle() }
            } label: {
                Image(systemName: showingSettings ? "xmark" : "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showingSettings ? "닫기" : "설정")
        }
        .padding(.horizontal, 4)
    }

    private var content: some View {
        VStack(spacing: 0) {
            if let pending = updates.state.pending {
                UpdateBanner(state: updates.state, pending: pending) { updates.install() }
                Divider().padding(.horizontal, 12)
            }
            if let error = store.error {
                ErrorBanner(error: error)
                if !store.limits.isEmpty { Divider().padding(.horizontal, 12) }
            }
            if store.limits.isEmpty && store.error == nil {
                ProgressView().controlSize(.small).padding(24)
            }
            ForEach(Array(store.limits.enumerated()), id: \.element.id) { index, limit in
                if index > 0 { Divider().padding(.horizontal, 12) }
                LimitSection(
                    limit: limit,
                    projection: store.projections[limit.id],
                    thresholds: settings.alertsEnabled ? settings.thresholds : [],
                    now: store.now
                )
            }
            if settings.showActivity, let activity = store.activity, activity.today.requests > 0 || activity.lastEventAt != nil {
                Divider().padding(.horizontal, 12)
                ActivitySection(activity: activity)
            }
            Divider().padding(.horizontal, 12)
            TipsSection(contextual: store.contextualTips)
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let fetchedAt = store.fetchedAt {
                Text(verbatim: "\(fetchedAt.formatted(date: .omitted, time: .standard)) 업데이트")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            FooterButton(symbol: "arrow.clockwise", help: "지금 새로고침", spinning: store.isRefreshing) {
                Task { await store.refresh(force: true) }
            }
            FooterButton(symbol: "safari", help: "claude.ai 사용량 페이지 열기") {
                NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
            }
            FooterButton(symbol: "power", help: "종료") {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 4)
    }
}

private struct FooterButton: View {
    let symbol: String
    let help: String
    var spinning = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(spinning ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: spinning)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

private struct ErrorBanner: View {
    let error: StoreError

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text(error.title).font(.system(size: 12, weight: .semibold))
                Text(error.hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }
}

private struct UpdateBanner: View {
    let state: UpdateState
    let pending: PendingUpdate
    let install: () -> Void

    private var isInstalling: Bool {
        if case .installing = state { return true }
        return false
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(Color.accentColor)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "새 버전 (커밋 \(pending.commits.count)개)")
                    .font(.system(size: 12, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(pending.commits.prefix(3), id: \.sha) { commit in
                        Text(verbatim: "· \(commit.subject)")
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                if isInstalling {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("빌드 중… 끝나면 자동으로 다시 열려요")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    if case .installFailed(_, let message) = state {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 10) {
                        if let url = pending.compareURL {
                            Button("변경 내역") { NSWorkspace.shared.open(url) }
                                .buttonStyle(.link)
                        }
                        Button("업데이트", action: install)
                            .buttonStyle(.borderedProminent)
                    }
                    .controlSize(.small)
                    .font(.system(size: 11))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }
}

/// Reports when the hosting panel window opens/closes, and keeps the window exactly as tall as
/// the panel. MenuBarExtra's window becomes key when shown and resigns when dismissed;
/// `onAppear` alone doesn't fire on every open. Its own sizing is unreliable while the window is
/// on screen: it can update the size constraints yet leave the frame at the old height, which
/// clips taller content or centers shorter content below a gap.
struct PanelWindowBridge: NSViewRepresentable {
    let contentHeight: CGFloat
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> BridgeView {
        let view = BridgeView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: BridgeView, context: Context) {
        nsView.onChange = onChange
        nsView.fit(height: contentHeight)
    }

    final class BridgeView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        /// Resizes around the top edge, which MenuBarExtra pins just under the status item.
        func fit(height: CGFloat) {
            guard let window, height > 0, abs(window.frame.height - height) > 0.5 else { return }
            var frame = window.frame
            frame.origin.y = frame.maxY - height
            frame.size.height = height
            window.setFrame(frame, display: true)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else {
                onChange?(false)
                return
            }
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.onChange?(true)
            })
            observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.onChange?(false)
            })
            if window.isKeyWindow || window.isVisible { onChange?(true) }
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
