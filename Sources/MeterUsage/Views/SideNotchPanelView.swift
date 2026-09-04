import SwiftUI

// MARK: - Side notch panel view
//
// The content of the floating right-edge strip: one progress ring per menu-bar
// provider, each with its percent underneath. Hovering the strip expands a
// detail card beside it — the same "glance, then lean in" escalation the popover
// offers, without leaving the edge of the screen.
//
// Data comes straight from the coordinator, exactly like the menu-bar label:
// the tightest window per provider drives the ring, tinted by quota headroom,
// and the mark is tinted by service status. A provider with no quota reading is
// skipped rather than drawn as an empty ring.

struct SideNotchPanelView: View {

    @ObservedObject var coordinator: AppCoordinator
    /// Reports the view's natural size so the hosting panel can keep its
    /// top-right corner pinned while the content grows and shrinks. Same
    /// contract as `MenuBarLabel.onWidthChange`.
    var onSizeChange: (CGSize) -> Void = { _ in }

    @State private var isExpanded = false
    /// Collapse hysteresis: a real pointer exit schedules the collapse, but a
    /// re-enter before it fires cancels it. Without the grace window, the
    /// tracking-area churn caused by the panel's own resize can deliver a
    /// spurious exit while the pointer is still geometrically inside — the
    /// panel then thrashes open/closed nonstop while hovered.
    @State private var collapseTask: Task<Void, Never>?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Instant insert, deliberately: animating the layout change makes
            // the panel resize across many frames, and every frame risks a
            // tracking update that flips the hover state and restarts the
            // cycle. One layout pass means one resize.
            if isExpanded {
                detailCard
            }
            strip
        }
        .fixedSize()
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { onSizeChange(proxy.size) }
                    .onChange(of: proxy.size.width) { _ in onSizeChange(proxy.size) }
                    .onChange(of: proxy.size.height) { _ in onSizeChange(proxy.size) }
            }
        )
        .background(
            HoverSensor { hovering in
                if hovering {
                    collapseTask?.cancel()
                    collapseTask = nil
                    isExpanded = true
                } else {
                    collapseTask = Task {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        guard !Task.isCancelled else { return }
                        isExpanded = false
                    }
                }
            }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: Compact strip

    private var strip: some View {
        VStack(spacing: 10) {
            if entries.isEmpty {
                Text("—")
                    .font(.muNumber)
                    .foregroundColor(MU.neutral)
            } else {
                ForEach(entries) { entry in
                    VStack(spacing: 3) {
                        QuotaRing(
                            fraction: entry.fraction,
                            tint: entry.ringTint,
                            provider: entry.provider,
                            markTint: entry.markTint
                        )
                        Text(Fmt.percent(entry.usedPercent))
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundColor(entry.ringTint)
                    }
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(MU.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(MU.hairline, lineWidth: 1)
        )
    }

    // MARK: Expanded detail card

    private var detailCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        ProviderMark(provider: entry.provider, tint: entry.markTint)
                            .frame(width: 12, height: 12)
                        Text(entry.provider.displayName)
                            .font(.muBody)
                            .foregroundColor(MU.text)
                        Spacer(minLength: 6)
                        Text(Fmt.percent(entry.usedPercent))
                            .font(.muNumber)
                            .foregroundColor(entry.ringTint)
                    }
                    MeterBar(fraction: entry.fraction, tint: entry.ringTint)
                    if let reset = resetCaption(for: entry) {
                        Text(reset)
                            .font(.muCaption)
                            .foregroundColor(MU.textTertiary)
                    }
                }
            }
            if let last = coordinator.lastRefreshedAt {
                Text("Updated \(Fmt.timeSince(last, now: coordinator.clock))")
                    .font(.muCaption)
                    .foregroundColor(MU.textTertiary)
            }
        }
        .padding(12)
        .frame(width: 220)
        .background(
            RoundedRectangle(cornerRadius: MU.cardRadius, style: .continuous)
                .fill(MU.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MU.cardRadius, style: .continuous)
                .strokeBorder(MU.hairline, lineWidth: 1)
        )
    }

    // MARK: Entries

    /// One glanceable reading per provider: the provider's tightest window.
    ///
    /// A pure function of the coordinator's published state so tests can assert
    /// ordering and selection without a screen.
    struct Entry: Identifiable {
        let provider: Provider
        let usedPercent: Double
        let fraction: Double
        let ringTint: Color
        let markTint: Color
        let resetsAt: Date?

        var id: Provider { provider }
    }

    static func entries(
        menuBarProviders: [Provider],
        quotas: [Provider: Loaded<ProviderQuota>],
        statuses: [Provider: Loaded<ServiceStatus>]
    ) -> [Entry] {
        menuBarProviders.compactMap { provider in
            guard let window = quotas[provider]?.value?.windows
                .max(by: { $0.usedPercent < $1.usedPercent }) else { return nil }
            let markTint: Color
            if let status = statuses[provider]?.value {
                markTint = MenuBarLabel.statusTint(status.severity)
            } else {
                markTint = headroomColor(usedPercent: window.usedPercent)
            }
            return Entry(
                provider: provider,
                usedPercent: window.usedPercent,
                fraction: window.fraction,
                ringTint: headroomColor(usedPercent: window.usedPercent),
                markTint: markTint,
                resetsAt: window.resetsAt
            )
        }
    }

    private var entries: [Entry] {
        Self.entries(
            menuBarProviders: coordinator.menuBarProviders,
            quotas: coordinator.quotas,
            statuses: coordinator.statuses
        )
    }

    /// Same escalation the popover uses: a live countdown when one is
    /// meaningful, otherwise the wall-clock moment, otherwise nothing.
    private func resetCaption(for entry: Entry) -> String? {
        guard let resetsAt = entry.resetsAt else { return nil }
        if let remaining = Fmt.timeUntil(resetsAt, now: coordinator.clock) {
            return "Resets in \(remaining)"
        }
        return "Resets \(Fmt.absoluteMoment(resetsAt, now: coordinator.clock))"
    }

    private var accessibilityText: String {
        if entries.isEmpty { return "Usage unavailable" }
        return entries.map { "\($0.provider.displayName) \(Fmt.percent($0.usedPercent)) used" }
            .joined(separator: ", ")
    }
}

