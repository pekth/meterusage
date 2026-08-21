import Foundation
// MARK: - Formatting
//
// Pure display formatting shared by every shell. Foundation-only so the
// Linux and Windows builds can reuse it verbatim.

// MARK: - Formatting

public enum Fmt {

    /// "12.4M", "874K", "312" — keeps token columns narrow and stable.
    public static func compactCount(_ value: Int) -> String {
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
    public static func credits(_ value: Double) -> String {
        if let formatted = wholeNumber.string(from: NSNumber(value: value.rounded())) {
            return formatted
        }
        return String(Int(value.rounded()))
    }

    /// Exact grouped count for sessions and messages. Unlike token totals,
    /// these provider-native activity counts are small enough that rounding to
    /// "1.4K" would hide useful information.
    public static func count(_ value: Int) -> String {
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
    public static func usd(_ value: Double) -> String {
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

    public static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value.clamped(to: 0...100))
    }

    /// Codex popover cards show remaining headroom; the menu-bar slot uses
    /// `percent(_:)` directly to retain its compact consumed-usage figure.
    public static func remainingPercent(_ usedPercent: Double) -> String {
        "\(percent(100 - usedPercent)) left"
    }

    /// Compact forward duration: "2h 14m", "9m", "3d 4h".
    ///
    /// `RelativeDateTimeFormatter` renders "in 2 hours", which is both wider and
    /// less precise than users want when deciding whether to keep working.
    public static func timeUntil(_ date: Date, now: Date = Date()) -> String? {
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
    public static func timeSince(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(now.timeIntervalSince(date), 0)
        if seconds < 45 { return "just now" }
        let total = Int(seconds)
        if total < 3_600 { return "\(total / 60)m ago" }
        if total < 86_400 { return "\(total / 3_600)h ago" }
        return "\(total / 86_400)d ago"
    }

    public static let dayLabel: DateFormatter = {
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
    public static func absoluteMoment(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
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
    public static func expiryMoment(_ date: Date) -> String {
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
    public static func shortModel(_ raw: String) -> String {
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
