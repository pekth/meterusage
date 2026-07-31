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

    // MARK: Sources

    private let quotaSources: [QuotaSource]
    /// Not `let`: clearing the cache replaces these instances (see
    /// `performCacheClear`), which is how a re-scan is made genuinely cold.
    private var activitySources: [LocalActivitySource]
    /// Rebuilds the activity sources from scratch. Supplied by the composition
    /// root so this file still names no concrete source.
    private let activitySourceFactory: (() -> [LocalActivitySource])?
    private let statusSources: [StatusSource]
    /// Optional: a build with no plan source simply never renders a plan badge,
    /// which is the same as a source that reports `.noData`.
    private let planSources: [PlanSource]

    // MARK: Scheduling

    private var refreshTask: Task<Void, Never>?
    private var scheduleTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()

    init(
        preferences: Preferences,
        quotaSources: [QuotaSource] = [],
        activitySources: [LocalActivitySource] = [],
        statusSources: [StatusSource] = [],
        planSources: [PlanSource] = [],
        activitySourceFactory: (() -> [LocalActivitySource])? = nil
    ) {
        self.preferences = preferences
        self.quotaSources = quotaSources
        self.activitySources = activitySources
        self.activitySourceFactory = activitySourceFactory
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
                self?.refresh()
            }
        }
    }

    // MARK: Refresh

    /// Kicks off a refresh, coalescing with one already in flight.
    ///
    /// Wake, timer and popover-open can all fire within the same second; running
    /// three concurrent sweeps would spawn duplicate CLI subprocesses for no
    /// benefit.
    func refresh() {
        guard refreshTask == nil else { return }
        isRefreshing = true
        refreshTask = Task { [weak self] in
            await self?.performRefresh()
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

    private func performRefresh() async {
        // Sources are independent and mostly I/O-bound, so they run together and
        // the sweep costs as long as the slowest one, not their sum.
        await withTaskGroup(of: Void.self) { group in
            for source in quotaSources {
                group.addTask { [weak self] in await self?.load(quota: source) }
            }
            for source in activitySources {
                group.addTask { [weak self] in await self?.load(activity: source) }
            }
            for source in statusSources {
                group.addTask { [weak self] in await self?.load(status: source) }
            }
            for source in planSources {
                group.addTask { [weak self] in await self?.load(plan: source) }
            }
        }
        clock = Date()
    }

    private func load(quota source: QuotaSource) async {
        let result: Loaded<ProviderQuota>
        do {
            result = .value(try await source.fetchQuota())
        } catch {
            result = .missing(Self.reason(for: error, provider: source.provider))
        }
        quotas[source.provider] = result
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
    }

    private func load(status source: StatusSource) async {
        let result: Loaded<ServiceStatus>
        do {
            result = .value(try await source.fetchStatus())
        } catch {
            result = .missing(Self.reason(for: error, provider: source.provider))
        }
        statuses[source.provider] = result
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

    /// The single most-constrained window across every visible provider — the
    /// one number the menu bar shows.
    var mostConstrained: (provider: Provider, window: QuotaWindow)? {
        visibleProviders
            .compactMap { quotas[$0]?.value }
            .flatMap { quota in quota.windows.map { (quota.provider, $0) } }
            .max { $0.1.usedPercent < $1.1.usedPercent }
    }

    /// Worst known service severity, or `nil` when nothing has been checked.
    var worstStatus: ServiceStatus? {
        visibleProviders
            .compactMap { statuses[$0]?.value }
            .max { $0.severity.rawValue < $1.severity.rawValue }
    }

    var combinedActivity: [LocalActivity] {
        visibleProviders.compactMap { activities[$0]?.value }
    }
}
