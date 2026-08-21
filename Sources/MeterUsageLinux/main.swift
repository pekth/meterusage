// meterusage-linux: GTK3 and Ayatana system-tray shell for Linux.
//
// Build requirements: libgtk-3-dev and libayatana-appindicator3-dev
// (Debian and Ubuntu package names).

#if os(Linux)
import Foundation
import MeterUsageCore
import CGtk3
import CAyatanaAppIndicator3

@main
struct MeterUsageLinuxApp {
    private static var coordinator: AppCoordinator!
    private static var indicator: UnsafeMutablePointer<AppIndicator>!
    private static var menu: UnsafeMutablePointer<GtkWidget>!
    private static var isRunning = true
    private static var lastRenderedRefreshing = false
    private static var lastRenderedRefreshAt: Date?

    @MainActor
    static func main() async {
        gtk_init(nil, nil)

        let preferences = Preferences()
        coordinator = AppCoordinator(
            preferences: preferences,
            isDemoMode: DemoMode.isEnabled(),
            quotaSources: quotaSources(),
            activitySources: activitySources(),
            usageSources: usageSources(),
            statusSources: statusSources(),
            planSources: planSources()
        )

        indicator = app_indicator_new(
            "meterusage",
            "utilities-system-monitor",
            APP_INDICATOR_CATEGORY_APPLICATION_STATUS
        )
        app_indicator_set_status(indicator, APP_INDICATOR_STATUS_ACTIVE)
        app_indicator_set_title(indicator, "meterusage")

        menu = gtk_menu_new()
        app_indicator_set_menu(
            indicator,
            UnsafeMutablePointer<GtkMenu>(OpaquePointer(menu))
        )
        rebuildMenu()
        updateLabel()
        coordinator.start()

        // gtk_main() would hold the process main thread and prevent MainActor
        // tasks from running. Pump pending GTK events, then suspend so Swift
        // concurrency can run provider refresh work on the same actor.
        while isRunning {
            while gtk_events_pending() != 0 {
                _ = gtk_main_iteration_do(0)
            }
            updateLabel()
            if coordinator.isRefreshing != lastRenderedRefreshing
                || coordinator.lastRefreshedAt != lastRenderedRefreshAt {
                rebuildMenu()
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    // MARK: Tray rendering

    @MainActor
    private static func updateLabel() {
        guard let most = coordinator.mostConstrained else {
            app_indicator_set_label(indicator, "meterusage", "")
            return
        }
        let text = "\(most.provider.displayName) \(Fmt.percent(most.window.usedPercent))"
        app_indicator_set_label(indicator, text, "")
    }

    // MARK: Menu

    @MainActor
    private static func rebuildMenu() {
        meterusage_gtk_menu_clear(menu)

        var stateRows = 0
        if coordinator.isRefreshing {
            appendInfoItem(coordinator.quotas.isEmpty ? "Loading usage…" : "Refreshing…")
            stateRows += 1
        }

        for provider in coordinator.visibleQuotaProviders {
            switch coordinator.quotas[provider] {
            case .value(let quota):
                stateRows += appendQuotaItems(quota)
            case .missing(let reason):
                // SourceUnavailable owns the sanitized text contract. Never
                // render a raw provider error or request body in the tray.
                appendInfoItem("\(provider.displayName): \(reason.userFacingMessage)")
                stateRows += 1
            case .idle, .none:
                appendInfoItem("\(provider.displayName): Loading…")
                stateRows += 1
            }
        }

        if stateRows == 0 {
            appendInfoItem("No providers enabled")
        }

        appendSeparator()

        let refresh = gtk_menu_item_new_with_label("Refresh")!
        gtk_widget_set_sensitive(refresh, coordinator.isRefreshing ? 0 : 1)
        _ = meterusage_gtk_connect_activate(refresh, refreshCallback, nil)
        meterusage_gtk_menu_append(menu, refresh)

        let providersHeading = gtk_menu_item_new_with_label("Providers")!
        gtk_widget_set_sensitive(providersHeading, 0)
        meterusage_gtk_menu_append(menu, providersHeading)

        for (index, provider) in Provider.allCases.enumerated() {
            let item = gtk_check_menu_item_new_with_label(provider.displayName)!
            gtk_check_menu_item_set_active(
                UnsafeMutablePointer<GtkCheckMenuItem>(OpaquePointer(item)),
                coordinator.preferences.isEnabled(provider) ? 1 : 0
            )
            let providerData = UnsafeMutableRawPointer(bitPattern: index + 1)
            _ = meterusage_gtk_connect_activate(item, providerToggleCallback, providerData)
            meterusage_gtk_menu_append(menu, item)
        }

        appendSeparator()

        let quit = gtk_menu_item_new_with_label("Quit")!
        _ = meterusage_gtk_connect_activate(quit, quitCallback, nil)
        meterusage_gtk_menu_append(menu, quit)

        gtk_widget_show_all(menu)
        lastRenderedRefreshing = coordinator.isRefreshing
        lastRenderedRefreshAt = coordinator.lastRefreshedAt
    }

    @MainActor
    private static func appendQuotaItems(_ quota: ProviderQuota) -> Int {
        var count = 0

        for window in quota.windows {
            appendInfoItem(quotaLine(provider: quota.provider, group: nil, window: window))
            count += 1
        }
        for group in quota.groups {
            for window in group.windows {
                appendInfoItem(quotaLine(provider: quota.provider, group: group.title, window: window))
                count += 1
            }
        }
        if let credits = quota.credits {
            let detail: String
            if credits.unlimited {
                detail = "Unlimited credits"
            } else {
                switch credits.unit {
                case .credits:
                    detail = "\(Fmt.credits(credits.balance)) credits"
                case .dollars:
                    detail = "\(Fmt.usd(credits.balance)) credit"
                }
            }
            appendInfoItem("\(quota.provider.displayName): \(detail)")
            count += 1
        }
        if count == 0 {
            appendInfoItem("\(quota.provider.displayName): No quota data")
            count = 1
        }
        return count
    }

    private static func quotaLine(
        provider: Provider,
        group: String?,
        window: QuotaWindow
    ) -> String {
        let scope = group.map { "\($0) \(window.label)" } ?? window.label
        var line = "\(provider.displayName) · \(scope): \(Fmt.percent(window.usedPercent)) used"
        if let reset = window.resetsAt, let remaining = Fmt.timeUntil(reset) {
            line += " · resets in \(remaining)"
        }
        return line
    }

    @MainActor
    private static func appendInfoItem(_ label: String) {
        let item = gtk_menu_item_new_with_label(label)!
        gtk_widget_set_sensitive(item, 0)
        meterusage_gtk_menu_append(menu, item)
    }

    @MainActor
    private static func appendSeparator() {
        meterusage_gtk_menu_append(menu, gtk_separator_menu_item_new())
    }

    private static let refreshCallback: MeterUsageGtkActivateCallback = { _, _ in
        Task { @MainActor in
            coordinator.refresh()
            rebuildMenu()
        }
    }

    private static let providerToggleCallback: MeterUsageGtkActivateCallback = { _, data in
        guard let data else { return }
        let index = Int(bitPattern: data) - 1
        guard Provider.allCases.indices.contains(index) else { return }
        let provider = Provider.allCases[index]
        Task { @MainActor in
            let preferences = coordinator.preferences
            preferences.setProvider(provider, enabled: !preferences.isEnabled(provider))
            coordinator.preferencesDidChange()
            coordinator.refresh()
            rebuildMenu()
        }
    }

    private static let quitCallback: MeterUsageGtkActivateCallback = { _, _ in
        Task { @MainActor in isRunning = false }
    }

    // MARK: Composition root

    private static func quotaSources() -> [QuotaSource] {
        if DemoMode.isEnabled() {
            return [
                DemoClaudeQuotaSource(), DemoCodexQuotaSource(),
                DemoOpenRouterQuotaSource(), DemoOpenCodeGoQuotaSource(),
                DemoGrokQuotaSource(),
            ]
        }
        return [
            CodexQuotaSource(), OpenRouterQuotaSource(), OpenCodeGoQuotaSource(),
            GrokQuotaSource(), OptionalQuotaFileSource(),
        ]
    }

    private static func activitySources() -> [LocalActivitySource] {
        DemoMode.isEnabled()
            ? [DemoLocalActivitySource(), DemoCodexActivitySource()]
            : [ClaudeLocalSource(), CodexLocalSource()]
    }

    private static func usageSources() -> [UsageSource] {
        DemoMode.isEnabled() ? [DemoAntigravityUsageSource()] : [AntigravityUsageSource()]
    }

    private static func statusSources() -> [StatusSource] {
        if DemoMode.isEnabled() {
            return [.codex, .claude].map { DemoStatusSource(provider: $0) }
        }
        return [
            StatusPageSource(provider: .codex),
            StatusPageSource(provider: .claude),
        ]
    }

    private static func planSources() -> [PlanSource] {
        DemoMode.isEnabled() ? [DemoPlanSource()] : [ClaudePlanSource()]
    }
}
#endif
