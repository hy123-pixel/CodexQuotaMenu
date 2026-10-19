import Foundation

public struct CodexVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(_ value: String) {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^v", with: "", options: .regularExpression)
            .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
            .first

        guard let normalized else { return nil }
        let components = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count), components.allSatisfy({ Int($0) != nil }) else {
            return nil
        }

        major = Int(components[0]) ?? 0
        minor = components.count > 1 ? Int(components[1]) ?? 0 : 0
        patch = components.count > 2 ? Int(components[2]) ?? 0 : 0
    }

    public var description: String {
        "v\(major).\(minor).\(patch)"
    }

    public static func < (lhs: CodexVersion, rhs: CodexVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

public struct CodexReleaseAsset: Codable, Equatable, Sendable {
    public let name: String
    public let browserDownloadURL: URL
    public let digest: String?

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case digest
    }
}

public struct CodexRelease: Codable, Equatable, Sendable {
    public let tagName: String
    public let name: String
    public let htmlURL: URL
    public let publishedAt: Date?
    public let assets: [CodexReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case assets
    }

    public var version: CodexVersion? {
        CodexVersion(tagName)
    }

    public var macOSUniversalAsset: CodexReleaseAsset? {
        assets.first { asset in
            let lowercasedName = asset.name.lowercased()
            return lowercasedName.hasPrefix("codexquotamenu-macos-universal-")
                && lowercasedName.hasSuffix(".zip")
        }
    }
}
