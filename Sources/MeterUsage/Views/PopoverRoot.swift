import SwiftUI
import AppKit

// MARK: - Unified strip totals
//
// Pure aggregation behind the "ALL AI CODING TODAY" strip, extracted so the
// day-boundary math is unit-testable without rendering the popover.
//
// TODAY is derived from session activity windows against local midnight: day
// buckets are UTC-midnight days (Codex and Claude group by UTC), so no
// UTC/local bucket comparison can define "today" at all hours — a local
// compare misses the whole day west of UTC, and a UTC compare misses every
// evening past 20:00 EDT. Session instants are unambiguous in any zone, and a
// session counts toward today when its window overlaps today (started before
// local midnight but still written after it counts), so a session in flight
// across midnight never drops the day to zero. The 7-day WEEK still sums the
// UTC day buckets, where an hour-scale boundary difference is immaterial.
// Usage day-totals keep the local-day convention computed inside their own
// sources.
struct StripTotals {
    let todayTokens: Int
    let weekTokens: Int
    let todayCost: Double

    static func calculate(
        activities: [LocalActivity],
        usages: [ProviderUsage],
        now: Date,
        calendar: Calendar = .current
    ) -> StripTotals {
        let todayStart = calendar.startOfDay(for: now)
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? now
        // Today plus the 6 prior days: 7 calendar days for the "last 7 days"
        // label. `>=` on a -7d start would silently count 8 days.
        let weekStart = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let weekStartUTC = utcCalendar.date(
            byAdding: .day, value: -6,
            to: utcCalendar.startOfDay(for: now)) ?? weekStart

        var todayTokens = 0
        var weekTokens = 0
        var todayCost: Double = 0.0

        for act in activities {
            let todaySessions = act.sessions.filter {
                $0.startedAt < tomorrowStart && $0.activeUntil >= todayStart
            }
            todayTokens += todaySessions.reduce(0) { $0 + $1.tokens.total }
            todayCost += todaySessions.reduce(0.0) { $0 + $1.estimatedCostUSD }
            if !act.daily.isEmpty {
                for day in act.daily where day.day >= weekStartUTC {
                    weekTokens += day.tokens.total
                }
            } else {
                weekTokens += act.sessions.filter { $0.startedAt >= weekStart }
                    .reduce(0) { $0 + $1.tokens.total }
            }
        }
        for usage in usages {
            if let t = usage.todayTokens { todayTokens += t.total }
            if let w = usage.weekTokens { weekTokens += w.total }
            if let c = usage.todayCostUSD { todayCost += c }
        }
        return StripTotals(todayTokens: todayTokens, weekTokens: weekTokens, todayCost: todayCost)
    }
}

// MARK: - Failover nudge
//
// Pure decision behind the "X burning fast. Switch to Y" line in the totals
// card, extracted so the honesty rules are unit-testable without rendering
// the popover.
//
// Two claims, never mixed: "burning fast" is present tense and requires a
// pace deficit plus burn evidence inside the quiet period (`BurnRecency`);
// "near its limit" is a state claim from `usedPercent >= 80` alone. A
// window-shape deficit without a recent burn is neither — a weekly window
// holds its deficit for days after the burst — so it produces no burning
// claim at all, only the near-limit wording when the window is nearly gone.

struct FailoverNudge: Equatable {
    /// One provider worth warning about. A struct rather than a tuple so
    /// key paths work for the ordering and exclusion sets below.
    private struct Hot: Equatable {
        let provider: Provider
        let window: QuotaWindow
        let activelyBurning: Bool
    }

    let message: String?
    let accessibilityLabel: String

