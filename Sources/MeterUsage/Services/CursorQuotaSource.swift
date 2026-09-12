import Foundation

public struct CursorQuotaSource: QuotaSource {
    public let provider: Provider = .cursor

    private let configDirectory: URL
    private nonisolated(unsafe) let fileManager: FileManager

    public init(configDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.configDirectory = configDirectory ?? HomeDirectory.real.appendingPathComponent(".cursor", isDirectory: true)
        self.fileManager = fileManager
    }

    public func fetchQuota() async throws -> ProviderQuota {
        // Look for local usage file or state in ~/.cursor/quota.json or ~/.cursor/usage.json
        let candidates = [
            configDirectory.appendingPathComponent("quota.json"),
            configDirectory.appendingPathComponent("usage.json"),
            HomeDirectory.real.appendingPathComponent("Library/Application Support/Cursor/quota.json")
        ]

        if let validURL = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }),
           let data = try? Data(contentsOf: validURL),
           let quota = try? parseQuota(data: data) {
            return quota
        }

        // Check if Cursor directory exists at all to give appropriate unavailability reason
        if fileManager.fileExists(atPath: configDirectory.path) ||
           fileManager.fileExists(atPath: HomeDirectory.real.appendingPathComponent("Library/Application Support/Cursor").path) {
            throw SourceUnavailable.dataNotFound("Cursor credentials")
        }

        throw SourceUnavailable.cliNotFound("Cursor")
    }

    private func parseQuota(data: Data) throws -> ProviderQuota {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SourceUnavailable.noData
        }

        var windows: [QuotaWindow] = []
        if let fastRequests = json["fast_requests"] as? [String: Any],
           let used = fastRequests["used_percent"] as? Double {
            let resetsAt = (fastRequests["resets_at"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) }
            windows.append(QuotaWindow(label: "Fast requests", usedPercent: used, resetsAt: resetsAt, windowDurationMins: 43200))
        } else if let used = json["used_percent"] as? Double {
            windows.append(QuotaWindow(label: "Monthly", usedPercent: used, windowDurationMins: 43200))
        }

        let plan = json["plan"] as? String ?? "Pro"
        return ProviderQuota(
            provider: .cursor,
            windows: windows,
            planType: plan,
            capturedAt: Date()
        )
    }
}
