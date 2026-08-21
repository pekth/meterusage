import Foundation
import Combine
import AppKit

/// Outcome of one source poll: either data, or a reason there is none.
///
/// Modelled explicitly rather than as `T?` because *why* a value is missing is
/// the entire content of the empty state — "Codex CLI not found" and "couldn't
/// read Codex usage" must not render the same way.
enum Loaded<T> {
    case idle
    case value(T)
    case missing(SourceUnavailable)

    var value: T? {
        if case .value(let v) = self { return v }
        return nil
    }

    var unavailable: SourceUnavailable? {
        if case .missing(let reason) = self { return reason }
        return nil
    }
}

/// Owns refresh scheduling and publishes everything the UI renders.
///
/// Sources arrive by injection. The coordinator knows only the protocols, so the
/// app can be assembled with real sources, fixtures, or none at all, and adding
/// a provider never touches this file.
@MainActor
final class AppCoordinator: ObservableObject {

    // MARK: Published state

    @Published private(set) var quotas: [Provider: Loaded<ProviderQuota>] = [:]
    @Published private(set) var activities: [Provider: Loaded<LocalActivity>] = [:]
    @Published private(set) var usages: [Provider: Loaded<ProviderUsage>] = [:]
    @Published private(set) var statuses: [Provider: Loaded<ServiceStatus>] = [:]
    /// Subscription tier per provider. Kept in its own map rather than folded
    /// into `quotas` because a plan is read from a different place than the
    /// quota (account metadata vs. rate-limit endpoint) and either can be
    /// present without the other.
    @Published private(set) var plans: [Provider: Loaded<PlanTier>] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var isClearingCache = false
    @Published private(set) var lastRefreshedAt: Date?

    /// Ticks once a minute purely so relative labels ("resets in 2h 14m") stay
    /// truthful between refreshes without re-polling any source.
    @Published private(set) var clock = Date()

    let preferences: Preferences

    /// `true` when every number on screen is synthetic (see `DemoMode`).
    ///
    /// Carried here rather than read from the environment by the view, so the
    /// views stay ignorant of how the app was launched and the flag is decided
    /// exactly once, in the composition root. Defaults to `false`, so any
    /// caller that doesn't opt in gets the real thing.
    let isDemoMode: Bool

    // MARK: Sources

    private let quotaSources: [QuotaSource]
    /// Optional because only Codex exposes an account-mutating reset action.
    private let resetConsumer: QuotaResetConsumer?
    /// Not `let`: clearing the cache replaces these instances (see
    /// `performCacheClear`), which is how a re-scan is made genuinely cold.
    private var activitySources: [LocalActivitySource]
    /// Rebuilds the activity sources from scratch. Supplied by the composition
    /// root so this file still names no concrete source.
    private let activitySourceFactory: (() -> [LocalActivitySource])?
    private let usageSources: [UsageSource]
    private let statusSources: [StatusSource]
    /// Optional: a build with no plan source simply never renders a plan badge,
    /// which is the same as a source that reports `.noData`.
    private let planSources: [PlanSource]
    /// Optional quota-alert delivery. `nil` in tests and any build that does
    /// not want notifications; the coordinator never depends on it.
    var quotaAlertService: QuotaAlertService?

    // MARK: Scheduling

    private var refreshTask: Task<Void, Never>?
    private var scheduleTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()

    /// Per-source failure backoff, keyed by `"<kind>-<provider>"`. A source
    /// that keeps failing (provider outage, no network) is skipped by scheduled
    /// sweeps until its backoff elapses instead of being hammered every cycle.
    private var backoffs: [String: Backoff] = [:]

    /// One source's retry state. `nextAttemptAt` is when a scheduled sweep may
    /// try it again; user-initiated refreshes always bypass it.
    private struct Backoff {
        var failures: Int
        var nextAttemptAt: Date
    }

    /// Delay before the next attempt after `failures` consecutive transient
    /// failures: 1m, 2m, 4m … capped at 30m. Pure so it is testable without
    /// touching the coordinator.
    nonisolated static func backoffDelay(afterFailures failures: Int) -> TimeInterval {
        // Cap the exponent before computing, so a long outage (hundreds of
        // consecutive failures) can never overflow the shift/pow.
        let capped = min(max(failures, 1), 6)
        let exp = Int(pow(2.0, Double(capped - 1)))
        return Double(min(exp, 30)) * 60
    }

    private static func backoffKey(kind: String, provider: Provider) -> String {
        "\(kind)-\(provider.rawValue)"
    }

