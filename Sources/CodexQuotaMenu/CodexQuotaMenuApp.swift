import AppKit
import SwiftUI
import CodexQuotaCore

@main
@MainActor
struct CodexQuotaMenuApp: App {
    @StateObject private var model = QuotaStore()

    var body: some Scene {
        MenuBarExtra {
            QuotaPopover(model: model)
        } label: {
            MenuBarStatusLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarStatusLabel: View {
    @ObservedObject var model: QuotaStore

    var body: some View {
        HStack(spacing: 5) {
            CodexStatusMark(tint: model.statusColor)
            Text(model.menuBarText)
                .monospacedDigit()
        }
        .accessibilityLabel("Codex 用量：\(model.menuBarText)")
        .help("Codex 用量：\(model.menuBarText)")
    }
}

struct CodexStatusMark: View {
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0.14, to: 0.86)
                .stroke(tint, style: StrokeStyle(lineWidth: 2.1, lineCap: .round))
                .rotationEffect(.degrees(90))

            RoundedRectangle(cornerRadius: 1)
                .fill(Color.primary.opacity(0.82))
                .frame(width: 1.8, height: 6.2)
                .offset(y: -2.1)
                .rotationEffect(.degrees(42))

            Circle()
                .fill(tint)
                .frame(width: 3.8, height: 3.8)
                .offset(y: 3.7)
        }
        .frame(width: 15, height: 15)
        .accessibilityHidden(true)
    }
}

struct QuotaPopover: View {
    @ObservedObject var model: QuotaStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(now: context.date)
        }
        .frame(width: 340)
        .padding(18)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if let snapshot = model.snapshot {
                UsageCard(
                    title: "5 小时额度",
                    window: snapshot.fiveHour,
                    accent: .indigo,
                    now: now
                )
                UsageCard(
                    title: "周额度",
                    window: snapshot.weekly,
                    accent: .teal,
                    now: now
                )
            } else if model.isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在从 Codex 读取额度…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 18)
            } else {
                EmptyState(model: model)
            }

            if let errorMessage = model.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.snapshot == nil ? "读取失败" : "实时读取失败")
                            .font(.subheadline.weight(.semibold))
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
            }

            footer
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            CodexStatusMark(tint: model.statusColor)
                .scaleEffect(1.45)
                .frame(width: 30, height: 30)
                .background(model.statusColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text("Codex 用量")
                    .font(.title3.weight(.bold))
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(model.isLoading ? 360 : 0))
            }
            .buttonStyle(.borderless)
            .disabled(model.isLoading)
            .help("立即刷新")
        }
    }

    private var headerSubtitle: String {
        if model.isUsingCache {
            return "上次成功读取的缓存 · 仍会自动刷新"
        }
        if let planType = model.snapshot?.planType, !planType.isEmpty {
            return "\(planType.capitalized) · 数据来自 Codex app-server"
        }
        return "数据来自 Codex app-server"
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Toggle(
                    "自动刷新",
                    isOn: Binding(
                        get: { model.autoRefreshEnabled },
                        set: { model.setAutoRefresh($0) }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.small)

                HStack {
                    Label("刷新频率", systemImage: "timer")
                        .foregroundStyle(.secondary)

                    Spacer()

                    Picker(
                        "刷新频率",
                        selection: Binding(
                            get: { model.refreshInterval },
                            set: { model.setRefreshInterval($0) }
                        )
                    ) {
                        ForEach(QuotaRefreshInterval.allCases) { interval in
                            Text(interval.title).tag(interval)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .disabled(!model.autoRefreshEnabled)
                }

                Text(model.refreshInterval.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack {
                    Toggle(
                        "登录时自动启动",
                        isOn: Binding(
                            get: { model.launchAtLoginEnabled },
                            set: { model.setLaunchAtLogin($0) }
                        )
                    )
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    Spacer()

                    Button("打开 Codex") {
                        openCodex()
                    }
                    .buttonStyle(.borderless)
                }

                if let launchAtLoginMessage = model.launchAtLoginMessage {
                    Text(launchAtLoginMessage)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            HStack {
                if let lastUpdated = model.lastUpdated {
                    Image(systemName: model.isUsingCache ? "externaldrive" : "checkmark.circle.fill")
                        .foregroundStyle(model.isUsingCache ? Color.secondary : Color.green)
                    Text(model.isUsingCache ? "缓存于 \(Self.timeString(lastUpdated))" : "更新于 \(Self.timeString(lastUpdated))")
                } else {
                    Image(systemName: "clock")
                    Text("尚未成功读取")
                }

                Spacer()

                Button("退出") {
                    model.stop()
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func openCodex() {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.openai.codex"
        ) else {
            return
        }
        NSWorkspace.shared.open(applicationURL)
    }

    private static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

struct UsageCard: View {
    let title: String
    let window: CodexRateLimitWindow
    let accent: Color
    let now: Date

    private var usedColor: Color {
        switch window.clampedUsedPercent {
        case 90...100:
            return .red
        case 75..<90:
            return .orange
        default:
            return accent
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)
                Spacer()
                Text("剩余 \(window.remainingPercent)%")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(usedColor)
            }

            ProgressView(value: Double(window.clampedUsedPercent), total: 100)
                .tint(usedColor)

            HStack {
                Text("已使用 \(window.clampedUsedPercent)%")
                Spacer()
                Text(resetText)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(13)
        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)，已使用 \(window.clampedUsedPercent)%，剩余 \(window.remainingPercent)%，\(resetText)")
    }

    private var resetText: String {
        guard let resetDate = window.resetDate else {
            return "重置时间未知"
        }

        let seconds = resetDate.timeIntervalSince(now)
        if seconds <= 0 {
            return "即将重置"
        }
        if seconds < 3_600 {
            return "\(max(1, Int(seconds / 60))) 分钟后重置"
        }
        if seconds < 86_400 {
            return "\(Int(seconds / 3_600)) 小时后重置"
        }
        return "\(Int(seconds / 86_400)) 天后重置"
    }
}

struct EmptyState: View {
    @ObservedObject var model: QuotaStore

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: "wifi.exclamationmark")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("还没有额度数据")
                .font(.headline)
            Text("请确认 Codex 已安装并已登录，然后点击刷新。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("重试") {
                Task { await model.refresh() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }
}

private extension QuotaStore {
    var statusColor: Color {
        if snapshot == nil, errorMessage != nil {
            return .orange
        }
        let highestUsage = max(
            snapshot?.fiveHour.clampedUsedPercent ?? 0,
            snapshot?.weekly.clampedUsedPercent ?? 0
        )
        switch highestUsage {
        case 90...100:
            return .red
        case 75..<90:
            return .orange
        default:
            return .green
        }
    }
}
