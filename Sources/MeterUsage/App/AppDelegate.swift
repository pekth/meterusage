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
    /// `main.swift`'s top-level code is not main-actor isolated, so the delegate
    /// must be constructible from there. Construction touches nothing isolated;
    /// every stored property is populated later in
    /// `applicationDidFinishLaunching`, which AppKit always calls on the main
    /// thread.
    override nonisolated init() { super.init() }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        let preferences = Preferences()
        let coordinator = AppCoordinator(
            preferences: preferences,
            quotaSources: Composition.quotaSources(),
            activitySources: Composition.activitySources(),
            statusSources: Composition.statusSources(),
            planSources: Composition.planSources(),
            // Same factory, so "clear cache" can rebuild the activity sources
            // and get a genuinely cold scan rather than a re-warmed one.
            activitySourceFactory: Composition.activitySources
        )
        self.preferences = preferences
        self.coordinator = coordinator

        installStatusItem(coordinator: coordinator)
        installPopover(coordinator: coordinator, preferences: preferences)
        coordinator.start()
    }

    // MARK: Status item

    private func installStatusItem(coordinator: AppCoordinator) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }

        let host = NSHostingView(rootView: MenuBarLabel(coordinator: coordinator))
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
        popover.contentViewController = NSHostingController(
            rootView: PopoverRoot(coordinator: coordinator, preferences: preferences)
        )
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

    static func quotaSources() -> [QuotaSource] {
        [
            // Live Codex limits, read over the CLI's local RPC.
            CodexQuotaSource(),
            // Claude publishes no local quota endpoint. This reads a file only
            // if one happens to exist, and reports `.noData` otherwise — the
            // normal case, and deliberately not an error.
            OptionalQuotaFileSource()
        ]
    }

    static func activitySources() -> [LocalActivitySource] {
        [ClaudeLocalSource()]
    }

    static func statusSources() -> [StatusSource] {
        [StatusPageSource(provider: .claude)]
    }

    /// Codex reports its plan inline with its quota, so it needs no source
    /// here; Claude's tier lives in local account metadata and needs its own.
    static func planSources() -> [PlanSource] {
        [ClaudePlanSource()]
    }
}

