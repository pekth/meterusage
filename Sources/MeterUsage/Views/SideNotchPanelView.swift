import SwiftUI

// MARK: - Side notch panel view
//
// The content of the floating right-edge strip: one progress ring per menu-bar
// provider, each with its used percent underneath. Hovering any provider in
// the strip expands a dedicated detail card beside the strip with per-window
// bars and reset times.
//
// Data comes straight from the coordinator, exactly like the menu-bar label:
// the tightest window per provider drives the ring, tinted by quota headroom,
// and the mark is tinted by service status. A provider with no quota reading is
// skipped rather than drawn as an empty ring.

struct SideNotchPanelView: View {

    @ObservedObject var coordinator: AppCoordinator
    var onOpenSettings: () -> Void = {}
    /// Reports the view's natural size so the hosting panel can keep its
    /// top-right corner pinned while the content grows and shrinks. Same
    /// contract as `MenuBarLabel.onWidthChange`.
    var onSizeChange: (CGSize) -> Void = { _ in }

    @State private var hoveredProvider: Provider?
    @State private var isHoveringSettings = false
    @State private var isHoveringBottom = false
    /// Collapse hysteresis: a pointer exit schedules collapse, but a
    /// re-enter before the delay fires cancels it.
    @State private var collapseTask: Task<Void, Never>?

    var body: some View {
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
                        if hovering {
                            collapseTask?.cancel()
                            collapseTask = nil
                        }
                    }
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
                } else {
                    collapseTask = Task {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        guard !Task.isCancelled else { return }
                        hoveredProvider = nil
                        isHoveringSettings = false
                        isHoveringBottom = false
                    }
                }
            }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: - Strip

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
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering {
                            collapseTask?.cancel()
                            collapseTask = nil
                            hoveredProvider = entry.provider
                            isHoveringSettings = false
                            isHoveringBottom = false
                        }
                    }
                }

                if isHoveringBottom {
                    Button(action: onOpenSettings) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(isHoveringSettings ? MU.text : MU.textTertiary)
                            .frame(width: 28, height: 28)
                            .background(
                                Circle()
                                    .fill(isHoveringSettings ? MU.well : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Settings")
                    .onHover { hovering in
                        isHoveringSettings = hovering
                        if hovering {
                            collapseTask?.cancel()
                            collapseTask = nil
                            hoveredProvider = nil
                            isHoveringBottom = true
                        } else {
                            isHoveringBottom = false
                        }
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
        .overlay(alignment: .bottom) {
            if !isHoveringBottom && !entries.isEmpty {
                Color.clear
                    .frame(height: 20)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering {
                            collapseTask?.cancel()
                            collapseTask = nil
                            hoveredProvider = nil
                            isHoveringBottom = true
                        }
                    }
            }
        }
    }

    // MARK: - Detail card for hovered provider

    private func detailCard(for provider: Provider) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: icon, "[Provider] Usage", and reset countdown
            HStack(alignment: .center, spacing: 8) {
                ProviderMark(provider: provider, tint: providerColor(provider))
                    .frame(width: 14, height: 14)
                Text("\(provider.displayName) Usage")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(MU.text)
                Spacer(minLength: 6)
                if let countdown = headerResetCountdown(for: provider) {
                    Text("Resets in \(countdown)")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(MU.textTertiary)
                }
            }

            // Service status alert if degraded or outage
            if let status = coordinator.statuses[provider]?.value,
               status.severity != .operational && status.severity != .unknown {
                StatusBadge(severity: status.severity)
            }

            // Rate limit windows
            if let quota = coordinator.quotas[provider]?.value, !quota.windows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(quota.windows.enumerated()), id: \.offset) { _, window in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(windowDisplayTitle(for: window, provider: provider))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(MU.text)

                            // Fixed-width track so layout never collapses or jumps
                            ZStack(alignment: .leading) {
                                Capsule(style: .continuous)
                                    .fill(MU.well)
                                    .frame(width: 222, height: 5)
                                Capsule(style: .continuous)
                                    .fill(headroomColor(usedPercent: window.usedPercent))
                                    .frame(width: max(222 * window.fraction.clamped(to: 0...1), window.fraction > 0 ? 3 : 0), height: 5)
                            }

                            HStack {
                                Text("\(Fmt.percent(window.usedPercent)) Used")
                                    .font(.system(size: 11, weight: .regular))
                                    .foregroundColor(MU.text)
                                Spacer()
                                if let resetsAt = window.resetsAt {
                                    Text("Resets \(Fmt.absoluteMoment(resetsAt, now: coordinator.clock))")
                                        .font(.system(size: 11, weight: .regular))
                                        .foregroundColor(MU.textTertiary)
                                }
                            }
                        }
                    }
                }
            } else if let quota = coordinator.quotas[provider]?.value, let credits = quota.credits {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Account balance")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(MU.text)
                    Text(credits.unit == .dollars ? Fmt.usd(credits.balance) : Fmt.credits(credits.balance))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundColor(MU.text)
                }
            }

            // Token usage summary
            if let tokenUsage = tokenUsage(for: provider),
               (tokenUsage.todayText != nil || tokenUsage.last30DaysText != nil) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Token usage")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(MU.text)

                    if let today = tokenUsage.todayText {
                        HStack {
                            Text("Today")
                                .font(.system(size: 11, weight: .regular))
                                .foregroundColor(MU.text)
                            Spacer()
                            Text(today)
                                .font(.system(size: 11, weight: .regular).monospacedDigit())
                                .foregroundColor(MU.textTertiary)
                        }
                    }

                    if let last30 = tokenUsage.last30DaysText {
                        HStack {
                            Text("Last 30 days")
                                .font(.system(size: 11, weight: .regular))
                                .foregroundColor(MU.text)
                            Spacer()
                            Text(last30)
                                .font(.system(size: 11, weight: .regular).monospacedDigit())
                                .foregroundColor(MU.textTertiary)
                        }
                    }
                }
            }

            // Timestamp
            if let last = coordinator.lastRefreshedAt {
                Text("Updated \(Fmt.timeSince(last, now: coordinator.clock))")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(MU.textTertiary)
            }
        }
        .padding(14)
        .frame(width: 250)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(MU.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(MU.hairline, lineWidth: 1)
        )
    }

    // MARK: - Geometry helpers

    private func ringCenterY(for provider: Provider) -> CGFloat {
        guard let index = entries.firstIndex(where: { $0.provider == provider }) else {
            return 31
        }
        return 31 + CGFloat(index) * 65
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

    private func headerResetCountdown(for provider: Provider) -> String? {
        guard let quota = coordinator.quotas[provider]?.value else { return nil }
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

    private var accessibilityText: String {
        if entries.isEmpty { return "Usage unavailable" }
        return entries.map { "\($0.provider.displayName) \(Fmt.percent($0.usedPercent)) used" }
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
        ZStack {
            TriangleArrow()
                .fill(MU.surface)
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: 7, y: 6))
                path.addLine(to: CGPoint(x: 0, y: 12))
            }
            .stroke(MU.hairline, lineWidth: 1)
        }
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