// MARK: - Hover sensor

/// Reports pointer presence for the panel with one AppKit-level tracking area.
///
/// SwiftUI's `.onHover` installs per-view tracking areas that are rebuilt on
/// every layout pass. During the panel's own resize that churn delivers
/// exit/enter pairs while the pointer is still geometrically inside, which
/// used to thrash the panel open/closed nonstop. A single `NSTrackingArea`
/// covering this view's bounds is stable: AppKit evaluates containment and
/// fires only on true boundary crossings.
private struct HoverSensor: NSViewRepresentable {
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> SensorView {
        let view = SensorView()
        view.onHover = onHover
        return view
    }

    func updateNSView(_ view: SensorView, context: Context) {
        view.onHover = onHover
    }

    final class SensorView: NSView {
        var onHover: (Bool) -> Void = { _ in }
        private var tracking: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            // Installed once, with `.inVisibleRect`: AppKit then evaluates the
            // cursor against the view's visible rect as it changes and fires
            // only on true boundary crossings. Re-adding an area per layout
            // pass is not an option here — AppKit reports mouseExited for a
            // removed area the pointer was inside, and the replacement only
            // re-enters on the next mouse event, so every resize synthesized
            // an exit while the pointer sat still.
            guard tracking == nil else { return }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) { onHover(true) }

        override func mouseExited(with event: NSEvent) { onHover(false) }
    }
}

// MARK: - Ring

/// A circular progress ring with the provider's mark at its centre.
///
/// Drawn by hand for the same reason `MeterBar` is: the stock progress view
/// cannot be tinted per-value here, and the ring must read as part of this
/// app's design language, not a system control.
private struct QuotaRing: View {
    let fraction: Double
    let tint: Color
    let provider: Provider
    let markTint: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(MU.well, lineWidth: 3.5)
            Circle()
                .trim(from: 0, to: fraction.clamped(to: 0...1))
                .stroke(tint, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            ProviderMark(provider: provider, tint: markTint)
                .frame(width: 14, height: 14)
        }
        .frame(width: 38, height: 38)
        .animation(.easeOut(duration: 0.35), value: fraction)
    }
}
