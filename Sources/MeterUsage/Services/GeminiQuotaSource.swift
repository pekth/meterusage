import Foundation

public struct GeminiQuotaSource: QuotaSource {
    public let provider: Provider = .gemini

    private let configDirectory: URL
    private nonisolated(unsafe) let fileManager: FileManager

    public init(configDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.configDirectory = configDirectory ?? HomeDirectory.real.appendingPathComponent(".gemini", isDirectory: true)
        self.fileManager = fileManager
    }

    public func fetchQuota() async throws -> ProviderQuota {
        let candidates = [
            configDirectory.appendingPathComponent("quota.json"),
            configDirectory.appendingPathComponent("usage.json"),
            HomeDirectory.real.appendingPathComponent(".config/gemini/quota.json")
        ]

        if let validURL = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }),
           let data = try? Data(contentsOf: validURL),
           let quota = try? parseQuota(data: data) {
            return quota
        }

        // Check if accounts exist
        let accountsPath = configDirectory.appendingPathComponent("google_accounts.json").path
        let oauthPath = configDirectory.appendingPathComponent("oauth_creds.json").path
        if fileManager.fileExists(atPath: accountsPath) || fileManager.fileExists(atPath: oauthPath) {
            throw SourceUnavailable.dataNotFound("Gemini credentials")
        }

        throw SourceUnavailable.cliNotFound("Gemini CLI")
    }

    private func parseQuota(data: Data) throws -> ProviderQuota {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SourceUnavailable.noData
        }

        var windows: [QuotaWindow] = []
        if let requests = json["requests"] as? [String: Any],
           let used = requests["used_percent"] as? Double {
            let resetsAt = (requests["resets_at"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) }
            windows.append(QuotaWindow(label: "Daily", usedPercent: used, resetsAt: resetsAt, windowDurationMins: 1440))
        } else if let used = json["used_percent"] as? Double {
            windows.append(QuotaWindow(label: "Daily", usedPercent: used, windowDurationMins: 1440))
        }

        let plan = json["plan"] as? String ?? "Developer"
        return ProviderQuota(
            provider: .gemini,
            windows: windows,
            planType: plan,
            capturedAt: Date()
        )
    }
}
