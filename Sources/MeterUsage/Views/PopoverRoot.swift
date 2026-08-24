import SwiftUI
import AppKit

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

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 14) {

            if let release = coordinator.updateChecker?.visibleRelease {
                UpdateBanner(
                    release: release,
                    onOpen: {
                        if let url = release.url {
                            openStatusPage(url)
                        }
                    },
                    onDismiss: { coordinator.updateChecker?.dismiss() }
                )
            }

            StatusStrip(
                statuses: coordinator.statuses,
                providers: coordinator.statusProviders,
                now: coordinator.clock
            )

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
                        heatmapIntensity: provider == .codex ? .sessions : .tokens
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

/// One-line notice that a newer release exists. Accent-tinted but calm: it
/// sits above the status strip, links to the release page, and disappears for
/// good once the user dismisses that version. Demo builds never see it.
private struct UpdateBanner: View {
    let release: UpdateChecker.Release
    let onOpen: () -> Void
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
                    Text("See what's new on the releases page.")
                        .font(.muCaption)
                        .foregroundColor(MU.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Button(action: onOpen) {
                    Text("View")
                }
                .controlSize(.small)
                .help("Open the v\(release.version) release page")
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
