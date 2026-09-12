import SwiftUI
import AppKit

/// The status-item content: one compact `[mark] percent` cluster per enabled
/// provider that has data, so the tray shows every usage at once — the same
/// multi-cluster idea as ClaudeWatch's Claude/Codex pair, extended to whatever
/// providers the user has switched on.
///
/// Each cluster:
///
/// * **Mark** — the provider's own glyph. Codex uses the real logo asset
///   (bundled, tintable as a template image); other providers use a close SF
///   Symbol stand-in. The mark carries that provider's *service status* signal:
///   amber on a degraded service, red on any outage, independent of its quota.
/// * **Percent** — that provider's tightest window, tinted by quota headroom
///   (green → amber → red).
///
/// A provider with no quota but a degraded-or-worse service shows its mark
/// alone so the outage still flags itself. Providers with nothing at all are
/// skipped, and an empty tray renders a lone em dash rather than "0%".
///
/// Constraints that shaped this:
///
/// * It is hosted inside the menu bar, whose appearance is independent of the
///   app's. Every colour is a dynamic token (see `SharedComponents`), so the
///   glyph stays legible on both a light and a dark bar without any observation.
/// * The status item's width is recomputed whenever the view resizes, so adding
///   or hiding a provider reshapes the slot instead of clipping it. Numbers are
///   monospaced-digit so the digits never shuffle sideways between refreshes.
struct MenuBarLabel: View {

    @ObservedObject var coordinator: AppCoordinator
    /// The host reports the label's natural width so the `NSStatusItem` can
    /// match it: too narrow a slot clips "100%" to "10", and a wider fixed
    /// slot pads short figures like "9%" away from the gauge.
    var onWidthChange: (CGFloat) -> Void = { _ in }

    private var ambientDeficitETA: String? {
        clusters.first(where: { $0.etaText != nil })?.etaText
    }

    var body: some View {
        HStack(spacing: 3) {
            if AppInfo.isPreview {
                Text("v2")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Color.purple)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }

            if coordinator.preferences.menuBarCompactEnabled {
                CompactTrayGlyph()
            } else {
                trayClusters
            }

            if let eta = ambientDeficitETA {
                Text(eta)
                    .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                    .foregroundColor(MU.warn)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(MU.warn.opacity(0.16))
                    .cornerRadius(3)
            }
        }
        .padding(.horizontal, 5)
        .frame(height: 22)
        // Natural width regardless of the hosting slot, so the measurement
        // below reports what the label really needs instead of a clipped size.
        .fixedSize(horizontal: true, vertical: false)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { onWidthChange(proxy.size.width) }
                    .onChange(of: proxy.size.width) { newWidth in
                        onWidthChange(newWidth)
                    }
            }
        )
        .animation(.easeOut(duration: 0.3), value: fraction)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(coordinator.preferences.menuBarCompactEnabled ? "MeterUsage" : accessibilityText)
    }

    /// The per-provider `[mark] percent` clusters, unchanged from the original
    /// tray layout.
    private var trayClusters: some View {
        HStack(spacing: 4) {
            if clusters.isEmpty {
                Text("—")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundColor(MU.neutral)
            } else {
                ForEach(clusters, id: \.provider) { cluster in
                    HStack(spacing: 2) {
                        ProviderMark(provider: cluster.provider, tint: cluster.markTint)
                            .frame(width: 13, height: 13)
                        if let percent = cluster.percent {
                            Text(percent)
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundColor(cluster.numberTint)
                        }
                        if let eta = cluster.etaText {
                            Text(eta)
                                .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                                .foregroundColor(cluster.isDeficit ? MU.warn : MU.textSecondary)
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule()
                                        .fill((cluster.isDeficit ? MU.warn : MU.neutral).opacity(0.16))
                                )
                        }
                    }
                    // A remembered reading never passes for a live number.
                    .opacity(cluster.isStale ? 0.55 : 1.0)
                }
            }
        }
    }

    // MARK: Clusters

    private struct Cluster {
        let provider: Provider
        let percent: String?
        let etaText: String?
        let isDeficit: Bool
        let usedFraction: Double
        let markTint: Color
        let numberTint: Color
        let isStale: Bool
    }

    private var clusters: [Cluster] {
        coordinator.menuBarProviders.compactMap { provider in
            let display = coordinator.displayQuota(for: provider)
            let window = display.flatMap { provider.headlineWindow(from: $0.quota.windows) }
            let isStale = display?.isStale ?? false

            let status = coordinator.statuses[provider]?.value
            let markTint: Color
            if let status {
                markTint = Self.statusTint(status.severity)
            } else if let window {
                markTint = headroomColor(window.usedPercent)
            } else {
                markTint = MU.neutral
            }

            if let window {
                let pace = window.pace(now: coordinator.clock)
                let showAmbient = window.shouldShowAmbientETA(now: coordinator.clock)
                let eta = showAmbient ? window.paceETA(now: coordinator.clock, short: true) : nil
                let isDeficit = pace?.status.isDeficit ?? false

                return Cluster(
                    provider: provider,
                    percent: Fmt.percent(window.usedPercent),
                    etaText: eta,
                    isDeficit: isDeficit,
                    usedFraction: window.fraction,
                    markTint: markTint,
                    numberTint: headroomColor(window.usedPercent),
                    isStale: isStale
                )
            }
            // No quota, but a non-operational service is worth a bare mark —
            // degraded and outages in their band tint, unknown in neutral.
            if let status, status.severity != .operational {
                return Cluster(
                    provider: provider,
                    percent: nil,
                    etaText: nil,
                    isDeficit: false,
                    usedFraction: 0,
                    markTint: markTint,
                    numberTint: markTint,
                    isStale: false
                )
            }
            return nil
        }
    }

    /// Animates on the largest headline cluster so a meaningful change (a quota
    /// crossing a colour band) eases rather than snapping.
    private var fraction: Double {
        clusters.map(\.usedFraction).max() ?? 0
    }

    /// Mirrors the popover's `severityColor` mapping, except that a partial
    /// outage reads as an alert (red) rather than a warning, matching the old
    /// tray behaviour where any partial outage escalated the whole label.
    static func statusTint(_ severity: Severity) -> Color {
        switch severity {
        case .operational:   return MU.calm
        case .degraded:      return MU.warn
        case .partialOutage, .majorOutage: return MU.alert
        case .unknown:       return MU.neutral
        }
    }

    private var accessibilityText: String {
        if clusters.isEmpty { return "Usage unavailable" }
        return clusters.map { cluster in
            guard let percent = cluster.percent else {
                return "\(cluster.provider.displayName) unavailable"
            }
            return "\(cluster.provider.displayName) \(percent) used\(cluster.isStale ? ", last known" : "")"
        }
        .joined(separator: ", ")
    }
}

