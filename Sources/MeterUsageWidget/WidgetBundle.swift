import WidgetKit
import SwiftUI
import AppIntents

// MARK: - MeterUsage widget extension
//
// Reads the snapshot file the menu-bar app rewrites after every refresh
// (the app-group container, falling back to the conventional path). The
// extension deliberately shares no code or process with the app: the JSON
// schema is the whole contract, decoded leniently here so an older widget
// survives a newer writer.
//
// The widget never spawns a provider CLI, never touches the network, and
// never reads anything but that one file.
//
// PROVIDER CHOICE, WITHOUT CONFIGURATION: AppIntentConfiguration was tried
// first (2026-08-24) and failed structurally — placements stored no intent,
// chronod rejected every reload with "Intent configuration is required but
// was not provided", and the Edit sheet never appeared, across parameter
// styles, kind renames, and version bumps. So choice is expressed the dumb,
// unbreakable way instead: one static widget per provider, plus an
// automatic one. Picking what to display = picking which widget to place.

// MARK: Snapshot model (mirror of LimitsReport, kept decoupled)

struct Snapshot: Decodable {
    var generatedAt: Date
    var providers: [ProviderRow]
    /// Display options chosen in the app's Settings. Nil in snapshots from
    /// older app versions; every field defaults.
    var options: Options?

    // The app encodes snake_case keys (LimitsReport's CodingKeys); the
    // mirror must match or every read decodes as garbage — which is exactly
    // what the first widget build did.
    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case providers
        case options
    }

    struct Options: Decodable {
        /// Per-provider display override: medium widgets pinned to that
        /// provider list every window instead of just the current and
        /// weekly ones.
        var allWindowsByProvider: [String: Bool]?

        enum CodingKeys: String, CodingKey {
            case allWindowsByProvider = "all_windows_by_provider"
        }

        func allWindows(forProvider provider: String) -> Bool {
            allWindowsByProvider?[provider] ?? false
        }
    }

    struct ProviderRow: Decodable {
        var provider: String
        var status: String
        var plan: String?
        var windows: [Window]?

        var displayName: String {
            switch provider {
            case "codex": return "Codex"
            case "claude": return "Claude"
            case "grok": return "Grok"
            case "antigravity": return "Antigravity"
            case "openCodeGo": return "OpenCode Go"
            case "openRouter": return "OpenRouter"
            default: return provider
            }
        }

        struct Window: Decodable {
            var label: String
            var usedPercent: Double
            var resetsAt: Date?

            enum CodingKeys: String, CodingKey {
                case label
                case usedPercent = "used_percent"
                case resetsAt = "resets_at"
            }
        }
    }
}

enum SnapshotFile {
    /// Must mirror `SnapshotStore.fileURL` in the app: the app group
    /// container when the platform answers, the conventional group-container
    /// path otherwise.
    static let groupIdentifier = "group.dev.meterusage.app"

    static func read() -> Snapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupIdentifier) {
            let url = container.appendingPathComponent("widget-snapshot.json")
            if let data = try? Data(contentsOf: url),
               let snapshot = try? decoder.decode(Snapshot.self, from: data) {
                return snapshot
            }
        }
        // Fallback: the conventional group-container path.
        let base: URL
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir,
           let home = String(validatingUTF8: dir), !home.isEmpty {
            base = URL(fileURLWithPath: home)
        } else {
            base = URL(fileURLWithPath: NSHomeDirectory())
        }
        let url = base
            .appendingPathComponent("Library/Group Containers", isDirectory: true)
            .appendingPathComponent(groupIdentifier, isDirectory: true)
            .appendingPathComponent("widget-snapshot.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(Snapshot.self, from: data)
    }
}

// MARK: Timeline

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: Snapshot?
    /// A provider key ("codex", "openCodeGo", …) when this widget is pinned
    /// to one provider; nil shows the automatic worst-of-everything view.
    var selectionRaw: String? = nil

    /// The rows this entry should render, honouring the selection. Medium
    /// pinned widgets pass `currentAndWeeklyOnly` to show just the short
    /// window and the weekly one; everything else ranks all windows.
    func displayRows(currentAndWeeklyOnly: Bool = false) -> [DisplayRow] {
        guard let snapshot else { return [] }
        return DisplayRow.rows(from: snapshot, selectionRaw: selectionRaw,
                               date: date, currentAndWeeklyOnly: currentAndWeeklyOnly)
    }
}