    static func evaluate(
        providers: [Provider],
        headline: (Provider) -> QuotaWindow?,
        lastBurn: (Provider) -> Date?,
        now: Date
    ) -> FailoverNudge {
        // A provider is worth warning about when it is actively burning
        // fast, or when its headline window is nearly gone — the former is a
        // pace claim gated on burn recency, the latter a plain state claim.
        let hot: [Hot] = providers.compactMap { p in
            guard let h = headline(p) else { return nil }
            let burning = h.pace(now: now)?.status.isDeficit == true
                && BurnRecency.isActive(lastBurn: lastBurn(p), now: now)
            guard burning || h.usedPercent >= 80 else { return nil }
            return Hot(provider: p, window: h, activelyBurning: burning)
        }

        // Never suggest switching to a provider that is itself hot —
        // "Codex burning fast. Switch to Codex" is the exact failure.
        let hotProviders = Set(hot.map(\.provider))
        let alternatives = providers.filter { p in
            guard !hotProviders.contains(p), let h = headline(p) else { return false }
            return h.usedPercent < 50
        }

        // An actively burning provider outranks one that merely sits near
        // its limit; without alternatives there is nothing to switch to.
        guard let first = hot.first(where: \.activelyBurning) ?? hot.first,
              !alternatives.isEmpty else {
            return FailoverNudge(message: nil, accessibilityLabel: "")
        }

        let names = alternatives.map(\.displayName).joined(separator: ", ")
        let label = first.window.label.lowercased()
        let limit = label.contains("limit") ? label : "\(label) limit"
        let claim = first.activelyBurning
            ? "\(first.provider.displayName) burning fast."
            : "\(first.provider.displayName) near its \(limit)."
        return FailoverNudge(
            message: "\(claim) Switch to \(names) for headroom.",
            accessibilityLabel: "\(claim) Headroom in \(names)."
        )
    }
}

/// The whole popover: a fixed header, a scrolling body, and a settings pane that
/// swaps in place of the body.
///
/// Layout is deliberately one column of cards at a fixed width. A menu-bar
/// popover is read at a glance and dismissed; anything that needs horizontal
/// scanning or resizing belongs in a real window, which this app does not have.
struct PopoverRoot: View {

    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var preferences: Preferences

    @State private var showingSettings = false
    /// First-run welcome. Absent means never dismissed, which is what shows
    /// the page; either button on it writes through and never returns.
    @AppStorage(PrefKey.onboardingDone) private var onboardingDone = false
    @AppStorage(PrefKey.sideNotchPanel) private var sideNotchPanel = false

