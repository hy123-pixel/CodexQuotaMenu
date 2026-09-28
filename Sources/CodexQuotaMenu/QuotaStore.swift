import Foundation
import ServiceManagement
import SwiftUI
import CodexQuotaCore

enum QuotaRefreshInterval: Int, CaseIterable, Hashable, Identifiable {
    case followCodex = 0
    case thirtySeconds = 30
    case oneMinute = 60
    case threeMinutes = 180
    case fiveMinutes = 300
    case tenMinutes = 600

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .followCodex:
            return "跟随 Codex（智能）"
        case .thirtySeconds:
            return "30 秒"
        case .oneMinute:
            return "1 分钟"
        case .threeMinutes:
            return "3 分钟"
        case .fiveMinutes:
            return "5 分钟"
        case .tenMinutes:
            return "10 分钟"
        }
    }

    var fallbackSeconds: UInt64 {
        self == .followCodex ? 30 : UInt64(rawValue)
    }

    var detail: String {
        self == .followCodex ? "有 Codex 通知时立即更新，无通知时 30 秒兜底" : "每次读取间隔：\(title)"
    }
}

@MainActor
final class QuotaStore: ObservableObject {
    @Published private(set) var snapshot: CodexQuotaSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isUsingCache = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var autoRefreshEnabled: Bool
    @Published private(set) var refreshInterval: QuotaRefreshInterval
    @Published private(set) var launchAtLoginEnabled: Bool
    @Published private(set) var launchAtLoginMessage: String?

    private let cacheKey = "codex-quota-menu.last-successful-snapshot"
    private let refreshIntervalKey = "codex-quota-menu.refresh-interval"
    private let client: CodexAppServerClient
    private var pollingTask: Task<Void, Never>?

    init() {
        self.client = CodexAppServerClient()
        self.autoRefreshEnabled = UserDefaults.standard.object(forKey: "codex-quota-menu.auto-refresh") as? Bool ?? true
        let savedInterval = UserDefaults.standard.object(forKey: refreshIntervalKey) as? Int ?? QuotaRefreshInterval.followCodex.rawValue
        self.refreshInterval = QuotaRefreshInterval(rawValue: savedInterval) ?? .followCodex
        self.launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        self.client.onRateLimitsUpdated = { [weak self] response in
            self?.applyRateLimitsUpdate(response)
        }
        loadCachedSnapshot()
        startPolling()
    }

    deinit {
        pollingTask?.cancel()
    }

    var menuBarText: String {
        guard let snapshot else {
            return isLoading ? "Codex …" : "Codex —"
        }
        return "5h \(snapshot.fiveHour.remainingPercent)% · 周 \(snapshot.weekly.remainingPercent)%"
    }

    func refresh() async {
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil

        do {
            let newSnapshot = try await client.fetchQuotaSnapshot()
            applySnapshot(newSnapshot)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func setAutoRefresh(_ enabled: Bool) {
        autoRefreshEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "codex-quota-menu.auto-refresh")

        pollingTask?.cancel()
        pollingTask = nil
        if enabled {
            startPolling()
        }
    }

    func setRefreshInterval(_ interval: QuotaRefreshInterval) {
        refreshInterval = interval
        UserDefaults.standard.set(interval.rawValue, forKey: refreshIntervalKey)

        pollingTask?.cancel()
        pollingTask = nil
        if autoRefreshEnabled {
            startPolling()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            launchAtLoginMessage = launchAtLoginEnabled == enabled ? nil : "请到系统设置的登录项中确认。"
        } catch {
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            launchAtLoginMessage = error.localizedDescription
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        client.stop()
    }

    private func startPolling() {
        guard autoRefreshEnabled, pollingTask == nil else { return }

        pollingTask = Task { [weak self] in
            guard let self else { return }

            await self.refresh()

            while !Task.isCancelled {
                do {
                    let delay = self.refreshInterval.fallbackSeconds * 1_000_000_000
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    break
                }

                guard !Task.isCancelled, self.autoRefreshEnabled else { break }
                await self.refresh()
            }
        }
    }

    private func applyRateLimitsUpdate(_ response: CodexRateLimitsResponse) {
        guard autoRefreshEnabled,
              let updatedSnapshot = try? CodexQuotaSnapshot(response: response, fetchedAt: Date())
        else {
            return
        }
        applySnapshot(updatedSnapshot)
    }

    private func applySnapshot(_ newSnapshot: CodexQuotaSnapshot) {
        snapshot = newSnapshot
        lastUpdated = newSnapshot.fetchedAt
        isUsingCache = false
        errorMessage = nil
        saveCachedSnapshot(newSnapshot)
    }

    private func loadCachedSnapshot() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let cachedSnapshot = try? JSONDecoder().decode(CodexQuotaSnapshot.self, from: data)
        else {
            return
        }

        snapshot = cachedSnapshot
        lastUpdated = cachedSnapshot.fetchedAt
        isUsingCache = true
    }

    private func saveCachedSnapshot(_ snapshot: CodexQuotaSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }
}
