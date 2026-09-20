import Foundation

public enum BurnAttributionCalculator {
    /// Sessions feeding burn attribution: real per-session histories plus one
    /// synthetic aggregate per token-bearing usage provider that cannot split
    /// its week total (Antigravity, OpenRouter), which expose totals but no
    /// per-session list. A provider that reports a per-project breakdown
    /// (OpenCode Go) contributes one synthetic row per project instead, so the
    /// top rows name projects rather than the provider. Aggregates carry week
    /// tokens with an empty model and `isAggregate`, so they join token totals
    /// without ever posing as one long chat.
    static func attributionSessions(
        activities: [Provider: Loaded<LocalActivity>],
        usages: [Provider: Loaded<ProviderUsage>],
        now: Date = Date()
    ) -> [SessionSummary] {
        var result: [SessionSummary] = []
        for provider in Provider.allCases {
            if let act = activities[provider]?.value {
                result.append(contentsOf: act.sessions)
            }
        }
        for provider in Provider.allCases {
            guard let usage = usages[provider]?.value else { continue }
            if let breakdown = usage.projectBreakdown, !breakdown.isEmpty {
                for split in breakdown {
                    result.append(
                        SessionSummary(
                            id: "aggregate-\(Privacy.opaqueID("\(provider.rawValue)/\(split.project)"))",
                            projectName: split.project,
                            model: "",
                            tokens: split.tokens,
                            estimatedCostUSD: 0,
                            startedAt: now,
                            messageCount: 0,
                            isAggregate: true
                        )
                    )
                }
                continue
            }
            guard let week = usage.weekTokens, week.total > 0 else { continue }
            result.append(
                SessionSummary(
                    id: "aggregate-\(provider.rawValue)",
                    projectName: provider.displayName,
                    model: "",
                    tokens: week,
                    estimatedCostUSD: 0,
                    startedAt: now,
                    messageCount: 0,
                    isAggregate: true
                )
            )
        }
        return result.sorted { $0.startedAt > $1.startedAt }
    }

    public static func calculate(
        sessions: [SessionSummary],
        window: QuotaWindow?,
        since: Date? = nil,
        fallbackToRecent: Bool = true,
        now: Date = Date()
    ) -> WindowBurnBreakdown? {
        guard !sessions.isEmpty else { return nil }

        // Filter sessions within the scope: an explicit `since` date (the
        // 7-day strip), else the quota window's timeframe.
        let relevantSessions: [SessionSummary]
        if let since {
            let filtered = sessions.filter { $0.startedAt >= since && $0.startedAt <= now }
            if filtered.isEmpty, !fallbackToRecent { return nil }
            relevantSessions = filtered.isEmpty ? Array(sessions.suffix(8)) : filtered
        } else if let window, let resetsAt = window.resetsAt, let durationMins = window.effectiveDurationMins, durationMins > 0 {
            let windowStart = resetsAt.addingTimeInterval(-Double(durationMins) * 60.0)
            let filtered = sessions.filter { $0.startedAt >= windowStart && $0.startedAt <= now }
            if filtered.isEmpty, !fallbackToRecent { return nil }
            relevantSessions = filtered.isEmpty ? Array(sessions.suffix(8)) : filtered
        } else {
            relevantSessions = Array(sessions.suffix(8))
        }

        guard !relevantSessions.isEmpty else { return nil }

        // A session without a token ledger carries no burn evidence — a
        // realtime/voice session whose rollout never records `token_count`
        // would otherwise force the card open with fabricated zeros
        // ("0 tokens", "0%", "Avg/turn: 0"). Provider-scheduled automations
        // are skipped too: they run in per-thread folders instead of a repo,
        // so attributing them would name thread directories rather than the
        // repos the user worked in. When the whole scope has no measured,
        // user-driven burn, hide the section — the same rule the popover
        // applies to an empty week.
        let attributedSessions = relevantSessions.filter { $0.tokens.total > 0 && !$0.isAutomation }
        guard !attributedSessions.isEmpty else { return nil }

        // Aggregate by project + model
        var grouped: [String: (project: String, model: String, turns: Int, tokens: TokenTotals, hasRealSession: Bool)] = [:]
        var totalWindowTokens = 0
        var totalTurns = 0
        var totalInput = 0
        var totalCacheRead = 0
        var totalCacheWrite = 0
        var longChats = 0

        for session in attributedSessions {
            let key = "\(session.projectName)|\(session.model)"
            let tokens = session.tokens
            let turns = max(1, session.messageCount)
            let isLong = turns >= 10 || tokens.total >= 100_000
            // Aggregates carry a whole provider's week: real burn, but never
            // "one long chat".
            if isLong, !session.isAggregate { longChats += 1 }

            totalWindowTokens += tokens.total
            totalTurns += turns
            totalInput += tokens.input
            totalCacheRead += tokens.cacheRead
            totalCacheWrite += tokens.cacheWrite

            if let existing = grouped[key] {
                grouped[key] = (
                    project: existing.project,
                    model: existing.model,
                    turns: existing.turns + turns,
                    tokens: existing.tokens + tokens,
                    hasRealSession: existing.hasRealSession || !session.isAggregate
                )
            } else {
                grouped[key] = (
                    project: session.projectName,
                    model: session.model,
                    turns: turns,
                    tokens: tokens,
                    hasRealSession: !session.isAggregate
                )
            }
        }

        let totalTokensSafe = max(1, totalWindowTokens)
        let contributors = grouped.values
            .map { item in
                let turns = item.turns
                let itemTotal = item.tokens.total
                let share = (Double(itemTotal) / Double(totalTokensSafe)) * 100.0
                let isLong = (turns >= 10 || itemTotal >= 100_000) && item.hasRealSession
                return BurnContributor(
                    projectName: item.project,
                    model: item.model,
                    turns: turns,
                    tokens: item.tokens,
                    totalTokens: itemTotal,
                    shareOfWindow: share,
                    isLongChat: isLong
                )
            }
            .sorted(by: { $0.totalTokens > $1.totalTokens })
            .prefix(3)

        let cacheDenominator = totalInput + totalCacheRead + totalCacheWrite
        let cacheHitRate: Double? = cacheDenominator > 0 ? (Double(totalCacheRead) / Double(cacheDenominator)) * 100.0 : nil
        let avgTokensPerTurn: Int? = totalTurns > 0 ? totalWindowTokens / totalTurns : nil

        return WindowBurnBreakdown(
            windowLabel: window?.label ?? "Active window",
            contributors: Array(contributors),
            totalTokens: totalWindowTokens,
            cacheHitRate: cacheHitRate,
            avgTokensPerTurn: avgTokensPerTurn,
            longChatCount: longChats
        )
    }
}
