import Foundation

public enum CodexQuotaModelError: LocalizedError, Equatable, Sendable {
    case missingFiveHourWindow
    case missingWeeklyWindow

    public var errorDescription: String? {
        switch self {
        case .missingFiveHourWindow:
            return "Codex 没有返回 5 小时额度窗口。"
        case .missingWeeklyWindow:
            return "Codex 没有返回周额度窗口。"
        }
    }
}

public struct CodexRateLimitsResponse: Codable, Equatable, Sendable {
    public let rateLimits: CodexRateLimitSnapshot

    public init(rateLimits: CodexRateLimitSnapshot) {
        self.rateLimits = rateLimits
    }
}

public struct CodexRateLimitSnapshot: Codable, Equatable, Sendable {
    public let primary: CodexRateLimitWindow?
    public let secondary: CodexRateLimitWindow?
    public let planType: String?
    public let rateLimitReachedType: String?

    public init(
        primary: CodexRateLimitWindow?,
        secondary: CodexRateLimitWindow?,
        planType: String? = nil,
        rateLimitReachedType: String? = nil
    ) {
        self.primary = primary
        self.secondary = secondary
        self.planType = planType
        self.rateLimitReachedType = rateLimitReachedType
    }

    public func merged(with update: CodexRateLimitSnapshot) -> CodexRateLimitSnapshot {
        CodexRateLimitSnapshot(
            primary: update.primary ?? primary,
            secondary: update.secondary ?? secondary,
            planType: update.planType ?? planType,
            rateLimitReachedType: update.rateLimitReachedType ?? rateLimitReachedType
        )
    }
}

public struct CodexRateLimitWindow: Codable, Equatable, Sendable {
    public let usedPercent: Int
    public let windowDurationMins: Int64?
    public let resetsAt: Int64?

    public init(usedPercent: Int, windowDurationMins: Int64?, resetsAt: Int64?) {
        self.usedPercent = usedPercent
        self.windowDurationMins = windowDurationMins
        self.resetsAt = resetsAt
    }

    public var clampedUsedPercent: Int {
        min(max(usedPercent, 0), 100)
    }

    public var remainingPercent: Int {
        100 - clampedUsedPercent
    }

    public var resetDate: Date? {
        guard let resetsAt else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(resetsAt))
    }
}

public struct CodexQuotaSnapshot: Codable, Equatable, Sendable {
    public let fiveHour: CodexRateLimitWindow
    public let weekly: CodexRateLimitWindow
    public let planType: String?
    public let fetchedAt: Date

    public init(response: CodexRateLimitsResponse, fetchedAt: Date = Date()) throws {
        guard let fiveHour = response.rateLimits.primary else {
            throw CodexQuotaModelError.missingFiveHourWindow
        }
        guard let weekly = response.rateLimits.secondary else {
            throw CodexQuotaModelError.missingWeeklyWindow
        }

        self.fiveHour = fiveHour
        self.weekly = weekly
        self.planType = response.rateLimits.planType
        self.fetchedAt = fetchedAt
    }
}
