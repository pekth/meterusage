import SwiftUI
import AppKit

// MARK: - Notch palette
//
// The side panel is a hardware-like object: fixed black in every appearance,
// never the app's dynamic surfaces. Values below follow the codenotch design
// frame (reference only — nothing is shared with that project): pure-black
// body, near-black card, dark-grey ring fill and track, vivid state bands,
// white figures. Provider marks keep their existing tints; only the panel
// chrome and state colours live here.

/// Ring state band. Same thresholds as the app's headroom scale, so severity
/// never disagrees between the notch and the popover — only the hues differ.
enum NotchBand: Equatable {
    case plenty
    case gettingClose
    case nearlyOut
    case atLimit

    static func band(usedPercent: Double) -> NotchBand {
        switch usedPercent {
        case ..<50:  return .plenty
        case ..<80:  return .gettingClose
        case ..<100: return .nearlyOut
        default:     return .atLimit
        }
    }
}

enum Notch {
    static let body = Color(red: 0, green: 0, blue: 0)
    static let card = Color(red: 0.04, green: 0.04, blue: 0.04)
    static let disc = Color(red: 0.16, green: 0.16, blue: 0.16)
    static let track = Color(red: 0.23, green: 0.23, blue: 0.23)
    static let text = Color.white
    static let subtext = Color(white: 1, opacity: 0.55)
    static let orbGrey = Color(white: 1, opacity: 0.35)

    static func color(usedPercent: Double) -> Color {
        switch NotchBand.band(usedPercent: usedPercent) {
        case .plenty:       return Color(red: 0.16, green: 0.88, blue: 0.48)
        case .gettingClose: return Color(red: 0.96, green: 0.89, blue: 0.0)
        case .nearlyOut, .atLimit:
            return Color(red: 1.0, green: 0.27, blue: 0.0)
        }
    }
}

// MARK: - Side notch panel view
//
// The content of the floating right-edge strip: one progress ring per menu-bar
// provider, each with its used percent underneath. Hovering any provider in
// the strip expands a dedicated detail card beside the strip with per-window
// bars and reset times. Provider marks are untouched by this view's
// interaction layer: fold, pin, click-to-refresh, and cursor only.
//
// Data comes straight from the coordinator, exactly like the menu-bar label:
// each provider's declared headline window drives its ring, tinted by quota
// headroom, and the mark is tinted by service status. A provider with no
// headline reading is skipped rather than drawn as an empty ring.
//
// Interaction (borrowed from codenotch's notch, adapted to this strip):
// the panel folds to a slim pill and unfolds on hover; "Keep open" pins it
// unfolded across relaunches; clicking a ring refetches only that provider
// so one cell never spends the others' rate-limit budget.

struct SideNotchPanelView: View {

    @ObservedObject var coordinator: AppCoordinator
    var onOpenSettings: () -> Void = {}
    /// Reports the view's natural size so the hosting panel can keep its
    /// top-right corner pinned while the content grows and shrinks. Same
    /// contract as `MenuBarLabel.onWidthChange`.
    var onSizeChange: (CGSize) -> Void = { _ in }

    @AppStorage(PrefKey.sideNotchPanelPinned) private var isPinned = false
    @AppStorage(PrefKey.sideNotchPanel) private var panelEnabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredProvider: Provider?
    @State private var isHoveringPanel = false
    @State private var isHoveringSettings = false
    @State private var refreshingProviders: Set<Provider> = []
    /// Collapse hysteresis: a pointer exit schedules collapse, but a
    /// re-enter before the delay fires cancels it. 450ms — deliberately
    /// longer than a tooltip grace, so the fold never feels twitchy.
    @State private var collapseTask: Task<Void, Never>?

    /// Unfolded while pinned or while the pointer is on the panel.
    private var isOpen: Bool {
        isPinned || isHoveringPanel || hoveredProvider != nil || isHoveringSettings
    }

