import AppKit
import Combine
import SwiftUI
import CodexQuotaCore

@main
struct CodexQuotaMenuApp: App {
    @NSApplicationDelegateAdaptor(CodexQuotaMenuAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
private final class CodexQuotaMenuAppDelegate: NSObject, NSApplicationDelegate {
    private var model: QuotaStore!
    private var updateStore: UpdateStore!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var modelObserver: AnyCancellable?
    private var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        model = QuotaStore()
        updateStore = UpdateStore()
        updateStore.startAutomaticChecks()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureStatusButton()
        configurePopover()
        installOutsideClickMonitor()

        // QuotaStore publishes before its values change. Dispatching the
        // button update keeps the native status item in sync with the new
        // snapshot while preserving AppKit's native centering behavior.
        modelObserver = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.updateStatusButton()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stop()
        updateStore?.stopAutomaticChecks()
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }

        let image = NSImage(
            systemSymbolName: "gauge",
            accessibilityDescription: "Codex 用量"
        )
        image?.isTemplate = true
        image?.size = NSSize(width: 16, height: 16)

        button.image = image
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.alignment = .center
        button.font = NSFont.menuBarFont(ofSize: 0)
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.toolTip = "Codex 用量"

        updateStatusButton()
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 376, height: 590)
        popover.contentViewController = NSHostingController(
            rootView: QuotaPopover(model: model, updateStore: updateStore)
        )
    }

    private func installOutsideClickMonitor() {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.popover.isShown else { return }
                self.popover.performClose(nil)
            }
        }
    }

    private func updateStatusButton() {
        guard let button = statusItem?.button else { return }

        button.attributedTitle = NSAttributedString(
            string: model?.menuBarText ?? "Codex —",
            attributes: [
                .font: NSFont.menuBarFont(ofSize: 0),
                .baselineOffset: -0.75
            ]
        )
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.popover.isShown else { return }
                // An accessory app does not become active just because its
                // popover is shown. Make the popover the active/key surface so
                // SwiftUI controls render and behave as the current selection.
                NSApp.activate(ignoringOtherApps: true)
                self.popover.contentViewController?.view.window?.makeKey()
            }
        }
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
    @ObservedObject var updateStore: UpdateStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(now: context.date)
        }
        .frame(width: 340)
        .padding(18)
        .background(.background)
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

                    Menu {
                        ForEach(QuotaRefreshInterval.allCases) { interval in
                            Button {
                                model.setRefreshInterval(interval)
                            } label: {
                                if interval == model.refreshInterval {
                                    Label(interval.title, systemImage: "checkmark")
                                } else {
                                    Text(interval.title)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(model.refreshInterval.title)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2.weight(.semibold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Color.secondary.opacity(0.16),
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
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

                Divider()

                HStack(spacing: 8) {
                    Label("应用更新", systemImage: updateStore.hasUpdate ? "arrow.down.circle.fill" : "arrow.triangle.2.circlepath")
                        .foregroundStyle(updateStore.hasUpdate ? Color.accentColor : .secondary)

                    Spacer()

                    if updateStore.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button(updateStore.actionTitle) {
                            if updateStore.hasUpdate {
                                updateStore.downloadAndInstall()
                            } else {
                                updateStore.checkNow()
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                }

                Text(updateStore.statusText)
                    .font(.caption2)
                    .foregroundStyle(updateStore.hasUpdate ? Color.accentColor : .secondary)
                    .lineLimit(2)
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