    @State private var headerHeight: CGFloat = 44
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: HeaderHeightKey.self, value: proxy.size.height)
                    }
                )
            Divider().overlay(MU.hairline)
            content
        }
        .frame(
            width: MU.popoverWidth,
            height: min(MU.popoverHeight, headerHeight + 1 + contentHeight)
        )
        .onPreferenceChange(HeaderHeightKey.self) { headerHeight = $0 }
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        .background(MU.canvas)
        .preferredColorScheme(preferences.theme.colorScheme)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(showingSettings ? "Settings" : AppInfo.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(MU.text)

            if AppInfo.isPreview {
                Text("v2 PREVIEW")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.purple)
                    .clipShape(Capsule())
            }

            // Every number below is synthetic when this shows. Quiet enough not
            // to spoil a marketing screenshot, unmistakable on inspection — so
            // a demo shot can never be read as real telemetry, and nobody files
            // a bug about the figures being wrong.
            if coordinator.isDemoMode {
                PlanBadge(text: "Demo")
            }

            if coordinator.isRefreshing && !showingSettings {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
                    .transition(.opacity)
            }

            Spacer(minLength: 0)

            if !showingSettings, let last = coordinator.lastRefreshedAt {
                Text(Fmt.timeSince(last, now: coordinator.clock))
                    .font(.muCaption)
                    .foregroundColor(MU.textTertiary)
            }

            IconButton(symbol: "arrow.clockwise", help: "Refresh now") {
                coordinator.refresh()
            }
            .disabled(coordinator.isRefreshing)
            .opacity(showingSettings ? 0 : 1)

            IconButton(
                symbol: showingSettings ? "chevron.backward" : "gearshape",
                help: showingSettings ? "Back" : "Settings"
            ) {
                withAnimation(.easeInOut(duration: 0.2)) { showingSettings.toggle() }
            }
        }
        .padding(.horizontal, MU.gutter)
        .padding(.vertical, 10)
        .animation(.easeInOut(duration: 0.2), value: coordinator.isRefreshing)
    }

    // MARK: Body

    private var content: some View {
        ScrollView(.vertical) {
            Group {
                if showingSettings {
                    SettingsView(coordinator: coordinator)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                } else if !onboardingDone {
                    onboarding
                        .transition(.opacity)
                } else {
                    dashboard
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .padding(MU.gutter)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                }
            )
        }
        .scrollIndicatorsHiddenIfAvailable()
    }

    // MARK: Onboarding

    /// First-run page explaining where usage lives now.
    ///
    /// Exists because the compact menu bar is the default: a tray that once
    /// showed every provider's figures now shows one mark, and a first-time
    /// reader has no way to guess that the side notch panel carries what the
    /// tray used to. The page says so once and both its buttons dismiss it
    /// permanently — nobody should be re-greeted on every open.
    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader("Welcome")
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        CompactTrayGlyph()
                        Text("The menu bar now shows one small mark.")
                            .font(.muBody)
                            .foregroundColor(MU.text)
                    }
                    Text("Your usage meters live in the side notch panel: a floating strip of rings. Hover any ring for its detail card — the card flips sides to stay on screen — and drag the strip anywhere. Click the menu bar mark to open this popover anytime.")
                        .font(.muBody)
                        .foregroundColor(MU.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("You can change this in Settings at any time.")
                        .font(.muCaption)
                        .foregroundColor(MU.textTertiary)
                }
            }
            HStack(spacing: 8) {
                Button {
                    sideNotchPanel = true
                    onboardingDone = true
                } label: {
                    Text("Enable side notch panel")
                }
                .controlSize(.regular)
                Spacer(minLength: 6)
                Button {
                    onboardingDone = true
                } label: {
                    Text("Continue")
                }
                .controlSize(.regular)
            }
        }
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 14) {

            if let release = coordinator.updateChecker?.visibleRelease {
                UpdateBanner(
                    release: release,
                    installState: coordinator.updateChecker?.installState ?? .idle,
                    onInstall: { coordinator.installAvailableUpdate() },
                    onDismiss: { coordinator.updateChecker?.dismiss() }
                )
            }

            StatusStrip(
                statuses: coordinator.statuses,
                providers: coordinator.statusProviders,
                now: coordinator.clock
            )

            if AppInfo.isPreview {
                previewImprovementsCard
            }

            unifiedActivityStrip

            SectionHeader("Quotas")
            if coordinator.visibleQuotaProviders.isEmpty {
                Card {
                    InfoState(
                        message: "No quota providers shown",
                        hint: "Turn Codex, OpenRouter, or Claude on in Settings."
                    )
                }
            } else {
                ForEach(coordinator.visibleQuotaProviders, id: \.self) { provider in
                    QuotaSection(
                        provider: provider,
                        state: coordinator.quotas[provider] ?? .idle,
                        plan: coordinator.plans[provider] ?? .idle,
                        now: coordinator.clock,
                        onUseReset: { creditID in
                            try await coordinator.consumeCodexReset(creditID: creditID)
                        },
                        // Codex and Claude render their weekly heatmaps inside
                        // their own quota cards so all of a provider's figures
                        // sit together. Codex shades by sessions (no token
                        // ledger); Claude shades by tokens. Other providers
                        // pass nothing and render unchanged.
                        heatmapDaily: heatmapDaily(for: provider),
                        heatmapIntensity: provider == .codex ? .sessions : .tokens,
                        lastBurn: BurnRecency.lastBurn(
                            of: coordinator.activities[provider]?.value?.sessions ?? [])
                    )
                }
            }

            ProviderUsageSection(
                usages: coordinator.usages,
                providers: coordinator.visibleUsageProviders,
                now: coordinator.clock
            )
        }
    }

    private func heatmapDaily(for provider: Provider) -> [DailyActivity] {
        switch provider {
        case .codex:  return coordinator.activities[.codex]?.value?.daily ?? []
        case .claude: return coordinator.activities[.claude]?.value?.daily ?? []
        default:      return []
        }
    }

    @State private var showImprovementsList = false

    private var previewImprovementsCard: some View {
        Card(padding: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showImprovementsList.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .foregroundColor(.purple)
                            .font(.system(size: 11, weight: .bold))
                        Text("v2 Pipeline: Top 10 Improvements Active")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(MU.text)
                        Spacer()
                        Text(showImprovementsList ? "Hide" : "Compare")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.purple)
                        Image(systemName: showImprovementsList ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9))
                            .foregroundColor(MU.textTertiary)
                    }
                }
                .buttonStyle(.plain)

                if showImprovementsList {
                    VStack(alignment: .leading, spacing: 6) {
                        featureRow(num: "1", title: "Ambient Time-To-Empty", desc: "Menu bar [v2] badge & card ETA (~XXm left) when burning fast")
                        featureRow(num: "2", title: "Window Burn Attribution", desc: "Tokens attributed by project & model in card below")
                        featureRow(num: "3", title: "Context Waste Hints", desc: "Real-time cache-hit %, avg tokens/turn & long-chat flags")
                        featureRow(num: "4", title: "Durable History Store", desc: "Daily history survives CLI purges in Application Support")
                        featureRow(num: "5", title: "Unified AI Coding Strip", desc: "Aggregated tokens and cost across all tools today")
                        featureRow(num: "6", title: "Claude Quota Companion", desc: "Maintains JSON snapshots preserving limits[]")
                        featureRow(num: "7", title: "Cursor, Copilot & Gemini", desc: "Local sources ready in Settings > Providers")
                        featureRow(num: "8", title: "Smart Pace Alerts", desc: "Pace cliff (<30m) and 50% soft warnings")
                        featureRow(num: "9", title: "Headroom Failover", desc: "Smart nudge to alternate providers on quota pressure")
                        featureRow(num: "10", title: "Agent Budget API", desc: "Run 'meterusage json' for machine-readable pacing & ETAs")
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private func featureRow(num: String, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(num)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.purple)
                .frame(width: 14, height: 14)
                .background(Color.purple.opacity(0.14))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(MU.text)
                Text(desc)
                    .font(.system(size: 9.5))
                    .foregroundColor(MU.textSecondary)
            }
        }
    }

    private var unifiedActivityStrip: some View {
        // Day buckets are the source of truth for "today" vs "last 7 days":
        // a session started yesterday that ran past midnight must count toward
        // today. Fall back to session start dates only when a provider has no
        // daily history yet. Token-bearing usage sources (OpenCode Go,
        // Antigravity, OpenRouter) contribute their own day totals — without
        // them the strip only ever saw Codex and Claude.
        //
        // Two day conventions meet here: activity "today" counts sessions
        // started today (local day, exact instants), while usage day-totals
        // count by last activity (a session started days ago but worked on
        // today counts toward today, matching the rolling windows). Both are
        // approximations of "work done today" from stores that never record
        // per-day ledgers; the difference only shows at day boundaries.
        let totals = StripTotals.calculate(
            activities: Provider.allCases.compactMap { coordinator.activities[$0]?.value },
            usages: Provider.allCases.compactMap { coordinator.usages[$0]?.value },
            now: coordinator.clock
        )
        let todayTokens = totals.todayTokens
        let weekTokens = totals.weekTokens
        let todayCost = totals.todayCost
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: coordinator.clock)
        // Today plus the 6 prior days: 7 calendar days for the "last 7 days"
        // label. `>=` on a -7d start would silently count 8 days.
        let weekStart = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart

        let nudge = FailoverNudge.evaluate(
            providers: coordinator.visibleQuotaProviders,
            headline: { p in
                guard let q = coordinator.displayQuota(for: p)?.quota else { return nil }
                return p.headlineWindow(from: q.windows)
            },
            lastBurn: { p in
                BurnRecency.lastBurn(of: coordinator.activities[p]?.value?.sessions ?? [])
            },
            now: coordinator.clock
        )

        return VStack(alignment: .leading, spacing: 6) {
            Card(padding: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(MU.accent)
                        Text("ALL AI CODING TODAY")
                            .font(.muSectionTitle)
                            .tracking(0.8)
                            .foregroundColor(MU.textTertiary)
                        Spacer()
                        if todayCost > 0 {
                            Text(Fmt.usd(todayCost))
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundColor(MU.textSecondary)
                        }
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(todayTokens > 0 ? Fmt.tokenCountString(todayTokens) : "0")
                                .font(.system(size: 19, weight: .semibold).monospacedDigit())
                                .foregroundColor(todayTokens > 0 ? MU.text : MU.textTertiary)
                            Text(todayTokens > 0 ? "tokens today" : "no sessions today")
                                .font(.muCaption)
                                .foregroundColor(MU.textSecondary)
                        }

                        if weekTokens > todayTokens {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(Fmt.tokenCountString(weekTokens))
                                    .font(.system(size: 19, weight: .semibold).monospacedDigit())
                                    .foregroundColor(MU.text)
                                Text("last 7 days")
                                    .font(.muCaption)
                                    .foregroundColor(MU.textSecondary)
                            }
                        }

                        Spacer()

                        HStack(spacing: 3) {
                            ForEach(coordinator.menuBarProviders, id: \.self) { p in
                                ProviderMark(provider: p, tint: providerColor(p))
                                    .frame(width: 11, height: 11)
                                    .help(p.displayName)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Includes: \(coordinator.menuBarProviders.map(\.displayName).joined(separator: ", "))")
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(Fmt.tokenCountString(todayTokens)) tokens today, \(Fmt.tokenCountString(weekTokens)) last 7 days")

                    if let message = nudge.message {
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: "arrow.triangle.swap")
                                .font(.system(size: 9.5))
                                .foregroundColor(MU.warn)
                                .padding(.top, 1)
                            Text(message)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(MU.warn)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 2)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(nudge.accessibilityLabel)
                    }

                    // Attribution covers every token-bearing provider over the
                    // same 7-day scope as the totals above — not just the
                    // last 8 Codex/Claude sessions. No fallback to stale
                    // sessions: an empty week hides the section instead of
                    // presenting old burn as today's.
                    let attributionSessions = BurnAttributionCalculator.attributionSessions(
                        activities: coordinator.activities,
                        usages: coordinator.usages,
                        now: coordinator.clock
                    )
                    let burnBreakdown = BurnAttributionCalculator.calculate(
                        sessions: attributionSessions,
                        window: nil,
                        since: weekStart,
                        fallbackToRecent: false,
                        now: coordinator.clock
                    )
                    if let breakdown = burnBreakdown, !breakdown.contributors.isEmpty {
                        Divider().overlay(MU.hairline).padding(.vertical, 2)

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "flame.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(MU.warn)
                                Text("BURN ATTRIBUTION & CONTEXT EFFICIENCY")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .tracking(0.6)
                                    .foregroundColor(MU.textTertiary)
                                Spacer()
                                Text("last 7d")
                                    .font(.muCaption)
                                    .foregroundColor(MU.textTertiary)
                            }

                            VStack(alignment: .leading, spacing: 7) {
                                ForEach(breakdown.contributors.prefix(3), id: \.id) { c in
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                                            Text(c.projectName.isEmpty ? "default" : c.projectName)
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundColor(MU.text)
                                                .lineLimit(1)
                                                .truncationMode(.tail)
                                            // Aggregates carry a provider's whole week under
                                            // the provider name with no model — no separator.
                                            if !c.model.isEmpty {
                                                Text("· \(Fmt.shortModel(c.model))")
                                                    .font(.system(size: 10))
                                                    .foregroundColor(MU.textSecondary)
                                                    .lineLimit(1)
                                                    .truncationMode(.tail)
                                            }
                                            Spacer(minLength: 6)
                                            Text("\(Fmt.tokenCountString(c.totalTokens)) (\(Fmt.share(c.shareOfWindow)))")
                                                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                                                .foregroundColor(MU.text)
                                        }
                                        MeterBar(fraction: (c.shareOfWindow / 100).muClamped(to: 0...1), tint: MU.neutral, height: 4)
                                    }
                                    .help("\(c.projectName.isEmpty ? "default" : c.projectName)\(c.model.isEmpty ? "" : " · \(Fmt.shortModel(c.model))") — \(Fmt.tokenCountString(c.totalTokens)) (\(Fmt.share(c.shareOfWindow)))")
                                    .accessibilityElement(children: .combine)
                                    .accessibilityLabel("\(c.projectName.isEmpty ? "default" : c.projectName)\(c.model.isEmpty ? "" : ", \(Fmt.shortModel(c.model))"), \(Fmt.tokenCountString(c.totalTokens)), \(Fmt.share(c.shareOfWindow)) of last 7 days burn")
                                }
                            }

                            HStack(spacing: 12) {
                                if let hit = breakdown.cacheHitRate {
                                    HStack(spacing: 3) {
                                        Image(systemName: "bolt.badge.checkmark.fill")
                                            .font(.system(size: 9))
                                            .foregroundColor(hit >= 80 ? MU.good : (hit >= 50 ? MU.calm : MU.warn))
                                        Text("Cache \(Int(round(hit)))%")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundColor(MU.textSecondary)
                                    }
                                    .help("Share of recent tokens served from cache")
                                }
                                if let avg = breakdown.avgTokensPerTurn {
                                    HStack(spacing: 3) {
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                            .font(.system(size: 9))
                                            .foregroundColor(MU.textTertiary)
                                        Text("~\(Fmt.tokenCountString(avg))/turn")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundColor(MU.textSecondary)
                                    }
                                    .help("Average tokens per turn across recent sessions")
                                }
                                if breakdown.longChatCount > 0 {
                                    HStack(spacing: 3) {
                                        Image(systemName: "exclamationmark.bubble")
                                            .font(.system(size: 9))
                                            .foregroundColor(MU.warn)
                                        Text("\(breakdown.longChatCount) long chat\(breakdown.longChatCount > 1 ? "s" : "")")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundColor(MU.warn)
                                    }
                                    .help("Sessions with 10+ turns or 100k+ tokens")
                                }
                            }
                            .padding(.top, 2)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Popover sizing

