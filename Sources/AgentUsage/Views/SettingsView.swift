import AgentUsageCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?
    @State private var notificationsDenied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            group("메뉴 막대") {
                row("표시") {
                    Picker("", selection: $settings.menuBarMode) {
                        ForEach(MenuBarMode.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
                row("새로고침 주기") {
                    Picker("", selection: $settings.refreshInterval) {
                        ForEach(AppSettings.refreshPresets, id: \.self) { s in
                            Text(s < 60 ? "\(s)초" : "\(s / 60)분").tag(s)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
                switchRow("실시간 활동 (로컬 Claude Code 로그)", isOn: $settings.showActivity)
            }

            group("알림") {
                switchRow("사용량 알림 받기", isOn: $settings.alertsEnabled)
                if settings.alertsEnabled {
                    Text("이 비율에 도달하면 알림")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    ThresholdChips(selected: settings.thresholds) { settings.toggleThreshold($0) }
                    row("도달 전 미리 알림") {
                        Stepper(value: $settings.approachMargin, in: 0...20) {
                            Text(settings.approachMargin == 0 ? "끔" : "\(settings.approachMargin)%p 전")
                                .monospacedDigit()
                        }
                    }
                    switchRow("재설정 전 소진이 예상되면 알림", isOn: $settings.predictiveAlerts)
                    switchRow("한도가 재설정되면 알림", isOn: $settings.resetAlerts)
                    HStack(spacing: 12) {
                        Toggle("세션", isOn: $settings.watchSession)
                        Toggle("주간", isOn: $settings.watchWeekly)
                        Toggle("모델별 주간", isOn: $settings.watchScoped)
                    }
                    .toggleStyle(.checkbox)
                    HStack {
                        Button("테스트 알림") {
                            NotificationService.shared.post(
                                identifier: "test-\(Date().timeIntervalSince1970)",
                                title: "현재 세션 75% 도달",
                                body: "알림이 이렇게 표시돼요."
                            )
                        }
                        if notificationsDenied {
                            Button("알림 권한 열기") { NotificationService.shared.openSystemSettings() }
                            Text("알림이 꺼져 있어요").font(.system(size: 11)).foregroundStyle(.orange)
                        }
                    }
                    .controlSize(.small)
                }
            }

            group("일반") {
                switchRow("로그인 시 자동 실행", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let launchError {
                    Text(launchError).font(.system(size: 11)).foregroundStyle(.orange)
                }
                Text("인증: Claude Code가 키체인에 저장한 로그인 토큰을 읽기 전용으로 사용합니다. 별도 로그인이 필요 없고 토큰은 이 Mac 밖으로 Anthropic API 외에는 전송되지 않아요.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: "버전 \(AppInfo.version)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .font(.system(size: 12))
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
        .task { notificationsDenied = await NotificationService.shared.authorizationDenied() }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content()
        }
    }

    private func switchRow(_ label: String, isOn: Binding<Bool>) -> some View {
        row(label) {
            Toggle(label, isOn: isOn).labelsHidden()
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
            Spacer()
            content()
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchError = nil
        } catch {
            launchError = "설정하지 못했어요: \(error.localizedDescription) (앱을 /Applications 에 설치한 뒤 다시 시도하세요)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct ThresholdChips: View {
    let selected: [Int]
    let toggle: (Int) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 5)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(AppSettings.thresholdPresets, id: \.self) { value in
                let isOn = selected.contains(value)
                Button { toggle(value) } label: {
                    Text(verbatim: "\(value)%")
                        .font(.system(size: 11, weight: isOn ? .semibold : .regular))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(isOn ? Color.accentColor : Color.secondary.opacity(0.12))
                        )
                        .foregroundStyle(isOn ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
