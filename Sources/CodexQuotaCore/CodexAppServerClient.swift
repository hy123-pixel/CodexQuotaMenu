import Foundation

public enum CodexAppServerError: LocalizedError, Equatable, Sendable {
    case executableNotFound
    case launchFailed(String)
    case processExited(Int32)
    case responseTimedOut
    case malformedResponse
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "找不到本机 Codex CLI，请确认 ChatGPT/Codex 已安装，或设置 CODEX_CLI_PATH。"
        case .launchFailed(let message):
            return "无法启动 Codex app-server：\(message)"
        case .processExited(let status):
            return "Codex app-server 已退出（状态码 \(status)）。"
        case .responseTimedOut:
            return "等待 Codex 额度响应超时。"
        case .malformedResponse:
            return "Codex 返回的数据格式无法识别。"
        case .server(let message):
            return "Codex 返回错误：\(message)"
        }
    }
}

/// Talks to the locally installed Codex app-server.
///
/// The client deliberately does not read or persist auth tokens. The Codex
/// process owns authentication and makes the same account-scoped request as
/// the Codex app itself.
@MainActor
public final class CodexAppServerClient {
    private let responseTimeoutNanoseconds: UInt64 = 20_000_000_000

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var outputBuffer = Data()
    private var nextRequestID = 1
    private var pendingResponses: [Int: CheckedContinuation<Data, Error>] = [:]
    private var isInitialized = false
    private var latestRateLimitsResponse: CodexRateLimitsResponse?

    /// Called when Codex emits an account/rateLimits/updated notification.
    /// The callback runs on the main actor and may receive a sparse update
    /// merged into the most recent full snapshot.
    public var onRateLimitsUpdated: ((CodexRateLimitsResponse) -> Void)?

    public init() {}

    public func fetchQuotaSnapshot() async throws -> CodexQuotaSnapshot {
        let resultData = try await fetchRateLimitsData()
        let response = try JSONDecoder().decode(CodexRateLimitsResponse.self, from: resultData)
        latestRateLimitsResponse = response
        return try CodexQuotaSnapshot(response: response)
    }

    public func stop() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil

