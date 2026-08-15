import AppKit
import SwiftUI

/// Owns the status item, the popover, and the object graph.
///
/// Built on `NSStatusItem` + `NSPopover` rather than SwiftUI's `MenuBarExtra`.
/// `MenuBarExtra(.window)` exists on macOS 13, but it does not expose the popover
/// behaviour, the status-item click handling, or the exact content sizing this
/// app needs — in particular right-click for a context menu while left-click
/// toggles the panel.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var preferences: Preferences?
    private var coordinator: AppCoordinator?
    private var resetAvailabilityNotifier: ResetAvailabilityNotifier?
    /// `main.swift`'s top-level code is not main-actor isolated, so the delegate
    /// must be constructible from there. Construction touches nothing isolated;
    /// every stored property is populated later in
    /// `applicationDidFinishLaunching`, which AppKit always calls on the main
    /// thread.
    override nonisolated init() { super.init() }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        let preferences = Preferences()
        let quotaSources = Composition.quotaSources()
        let resetAvailabilityNotifier: ResetAvailabilityNotifier?
        if Composition.isDemoMode {
            resetAvailabilityNotifier = nil
        } else {
            let notifier = ResetAvailabilityNotifier()
            notifier.start()
            resetAvailabilityNotifier = notifier
        }
        let coordinator = AppCoordinator(
            preferences: preferences,
            isDemoMode: Composition.isDemoMode,
            quotaSources: quotaSources,
            resetConsumer: quotaSources.compactMap { $0 as? QuotaResetConsumer }.first,
            onQuotaResetAvailable: { event in
                resetAvailabilityNotifier?.notify(event)
            },
            activitySources: Composition.activitySources(),
            usageSources: Composition.usageSources(),
            statusSources: Composition.statusSources(),
            planSources: Composition.planSources(),
            // Same factory, so "clear cache" can rebuild the activity sources
            // and get a genuinely cold scan rather than a re-warmed one.
            activitySourceFactory: Composition.activitySources
        )
        self.preferences = preferences
        self.coordinator = coordinator
        self.resetAvailabilityNotifier = resetAvailabilityNotifier

        installStatusItem(coordinator: coordinator)
        installPopover(coordinator: coordinator, preferences: preferences)
        coordinator.start()
    }

    // MARK: Status item

    private func installStatusItem(coordinator: AppCoordinator) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }

        let host = NSHostingView(
            rootView: MenuBarLabel(
                coordinator: coordinator,
                onWidthChange: { width in
                    let pixels = ceil(width)
                    if item.length != pixels {
                        item.length = pixels
                    }
                }
            )
        )
        host.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            host.topAnchor.constraint(equalTo: button.topAnchor),
            host.bottomAnchor.constraint(equalTo: button.bottomAnchor)
        ])

        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        statusItem = item
    }

    @objc private func statusItemClicked() {
        // Right-click (and control-click) opens a menu instead of the panel:
        // Quit must be reachable without hunting inside the popover.
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if wantsMenu {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(AppInfo.name)", action: #selector(quit), keyEquivalent: "q")
            .target = self

        // `popUpMenu` is deprecated; assigning then clearing `menu` is the
        // supported way to show a menu for a status item that also has an action.
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func refreshNow() { coordinator?.refresh() }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Popover

    private func installPopover(coordinator: AppCoordinator, preferences: Preferences) {
        let popover = NSPopover()
        popover.contentSize = NSSize(width: MU.popoverWidth, height: MU.popoverHeight)
        // `.transient` dismisses on any outside click, which is what a menu-bar
        // panel is expected to do. `.semitransient` would keep it up over other
        // apps' windows and feel like a stuck window.
        popover.behavior = .transient
        popover.animates = true
        let hostingController = NSHostingController(
            rootView: PopoverRoot(coordinator: coordinator, preferences: preferences)
        )
        // Let SwiftUI's measured content height drive the popover size instead
        // of the fixed `contentSize` above, so the popover shrinks to its
        // content (e.g. after a Codex reset credit is used and its section
        // disappears) rather than reserving empty footer space.
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController
        self.popover = popover
    }

    private func togglePopover() {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Numbers on screen must be current the moment the panel appears,
            // but opening it repeatedly should not re-poll every time.
            coordinator?.refreshIfStale()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Without this the popover can open behind the frontmost app.
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - Composition root
//
// The only place in the app that names concrete sources. `AppCoordinator` and
// every view depend on the protocols alone, so adding, removing or stubbing a
// source is a change to this enum and nothing else.

enum Composition {

    /// Whether this launch shows synthetic data instead of the user's own.
    ///
    /// Read exactly once, here, at first use — not per source and not per
    /// refresh. A flag that could change mid-session would let half the popover
    /// show real numbers and half show invented ones, which is worse than
    /// either. Default is off: a user who never sets `METERUSAGE_DEMO=1`
    /// cannot reach demo mode by any route. See `DemoMode` and docs/DEMO.md.
    static let isDemoMode = DemoMode.isEnabled()

    static func quotaSources() -> [QuotaSource] {
        if isDemoMode {
            return [DemoClaudeQuotaSource(), DemoCodexQuotaSource(), DemoOpenRouterQuotaSource()]
        }
        return [
            // Live Codex limits, read over the CLI's local RPC.
            CodexQuotaSource(),
            // OpenRouter key spend and optional limit, read from its
            // authenticated account endpoint.
            OpenRouterQuotaSource(),
            // Claude publishes no local quota endpoint. This reads a file only
            // if one happens to exist, and reports `.noData` otherwise — the
            // normal case, and deliberately not an error.
            OptionalQuotaFileSource()
        ]
    }

    static func activitySources() -> [LocalActivitySource] {
        isDemoMode ? [DemoLocalActivitySource()] : [ClaudeLocalSource()]
    }

    static func usageSources() -> [UsageSource] {
        if isDemoMode {
            return [
                DemoAntigravityUsageSource(),
                DemoGrokUsageSource(),
                DemoOpenCodeGoUsageSource()
            ]
        }
        return [
            AntigravityUsageSource(),
            GrokUsageSource(),
            OpenCodeGoUsageSource()
        ]
    }

    static func statusSources() -> [StatusSource] {
        if isDemoMode {
            return [.codex, .claude].map { DemoStatusSource(provider: $0) }
        }
        return [
            StatusPageSource(provider: .codex),
            StatusPageSource(provider: .claude)
        ]
    }

    /// Codex reports its plan inline with its quota, so it needs no source
    /// here; Claude's tier lives in local account metadata and needs its own.
    static func planSources() -> [PlanSource] {
        isDemoMode ? [DemoPlanSource()] : [ClaudePlanSource()]
    }
}
