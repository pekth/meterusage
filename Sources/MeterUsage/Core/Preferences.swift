import SwiftUI
import Combine
import ServiceManagement

// MARK: - Preferences
//
// Settings live in `UserDefaults` and are read two ways:
//
//   * `SettingsView` binds them with `@AppStorage`, so toggling a control writes
//     through immediately with no plumbing.
//   * `AppCoordinator` needs to *react* to the same values (a changed refresh
//     interval must restart the timer), and `@AppStorage` gives no notification
//     outside a View's body. `Preferences` therefore observes
//     `UserDefaults.didChangeNotification` and republishes.
//
// Both paths address the same keys, so there is exactly one stored value per
// setting and no synchronisation problem.

enum PrefKey {
    static let refreshInterval = "refreshIntervalSeconds"
    static let showClaude = "showProviderClaude"
    static let showCodex = "showProviderCodex"
    static let showAntigravity = "showProviderAntigravity"
    static let showGrok = "showProviderGrok"
    static let showOpenCodeGo = "showProviderOpenCodeGo"
    static let showOpenRouter = "showProviderOpenRouter"
    static let menuBarClaude = "menuBarProviderClaude"
    static let menuBarCodex = "menuBarProviderCodex"
    static let menuBarAntigravity = "menuBarProviderAntigravity"
    static let menuBarGrok = "menuBarProviderGrok"
    static let menuBarOpenCodeGo = "menuBarProviderOpenCodeGo"
    static let menuBarOpenRouter = "menuBarProviderOpenRouter"
    static let theme = "appearanceTheme"
    static let launchAtLogin = "launchAtLogin"
    static let showHeatmap = "showHeatmap"
    static let showClaudeHeatmap = "showClaudeHeatmap"
    static let showCodexHeatmap = "showCodexHeatmap"
    static let quotaAlerts = "quotaAlertsEnabled"
}

/// Popover appearance. The menu-bar label always follows the system menu bar.
enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

@MainActor
final class Preferences: ObservableObject {

    /// Polling faster than this is pure waste: providers report coarse windows
    /// and every poll spawns a subprocess. Enforced here rather than trusted to
    /// the UI, so a hand-edited defaults value can't create a hot loop.
    static let minimumRefreshInterval: TimeInterval = 30
    static let defaultRefreshInterval: TimeInterval = 60

    static let intervalChoices: [TimeInterval] = [30, 60, 120, 300, 900]

    @Published private(set) var refreshInterval: TimeInterval = Preferences.defaultRefreshInterval
    @Published private(set) var enabledProviders: Set<Provider> = Set(Provider.allCases)
    /// Which enabled providers also appear as clusters in the menu bar.
    @Published private(set) var menuBarProviders: Set<Provider> = Set(Provider.allCases)
    @Published private(set) var theme: AppTheme = .system
    @Published private(set) var showHeatmap: Bool = true
    @Published private(set) var showClaudeHeatmap: Bool = true
    @Published private(set) var showCodexHeatmap: Bool = true
    /// Opt-in quota threshold notifications. Off by default so the app never
    /// prompts for notification access until the user asks for the feature.
    @Published private(set) var quotaAlertsEnabled: Bool = false

    private let defaults: UserDefaults
    private var observer: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `register(defaults:)` supplies first-run values only. It never
        // replaces values the user has already saved in this suite.
        defaults.register(defaults: [
            PrefKey.refreshInterval: Preferences.defaultRefreshInterval,
            // Codex is the primary provider. OpenRouter and OpenCode Go are
            // enabled when configured; Claude, Antigravity, and Grok remain
            // explicit opt-ins until their integrations are enabled for
            // normal use.
            PrefKey.showClaude: false,
            PrefKey.showCodex: true,
            PrefKey.showAntigravity: false,
            PrefKey.showGrok: false,
            PrefKey.showOpenCodeGo: true,
            PrefKey.showOpenRouter: true,
            // Every provider shows in the menu bar until the user trims the set
            // down to the ones they glance at.
            PrefKey.menuBarClaude: true,
            PrefKey.menuBarCodex: true,
            PrefKey.menuBarAntigravity: true,
            PrefKey.menuBarGrok: true,
            PrefKey.menuBarOpenCodeGo: true,
            PrefKey.menuBarOpenRouter: true,
            PrefKey.theme: AppTheme.system.rawValue,
            PrefKey.launchAtLogin: false,
            PrefKey.showHeatmap: true,
            PrefKey.showClaudeHeatmap: true,
            PrefKey.showCodexHeatmap: true,
            PrefKey.quotaAlerts: false
        ])
        reload()
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    // No `deinit` teardown: a single `Preferences` is created by the app
    // delegate and lives for the process lifetime, and touching main-actor state
    // from a nonisolated `deinit` is not expressible cleanly here.

