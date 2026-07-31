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
// `weekly` (an array that would supersede `seven_day` when present) is not
// currently written by the on-disk file above, but IS real: verified
// 2026-07-31 against the raw Claude usage API response cached at
// `/tmp/claude/statusline-usage-cache-*.json` (source of the `claudewatch`
// statusline writer). That response carries a `limits` array with entries
// like:
//   {
//     "kind": "weekly_all", "group": "weekly", "percent": 100,
//     "resets_at": "2026-08-01T12:00:00Z", "scope": null
//   },
//   {
//     "kind": "weekly_scoped", "group": "weekly", "percent": 99,
//     "resets_at": "2026-08-01T12:00:00Z",
//     "scope": { "model": { "id": null, "display_name": "Fable" } }
//   }
// This matches the machine owner's own screenshot of the Claude app's usage
// screen exactly (99% used, "Resets Sat 8:00 AM", labeled "Fable") and
// disproves two earlier, wrong conclusions reached from grepping strings in
// the Claude Code CLI binary: Fable is NOT billed only through
// `extra_usage`/usage-credits, and it DOES have its own weekly plan-quota
// window — "Fable 5 is still included with your Max plan" per the app's own
// copy. The CLI binary grep found nothing because that usage screen is
// rendered by the Claude desktop/web app reading this API response
// directly, not by anything shipped in the CLI bundle.
//
// The `claudewatch` statusline writer (`statusline.sh`) currently discards
// the entire `limits` array when it builds `claudewatch-usage.json` — it
// only extracts `.five_hour`, `.seven_day`, and `.extra_usage` from the
// cached response. The one-line-shaped fix on that side: map each
// `limits[] | select(.group == "weekly")` entry to a `weekly` array entry
// `{ label, used_percentage: .percent, resets_at }` (label = "All models"
// for `kind == "weekly_all"`, else `.scope.model.display_name`) and include
// it in the JSON written to `claudewatch-usage.json`. Until that writer
// change ships, this parser's `weekly` handling below is exercised by
// synthetic fixtures rather than the live file, which is why the precedence
// logic is kept even though today's live file has no `weekly` key:
//   {
//     "weekly": [
//       { "label": "All models", "used_percentage": 100, "resets_at": 1785585600 },
//       { "label": "Fable", "used_percentage": 99, "resets_at": 1785585600 }
//     ]
//   }
//
// `weekly`, when present (even as a single-element array), takes precedence
// over `seven_day` — it's the more specific, potentially multi-window
// breakdown (e.g. separate Sonnet/Opus/Fable weekly caps), so it supersedes
// the coarser single seven-day figure rather than being merged with it.
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

        // `limits[]`, when present, is the BEST source and takes full
        // precedence over every legacy key below (`five_hour`, `seven_day`,
        // `weekly`, and the per-model `seven_day_<model>` family) — it is
        // built directly from the real Anthropic usage API's `limits`
        // array (see header comment), which is the same data the Claude
        // app's own usage screen renders from. Rendering `limits[]`
        // *alongside* the legacy keys would show the same window twice
        // under two different labels (e.g. "7-day" and "Weekly · All
        // models" both meaning the seven-day-all-models window), so this
        // is a full replacement, not a merge, whenever `limits` is present
        // and non-empty. `extra_usage`/credits handling below is
        // unaffected either way — it's an orthogonal concern.
        if let limits = payload.limits?.compactMap(\.entry), !limits.isEmpty {
            for entry in limits {
                guard let window = Self.quotaWindow(fromLimitEntry: entry) else { continue }
                windows.append(window)
            }
        } else {
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

            // Per-model weekly windows: `seven_day_opus`, `seven_day_sonnet`,
            // and — generically, see below — any future `seven_day_<model>`
            // key. Additive to the coarse `seven_day` window above, never a
            // replacement for it: the overall 7-day figure and a per-model
            // breakdown answer different questions, and both can be true at
            // once (unlike `weekly` vs `seven_day`, which describe the same
            // thing at two granularities).
            //
            // Both `seven_day_opus` and `seven_day_sonnet` are OPTIONAL and, on
            // this machine's real file (captured 2026-07-31), ABSENT — the
            // live payload only has the bare `seven_day` block. Absence must
            // produce zero extra windows and zero errors, never a fabricated
            // window.
            //
            // `seven_day_fable` (this exact key spelling) has never been
            // observed — the API's actual per-model weekly breakdown arrives
            // via the `limits` array (handled above, taking full precedence
            // when present), not via a `seven_day_<model>` sibling key.
            // Fable DOES have its own weekly plan-quota window — confirmed
            // 2026-07-31 against the machine owner's own Claude app usage
            // screenshot and the raw cached API response — it is just carried
            // under a different shape than Opus/Sonnet's `seven_day_*` keys.
            // The generic `seven_day_<model>` scan below stays as
            // forward-compatible handling for that key family in case the API
            // ever adds `seven_day_fable` directly; it is not itself how Fable
            // shows up today.
            for (model, window) in payload.perModelSevenDay.sorted(by: { $0.key < $1.key }) {
                windows.append(
                    QuotaWindow(
                        label: "7-day (\(Self.capitalized(model)))",
                        usedPercent: window.used_percentage ?? 0,
                        resetsAt: window.resets_at.map(Date.init(timeIntervalSince1970:))
                    )
                )
            }
        }

        // `extra_usage.is_enabled: false` (the observed real-world default)
        // arrives alongside `used_percentage`/`used_credits`/`monthly_limit`
        // all `null`. Only build a `CreditBalance` when the block is
        // actually enabled — otherwise `flatMap` returns `nil`, so the UI
        // sees "no credit balance to show" rather than a balance struct
        // that reads as "0 credits used" (a null/disabled extra-usage
        // block is not the same claim as a verified zero).
        // Both `used_credits` and `monthly_limit` must actually be present
        // (not just `is_enabled == true`) before a credits row is built —
        // the observed real-world shape is `is_enabled: false` with every
        // numeric field `null`, and a *future* enabled-but-still-null
        // payload deserves the same "nothing to show" treatment rather
        // than a fabricated $0/$0 row.
        let credits: CreditBalance? = payload.extra_usage.flatMap { extra -> CreditBalance? in
            guard extra.is_enabled == true,
                  let usedCents = extra.used_credits,
                  let limitCents = extra.monthly_limit
            else { return nil }
            // Cents on the wire, dollars in `CreditBalance` — the one and
            // only place this conversion happens.
            let unlimited = limitCents <= 0
            let usedDollars = Double(usedCents) / 100
            let limitDollars = Double(limitCents) / 100
            let remainingDollars = unlimited ? 0 : (limitDollars - usedDollars)
            return CreditBalance(
                balance: remainingDollars,
                hasCredits: true,
                unlimited: unlimited,
                usedDollars: usedDollars,
                limitDollars: unlimited ? nil : limitDollars
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

    /// "opus" -> "Opus". Model names in `seven_day_<model>` keys are single
    /// lowercase words on every observed and speculative shape; this is
    /// display formatting only, not a lookup against a known-models list —
    /// an unrecognised model name still gets a truthful, readable label
    /// instead of being silently dropped.
    private static func capitalized(_ model: String) -> String {
        guard let first = model.first else { return model }
        return first.uppercased() + model.dropFirst()
    }

    /// Maps one `limits[]` entry to a displayable `QuotaWindow`, per the
    /// label rules verified against the machine owner's own Claude app
    /// usage screen (2026-07-31):
    ///   - `kind == "session"`       -> "5-hour" (the session/5h window)
    ///   - `kind == "weekly_all"`    -> "Weekly · All models"
    ///   - `kind == "weekly_scoped"` -> "Weekly · <scope.model.display_name>"
    ///   - any other/unknown `kind` (including a missing one) -> derive a
    ///     label from `scope.model.display_name` when present; otherwise
    ///     return `nil` so the caller skips the entry entirely rather than
    ///     inventing a label for data we don't understand.
    private static func quotaWindow(fromLimitEntry entry: LimitEntry) -> QuotaWindow? {
        let label: String
        switch entry.kind ?? "" {
        case "session":
            label = "5-hour"
        case "weekly_all":
            label = "Weekly · All models"
        case "weekly_scoped":
            if let name = entry.scopeModelDisplayName {
                label = "Weekly · \(name)"
            } else {
                // Known kind, just missing the scope name we'd normally
                // hang off it — still a real weekly window, so render it
                // generically rather than dropping it.
                label = "Weekly"
            }
        default:
            guard let name = entry.scopeModelDisplayName else { return nil }
            if let group = entry.group {
                label = "\(Self.capitalized(group)) · \(name)"
            } else {
                label = name
            }
        }
        return QuotaWindow(label: label, usedPercent: entry.percent ?? 0, resetsAt: entry.resetsAt)
    }

    // MARK: - Wire types

    private struct Payload: Decodable {
        let five_hour: Window?
        let seven_day: Window?
        let weekly: [WeeklyWindow]?
        let limits: [SkippableLimitEntry]?
        let extra_usage: ExtraUsage?
        /// Every `seven_day_<model>` key found in the payload, keyed by the
        /// model name (e.g. "opus", "sonnet"). Built generically in
        /// `init(from:)` below by scanning for the naming pattern rather
        /// than declaring `seven_day_opus`/`seven_day_sonnet` as named
        /// properties — see the TASK 1 comment at the top of this file for
        /// why this stays generic instead of hardcoding a `seven_day_fable`
        /// branch that has never been observed. A key that matches the
        /// pattern but doesn't decode as `{used_percentage, resets_at}`
        /// (e.g. a hypothetical `seven_day_overage_included: Bool`) is
        /// skipped, not treated as a parse failure.
        let perModelSevenDay: [String: Window]

        private enum CodingKeys: String, CodingKey {
            case five_hour, seven_day, weekly, limits, extra_usage
        }

        /// Opens the same JSON object a second time under keys typed as
        /// plain strings, so any key can be inspected without declaring it
        /// up front.
        private struct DynamicKey: CodingKey {
            let stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { nil }
            init?(intValue: Int) { nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            five_hour = try container.decodeIfPresent(Window.self, forKey: .five_hour)
            seven_day = try container.decodeIfPresent(Window.self, forKey: .seven_day)
            weekly = try container.decodeIfPresent([WeeklyWindow].self, forKey: .weekly)
            limits = try container.decodeIfPresent([SkippableLimitEntry].self, forKey: .limits)
            extra_usage = try container.decodeIfPresent(ExtraUsage.self, forKey: .extra_usage)

            let dynamic = try decoder.container(keyedBy: DynamicKey.self)
            var extras: [String: Window] = [:]
            for key in dynamic.allKeys {
                let name = key.stringValue
                guard name.hasPrefix("seven_day_") else { continue }
                let model = String(name.dropFirst("seven_day_".count))
                guard !model.isEmpty else { continue }
                // `try?` flattens the nested optional from a throwing
                // `decodeIfPresent`, so this is `nil` on a missing key, a
                // JSON `null`, AND a shape mismatch alike — every one of
                // those cases means "no window for this model", never a
                // parse error.
                guard let window = try? dynamic.decodeIfPresent(Window.self, forKey: key) else { continue }
                extras[model] = window
            }
            perModelSevenDay = extras
        }
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

    /// One entry of the real Anthropic usage API's `limits` array (see the
    /// header comment for the verified shape). `percent` decodes as
    /// `Double` even for a bare JSON integer literal — the same
    /// `JSONDecoder` widening behaviour documented on `Window` above.
    /// `resets_at` is handled manually in `init(from:)` because it arrives
    /// as EITHER an ISO-8601 string (the `limits[]` shape) or an integer
    /// epoch (the older `five_hour`/`seven_day` shape) — never assume
    /// which, decode defensively for both.
    private struct LimitEntry: Decodable {
        let kind: String?
        let group: String?
        let percent: Double?
        let scopeModelDisplayName: String?
        let resetsAt: Date?

        private enum CodingKeys: String, CodingKey {
            case kind, group, percent, scope, resets_at
        }

        private struct Scope: Decodable {
            let model: Model?
            struct Model: Decodable {
                let id: String?
                let display_name: String?
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decodeIfPresent(String.self, forKey: .kind)
            group = try container.decodeIfPresent(String.self, forKey: .group)
            percent = try container.decodeIfPresent(Double.self, forKey: .percent)
            let scope = try container.decodeIfPresent(Scope.self, forKey: .scope)
            scopeModelDisplayName = scope?.model?.display_name

            // `resets_at`: try the epoch-number shape first, then the
            // ISO-8601-string shape. Either being absent/mismatched is
            // fine — `try?` collapses "missing key", "JSON null", and
            // "wrong type" all down to `nil`, and a `resets_at` this
            // parser can't make sense of just means "no reset time to
            // show", never a parse failure for the whole entry.
            if let epoch = try? container.decode(Double.self, forKey: .resets_at) {
                resetsAt = Date(timeIntervalSince1970: epoch)
            } else if let iso = try? container.decode(String.self, forKey: .resets_at) {
                resetsAt = Self.parseISO8601(iso)
            } else {
                resetsAt = nil
            }
        }

        /// Handles both the fractional-seconds form observed in the real
        /// cached API response (`"2026-08-01T12:00:00.384229+00:00"`) and
        /// the plain-seconds form, in case a future/other producer omits
        /// the fraction.
        private static func parseISO8601(_ string: String) -> Date? {
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFraction.date(from: string) {
                return date
            }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: string)
        }
    }

    /// Wraps `LimitEntry`'s throwing decode in a `try?` so one malformed
    /// element (wrong shape, not even a JSON object, an unparseable
    /// `resets_at`, etc.) never fails the whole `limits` array — it just
    /// produces a `nil` `entry`, which the caller filters out. Mirrors the
    /// same "malformed input degrades gracefully" posture as the rest of
    /// this file (see `Payload`'s `perModelSevenDay` scan above).
    private struct SkippableLimitEntry: Decodable {
        let entry: LimitEntry?

        init(from decoder: Decoder) throws {
            entry = try? LimitEntry(from: decoder)
        }
    }

    private struct ExtraUsage: Decodable {
        let is_enabled: Bool?
        let used_percentage: Double?
        let used_credits: Int?
        let monthly_limit: Int?
    }
}
