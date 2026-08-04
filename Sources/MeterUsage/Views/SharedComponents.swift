import SwiftUI
import AppKit

// MARK: - Design system
//
// Everything visual is defined once here so the popover reads as one designed
// surface rather than a pile of stock controls. Two rules drive the choices:
//
// 1. The app lives in the menu bar, which can be light or dark independently of
//    the popover's own appearance. Colours are therefore declared as dynamic
//    NSColor pairs rather than fixed sRGB values, so a single token is correct
//    in both appearances without any branching at the call site.
// 2. Numbers change on every refresh. Layout must not move when they do, so
//    numeric text is monospaced-digit and meters animate rather than snap.

// MARK: Colour tokens

/// Builds an appearance-reactive colour.
///
/// SwiftUI's `Color` has no first-class light/dark literal on macOS 13, and
/// `@Environment(\.colorScheme)` is unavailable in the AppKit-hosted status-item
/// view. `NSColor(name:dynamicProvider:)` is resolved by AppKit at draw time, so
/// it stays correct even in the menu bar where we control no environment.
func dynamicColor(light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    })
}

private func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

enum MU {

    // Surfaces ------------------------------------------------------------

    /// Popover backdrop. Deliberately not `windowBackgroundColor`: the popover
    /// already vibrancy-blurs, so a near-transparent wash reads cleaner.
    static let canvas = dynamicColor(light: rgb(250, 250, 252), dark: rgb(28, 28, 32))

    /// Raised card fill.
    static let surface = dynamicColor(light: rgb(255, 255, 255), dark: rgb(40, 40, 46))

    /// Recessed fill, used for meter tracks and heatmap empty cells.
    static let well = dynamicColor(light: rgb(236, 236, 241), dark: rgb(53, 53, 60))

    static let hairline = dynamicColor(light: rgb(0, 0, 0, 0.08), dark: rgb(255, 255, 255, 0.10))

    // Text ----------------------------------------------------------------

    static let text = dynamicColor(light: rgb(24, 24, 28), dark: rgb(240, 240, 245))
    static let textSecondary = dynamicColor(light: rgb(104, 104, 116), dark: rgb(160, 160, 172))
    static let textTertiary = dynamicColor(light: rgb(146, 146, 158), dark: rgb(122, 122, 134))

    // Semantic ------------------------------------------------------------

    /// Plenty of headroom.
    static let calm = dynamicColor(light: rgb(28, 150, 108), dark: rgb(70, 200, 150))
    /// Getting close.
    static let warn = dynamicColor(light: rgb(190, 130, 20), dark: rgb(230, 175, 60))
    /// Nearly exhausted.
    static let alert = dynamicColor(light: rgb(198, 60, 55), dark: rgb(240, 110, 100))
    /// Informational, never alarming — used for "nothing here yet" states.
    static let neutral = dynamicColor(light: rgb(120, 120, 132), dark: rgb(150, 150, 162))

    static let accent = dynamicColor(light: rgb(64, 96, 220), dark: rgb(124, 152, 255))
    static let antigravity = dynamicColor(light: rgb(122, 76, 194), dark: rgb(181, 132, 255))
    static let grok = dynamicColor(light: rgb(196, 94, 30), dark: rgb(255, 145, 78))
    static let openCodeGo = dynamicColor(light: rgb(20, 126, 150), dark: rgb(69, 199, 219))
    static let openRouter = dynamicColor(light: rgb(104, 72, 190), dark: rgb(166, 132, 255))

    // Metrics -------------------------------------------------------------

    static let popoverWidth: CGFloat = 340
    /// Keeps the default dashboard tight. Optional provider and activity cards
    /// can make the content taller; `PopoverRoot`'s scroll view handles those
    /// cases instead of reserving a large empty footer on the common layout.
    static let popoverHeight: CGFloat = 650
    static let cardRadius: CGFloat = 10
    static let gutter: CGFloat = 14

    /// Fixed widths for the two numeric columns in the per-model breakdown, so
    /// the header labels and every row share one grid and the digits don't
    /// shuffle sideways between refreshes.
    static let tokenColumn: CGFloat = 52
    static let costColumn: CGFloat = 54
}

/// Maps consumption to a headroom colour.
///
/// The bands follow the percentage the user sees: under half used is calm,
/// half to four-fifths used is getting tight, and the final fifth is critical.
/// Codex displays remaining percentage while other providers display consumed
/// percentage, but both use this same consumed-percentage input.
func headroomColor(usedPercent: Double) -> Color {
    switch usedPercent {
    case ..<50:  return MU.calm
    case ..<80:  return MU.warn
    default:     return MU.alert
    }
}

func severityColor(_ severity: Severity) -> Color {
    switch severity {
    case .operational:   return MU.calm
    case .degraded:      return MU.warn
    case .partialOutage: return MU.warn
    case .majorOutage:   return MU.alert
    case .unknown:       return MU.neutral
    }
}