    init(
        preferences: Preferences,
        isDemoMode: Bool = false,
        quotaSources: [QuotaSource] = [],
        resetConsumer: QuotaResetConsumer? = nil,
        activitySources: [LocalActivitySource] = [],
        usageSources: [UsageSource] = [],
        statusSources: [StatusSource] = [],
        planSources: [PlanSource] = [],
        activitySourceFactory: (() -> [LocalActivitySource])? = nil
    ) {
        self.preferences = preferences
        self.isDemoMode = isDemoMode
        self.quotaSources = quotaSources
        self.resetConsumer = resetConsumer
        self.activitySources = activitySources
        self.activitySourceFactory = activitySourceFactory
        self.usageSources = usageSources
        self.statusSources = statusSources
        self.planSources = planSources
    }

    // No `deinit`: one coordinator is created by the app delegate and lives for
    // the process lifetime, so there is nothing to tear down, and a nonisolated
    // `deinit` cannot touch main-actor state cleanly.

    // MARK: Lifecycle

    func start() {
        observeWake()
        observePreferences()
        startClock()
        restartSchedule()
        refresh()
    }

    /// A machine that slept for eight hours wakes holding numbers from before
    /// the nap, and the scheduled timer may not have fired during sleep. Refresh
    /// on wake so the first glance at the menu bar is never a lie.
    private func observeWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func observePreferences() {
        preferences.$refreshInterval
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.restartSchedule() }
            .store(in: &cancellables)
        // The provider visibility and menu-bar selection are read by the
        // popover and the status item. Preferences republishes those, but the
        // coordinator's views observe *this* object, so a change must be
        // forwarded here or the tray keeps drawing the old provider set until
        // the next scheduled refresh.
        preferences.$enabledProviders
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        preferences.$menuBarProviders
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    private func startClock() {
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * NSEC_PER_SEC)
                guard !Task.isCancelled else { return }
                self?.clock = Date()
            }
        }
    }

    private func restartSchedule() {
        scheduleTask?.cancel()
        let interval = max(preferences.refreshInterval, Preferences.minimumRefreshInterval)
        scheduleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * Double(NSEC_PER_SEC)))
                guard !Task.isCancelled else { return }
                // Scheduled sweeps respect per-source backoff; anything the
                // user triggers directly does not.
                self?.refresh(scheduled: true)
            }
        }
    }

    /// Forwards the Settings toggle's authorization request to the alert
    /// service. A no-op when no service is installed (tests, stripped builds).
    func requestQuotaAlertAuthorization() {
        quotaAlertService?.requestAuthorization()
    }

    // MARK: Refresh

    /// Kicks off a refresh, coalescing with one already in flight.
    ///
    /// Wake, timer and popover-open can all fire within the same second; running
    /// three concurrent sweeps would spawn duplicate CLI subprocesses for no
    /// benefit.
    ///
    /// User-initiated refreshes (button, menu, wake, popover open) pass the
    /// default `scheduled: false` and bypass per-source backoff — an explicit
    /// request should always try. Only the timer passes `true`, so a source in
    /// backoff is skipped until its delay elapses rather than retried every
    /// cycle.
    func refresh(scheduled: Bool = false) {
        guard refreshTask == nil else { return }
        isRefreshing = true
        refreshTask = Task { [weak self] in
            await self?.performRefresh(forceAll: !scheduled)
            self?.isRefreshing = false
            self?.lastRefreshedAt = Date()
            self?.refreshTask = nil
        }
    }

    /// Refreshes only if the data is older than `maxAge`. Called when the
    /// popover opens, so opening it repeatedly doesn't hammer the sources.
    func refreshIfStale(maxAge: TimeInterval = 20) {
        guard let last = lastRefreshedAt else { return refresh() }
        if Date().timeIntervalSince(last) > maxAge { refresh() }
    }

    /// Performs the explicitly confirmed Codex reset and refreshes all data so
    /// the menu immediately reflects the provider's new limits and remaining
    /// reset credits. A non-reset outcome is treated as unavailable rather than
    /// presented as a successful mutation.
    func consumeCodexReset(creditID: String) async throws {
        guard let resetConsumer else { throw SourceUnavailable.failed(.codex) }
        guard try await resetConsumer.consumeReset(creditID: creditID) else {
            throw SourceUnavailable.failed(.codex)
        }
        refresh()
    }

    private func performRefresh(forceAll: Bool) async {
        // Sources are independent and mostly I/O-bound, so they run together and
        // the sweep costs as long as the slowest one, not their sum.
        let now = Date()
        await withTaskGroup(of: Void.self) { group in
            for source in quotaSources where preferences.isEnabled(source.provider) {
                if forceAll || !isBackedOff(kind: "quota", provider: source.provider, now: now) {
                    group.addTask { [weak self] in await self?.load(quota: source) }
                }
            }
            for source in activitySources where preferences.isEnabled(source.provider) {
                if forceAll || !isBackedOff(kind: "activity", provider: source.provider, now: now) {
                    group.addTask { [weak self] in await self?.load(activity: source) }
                }
            }
            for source in usageSources where preferences.isEnabled(source.provider) {
                if forceAll || !isBackedOff(kind: "usage", provider: source.provider, now: now) {
                    group.addTask { [weak self] in await self?.load(usage: source) }
                }
            }
            // Server health is independent of the provider visibility toggles:
            // hiding Claude usage should not hide the top-level health signal.
            for source in statusSources {
                if forceAll || !isBackedOff(kind: "status", provider: source.provider, now: now) {
                    group.addTask { [weak self] in await self?.load(status: source) }
                }
            }
            for source in planSources where preferences.isEnabled(source.provider) {
                if forceAll || !isBackedOff(kind: "plan", provider: source.provider, now: now) {
                    group.addTask { [weak self] in await self?.load(plan: source) }
                }
            }
        }
        clock = Date()
        // Threshold alerts evaluate the full map after every sweep, whether or
        // not individual sources were skipped for backoff — a skipped source
        // simply keeps its previous reading.
        quotaAlertService?.process(quotas: quotas)
    }

    private func isBackedOff(kind: String, provider: Provider, now: Date) -> Bool {
        guard let backoff = backoffs[Self.backoffKey(kind: kind, provider: provider)] else { return false }
        return now < backoff.nextAttemptAt
    }

    /// Records one sweep outcome for a source. A value clears any backoff; a
    /// *transient* failure (`.failed`, `.offline`) extends it exponentially.
    /// Permanent conditions — CLI not installed, nothing signed in, no data
    /// yet — are facts about the machine, not outages, so they never back off:
    /// the user should see them resolve on the very next sweep after they fix
    /// the cause.
    private func record(kind: String, provider: Provider, result: SourceUnavailable?) {
        let key = Self.backoffKey(kind: kind, provider: provider)
        guard let reason = result, Self.isTransient(reason) else {
            backoffs[key] = nil
            return
        }
        let failures = (backoffs[key]?.failures ?? 0) + 1
        backoffs[key] = Backoff(
            failures: failures,
            nextAttemptAt: Date().addingTimeInterval(Self.backoffDelay(afterFailures: failures))
        )
    }

    private static func isTransient(_ reason: SourceUnavailable) -> Bool {
        switch reason {
        case .failed, .offline: return true
        case .cliNotFound, .notSignedIn, .noData, .dataNotFound: return false
        }
    }

    private func load(quota source: QuotaSource) async {
        let result: Loaded<ProviderQuota>
        do {
            result = .value(try await source.fetchQuota())
        } catch {
            result = .missing(Self.reason(for: error, provider: source.provider))
        }
        quotas[source.provider] = result
        record(kind: "quota", provider: source.provider, result: result.unavailable)
    }

    private func load(activity source: LocalActivitySource) async {
        let result: Loaded<LocalActivity>
        do {
            let activity = try await source.scan()
            // A successful scan of an empty machine is `noData`, not a value —
            // otherwise the view shows a confident "0 tokens" for someone whose
            // transcripts simply live elsewhere.
            result = activity.sessions.isEmpty && activity.daily.isEmpty
                ? .missing(.noData)
                : .value(activity)
        } catch {
            result = .missing(Self.reason(for: error, provider: source.provider))
        }
        activities[source.provider] = result
        record(kind: "activity", provider: source.provider, result: result.unavailable)
    }

    private func load(usage source: UsageSource) async {
        let result: Loaded<ProviderUsage>
        do {
            result = .value(try await source.fetchUsage())
        } catch {
            result = .missing(Self.reason(for: error, provider: source.provider))
        }
        usages[source.provider] = result
        record(kind: "usage", provider: source.provider, result: result.unavailable)
    }

    private func load(status source: StatusSource) async {
        let result: Loaded<ServiceStatus>
        do {
            result = .value(try await source.fetchStatus())
        } catch {
            result = .missing(Self.reason(for: error, provider: source.provider))
        }
        statuses[source.provider] = result
        record(kind: "status", provider: source.provider, result: result.unavailable)
    }

    /// A plan we couldn't read is not worth a message.
    ///
    /// Every other source has an empty state worth rendering ("CLI not found"
    /// tells the user something). A missing plan does not: the quota bars are
    /// still correct without it, and an "Unknown plan" badge would be pure
    /// noise. So the failure is recorded but the view draws nothing.
    private func load(plan source: PlanSource) async {
        let result: Loaded<PlanTier>
        do {
            result = .value(try await source.fetchPlan())
        } catch {
            result = .missing(Self.reason(for: error, provider: source.provider))
        }
        plans[source.provider] = result
        record(kind: "plan", provider: source.provider, result: result.unavailable)
    }

    /// Collapses any thrown error to a displayable reason.
    ///
    /// Anything that isn't already a `SourceUnavailable` becomes `.failed`,
    /// which deliberately discards the underlying message: provider errors can
    /// echo request URLs, headers and account hints into a window the user may
    /// screenshot.
    private static func reason(for error: Error, provider: Provider) -> SourceUnavailable {
        (error as? SourceUnavailable) ?? .failed(provider)
    }

    // MARK: Local cache maintenance

    /// Deletes *our own* scan cache and forces a cold re-scan.
    ///
    /// SCOPE, deliberately narrow: this touches one directory —
    /// `~/Library/Application Support/MeterUsage` — which contains nothing but
    /// files this app wrote. It must never reach into `~/.claude`, `~/.codex`,
    /// or any other provider tree: those are the user's data, this app only
    /// reads them, and deleting from them would be a defect, not a feature. The
    /// path is rebuilt here from `HomeDirectory.real` rather than accepted from
    /// a caller so no call site can widen it.
    func clearLocalCache() {
        guard !isClearingCache else { return }
        isClearingCache = true
        Task { [weak self] in
            self?.performCacheClear()
            self?.isClearingCache = false
            // A cold scan is materially slower than a warm one, so re-read
            // immediately rather than leaving the user on stale numbers until
            // the next tick.
            self?.refresh()
        }
    }

    private func performCacheClear() {
        // Best-effort: a cache that can't be removed is not an error worth
        // interrupting the user for — the next scan simply stays warm.
        try? FileManager.default.removeItem(at: Self.cacheDirectory)
        // Deleting the file is only half of it. A source that has already run
        // is still holding the parsed entries in memory and would write them
        // straight back, so the "cold re-scan" would silently be a warm one.
        // Rebuilding the sources discards that state without this file needing
        // to know which sources keep any.
        if let factory = activitySourceFactory {
            activitySources = factory()
        }
    }

    /// The single directory this app is allowed to delete from.
    static var cacheDirectory: URL {
        HomeDirectory.real
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("MeterUsage", isDirectory: true)
    }

    // MARK: Derived state

    /// Providers the user has switched on, in a stable display order.
    var visibleProviders: [Provider] {
        Provider.allCases.filter { preferences.isEnabled($0) }
    }

    var visibleQuotaProviders: [Provider] {
        let providers = Set(quotaSources.map(\.provider))
        return visibleProviders.filter { providers.contains($0) }
    }

    /// Enabled providers the user also chose to show in the menu bar, in the
    /// stable display order. OpenRouter is pay-as-you-go (no quota), so it is
    /// always excluded from the tray regardless of the stored preference.
    var menuBarProviders: [Provider] {
        visibleProviders.filter { preferences.showsInMenuBar($0) && $0 != .openRouter }
    }

    var visibleActivityProviders: [Provider] {
        let providers = Set(activitySources.map(\.provider))
        return visibleProviders.filter { providers.contains($0) }
    }

    var visibleUsageProviders: [Provider] {
        let providers = Set(usageSources.map(\.provider))
        return visibleProviders.filter { providers.contains($0) }
    }

    var visibleStatusProviders: [Provider] {
        statusSources.map(\.provider)
    }

    /// Status sources describe service health, not provider usage. They remain
    /// visible even when the matching provider's usage card is switched off.
    var statusProviders: [Provider] { visibleStatusProviders }

    /// The single most-constrained window across every visible provider — the
    /// one number the menu bar shows.
    var mostConstrained: (provider: Provider, window: QuotaWindow)? {
        visibleQuotaProviders
            .compactMap { quotas[$0]?.value }
            .flatMap { quota in quota.windows.map { (quota.provider, $0) } }
            .max { $0.1.usedPercent < $1.1.usedPercent }
    }

    /// Worst known service severity, or `nil` when nothing has been checked.
    var worstStatus: ServiceStatus? {
        statusProviders
            .compactMap { statuses[$0]?.value }
            .max { $0.severity.rawValue < $1.severity.rawValue }
    }

    var combinedActivity: [LocalActivity] {
        visibleActivityProviders.compactMap { activities[$0]?.value }
    }

    /// Sanitized diagnostics for the "Copy diagnostics" button. Built from the
    /// same published state the views read, so it can never carry more than the
    /// popover shows — see `DiagnosticsReport`.
    func diagnosticsText() -> String {
        DiagnosticsReport.build(
            appName: AppInfo.name,
            appVersion: AppInfo.version,
            isDemoMode: isDemoMode,
            refreshInterval: preferences.refreshInterval,
            lastRefreshedAt: lastRefreshedAt,
            now: clock,
            enabledProviders: visibleProviders,
            quotas: quotas,
            activities: activities,
            usages: usages,
            statuses: statuses,
            plans: plans
        )
    }
}
