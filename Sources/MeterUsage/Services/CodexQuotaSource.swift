import Foundation

/// Live quota for Codex, read via `codex app-server`'s JSON-RPC interface.
///
/// This type never touches `~/.codex/auth.json` and never spawns a process
/// directly — it delegates the RPC exchange to a `JSONRPCClient`, which keeps
/// auth entirely inside the `codex` subprocess (it manages its own login
/// state) and keeps this type unit-testable without a real CLI installed.
public struct CodexQuotaSource: QuotaSource, QuotaResetConsumer {
    public let provider: Provider = .codex

    private let client: JSONRPCClient

    public init(client: JSONRPCClient = SubprocessJSONRPCClient()) {
        self.client = client
    }

    public func fetchQuota() async throws -> ProviderQuota {
        let responseLine: Data
        do {
            responseLine = try await client.requestCodexRateLimits()
        } catch let transportError as JSONRPCTransportError {
            throw Self.map(transportError)
        }
        // Anything else (a client implementation throwing something other
        // than JSONRPCTransportError) is a programmer error in the client,
        // not a state we can classify — let it propagate.

        let envelope: RPCEnvelope
        do {
            envelope = try JSONDecoder().decode(RPCEnvelope.self, from: responseLine)
        } catch {
            // A response line that isn't even valid JSON-RPC is not a
            // provider error we understand well enough to name — fail
            // generically rather than guess.
            throw SourceUnavailable.failed(.codex)
        }

        if let rpcError = envelope.error {
            throw Self.map(rpcError)
        }
        guard let result = envelope.result, let rateLimits = result.rateLimits else {
            throw SourceUnavailable.failed(.codex)
        }
        return Self.buildQuota(
            from: rateLimits,
            additional: result.rateLimitsByLimitId,
            resets: result.rateLimitResetCredits
        )
    }

    /// Redeems one provider-issued reset. The UI confirms this action before
    /// calling it; this source only reports whether the provider accepted it.
    public func consumeReset(creditID: String) async throws -> Bool {
        guard !creditID.isEmpty else { throw SourceUnavailable.failed(.codex) }

        let responseLine: Data
        do {
            responseLine = try await client.consumeCodexRateLimitReset(creditID: creditID)
        } catch let transportError as JSONRPCTransportError {
            throw Self.map(transportError)
        }

        let envelope: ConsumeRPCEnvelope
        do {
            envelope = try JSONDecoder().decode(ConsumeRPCEnvelope.self, from: responseLine)
        } catch {
            throw SourceUnavailable.failed(.codex)
        }

        if let rpcError = envelope.error {
            throw Self.map(rpcError)
        }
        return envelope.result?.outcome == "reset"
    }

    // MARK: - Response shape

    /// A generic JSON-RPC response envelope. `result` and `error` are
    /// mutually exclusive per spec; we decode both as optional and let the
    /// caller decide which branch fired.
    struct RPCEnvelope: Decodable {
        let id: Int?
        let result: RateLimitsResult?
        let error: RPCErrorPayload?
    }

    struct RPCErrorPayload: Decodable {
        let code: Int
        let message: String
    }

    struct ConsumeRPCEnvelope: Decodable {
        let result: ConsumeResult?
        let error: RPCErrorPayload?
    }

    struct ConsumeResult: Decodable {
        let outcome: String?
    }

    struct RateLimitsResult: Decodable {
        let rateLimits: RateLimitsPayload?
        let rateLimitsByLimitId: [String: RateLimitsPayload]
        let rateLimitResetCredits: RateLimitResetCredits?

        private enum CodingKeys: String, CodingKey {
            case rateLimits
            case rateLimitsByLimitId
            case rateLimitResetCredits
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            rateLimits = try container.decodeIfPresent(RateLimitsPayload.self, forKey: .rateLimits)
            rateLimitsByLimitId = (try? container.decode([String: RateLimitsPayload].self, forKey: .rateLimitsByLimitId)) ?? [:]
            rateLimitResetCredits = try? container.decodeIfPresent(RateLimitResetCredits.self, forKey: .rateLimitResetCredits)
        }
    }