/// One line of the widget: a title, a percent, and a reset caption.
struct DisplayRow {
    let title: String
    let caption: String
    let percent: Double

    static func rows(from snapshot: Snapshot, selectionRaw: String?, date: Date,
                     currentAndWeeklyOnly: Bool = false) -> [DisplayRow] {
        let ok = snapshot.providers.filter { $0.status == "ok" && !($0.windows ?? []).isEmpty }

        // Pinned to one provider: its own windows. A pinned widget NEVER
        // falls back to another provider — empty data renders as "no quota
        // yet", not as somebody else's numbers.
        if let selectionRaw {
            guard let row = ok.first(where: { $0.provider == selectionRaw }) else { return [] }
            let windows = (row.windows ?? []).sorted { $0.usedPercent > $1.usedPercent }
            // Default medium view: the two windows that matter at a glance —
            // the current (short) window and the weekly one. The Settings
            // toggle "Show all windows" opts into the full list instead.
            var selected = windows
            if currentAndWeeklyOnly {
                let current = windows.first {
                    let l = $0.label.lowercased()
                    return l.contains("5-hour") || l.contains("5h")
                        || l.contains("rolling") || l.contains("session")
                        || (l.contains("day") && !l.contains("7-day") && !l.contains("week"))
                }
                let weekly = windows.first {
                    let l = $0.label.lowercased()
                    return l.contains("week") || l.contains("7-day")
                }
                if current != nil || weekly != nil {
                    selected = [current, weekly].compactMap { $0 }
                }
            }
            return selected.map { window in
                DisplayRow(title: window.label,
                           caption: Self.resetLine(window, date: date, includeLabel: false),
                           percent: window.usedPercent)
            }
        }

        // Automatic: one row per provider, its busiest window, busiest
        // provider first.
        return ok.compactMap { row -> DisplayRow? in
            guard let window = (row.windows ?? []).max(by: { $0.usedPercent < $1.usedPercent }) else {
                return nil
            }
            return DisplayRow(title: row.displayName,
                              caption: Self.resetLine(window, date: date),
                              percent: window.usedPercent)
        }.sorted { $0.percent > $1.percent }
    }

    static func resetLine(_ window: Snapshot.ProviderRow.Window, date: Date,
                          includeLabel: Bool = true) -> String {
        guard let resetsAt = window.resetsAt else { return includeLabel ? window.label : "" }
        let remaining = resetsAt.timeIntervalSince(date)
        guard remaining > 0 else { return includeLabel ? "\(window.label) · resetting" : "resetting" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        formatter.unitsStyle = .abbreviated
        let span = formatter.string(from: remaining) ?? ""
        if span.isEmpty { return includeLabel ? window.label : "" }
        return includeLabel ? "\(window.label) · \(span) left" : "\(span) left"
    }
}

struct Provider: TimelineProvider {
    /// nil for the automatic widgets; a provider key pins the widget.
    let selectionRaw: String?

    init(selectionRaw: String? = nil) {
        self.selectionRaw = selectionRaw
    }

    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), snapshot: SnapshotFile.read(), selectionRaw: selectionRaw)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(UsageEntry(date: Date(), snapshot: SnapshotFile.read(), selectionRaw: selectionRaw))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        // Four 15-minute entries keep the "resets in" lines honest for an
        // hour without the system re-loading the timeline too often. The app
        // also reloads timelines after every sweep, so fresh data arrives
        // as soon as it exists.
        let now = Date()
        let entries = (0..<4).map { offset in
            UsageEntry(date: now.addingTimeInterval(Double(offset) * 900),
                       snapshot: SnapshotFile.read(),
                       selectionRaw: selectionRaw)
        }
        completion(Timeline(entries: entries,
                            policy: .after(now.addingTimeInterval(3600))))
    }
}

// MARK: View

struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                content(snapshot)
                    .staleTint(generatedAt: snapshot.generatedAt, now: entry.date)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("meterusage")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Run MeterUsage once to fill this in.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        // Clicking a pinned widget opens its display options in the app.
        .widgetURL(entry.selectionRaw.flatMap { URL(string: "meterusage://widget/\($0)") })
    }

    @ViewBuilder
    private func content(_ snapshot: Snapshot) -> some View {
        let allWindows = entry.selectionRaw.map {
            snapshot.options?.allWindows(forProvider: $0) ?? false
        } ?? false
        let rows = entry.displayRows(currentAndWeeklyOnly: !allWindows)
        if family == .systemSmall {
            // Small: a single headline figure — the first row, which is the
            // worst window overall (automatic) or the pinned provider's.
            VStack(alignment: .leading, spacing: 6) {
                if let row = rows.first {
                    Text(headlineTitle(snapshot: snapshot, row: row))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("\(Int(row.percent.rounded()))%")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .foregroundStyle(tint(row.percent))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(row.caption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(emptyMessage(snapshot: snapshot))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                // Pinned medium widgets name their provider up top — window
                // labels alone ("Weekly", "Monthly") could belong to anyone.
                let pinnedName = entry.selectionRaw.flatMap { raw in
                    snapshot.providers.first(where: { $0.provider == raw })?.displayName
                }
                if let pinnedName {
                    Text(pinnedName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(rows.prefix(pinnedName == nil ? 5 : 4).enumerated()), id: \.offset) { _, row in
                    rowView(row)
                }
                if rows.isEmpty {
                    Text("No quota data yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// Pinned widgets headline the provider name — a bare "Weekly" title is
    /// indistinguishable from every other provider's weekly window.
    private func headlineTitle(snapshot: Snapshot, row: DisplayRow) -> String {
        if let selectionRaw = entry.selectionRaw,
           let pinned = snapshot.providers.first(where: { $0.provider == selectionRaw }) {
            return pinned.displayName
        }
        return row.title
    }

    private func emptyMessage(snapshot: Snapshot) -> String {
        if let selectionRaw = entry.selectionRaw {
            let name = snapshot.providers.first(where: { $0.provider == selectionRaw })?.displayName
                ?? selectionRaw
            return "\(name): no quota yet"
        }
        return "No quota yet"
    }

    private func rowView(_ row: DisplayRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(row.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(row.caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(tint(row.percent))
                        .frame(width: geo.size.width * row.percent / 100)
                }
            }
            .frame(height: 5)
        }
    }

    private func tint(_ usedPercent: Double) -> Color {
        // Same bands as the popover's headroom colours: calm under 70,
        // warning to 90, alert beyond.
        switch usedPercent {
        case ..<70: return Color.green
        case ..<90: return Color.orange
        default: return Color.red
        }
    }
}

extension View {
    /// Surfaces staleness honestly: a snapshot older than two refresh cycles
    /// dims, so a paused app can't masquerade as current data.
    @ViewBuilder
    func staleTint(generatedAt: Date, now: Date) -> some View {
        if now.timeIntervalSince(generatedAt) > 3600 {
            opacity(0.45)
        } else {
            self
        }
    }
}

// MARK: Configurable widget (macOS 14+)
//
// The right-click → Edit sheet with per-widget options. An earlier attempt
// stored placements without intents (chronod 1103); the two differences this
// time are outside code: the app's AppIntents metadata is force-registered
// with lsregister after install, and the metadata bundle is also embedded in
// the app, not only the extension.

@available(macOS 14.0, *)
enum QuotaSelection: String, AppEnum {
    case automatic
    case codex
    case claude
    case grok
    case antigravity
    case openCodeGo
    case openRouter

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Provider")
    }

    static var caseDisplayRepresentations: [QuotaSelection: DisplayRepresentation] {
        [
            .automatic: DisplayRepresentation(title: "Automatic (worst)"),
            .codex: DisplayRepresentation(title: "Codex"),
            .claude: DisplayRepresentation(title: "Claude"),
            .grok: DisplayRepresentation(title: "Grok"),
            .antigravity: DisplayRepresentation(title: "Antigravity"),
            .openCodeGo: DisplayRepresentation(title: "OpenCode Go"),
            .openRouter: DisplayRepresentation(title: "OpenRouter"),
        ]
    }
}

@available(macOS 14.0, *)
struct SelectProviderIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Choose provider"
    static var description = IntentDescription(
        "Pick which provider this widget shows. Automatic shows whichever is closest to its limit.")

    // Optional rather than defaulted: a metadata-resolved AppEnum default
    // was stored as an empty config on placement. nil renders as Automatic.
    @Parameter(title: "Provider")
    var selection: QuotaSelection?
}

@available(macOS 14.0, *)
struct ConfigurableProvider: AppIntentTimelineProvider {
    typealias Entry = UsageEntry
    typealias Intent = SelectProviderIntent

    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), snapshot: SnapshotFile.read())
    }

    func snapshot(
        for configuration: SelectProviderIntent,
        in context: Context
    ) async -> UsageEntry {
        UsageEntry(
            date: Date(),
            snapshot: SnapshotFile.read(),
            selectionRaw: configuration.selection?.rawValue)
    }

    func timeline(
        for configuration: SelectProviderIntent,
        in context: Context
    ) async -> Timeline<UsageEntry> {
        let now = Date()
        let entries = (0..<4).map { offset in
            UsageEntry(
                date: now.addingTimeInterval(Double(offset) * 900),
                snapshot: SnapshotFile.read(),
                selectionRaw: configuration.selection?.rawValue)
        }
        return Timeline(entries: entries,
                        policy: .after(now.addingTimeInterval(3600)))
    }
}

@available(macOS 14.0, *)
struct ConfigurableQuotaWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "dev.meterusage.quota.custom.v3",
            intent: SelectProviderIntent.self,
            provider: ConfigurableProvider()
        ) { entry in
            UsageWidgetView(entry: entry)
        }
        .configurationDisplayName("AI quota (custom)")
        .description(
            "Quota headroom from the MeterUsage menu-bar app. Edit to pick the provider.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: Bundle

@main
struct MeterUsageWidgetBundle: WidgetBundle {
    var body: some Widget {
        MeterUsageQuotaWidget()
        CodexQuotaWidget()
        ClaudeQuotaWidget()
        GrokQuotaWidget()
        AntigravityQuotaWidget()
        OpenCodeGoQuotaWidget()
        OpenRouterQuotaWidget()
        if #available(macOS 14.0, *) {
            ConfigurableQuotaWidget()
        }
    }
}

