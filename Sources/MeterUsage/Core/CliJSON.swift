import Foundation

// MARK: - Scriptable CLI mode
//
// `meterusage json` runs the binary headlessly: it polls the same
// quota sources the menu-bar app uses, prints a stable JSON report on stdout,
// and exits. The app does not launch, no status item appears, and nothing is
// cached between invocations — every run reads live state. `--force` is
// accepted and ignored for compatibility with other usage CLIs.
//
// Purpose: agents, scripts, and editor integrations can read quota without
// scraping UI or reimplementing any source. Output carries only display
// names, percentages, reset timestamps, and plan labels — the same
// privacy contract the popover renders under.

enum CliMode {

    /// True when argv asks for headless JSON output rather than the app.
    static func wantsJSON(_ arguments: [String]) -> Bool {
        arguments.dropFirst().contains { $0 == "json" || $0 == "--json" }
    }

    /// Accepted so scripts written against other usage CLIs' conventions
    /// work unchanged; this CLI never caches, so every invocation already
    /// bypasses any freshness gate. Kept so scripts
    /// written against that convention work unchanged.
    static func wantsForce(_ arguments: [String]) -> Bool {
        arguments.dropFirst().contains("--force")
    }

    /// Per-source timeout. A hung provider subprocess (e.g. a wedged `codex`
    /// RPC child) must degrade to "unavailable" in the report instead of
    /// hanging the calling script.
    static let sourceTimeout: TimeInterval = 30

    /// Polls every configured quota source concurrently and builds the report.
    /// Runs off the main actor entirely: AppKit is never touched on this path.
    static func run() async -> LimitsReport {
        let sources = Composition.quotaSources()
        var loaded: [Provider: Loaded<ProviderQuota>] = [:]
        await withTaskGroup(of: (Provider, Loaded<ProviderQuota>).self) { group in
            for source in sources {
                group.addTask {
                    await Self.fetchOne(source)
                }
            }
            for await (provider, result) in group {
                loaded[provider] = result
            }
        }
        let order = sources.map(\.provider)
        return LimitsReporter.build(
            quotas: loaded,
            order: order,
            now: Date()
        )
    }

    /// One source poll, collapsed to the same `Loaded` shape the coordinator
    /// stores, with a timeout guard so a wedged CLI subprocess cannot hang a
    /// calling script.
    static func fetchOne(_ source: QuotaSource) async -> (Provider, Loaded<ProviderQuota>) {
        do {
            let quota = try await withTimeout(sourceTimeout) {
                try await source.fetchQuota()
            }
            return (source.provider, .value(quota))
        } catch let reason as SourceUnavailable {
            return (source.provider, .missing(reason))
        } catch {
            // Deliberately opaque, matching the coordinator's rule: raw errors
            // can echo URLs, headers, or account hints.
            return (source.provider, .missing(.failed(source.provider)))
        }
    }
}

/// Race a throwing async call against a timeout. The timeout arm throws, so a
/// slow loser surfaces as an ordinary failure at the call site.
func withTimeout<T: Sendable>(_ seconds: TimeInterval,
                              _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * Double(NSEC_PER_SEC)))
            throw CancellationError()
        }
        guard let first = try await group.next() else { throw CancellationError() }
        group.cancelAll()
        return first
    }
}