    private func reload() {
        let stored = defaults.double(forKey: PrefKey.refreshInterval)
        let interval = stored > 0 ? stored : Preferences.defaultRefreshInterval
        let clamped = max(interval, Preferences.minimumRefreshInterval)
        if clamped != refreshInterval { refreshInterval = clamped }

        var providers = Set<Provider>()
        if defaults.bool(forKey: PrefKey.showCodex) { providers.insert(.codex) }
        if defaults.bool(forKey: PrefKey.showAntigravity) { providers.insert(.antigravity) }
        if defaults.bool(forKey: PrefKey.showGrok) { providers.insert(.grok) }
        if defaults.bool(forKey: PrefKey.showOpenCodeGo) { providers.insert(.openCodeGo) }
        if defaults.bool(forKey: PrefKey.showOpenRouter) { providers.insert(.openRouter) }
        if defaults.bool(forKey: PrefKey.showClaude) { providers.insert(.claude) }
        if providers != enabledProviders { enabledProviders = providers }

        var menuBar = Set<Provider>()
        if defaults.bool(forKey: PrefKey.menuBarCodex) { menuBar.insert(.codex) }
        if defaults.bool(forKey: PrefKey.menuBarAntigravity) { menuBar.insert(.antigravity) }
        if defaults.bool(forKey: PrefKey.menuBarGrok) { menuBar.insert(.grok) }
        if defaults.bool(forKey: PrefKey.menuBarOpenCodeGo) { menuBar.insert(.openCodeGo) }
        if defaults.bool(forKey: PrefKey.menuBarOpenRouter) { menuBar.insert(.openRouter) }
        if defaults.bool(forKey: PrefKey.menuBarClaude) { menuBar.insert(.claude) }
        if menuBar != menuBarProviders { menuBarProviders = menuBar }

        let newTheme = AppTheme(rawValue: defaults.string(forKey: PrefKey.theme) ?? "") ?? .system
        if newTheme != theme { theme = newTheme }

        let heatmap = defaults.bool(forKey: PrefKey.showHeatmap)
        if heatmap != showHeatmap { showHeatmap = heatmap }

        let claudeHeatmap = defaults.bool(forKey: PrefKey.showClaudeHeatmap)
        if claudeHeatmap != showClaudeHeatmap { showClaudeHeatmap = claudeHeatmap }

        let codexHeatmap = defaults.bool(forKey: PrefKey.showCodexHeatmap)
        if codexHeatmap != showCodexHeatmap { showCodexHeatmap = codexHeatmap }

        let alerts = defaults.bool(forKey: PrefKey.quotaAlerts)
        if alerts != quotaAlertsEnabled { quotaAlertsEnabled = alerts }
    }

    func isEnabled(_ provider: Provider) -> Bool { enabledProviders.contains(provider) }

    func showsInMenuBar(_ provider: Provider) -> Bool { menuBarProviders.contains(provider) }
}

// MARK: - Launch at login

/// Thin wrapper over `SMAppService`.
///
/// Kept separate from `Preferences` because registration can fail (the user can
/// deny it in System Settings) and the stored toggle must then be corrected to
/// match reality rather than lying about the app's state.
enum LoginItem {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns the state actually achieved, which may differ from `enabled`.
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Registration is unavailable when running from a bare binary rather
            // than an installed .app bundle. Nothing to surface beyond the
            // toggle snapping back.
            return isEnabled
        }
        return isEnabled
    }
}