    var body: some View {
        Group {
            if isOpen {
                openPanel
                    .transition(.opacity)
            } else {
                foldedPill
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: isOpen)
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
                    isHoveringPanel = true
                } else {
                    scheduleFold()
                }
            }
        )
        .contextMenu {
            Toggle("Keep open", isOn: $isPinned)
            Button("Refresh now") { coordinator.refresh() }
            Divider()
            Button("Hide panel") { panelEnabled = false }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func scheduleFold() {
        collapseTask?.cancel()
        collapseTask = Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            hoveredProvider = nil
            isHoveringPanel = false
            isHoveringSettings = false
        }
    }

    private func cancelFold() {
        collapseTask?.cancel()
        collapseTask = nil
    }

    /// Pushes/pops (never stamps) the pointing hand over a ring, so leaving
    /// restores whatever cursor the app underneath had chosen. Static and
    /// out-of-line to keep the cell's view-builder expression cheap to check.
    private static func setHandCursor(_ hovering: Bool) {
        if hovering {
            NSCursor.pointingHand.push()
        } else {
            NSCursor.pop()
        }
    }

    private var openPanel: some View {
        HStack(alignment: .top, spacing: 0) {
            if let hovered = hoveredProvider, entries.contains(where: { $0.provider == hovered }) {
                detailCard(for: hovered)
                    .id(hovered)
                    .overlay(alignment: .topTrailing) {
                        ArrowBeakView()
                            .offset(x: 6.5, y: beakYOnCard(for: hovered))
                    }
                    .padding(.top, cardTopOffset(for: hovered))
                    .padding(.trailing, 8)
                    .onHover { hovering in
                        if hovering { cancelFold() }
                    }
            }
            strip
        }
        .fixedSize()
    }

    // MARK: - Folded pill

    /// Slim resting pill shown when the panel is neither pinned nor hovered.
    /// Dots reuse the entries' ring tints so headroom stays readable at rest.
    private var foldedPill: some View {
        VStack(spacing: 6) {
            ForEach(entries.prefix(5)) { entry in
                Circle()
                    .fill(entry.ringTint)
                    .frame(width: 8, height: 8)
            }
            if entries.isEmpty {
                Circle()
                    .fill(Color(white: 1, opacity: 0.4))
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .background(
            Capsule(style: .continuous)
                .fill(Notch.body)
        )
        .overlay(
            // The one border in the notch: without it the resting pill
            // vanishes into dark wallpapers. Track-grey keeps it a whisper.
            Capsule(style: .continuous)
                .strokeBorder(Notch.track, lineWidth: 1)
        )
        .fixedSize()
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                cancelFold()
                isHoveringPanel = true
            } else {
                scheduleFold()
            }
        }
        .accessibilityLabel(accessibilityText)
    }

    // MARK: - Strip

    private var strip: some View {
        VStack(spacing: 10) {
            if entries.isEmpty {
                Text("—")
                    .font(.muNumber)
                    .foregroundColor(Notch.subtext)
            } else {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    VStack(spacing: 3) {
                        QuotaRing(
                            fraction: entry.fraction,
                            tint: entry.ringTint,
                            provider: entry.provider,
                            markTint: entry.markTint,
                            reduceMotion: reduceMotion
                        )
                        Text(Fmt.percent(entry.usedPercent))
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .foregroundColor(Notch.text)
                    }
                    .contentShape(Rectangle())
                    .scaleEffect(refreshingProviders.contains(entry.provider) ? 0.92 : 1.0)
                    // A remembered reading is dated information: dim it so it
                    // never passes for a live number.
                    .opacity(entry.isStale ? 0.55 : 1.0)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                    // Cells trail each other behind the unfold, capped so a
                    // long list never drags.
                    .animation(
                        reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)
                            .delay(min(Double(index) * 0.03, 0.12)),
                        value: entry.fraction
                    )
                    .help("Click to refresh \(entry.provider.displayName)")
                    .onTapGesture { refreshRing(entry.provider) }
                    .onHover { hovering in
                        if hovering {
                            cancelFold()
                            isHoveringPanel = true
                            hoveredProvider = entry.provider
                            isHoveringSettings = false
                        }
                        Self.setHandCursor(hovering)
                    }
                }

                // Settings orb: a quiet arc at rest below the strip that wakes
                // into a gear on hover. Always present, never gated behind a
                // hotspot hunt — the readings stay the point, but settings
                // stay findable.
                settingsOrb
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Notch.body)
        )
    }

    private var settingsOrb: some View {
        Button(action: onOpenSettings) {
            ZStack {
                if isHoveringSettings {
                    Circle()
                        .fill(Notch.disc)
                        .frame(width: 30, height: 30)
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Notch.text)
                } else {
                    Circle()
                        .trim(from: 0.05, to: 0.7)
                        .stroke(Notch.orbGrey, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 26, height: 26)
                }
            }
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .help("Settings")
        .onHover { hovering in
            isHoveringSettings = hovering
            if hovering {
                cancelFold()
                hoveredProvider = nil
            }
        }
    }

    // MARK: - Detail card for hovered provider

    private func detailCard(for provider: Provider) -> some View {
        // The card follows the ring: live reading when present, otherwise
        // the archived last-good reading, dated as such.
        let display = coordinator.displayQuota(for: provider)
        let quota = display?.quota
        let isStale = display?.isStale ?? false
        return VStack(alignment: .leading, spacing: 10) {
            // Header: icon, "[Provider] Usage", and reset countdown
            HStack(alignment: .center, spacing: 8) {
                ProviderMark(provider: provider, tint: providerColor(provider))
                    .frame(width: 14, height: 14)
                Text("\(provider.displayName) Usage")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Notch.text)
                Spacer(minLength: 6)
                if let countdown = headerResetCountdown(for: provider) {
                    Text("Resets in \(countdown)")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(Notch.subtext)
                }
            }

            // Service status alert if degraded or outage
            if let status = coordinator.statuses[provider]?.value,
               status.severity != .operational && status.severity != .unknown {
                StatusBadge(severity: status.severity)
            }

            // Rate limit windows
            if let quota, !quota.windows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(quota.windows.enumerated()), id: \.offset) { _, window in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(windowDisplayTitle(for: window, provider: provider))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(Notch.text)

                            // Fixed-width track so layout never collapses or jumps
                            ZStack(alignment: .leading) {
                                Capsule(style: .continuous)
                                    .fill(Notch.track)
                                    .frame(width: 222, height: 4)
                                Capsule(style: .continuous)
                                    .fill(Notch.color(usedPercent: window.usedPercent))
                                    .frame(width: max(222 * window.fraction.clamped(to: 0...1), window.fraction > 0 ? 3 : 0), height: 4)
                            }

                            HStack {
                                Text("\(Fmt.percent(window.usedPercent)) Used")
                                    .font(.system(size: 11, weight: .regular))
                                    .foregroundColor(Notch.text)
                                Spacer()
                                if let resetsAt = window.resetsAt {
                                    Text("Resets \(Fmt.absoluteMoment(resetsAt, now: coordinator.clock))")
                                        .font(.system(size: 11, weight: .regular))
                                        .foregroundColor(Notch.subtext)
                                }
                            }
                        }
                    }
                }
            } else if let quota, let credits = quota.credits {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Account balance")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Notch.text)
                    Text(credits.unit == .dollars ? Fmt.usd(credits.balance) : Fmt.credits(credits.balance))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundColor(Notch.text)
                }
            }

            // Token usage summary
            if let tokenUsage = tokenUsage(for: provider),
               (tokenUsage.todayText != nil || tokenUsage.last30DaysText != nil) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Token usage")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Notch.text)

                    if let today = tokenUsage.todayText {
                        HStack {
                            Text("Today")
                                .font(.system(size: 11, weight: .regular))
                                .foregroundColor(Notch.text)
                            Spacer()
                            Text(today)
                                .font(.system(size: 11, weight: .regular).monospacedDigit())
                                .foregroundColor(Notch.subtext)
                        }
                    }

                    if let last30 = tokenUsage.last30DaysText {
                        HStack {
                            Text("Last 30 days")
                                .font(.system(size: 11, weight: .regular))
                                .foregroundColor(Notch.text)
                            Spacer()
                            Text(last30)
                                .font(.system(size: 11, weight: .regular).monospacedDigit())
                                .foregroundColor(Notch.subtext)
                        }
                    }
                }
            }

            // Timestamp: a remembered reading is dated by its own capture,
            // never by the last sweep — presenting it under "just now"
            // would be a lie.
            if isStale, let quota {
                Text("Last reading \(Fmt.timeSince(quota.capturedAt, now: coordinator.clock))")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(Notch.subtext)
            } else if let last = coordinator.lastRefreshedAt {
                Text("Updated \(Fmt.timeSince(last, now: coordinator.clock))")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(Notch.subtext)
            }
        }
        .padding(14)
        .frame(width: 250)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Notch.card)
        )
    }

    // MARK: - Geometry helpers

    private func ringCenterY(for provider: Provider) -> CGFloat {
        guard let index = entries.firstIndex(where: { $0.provider == provider }) else {
            return 34
        }
        return 34 + CGFloat(index) * 73
    }

    private func cardTopOffset(for provider: Provider) -> CGFloat {
        let center = ringCenterY(for: provider)
        return max(0, center - 37)
    }

    private func beakYOnCard(for provider: Provider) -> CGFloat {
        let center = ringCenterY(for: provider)
        let offset = cardTopOffset(for: provider)
        return center - offset - 6
    }

    private func windowDisplayTitle(for window: QuotaWindow, provider: Provider) -> String {
        if provider == .codex && (window.label == "5-hour" || window.label.lowercased().contains("session")) {
            return "Current session"
        }
        return window.label
    }

    /// Click-to-refresh for one ring. Refetches only that provider so one
    /// cell never spends the others' rate-limit budget. A second click while
    /// one is in flight is ignored.
    private func refreshRing(_ provider: Provider) {
        guard !refreshingProviders.contains(provider) else { return }
        refreshingProviders.insert(provider)
        coordinator.refresh(provider: provider)
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            refreshingProviders.remove(provider)
        }
    }

    private func headerResetCountdown(for provider: Provider) -> String? {
        guard let quota = coordinator.displayQuota(for: provider)?.quota else { return nil }
        let windowsWithReset = quota.windows.compactMap { w -> (QuotaWindow, Date)? in
            guard let r = w.resetsAt, r > coordinator.clock else { return nil }
            return (w, r)
        }.sorted { $0.1 < $1.1 }

        guard let first = windowsWithReset.first else { return nil }
        return Fmt.timeUntil(first.1, now: coordinator.clock)
    }

    private struct ProviderTokenUsage {
        var todayText: String?
        var last30DaysText: String?
    }

    private func tokenUsage(for provider: Provider) -> ProviderTokenUsage? {
        var todayStr: String?
        var last30Str: String?

        if let usage = coordinator.usages[provider]?.value {
            if let windows = usage.usageWindows {
                if let window = windows.first(where: { $0.label.lowercased().contains("24h") || $0.label.lowercased().contains("today") }) {
                    let tokenPart = window.tokens.total > 0 ? Fmt.tokenCountString(window.tokens.total) : nil
                    let costPart = window.estimatedCostUSD > 0 ? String(format: "$%.2f", window.estimatedCostUSD) : nil
                    if let tokenPart, let costPart {
                        todayStr = "\(tokenPart) · \(costPart)"
                    } else if let tokenPart {
                        todayStr = tokenPart
                    } else if let costPart {
                        todayStr = costPart
                    }
                }
                if let window = windows.first(where: { $0.label.lowercased().contains("30d") || $0.label.lowercased().contains("30 days") }) {
                    let tokenPart = window.tokens.total > 0 ? Fmt.tokenCountString(window.tokens.total) : nil
                    let costPart = window.estimatedCostUSD > 0 ? String(format: "$%.2f", window.estimatedCostUSD) : nil
                    if let tokenPart, let costPart {
                        last30Str = "\(tokenPart) · \(costPart)"
                    } else if let tokenPart {
                        last30Str = tokenPart
                    } else if let costPart {
                        last30Str = costPart
                    }
                }
            }

            if todayStr == nil, let tokens = usage.tokens, tokens.total > 0 {
                if let cost = usage.estimatedCostUSD, cost > 0 {
                    todayStr = "\(Fmt.tokenCountString(tokens.total)) · \(String(format: "$%.2f", cost))"
                } else {
                    todayStr = Fmt.tokenCountString(tokens.total)
                }
            } else if todayStr == nil && usage.sessionCount > 0 {
                todayStr = "\(usage.sessionCount) sessions"
            }
        }

        if todayStr == nil && last30Str == nil {
            return nil
        }
        return ProviderTokenUsage(todayText: todayStr, last30DaysText: last30Str)
    }

    // MARK: - Entries

    struct Entry: Identifiable {
        let provider: Provider
        let usedPercent: Double
        let fraction: Double
        let ringTint: Color
        let markTint: Color
        let resetsAt: Date?
        /// True when the ring shows the archived last-good reading because
        /// the live fetch has nothing. Rendered dimmed, never as live.
        let isStale: Bool

        var id: Provider { provider }
    }

    static func entries(
        menuBarProviders: [Provider],
        quotas: [Provider: Loaded<ProviderQuota>],
        statuses: [Provider: Loaded<ServiceStatus>],
        archivedQuotas: [Provider: ProviderQuota] = [:]
    ) -> [Entry] {
        menuBarProviders.compactMap { provider in
            let live = quotas[provider]?.value
            let quota = live ?? archivedQuotas[provider]
            guard let windows = quota?.windows,
                  let window = provider.headlineWindow(from: windows)
            else { return nil }
            let markTint: Color
            if let status = statuses[provider]?.value {
                markTint = MenuBarLabel.statusTint(status.severity)
            } else {
                markTint = Notch.color(usedPercent: window.usedPercent)
            }
            return Entry(
                provider: provider,
                usedPercent: window.usedPercent,
                fraction: window.fraction,
                ringTint: Notch.color(usedPercent: window.usedPercent),
                markTint: markTint,
                resetsAt: window.resetsAt,
                isStale: live == nil
            )
        }
    }

    private var entries: [Entry] {
        Self.entries(
            menuBarProviders: coordinator.menuBarProviders,
            quotas: coordinator.quotas,
            statuses: coordinator.statuses,
            archivedQuotas: coordinator.archivedQuotas
        )
    }

    private var accessibilityText: String {
        if entries.isEmpty { return "Usage unavailable" }
        return entries.map {
            "\($0.provider.displayName) \(Fmt.percent($0.usedPercent)) used\($0.isStale ? ", last known" : "")"
        }
        .joined(separator: ", ")
    }
}

// MARK: - Popover Arrow Beak

private struct TriangleArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct ArrowBeakView: View {
    var body: some View {
        TriangleArrow()
            .fill(Notch.card)
            .frame(width: 7, height: 12)
    }
}

// MARK: - Hover sensor

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

private struct QuotaRing: View {
    let fraction: Double
    let tint: Color
    let provider: Provider
    let markTint: Color
    var reduceMotion = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Notch.disc)
            Circle()
                .stroke(Notch.track, lineWidth: 3.5)
            Circle()
                .trim(from: 0, to: fraction.clamped(to: 0...1))
                .stroke(tint, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            ProviderMark(provider: provider, tint: markTint)
                .frame(width: 14, height: 14)
                // A hit limit dims the glyph: the full orange ring already
                // carries the state, and the mark steps back.
                .opacity(fraction >= 1 ? 0.5 : 1.0)
        }
        .frame(width: 44, height: 44)
        // A ring that jumps reads as a glitch; one that sweeps reads as a
        // measurement.
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.65), value: fraction)
    }
}
