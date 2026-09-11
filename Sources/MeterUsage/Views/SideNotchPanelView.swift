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
    static let deficit = Color(red: 1.0, green: 0.584, blue: 0.0) // #FF9500 amber
    static let surplus = Color(red: 0.204, green: 0.78, blue: 0.349) // #34C759 calm green

    static func color(usedPercent: Double) -> Color {
        switch NotchBand.band(usedPercent: usedPercent) {
        case .plenty:       return Color(red: 0.16, green: 0.88, blue: 0.48)
        case .gettingClose: return Color(red: 0.96, green: 0.89, blue: 0.0)
        case .nearlyOut, .atLimit:
            return Color(red: 1.0, green: 0.27, blue: 0.0)
        }
    }
}

// MARK: - Measured strip & card sizes
//
// The card-side math needs the strip's size, which only exists after layout.
// This preference carries it up without affecting layout (a background reader
// is zero-size). The card min-height clamps to the strip height so docking
// is always seamless without orphan beaks or exposed corners.

private struct StripSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

private struct CardHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
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
// Interaction: the panel folds to a slim pill and unfolds on hover;
// "Keep open" pins it unfolded across relaunches. Hover only — rings and
// settings carry no click action; refresh lives in the context menu.

struct SideNotchPanelView: View {

    @ObservedObject var coordinator: AppCoordinator
    /// The hosting controller, observed for the card side only: dragging the
    /// strip across the screen flips the card left/right, which must
    /// re-render the panel. (Both live for the life of the app, so the
    /// reference cycle is harmless.)
    @ObservedObject var panel: SideNotchPanelController
    /// Reports the view's natural size so the hosting panel can keep its
    /// top-right corner pinned while the content grows and shrinks. Same
    /// contract as `MenuBarLabel.onWidthChange`.
    var onSizeChange: (CGSize) -> Void = { _ in }
    /// Reports the strip alone (card excluded) so the controller can track
    /// the strip's screen rect for the card-side math.
    var onStripSizeChange: (CGSize) -> Void = { _ in }

    @AppStorage(PrefKey.sideNotchPanelPinned) private var isPinned = false
    @AppStorage(PrefKey.sideNotchPanel) private var panelEnabled = true
    @AppStorage(PrefKey.showPacingBurnRate) private var showPacingBurnRate = true
    @AppStorage(PrefKey.showActivityTelemetry) private var showActivityTelemetry = true
    @AppStorage(PrefKey.showDailyActivityChart) private var showDailyActivityChart = true
    @AppStorage(PrefKey.showSideNotchResetButton) private var showSideNotchResetButton = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredProvider: Provider?
    @State private var isHoveringPanel = false
    @State private var confirmingResetID: String?
    @State private var consumingResetID: String?
    @State private var resetStatusMessage: String?
    @State private var resetErrorMessage: String?
    @State private var stripHeight: CGFloat = 0
    @State private var cardHeight: CGFloat = 0
    /// Collapse hysteresis: a pointer exit schedules collapse, but a
    /// re-enter before the delay fires cancels it. 450ms — deliberately
    /// longer than a tooltip grace, so the fold never feels twitchy.
    @State private var collapseTask: Task<Void, Never>?

    /// Unfolded while pinned, while the pointer is on the panel, or while a
    /// reset action / confirmation is active.
    private var isOpen: Bool {
        isPinned || isHoveringPanel || hoveredProvider != nil || confirmingResetID != nil || consumingResetID != nil
    }

    /// True when a detail card is actively showing beside the strip.
    private var isCardShowing: Bool {
        let activeHovered = hoveredProvider ?? ((confirmingResetID != nil || consumingResetID != nil) ? .codex : nil)
        return !panel.isDragging && activeHovered != nil && entries.contains(where: { $0.provider == activeHovered })
    }