        let continuations = pendingResponses.values
        pendingResponses.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: CodexAppServerError.processExited(-1))
        }

        if let process, process.isRunning {
            process.terminate()
        }

        try? inputPipe?.fileHandleForWriting.close()
        process = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        outputBuffer.removeAll(keepingCapacity: false)
        isInitialized = false
        latestRateLimitsResponse = nil
    }

    private func fetchRateLimitsData() async throws -> Data {
        try await ensureServerReady()
        return try await sendRequest(
            method: "account/rateLimits/read",
            params: NSNull()
        )
    }

    private func ensureServerReady() async throws {
        if isInitialized, let process, process.isRunning {
            return
        }

        stop()

        guard let executablePath = resolveCodexExecutable() else {
            throw CodexAppServerError.executableNotFound
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["app-server", "--stdio"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.environment = ProcessInfo.processInfo.environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.consumeOutput(data)
            }
        }

        // Drain stderr so a verbose Codex process cannot block on its pipe.
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        process.terminationHandler = { [weak self, weak process] terminatedProcess in
            Task { @MainActor [weak self, weak process] in
                guard let self, let process else { return }
                self.processDidTerminate(process, status: terminatedProcess.terminationStatus)
            }
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw CodexAppServerError.launchFailed(error.localizedDescription)
        }

        self.process = process
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe

        do {
            _ = try await sendRequest(
                method: "initialize",
                params: [
                    "clientInfo": [
                        "name": "codex-quota-menu",
                        "version": "0.2.0"
                    ],
                    "capabilities": [
                        "experimentalApi": true
                    ]
                ]
            )
            try sendNotification(method: "initialized", params: [:])
            isInitialized = true
        } catch {
            stop()
            throw error
        }
    }

    private func sendRequest(method: String, params: Any) async throws -> Data {
        guard let process, process.isRunning else {
            throw CodexAppServerError.processExited(-1)
        }

        let requestID = nextRequestID
        nextRequestID += 1

        let timeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: self?.responseTimeoutNanoseconds ?? 20_000_000_000)
            } catch {
                return
            }
            self?.failPendingResponse(
                requestID: requestID,
                with: CodexAppServerError.responseTimedOut
            )
        }
        defer { timeoutTask.cancel() }

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                pendingResponses[requestID] = continuation

                do {
                    try sendMessage(
                        method: method,
                        requestID: requestID,
                        params: params
                    )
                } catch {
                    pendingResponses.removeValue(forKey: requestID)
                    continuation.resume(throwing: error)
                }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.failPendingResponse(requestID: requestID, with: CancellationError())
            }
        })
    }

    private func sendNotification(method: String, params: Any) throws {
        try sendMessage(method: method, requestID: nil, params: params)
    }

    private func sendMessage(method: String, requestID: Int?, params: Any) throws {
        guard let inputPipe else {
            throw CodexAppServerError.processExited(-1)
        }

        var message: [String: Any] = [
            "method": method,
            "params": params
        ]
        if let requestID {
            message["id"] = requestID
        }

        var data = try JSONSerialization.data(withJSONObject: message, options: [])
        data.append(0x0A)
        try inputPipe.fileHandleForWriting.write(contentsOf: data)
    }

    private func consumeOutput(_ data: Data) {
        outputBuffer.append(data)

        while let newlineIndex = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer.subdata(in: 0..<newlineIndex)
            outputBuffer.removeSubrange(0...newlineIndex)
            consumeLine(line)
        }
    }

    private func consumeLine(_ line: Data) {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line, options: []),
              let dictionary = object as? [String: Any]
        else {
            return
        }

        if let method = dictionary["method"] as? String {
            if method == "account/rateLimits/updated" {
                consumeRateLimitsUpdate(dictionary["params"])
            }
            return
        }

        guard let requestID = requestID(from: dictionary["id"]) else { return }

        if let error = dictionary["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "未知错误"
            failPendingResponse(requestID: requestID, with: CodexAppServerError.server(message))
            return
        }

        guard let result = dictionary["result"],
              let resultData = try? JSONSerialization.data(withJSONObject: result, options: [])
        else {
            failPendingResponse(requestID: requestID, with: CodexAppServerError.malformedResponse)
            return
        }

        guard let continuation = pendingResponses.removeValue(forKey: requestID) else {
            return
        }
        continuation.resume(returning: resultData)
    }

    private func consumeRateLimitsUpdate(_ params: Any?) {
        guard let params,
              let paramsData = try? JSONSerialization.data(withJSONObject: params, options: []),
              let notification = try? JSONDecoder().decode(
                  RateLimitsUpdatedNotification.self,
                  from: paramsData
              )
        else {
            return
        }

        let mergedResponse: CodexRateLimitsResponse
        if let latestRateLimitsResponse {
            mergedResponse = CodexRateLimitsResponse(
                rateLimits: latestRateLimitsResponse.rateLimits.merged(with: notification.rateLimits)
            )
        } else {
            mergedResponse = CodexRateLimitsResponse(rateLimits: notification.rateLimits)
        }

        latestRateLimitsResponse = mergedResponse
        onRateLimitsUpdated?(mergedResponse)
    }

    private func requestID(from value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private func failPendingResponse(requestID: Int, with error: Error) {
        guard let continuation = pendingResponses.removeValue(forKey: requestID) else {
            return
        }
        continuation.resume(throwing: error)
    }

    private func processDidTerminate(_ terminatedProcess: Process, status: Int32) {
        guard process === terminatedProcess else { return }

        let continuations = pendingResponses.values
        pendingResponses.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: CodexAppServerError.processExited(status))
        }

        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        isInitialized = false
    }

    private func resolveCodexExecutable() -> String? {
        var candidates: [String] = []
        var seen = Set<String>()

        func addCandidate(_ path: String) {
            guard !path.isEmpty, seen.insert(path).inserted else { return }
            candidates.append(path)
        }

        if let configuredPath = ProcessInfo.processInfo.environment["CODEX_CLI_PATH"],
           !configuredPath.isEmpty {
            addCandidate(configuredPath)
        }

        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        let applicationRoots = [
            "/Applications/ChatGPT.app",
            "\(homeDirectory)/Applications/ChatGPT.app",
            "/Applications/Codex.app",
            "\(homeDirectory)/Applications/Codex.app"
        ]

        for applicationRoot in applicationRoots {
            let resourcesRoot = "\(applicationRoot)/Contents/Resources"
            let codexCLIContainer = URL(fileURLWithPath: resourcesRoot)
                .appendingPathComponent("codex-cli", isDirectory: true)

            // Current ChatGPT bundles ship a stable wrapper next to the
            // nested CLI app. Prefer it so the bundle can change its internal
            // executable location without breaking this menu bar tool.
            addCandidate(
                codexCLIContainer
                    .appendingPathComponent("bin/codex")
                    .path
            )

            // Older ChatGPT bundles shipped the executable directly here.
            addCandidate("\(resourcesRoot)/codex")

            // Current ChatGPT bundles keep the CLI inside a nested app.
            addCandidate("\(resourcesRoot)/codex-cli/CodexCLI.app/Contents/MacOS/codex")

            // Keep this resilient to a future nested CLI app name/version.
            if let entries = try? FileManager.default.contentsOfDirectory(
                at: codexCLIContainer,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                for entry in entries where entry.pathExtension == "app" {
                    addCandidate(
                        entry
                            .appendingPathComponent("Contents/MacOS/codex")
                            .path
                    )
                }
            }
        }

        candidates.append(contentsOf: [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/opt/local/bin/codex"
        ].filter { seen.insert($0).inserted })

        // GUI-launched apps often receive a shorter PATH than a login shell.
        // Cover the common per-user install locations as well.
        for path in [
            "\(homeDirectory)/bin/codex",
            "\(homeDirectory)/.local/bin/codex",
            "\(homeDirectory)/.npm-global/bin/codex",
            "\(homeDirectory)/.npm/bin/codex",
            "\(homeDirectory)/.volta/bin/codex",
            "\(homeDirectory)/.asdf/shims/codex",
            "\(homeDirectory)/Library/pnpm/codex"
        ] {
            addCandidate(path)
        }

        // npm installations managed by nvm/fnm are versioned and are not
        // always present in the environment inherited by a menu bar app.
        for versionRoot in [
            "\(homeDirectory)/.nvm/versions/node",
            "\(homeDirectory)/.fnm/node-versions"
        ] {
            let rootURL = URL(fileURLWithPath: versionRoot, isDirectory: true)
            if let entries = try? FileManager.default.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                for entry in entries {
                    guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                        continue
                    }
                    addCandidate(
                        entry
                            .appendingPathComponent("installation/bin/codex")
                            .path
                    )
                    addCandidate(
                        entry
                            .appendingPathComponent("bin/codex")
                            .path
                    )
                }
            }
        }

        if let pathEnvironment = ProcessInfo.processInfo.environment["PATH"] {
            for directory in pathEnvironment.split(separator: ":", omittingEmptySubsequences: true) {
                addCandidate(
                    URL(fileURLWithPath: String(directory))
                        .appendingPathComponent("codex")
                        .path
                )
            }
        }

        return candidates.first(where: FileManager.default.isExecutableFile(atPath:))
    }
}

private struct RateLimitsUpdatedNotification: Decodable {
    let rateLimits: CodexRateLimitSnapshot
}
