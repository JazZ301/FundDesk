import FundCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: BoardModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @ViewState private var interval = RefreshInterval.defaultValue
    @ViewState private var theme = AppearanceTheme.defaultValue

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("设置").font(.title2.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("外观主题", systemImage: "circle.lefthalf.filled")
                    .font(.headline)
                    .foregroundStyle(Display.primaryStrong)

                Text("手动切换白色或黑色界面；跟随系统会随 macOS 外观自动变化。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ThemedSegmentedControl(
                    options: AppearanceTheme.allCases, selection: $theme, title: "外观主题"
                ) { $0.label }
            }
            .padding(14)
            .background(Display.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Display.stroke)
            }

            VStack(alignment: .leading, spacing: 12) {
                Label("自动刷新间隔", systemImage: "timer")
                    .font(.headline)
                    .foregroundStyle(Display.primaryStrong)

                Text("按所选间隔自动检查自选基金。盘中估值会按此周期请求，正式净值仍沿用原有缓存周期，避免重复下载历史数据。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ThemedSegmentedControl(
                    options: RefreshInterval.allCases, selection: $interval, title: "自动刷新间隔"
                ) { $0.label }

                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Display.primary)
                    Text("当前每 \(interval.rawValue) 秒自动检查")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Text("默认 10 秒")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Display.primarySoft, in: Capsule())
                }
            }
            .padding(14)
            .background(Display.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Display.stroke)
            }

            VStack(alignment: .leading, spacing: 8) {
                settingRow("盘中估算", detail: "每 \(interval.rawValue) 秒检查，交易时段内生效")
                Divider()
                settingRow("正式净值", detail: "继续使用现有缓存周期，手动刷新可立即检查")
                Divider()
                settingRow("请求保护", detail: "刷新进行中不会重复发起，失败后会自动退避重试")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Display.panelRaised, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Display.stroke)
            }

            if let warning = model.storageWarning {
                Label(warning, systemImage: "externaldrive.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(Display.warning)
            }

            Spacer(minLength: 0)
        }
        .id(theme)
        .padding(20)
        .frame(width: 540, height: 500)
        .background(Display.canvasWash)
        .tint(Display.primary(for: theme, systemColorScheme: colorScheme))
        .onAppear {
            interval = model.board.refreshIntervalValue
            theme = model.board.appearanceThemeValue
        }
        .onChange(of: interval) { value in
            model.setRefreshInterval(value)
        }
        .onChange(of: theme) { value in
            model.setAppearanceTheme(value)
        }
    }

    private func settingRow(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.callout.weight(.medium))
                .frame(width: 72, alignment: .leading)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
