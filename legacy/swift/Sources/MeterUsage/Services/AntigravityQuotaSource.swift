import Foundation

/// Reads Antigravity's live quota windows through the agy CLI itself.
///
/// Antigravity caches no quota on disk: the CLI's `/usage` panel refreshes
/// windows from the backend each time it opens, and `agy -p "/usage"` prints
/// those windows non-interactively as tab-separated rows:
///
/// ```
/// Gemini Models\tWeekly Limit Remaining\t99%\t2026-09-10T03:14:38Z
/// ```
///
/// Each row carries a model group, a window label, the percent of the window
/// still remaining, and the reset time. This source runs that one command and
/// decodes only those numeric and timestamp fields. It never sends a prompt
/// or model request: `-p` with a slash command is handled locally. The CLI
/// runs in its own container when agy is containerised, mounting the same
/// volumes the user's own `agy` wrapper mounts, so no credentials are copied
/// out of the volume.
public struct AntigravityQuotaSource: QuotaSource {
    public let provider: Provider = .antigravity

    private let runtimeExecutable: String?

    public init(runtimeExecutable: String? = nil) {
        self.runtimeExecutable = runtimeExecutable
    }

    public func fetchQuota() async throws -> ProviderQuota {
        let data = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.runUsageCommand(runtime: runtimeExecutable))
            }
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SourceUnavailable.failed(.antigravity)
        }
        return try Self.parse(text, now: Date())
    }

    // MARK: CLI invocation

    /// Runs `agy -p "/usage"` and returns its stdout.
    ///
    /// Containerised agy keeps its state in the `antigravity-config` volume
    /// and its binary in the `antigravity-bin` volume, so the command is
    /// run inside a throwaway container with those exact mounts instead of
    /// reaching into the volume by hand. Returns an empty Data when the
    /// runtime, image, or volume is missing — an install without agy is a
    /// calm "unavailable", not an error.
    static func runUsageCommand(runtime: String?) -> Data {
        guard let executable = runtime ?? AntigravityRuntime.resolve(),
              Self.exists(executable, ["image", "inspect", Self.imageName]),
              Self.exists(executable, ["volume", "inspect", Self.volumeName]),
              Self.exists(executable, ["volume", "inspect", Self.binVolumeName]) else {
            return Data()
        }

        let data = AntigravityRuntime.run(executable: executable, arguments: [
            "run", "--rm", "--pull=never",
            "-v", "\(Self.volumeName):/root/.gemini",
            "-v", "\(Self.binVolumeName):/root/.local/bin",
            Self.imageName,
            "-p", "/usage"
        ])
        return data ?? Data()
    }

    static let imageName = "antigravity-cli:local"
    static let volumeName = "antigravity-config"
    static let binVolumeName = "antigravity-bin"

    private static func exists(_ executable: String, _ arguments: [String]) -> Bool {
        return AntigravityRuntime.run(executable: executable, arguments: arguments) != nil
    }

    // MARK: Parsing

    /// One decoded `/usage` row.
    struct UsageRow: Equatable {
        var group: String
        var window: String
        var remainingPercent: Double
        var resetsAt: Date?
    }

    /// Parses `/usage` output into grouped quota windows.
    ///
    /// The flat `windows` list carries one entry per row so the tray and
    /// side notch show every window; the popover gets the same windows grouped
    /// by model family, mirroring how Codex's model-specific windows are
    /// surfaced. Rows that do not parse are skipped rather than failing the
    /// whole report.
    static func parse(_ text: String, now: Date) throws -> ProviderQuota {
        let rows = text.split(separator: "\n").compactMap { line -> UsageRow? in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 4 else { return nil }
            guard let remaining = percent(parts[2]) else { return nil }
            return UsageRow(
                group: String(parts[0]).trimmingCharacters(in: .whitespaces),
                window: windowLabel(String(parts[1])),
                remainingPercent: remaining,
                resetsAt: timestamp(String(parts[3]))
            )
        }
        guard !rows.isEmpty else { throw SourceUnavailable.noData }

        let windows = rows.map { row in
            QuotaWindow(
                label: "\(shortGroup(row.group)) \(shortWindow(row.window))",
                usedPercent: 100 - row.remainingPercent,
                resetsAt: row.resetsAt,
                windowDurationMins: durationMins(for: row.window)
            )
        }

        var order: [String] = []
        var byGroup: [String: [QuotaWindow]] = [:]
        for row in rows {
            if byGroup[row.group] == nil { order.append(row.group) }
            let groupWindow = QuotaWindow(
                label: groupWindowLabel(row.window),
                usedPercent: 100 - row.remainingPercent,
                resetsAt: row.resetsAt,
                windowDurationMins: durationMins(for: row.window)
            )
            byGroup[row.group, default: []].append(groupWindow)
        }
        let groups = order.map { title in
            QuotaGroup(id: title.lowercased(), title: title, windows: byGroup[title] ?? [])
        }

        return ProviderQuota(
            provider: .antigravity,
            windows: windows,
            groups: groups,
            capturedAt: now
        )
    }

    private static func durationMins(for window: String) -> Int? {
        let lower = window.lowercased()
        if lower.contains("week") { return 10_080 }
        if lower.contains("five") || lower.contains("5") || lower.contains("hour") { return 300 }
        return nil
    }

    /// "Weekly Limit Remaining" → "Weekly"; unknown labels keep their words
    /// so a new window type reads truthfully instead of being dropped.
    private static func windowLabel(_ raw: String) -> String {
        raw.replacingOccurrences(of: " Limit Remaining", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func groupWindowLabel(_ window: String) -> String {
        let short = shortWindow(window)
        if short.lowercased().contains("limit") { return short }
        return "\(short) limit"
    }

    private static func shortGroup(_ raw: String) -> String {
        switch raw.lowercased() {
        case let g where g.contains("claude") || g.contains("gpt"): return "Claude/GPT"
        case let g where g.contains("gemini"): return "Gemini"
        default: return raw
        }
    }

    private static func shortWindow(_ raw: String) -> String {
        raw == "Five Hour" ? "5-hour" : raw
    }

    private static func percent(_ raw: Substring) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix("%") else { return nil }
        return Double(trimmed.dropLast())
    }

    /// `/usage` prints whole-second UTC timestamps; fractional-second
    /// timestamps are accepted in case a build starts emitting them.
    private static func timestamp(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) { return date }

        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        whole.timeZone = TimeZone(identifier: "UTC")
        return whole.date(from: trimmed)
    }
}
