import Foundation

// MARK: - Machine-readable limits report
//
// One stable, credential-free serialization of exactly what the popover
// shows. Two consumers share it:
//
//   * the one-shot CLI (`meterusage json`) — agents and scripts read limits;
//   * the widget snapshot file — the menu-bar app writes it after every
//     refresh so the WidgetKit extension never needs to spawn a provider CLI.
//
// PRIVACY CONTRACT (same as UsageModels, enforced here): the DTOs carry only
// display names, percentages, reset timestamps, and plan labels. No tokens,
// ids, paths, or hostnames can reach this format because the source types
// they are built from cannot hold them.

struct LimitsReport: Equatable, Sendable, Codable {
    /// Bumped on any breaking shape change so readers can gate on it.
    static let schemaVersion = 1

    var schema: Int
    var generatedAt: Date
    var providers: [ProviderReport]
    /// Display options the widget honours. Optional so older readers ignore
    /// it and older writers leave it nil (widget falls back to defaults).
    var widgetOptions: WidgetOptions?

    init(schema: Int = LimitsReport.schemaVersion,
         generatedAt: Date,
         providers: [ProviderReport],
         widgetOptions: WidgetOptions? = nil) {
        self.schema = schema
        self.generatedAt = generatedAt
        self.providers = providers
        self.widgetOptions = widgetOptions
    }

    enum CodingKeys: String, CodingKey {
        case schema
        case generatedAt = "generated_at"
        case providers
        case widgetOptions = "widget_options"
    }
}

/// User-chosen widget display behaviour, toggled in Settings →
/// "Edit usage display" (global default) or in the per-provider panel that
/// opens when a widget is clicked. Carried to the extension through the
/// snapshot.
struct WidgetOptions: Equatable, Sendable, Codable {
    /// Medium widgets pinned to one provider list every window instead of
    /// just the current and weekly ones. Global default.
    var allWindowsMedium: Bool
    /// Per-provider override; wins over the global default when present.
    var allWindowsByProvider: [String: Bool]?

    enum CodingKeys: String, CodingKey {
        case allWindowsMedium = "all_windows_medium"
        case allWindowsByProvider = "all_windows_by_provider"
    }
}

struct ProviderReport: Equatable, Sendable, Codable {
    var provider: String
    /// "ok" when windows or credits were read; "unavailable" otherwise.
    var status: String
    /// Present only when status is "unavailable"; verbatim from
    /// `SourceUnavailable.userFacingMessage`.
    var reason: String?
    var plan: String?
    var windows: [WindowReport]
    var credits: CreditsReport?

    init(provider: String, status: String, reason: String? = nil,
         plan: String? = nil, windows: [WindowReport] = [],
         credits: CreditsReport? = nil) {
        self.provider = provider
        self.status = status
        self.reason = reason
        self.plan = plan
        self.windows = windows
        self.credits = credits
    }
}

struct WindowReport: Equatable, Sendable, Codable {
    var label: String
    var usedPercent: Double
    /// ISO 8601 when the provider reports a reset; omitted otherwise.
    var resetsAt: Date?

    init(label: String, usedPercent: Double, resetsAt: Date?) {
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    static func from(_ window: QuotaWindow, now: Date) -> WindowReport {
        WindowReport(
            label: window.label,
            usedPercent: window.usedPercent,
            resetsAt: window.resetsAt
        )
    }

    enum CodingKeys: String, CodingKey {
        case label
        case usedPercent = "used_percent"
        case resetsAt = "resets_at"
    }
}

struct CreditsReport: Equatable, Sendable, Codable {
    var balance: Double
    var unit: String
    var dollarBalance: Double?

    init(balance: Double, unit: String, dollarBalance: Double? = nil) {
        self.balance = balance
        self.unit = unit
        self.dollarBalance = dollarBalance
    }

    enum CodingKeys: String, CodingKey {
        case balance
        case unit
        case dollarBalance = "dollar_balance"
    }
}

// MARK: - Builder

enum LimitsReporter {

    /// Builds the report from loaded quota state, in the caller's provider
    /// order. Unavailable sources appear with their calm user-facing reason —
    /// never a raw error — so a consumer can distinguish "not installed"
    /// from "offline" without this module exposing anything sensitive.
    static func build(
        quotas: [Provider: Loaded<ProviderQuota>],
        order: [Provider],
        now: Date = Date()
    ) -> LimitsReport {
        let providers = order.map { provider -> ProviderReport in
            switch quotas[provider] {
            case .value(let quota):
                // Groups carry real windows (Codex nests its General and
                // model-specific limits there), so flatten them in with any
                // top-level windows — the popover renders groups, but a
                // top-level-only report would silently drop most of them.
                let allWindows = quota.windows + quota.groups.flatMap { $0.windows }
                return ProviderReport(
                    provider: provider.rawValue,
                    status: "ok",
                    plan: quota.planType,
                    windows: allWindows.map { WindowReport.from($0, now: now) },
                    credits: quota.credits.map {
                        CreditsReport(
                            balance: $0.balance,
                            unit: $0.unit == .credits ? "credits" : "dollars",
                            dollarBalance: $0.dollarBalance
                        )
                    }
                )
            case .missing(let reason):
                return ProviderReport(
                    provider: provider.rawValue,
                    status: "unavailable",
                    reason: reason.userFacingMessage
                )
            case .idle, .none:
                // Never refreshed — indistinguishable to a reader from a
                // source we haven't polled yet, which is exactly what it is.
                return ProviderReport(provider: provider.rawValue, status: "unavailable")
            }
        }
        return LimitsReport(generatedAt: now, providers: providers)
    }
}

// MARK: - Encoding

extension LimitsReport {

    /// Canonical JSON for stdout and the snapshot file: stable key order via
    /// `sortedKeys`, ISO 8601 dates, no debug noise.
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Decodes a snapshot written by the app. Lenient by design: unknown
    /// fields are ignored, missing optional fields default, so an older
    /// reader survives a newer writer.
    static func decode(_ data: Data) -> LimitsReport? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LimitsReport.self, from: data)
    }
}

// MARK: - Snapshot store
//
// The file hand-off between the running app and the WidgetKit extension,
// which runs out-of-process and shares nothing with us.

enum SnapshotStore {

    /// The app group both sides agree on. The sandboxed widget may read only
    /// its group container, so the snapshot lives there rather than in
    /// Application Support. The unsandboxed app writes through the plain
    /// filesystem; the sandbox maps the same path for the widget.
    static let groupIdentifier = "group.dev.meterusage.app"

    /// Written after every refresh sweep. Best-effort in both directions:
    /// a failed write leaves the previous snapshot in place, and a failed
    /// delete is harmless because readers treat any unreadable file as
    /// "no data".
    static func write(_ report: LimitsReport) {
        let url = fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? report.jsonData() {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func read() -> LimitsReport? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return LimitsReport.decode(data)
    }

    static var fileURL: URL {
        let directory: URL
        // The container API answers inside a sandbox (the widget's case);
        // the computed fallback covers the unsandboxed app, which has no
        // entitlement to consult. Both land on the same absolute path.
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupIdentifier) {
            directory = container
        } else {
            directory = HomeDirectory.real
                .appendingPathComponent("Library/Group Containers", isDirectory: true)
                .appendingPathComponent(groupIdentifier, isDirectory: true)
        }
        return directory.appendingPathComponent("widget-snapshot.json")
    }
}