// MARK: - Compact tray glyph

/// The one small mark the tray shows in compact mode, reused by the popover's
/// headline so both entry points look like the same product.
///
/// Uses the app icon as a template NSImage so it automatically tints with the
/// menu bar (dark in light mode, light in dark mode), matching every native
/// macOS accessory.
struct CompactTrayGlyph: View {

    var body: some View {
        Image(systemName: "gauge.with.needle")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.primary)
            .frame(width: 16, height: 16)
    }
}

// MARK: - Provider mark

/// The provider's real glyph, drawn from its bundled asset where one exists or
/// fallen back to an SF Symbol.
///
/// Bundled marks are `codex-logo.png`, `grok-logo.png`, `opencode-logo.png`,
/// and `antigravity-logo.png` under `Resources/`. Each is loaded once as
/// a template image so it tints like any other glyph. When the asset is missing
/// (e.g. a bare debug binary with no bundle), it falls back to the drawn
/// `CodexMark` shape. The other providers have no vector mark in this app, so
/// they use a close SF Symbol stand-in rather than a guessed logo.
struct ProviderMark: View {
    let provider: Provider
    let tint: Color

    var body: some View {
        Group {
            switch provider {
            case .codex, .grok, .openCodeGo, .antigravity:
                bundledMark(named: Self.resourceName(for: provider))
            case .claude:
                ClaudeMascotShape()
                    .fill(tint, style: FillStyle(eoFill: true))
            case .openRouter, .cursor, .copilot, .gemini:
                Image(systemName: Self.symbol(for: provider))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(tint)
            }
        }
    }

    /// A bundled provider logo rendered as a template image so it tints like
    /// any other glyph. Falls back to an SF Symbol when the asset is missing
    /// (e.g. a bare debug binary with no bundle).
    @ViewBuilder
    private func bundledMark(named name: String) -> some View {
        if let image = Self.bundledImage(named: name) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .foregroundColor(tint)
        } else {
            Image(systemName: Self.symbol(for: provider))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(tint)
        }
    }

    private static func bundledImage(named name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        return image
    }

    /// Bundle resource name (without extension) for providers that ship a logo
    /// asset; `nil` would mean "no logo" but callers guard by provider first.
    private static func resourceName(for provider: Provider) -> String {
        switch provider {
        case .codex:      return "codex-logo"
        case .grok:       return "grok-logo"
        case .openCodeGo: return "opencode-logo"
        case .antigravity:return "antigravity-logo"
        case .openRouter, .claude, .cursor, .copilot, .gemini: return ""
        }
    }

    static func symbol(for provider: Provider) -> String {
        switch provider {
        case .codex:      return "sparkle"
        case .antigravity:return "sparkles"
        case .grok:       return "eye"
        // A real SF Symbol name: an invalid name renders as nothing, which
        // silently blanked this provider's mark wherever no bundled logo
        // exists (e.g. a bare debug binary).
        case .openCodeGo: return "arrow.up.left.and.arrow.down.right"
        case .openRouter: return "arrow.triangle.branch"
        case .claude:     return "sparkles"
        case .cursor:     return "cursorarrow.rays"
        case .copilot:    return "terminal"
        case .gemini:     return "diamond"
        }
    }
}
