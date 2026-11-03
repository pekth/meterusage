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

public enum DurableHistoryStoreError: String, Equatable, Sendable {
    case loadFailed
    case writeFailed
}

public final class DurableHistoryStore: @unchecked Sendable {
    public static let shared = DurableHistoryStore()

    private let storeURL: URL
    private let lock = NSLock()
    private var inMemory: [String: [StoredDailyRecord]] = [:]
    private var storeError: DurableHistoryStoreError?

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
        do {
            let data = try Data(contentsOf: storeURL)
            self.inMemory = try JSONDecoder().decode([String: [StoredDailyRecord]].self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // A first launch has no history file yet.
        } catch {
            storeError = .loadFailed
        }
    }

    public var error: DurableHistoryStoreError? {
        lock.lock()
        defer { lock.unlock() }
        return storeError
    }

    /// Reads one slot's daily history. The key is `ProviderSlot.key` — the
    /// provider raw value for a primary slot (matching files written before
    /// slots existed), `"<rawValue>#<slotID>"` for additional accounts.
    public func records(forKey key: String) -> [DailyActivity] {
        lock.lock()
        defer { lock.unlock() }
        guard let list = inMemory[key] else { return [] }
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

    public func record(key: String, daily: [DailyActivity], peakUsedPercent: Double? = nil) {
        guard !daily.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        let current = inMemory[key] ?? []
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
        inMemory[key] = sorted

        guard storeError != .loadFailed else { return }

        do {
            let data = try JSONEncoder().encode(inMemory)
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: storeURL, options: .atomic)
            storeError = nil
        } catch {
            storeError = .writeFailed
        }
    }

    /// Primary-slot convenience over the key-based API: keys by the
    /// provider's raw value, exactly as files were written before slots
    /// existed.
    public func record(provider: Provider, daily: [DailyActivity], peakUsedPercent: Double? = nil) {
        record(key: provider.rawValue, daily: daily, peakUsedPercent: peakUsedPercent)
    }

    public func records(for provider: Provider) -> [DailyActivity] {
        records(forKey: provider.rawValue)
    }
}
