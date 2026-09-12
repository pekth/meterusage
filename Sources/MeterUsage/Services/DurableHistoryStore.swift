import Foundation

public struct StoredTokenTotals: Codable, Equatable, Sendable {
    public var input: Int
    public var output: Int
    public var reasoning: Int
    public var cacheRead: Int
    public var cacheWrite: Int

    public init(from tokens: TokenTotals) {
        self.input = tokens.input
        self.output = tokens.output
        self.reasoning = tokens.reasoning
        self.cacheRead = tokens.cacheRead
        self.cacheWrite = tokens.cacheWrite
    }

    public var asTokenTotals: TokenTotals {
        TokenTotals(input: input, output: output, reasoning: reasoning, cacheRead: cacheRead, cacheWrite: cacheWrite)
    }
}

public struct StoredDailyRecord: Codable, Equatable, Sendable {
    public let dayISO: String // "2026-09-11"
    public let tokens: StoredTokenTotals
    public let estimatedCostUSD: Double
    public let sessionCount: Int
    public let peakUsedPercent: Double?

    public init(dayISO: String, tokens: StoredTokenTotals, estimatedCostUSD: Double, sessionCount: Int, peakUsedPercent: Double?) {
        self.dayISO = dayISO
        self.tokens = tokens
        self.estimatedCostUSD = estimatedCostUSD
        self.sessionCount = sessionCount
        self.peakUsedPercent = peakUsedPercent
    }
}

public final class DurableHistoryStore: @unchecked Sendable {
    public static let shared = DurableHistoryStore()

    private let storeURL: URL
    private let lock = NSLock()
    private var inMemory: [String: [StoredDailyRecord]] = [:]

    public init(storeURL: URL? = nil) {
        self.storeURL = storeURL ?? HomeDirectory.real
            .appendingPathComponent("Library/Application Support/MeterUsage", isDirectory: true)
            .appendingPathComponent("durable-daily-history.json")
        load()
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([String: [StoredDailyRecord]].self, from: data) else {
            return
        }
        self.inMemory = decoded
    }

    public func records(for provider: Provider) -> [DailyActivity] {
        lock.lock()
        defer { lock.unlock() }
        guard let list = inMemory[provider.rawValue] else { return [] }
        return list.compactMap { rec in
            guard let date = Self.dayFormatter.date(from: rec.dayISO) else { return nil }
            return DailyActivity(
                day: date,
                tokens: rec.tokens.asTokenTotals,
                estimatedCostUSD: rec.estimatedCostUSD,
                sessionCount: rec.sessionCount
            )
        }
    }

    public func record(provider: Provider, daily: [DailyActivity], peakUsedPercent: Double? = nil) {
        guard !daily.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        let current = inMemory[provider.rawValue] ?? []
        var byDay: [String: StoredDailyRecord] = [:]
        for r in current { byDay[r.dayISO] = r }

        for d in daily {
            let iso = Self.dayFormatter.string(from: d.day)
            let newRecord = StoredDailyRecord(
                dayISO: iso,
                tokens: StoredTokenTotals(from: d.tokens),
                estimatedCostUSD: d.estimatedCostUSD,
                sessionCount: d.sessionCount,
                peakUsedPercent: peakUsedPercent
            )
            if let existing = byDay[iso] {
                // Keep the record with larger tokens if older transcripts were purged
                if existing.tokens.asTokenTotals.total > d.tokens.total {
                    // keep existing
                } else {
                    byDay[iso] = newRecord
                }
            } else {
                byDay[iso] = newRecord
            }
        }

        let sorted = byDay.values.sorted(by: { $0.dayISO < $1.dayISO })
        inMemory[provider.rawValue] = sorted

        // Atomic write
        if let data = try? JSONEncoder().encode(inMemory) {
            try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: storeURL, options: .atomic)
        }
    }
}
