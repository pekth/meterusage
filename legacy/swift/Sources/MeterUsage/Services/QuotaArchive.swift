import Foundation

// MARK: - Quota archive
//
// Persists the last good quota reading per provider so a cold start that
// cannot reach an endpoint opens on dated numbers instead of a blank ring.
// Only display metadata and reset pacing samples are stored. No credential, token, account id, or prompt text ever enters
// this file (sources never produce such values; see UsageModels).
//
// Restored readings are always stale-by-construction: callers must render
// them dimmed and dated, never as live numbers. Clearing the app cache
// (`~/Library/Application Support/MeterUsage`) deletes this file too, so a
// cold re-scan is genuinely cold.

enum QuotaArchive {

    /// Computed directly instead of reading through `AppCoordinator`: that
    /// type is `@MainActor`-isolated and this enum must stay nonisolated so
    /// `load`/`save` remain callable (and testable) off the main actor.
    static var defaultURL: URL {
        HomeDirectory.real
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("MeterUsage", isDirectory: true)
            .appendingPathComponent("quota-archive.json")
    }

    private struct Stored: Codable {
        var provider: Provider
        /// Empty for a primary slot; the generated id of an additional
        /// account. Absent in files written before slots existed — decoding
        /// defaults it to nil, which maps to the primary slot.
        var slotID: String?
        /// The account label at capture time, so a restored reading can keep
        /// naming its account. Display-only; identity is provider + slotID.
        var label: String?
        var windows: [QuotaWindow]
        var groups: [QuotaGroup]?
        var credits: CreditBalance?
        var resetCreditCount: Int?
        var resetCredits: [QuotaResetCredit]?
        var planType: String?
        var resetPacingSince: Date?
        var capturedAt: Date
    }

    /// Best-effort load. Any failure — missing file, malformed JSON, unknown
    /// provider key — yields an empty map rather than an error worth
    /// interrupting launch for.
    static func load(from url: URL) -> [ProviderSlot: ProviderQuota] {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([Stored].self, from: data)
        else { return [:] }
        var out: [ProviderSlot: ProviderQuota] = [:]
        for entry in stored {
            let slot = ProviderSlot(
                provider: entry.provider,
                slotID: entry.slotID ?? "",
                label: entry.label ?? ""
            )
            out[slot] = ProviderQuota(
                provider: entry.provider,
                windows: entry.windows,
                groups: entry.groups ?? [],
                credits: entry.credits,
                resetCreditCount: entry.resetCreditCount,
                resetCredits: entry.resetCredits ?? [],
                planType: entry.planType,
                resetPacingSince: entry.resetPacingSince,
                capturedAt: entry.capturedAt
            )
        }
        return out
    }

    /// Best-effort save. A cache that can't be written is not an error worth
    /// surfacing — the next sweep simply tries again.
    static func save(_ quotas: [ProviderSlot: ProviderQuota], to url: URL) {
        let stored = quotas.map { slot, quota in
            Stored(
                provider: slot.provider,
                slotID: slot.isPrimary ? nil : slot.slotID,
                label: slot.label.isEmpty ? nil : slot.label,
                windows: quota.windows,
                groups: quota.groups.isEmpty ? nil : quota.groups,
                credits: quota.credits,
                resetCreditCount: quota.resetCreditCount,
                resetCredits: quota.resetCredits.isEmpty ? nil : quota.resetCredits,
                planType: quota.planType,
                resetPacingSince: quota.resetPacingSince,
                capturedAt: quota.capturedAt
            )
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