private struct HeaderHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 44
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Service status

/// Compact health row. It stays at the top so a service issue is visible before
/// the usage cards, even when the matching provider's usage is hidden.
private struct StatusStrip: View {
    let statuses: [Provider: Loaded<ServiceStatus>]
    let providers: [Provider]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Service status")
            Card(padding: 10) {
                if rows.isEmpty {
                    InfoState(message: "Not checked yet")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            if index > 0 {
                                Divider().overlay(MU.hairline)
                            }
                            HStack(spacing: 8) {
                                // The provider's mark, tinted by service
                                // severity so identity and health share one
                                // glyph instead of a plain colour dot.
                                ProviderMark(provider: row.provider, tint: severityColor(row.severity))
                                    .frame(width: 13, height: 13)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.provider.displayName)
                                        .font(.muBody)
                                        .foregroundColor(providerColor(row.provider))
                                    Text(row.description)
                                        .font(.muCaption)
                                        .foregroundColor(MU.textSecondary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                                Spacer(minLength: 4)
                                VStack(alignment: .trailing, spacing: 3) {
                                    if let url = row.provider.statusPageURL {
                                        Button {
                                            openStatusPage(url)
                                        } label: {
                                            StatusBadge(severity: row.severity)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Open \(row.provider.displayName) status page")
                                    } else {
                                        StatusBadge(severity: row.severity)
                                    }
                                    Text(Fmt.timeSince(row.checkedAt, now: now))
                                        .font(.muCaption)
                                        .foregroundColor(MU.textTertiary)
                                }
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
            }
        }
    }

    private struct Row: Identifiable {
        let id: String
        let provider: Provider
        let severity: Severity
        let description: String
        let checkedAt: Date
    }

    /// Only providers that actually reported are listed. A provider with no
    /// status source is simply absent rather than shown as "unknown", which
    /// would imply we tried and failed.
    private var rows: [Row] {
        providers.compactMap { provider in
            guard let status = statuses[provider]?.value else { return nil }
            return Row(
                id: provider.rawValue,
                provider: provider,
                severity: status.severity,
                description: status.description,
                checkedAt: status.checkedAt
            )
        }
    }
}

// MARK: - Update banner

/// One-line notice that a newer release exists. The primary action downloads,
/// verifies, and installs the update in place and relaunches; the caption
/// links to the release page for anyone who wants the notes first. Demo
/// builds never see it.
private struct UpdateBanner: View {
    let release: UpdateChecker.Release
    let installState: UpdateChecker.InstallState
    let onInstall: () -> Void
    let onDismiss: () -> Void