    struct RateLimitsPayload: Decodable {
        let limitId: String?
        let limitName: String?
        let primary: RateLimitWindow?
        let secondary: RateLimitWindow?
        let credits: RateLimitsCredits?
        let planType: String?

        private enum CodingKeys: String, CodingKey {
            case limitId, limitName, primary, secondary, credits, planType
        }

        // Custom init so one malformed optional field degrades gracefully
        // instead of failing the whole payload. This is the actual fix for
        // the live bug: the real API sends `credits.balance` as a JSON
        // *string*, not a number — a plain synthesized Decodable would throw
        // on that single field and the `guard let rateLimits = ...` in
        // `fetchQuota` would turn a perfectly good windows payload into
        // `.failed`. The windows are the primary value of this call; a bad
        // `credits` (or any other field we don't recognize the shape of)
        // must never take them down with it. `limitId` and `limitName` are
        // retained for model-specific group labels; `individualLimit`,
        // `spendControlReached`, and `rateLimitReachedType` remain intentionally
        // unmodeled, so Decodable drops them for free.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            limitId = try container.decodeIfPresent(String.self, forKey: .limitId)
            limitName = try container.decodeIfPresent(String.self, forKey: .limitName)
            primary = try container.decodeIfPresent(RateLimitWindow.self, forKey: .primary)
            secondary = try container.decodeIfPresent(RateLimitWindow.self, forKey: .secondary)
            planType = try container.decodeIfPresent(String.self, forKey: .planType)
        // `try?` on purpose: a credits shape we can't parse becomes
        // "no credits reported", not a fetch failure.
            credits = try? container.decodeIfPresent(RateLimitsCredits.self, forKey: .credits)
        }
    }

    struct RateLimitWindow: Decodable {
        let usedPercent: Double
        let windowDurationMins: Int
        let resetsAt: FlexibleDate?
    }

    struct RateLimitsCredits: Decodable {
        let balance: Double
        let hasCredits: Bool
        let unlimited: Bool

        private enum CodingKeys: String, CodingKey {
            case balance, hasCredits, unlimited
        }

        // The live API sends `balance` as a JSON string (e.g. "12.50"), not
        // a number, despite it being numeric data — accept either shape so a
        // provider-side type change (in either direction) doesn't throw.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            hasCredits = try container.decode(Bool.self, forKey: .hasCredits)
            unlimited = try container.decode(Bool.self, forKey: .unlimited)
            if let numeric = try? container.decode(Double.self, forKey: .balance) {
                balance = numeric
            } else {
                let text = try container.decode(String.self, forKey: .balance)
                guard let parsed = Double(text) else {
                    // Matches RateLimitsPayload's rule: an unparseable value
                    // degrades the field, it doesn't fail the decode. The
                    // caller (`try?` in RateLimitsPayload) turns this thrown
                    // error into "credits absent" rather than losing windows.
                    throw DecodingError.dataCorruptedError(
                        forKey: .balance,
                        in: container,
                        debugDescription: "balance is neither a number nor a numeric string"
                    )
                }
                balance = parsed
            }
        }

    }

    struct RateLimitResetCredits: Decodable {
        let availableCount: Int
        let credits: [RateLimitResetCredit]?

        private enum CodingKeys: String, CodingKey {
            case availableCount, credits
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            availableCount = try container.decode(Int.self, forKey: .availableCount)
            credits = try? container.decodeIfPresent([RateLimitResetCredit].self, forKey: .credits)
        }
    }

    struct RateLimitResetCredit: Decodable {
        let id: String
        let title: String?
        let status: String?
        let expiresAt: FlexibleDate?

        private enum CodingKeys: String, CodingKey {
            case id, title, status, expiresAt
        }
    }

    /// `resetsAt` has been observed as both an epoch-seconds number and an
    /// ISO-8601 string across Codex builds; decode defensively rather than
    /// pick one and break on the other. An unparseable or absent value
    /// becomes `nil` — callers already treat `nil` as "provider didn't say".
    struct FlexibleDate: Decodable {
        let date: Date?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                date = Date(timeIntervalSince1970: seconds)
                return
            }
            if let text = try? container.decode(String.self) {
                if let iso = ISO8601DateFormatter().date(from: text) {
                    date = iso
                    return
                }
                if let secondsFromText = Double(text) {
                    date = Date(timeIntervalSince1970: secondsFromText)
                    return
                }
            }
            date = nil
        }
    }

    // MARK: - Parsing

    private static func buildQuota(
        from payload: RateLimitsPayload,
        additional: [String: RateLimitsPayload],
        resets: RateLimitResetCredits?
    ) -> ProviderQuota {
        let baseWindows = windows(from: payload)
        var groups: [QuotaGroup] = []
        if !baseWindows.isEmpty {
            groups.append(
                QuotaGroup(
                    id: payload.limitId ?? "codex",
                    title: "General usage limits",
                    windows: baseWindows
                )
            )
        }

        let baseID = payload.limitId ?? "codex"
        for (key, extra) in additional.sorted(by: { $0.key < $1.key }) {
            let extraID = extra.limitId ?? key
            guard extraID != baseID, key != baseID else { continue }
            let extraWindows = windows(from: extra)
            guard !extraWindows.isEmpty else { continue }
            groups.append(
                QuotaGroup(
                    id: extraID,
                    title: "\(extra.limitName ?? key) usage limits",
                    windows: extraWindows
                )
            )
        }

        let credits = payload.credits.map {
            CreditBalance(
                balance: $0.balance,
                hasCredits: $0.hasCredits,
                unlimited: $0.unlimited,
                unit: .credits,
                dollarBalance: CodexCreditConversion.dollars(for: $0.balance)
            )
        }
        let resetCredits = resets?.credits?.map {
            QuotaResetCredit(
                id: $0.id,
                title: $0.title ?? "Full reset",
                status: $0.status,
                expiresAt: $0.expiresAt?.date
            )
        } ?? []
        return ProviderQuota(
            provider: .codex,
            windows: baseWindows,
            groups: groups,
            credits: credits,
            resetCreditCount: resets?.availableCount,
            resetCredits: resetCredits,
            planType: payload.planType,
            capturedAt: Date()
        )
    }

    private static func windows(from payload: RateLimitsPayload) -> [QuotaWindow] {
        [payload.primary, payload.secondary].compactMap { window in
            guard let window else { return nil }
            return QuotaWindow(
                label: label(for: window),
                usedPercent: window.usedPercent,
                resetsAt: window.resetsAt?.date
            )
        }
    }

    /// Classify by duration, never by primary/secondary position.
    ///
    /// Codex has changed which slot ("primary" vs "secondary") holds the
    /// 5-hour window versus the weekly window depending on plan — a real bug
    /// shipped once from assuming "primary == 5-hour". `windowDurationMins`
    /// is the one field that reliably identifies the window regardless of
    /// which position it arrived in, so that's what we switch on. 1440
    /// minutes = 24h is the cutoff: Codex's short window is measured in
    /// hours (5h), its long window in days (weekly), so anything a full day
    /// or longer is "Weekly".
    private static func label(for window: RateLimitWindow) -> String {
        window.windowDurationMins >= 1440 ? "Weekly" : "5-hour"
    }

    // MARK: - Error mapping

    private static func map(_ transportError: JSONRPCTransportError) -> SourceUnavailable {
        switch transportError {
        case .processNotFound:
            return .cliNotFound("codex")
        case .timeout, .processExited:
            return .failed(.codex)
        }
    }

    private static func map(_ rpcError: RPCErrorPayload) -> SourceUnavailable {
        let message = rpcError.message.lowercased()
        // codex-cli's exact wording for "not logged in" wasn't available to
        // confirm empirically on this machine (that requires a logged-out
        // install), so this matches on the vocabulary CLIs in this family
        // commonly use for the state rather than one exact string. Anything
        // that doesn't match falls through to `.failed`, per the mapping
        // rule: never guess past what we can name confidently.
        if message.contains("not logged in") || message.contains("not authenticated") || message.contains("sign in") {
            return .notSignedIn(.codex)
        }
        // Verified: code -32603 with a message mentioning the backend is
        // unreachable is how a network-down `account/rateLimits/read` call
        // reports offline.
        if rpcError.code == -32603
            && (message.contains("reach") || message.contains("backend") || message.contains("network") || message.contains("connect")) {
            return .offline
        }
        return .failed(.codex)
    }
}
