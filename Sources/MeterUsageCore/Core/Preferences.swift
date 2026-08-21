import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(Combine)
import Combine
#endif

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

public enum PrefKey {
    public static let refreshInterval = "refreshIntervalSeconds"
    public static let showClaude = "showProviderClaude"
    public static let showCodex = "showProviderCodex"
    public static let showAntigravity = "showProviderAntigravity"
    public static let showGrok = "showProviderGrok"
    public static let showOpenCodeGo = "showProviderOpenCodeGo"
    public static let showOpenRouter = "showProviderOpenRouter"
    public static let menuBarClaude = "menuBarProviderClaude"
    public static let menuBarCodex = "menuBarProviderCodex"
    public static let menuBarAntigravity = "menuBarProviderAntigravity"
    public static let menuBarGrok = "menuBarProviderGrok"
    public static let menuBarOpenCodeGo = "menuBarProviderOpenCodeGo"
    public static let menuBarOpenRouter = "menuBarProviderOpenRouter"
    public static let theme = "appearanceTheme"
    public static let launchAtLogin = "launchAtLogin"
    public static let showHeatmap = "showHeatmap"
    public static let showClaudeHeatmap = "showClaudeHeatmap"
    public static let showCodexHeatmap = "showCodexHeatmap"
}

/// Popover appearance. The menu-bar label always follows the system menu bar.
public enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    #if canImport(SwiftUI)
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
    #endif
}

@MainActor
public final class Preferences: ObservableObject {

    /// Polling faster than this is pure waste: providers report coarse windows
    /// and every poll spawns a subprocess. Enforced here rather than trusted to
    /// the UI, so a hand-edited defaults value can't create a hot loop.
    public static let minimumRefreshInterval: TimeInterval = 30
    public static let defaultRefreshInterval: TimeInterval = 60

    public static let intervalChoices: [TimeInterval] = [30, 60, 120, 300, 900]

    @Published public private(set) var refreshInterval: TimeInterval = Preferences.defaultRefreshInterval
    @Published public private(set) var enabledProviders: Set<Provider> = Set(Provider.allCases)
    /// Which enabled providers also appear as clusters in the menu bar.
    @Published public private(set) var menuBarProviders: Set<Provider> = Set(Provider.allCases)
    @Published public private(set) var theme: AppTheme = .system
    @Published public private(set) var showHeatmap: Bool = true
    @Published public private(set) var showClaudeHeatmap: Bool = true
    @Published public private(set) var showCodexHeatmap: Bool = true

    private let defaults: UserDefaults
    private var observer: NSObjectProtocol?

    public init(defaults: UserDefaults = .standard) {
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
            PrefKey.showCodexHeatmap: true
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
    }

    public func isEnabled(_ provider: Provider) -> Bool { enabledProviders.contains(provider) }

    public func setRefreshInterval(_ interval: TimeInterval) {
        defaults.set(max(interval, Preferences.minimumRefreshInterval), forKey: PrefKey.refreshInterval)
        reload()
    }

    public func setProvider(_ provider: Provider, enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey(for: provider))
        reload()
    }

    public func showsInMenuBar(_ provider: Provider) -> Bool { menuBarProviders.contains(provider) }

    private static func enabledKey(for provider: Provider) -> String {
        switch provider {
        case .claude: return PrefKey.showClaude
        case .codex: return PrefKey.showCodex
        case .antigravity: return PrefKey.showAntigravity
        case .grok: return PrefKey.showGrok
        case .openCodeGo: return PrefKey.showOpenCodeGo
        case .openRouter: return PrefKey.showOpenRouter
        }
    }
}
