import Foundation

public struct CopilotQuotaSource: QuotaSource {
    public let provider: Provider = .copilot

    private let configDirectory: URL
    private nonisolated(unsafe) let fileManager: FileManager

    public init(configDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.configDirectory = configDirectory ?? HomeDirectory.real.appendingPathComponent(".copilot", isDirectory: true)
        self.fileManager = fileManager
    }

    public func fetchQuota() async throws -> ProviderQuota {
        let candidates = [
            configDirectory.appendingPathComponent("quota.json"),
            configDirectory.appendingPathComponent("usage.json"),
            HomeDirectory.real.appendingPathComponent(".config/github-copilot/quota.json")
        ]

        if let validURL = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }),
           let data = try? Data(contentsOf: validURL),
           let quota = try? parseQuota(data: data) {
            return quota
        }

        // Check if Copilot CLI config exists
        let configPath = configDirectory.appendingPathComponent("config.json").path
        let hostsPath = HomeDirectory.real.appendingPathComponent(".config/github-copilot/hosts.json").path
        if fileManager.fileExists(atPath: configPath) || fileManager.fileExists(atPath: hostsPath) {
            throw SourceUnavailable.dataNotFound("Copilot credentials")
        }

        throw SourceUnavailable.cliNotFound("Copilot CLI")
    }

    private func parseQuota(data: Data) throws -> ProviderQuota {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SourceUnavailable.noData
        }

        var windows: [QuotaWindow] = []
        if let premium = json["premium_requests"] as? [String: Any],
           let used = premium["used_percent"] as? Double {
            let resetsAt = (premium["resets_at"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) }
            windows.append(QuotaWindow(label: "Premium requests", usedPercent: used, resetsAt: resetsAt, windowDurationMins: 43200))
        } else if let used = json["used_percent"] as? Double {
            windows.append(QuotaWindow(label: "Monthly", usedPercent: used, windowDurationMins: 43200))
        }

        let plan = json["plan"] as? String ?? "Individual"
        return ProviderQuota(
            provider: .copilot,
            windows: windows,
            planType: plan,
            capturedAt: Date()
        )
    }
}
