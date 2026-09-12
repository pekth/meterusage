import Foundation

// MARK: - Machine-readable limits report
//
// One stable, credential-free serialization of exactly what the popover
// shows, consumed by the one-shot CLI (`meterusage json`) for agents and scripts.
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

    init(schema: Int = LimitsReport.schemaVersion,
         generatedAt: Date,
         providers: [ProviderReport]) {
        self.schema = schema
        self.generatedAt = generatedAt
        self.providers = providers
    }

    enum CodingKeys: String, CodingKey {
        case schema
        case generatedAt = "generated_at"
        case providers
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
    var remainingPercent: Double?
    /// ISO 8601 when the provider reports a reset; omitted otherwise.
    var resetsAt: Date?
    var etaSeconds: Double?
    var etaText: String?
    var pacing: String?
    var burnRate: Double?

    init(
        label: String,
        usedPercent: Double,
        resetsAt: Date?,
        remainingPercent: Double? = nil,
        etaSeconds: Double? = nil,
        etaText: String? = nil,
        pacing: String? = nil,
        burnRate: Double? = nil
    ) {
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.remainingPercent = remainingPercent ?? max(0, 100.0 - usedPercent)
        self.etaSeconds = etaSeconds
        self.etaText = etaText
        self.pacing = pacing
        self.burnRate = burnRate
    }

    static func from(_ window: QuotaWindow, now: Date) -> WindowReport {
        let pace = window.pace(now: now)
        return WindowReport(
            label: window.label,
            usedPercent: window.usedPercent,
            resetsAt: window.resetsAt,
            remainingPercent: max(0, 100.0 - window.usedPercent),
            etaSeconds: pace?.etaInterval(resetsAt: window.resetsAt, now: now),
            etaText: pace?.etaText(resetsAt: window.resetsAt, now: now),
            pacing: pace?.statusText(usedPercent: window.usedPercent),
            burnRate: pace?.burnRate
        )
    }

    enum CodingKeys: String, CodingKey {
        case label
        case usedPercent = "used_percent"
        case remainingPercent = "remaining_percent"
        case resetsAt = "resets_at"
        case etaSeconds = "eta_seconds"
        case etaText = "eta_text"
        case pacing
        case burnRate = "burn_rate"
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
                // The report is the glance-level usage view (tray, widget,
                // CLI), so it carries the provider's regular allowance
                // windows. Codex's model-specific windows live in `groups`;
                // they stay out of the report so the widget shows the same
                // regular usage the tray does, never a model-specific limit.
                let windows = quota.windows
                return ProviderReport(
                    provider: provider.rawValue,
                    status: "ok",
                    plan: quota.planType,
                    windows: windows.map { WindowReport.from($0, now: now) },
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