    @State private var hoveringDismiss = false

    var body: some View {
        Card(padding: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(MU.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update available — v\(release.version)")
                        .font(.muBody)
                        .foregroundColor(MU.text)
                    caption
                        .font(.muCaption)
                        .foregroundColor(MU.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                actionButton
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(hoveringDismiss ? MU.text : MU.textTertiary)
                        .frame(width: 18, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(hoveringDismiss ? MU.well : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .help("Dismiss this update notice")
                .onHover { hoveringDismiss = $0 }
            }
        }
    }

    @ViewBuilder
    private var caption: some View {
        if installState == .failed {
            Text("Install failed — try again or update manually.")
        } else if let url = release.url {
            Button {
                openStatusPage(url)
            } label: {
                Text("See what's new")
                    .underline()
            }
            .buttonStyle(.plain)
            .help("Open the v\(release.version) release page")
        } else {
            Text("Downloads and installs in place, then relaunches.")
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch installState {
        case .downloading:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
                .frame(width: 40)
                .help("Downloading the update")
        case .installing:
            Text("Relaunching…")
                .font(.muCaption)
                .foregroundColor(MU.textSecondary)
                .frame(width: 40)
        default:
            Button(action: onInstall) {
                Text(installState == .failed ? "Retry" : "Install")
            }
            .controlSize(.small)
            .help("Download, verify, and install v\(release.version), then relaunch")
        }
    }
}

// MARK: - Controls

/// Borderless icon button with a hover affordance.
///
/// Stock `Button` in a popover draws a bordered capsule that fights the card
/// layout; this keeps the chrome quiet until pointed at.
private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(hovering ? MU.text : MU.textSecondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hovering ? MU.well : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private extension View {
    /// `scrollIndicators(_:)` is macOS 13+, but keeping the call site guarded
    /// documents the intent and avoids a hard floor if the target ever drops.
    @ViewBuilder
    func scrollIndicatorsHiddenIfAvailable() -> some View {
        if #available(macOS 13.0, *) {
            self.scrollIndicators(.never)
        } else {
            self
        }
    }
}

// MARK: - Opening status pages in a browser tab

/// Opens the status page in the default browser, preferring a new tab.
///
/// A plain `NSWorkspace.open` hands the URL to LaunchServices, and Chromium
/// browsers such as Helium open such links in a new window whenever the
/// browser was not already running. Asking the running browser directly to
/// `open location` opens a new tab in its frontmost window instead. Non-
/// scriptable browsers make the AppleScript call throw, and the URL then
/// falls back to `NSWorkspace.open`.
private func openStatusPage(_ url: URL) {
    guard let browserName = defaultBrowserName() else {
        NSWorkspace.shared.open(url)
        return
    }
    let source = """
    tell application "\(appleScriptEscape(browserName))"
        open location "\(appleScriptEscape(url.absoluteString))"
    end tell
    """
    var error: NSDictionary?
    let script = NSAppleScript(source: source)
    if script?.executeAndReturnError(&error) == nil {
        NSWorkspace.shared.open(url)
    }
}

private func defaultBrowserName() -> String? {
    guard let probe = URL(string: "https://status.example/"),
          let appURL = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return nil }
    let bundleName = Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleName") as? String
    return bundleName ?? appURL.deletingPathExtension().lastPathComponent
}

private func appleScriptEscape(_ string: String) -> String {
    string
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}
