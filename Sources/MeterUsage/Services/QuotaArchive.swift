import Foundation

// MARK: - Quota archive
//
// Persists the last good quota reading per provider so a cold start that
// cannot reach an endpoint opens on dated numbers instead of a blank ring.
// Only what the UI already displays is stored — window labels, percents, and
// reset times. No credential, token, account id, or prompt text ever enters
// this file (sources never produce such values; see UsageModels).
//
// Restored readings are always stale-by-construction: callers must render
// them dimmed and dated, never as live numbers. Clearing the app cache
// (`~/Library/Application Support/MeterUsage`) deletes this file too, so a
// cold re-scan is genuinely cold.

enum QuotaArchive {

    static var defaultURL: URL {
        AppCoordinator.cacheDirectory.appendingPathComponent("quota-archive.json")
    }

    private struct Stored: Codable {
        var provider: Provider
        var windows: [Window]
        var capturedAt: Date
    }

    private struct Window: Codable {
        var label: String
        var usedPercent: Double
        var resetsAt: Date?
    }

    /// Best-effort load. Any failure — missing file, malformed JSON, unknown
    /// provider key — yields an empty map rather than an error worth
    /// interrupting launch for.
    static func load(from url: URL) -> [Provider: ProviderQuota] {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([Stored].self, from: data)
        else { return [:] }
        var out: [Provider: ProviderQuota] = [:]
        for entry in stored {
            out[entry.provider] = ProviderQuota(
                provider: entry.provider,
                windows: entry.windows.map {
                    QuotaWindow(label: $0.label, usedPercent: $0.usedPercent, resetsAt: $0.resetsAt)
                },
                capturedAt: entry.capturedAt
            )
        }
        return out
    }

    /// Best-effort save. A cache that can't be written is not an error worth
    /// surfacing — the next sweep simply tries again.
    static func save(_ quotas: [Provider: ProviderQuota], to url: URL) {
        let stored = quotas.map { provider, quota in
            Stored(
                provider: provider,
                windows: quota.windows.map {
                    Window(label: $0.label, usedPercent: $0.usedPercent, resetsAt: $0.resetsAt)
                },
                capturedAt: quota.capturedAt
            )
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
