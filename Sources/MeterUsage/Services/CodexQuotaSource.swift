import Foundation

/// Live quota for Codex, read via `codex app-server`'s JSON-RPC interface.
///
/// This type never touches `~/.codex/auth.json` and never spawns a process
/// directly — it delegates the RPC exchange to a `JSONRPCClient`, which keeps
/// auth entirely inside the `codex` subprocess (it manages its own login
/// state) and keeps this type unit-testable without a real CLI installed.
public struct CodexQuotaSource: QuotaSource {
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
        guard let rateLimits = envelope.result?.rateLimits else {
            throw SourceUnavailable.failed(.codex)
        }
        return Self.buildQuota(from: rateLimits)
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

    struct RateLimitsResult: Decodable {
        let rateLimits: RateLimitsPayload?
    }

    struct RateLimitsPayload: Decodable {
        let primary: RateLimitWindow?
        let secondary: RateLimitWindow?
        let credits: RateLimitsCredits?
        let planType: String?

        private enum CodingKeys: String, CodingKey {
            case primary, secondary, credits, planType
        }

        // Custom init so one malformed optional field degrades gracefully
        // instead of failing the whole payload. This is the actual fix for
        // the live bug: the real API sends `credits.balance` as a JSON
        // *string*, not a number — a plain synthesized Decodable would throw
        // on that single field and the `guard let rateLimits = ...` in
        // `fetchQuota` would turn a perfectly good windows payload into
        // `.failed`. The windows are the primary value of this call; a bad
        // `credits` (or any other field we don't recognize the shape of)
        // must never take them down with it. `limitId`, `limitName`,
        // `individualLimit`, `spendControlReached`, `rateLimitReachedType`
        // are intentionally not modeled at all — Decodable ignores keys with
        // no matching property, so they're dropped for free.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
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

    private static func buildQuota(from payload: RateLimitsPayload) -> ProviderQuota {
        var windows: [QuotaWindow] = []
        for window in [payload.primary, payload.secondary].compactMap({ $0 }) {
            windows.append(QuotaWindow(label: label(for: window), usedPercent: window.usedPercent, resetsAt: window.resetsAt?.date))
        }
        let credits = payload.credits.map {
            CreditBalance(balance: $0.balance, hasCredits: $0.hasCredits, unlimited: $0.unlimited)
        }
        return ProviderQuota(
            provider: .codex,
            windows: windows,
            credits: credits,
            planType: payload.planType,
            capturedAt: Date()
        )
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
