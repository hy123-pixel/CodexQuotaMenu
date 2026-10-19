import AppKit
import Combine
import CryptoKit
import Foundation
import CodexQuotaCore

@MainActor
final class UpdateStore: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(CodexRelease)
        case downloading(CodexRelease)
        case installing(CodexRelease)
        case failed(String)
    }

    private enum UpdateError: LocalizedError {
        case invalidResponse
        case missingAsset
        case checksumMismatch
        case extractedAppMissing
        case installLocationUnsupported
        case processFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "GitHub 返回了无法识别的更新信息。"
            case .missingAsset:
                return "该版本没有可用的 macOS 通用安装包。"
            case .checksumMismatch:
                return "安装包校验失败，已停止更新。"
            case .extractedAppMissing:
                return "安装包中没有找到 CodexQuotaMenu.app。"
            case .installLocationUnsupported:
                return "当前 App 位置不支持自动替换，请手动下载更新。"
            case let .processFailed(message):
                return "解压更新包失败：\(message)"
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastCheckedAt: Date?

    private let currentVersion: CodexVersion
    private let defaults = UserDefaults.standard
    private let lastCheckKey = "codex-quota-menu.last-update-check"
    private let repositoryAPI = URL(string: "https://api.github.com/repos/hy123-pixel/CodexQuotaMenu/releases/latest")!
    private let automaticCheckInterval: TimeInterval = 12 * 60 * 60
    private var automaticCheckTask: Task<Void, Never>?

    init() {
        currentVersion = CodexVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0")!
        lastCheckedAt = defaults.object(forKey: lastCheckKey) as? Date
    }

    var availableRelease: CodexRelease? {
        if case let .available(release) = state {
            return release
        }
        return nil
    }

    var hasUpdate: Bool {
        availableRelease != nil
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing:
            return true
        default:
            return false
        }
    }

    var actionTitle: String {
        if hasUpdate { return "下载并更新" }
        if case .failed = state { return "重试" }
        return "检查更新"
    }

    var statusText: String {
        switch state {
        case .idle:
            return "启动时自动检查更新"
        case .checking:
            return "正在检查 GitHub Release…"
        case .upToDate:
            return "当前已是最新版本（\(currentVersion)）"
        case let .available(release):
            return "发现新版本 \(release.version.map(String.init(describing:)) ?? release.tagName)"
        case let .downloading(release):
            return "正在下载 \(release.version.map(String.init(describing:)) ?? release.tagName)…"
        case let .installing(release):
            return "正在安装 \(release.version.map(String.init(describing:)) ?? release.tagName)，即将重启…"
        case let .failed(message):
            return message
        }
    }

    func startAutomaticChecks() {
        guard automaticCheckTask == nil else { return }

        automaticCheckTask = Task { [weak self] in
            guard let self else { return }
            checkIfDue()

            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(automaticCheckInterval * 1_000_000_000))
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                checkNow()
            }
        }
    }

    func stopAutomaticChecks() {
        automaticCheckTask?.cancel()
        automaticCheckTask = nil
    }

    private func checkIfDue() {
        guard lastCheckedAt == nil || Date().timeIntervalSince(lastCheckedAt!) >= automaticCheckInterval else {
            return
        }
        checkNow()
    }

    func checkNow() {
        guard !isBusy else { return }
        state = .checking

        Task { [weak self] in
            guard let self else { return }

            do {
                let release = try await fetchLatestRelease()
                let checkedAt = Date()
                lastCheckedAt = checkedAt
                defaults.set(checkedAt, forKey: lastCheckKey)

                guard let releaseVersion = release.version,
                      releaseVersion > currentVersion else {
                    state = .upToDate
                    return
                }

                guard release.macOSUniversalAsset != nil else {
                    state = .failed("发现新版本 \(release.tagName)，但没有可用的 macOS 通用安装包。")
                    return
                }

                state = .available(release)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func downloadAndInstall() {
        guard case let .available(release) = state else { return }
        state = .downloading(release)

        Task { [weak self] in
            guard let self else { return }

            do {
                try await downloadAndInstall(release)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func fetchLatestRelease() async throws -> CodexRelease {
        var request = URLRequest(url: repositoryAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CodexQuotaMenu/0.1", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw UpdateError.invalidResponse
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CodexRelease.self, from: data)
    }

    private func downloadAndInstall(_ release: CodexRelease) async throws {
        guard let asset = release.macOSUniversalAsset else {
            throw UpdateError.missingAsset
        }

        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("CodexQuotaMenuUpdate-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        var request = URLRequest(url: asset.browserDownloadURL)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("CodexQuotaMenu/0.1", forHTTPHeaderField: "User-Agent")

        let (downloadedURL, response) = try await URLSession.shared.download(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw UpdateError.invalidResponse
        }

        let zipURL = temporaryDirectory.appendingPathComponent(asset.name)
        try fileManager.moveItem(at: downloadedURL, to: zipURL)
        try verify(zipURL: zipURL, expectedDigest: asset.digest)

        let extractionDirectory = temporaryDirectory.appendingPathComponent("extracted", isDirectory: true)
        try fileManager.createDirectory(at: extractionDirectory, withIntermediateDirectories: true)
        try runDittoExtract(zipURL: zipURL, destination: extractionDirectory)

        guard let appURL = fileManager.enumerator(
            at: extractionDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )?.compactMap({ $0 as? URL }).first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.extractedAppMissing
        }

        state = .installing(release)
        try install(appURL: appURL)
    }

    private func verify(zipURL: URL, expectedDigest: String?) throws {
        guard let expectedDigest,
              let expectedHex = expectedDigest.split(separator: ":", maxSplits: 1).last,
              expectedDigest.lowercased().hasPrefix("sha256:") else {
            return
        }

        let data = try Data(contentsOf: zipURL)
        let actualHex = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()

        guard actualHex.caseInsensitiveCompare(String(expectedHex)) == .orderedSame else {
            throw UpdateError.checksumMismatch
        }
    }

    private func runDittoExtract(zipURL: URL, destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, destination.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "未知错误"
            throw UpdateError.processFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func install(appURL: URL) throws {
        let fileManager = FileManager.default
        let currentAppURL = Bundle.main.bundleURL.standardizedFileURL
        guard currentAppURL.pathExtension == "app" else {
            throw UpdateError.installLocationUnsupported
        }

        let backupURL = currentAppURL.deletingLastPathComponent()
            .appendingPathComponent(".CodexQuotaMenu-backup-\(UUID().uuidString).app")

        do {
            try fileManager.moveItem(at: currentAppURL, to: backupURL)
            do {
                try fileManager.moveItem(at: appURL, to: currentAppURL)
            } catch {
                try? fileManager.moveItem(at: backupURL, to: currentAppURL)
                throw error
            }
            try? fileManager.removeItem(at: backupURL)
        } catch {
            throw UpdateError.installLocationUnsupported
        }

        relaunchAfterTermination(at: currentAppURL)
    }

    private func relaunchAfterTermination(at appURL: URL) {
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        relauncher.arguments = [
            "-c",
            "sleep 1; exec /usr/bin/open -- \"$1\"",
            "CodexQuotaMenuUpdater",
            appURL.path
        ]
        relauncher.standardInput = FileHandle.nullDevice
        relauncher.standardOutput = FileHandle.nullDevice
        relauncher.standardError = FileHandle.nullDevice
        try? relauncher.run()
        NSApp.terminate(nil)
    }
}