/// Provider identity colours. These are paired with names and never carry
/// meaning by colour alone; quota severity still uses the separate green/amber/
/// red headroom scale.
func providerColor(_ provider: Provider) -> Color {
    switch provider {
    case .codex:      return MU.accent
    case .antigravity:return MU.antigravity
    case .grok:       return MU.grok
    case .openCodeGo: return MU.openCodeGo
    case .openRouter: return MU.openRouter
    case .claude:     return MU.calm
    }
}

// MARK: - Typography

extension Font {
    /// Section headings: small, uppercase-tracked, never shouty.
    static let muSectionTitle = Font.system(size: 10, weight: .semibold)
    static let muTitle = Font.system(size: 13, weight: .semibold)
    static let muBody = Font.system(size: 12, weight: .regular)
    static let muCaption = Font.system(size: 10.5, weight: .regular)
    /// Any figure that updates on refresh, so column widths stay put.
    static let muNumber = Font.system(size: 12, weight: .medium).monospacedDigit()
    static let muBigNumber = Font.system(size: 19, weight: .semibold).monospacedDigit()
}

// MARK: - Building blocks

/// Small-caps heading with an optional trailing accessory.
struct SectionHeader<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title.uppercased())
                .font(.muSectionTitle)
                .tracking(0.8)
                .foregroundColor(MU.textTertiary)
            Spacer(minLength: 4)
            accessory()
        }
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(_ title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// The one container shape in the app. Everything sits in one of these.
struct Card<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: MU.cardRadius, style: .continuous)
                    .fill(MU.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MU.cardRadius, style: .continuous)
                    .strokeBorder(MU.hairline, lineWidth: 1)
            )
    }
}

/// Horizontal consumption meter.
///
/// Drawn by hand rather than with `ProgressView` because the stock bar cannot be
/// tinted per-value on macOS 13 without an appearance hack, and its 4pt height
/// reads as a system control rather than part of this layout.
struct MeterBar: View {
    let fraction: Double
    let tint: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(MU.well)
                Capsule(style: .continuous)
                    .fill(tint)
                    // A hairline minimum keeps a 0.4% window from rendering as
                    // an empty track, which reads as "no data" instead of "new".
                    .frame(width: max(fraction.clamped(to: 0...1) * geo.size.width, fraction > 0 ? 3 : 0))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.35), value: fraction)
    }
}

/// Subscription tier shown beside a provider's name.
///
/// Deliberately quieter than `Pill`: a plan is *context* for the percentages in
/// the same card, not a metric of its own. A tinted, filled capsule next to the
/// provider name would out-shout the number it exists to qualify, so this is a
/// hairline outline over the recessed fill, in secondary text — legible, and
/// visually subordinate to everything around it.
///
/// The text is passed through verbatim. Unrecognised plan strings must reach the
/// user exactly as the provider spelled them rather than being title-cased into
/// something that looks official but isn't.
struct PlanBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .tracking(0.2)
            .foregroundColor(MU.textSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                Capsule(style: .continuous).fill(MU.well)
            )
            .overlay(
                Capsule(style: .continuous).strokeBorder(MU.hairline, lineWidth: 1)
            )
            .accessibilityLabel("Plan: \(text)")
    }
}

/// Small filled dot used for status rows.
struct StatusDot: View {
    let color: Color
    var diameter: CGFloat = 7

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .overlay(Circle().strokeBorder(color.opacity(0.30), lineWidth: 2.5).blur(radius: 0.5))
    }
}

/// A status colour paired with its written severity so the signal remains
/// understandable without colour perception.
struct StatusBadge: View {
    let severity: Severity

    var body: some View {
        HStack(spacing: 4) {
            StatusDot(color: severityColor(severity), diameter: 6)
            Text(severity.displayName)
                .font(.muCaption)
                .foregroundColor(severityColor(severity))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous).fill(severityColor(severity).opacity(0.12))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(severity.displayName)")
    }
}