    var body: some View {
        // No transition here by design: the hosting panel resizes itself
        // from this view's measured size, and an animated swap reports
        // mid-flight sizes that strand the window too narrow for the card.
        // The unfold reads fine as an instant reveal; the rings keep springs.
        Group {
            if isOpen {
                openPanel
            } else {
                foldedPill
            }
        }
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
            if showSideNotchResetButton,
               let codexQuota = coordinator.displayQuota(for: .codex)?.quota,
               let credit = codexQuota.resetCredits.first(where: { isAvailable($0) }) {
                Button("Use Codex reset (\(credit.title))...") {
                    cancelFold()
                    isHoveringPanel = true
                    hoveredProvider = .codex
                    confirmingResetID = credit.id
                }
                Divider()
            }
            Toggle("Keep open", isOn: $isPinned)
            Button("Refresh now") { coordinator.refresh() }
            Divider()
            Button("Hide panel") { panelEnabled = false }
        }
        // Children stay navigable (rings carry their own labels and detail
        // actions below); the folded pill labels itself separately.
    }

    private func scheduleFold() {
        guard confirmingResetID == nil && consumingResetID == nil else { return }
        collapseTask?.cancel()
        collapseTask = Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            guard confirmingResetID == nil && consumingResetID == nil else { return }
            hoveredProvider = nil
            isHoveringPanel = false
        }
    }

    private func cancelFold() {
        collapseTask?.cancel()
        collapseTask = nil
    }

    private var openPanel: some View {
        HStack(alignment: .top, spacing: 0) {
            // Ring exit clears nothing on purpose, so the pointer can slide
            // off a ring onto its card to read it. A provider that leaves
            // `entries` mid-hover must not keep a card mounted for data no
            // longer shown.
            if !panel.cardOnRight {
                cardColumn
            }
            strip
            if panel.cardOnRight {
                cardColumn
            }
        }
        .fixedSize()
        .onPreferenceChange(StripSizeKey.self) { size in
            stripHeight = size.height
            onStripSizeChange(size)
        }
        .onPreferenceChange(CardHeightKey.self) { height in
            cardHeight = height
        }
        .onChange(of: panel.isDragging) { dragging in
            // A drop can strand a hover from before the drag (the mouse never
            // re-enters to refresh it): always reopen from a clean hover.
            if !dragging && confirmingResetID == nil && consumingResetID == nil {
                hoveredProvider = nil
            }
        }
    }

    /// Hover card docked beside the strip — left on a right-parked strip,
    /// right once the strip crosses to the left half of the screen. Hidden
    /// while dragging: a slim strip tracks the cursor, and the side settles
    /// on drop.
    @ViewBuilder
    private var cardColumn: some View {
        let activeHovered = hoveredProvider ?? ((confirmingResetID != nil || consumingResetID != nil) ? .codex : nil)
        if !panel.isDragging,
           let hovered = activeHovered,
           entries.contains(where: { $0.provider == hovered }) {
            let beakY = beakYOnCard(for: hovered)
            let effectiveHeight = max(cardHeight, stripHeight)
            let isBeakWithinBounds = Self.isBeakWithinBounds(beakY: beakY, cardHeight: effectiveHeight)
            detailCard(for: hovered)
                .id(hovered)
                .accessibilityElement(children: .contain)
                .overlay(alignment: panel.cardOnRight ? .topLeading : .topTrailing) {
                    if isBeakWithinBounds {
                        ArrowBeakView()
                            .scaleEffect(x: panel.cardOnRight ? -1 : 1, y: 1)
                            .offset(x: panel.cardOnRight ? -3.5 : 3.5, y: beakY)
                    }
                }
                .onHover { hovering in
                    if hovering { cancelFold() }
                }
        }
    }

    // MARK: - Folded pill

    /// Slim resting pill shown when the panel is neither pinned nor hovered.
    /// Dots reuse the entries' ring tints so headroom stays readable at rest.
    private var foldedPill: some View {
        VStack(spacing: 4) {
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
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
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
        VStack(spacing: 3) {
            if entries.isEmpty {
                Text("—")
                    .font(.muNumber)
                    .foregroundColor(Notch.subtext)
            } else {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    VStack(spacing: 2) {
                        QuotaRing(
                            fraction: entry.fraction,
                            tint: entry.ringTint,
                            provider: entry.provider,
                            markTint: entry.markTint,
                            reduceMotion: reduceMotion
                        )
                        Text(Fmt.percent(entry.usedPercent))
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .foregroundColor(Notch.text)
                    }
                    .contentShape(Rectangle())
                    // VoiceOver reaches this panel without the window ever
                    // taking key focus (nonactivating by design, so Tab never
                    // arrives): each ring is therefore an accessible element
                    // with an explicit details action instead of a focusable
                    // control. The action drives the same card state as hover —
                    // explicit activation wins, and a later mouse enter still
                    // re-asserts, so the two inputs never fight.
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(accessibilityRingText(for: entry))
                    .accessibilityAction(named: "Show details") {
                        cancelFold()
                        isHoveringPanel = true
                        hoveredProvider = entry.provider
                    }
                    .accessibilityAction(named: "Hide details") {
                        hoveredProvider = nil
                    }
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
                    .onHover { hovering in
                        if hovering {
                            cancelFold()
                            isHoveringPanel = true
                            hoveredProvider = entry.provider
                        }
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: StripSizeKey.self, value: proxy.size)
            }
        )
        .background(
            // Square on the card side for the flush dock, round on the
            // exposed side — mirrored when the card flips right, so the
            // outer silhouette stays round and the joint stays square.
            // When no card is showing, all corners stay rounded.
            UnevenRoundedRectangle(
                topLeadingRadius: isCardShowing ? (panel.cardOnRight ? 20 : 0) : 20,
                bottomLeadingRadius: isCardShowing ? (panel.cardOnRight ? 20 : 0) : 20,
                bottomTrailingRadius: isCardShowing ? (panel.cardOnRight ? 0 : 20) : 20,
                topTrailingRadius: isCardShowing ? (panel.cardOnRight ? 0 : 20) : 20,
                style: .continuous
            )
            .fill(Notch.body)
        )
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 6)
                if let countdown = headerResetCountdown(for: provider) {
                    Text("Resets in \(countdown)")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(Notch.subtext)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }

            // Service status badge for anything but operational. Unknown gets
            // its neutral badge rather than silence: an unreadable check is
            // information, not health.
            if let status = coordinator.statuses[provider]?.value,
               status.severity != .operational {
                StatusBadge(severity: status.severity)
            }

            // Rate limit and usage windows (including OpenRouter's account balance / limit)
            let groups = quota?.groups ?? []
            if groups.count > 1 {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(groups, id: \.id) { group in
                        VStack(alignment: .leading, spacing: 5) {
                            if !group.title.isEmpty {
                                Text(group.title)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(Notch.subtext)
                            }
                            ForEach(Array(group.windows.enumerated()), id: \.offset) { _, window in
                                windowRow(window: window, quota: quota, provider: provider)
                            }
                        }
                    }
                }
            } else {
                let windows = Self.effectiveWindows(for: provider, quota: quota)
                if !windows.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                            windowRow(window: window, quota: quota, provider: provider)
                        }
                    }
                } else if let quota, let credits = quota.credits {
                    fallbackCreditsSection(credits: credits, provider: provider)
                }
            }

            // Usage limit resets (Codex)
            if showSideNotchResetButton,
               provider == .codex,
               let quota,
               (quota.resetCreditCount ?? 0) > 0 || !quota.resetCredits.isEmpty {
                resetCreditsSection(quota: quota)
            }

            // Activity Telemetry 2-column grid
            if showActivityTelemetry, let tel = telemetry(for: provider) {
                telemetryView(tel: tel, provider: provider)
            } else if let tokenUsage = tokenUsage(for: provider),
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

            // 30-day activity histogram
            if showDailyActivityChart, let tel = telemetry(for: provider), tel.dailyHistory.count >= 7 {
                dailyActivityChart(history: tel.dailyHistory, provider: provider)
            }

            Spacer(minLength: 0)

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
        .frame(width: SideNotchPanelLayout.cardWidth)
        .frame(minHeight: stripHeight > 0 ? stripHeight : nil, alignment: .top)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: CardHeightKey.self, value: proxy.size.height)
            }
        )
        .background(
            // Square on the strip side: the card docks flush against the
            // strip with no transparent gap, so no desktop hairline can show
            // through between them. Mirrored with the side: round outside,
            // square at the joint. The beak straddles the remaining tonal
            // step between the two blacks.
            UnevenRoundedRectangle(
                topLeadingRadius: panel.cardOnRight ? 0 : 16,
                bottomLeadingRadius: panel.cardOnRight ? 0 : 16,
                bottomTrailingRadius: panel.cardOnRight ? 16 : 0,
                topTrailingRadius: panel.cardOnRight ? 16 : 0,
                style: .continuous
            )
            .fill(Notch.card)
        )
    }

    @ViewBuilder
    private func windowRow(window: QuotaWindow, quota: ProviderQuota?, provider: Provider) -> some View {
        let pace = showPacingBurnRate ? window.pace(now: coordinator.clock) : nil
        let figure = Self.windowFigure(window: window, quota: quota, provider: provider)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(windowDisplayTitle(for: window, provider: provider))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Notch.text)
                    .lineLimit(1)
                Spacer()
                if let resetsAt = window.resetsAt {
                    Text("Resets \(Fmt.absoluteMoment(resetsAt, now: coordinator.clock))")
                        .font(.system(size: 10.5, weight: .regular))
                        .foregroundColor(Notch.subtext)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                } else if case .spent = figure, let credits = quota?.credits {
                    Text("\(Fmt.usd(credits.balance)) available")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(Notch.subtext)
                        .lineLimit(1)
                }
            }

            // Fixed-width track so layout never collapses or jumps
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Notch.track)
                    .frame(width: 222, height: 4)
                Capsule(style: .continuous)
                    .fill(Notch.color(usedPercent: window.usedPercent))
                    .frame(width: max(222 * window.fraction.clamped(to: 0...1), window.fraction > 0 ? 3 : 0), height: 4)
            }

            if let pace {
                HStack(spacing: 4) {
                    Text("\(Fmt.percent(window.usedPercent)) Used")
                        .foregroundColor(Notch.text)
                    Text("·")
                        .foregroundColor(Notch.subtext)
                    Text("\(Fmt.percent(pace.remainingPercent)) left")
                        .foregroundColor(Notch.subtext)
                    Text("·")
                        .foregroundColor(Notch.subtext)
                    Text(pace.statusText(usedPercent: window.usedPercent))
                        .foregroundColor(pace.status.isDeficit ? Notch.deficit : (pace.status.isSurplus ? Notch.surplus : Notch.subtext))
                        .fontWeight(pace.status.isDeficit ? .semibold : .regular)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10.5, weight: .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            } else {
                HStack(spacing: 4) {
                    Text("\(Fmt.percent(window.usedPercent)) Used")
                        .foregroundColor(Notch.text)
                    Text("·")
                        .foregroundColor(Notch.subtext)
                    if case let .spent(used, limit) = figure {
                        if let limit, limit > 0 {
                            Text("Spent \(Fmt.usd(used)) of \(Fmt.usd(limit))")
                                .foregroundColor(Notch.subtext)
                        } else {
                            Text("Spent \(Fmt.usd(used))")
                                .foregroundColor(Notch.subtext)
                        }
                    } else if case let .remaining(percent) = figure {
                        Text("\(Fmt.percent(percent)) left")
                            .foregroundColor(Notch.subtext)
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10.5, weight: .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
        }
    }

    @ViewBuilder
    private func fallbackCreditsSection(credits: CreditBalance, provider: Provider) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(provider == .openRouter ? "Account balance" : "Credits")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Notch.text)
                    .lineLimit(1)
                Spacer()
                Text(credits.unit == .dollars ? Fmt.usd(credits.balance) : Fmt.credits(credits.balance))
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(Notch.subtext)
                    .lineLimit(1)
            }
            if let used = credits.usedDollars {
                Text("Spent \(Fmt.usd(used))")
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundColor(Notch.subtext)
            }
        }
    }

    private func telemetry(for provider: Provider) -> ProviderTelemetry? {
        if let tel = coordinator.usages[provider]?.value?.telemetry {
            return tel
        }
        if let tel = coordinator.activities[provider]?.value?.telemetry {
            return tel
        }
        return nil
    }

    private func telemetryView(tel: ProviderTelemetry, provider: Provider) -> some View {
        let col1: [(String, String)]
        let col2: [(String, String)]

        if tel.lifetimeTokens != nil {
            col1 = [
                tel.lifetimeTokens.map { ("Lifetime tokens", Fmt.telemetryTokens($0)) },
                (tel.longestStreakDays > 0 ? ("Longest streak", Fmt.streakDays(tel.longestStreakDays)) : nil),
                tel.last30DaysTokens.map { ("30-day tokens", Fmt.telemetryTokens($0)) }
            ].compactMap { $0 }

            col2 = [
                tel.peakDailyTokens.map { ("Peak tokens", Fmt.telemetryTokens($0)) },
                (tel.currentStreakDays > 0 ? ("Current streak", Fmt.streakDays(tel.currentStreakDays)) : nil),
                tel.todayTokens.map { ("Today", Fmt.telemetryTokens($0)) }
            ].compactMap { $0 }
        } else {
            col1 = [
                tel.totalSessions.map { ("Total sessions", Fmt.count($0)) },
                (tel.longestStreakDays > 0 ? ("Longest streak", Fmt.streakDays(tel.longestStreakDays)) : nil)
            ].compactMap { $0 }

            col2 = [
                tel.totalMessages.map { ("Total messages", Fmt.count($0)) },
                (tel.currentStreakDays > 0 ? ("Current streak", Fmt.streakDays(tel.currentStreakDays)) : nil),
                tel.todaySessions.map { ("Today", $0 == 1 ? "1 session" : "\($0) sessions") }
            ].compactMap { $0 }
        }

        return HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(col1, id: \.0) { label, value in
                    VStack(alignment: .leading, spacing: 1.5) {
                        Text(label)
                            .font(.system(size: 9.5, weight: .regular))
                            .foregroundColor(Notch.subtext)
                        Text(value)
                            .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                            .foregroundColor(Notch.text)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(col2, id: \.0) { label, value in
                    VStack(alignment: .leading, spacing: 1.5) {
                        Text(label)
                            .font(.system(size: 9.5, weight: .regular))
                            .foregroundColor(Notch.subtext)
                        Text(value)
                            .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                            .foregroundColor(Notch.text)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 222)
    }

    private func dailyActivityChart(history: [DailyVolumePoint], provider: Provider) -> some View {
        let maxTokens = history.map(\.tokens).max() ?? 0
        let maxSessions = history.map(\.sessionCount).max() ?? 0
        let usesTokens = maxTokens > 0
        let peakValue = Double(usesTokens ? maxTokens : maxSessions)
        let safeMax = peakValue > 0 ? peakValue : 1.0

        return HStack(alignment: .bottom, spacing: 2.2) {
            ForEach(Array(history.enumerated()), id: \.offset) { index, point in
                let value = Double(usesTokens ? point.tokens : point.sessionCount)
                let heightFrac = max(0.08, min(1.0, value / safeMax))
                let isToday = index == history.count - 1
                let hasActivity = value > 0

                RoundedRectangle(cornerRadius: 1.2, style: .continuous)
                    .fill(
                        isToday
                            ? providerColor(provider)
                            : (hasActivity ? Notch.subtext.opacity(0.85) : Notch.track.opacity(0.6))
                    )
                    .frame(width: 5, height: heightFrac * 22)
            }
        }
        .frame(width: 222, height: 24, alignment: .bottom)
        .padding(.vertical, 2)
    }

    // MARK: - Geometry helpers

    static func ringCenterY(for provider: Provider, in entries: [Entry]) -> CGFloat {
        guard let index = entries.firstIndex(where: { $0.provider == provider }) else {
            return 19
        }
        return 19 + CGFloat(index) * 43
    }

    /// Beak height on the card. The card always starts at the top edge, so
    /// this is just the ring's center less half the beak.
    static func beakYOnCard(for provider: Provider, in entries: [Entry]) -> CGFloat {
        ringCenterY(for: provider, in: entries) - 6
    }

    static func isBeakWithinBounds(beakY: CGFloat, cardHeight: CGFloat) -> Bool {
        beakY >= 0 && cardHeight >= (beakY + 12)
    }

    private func ringCenterY(for provider: Provider) -> CGFloat {
        Self.ringCenterY(for: provider, in: entries)
    }

    private func beakYOnCard(for provider: Provider) -> CGFloat {
        Self.beakYOnCard(for: provider, in: entries)
    }

    private func windowDisplayTitle(for window: QuotaWindow, provider: Provider) -> String {
        if provider == .codex && (window.label == "5-hour" || window.label.lowercased().contains("session")) {
            return "Current session"
        }
        // A key spending limit stays a spending limit: only the legacy
        // "Credits" label (the synthesized account window is now emitted as
        // "Account balance") is an account balance. Retitling a key window
        // would pair an account-balance heading with key-limit figures.
        if provider == .openRouter && window.label == "Credits" {
            return "Account balance"
        }
        return window.label
    }

    // MARK: - Reset credits

    @ViewBuilder
    private func resetCreditsSection(quota: ProviderQuota) -> some View {
        let count = quota.resetCreditCount ?? quota.resetCredits.count
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Usage limit resets")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Notch.text)
                Spacer(minLength: 4)
                Text("\(count) available")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(Notch.subtext)
            }

            if let statusMsg = resetStatusMessage {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Notch.surplus)
                    Text(statusMsg)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(Notch.surplus)
                }
                .padding(.vertical, 2)
            } else if let errorMsg = resetErrorMessage {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(Notch.deficit)
                    Text(errorMsg)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(Notch.deficit)
                }
                .padding(.vertical, 2)
            }

            if quota.resetCredits.isEmpty {
                if count > 0 && resetStatusMessage == nil && resetErrorMessage == nil {
                    Text("\(count) reset credit\(count == 1 ? "" : "s") available")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(Notch.subtext)
                }
            } else {
                ForEach(Array(quota.resetCredits.enumerated()), id: \.element.id) { idx, credit in
                    let available = isAvailable(credit)
                    let isConfirming = confirmingResetID == credit.id
                    let isConsuming = consumingResetID == credit.id

                    if idx > 0 {
                        Divider()
                            .overlay(Notch.track.opacity(0.6))
                    }

                    HStack(alignment: .center, spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(credit.title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Notch.text)
                                .lineLimit(1)
                            if let expiresAt = credit.expiresAt {
                                Text("Expires \(Fmt.expiryMoment(expiresAt))")
                                    .font(.system(size: 9.5, weight: .regular))
                                    .foregroundColor(Notch.subtext)
                                    .lineLimit(1)
                            }
                        }

                        Spacer(minLength: 4)

                        if isConsuming {
                            HStack(spacing: 4) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Resetting...")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(Notch.subtext)
                            }
                        } else if isConfirming {
                            HStack(spacing: 4) {
                                Button {
                                    executeReset(creditID: credit.id)
                                } label: {
                                    Text("Confirm")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2.5)
                                        .background(
                                            Capsule(style: .continuous)
                                                .fill(Color(red: 0.85, green: 0.2, blue: 0.2))
                                        )
                                }
                                .buttonStyle(.plain)

                                Button {
                                    confirmingResetID = nil
                                } label: {
                                    Text("Cancel")
                                        .font(.system(size: 10, weight: .regular))
                                        .foregroundColor(Notch.subtext)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 2.5)
                                }
                                .buttonStyle(.plain)
                            }
                        } else if available {
                            Button {
                                confirmingResetID = credit.id
                            } label: {
                                Text("Use reset")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(Notch.text)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2.5)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(Notch.track)
                                    )
                            }
                            .buttonStyle(.plain)
                            .disabled(consumingResetID != nil || !coordinator.canUseCodexReset)
                        } else {
                            Text(statusLabel(for: credit))
                                .font(.system(size: 9.5, weight: .regular))
                                .foregroundColor(Notch.subtext)
                        }
                    }
                    .padding(.vertical, 2)
                }

                if quota.resetCredits.count < count {
                    Text("\(count - quota.resetCredits.count) more available")
                        .font(.system(size: 9.5, weight: .regular))
                        .foregroundColor(Notch.subtext)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    private func isAvailable(_ credit: QuotaResetCredit) -> Bool {
        guard credit.status?.lowercased() == "available" || credit.status == nil else { return false }
        guard let expiresAt = credit.expiresAt else { return true }
        return expiresAt > coordinator.clock
    }

    private func statusLabel(for credit: QuotaResetCredit) -> String {
        guard let status = credit.status, !status.isEmpty else { return "Available" }
        return status.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func executeReset(creditID: String) {
        confirmingResetID = nil
        consumingResetID = creditID
        resetErrorMessage = nil
        resetStatusMessage = nil
        Task { @MainActor in
            do {
                try await coordinator.consumeCodexReset(creditID: creditID)
                consumingResetID = nil
                resetStatusMessage = "Reset applied ✓"
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if resetStatusMessage == "Reset applied ✓" {
                        resetStatusMessage = nil
                    }
                }
            } catch {
                consumingResetID = nil
                resetErrorMessage = "Reset failed. Try again."
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if resetErrorMessage == "Reset failed. Try again." {
                        resetErrorMessage = nil
                    }
                }
            }
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

    /// The secondary figure a window row shows beside its used percent. The
    /// credit-spend case is reserved for OpenRouter's synthesized account
    /// balance window; a key-limit window is a different budget scope and must
    /// not quote the account figures even when a credits reading is present.
    enum WindowFigure: Equatable {
        case spent(used: Double, limit: Double?)
        case remaining(percent: Double)
    }

    static func entries(
        menuBarProviders: [Provider],
        quotas: [Provider: Loaded<ProviderQuota>],
        statuses: [Provider: Loaded<ServiceStatus>],
        archivedQuotas: [Provider: ProviderQuota] = [:]
    ) -> [Entry] {
        entries(providers: menuBarProviders, quotas: quotas, statuses: statuses, archivedQuotas: archivedQuotas)
    }

    static func entries(
        providers: [Provider],
        quotas: [Provider: Loaded<ProviderQuota>],
        statuses: [Provider: Loaded<ServiceStatus>],
        archivedQuotas: [Provider: ProviderQuota] = [:]
    ) -> [Entry] {
        providers.compactMap { provider in
            let live = quotas[provider]?.value
            let quota = live ?? archivedQuotas[provider]
            let windows = effectiveWindows(for: provider, quota: quota)
            guard let window = provider.headlineWindow(from: windows)
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
            providers: coordinator.sideNotchProviders,
            quotas: coordinator.quotas,
            statuses: coordinator.statuses,
            archivedQuotas: coordinator.archivedQuotas
        )
    }

    /// OpenRouter is pay-as-you-go: without a key limit its quota reports no
    /// window, so the ring falls back to a credits-spend meter when purchased
    /// credits and spend are known — the same ratio the dashboard's CreditsRow
    /// renders. A provider with a real limit window keeps using it.
    static func creditWindow(for quota: ProviderQuota?, provider: Provider) -> QuotaWindow? {
        guard provider == .openRouter,
              let credits = quota?.credits,
              credits.unit == .dollars,
              let used = credits.usedDollars,
              let limit = credits.limitDollars, limit > 0
        else { return nil }
        return QuotaWindow(
            label: "Account balance",
            usedPercent: min((used / limit) * 100, 100),
            resetsAt: nil
        )
    }

    /// Effective rate limit and usage windows for a provider. If the quota
    /// already specifies windows (e.g. Codex, Claude, Grok, OpenCode, or
    /// OpenRouter with an explicit key limit), those are returned. For
    /// OpenRouter without a key limit, this synthesizes a window from account
    /// credit spend so the detail card renders the exact same usage bar.
    static func effectiveWindows(for provider: Provider, quota: ProviderQuota?) -> [QuotaWindow] {
        guard let quota else { return [] }
        if !quota.windows.isEmpty {
            return quota.windows
        }
        if let creditWindow = creditWindow(for: quota, provider: provider) {
            return [creditWindow]
        }
        return []
    }

    /// Picks the secondary figure a window row shows. Account credits are only
    /// consulted for the synthesized "Account balance" window, which exists
    /// exactly when OpenRouter reports no key-limit window of its own. Every
    /// other window reports its own headroom, so a key limit and an account
    /// credit balance never appear as one mixed reading.
    static func windowFigure(window: QuotaWindow, quota: ProviderQuota?, provider: Provider) -> WindowFigure {
        let isAccountBalanceWindow = provider == .openRouter
            && window.label == "Account balance"
            && quota?.windows.isEmpty == true
        if isAccountBalanceWindow, let used = quota?.credits?.usedDollars {
            return .spent(used: used, limit: quota?.credits?.limitDollars)
        }
        return .remaining(percent: max(100 - window.usedPercent, 0))
    }

    private func accessibilityRingText(for entry: Entry) -> String {
        "\(entry.provider.displayName) \(Fmt.percent(entry.usedPercent)) used\(entry.isStale ? ", last known reading" : "")"
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
                .stroke(Notch.track, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: fraction.clamped(to: 0...1))
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            ProviderMark(provider: provider, tint: markTint)
                .frame(width: 9, height: 9)
                // A hit limit dims the glyph: the full orange ring already
                // carries the state, and the mark steps back.
                .opacity(fraction >= 1 ? 0.5 : 1.0)
        }
        .frame(width: 26, height: 26)
        // A ring that jumps reads as a glitch; one that sweeps reads as a
        // measurement.
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.65), value: fraction)
    }
}
