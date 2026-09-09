import Foundation

/// Item summarizing a session for telemetry aggregation.
public struct TelemetrySessionItem: Sendable {
    public let startedAt: Date
    public let endedAt: Date?
    public let tokens: Int
    public let messageCount: Int

    public init(
        startedAt: Date,
        endedAt: Date? = nil,
        tokens: Int = 0,
        messageCount: Int = 0
    ) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.tokens = max(tokens, 0)
        self.messageCount = max(messageCount, 0)
    }
}

/// Pure engine for computing telemetry metrics: streaks, peak tokens,
/// rolling windows, and 30-day histograms.
public enum TelemetryCalculator {

    public static func calculate(
        sessions: [TelemetrySessionItem] = [],
        daily: [DailyActivity] = [],
        calendar: Calendar = Calendar.current,
        now: Date = Date()
    ) -> ProviderTelemetry {
        let startOfToday = calendar.startOfDay(for: now)

        // Aggregate daily map: day -> (tokens, sessions)
        var dayStats: [Date: (tokens: Int, sessions: Int)] = [:]

        if !daily.isEmpty {
            for d in daily {
                let dayKey = calendar.startOfDay(for: d.day)
                let existing = dayStats[dayKey] ?? (0, 0)
                dayStats[dayKey] = (existing.tokens + d.tokens.total, existing.sessions + d.sessionCount)
            }
        } else {
            for s in sessions {
                let dayKey = calendar.startOfDay(for: s.startedAt)
                let existing = dayStats[dayKey] ?? (0, 0)
                dayStats[dayKey] = (existing.tokens + s.tokens, existing.sessions + 1)
            }
        }

        var totalTokensSum = 0
        var hasExplicitTokens = false
        var maxChatDuration: TimeInterval?

        for s in sessions {
            totalTokensSum += s.tokens
            if s.tokens > 0 {
                hasExplicitTokens = true
            }
            if let ended = s.endedAt {
                let duration = max(0, ended.timeIntervalSince(s.startedAt))
                if let currentMax = maxChatDuration {
                    if duration > currentMax { maxChatDuration = duration }
                } else {
                    maxChatDuration = duration
                }
            }
        }

        // Check if daily activity had tokens
        if !hasExplicitTokens {
            for (_, stat) in dayStats where stat.tokens > 0 {
                hasExplicitTokens = true
                totalTokensSum += stat.tokens
            }
        }

        let lifetimeTokens: Int? = (hasExplicitTokens || totalTokensSum > 0) ? totalTokensSum : nil

        // Peak daily tokens
        var peakTokens: Int?
        if hasExplicitTokens {
            let maxTokens = dayStats.values.map(\.tokens).max() ?? 0
            if maxTokens > 0 {
                peakTokens = maxTokens
            }
        }

        // Active days (where either sessions > 0 or tokens > 0)
        let activeDays = dayStats.compactMap { (day, stat) -> Date? in
            (stat.sessions > 0 || stat.tokens > 0) ? day : nil
        }.sorted()

        let (currentStreak, longestStreak) = computeStreaks(
            activeDays: activeDays,
            startOfToday: startOfToday,
            calendar: calendar
        )

        // 30-day daily history points and totals
        var historyPoints: [DailyVolumePoint] = []
        historyPoints.reserveCapacity(30)
        var todayTokens: Int?
        var last30Sum = 0

        for offset in 0..<30 {
            guard let dayDate = calendar.date(byAdding: .day, value: -(29 - offset), to: startOfToday) else {
                continue
            }
            let stat = dayStats[dayDate] ?? (0, 0)
            historyPoints.append(DailyVolumePoint(day: dayDate, tokens: stat.tokens, sessionCount: stat.sessions))
            last30Sum += stat.tokens
            if dayDate == startOfToday && hasExplicitTokens {
                todayTokens = stat.tokens
            }
        }

        let last30DaysTokens: Int? = hasExplicitTokens ? last30Sum : nil

        let totalSessions: Int? = !sessions.isEmpty ? sessions.count : nil
        let totalMessages: Int? = !sessions.isEmpty ? sessions.reduce(0) { $0 + $1.messageCount } : nil
        let todaySessions: Int? = !sessions.isEmpty ? dayStats[startOfToday]?.sessions : nil
        let todayMessages: Int? = !sessions.isEmpty ? sessions.filter { calendar.isDate($0.startedAt, inSameDayAs: startOfToday) }.reduce(0) { $0 + $1.messageCount } : nil

        return ProviderTelemetry(
            lifetimeTokens: lifetimeTokens,
            peakDailyTokens: peakTokens,
            longestChatSeconds: maxChatDuration,
            currentStreakDays: currentStreak,
            longestStreakDays: longestStreak,
            todayTokens: todayTokens,
            last30DaysTokens: last30DaysTokens,
            totalSessions: totalSessions,
            totalMessages: totalMessages,
            todaySessions: todaySessions,
            todayMessages: todayMessages,
            dailyHistory: historyPoints
        )
    }

    /// Computes (currentStreak, longestStreak) from sorted unique active calendar days.
    public static func computeStreaks(
        activeDays: [Date],
        startOfToday: Date,
        calendar: Calendar = Calendar.current
    ) -> (current: Int, longest: Int) {
        guard !activeDays.isEmpty else { return (0, 0) }

        let daySet = Set(activeDays)

        // Longest streak
        var longest = 0
        var currentRun = 0
        var prevDay: Date?

        for day in activeDays {
            if let prev = prevDay {
                if let nextExpected = calendar.date(byAdding: .day, value: 1, to: prev),
                   calendar.isDate(day, inSameDayAs: nextExpected) {
                    currentRun += 1
                } else if !calendar.isDate(day, inSameDayAs: prev) {
                    currentRun = 1
                }
            } else {
                currentRun = 1
            }
            if currentRun > longest {
                longest = currentRun
            }
            prevDay = day
        }

        // Current streak (counting backwards from today or yesterday)
        var current = 0
        var checkDay = startOfToday

        if daySet.contains(checkDay) {
            current += 1
            while let prev = calendar.date(byAdding: .day, value: -1, to: checkDay), daySet.contains(prev) {
                current += 1
                checkDay = prev
            }
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: checkDay), daySet.contains(yesterday) {
            current += 1
            checkDay = yesterday
            while let prev = calendar.date(byAdding: .day, value: -1, to: checkDay), daySet.contains(prev) {
                current += 1
                checkDay = prev
            }
        }

        return (current, max(longest, current))
    }
}
