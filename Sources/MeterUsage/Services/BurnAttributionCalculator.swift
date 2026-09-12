import Foundation

public enum BurnAttributionCalculator {
    public static func calculate(
        sessions: [SessionSummary],
        window: QuotaWindow?,
        now: Date = Date()
    ) -> WindowBurnBreakdown? {
        guard !sessions.isEmpty else { return nil }

        // Filter sessions within window's timeframe
        let relevantSessions: [SessionSummary]
        if let window, let resetsAt = window.resetsAt, let durationMins = window.effectiveDurationMins, durationMins > 0 {
            let windowStart = resetsAt.addingTimeInterval(-Double(durationMins) * 60.0)
            let filtered = sessions.filter { $0.startedAt >= windowStart && $0.startedAt <= now }
            relevantSessions = filtered.isEmpty ? Array(sessions.suffix(8)) : filtered
        } else {
            relevantSessions = Array(sessions.suffix(8))
        }

        guard !relevantSessions.isEmpty else { return nil }

        // Aggregate by project + model
        var grouped: [String: (project: String, model: String, turns: Int, tokens: TokenTotals)] = [:]
        var totalWindowTokens = 0
        var totalTurns = 0
        var totalInput = 0
        var totalCacheRead = 0
        var totalCacheWrite = 0
        var longChats = 0

        for session in relevantSessions {
            let key = "\(session.projectName)|\(session.model)"
            let tokens = session.tokens
            let turns = max(1, session.messageCount)
            let isLong = turns >= 10 || tokens.total >= 100_000
            if isLong { longChats += 1 }

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
                    tokens: existing.tokens + tokens
                )
            } else {
                grouped[key] = (
                    project: session.projectName,
                    model: session.model,
                    turns: turns,
                    tokens: tokens
                )
            }
        }

        let totalTokensSafe = max(1, totalWindowTokens)
        let contributors = grouped.values
            .map { item in
                let turns = item.turns
                let itemTotal = item.tokens.total
                let share = (Double(itemTotal) / Double(totalTokensSafe)) * 100.0
                let isLong = turns >= 10 || itemTotal >= 100_000
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
