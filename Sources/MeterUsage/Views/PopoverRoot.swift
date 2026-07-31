import SwiftUI

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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(MU.hairline)
            content
        }
        .frame(width: MU.popoverWidth, height: MU.popoverHeight)
        .background(MU.canvas)
        .preferredColorScheme(preferences.theme.colorScheme)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(showingSettings ? "Settings" : AppInfo.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(MU.text)

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
        }
        .scrollIndicatorsHiddenIfAvailable()
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 14) {

            SectionHeader("Quotas")
            if coordinator.visibleProviders.isEmpty {
                Card {
                    InfoState(
                        message: "No providers shown",
                        hint: "Turn one on in Settings."
                    )
                }
            } else {
                ForEach(coordinator.visibleProviders, id: \.self) { provider in
                    QuotaSection(
                        provider: provider,
                        state: coordinator.quotas[provider] ?? .idle,
                        plan: coordinator.plans[provider] ?? .idle,
                        now: coordinator.clock
                    )
                }
            }

            ActivitySection(
                activities: coordinator.activities,
                providers: coordinator.visibleProviders,
                now: coordinator.clock
            )

            StatusStrip(
                statuses: coordinator.statuses,
                providers: coordinator.visibleProviders,
                now: coordinator.clock
            )
        }
    }
}

// MARK: - Service status

/// Compact health row. Kept at the bottom because it is the least-consulted
/// information here — it matters only when something is wrong.
private struct StatusStrip: View {
    let statuses: [Provider: Loaded<ServiceStatus>]
    let providers: [Provider]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Service status")
            Card {
                if rows.isEmpty {
                    InfoState(message: "Not checked yet")
                } else {
                    VStack(spacing: 8) {
                        ForEach(rows) { row in
                            HStack(spacing: 8) {
                                StatusDot(color: severityColor(row.severity))
                                Text(row.description)
                                    .font(.muBody)
                                    .foregroundColor(MU.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 4)
                                Text(Fmt.timeSince(row.checkedAt, now: now))
                                    .font(.muCaption)
                                    .foregroundColor(MU.textTertiary)
                            }
                        }
                    }
                }
            }
        }
    }

    private struct Row: Identifiable {
        let id: String
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
                severity: status.severity,
                description: status.description,
                checkedAt: status.checkedAt
            )
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
