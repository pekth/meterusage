import Foundation

// MARK: - OptionalQuotaFileSource
//
// The app works with zero configuration. This source is a pure bonus: IF
// the user happens to have a companion tool (ClaudeWatch, or a future
// MeterUsage helper) writing a small usage snapshot to disk, we read it and
// light up real quota bars. Nothing prompts for this, nothing requires it,
// and its absence is not an error — `SourceUnavailable.noData` is the
// expected, everyday result for anyone who doesn't have such a file.
//
// Looked up, in order (first one found wins):
//   ~/.claude/claudewatch-usage.json
//   ~/.claude/meterusage-usage.json
//
// VERIFIED against the real live file (`~/.claude/claudewatch-usage.json`,
// a symlink into `~/ClaudeSync/dot-claude/`) on 2026-07-31:
//   {
//     "five_hour":  { "used_percentage": 50, "resets_at": 1785483000 },
//     "seven_day":  { "used_percentage": 93, "resets_at": 1785585600 },
//     "extra_usage": {
//       "is_enabled": false,
//       "used_percentage": null,
//       "used_credits": null,
//       "monthly_limit": null
//     },
//     "gemini": { "used_percentage": null, "resets_at": null },
//     "updated_at": 1785481457
//   }
// Notable real-world details this parser must tolerate:
//   - `used_percentage`/`resets_at` arrive as bare JSON integers, not
//     floats. `JSONDecoder` widens a JSON integer literal into a `Double`
//     property without loss, so `Window.used_percentage: Double?` decodes
//     these fine — this is NOT the `JSONSerialization` + `as? Double`
//     pitfall (an NSNumber boxing an Int doesn't bridge that way, but we
//     never touch JSONSerialization here).
//   - `extra_usage.*` fields can be `null` while `is_enabled` is present
//     and `false`. Null must decode to `nil`, not to `0`/`false`-as-zero,
//     and a disabled/absent extra-usage block must produce a `nil`
//     `CreditBalance` — never a zeroed-out one that reads as "0 credits
//     used" (see the `is_enabled == true` guard below).
//   - Unrecognised top-level blocks (`gemini`, and presumably future
//     provider blocks) and `updated_at` are silently ignored: `Payload`
//     only declares the keys it cares about, and `Decodable`'s
//     memberwise-keyed init never fails on *extra* JSON keys — it only
//     fails on a *missing* non-optional key, and every property here is
//     Optional.
//
// `weekly` (an array that would supersede `seven_day` when present) is
// SPEC-DRIVEN, not observed: the real file captured above has no `weekly`
// key at all. The schema still allows it, so the precedence logic below is
// kept, but it hasn't been exercised against a real payload.
//   {
//     "weekly": [
//       { "label": "Sonnet weekly", "used_percentage": 12, "resets_at": 1780500000 }
//     ]
//   }
//
// `weekly`, when present (even as a single-element array), takes precedence
// over `seven_day` — it's the more specific, potentially multi-window
// breakdown (e.g. separate Sonnet/Opus weekly caps), so it supersedes the
// coarser single seven-day figure rather than being merged with it.
public struct OptionalQuotaFileSource: QuotaSource {

    public let provider: Provider = .claude

    private let candidatePaths: [URL]
    // `FileManager` isn't marked `Sendable` upstream even though `.default`
    // is documented as thread-safe; `nonisolated(unsafe)` accepts that
    // known-safe gap instead of pretending it doesn't exist.
    private nonisolated(unsafe) let fileManager: FileManager

    /// - Parameter candidatePaths: Override for tests. Defaults to the two
    ///   real well-known locations under the user's real home directory.
    public init(candidatePaths: [URL]? = nil, fileManager: FileManager = .default) {
        if let candidatePaths {
            self.candidatePaths = candidatePaths
        } else {
            let claudeDir = HomeDirectory.real.appendingPathComponent(".claude", isDirectory: true)
            self.candidatePaths = [
                claudeDir.appendingPathComponent("claudewatch-usage.json"),
                claudeDir.appendingPathComponent("meterusage-usage.json"),
            ]
        }
        self.fileManager = fileManager
    }

    public func fetchQuota() async throws -> ProviderQuota {
        guard let path = candidatePaths.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            throw SourceUnavailable.noData
        }
        guard let data = try? Data(contentsOf: path),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else {
            // A file exists but isn't readable/parseable JSON. Treat this
            // the same as "no data" rather than surfacing a raw parse
            // error — this file is a best-effort bonus input, not
            // something the user configured deliberately, so a malformed
            // or half-written snapshot should never read as a hard error.
            throw SourceUnavailable.noData
        }

        var windows: [QuotaWindow] = []
        if let fiveHour = payload.five_hour {
            windows.append(
                QuotaWindow(
                    label: "5-hour",
                    usedPercent: fiveHour.used_percentage ?? 0,
                    resetsAt: fiveHour.resets_at.map(Date.init(timeIntervalSince1970:))
                )
            )
        }

        if let weekly = payload.weekly, !weekly.isEmpty {
            // `weekly` supersedes `seven_day` — see header comment.
            for entry in weekly {
                windows.append(
                    QuotaWindow(
                        label: entry.label ?? "Weekly",
                        usedPercent: entry.used_percentage ?? 0,
                        resetsAt: entry.resets_at.map(Date.init(timeIntervalSince1970:))
                    )
                )
            }
        } else if let sevenDay = payload.seven_day {
            windows.append(
                QuotaWindow(
                    label: "7-day",
                    usedPercent: sevenDay.used_percentage ?? 0,
                    resetsAt: sevenDay.resets_at.map(Date.init(timeIntervalSince1970:))
                )
            )
        }

        // `extra_usage.is_enabled: false` (the observed real-world default)
        // arrives alongside `used_percentage`/`used_credits`/`monthly_limit`
        // all `null`. Only build a `CreditBalance` when the block is
        // actually enabled — otherwise `flatMap` returns `nil`, so the UI
        // sees "no credit balance to show" rather than a balance struct
        // that reads as "0 credits used" (a null/disabled extra-usage
        // block is not the same claim as a verified zero).
        let credits: CreditBalance? = payload.extra_usage.flatMap { extra -> CreditBalance? in
            guard extra.is_enabled == true else { return nil }
            // `used_credits` / `monthly_limit` are USD cents on the wire;
            // `CreditBalance.balance` is dollars, so divide by 100 here —
            // the one and only place this conversion happens.
            let limitCents = extra.monthly_limit ?? 0
            let usedCents = extra.used_credits ?? 0
            let unlimited = (extra.monthly_limit ?? 0) <= 0
            let remainingDollars = unlimited ? 0 : Double(limitCents - usedCents) / 100
            return CreditBalance(
                balance: remainingDollars,
                hasCredits: true,
                unlimited: unlimited
            )
        }

        return ProviderQuota(
            provider: .claude,
            windows: windows,
            credits: credits,
            planType: nil,
            capturedAt: Date()
        )
    }

    // MARK: - Wire types

    private struct Payload: Decodable {
        let five_hour: Window?
        let seven_day: Window?
        let weekly: [WeeklyWindow]?
        let extra_usage: ExtraUsage?
    }

    private struct Window: Decodable {
        let used_percentage: Double?
        let resets_at: Double?
    }

    private struct WeeklyWindow: Decodable {
        let label: String?
        let used_percentage: Double?
        let resets_at: Double?
    }

    private struct ExtraUsage: Decodable {
        let is_enabled: Bool?
        let used_percentage: Double?
        let used_credits: Int?
        let monthly_limit: Int?
    }
}
