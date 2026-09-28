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

    /// State per metered account slot. Primary slots key exactly like the
    /// pre-slot maps; additional slots key on their own generated id, so two
    /// accounts of one tool never overwrite each other.
    @Published private(set) var quotas: [ProviderSlot: Loaded<ProviderQuota>] = [:]
    @Published private(set) var activities: [ProviderSlot: Loaded<LocalActivity>] = [:]
    @Published private(set) var usages: [ProviderSlot: Loaded<ProviderUsage>] = [:]
    @Published private(set) var testingAPIProviders: Set<Provider> = []
    @Published private(set) var apiConnectionErrors: [Provider: String] = [:]
    private let apiKeys: APIKeySession
    @Published private(set) var statuses: [Provider: Loaded<ServiceStatus>] = [:]
    /// Subscription tier per provider. Kept in its own map rather than folded
    /// into `quotas` because a plan is read from a different place than the
    /// quota (account metadata vs. rate-limit endpoint) and either can be
    /// present without the other.
    @Published private(set) var plans: [ProviderSlot: Loaded<PlanTier>] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var isClearingCache = false
    @Published private(set) var lastRefreshedAt: Date?
    /// Last good quota per provider, restored from disk at launch. Feeds only
    /// the ambient surfaces (notch, tray, tooltip) when live data is absent —
    /// always rendered dimmed and dated, never as a live number.
    @Published private(set) var archivedQuotas: [ProviderSlot: ProviderQuota] = [:]
    private let quotaArchiveURL: URL

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
    /// Reset consumers per account slot. Optional because only Codex exposes
    /// an account-mutating reset action, and per-slot because a second
    /// Codex account's reset credits are redeemed against that account's own
    /// subprocess (each slot's source holds its own client). A credit id can
    /// only be redeemed by the slot whose quota reported it.
    private let resetConsumers: [ProviderSlot: QuotaResetConsumer]
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
    /// Resolves where an additional account's config directory lives, for
    /// presence checks. Injectable so tests can point slots at fixture
    /// directories instead of the user's real home.
    let accountHome: (ManagedAccount) -> URL?
    /// Optional update-availability checker. `nil` in demo builds (an update
    /// banner would spoil marketing screenshots) and tests. Its published
    /// state is forwarded to `objectWillChange` so the popover re-renders
    /// without observing the checker directly.
    /// Optional callback invoked after each sweep with the freshly built limits report.
    var didPublishSnapshot: ((LimitsReport) -> Void)?
    var updateChecker: UpdateChecker? {
        didSet {
            guard let updateChecker, updateChecker !== oldValue else { return }
            updateChecker.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
    }

    // MARK: Scheduling

    private var refreshTask: Task<Void, Never>?
    /// Set when an explicit refresh arrives while a sweep is already in
    /// flight. Without this, opening the popover during a scheduled sweep
    /// would swallow the forced refresh — and that sweep may have skipped
    /// backed-off sources, leaving stale numbers on screen until the next
    /// manual open.
    private var pendingForcedRefresh = false
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

    private static func backoffKey(kind: String, slot: ProviderSlot) -> String {
        "\(kind)-\(slot.key)"
    }

    init(
        preferences: Preferences,
        isDemoMode: Bool = false,
        quotaSources: [QuotaSource] = [],
        resetConsumer: QuotaResetConsumer? = nil,
        resetConsumers: [ProviderSlot: QuotaResetConsumer] = [:],
        activitySources: [LocalActivitySource] = [],
        usageSources: [UsageSource] = [],
        statusSources: [StatusSource] = [],
        planSources: [PlanSource] = [],
        activitySourceFactory: (() -> [LocalActivitySource])? = nil,
        quotaArchiveURL: URL? = nil,
        accountHome: ((ManagedAccount) -> URL?)? = nil,
        apiKeys: APIKeySession = APIKeySession()
    ) {
        self.preferences = preferences
        self.isDemoMode = isDemoMode
        self.quotaSources = quotaSources
        // Reset consumers are derived from the quota sources themselves: a
        // source that can both read and mutate its slot owns that slot's
        // resets, so the map builds itself as slots come and go. The explicit
        // single-consumer parameter stays for tests and simpler call sites;
        // a derived entry wins when both exist for the same slot.
        var consumers: [ProviderSlot: QuotaResetConsumer] = resetConsumers
        for source in quotaSources {
            if let consumer = source as? QuotaResetConsumer {
                consumers[source.slot] = consumer
            }
        }
        if let resetConsumer {
            let slot = Self.resetConsumerSlot(of: resetConsumer, sources: quotaSources)
            if consumers[slot] == nil { consumers[slot] = resetConsumer }
        }
        self.resetConsumers = consumers
        self.activitySources = activitySources
        self.activitySourceFactory = activitySourceFactory
        self.usageSources = usageSources
        self.apiKeys = apiKeys
        self.apiConnectionErrors = apiKeys.restoreErrors
        self.statusSources = statusSources
        self.planSources = planSources
        let archiveURL = quotaArchiveURL ?? QuotaArchive.defaultURL
        self.quotaArchiveURL = archiveURL
        self.archivedQuotas = QuotaArchive.load(from: archiveURL)
        // Default: the account's configured path, tilde-expanded against the
        // real home. A nil result (blank path) reads as "not configured".
        self.accountHome = accountHome ?? { ManagedAccountPaths.home(for: $0) }
    }

    // No `deinit`: one coordinator is created by the app delegate and lives for
    // the process lifetime, so there is nothing to tear down, and a nonisolated
    // `deinit` cannot touch main-actor state cleanly.

    /// Which slot a reset consumer belongs to. A consumer that is itself a
    /// quota source names its own slot; a bare stub (tests, demo) attaches to
    /// the first Codex-family source, the only kind that can redeem resets.
    private nonisolated static func resetConsumerSlot(
        of consumer: QuotaResetConsumer,
        sources: [QuotaSource]
    ) -> ProviderSlot {
        if let source = consumer as? QuotaSource { return source.slot }
        return sources.first(where: { $0 is QuotaResetConsumer })?.slot ?? .primary(.codex)
    }

    // MARK: Lifecycle

    func start() {
        observeWake()
        observePreferences()
        startClock()
        restartSchedule()
        if preferences.updateCheckEnabled {
            updateChecker?.checkIfDue()
        }
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
        // Switching update checks off must clear any banner already on
        // screen, not merely stop future checks.
        preferences.$updateCheckEnabled
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self, let checker = self.updateChecker else { return }
                if enabled {
                    // Re-enabling is an explicit request: bypass the daily
                    // gate so the banner reflects reality right away instead
                    // of up to 24 hours later.
                    checker.checkIfDue(interval: 0)
                } else {
                    checker.reset()
                    self.objectWillChange.send()
                }
            }
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

    func hasAPIKey(for provider: Provider) -> Bool {
        apiKeys.key(for: provider) != nil
    }

    /// Test both reporting endpoints using the same source as scheduled refreshes.
    func connectAPI(_ provider: Provider, key: String) async {
        guard provider.isOrganizationAPI, !isDemoMode,
              !testingAPIProviders.contains(provider),
              let source = usageSources.first(where: { $0.provider == provider }) else { return }
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do { try apiKeys.set(key, for: provider) }
        catch {
            apiConnectionErrors[provider] = APIKeySession.message(for: error)
            return
        }
        apiConnectionErrors[provider] = nil
        await testAPIConnection(source)
    }

    func disconnectAPI(_ provider: Provider) {
        guard provider.isOrganizationAPI, !isDemoMode else { return }
        do { try apiKeys.set(nil, for: provider) }
        catch {
            apiConnectionErrors[provider] = APIKeySession.message(for: error)
            return
        }
        apiConnectionErrors[provider] = nil
        testingAPIProviders.remove(provider)
        usages[.primary(provider)] = .missing(.dataNotFound("API connection"))
    }

    func retrySavedAPIKey(_ provider: Provider) async {
        guard provider.isOrganizationAPI, !isDemoMode,
              !testingAPIProviders.contains(provider),
              let source = usageSources.first(where: { $0.provider == provider }) else { return }
        do { try apiKeys.restore(provider) }
        catch {
            apiConnectionErrors[provider] = APIKeySession.message(for: error)
            return
        }
        apiConnectionErrors[provider] = nil
        await testAPIConnection(source)
    }

    private func testAPIConnection(_ source: UsageSource) async {
        let provider = source.provider
        let revision = apiKeys.revision(for: provider)
        usages[.primary(provider)] = .idle
        testingAPIProviders.insert(provider)
        await load(usage: source)
        guard apiKeys.revision(for: provider) == revision else { return }
        testingAPIProviders.remove(provider)
        clock = Date()
    }

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
        guard refreshTask == nil else {
            // A sweep already in flight must not swallow an explicit request:
            // that sweep may be a scheduled one which skipped backed-off
            // sources, so honouring the request after it lands is what keeps
            // the popover from showing stale numbers until the next open.
            if !scheduled { pendingForcedRefresh = true }
            return
        }
        isRefreshing = true
        refreshTask = Task { [weak self] in
            await self?.performRefresh(forceAll: !scheduled)
            self?.isRefreshing = false
            self?.lastRefreshedAt = Date()
            self?.refreshTask = nil
            if self?.pendingForcedRefresh == true {
                self?.pendingForcedRefresh = false
                self?.refresh()
            }
        }
    }

    /// Refreshes only if the data is older than `maxAge`. Called when the
    /// popover opens, so opening it repeatedly doesn't hammer the sources.
    func refreshIfStale(maxAge: TimeInterval = 20) {
        guard let last = lastRefreshedAt else { return refresh() }
        if Date().timeIntervalSince(last) > maxAge { refresh() }
    }

    /// Refreshes only one metered slot's quota, usage, status, and plan
    /// sources.
    ///
    /// An explicit per-ring request: it bypasses backoff like any other
    /// user-initiated refresh, but never spends the other slots'
    /// rate-limit budget. Used by the side notch panel's click-to-refresh.
    func refresh(slot: ProviderSlot) {
        guard refreshTask == nil else {
            // A sweep is already running; fall back to a forced full refresh
            // afterwards rather than dropping the request.
            pendingForcedRefresh = true
            return
        }
        isRefreshing = true
        refreshTask = Task { [weak self] in
            await self?.performRefresh(slots: [slot])
            self?.isRefreshing = false
            self?.lastRefreshedAt = Date()
            self?.refreshTask = nil
            if self?.pendingForcedRefresh == true {
                self?.pendingForcedRefresh = false
                self?.refresh()
            }
        }
    }

    /// Whether a Codex rate-limit reset action is currently usable for a
    /// slot. Defaults to the primary account; an additional Codex account is
    /// redeemable only through its own source's subprocess.
    func canUseCodexReset(for slot: ProviderSlot = .primary(.codex)) -> Bool {
        resetConsumers[slot] != nil
    }

    /// Performs the explicitly confirmed Codex reset and refreshes all data so
    /// the menu immediately reflects the provider's new limits and remaining
    /// reset credits. A non-reset outcome is treated as unavailable rather
    /// than presented as a successful mutation.
    ///
    /// The reset is routed to the slot whose loaded quota reports the credit
    /// id, so a second Codex account's credits are redeemed against that
    /// account's own subprocess. When no loaded quota claims the id (credit
    /// expired between sweeps), the requested slot's consumer is used, and a
    /// single-account build keeps behaving exactly as before.
    func consumeCodexReset(creditID: String, in slot: ProviderSlot = .primary(.codex)) async throws {
        let claimedSlot = quotas.first(where: { _, state in
            state.value?.resetCredits.contains { $0.id == creditID } == true
        })?.key ?? slot
        guard let consumer = resetConsumers[claimedSlot] ?? resetConsumers[slot] else {
            throw SourceUnavailable.failed(claimedSlot.provider)
        }
        guard try await consumer.consumeReset(creditID: creditID) else {
            throw SourceUnavailable.failed(claimedSlot.provider)
        }
        refresh()
    }

    private func performRefresh(forceAll: Bool) async {
        if preferences.updateCheckEnabled {
            updateChecker?.checkIfDue()
        }
        // Sources are independent and mostly I/O-bound, so they run together and
        // the sweep costs as long as the slowest one, not their sum.
        let now = Date()
        await withTaskGroup(of: Void.self) { group in
            for source in quotaSources where showsSlot(source.slot) {
                if forceAll || !isBackedOff(kind: "quota", slot: source.slot, now: now) {
                    group.addTask { [weak self] in await self?.load(quota: source) }
                }
            }
            for source in activitySources where showsSlot(source.slot) {
                if forceAll || !isBackedOff(kind: "activity", slot: source.slot, now: now) {
                    group.addTask { [weak self] in await self?.load(activity: source) }
                }
            }
            for source in usageSources where showsSlot(source.slot) {
                if forceAll || !isBackedOff(kind: "usage", slot: source.slot, now: now) {
                    group.addTask { [weak self] in await self?.load(usage: source) }
                }
            }
            // Server health is independent of the provider visibility toggles:
            // hiding Claude usage should not hide the top-level health signal.
            for source in statusSources {
                if forceAll || !isBackedOff(kind: "status", slot: source.statusSlot, now: now) {
                    group.addTask { [weak self] in await self?.load(status: source) }
                }
            }
            for source in planSources where showsSlot(source.slot) {
                if forceAll || !isBackedOff(kind: "plan", slot: source.slot, now: now) {
                    group.addTask { [weak self] in await self?.load(plan: source) }
                }
            }
        }
        clock = Date()
        // Threshold alerts evaluate the full map after every sweep, whether or
        // not individual sources were skipped for backoff — a skipped source
        // simply keeps its previous reading. Pace alerts additionally require
        // a current burn, so the last-burn map rides along.
        quotaAlertService?.process(quotas: quotas, lastBurn: lastBurnBySlot)
        // Build the machine-readable report and notify any snapshot listener.
        didPublishSnapshot?(
            LimitsReporter.build(
                quotas: quotas,
                order: visibleQuotaSlots,
                lastBurn: lastBurnBySlot,
                now: clock))
        saveArchive()
    }

    /// Single-slot variant of the sweep above. Loads only the named slot's
    /// sources; status sources stay included because hiding usage must not
    /// hide the health signal.
    private func performRefresh(slots: [ProviderSlot]) async {
        let wanted = Set(slots)
        await withTaskGroup(of: Void.self) { group in
            for source in quotaSources where wanted.contains(source.slot) && showsSlot(source.slot) {
                group.addTask { [weak self] in await self?.load(quota: source) }
            }
            for source in activitySources where wanted.contains(source.slot) && showsSlot(source.slot) {
                group.addTask { [weak self] in await self?.load(activity: source) }
            }
            for source in usageSources where wanted.contains(source.slot) && showsSlot(source.slot) {
                group.addTask { [weak self] in await self?.load(usage: source) }
            }
            for source in statusSources where wanted.contains(source.statusSlot) {
                group.addTask { [weak self] in await self?.load(status: source) }
            }
            for source in planSources where wanted.contains(source.slot) && showsSlot(source.slot) {
                group.addTask { [weak self] in await self?.load(plan: source) }
            }
        }
        clock = Date()
        quotaAlertService?.process(quotas: quotas, lastBurn: lastBurnBySlot)
        didPublishSnapshot?(
            LimitsReporter.build(
                quotas: quotas,
                order: visibleQuotaSlots,
                lastBurn: lastBurnBySlot,
                now: clock))
        saveArchive()
    }

    /// Service health for a slot. Alternate-account slots resolve to their
    /// base provider's check: the service is shared across accounts, and
    //  only one status source exists per service.
    func status(for provider: Provider) -> Loaded<ServiceStatus>? {
        statuses[provider]
    }

    /// The quota an ambient surface should render: the live reading when
    /// present, otherwise the archived last-good reading marked stale. `nil`
    /// only when neither exists — the honest "we do not know" case.
    func displayQuota(for slot: ProviderSlot) -> (quota: ProviderQuota, isStale: Bool)? {
        if let live = quotas[slot]?.value {
            return (live, false)
        }
        if let remembered = archivedQuotas[slot] {
            return (remembered, true)
        }
        return nil
    }

    private func saveArchive() {
        QuotaArchive.save(archivedQuotas, to: quotaArchiveURL)
    }

    /// Most recent observable burn per provider. Feeds the pace-honesty gate:
    /// alerts and the machine report may only claim "burning fast" while the
    /// provider burned inside the quiet period (see `BurnRecency`).
    var lastBurnBySlot: [ProviderSlot: Date] {
        BurnRecency.lastBurns(from: activities)
    }

    private func isBackedOff(kind: String, slot: ProviderSlot, now: Date) -> Bool {
        guard let backoff = backoffs[Self.backoffKey(kind: kind, slot: slot)] else { return false }
        return now < backoff.nextAttemptAt
    }

    /// Records one sweep outcome for a source. A value clears any backoff; a
    /// *transient* failure (`.failed`, `.offline`) extends it exponentially.
    /// Permanent conditions — CLI not installed, nothing signed in, no data
    /// yet — are facts about the machine, not outages, so they never back off:
    /// the user should see them resolve on the very next sweep after they fix
    /// the cause.
    private func record(kind: String, slot: ProviderSlot, result: SourceUnavailable?) {
        let key = Self.backoffKey(kind: kind, slot: slot)
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
            let quota = try await source.fetchQuota()
            result = .value(quota)
            archivedQuotas[source.slot] = quota
        } catch {
            result = .missing(Self.reason(for: error, provider: source.slot.provider))
        }
        quotas[source.slot] = result
        record(kind: "quota", slot: source.slot, result: result.unavailable)
    }

    private func load(activity source: LocalActivitySource) async {
        let result: Loaded<LocalActivity>
        do {
            var activity = try await source.scan()
            if !isDemoMode {
                let peak = quotas[source.slot]?.value?.windows.map(\.usedPercent).max()
                DurableHistoryStore.shared.record(key: source.slot.key, daily: activity.daily, peakUsedPercent: peak)
                let durableDaily = DurableHistoryStore.shared.records(forKey: source.slot.key)
                if !durableDaily.isEmpty {
                    var byDay: [String: DailyActivity] = [:]
                    let dayFormatter = DateFormatter()
                    dayFormatter.dateFormat = "yyyy-MM-dd"
                    dayFormatter.timeZone = TimeZone(secondsFromGMT: 0)
                    for d in durableDaily {
                        byDay[dayFormatter.string(from: d.day)] = d
                    }
                    for d in activity.daily {
                        let iso = dayFormatter.string(from: d.day)
                        if let existing = byDay[iso], existing.tokens.total > d.tokens.total {
                            // keep existing with larger tokens
                        } else {
                            byDay[iso] = d
                        }
                    }
                    let mergedDaily = byDay.values.sorted(by: { $0.day < $1.day })
                    activity = LocalActivity(
                        provider: activity.provider,
                        sessions: activity.sessions,
                        daily: mergedDaily,
                        scannedAt: activity.scannedAt
                    )
                }
            }
            result = activity.sessions.isEmpty && activity.daily.isEmpty
                ? .missing(.noData)
                : .value(activity)
        } catch {
            result = .missing(Self.reason(for: error, provider: source.slot.provider))
        }
        activities[source.slot] = result
        record(kind: "activity", slot: source.slot, result: result.unavailable)
    }

    private func load(usage source: UsageSource) async {
        let revision = apiKeys.revision(for: source.provider)
        let result: Loaded<ProviderUsage>
        do {
            result = .value(try await source.fetchUsage())
        } catch {
            result = .missing(Self.reason(for: error, provider: source.slot.provider))
        }
        // A disconnected or replaced key must not publish a late account reading.
        guard apiKeys.revision(for: source.provider) == revision else { return }
        usages[source.slot] = result
        record(kind: "usage", slot: source.slot, result: result.unavailable)
    }

    private func load(status source: StatusSource) async {
        let result: Loaded<ServiceStatus>
        do {
            result = .value(try await source.fetchStatus())
        } catch {
            result = .missing(Self.reason(for: error, provider: source.provider))
        }
        statuses[source.provider] = result
        record(kind: "status", slot: source.statusSlot, result: result.unavailable)
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
            result = .missing(Self.reason(for: error, provider: source.slot.provider))
        }
        plans[source.slot] = result
        record(kind: "plan", slot: source.slot, result: result.unavailable)
    }

    /// Downloads, verifies, and installs the visible update, then relaunches.
    /// A no-op when there is no visible release or an install is running.
    func installAvailableUpdate() {
        guard let checker = updateChecker, let release = checker.visibleRelease else { return }
        checker.downloadAndInstall(release)
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

    /// Whether a slot's sources should be polled and shown: the primary
    /// slot follows its provider toggle; an additional slot must be enabled
    /// AND its config directory must exist — an additional account is a
    /// directory the user configured, not a guess. Service status is polled
    /// independently of both gates (see `performRefresh`), so hiding an
    /// account never hides an outage. Demo mode mounts synthetic slots for
    /// the additional accounts of the demoed tools regardless of either
    /// gate — they exist to be screenshotted.
    func showsSlot(_ slot: ProviderSlot) -> Bool {
        if isDemoMode {
            return slot.isPrimary ? preferences.isEnabled(slot.provider) : true
        }
        if slot.isPrimary {
            return preferences.isEnabled(slot.provider)
        }
        guard let account = preferences.managedAccounts.first(where: { $0.id == slot.slotID }),
              account.enabled,
              accountHome(account) != nil else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: accountHome(account)!.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Metered slots the user has switched on, in a stable display order.
    var visibleSlots: [ProviderSlot] {
        (Provider.allCases.map { ProviderSlot.primary($0) } + additionalSlots).filter { showsSlot($0) }
    }

    /// Additional configured slots, in the order they were added.
    var additionalSlots: [ProviderSlot] {
        preferences.managedAccounts.map(\.slot)
    }

    var visibleQuotaSlots: [ProviderSlot] {
        let slots = Set(quotaSources.map(\.slot))
        return visibleSlots.filter { slots.contains($0) }
    }

    /// Enabled slots the user also chose to show in the menu bar, in the
    /// stable display order. OpenRouter and OpenAI API stay out of the tray.
    var menuBarSlots: [ProviderSlot] {
        visibleSlots.filter {
            preferences.showsInMenuBar($0.provider) && $0.provider != .openRouter && $0.provider != .openAI
        }
    }

    /// Enabled slots the user also chose to show in the side notch panel,
    /// in the stable display order. The tray and the notch are independent
    /// surfaces (see `menuBarSlots`). OpenAI API shows reported spend without
    /// a quota ring; OpenRouter can show a key limit or account balance.
    var sideNotchSlots: [ProviderSlot] {
        visibleSlots.filter { preferences.showsInMenuBar($0.provider) }
    }

    var visibleActivitySlots: [ProviderSlot] {
        let slots = Set(activitySources.map(\.slot))
        return visibleSlots.filter { slots.contains($0) }
    }

    var visibleUsageProviders: [Provider] {
        let providers = Set(usageSources.map(\.slot.provider))
        let quotaProviders = Set(visibleQuotaSlots.map(\.provider))
        return visibleSlots.map(\.provider).filter { providers.contains($0) && !quotaProviders.contains($0) }
    }

    var visibleStatusProviders: [Provider] {
        statusSources.map(\.provider)
    }

    /// Status sources describe service health, not provider usage. They remain
    /// visible even when the matching provider's usage card is switched off.
    var statusProviders: [Provider] { visibleStatusProviders }

    /// Worst known service severity, or `nil` when nothing has been checked.
    var worstStatus: ServiceStatus? {
        statusProviders
            .compactMap { statuses[$0]?.value }
            .max { $0.severity.rawValue < $1.severity.rawValue }
    }

    var combinedActivity: [LocalActivity] {
        visibleActivitySlots.compactMap { activities[$0]?.value }
    }

    /// Whose readings these are: the plan the slot reports (when it reports
    /// one) and the tool holding the credential. No identity is read — a
    /// plan tier is context for the percentages, never an account.
    struct ProviderAccount {
        let plan: String?
        let via: String
        /// The slot's own display name, so two accounts of one tool read as
        /// two rows.
        let name: String
    }

    func account(for slot: ProviderSlot) -> ProviderAccount {
        let plan = plans[slot]?.value?.displayName
            ?? quotas[slot]?.value?.planType
        return ProviderAccount(plan: plan, via: slot.provider.sourceLabel, name: slot.displayName)
    }

    /// Sanitized diagnostics for the "Copy diagnostics" button, including
    /// provider state and local history persistence errors.
    func diagnosticsText() -> String {
        DiagnosticsReport.build(
            appName: AppInfo.name,
            appVersion: AppInfo.version,
            isDemoMode: isDemoMode,
            refreshInterval: preferences.refreshInterval,
            lastRefreshedAt: lastRefreshedAt,
            now: clock,
            enabledSlots: visibleSlots,
            quotas: quotas,
            activities: activities,
            usages: usages,
            statuses: statuses,
            plans: plans,
            historyError: isDemoMode ? nil : DurableHistoryStore.shared.error
        )
    }
}