// MARK: Widgets

/// The automatic widget: worst window across every provider with data.
struct MeterUsageQuotaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.meterusage.quota", provider: Provider()) {
            UsageWidgetView(entry: $0)
        }
        .configurationDisplayName("AI quota (automatic)")
        .description("Always shows whichever provider is closest to its limit.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

/// One widget per provider: choosing what to display is choosing which
/// widget to place. No configuration machinery to break.
///
/// These are deliberately written out longhand with literal kinds, names,
/// and provider keys — WidgetKit asserts at body evaluation when a Widget's
/// configuration is built from instance state (verified by crash report:
/// SIGTRAP in `ProviderQuotaWidget.body.getter`), so no shared parameterised
/// struct here, however repetitive it looks.
struct CodexQuotaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.meterusage.quota.codex", provider: Provider(selectionRaw: "codex")) {
            UsageWidgetView(entry: $0)
        }
        .configurationDisplayName("Codex quota")
        .description("Shows only Codex's quota windows.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct ClaudeQuotaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.meterusage.quota.claude", provider: Provider(selectionRaw: "claude")) {
            UsageWidgetView(entry: $0)
        }
        .configurationDisplayName("Claude quota")
        .description("Shows only Claude's quota windows.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct GrokQuotaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.meterusage.quota.grok", provider: Provider(selectionRaw: "grok")) {
            UsageWidgetView(entry: $0)
        }
        .configurationDisplayName("Grok quota")
        .description("Shows only Grok's quota windows.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct AntigravityQuotaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.meterusage.quota.antigravity", provider: Provider(selectionRaw: "antigravity")) {
            UsageWidgetView(entry: $0)
        }
        .configurationDisplayName("Antigravity quota")
        .description("Shows only Antigravity's quota windows.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct OpenCodeGoQuotaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.meterusage.quota.openCodeGo", provider: Provider(selectionRaw: "openCodeGo")) {
            UsageWidgetView(entry: $0)
        }
        .configurationDisplayName("OpenCode Go quota")
        .description("Shows only OpenCode Go's quota windows.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct OpenRouterQuotaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.meterusage.quota.openRouter", provider: Provider(selectionRaw: "openRouter")) {
            UsageWidgetView(entry: $0)
        }
        .configurationDisplayName("OpenRouter quota")
        .description("Shows only OpenRouter's credit balance and spend.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
