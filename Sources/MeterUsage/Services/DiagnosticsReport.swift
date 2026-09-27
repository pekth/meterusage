import Foundation

// MARK: - Diagnostics
//
// A copy-pasteable, sanitized summary of *why* the dashboard looks the way it
// does. Exists because every provider error is deliberately collapsed to a
// category before display (provider payloads can echo URLs, headers and
// account hints), which leaves a user with "Couldn't read Codex usage" and no
// way to describe the problem when filing an issue.
//
// The report carries categories and counts only, including local history
// persistence status: no paths, no hostnames, no account ids, no raw provider
// errors. Enforced by test.

enum DiagnosticsReport {

    /// Builds the report text. Every input comes from coordinator state; the
    /// function is pure so tests can pin its exact shape.
    static func build(
        appName: String,
        appVersion: String,
        isDemoMode: Bool,
        refreshInterval: TimeInterval,
        lastRefreshedAt: Date?,
        now: Date,
        enabledSlots: [ProviderSlot],
        quotas: [ProviderSlot: Loaded<ProviderQuota>],
        activities: [ProviderSlot: Loaded<LocalActivity>],
        usages: [ProviderSlot: Loaded<ProviderUsage>],
        statuses: [Provider: Loaded<ServiceStatus>],
        plans: [ProviderSlot: Loaded<PlanTier>],
        historyError: DurableHistoryStoreError? = nil
    ) -> String {
        var lines: [String] = []
        lines.append("\(appName) \(appVersion)")
        lines.append(isDemoMode ? "mode: demo" : "mode: live")
        lines.append("refresh interval: \(Int(refreshInterval))s")
        if let last = lastRefreshedAt {
            lines.append("last refresh: \(Fmt.timeSince(last, now: now))")
        } else {
            lines.append("last refresh: never")
        }
        lines.append("enabled: \(enabledSlots.map(\.key).sorted().joined(separator: ", "))")
        lines.append("")

        if let historyError {
            lines.append("history: \(historyError.rawValue)")
        }

        for slot in enabledSlots {
            lines.append("[\(slot.key)]")

            if let state = quotas[slot] {
                line(&lines, "quota", describe(state))
                if let quota = state.value {
                    let windows = quota.windows.map { "\($0.label) \(Fmt.percent($0.usedPercent))" }
                    if !windows.isEmpty {
                        lines.append("  windows: \(windows.joined(separator: ", "))")
                    }
                    if quota.resetCreditCount != nil || !quota.resetCredits.isEmpty {
                        let count = quota.resetCreditCount ?? quota.resetCredits.count
                        lines.append("  reset credits: \(count)")
                    }
                }
            }
            if let state = activities[slot] {
                line(&lines, "activity", describe(state))
            }
            if let state = usages[slot] {
                line(&lines, "usage", describe(state))
            }
            if let state = statuses[slot.provider] {
                line(&lines, "status", describe(state))
            }
            if let state = plans[slot] {
                line(&lines, "plan", describe(state))
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    /// One labelled state line, indented under the provider heading.
    private static func line(_ lines: inout [String], _ label: String, _ description: String) {
        lines.append("  \(label): \(description)")
    }

    /// Describes one source outcome as a stable category string.
    ///
    /// Values are intentionally terse machine-ish tokens rather than prose:
    /// they are greppable in issue reports and can never leak a payload.
    private static func describe<T>(_ state: Loaded<T>) -> String {
        switch state {
        case .idle:
            return "not checked yet"
        case .value:
            return "ok"
        case .missing(let reason):
            return "unavailable (\(category(of: reason)))"
        }
    }

    private static func category(of reason: SourceUnavailable) -> String {
        switch reason {
        case .cliNotFound:      return "cliNotFound"
        case .notSignedIn:      return "notSignedIn"
        case .offline:          return "offline"
        case .failed:           return "failed"
        case .noData:           return "noData"
        case .dataNotFound:     return "dataNotFound"
        }
    }
}
