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

    var body: some View {
        Group {
            if coordinator.preferences.menuBarCompactEnabled {
                // The tray and the side notch panel are independent surfaces.
                // Compact mode carries no usage numbers at all: whoever turns
                // it on reads usage from the notch panel (or the popover) and
                // the tray stays a single access point.
                CompactTrayGlyph()
            } else {
                trayClusters
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
        HStack(spacing: 3) {
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
                    }
                }
            }
        }
    }

    // MARK: Clusters

    private struct Cluster {
        let provider: Provider
        let percent: String?
        let usedFraction: Double
        let markTint: Color
        let numberTint: Color
    }

    private var clusters: [Cluster] {
        coordinator.menuBarProviders.compactMap { provider in
            let window = coordinator.quotas[provider]?.value?.windows
                .max(by: { $0.usedPercent < $1.usedPercent })

            let status = coordinator.statuses[provider]?.value
            let markTint: Color
            if let status {
                markTint = Self.statusTint(status.severity)
            } else if let window {
                markTint = headroomColor(usedPercent: window.usedPercent)
            } else {
                markTint = MU.neutral
            }

            if let window {
                return Cluster(
                    provider: provider,
                    percent: Fmt.percent(window.usedPercent),
                    usedFraction: window.fraction,
                    markTint: markTint,
                    numberTint: headroomColor(usedPercent: window.usedPercent)
                )
            }
            // No quota, but a degraded-or-worse service is worth a bare mark.
            if let status, status.severity != .operational, status.severity != .unknown {
                return Cluster(
                    provider: provider,
                    percent: nil,
                    usedFraction: 0,
                    markTint: markTint,
                    numberTint: markTint
                )
            }
            return nil
        }
    }

    /// Animates on the tightest cluster so a meaningful change (a quota
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
            return "\(cluster.provider.displayName) \(percent) used"
        }
        .joined(separator: ", ")
    }
}

// MARK: - Compact tray glyph

/// The one small mark the tray shows in compact mode, reused by the popover's
/// welcome page so the onboarding text points at the real thing.
///
/// The same fill-gauge geometry the app icon is drawn from (see
/// `Scripts/make-icon.swift`: 9×13 outline, 1pt stroke, fill rising from the
/// bottom). The fill is deliberately fixed — the compact tray carries no
/// usage numbers, so there is nothing here to tint by headroom or status.
struct CompactTrayGlyph: View {

    /// Same reading as the app icon, so the two read as one object.
    private static let fillFraction: CGFloat = 0.72

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .strokeBorder(MU.text, lineWidth: 1)
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(MU.text)
                    .frame(height: geo.size.height * Self.fillFraction)
            }
            .padding(2)
        }
        .frame(width: 9, height: 13)
    }
}

/// The compact provider glyph shown in the status item.
///
/// Codex uses the real logo bundled at `Resources/codex-logo.png`, rendered as
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
            case .openRouter:
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
        case .openRouter, .claude: return ""
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
        }
    }
}