import SwiftUI

/// Settings pane, shown in place of the dashboard inside the same popover.
///
/// A separate window would be a second thing to manage for four toggles, and a
/// menu-bar app that opens windows loses its "glance and dismiss" quality.
///
/// Every control binds `@AppStorage` directly. `Preferences` observes the same
/// keys and republishes, so changing the interval here restarts the coordinator's
/// timer with no explicit plumbing between the two.
struct SettingsView: View {

    @ObservedObject var coordinator: AppCoordinator

    @AppStorage(PrefKey.refreshInterval) private var refreshInterval: Double = Preferences.defaultRefreshInterval
    @AppStorage(PrefKey.showClaude) private var showClaude: Bool = false
    @AppStorage(PrefKey.showCodex) private var showCodex: Bool = true
    @AppStorage(PrefKey.showAntigravity) private var showAntigravity: Bool = false
    @AppStorage(PrefKey.showGrok) private var showGrok: Bool = false
    @AppStorage(PrefKey.showOpenCodeGo) private var showOpenCodeGo: Bool = true
    @AppStorage(PrefKey.showOpenRouter) private var showOpenRouter: Bool = true
    @AppStorage(PrefKey.menuBarClaude) private var menuBarClaude: Bool = true
    @AppStorage(PrefKey.menuBarCodex) private var menuBarCodex: Bool = true
    @AppStorage(PrefKey.menuBarAntigravity) private var menuBarAntigravity: Bool = true
    @AppStorage(PrefKey.menuBarGrok) private var menuBarGrok: Bool = true
    @AppStorage(PrefKey.menuBarOpenCodeGo) private var menuBarOpenCodeGo: Bool = true
    @AppStorage(PrefKey.menuBarOpenRouter) private var menuBarOpenRouter: Bool = true
    @AppStorage(PrefKey.theme) private var theme: String = AppTheme.system.rawValue
    @AppStorage(PrefKey.launchAtLogin) private var launchAtLogin: Bool = false
    @AppStorage(PrefKey.showHeatmap) private var showHeatmap: Bool = true
    @AppStorage(PrefKey.showClaudeHeatmap) private var showClaudeHeatmap: Bool = true
    @AppStorage(PrefKey.showCodexHeatmap) private var showCodexHeatmap: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            Group {
                SectionHeader("Refresh")
                Card {
                    Picker("", selection: $refreshInterval) {
                        ForEach(Preferences.intervalChoices, id: \.self) { seconds in
                            Text(Self.intervalLabel(seconds)).tag(seconds)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)

                    Text("Also refreshes when the Mac wakes from sleep.")
                        .font(.muCaption)
                        .foregroundColor(MU.textTertiary)
                }
            }

            Group {
                SectionHeader("Providers")
                Card {
                    ProviderToggle(
                        provider: .codex,
                        subtitle: "Primary quota and usage",
                        isOn: $showCodex
                    )
                    Divider().overlay(MU.hairline)
                    ProviderToggle(
                        provider: .antigravity,
                        subtitle: "Local sessions and messages",
                        isOn: $showAntigravity
                    )
                    Divider().overlay(MU.hairline)
                    ProviderToggle(
                        provider: .grok,
                        subtitle: "Local session history",
                        isOn: $showGrok
                    )
                    Divider().overlay(MU.hairline)
                    ProviderToggle(
                        provider: .openCodeGo,
                        subtitle: "OpenCode Go token usage",
                        isOn: $showOpenCodeGo
                    )
                    Divider().overlay(MU.hairline)
                    ProviderToggle(
                        provider: .openRouter,
                        subtitle: "API usage and spending limit",
                        isOn: $showOpenRouter
                    )
                    Divider().overlay(MU.hairline)
                    ProviderToggle(
                        provider: .claude,
                        subtitle: "Optional Claude Code activity",
                        isOn: $showClaude
                    )
                    Divider().overlay(MU.hairline)
                    Text("Enabled providers appear in the popover; the Menu bar section picks which also show in the tray.")
                        .font(.muCaption)
                        .foregroundColor(MU.textTertiary)
                }
            }

            Group {
                SectionHeader("Menu bar")
                Card {
                    Text("Pick which providers show as clusters in the menu bar.")
                        .font(.muCaption)
                        .foregroundColor(MU.textTertiary)
                    Divider().overlay(MU.hairline)
                    MenuBarToggle(provider: .codex, isOn: $menuBarCodex)
                    Divider().overlay(MU.hairline)
                    MenuBarToggle(provider: .grok, isOn: $menuBarGrok)
                    Divider().overlay(MU.hairline)
                    MenuBarToggle(provider: .openCodeGo, isOn: $menuBarOpenCodeGo)
                    Divider().overlay(MU.hairline)
                    MenuBarToggle(provider: .antigravity, isOn: $menuBarAntigravity)
                    Divider().overlay(MU.hairline)
                    MenuBarToggle(provider: .claude, isOn: $menuBarClaude)
                }
            }

            Group {
                SectionHeader("Appearance")
                Card {
                    Picker("", selection: $theme) {
                        ForEach(AppTheme.allCases) { option in
                            Text(option.displayName).tag(option.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    Divider().overlay(MU.hairline)
                    SettingToggle(
                        title: "Show heatmap",
                        subtitle: "Master switch for the weekly activity grids.",
                        isOn: $showHeatmap
                    )
                    Divider().overlay(MU.hairline)
                    SettingToggle(
                        title: "Codex heatmap",
                        subtitle: "Weekly sessions grid inside the Codex card.",
                        isOn: $showCodexHeatmap
                    )
                    .disabled(!showHeatmap)
                    Divider().overlay(MU.hairline)
                    SettingToggle(
                        title: "Claude heatmap",
                        subtitle: "Weekly token grid in the Local activity card.",
                        isOn: $showClaudeHeatmap
                    )
                    .disabled(!showHeatmap)
                }
            }

            Group {
                SectionHeader("Startup")
                Card {
                    SettingToggle(
                        title: "Launch at login",
                        subtitle: "Requires the app to be in /Applications.",
                        isOn: Binding(
                            get: { launchAtLogin },
                            // The system can refuse registration, so the stored
                            // value is reconciled with what actually happened
                            // rather than with what was asked for.
                            set: { launchAtLogin = LoginItem.set($0) }
                        )
                    )
                }
            }

            Group {
                SectionHeader("Maintenance")
                Card {
                    CacheRow(coordinator: coordinator)
                }
            }

            Spacer(minLength: 0)

            HStack {
                Text("\(AppInfo.name) \(AppInfo.version)")
                Spacer()
                Text("No telemetry · all data stays local")
            }
            .font(.muCaption)
            .foregroundColor(MU.textTertiary)
        }
        .onAppear {
            // Reflect reality: the user can remove the login item in System
            // Settings without the app ever hearing about it.
            launchAtLogin = LoginItem.isEnabled
        }
    }

    private static func intervalLabel(_ seconds: Double) -> String {
        seconds < 60 ? "\(Int(seconds))s" : "\(Int(seconds / 60))m"
    }
}

/// Clears this app's own scan cache.
///
/// WORDING IS THE FEATURE HERE. "Clear cached data" on a usage meter invites
/// exactly one catastrophic misreading — that it erases usage history at the
/// provider, or the transcripts themselves. It does neither: it deletes files
/// this app wrote, and the next scan rebuilds them from transcripts that are
/// never modified. The label says what is cleared and the subtitle says what
/// happens next, including that it isn't instant — the cold scan takes several
/// seconds on a large transcript corpus, and an unexplained multi-second
/// spinner reads as a hang.
private struct CacheRow: View {
    @ObservedObject var coordinator: AppCoordinator

    private var busy: Bool { coordinator.isClearingCache }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Clear local cache")
                    .font(.muBody)
                    .foregroundColor(MU.text)
                Text("Re-scans your transcripts from scratch — takes a few seconds. Your transcripts and your usage at the provider are untouched.")
                    .font(.muCaption)
                    .foregroundColor(MU.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Button(action: { coordinator.clearLocalCache() }) {
                if busy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 34)
                } else {
                    Text("Clear")
                }
            }
            .controlSize(.small)
            .disabled(busy)
            .help("Deletes this app's scan cache and re-reads your local transcripts.")
        }
    }
}

private struct SettingToggle: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.muBody)
                    .foregroundColor(MU.text)
                if let subtitle {
                    Text(subtitle)
                        .font(.muCaption)
                        .foregroundColor(MU.textTertiary)
                }
            }
            Spacer(minLength: 6)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

private struct ProviderToggle: View {
    let provider: Provider
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            StatusDot(color: providerColor(provider), diameter: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.displayName)
                    .font(.muBody)
                    .foregroundColor(MU.text)
                Text(subtitle)
                    .font(.muCaption)
                    .foregroundColor(MU.textTertiary)
            }
            Spacer(minLength: 6)
            Toggle("Show \(provider.displayName)", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .accessibilityElement(children: .contain)
    }
}

/// Whether one provider appears as a cluster in the menu bar.
private struct MenuBarToggle: View {
    let provider: Provider
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ProviderMark(provider: provider, tint: providerColor(provider))
                .frame(width: 13, height: 13)
            Text(provider.displayName)
                .font(.muBody)
                .foregroundColor(MU.text)
            Spacer(minLength: 6)
            Toggle("Show \(provider.displayName) in menu bar", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .accessibilityElement(children: .contain)
    }
}

