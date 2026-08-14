import Foundation

/// A newly issued provider reset that was not present in the preceding
/// successful quota snapshot.
struct QuotaResetAvailabilityEvent: Equatable, Sendable {
    let provider: Provider
    let newResetCount: Int
}

/// Compares successive successful quota snapshots without treating the first
/// snapshot as a new event. Source failures never reach this type, so a
/// temporary outage cannot erase its last known baseline.
struct QuotaResetAvailabilityDetector {
    private struct WindowSnapshot {
        let usedPercent: Double
        let resetsAt: Date?
    }

    private struct Snapshot {
        let count: Int
        let creditIDs: Set<String>
        let windows: [String: WindowSnapshot]
    }

    private var snapshots: [Provider: Snapshot] = [:]

    mutating func observe(_ quota: ProviderQuota) -> QuotaResetAvailabilityEvent? {
        let creditIDs = Set(
            quota.resetCredits
                .filter { credit in
                    credit.status?.lowercased() == "available"
                        && (credit.expiresAt.map { $0 > quota.capturedAt } ?? true)
                }
                .map(\.id)
        )
        let current = Snapshot(
            count: max(quota.resetCreditCount ?? 0, creditIDs.count),
            creditIDs: creditIDs,
            windows: Dictionary(
                quota.windows.map { window in
                    (window.label.lowercased(), WindowSnapshot(
                        usedPercent: window.usedPercent,
                        resetsAt: window.resetsAt
                    ))
                },
                uniquingKeysWith: { current, _ in current }
            )
        )
        let previous = snapshots.updateValue(current, forKey: quota.provider)
        guard let previous else { return nil }

        var newResetCount = max(0, current.count - previous.count)
        // IDs catch a replacement reset when the total stays constant. Only
        // trust that comparison when the prior snapshot described every reset;
        // otherwise a provider filling in previously omitted details would look
        // like a newly issued credit.
        if previous.creditIDs.count == previous.count {
            newResetCount = max(
                newResetCount,
                current.creditIDs.subtracting(previous.creditIDs).count
            )
        }
        newResetCount = max(
            newResetCount,
            current.windows.reduce(into: 0) { count, entry in
                guard let oldWindow = previous.windows[entry.key] else { return }
                let newWindow = entry.value
                guard let oldReset = oldWindow.resetsAt,
                      let newReset = newWindow.resetsAt,
                      newWindow.usedPercent < oldWindow.usedPercent,
                      newReset > oldReset.addingTimeInterval(1),
                      newReset > quota.capturedAt
                else { return }
                count += 1
            }
        )
        guard newResetCount > 0 else { return nil }

        return QuotaResetAvailabilityEvent(
            provider: quota.provider,
            newResetCount: newResetCount
        )
    }
}