/// Calm empty state.
///
/// A missing provider is the normal case on most machines — no CLI installed, or
/// nothing run yet. This deliberately shares no visual language with an error:
/// neutral grey, no icon fill, no border emphasis.
struct InfoState: View {
    let message: String
    var hint: String?
    /// `true` only for `SourceUnavailable.failed`, which is the single case that
    /// means "something actually went wrong".
    var isWarning: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isWarning ? "exclamationmark.triangle" : "circle.dashed")
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(isWarning ? MU.warn : MU.neutral)
                .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                    .font(.muBody)
                    .foregroundColor(isWarning ? MU.text : MU.textSecondary)
                if let hint {
                    Text(hint)
                        .font(.muCaption)
                        .foregroundColor(MU.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Formatting

enum Fmt {

    /// "12.4M", "874K", "312" — keeps token columns narrow and stable.
    static func compactCount(_ value: Int) -> String {
        let v = Double(value)
        switch abs(v) {
        case 1_000_000_000...: return String(format: "%.1fB", v / 1_000_000_000)
        case 1_000_000...:     return String(format: "%.1fM", v / 1_000_000)
        case 10_000...:        return String(format: "%.0fK", v / 1_000)
        case 1_000...:         return String(format: "%.1fK", v / 1_000)
        default:               return String(value)
        }
    }

    /// An exact, grouped whole-number count for provider credit units.
    /// Credits are not currency and must never inherit a dollar symbol or
    /// compact `1.8K` notation when the provider reports `1843`.
    static func credits(_ value: Double) -> String {
        if let formatted = wholeNumber.string(from: NSNumber(value: value.rounded())) {
            return formatted
        }
        return String(Int(value.rounded()))
    }

    /// Exact grouped count for sessions and messages. Unlike token totals,
    /// these provider-native activity counts are small enough that rounding to
    /// "1.4K" would hide useful information.
    static func count(_ value: Int) -> String {
        wholeNumber.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// Currency for display: "$4.20", "$78.31", "$43,640".
    ///
    /// Grouping separators are not cosmetic here — an unseparated "$43640"
    /// is genuinely hard to read at a glance and invites an order-of-magnitude
    /// misread, which is the one mistake a spend figure must not encourage.
    /// Cents are dropped at four figures and up, where they carry no useful
    /// signal and only add width.
    ///
    /// Uses a locale-aware formatter rather than hand-inserted commas so the
    /// separator follows the user's region (1.234,56 in much of Europe).
    static func usd(_ value: Double) -> String {
        let showCents = value < 1000
        let formatter = showCents ? currencyWithCents : currencyWhole
        if let s = formatter.string(from: NSNumber(value: value)) { return s }
        // Formatter failure is not expected; fall back to something truthful
        // rather than rendering an empty string in a spend column.
        return showCents
            ? String(format: "$%.2f", value)
            : String(format: "$%.0f", value)
    }

    private static let currencyWithCents: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    private static let currencyWhole: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 0
        return f
    }()

    private static let wholeNumber: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 0
        return f
    }()

    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value.clamped(to: 0...100))
    }

    /// Codex reports consumption, while its account screen presents the
    /// remaining headroom. Keep both values derived from the same source field
    /// so the bar, number and colour cannot disagree.
    static func remainingPercent(_ usedPercent: Double) -> String {
        "\(percent(100 - usedPercent)) left"
    }

    /// Compact forward duration: "2h 14m", "9m", "3d 4h".
    ///
    /// `RelativeDateTimeFormatter` renders "in 2 hours", which is both wider and
    /// less precise than users want when deciding whether to keep working.
    static func timeUntil(_ date: Date, now: Date = Date()) -> String? {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        let total = Int(seconds)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return "\(max(minutes, 1))m"
    }

    /// Backward duration for "checked 4m ago" style captions.
    static func timeSince(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(now.timeIntervalSince(date), 0)
        if seconds < 45 { return "just now" }
        let total = Int(seconds)
        if total < 3_600 { return "\(total / 60)m ago" }
        if total < 86_400 { return "\(total / 3_600)h ago" }
        return "\(total / 86_400)d ago"
    }

    static let dayLabel: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    // MARK: Absolute times

    // Both formatters use localised templates rather than fixed patterns, so a
    // 24-hour or non-English system renders correctly, and both default to the
    // *local* time zone. Providers report resets in UTC; showing that raw would
    // be precise and useless — nobody plans their afternoon in UTC.
    private static let clockOnly: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()

    private static let weekdayAndClock: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEdMMMjmm")
        return f
    }()

    /// Wall-clock rendering of a reset, in the user's own time zone.
    ///
    /// The countdown answers "can I keep working?"; this answers "when do I get
    /// it back?", which is the one people write down. Anything not landing today
    /// or tomorrow carries a weekday and date, because "11:11" five days out is
    /// worse than no timestamp at all.
    static func absoluteMoment(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return "today \(clockOnly.string(from: date))"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow \(clockOnly.string(from: date))"
        }
        return weekdayAndClock.string(from: date)
    }

    /// Expiry detail for earned reset credits, including the local time zone.
    static func expiryMoment(_ date: Date) -> String {
        expiryFormatter.string(from: date)
    }

    private static let expiryFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("Mdjmz")
        return f
    }()

    // MARK: Model names

    /// Shortens a raw model id for a narrow column, without inventing a name.
    ///
    /// Transcript `model` values are inconsistent by nature: full dated ids
    /// ("claude-opus-4-8"), bare families ("opus"), non-Claude markers, and
    /// names with no version at all ("claude-fable-5", "fable"). The rule is
    /// mechanical — drop a leading vendor prefix, keep everything else — so a
    /// model this app has never heard of still renders as itself rather than as
    /// a guess or a truncated stub.
    static func shortModel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "unknown" }
        // "<synthetic>" and friends are markers, not model names; leave them be.
        guard !trimmed.hasPrefix("<") else { return trimmed }

        var name = trimmed
        for prefix in ["claude-", "anthropic/", "anthropic."] where name.lowercased().hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            break
        }
        return name.isEmpty ? trimmed : name
    }
}
