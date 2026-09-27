import SwiftUI
import AppKit

// MARK: - Notch palette
//
// The side panel is a hardware-like object with a dark-grey body (not black),
// carrying the accent theme: the body, card, and ring disc/track are mixed
// toward the selected accent, so the strip's whole colour follows the theme
// instead of staying neutral. The ring band, text, and provider marks keep
// their own semantics — headroom stays green/amber/red and provider identity
// stays the provider's own colour — so only the chrome moves with the theme.
// Because every mix keeps luminance fixed (see `blend`), the white figures and
// status bands stay legible on any accent. Each colour is resolved once per
// theme (`AccentTheme.color` is cached), so the ring views can index the table
// directly without re-resolving a dynamic colour on every redraw.

/// Ring state band. The thresholds and the hues are the app's own headroom
/// scale (`headroomColor`): the notch previously used its own 50/80/100 bands
/// and its own vivid palette, so a 75% window read green here and amber in the
/// popover, and nothing followed an accent change. Delegating to `headroomColor`
/// makes severity, colour, and theme agree on every surface.
enum NotchBand: Equatable {
    case plenty
    case gettingClose
    case nearlyOut
    case atLimit

    static func band(usedPercent: Double) -> NotchBand {
        switch usedPercent {
        case ..<80:  return .plenty
        case ..<95:  return .gettingClose
        case ..<100: return .nearlyOut
        default:     return .atLimit
        }
    }
}

/// Perceptual luminance (Rec. 709), the axis the notch chrome must hold.
///
/// Two colours with the same max channel can look very different in brightness:
/// a saturated hue at a fixed max channel reads far darker than a neutral grey
/// at that channel. The chrome is compared against the popover's grey surfaces
/// and read as text behind, so it is luminance — not max channel — that has to
/// stay put or the tinted themes render darker than the window beside them.
private func relativeLuminance(_ c: (r: CGFloat, g: CGFloat, b: CGFloat)) -> CGFloat {
    func lin(_ v: CGFloat) -> CGFloat {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
}

/// Blends a neutral `base` toward `tint` at the base's own luminance.
///
/// The notch keeps a dark-grey body that must stay the same dark grey as the
/// popover — not black, not darker — and white figures that must stay legible on
/// every accent. The mix takes the accent's hue and saturation, then rescales
/// the result to the base's luminance so a saturated theme lands at the same
/// perceived brightness as the neutral it replaced. Without that rescale, a blue
/// or teal body rendered below the popover's grey, which is what made the strip
/// look black and the themes "not match".
private func blendTinted(_ base: (r: CGFloat, g: CGFloat, b: CGFloat),
                         with tint: NSColor,
                         amount: CGFloat) -> Color {
    let tintColor = tint.usingColorSpace(.sRGB) ?? NSColor.black
    var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
    tintColor.getHue(&h, saturation: &s, brightness: &v, alpha: &a)

    // Start from the base's own hue-saturation-value.
    var bh: CGFloat = 0, bs: CGFloat = 0, bv: CGFloat = 0, ba: CGFloat = 0
    NSColor(srgbRed: base.r, green: base.g, blue: base.b, alpha: 1)
        .getHue(&bh, saturation: &bs, brightness: &bv, alpha: &ba)

    // Take the accent's hue, pull its saturation in by `amount`, and keep the
    // base's brightness as the starting point.
    let mixed = NSColor(hue: h, saturation: min(1, s * amount), brightness: bv, alpha: 1)
        .usingColorSpace(.sRGB) ?? NSColor.black

    // Rescale to the base's luminance: nudge brightness up or down so the tinted
    // chrome is exactly as bright as the neutral it stands in for.
    let target = relativeLuminance(base)
    var lo: CGFloat = 0, hi: CGFloat = 1
    for _ in 0..<20 {
        let mid = (lo + hi) / 2
        let candidate = NSColor(hue: h, saturation: min(1, s * amount), brightness: mid, alpha: 1)
            .usingColorSpace(.sRGB) ?? .black
        let l = relativeLuminance((candidate.redComponent, candidate.greenComponent, candidate.blueComponent))
        if l < target { lo = mid } else { hi = mid }
    }
    let adjusted = NSColor(hue: h, saturation: min(1, s * amount), brightness: (lo + hi) / 2, alpha: 1)
        .usingColorSpace(.sRGB) ?? mixed
    return Color(red: Double(adjusted.redComponent), green: Double(adjusted.greenComponent), blue: Double(adjusted.blueComponent))
}

enum Notch {

    // Neutrals the accent is mixed into. These start from the popover's own
    // dark surface values (`MU.canvas` / `MU.surface` / `MU.well`) so the strip
    // is the same dark grey as the window beside it, then the accent is mixed
    // in on top. A body that started darker than the popover was what made the
    // strip read as black next to the window.
    private static let bodyBase: (r: CGFloat, g: CGFloat, b: CGFloat) = (28/255, 28/255, 30/255)
    private static let cardBase: (r: CGFloat, g: CGFloat, b: CGFloat) = (38/255, 38/255, 41/255)
    private static let discBase: (r: CGFloat, g: CGFloat, b: CGFloat) = (52/255, 52/255, 56/255)
    private static let trackBase: (r: CGFloat, g: CGFloat, b: CGFloat) = (64/255, 64/255, 68/255)

    /// The accent each chrome colour is derived from, in theme order matching
    /// `AccentTheme.allCases`. Resolved once; `AccentTheme.color` is cached, so
    /// indexing the table in a ring view costs nothing per redraw.
    static let body = chrome(AccentTheme.allCases.map { blendTinted(bodyBase, with: $0.light, amount: 0.55) })
    static let card = chrome(AccentTheme.allCases.map { blendTinted(cardBase, with: $0.light, amount: 0.55) })
    static let disc = chrome(AccentTheme.allCases.map { blendTinted(discBase, with: $0.light, amount: 0.50) })
    static let track = chrome(AccentTheme.allCases.map { blendTinted(trackBase, with: $0.light, amount: 0.50) })

    /// A chrome colour table indexed by `AccentTheme.allCases`. Callers pass the
    /// accent in (from the observed `preferences`) rather than reading a global,
    /// so a themed view can never resolve a different accent than its neighbour.
    struct chrome {
        let colors: [Color]
        init(_ colors: [Color]) { self.colors = colors }
        subscript(index: Int) -> Color { colors[min(max(index, 0), colors.count - 1)] }
    }

    static let text = Color.white
    static let subtext = Color(white: 1, opacity: 0.55)

    // The notch shows the app's own headroom scale, not a private palette:
    // status text, banners, and ring bands all resolve through `headroomColor`
    // so a reading looks the same here as in the popover and menu bar.
    static var deficit: Color { MU.warn }
    static var surplus: Color { MU.good }

    static func color(usedPercent: Double) -> Color {
        headroomColor(usedPercent)
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

/// The detail card's Share button as a real `NSButton`.
///
/// A clicked button is definitionally in a window, so the click handler can
/// hand the button itself to `NSSharingServicePicker.show(relativeTo:of:)` —
/// no cached view, no screen-coordinate conversion, no stale-reference race.
/// (The previous attempt cached the backing view of a SwiftUI Button in
/// `@State`; the card rebuilds on every hover and countdown tick, so the
/// cached view was usually detached at click time and the menu fell back to
/// whole-panel anchoring — the detached menu this replaces.)
///
/// Styled to match the surrounding SwiftUI header: borderless 10pt medium
/// symbol in notch subtext.
private struct ShareButton: NSViewRepresentable {
    var onShare: (NSView) -> Void

    final class Coordinator: NSObject {
        var onShare: (NSView) -> Void

        init(onShare: @escaping (NSView) -> Void) {
            self.onShare = onShare
        }

        @objc func clicked(_ sender: NSButton) {
            onShare(sender)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onShare: onShare)
    }

    func makeNSView(context: Context) -> NSButton {
        let symbol = NSImage(
            systemSymbolName: "square.and.arrow.up",
            accessibilityDescription: "Share screenshot"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        ) ?? NSImage()
        let button = NSButton(
            image: symbol,
            target: context.coordinator,
            action: #selector(Coordinator.clicked(_:))
        )
        button.isBordered = false
        button.contentTintColor = NSColor(white: 1.0, alpha: 0.55)
        button.toolTip = "Share screenshot"
        button.setAccessibilityLabel("Share screenshot")
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.onShare = onShare
        nsView.target = context.coordinator
    }
}

/// Hover-card identity. The provider slot alone is not enough: the card's
/// chrome is themed, so an accent change must invalidate it or the card keeps
/// the previous theme while the strip beside it recolours.
private struct CardIdentity: Hashable {
    let slot: ProviderSlot
    let accent: AccentTheme
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
// headroom, and the mark keeps its identity colour unless the service status
// recolours it. A provider with no headline reading is skipped rather than
// drawn as an empty ring.
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
    /// Observed so a changed accent re-renders the strip and its cards: the
    /// primary mark and every `MU.accent`-based figure follow the palette.
    @ObservedObject var preferences: Preferences
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
    @State private var hoveredSlot: ProviderSlot?
    @State private var isHoveringPanel = false
    @State private var confirmingResetID: String?
    @State private var consumingResetID: String?
    /// The slot a pending reset belongs to, so a card pinned open by a
    /// confirmation keeps showing *that* account even after the pointer
    /// leaves — with two Codex accounts, the primary card would be the
    /// wrong one.
    @State private var resetSlot: ProviderSlot?
    @State private var resetStatusMessage: String?
    @State private var resetErrorMessage: String?
    @State private var stripHeight: CGFloat = 0
    @State private var cardHeight: CGFloat = 0
    /// Tallest card measured this session. The card column never shrinks
    /// below it, so sweeping hover across providers never resizes the
    /// window: short cards show quiet empty space instead of everyone
    /// flapping. Resets when the provider set changes; otherwise a removed
    /// provider's ghost height would linger all session. Stored rounded up
    /// to whole points so the panel frame stays on the pixel grid.
    @State private var maxCardHeight: CGFloat = 0
    /// Collapse hysteresis: a pointer exit schedules collapse, but a
    /// re-enter before the delay fires cancels it. 450ms — deliberately
    /// longer than a tooltip grace, so the fold never feels twitchy.
    @State private var collapseTask: Task<Void, Never>?

    /// The selected accent's index into `Notch`'s chrome tables.
    ///
    /// Taken from the observed `preferences`, not from `UserDefaults` directly:
    /// the strip chrome and the hover-card identity must resolve the accent from
    /// one source, or a change between them can leave the card on the old theme
    /// while the strip recolours.
    private var accentIndex: Int {
        AccentTheme.allCases.firstIndex(of: preferences.accentTheme) ?? 0
    }

    /// Unfolded while pinned, while the pointer is on the panel, or while a
    /// reset action / confirmation is active.
    private var isOpen: Bool {
        isPinned || isHoveringPanel || hoveredSlot != nil || confirmingResetID != nil || consumingResetID != nil
    }

    /// True when a detail card is actively showing beside the strip.
    private var isCardShowing: Bool {
        let activeHovered = hoveredSlot
            ?? ((confirmingResetID != nil || consumingResetID != nil) ? resetSlot : nil)
        return !panel.isDragging && activeHovered != nil && entries.contains(where: { $0.slot == activeHovered })
    }

    var body: some View {
        if #available(macOS 15.0, *) {
            panelContent.simultaneousGesture(
                WindowDragGesture()
                    .onChanged { _ in panel.isDragging = true }
                    .onEnded { _ in panel.endDrag() }
            )
        } else {
            panelContent
        }
    }

    private var panelContent: some View {
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
        // Pin the content to the top of the window. The window is sized from
        // the measurement above, but AppKit rounds a fractional frame up to
        // whole points, so the window can be up to a point taller than the
        // content. Left alone, SwiftUI centers that leftover split above and
        // below, and because only some cards have a fractional height (Grok,
        // OpenRouter) those cards drew a pixel off from the integral ones.
        // Top-anchoring keeps the visible top edge on one row and pushes any
        // leftover below the card's own black edge, where it cannot be seen.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: panel.cardOnRight ? .topLeading : .topTrailing)
        // The panel is always on screen, so unlike the popover it never
        // refreshes on open: unfolding is the moment the numbers are read.
        // Refresh then (the same 20-second staleness guard the popover uses)
        // instead of showing a reading up to a full sweep interval old.
        .onChange(of: isOpen) { open in
            if open { coordinator.refreshIfStale() }
        }
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
            hoveredSlot = nil
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
            let height = size.height.rounded(.up)
            stripHeight = height
            onStripSizeChange(CGSize(width: SideNotchPanelLayout.stripWidth, height: height))
        }
        .onPreferenceChange(CardHeightKey.self) { height in
            let whole = height.rounded(.up)
            cardHeight = whole
            if whole > maxCardHeight { maxCardHeight = whole }
        }
        .onChange(of: entries.map(\.slot.key)) { _ in
            maxCardHeight = 0
        }
        .onChange(of: panel.isDragging) { dragging in
            // A drop can strand a hover from before the drag (the mouse never
            // re-enters to refresh it): always reopen from a clean hover.
            if !dragging && confirmingResetID == nil && consumingResetID == nil {
                hoveredSlot = nil
            }
        }
    }

    /// Hover card docked beside the strip — left on a right-parked strip,
    /// right once the strip crosses to the left half of the screen. Hidden
    /// while dragging: a slim strip tracks the cursor, and the side settles
    /// on drop.
    @ViewBuilder
    private var cardColumn: some View {
        let activeHovered = hoveredSlot
            ?? ((confirmingResetID != nil || consumingResetID != nil) ? resetSlot : nil)
        if !panel.isDragging,
           let hovered = activeHovered,
           entries.contains(where: { $0.slot == hovered }) {
            let beakY = beakYOnCard(for: hovered)
            let effectiveHeight = max(cardHeight, stripHeight)
            let isBeakWithinBounds = Self.isBeakWithinBounds(beakY: beakY, cardHeight: effectiveHeight)
            detailCard(for: hovered)
                // Identity includes the accent, not just the provider: a card
                // keyed on the slot alone is reused across an accent change and
                // keeps its old chrome while the strip recolours, so the two
                // halves of one object show different themes.
                .id(CardIdentity(slot: hovered, accent: preferences.accentTheme))
                .accessibilityElement(children: .contain)
                .overlay(alignment: panel.cardOnRight ? .topLeading : .topTrailing) {
                    if isBeakWithinBounds {
                        ArrowBeakView(accent: preferences.accentTheme)
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
                    // An additional account's dot carries a thin outline so
                    // two dots of one tool don't read as a duplicate.
                    .overlay(
                        entry.digit != nil
                            ? Circle().strokeBorder(Notch.text.opacity(0.7), lineWidth: 1)
                            : nil
                    )
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
                .fill(Notch.body[accentIndex])
        )
        .overlay(
            // The one border in the notch: without it the resting pill
            // vanishes into dark wallpapers. Track-grey keeps it a whisper.
            Capsule(style: .continuous)
                .strokeBorder(Notch.track[accentIndex], lineWidth: 1)
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

    static func stripReading(for entry: Entry) -> some View {
        Text(entry.primaryText)
            .font(.system(size: 9, weight: .semibold).monospacedDigit())
            .foregroundColor(Notch.text)
            .lineLimit(1)
            .minimumScaleFactor(entry.usedPercent == nil ? 0.6 : 1)
            .frame(maxWidth: SideNotchPanelLayout.stripWidth - 12)
    }

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
                            slot: entry.slot,
                            digit: entry.digit,
                            markTint: entry.markTint,
                            accent: preferences.accentTheme,
                            reduceMotion: reduceMotion
                        )
                        Self.stripReading(for: entry)
                        if let eta = entry.etaText {
                            Text(eta)
                                .font(.system(size: 7.5, weight: .bold).monospacedDigit())
                                .foregroundColor(entry.isDeficit ? Notch.deficit : Notch.subtext)
                                .lineLimit(1)
                        }
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
                    .accessibilityLabel(entry.accessibilityText)
                    .help(entry.accessibilityText)
                    .accessibilityAction(named: "Show details") {
                        cancelFold()
                        isHoveringPanel = true
                        hoveredSlot = entry.slot
                    }
                    .accessibilityAction(named: "Hide details") {
                        hoveredSlot = nil
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
                            hoveredSlot = entry.slot
                        }
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        // Whole-point frames: the intrinsic width came out fractional (42.5pt
        // from the 7.5pt ETA text) and the intrinsic height off the stacked
        // 9pt/7.5pt lines, either of which puts the panel frame off the pixel
        // grid so the window server snaps it a pixel off. A constant width
        // and a ceilinged height keep every frame integral.
        .frame(
            width: SideNotchPanelLayout.stripWidth,
            height: stripHeight > 0 ? stripHeight : nil
        )
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
            .fill(Notch.body[accentIndex])
        )
    }

    // MARK: - Detail card for hovered provider

    func detailCard(for slot: ProviderSlot) -> some View {
        // The card follows the ring: live reading when present, otherwise
        // the archived last-good reading, dated as such.
        let display = coordinator.displayQuota(for: slot)
        let quota = display?.quota
        let isStale = display?.isStale ?? false
        return VStack(alignment: .leading, spacing: 10) {
            // Header: icon, "[Provider · account] Usage", and reset countdown
            HStack(alignment: .center, spacing: 8) {
                ProviderMark(provider: slot.provider, tint: providerColor(slot.provider))
                    .frame(width: 14, height: 14)
                Text("\(slot.displayName) Usage")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Notch.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 6)
                if let countdown = headerResetCountdown(for: slot) {
                    Text("Resets in \(countdown)")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(Notch.subtext)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                let panel = panel
                ShareButton { [weak panel] view in
                    panel?.shareSnapshot(anchoredAt: view)
                }
                .frame(width: 18, height: 18)
                .help("Share screenshot")
                .accessibilityLabel("Share screenshot")
            }

            // Service status badge for anything but operational. Unknown gets
            // its neutral badge rather than silence: an unreadable check is
            // information, not health. Health is per service, so every
            // account of one tool shares the check.
            if let status = coordinator.status(for: slot.provider)?.value,
               status.severity != .operational {
                StatusBadge(severity: status.severity)
            }

            if slot.provider == .openAI {
                ProviderUsageRow(provider: .openAI, state: coordinator.usages[slot] ?? .idle, now: coordinator.clock)
                    .detail
                    .environment(\.colorScheme, .dark)
            }

            // Ambient Time-To-Empty banner. It reports the window's own pace:
            // a deficit empties before reset at that shape even when the burn
            // has since gone quiet. Only the present-tense "burning fast"
            // nudge and alerts are gated on burn recency.
            if let headline = slot.provider.headlineWindow(from: Self.effectiveWindows(for: slot.provider, quota: quota)),
               let pace = headline.pace(now: coordinator.clock),
               let etaText = pace.etaText(resetsAt: headline.resetsAt, now: coordinator.clock) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(etaText)
                            .font(.system(size: 13, weight: .bold).monospacedDigit())
                            .foregroundColor(pace.status.isDeficit ? Notch.deficit : Notch.surplus)
                        Text(Self.bannerSubtitle(pace: pace, usedPercent: headline.usedPercent))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Notch.subtext)
                    }
                    Spacer()
                    if let resetsAt = headline.resetsAt {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Reset")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundColor(Notch.subtext)
                            Text(Fmt.timeUntil(resetsAt, now: coordinator.clock) ?? "now")
                                .font(.system(size: 11, weight: .bold).monospacedDigit())
                                .foregroundColor(Notch.text)
                        }
                    }
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill((pace.status.isDeficit ? Notch.deficit : Notch.surplus).opacity(0.12))
                )
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
                                windowRow(window: window, quota: quota, provider: slot.provider, slot: slot)
                            }
                        }
                    }
                }
            } else {
                let windows = Self.effectiveWindows(for: slot.provider, quota: quota)
                if !windows.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                            windowRow(window: window, quota: quota, provider: slot.provider, slot: slot)
                        }
                    }
                } else if let quota, let credits = quota.credits {
                    fallbackCreditsSection(credits: credits, provider: slot.provider)
                }
            }

            // Usage limit resets (either Codex account)
            if showSideNotchResetButton,
               slot.provider == .codex,
               let quota,
               (quota.resetCreditCount ?? 0) > 0 || !quota.resetCredits.isEmpty {
                resetCreditsSection(slot: slot, quota: quota)
            }

            // Activity Telemetry 2-column grid
            if showActivityTelemetry, let tel = telemetry(for: slot) {
                telemetryView(tel: tel)
            } else if slot.provider != .openAI, let tokenUsage = tokenUsage(for: slot),
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
            if showDailyActivityChart, let tel = telemetry(for: slot), tel.dailyHistory.count >= 7 {
                dailyActivityChart(history: tel.dailyHistory, provider: slot.provider)
            }

            // Burn breakdown and context waste hints
            if let act = coordinator.activities[slot]?.value,
               let headline = slot.provider.headlineWindow(from: Self.effectiveWindows(for: slot.provider, quota: quota)),
               let breakdown = act.burnBreakdown(for: headline, now: coordinator.clock),
               !breakdown.contributors.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Active window burn")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Notch.text)
                        Spacer()
                        Text(Fmt.compactCount(breakdown.totalTokens) + " tokens")
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundColor(Notch.subtext)
                    }

                    ForEach(breakdown.contributors) { item in
                        HStack(spacing: 6) {
                            Text(item.projectName)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Notch.text)
                                .lineLimit(1)
                            Text("· " + Fmt.shortModel(item.model))
                                .font(.system(size: 10, weight: .regular))
                                .foregroundColor(Notch.subtext)
                                .lineLimit(1)
                            Spacer()
                            Text(Fmt.share(item.shareOfWindow))
                                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                                .foregroundColor(Notch.text)
                        }
                    }

                    // Numeric metadata waste hints
                    HStack(spacing: 8) {
                        if let hitRate = breakdown.cacheHitRate {
                            HStack(spacing: 3) {
                                Text("Cache:")
                                    .font(.system(size: 9.5, weight: .regular))
                                    .foregroundColor(Notch.subtext)
                                Text(String(format: "%.0f%%", hitRate))
                                    .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                                    .foregroundColor(hitRate >= 50 ? Notch.surplus : Notch.deficit)
                            }
                        }
                        if let avgTurns = breakdown.avgTokensPerTurn {
                            HStack(spacing: 3) {
                                Text("Avg/turn:")
                                    .font(.system(size: 9.5, weight: .regular))
                                    .foregroundColor(Notch.subtext)
                                Text(Fmt.compactCount(avgTurns))
                                    .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                                    .foregroundColor(Notch.text)
                            }
                        }
                        if breakdown.longChatCount > 0 {
                            Text("\(breakdown.longChatCount) long chats")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundColor(Notch.deficit)
                        }
                    }
                    .padding(.top, 2)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                )
            }

            Spacer(minLength: 0)

            // Timestamp: a remembered reading is dated by its own capture,
            // never by the last sweep — presenting it under "just now"
            // would be a lie.
            if isStale, let quota {
                Text("Last reading \(Fmt.timeSince(quota.capturedAt, now: coordinator.clock))")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(Notch.subtext)
            } else if slot.provider != .openAI, let last = coordinator.lastRefreshedAt {
                Text("Updated \(Fmt.timeSince(last, now: coordinator.clock))")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(Notch.subtext)
            }
        }
        .padding(14)
        .frame(width: SideNotchPanelLayout.cardWidth)
        .frame(minHeight: Self.stabilizedCardMinHeight(stripHeight: stripHeight, maxCardHeight: maxCardHeight), alignment: .top)
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
            .fill(Notch.card[accentIndex])
        )
    }

    @ViewBuilder
    private func windowRow(window: QuotaWindow, quota: ProviderQuota?, provider: Provider, slot: ProviderSlot) -> some View {
        // The row reports the window's own pace: a deficit means the window
        // is ahead of the even-burn line, and it carries the projected
        // exhaustion even when the burst that caused it has gone quiet.
        let pace = showPacingBurnRate
            ? window.pace(now: coordinator.clock)
            : nil
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
                    .fill(Notch.track[accentIndex])
                    .frame(width: 222, height: 4)
                Capsule(style: .continuous)
                    .fill(Notch.color(usedPercent: window.usedPercent))
                    .frame(width: max(222 * window.fraction.muClamped(to: 0...1), window.fraction > 0 ? 3 : 0), height: 4)
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

    private func telemetry(for slot: ProviderSlot) -> ProviderTelemetry? {
        if let tel = coordinator.usages[slot]?.value?.telemetry {
            return tel
        }
        if let tel = coordinator.activities[slot]?.value?.telemetry {
            return tel
        }
        return nil
    }

    private func telemetryView(tel: ProviderTelemetry) -> some View {
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
                            : (hasActivity ? Notch.subtext.opacity(0.85) : Notch.track[accentIndex].opacity(0.6))
                    )
                    .frame(width: 5, height: heightFrac * 22)
            }
        }
        .frame(width: 222, height: 24, alignment: .bottom)
        .padding(.vertical, 2)
    }

    // MARK: - Geometry helpers

    static func ringCenterY(for slot: ProviderSlot, in entries: [Entry]) -> CGFloat {
        guard let index = entries.firstIndex(where: { $0.slot == slot }) else {
            return 19
        }
        return 19 + CGFloat(index) * 43
    }

    /// Beak height on the card. The card always starts at the top edge, so
    /// this is just the ring's center less half the beak.
    static func beakYOnCard(for slot: ProviderSlot, in entries: [Entry]) -> CGFloat {
        ringCenterY(for: slot, in: entries) - 6
    }

    static func isBeakWithinBounds(beakY: CGFloat, cardHeight: CGFloat) -> Bool {
        beakY >= 0 && cardHeight >= (beakY + 12)
    }

    private func ringCenterY(for slot: ProviderSlot) -> CGFloat {
        Self.ringCenterY(for: slot, in: entries)
    }

    private func beakYOnCard(for slot: ProviderSlot) -> CGFloat {
        Self.beakYOnCard(for: slot, in: entries)
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
    private func resetCreditsSection(slot: ProviderSlot, quota: ProviderQuota) -> some View {
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
                            .overlay(Notch.track[accentIndex].opacity(0.6))
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
                                    executeReset(creditID: credit.id, slot: slot)
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
                                resetSlot = slot
                            } label: {
                                Text("Use reset")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(Notch.text)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2.5)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(Notch.track[accentIndex])
                                    )
                            }
                            .buttonStyle(.plain)
                            .disabled(consumingResetID != nil || !coordinator.canUseCodexReset(for: slot))
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

    private func executeReset(creditID: String, slot: ProviderSlot) {
        confirmingResetID = nil
        consumingResetID = creditID
        resetSlot = slot
        resetErrorMessage = nil
        resetStatusMessage = nil
        Task { @MainActor in
            do {
                try await coordinator.consumeCodexReset(creditID: creditID, in: slot)
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

    private func headerResetCountdown(for slot: ProviderSlot) -> String? {
        guard let quota = coordinator.displayQuota(for: slot)?.quota else { return nil }
        let windowsWithReset = quota.windows.compactMap { w -> (QuotaWindow, Date)? in
            guard let r = w.resetsAt, r > coordinator.clock else { return nil }
            return (w, r)
        }.sorted { $0.1 < $1.1 }

        guard let first = windowsWithReset.first else { return nil }
        return Fmt.timeUntil(first.1, now: coordinator.clock)
    }

    /// Ambient banner subtitle for the headline window. An exhausted headline
    /// must never read "Paced to last until reset" — the reset countdown above
    /// it is time until relief, not headroom that lasts.
    static func bannerSubtitle(pace: QuotaPace, usedPercent: Double) -> String {
        if usedPercent >= 100 {
            return "Exhausted early — waiting for reset"
        }
        if pace.projectedExhaustion != nil {
            return "Empties before reset at current pace"
        }
        return "Paced to last until reset"
    }

    /// Minimum card height that never resizes the window mid-sweep. The max
    /// is self-consistent: the height report already includes this minimum,
    /// so it ratchets once per taller card and then holds.
    static func stabilizedCardMinHeight(stripHeight: CGFloat, maxCardHeight: CGFloat) -> CGFloat? {
        let stable = max(stripHeight, maxCardHeight)
        return stable > 0 ? stable : nil
    }

    private struct ProviderTokenUsage {
        var todayText: String?
        var last30DaysText: String?
    }

    private func tokenUsage(for slot: ProviderSlot) -> ProviderTokenUsage? {
        var todayStr: String?
        var last30Str: String?

        if let usage = coordinator.usages[slot]?.value {
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
        let slot: ProviderSlot
        /// The slot digit shown for additional accounts ("2", "3", …); nil
        /// for primary slots.
        let digit: String?
        let usedPercent: Double?
        let fraction: Double?
        let spendUSD: Double?
        let ringTint: Color
        let markTint: Color
        let resetsAt: Date?
        /// True when the ring shows the archived last-good reading because
        /// the live fetch has nothing. Rendered dimmed, never as live.
        let isStale: Bool
        let etaText: String?
        let isDeficit: Bool

        var id: String { slot.key }

        var primaryText: String {
            if let usedPercent { return Fmt.percent(usedPercent) }
            return spendUSD.map(Fmt.usd) ?? "N/A"
        }

        var accessibilityText: String {
            if let usedPercent {
                return "\(slot.displayName) \(Fmt.percent(usedPercent)) used\(isStale ? ", last known reading" : "")"
            }
            if let spendUSD {
                return "\(slot.displayName), last 30 days (UTC), reported spend \(Fmt.usd(spendUSD))"
            }
            return "\(slot.displayName), usage unavailable"
        }

        init(
            slot: ProviderSlot,
            digit: String? = nil,
            usedPercent: Double?,
            fraction: Double?,
            ringTint: Color,
            markTint: Color,
            resetsAt: Date?,
            isStale: Bool,
            etaText: String? = nil,
            isDeficit: Bool = false,
            spendUSD: Double? = nil
        ) {
            self.slot = slot
            self.digit = digit
            self.usedPercent = usedPercent
            self.fraction = fraction
            self.spendUSD = spendUSD
            self.ringTint = ringTint
            self.markTint = markTint
            self.resetsAt = resetsAt
            self.isStale = isStale
            self.etaText = etaText
            self.isDeficit = isDeficit
        }
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
        menuBarSlots: [ProviderSlot],
        quotas: [ProviderSlot: Loaded<ProviderQuota>],
        statuses: [Provider: Loaded<ServiceStatus>],
        usages: [ProviderSlot: Loaded<ProviderUsage>] = [:],
        archivedQuotas: [ProviderSlot: ProviderQuota] = [:],
        now: Date = Date()
    ) -> [Entry] {
        // Additional accounts number from 2 within their tool, in stable
        // display order, so their rings stay tellable from the primary's.
        var familyCounts: [Provider: Int] = [:]
        return menuBarSlots.compactMap { slot in
            if slot.provider == .openAI {
                return Entry(
                    slot: slot, usedPercent: nil, fraction: nil,
                    ringTint: providerColor(.openAI), markTint: providerColor(.openAI),
                    resetsAt: nil, isStale: false,
                    spendUSD: usages[slot]?.value?.estimatedCostUSD
                )
            }
            let live = quotas[slot]?.value
            let quota = live ?? archivedQuotas[slot]
            let windows = effectiveWindows(for: slot.provider, quota: quota)
            guard let window = slot.provider.headlineWindow(from: windows)
            else { return nil }
            let markTint: Color
            let status = statuses[slot.provider]
            if let status = status?.value {
                markTint = MenuBarLabel.statusTint(status.severity, for: slot.provider)
            } else {
                // Headroom tints rings and percents only; the mark keeps the
                // provider's identity colour until a status check says
                // otherwise.
                markTint = providerColor(slot.provider)
            }
            // The strip reports the window's own pace: a deficit carries the
            // projected exhaustion chip whatever the last burn recency.
            let pace = window.pace(now: now)
            let showAmbient = pace?.shouldShowAmbientETA(resetsAt: window.resetsAt, now: now) ?? false
            let eta = showAmbient ? pace?.etaText(resetsAt: window.resetsAt, now: now, short: true) : nil
            let isDeficit = pace?.status.isDeficit ?? false

            if !slot.isPrimary {
                familyCounts[slot.provider, default: 1] += 1
            }
            let digit = slot.isPrimary ? nil : String(familyCounts[slot.provider] ?? 2)

            return Entry(
                slot: slot,
                digit: digit,
                usedPercent: window.usedPercent,
                fraction: window.fraction,
                ringTint: Notch.color(usedPercent: window.usedPercent),
                markTint: markTint,
                resetsAt: window.resetsAt,
                isStale: live == nil,
                etaText: eta,
                isDeficit: isDeficit
            )
        }
    }

    private var entries: [Entry] {
        SideNotchPanelView.entries(
            menuBarSlots: coordinator.sideNotchSlots,
            quotas: coordinator.quotas,
            statuses: coordinator.statuses,
            usages: coordinator.usages,
            archivedQuotas: coordinator.archivedQuotas,
            now: coordinator.clock
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

    private var accessibilityText: String {
        if entries.isEmpty { return "Usage unavailable" }
        return entries.map(\.accessibilityText).joined(separator: ", ")
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
    /// Passed in rather than read from `UserDefaults`, so the beak is themed
    /// from the same observed value as the card it sits on.
    let accent: AccentTheme

    private var accentIndex: Int { AccentTheme.allCases.firstIndex(of: accent) ?? 0 }

    var body: some View {
        TriangleArrow()
            .fill(Notch.card[accentIndex])
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
    let fraction: Double?
    let tint: Color
    let slot: ProviderSlot
    /// The slot digit for an additional account, drawn as a tiny chip so two
    /// rings of one tool stay tellable apart. The digit is the only account
    /// attribute that exists in this app (see the privacy contract).
    let digit: String?
    let markTint: Color
    /// Passed in rather than read from `UserDefaults`, so the ring chrome is
    /// themed from the same observed value as the rest of the panel.
    let accent: AccentTheme
    var reduceMotion = false

    private var accentIndex: Int { AccentTheme.allCases.firstIndex(of: accent) ?? 0 }

    var body: some View {
        ZStack {
            Circle()
                .fill(Notch.disc[accentIndex])
            Circle()
                .stroke(Notch.track[accentIndex], lineWidth: 2.5)
            if let fraction {
                Circle()
                    .trim(from: 0, to: fraction.muClamped(to: 0...1))
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            ProviderMark(provider: slot.provider, tint: markTint)
                .frame(width: 9, height: 9)
                // A hit limit dims the glyph: the full orange ring already
                // carries the state, and the mark steps back.
                .opacity((fraction ?? 0) >= 1 ? 0.5 : 1.0)
            if let digit {
                Text(digit)
                    .font(.system(size: 6.5, weight: .bold))
                    .foregroundColor(Notch.text)
                    .frame(width: 9, height: 9)
                    .background(Circle().fill(Notch.track[accentIndex]))
                    .offset(x: 10, y: 10)
                    // A ring recolours with the accent theme at rest; the
                    // digit chip shares that chrome so it stays part of the
                    // ring rather than a separate disk.
            }
        }
        .frame(width: 26, height: 26)
        // A ring that jumps reads as a glitch; one that sweeps reads as a
        // measurement.
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.65), value: fraction)
    }
}
