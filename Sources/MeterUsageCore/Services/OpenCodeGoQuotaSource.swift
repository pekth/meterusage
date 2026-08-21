import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reads OpenCode Go's account usage limits from its authenticated Zen API.
///
/// OpenCode Go is a subscription with three server-enforced windows — a rolling
/// allowance, a weekly allowance, and a monthly allowance — each reported as a
/// percentage used and a reset time. They live on the same control plane the
/// opencode CLI talks to (`https://opencode.ai/zen/go/v1/usage`), authenticated
/// with the API key opencode's `/connect` wrote to `~/.local/share/opencode/
/// auth.json`.
///
/// This source only reads the aggregate percentage and reset fields. It never
/// sends prompts, model requests, or the key anywhere except the endpoint's
/// Authorization header, and it never reads prompt text or workspace paths.
public struct OpenCodeGoQuotaSource: QuotaSource {
    public let provider: Provider = .openCodeGo

    private let apiKey: String?
    private let endpoint: URL
    private let session: URLSession

    public init(
        apiKey: String? = nil,
        endpoint: URL? = nil,
        session: URLSession = OpenCodeGoQuotaSource.defaultSession()
    ) {
        self.apiKey = apiKey ?? Self.discoverAPIKey()
        self.endpoint = endpoint ?? URL(string: "https://opencode.ai/zen/go/v1/usage")!
        self.session = session
    }

    public func fetchQuota() async throws -> ProviderQuota {
        guard let key = Self.normalized(apiKey) else {
            throw SourceUnavailable.dataNotFound("OpenCode Go API key")
        }

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("meterusage/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")

        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch let error as URLError where error.isOffline {
            throw SourceUnavailable.offline
        } catch {
            throw SourceUnavailable.failed(.openCodeGo)
        }

        do {
            return try Self.parse(data: data, now: Date())
        } catch let unavailable as SourceUnavailable {
            throw unavailable
        } catch {
            throw SourceUnavailable.failed(.openCodeGo)
        }
    }

    /// Parses the Zen usage payload into the three quota windows.
    ///
    /// ```json
    /// {"usage":{
    ///   "rolling":{"status":"ok","percent":1,"resetsAt":"2026-08-15T23:00:20Z"},
    ///   "weekly": {"status":"ok","percent":77,"resetsAt":"2026-08-17T00:00:00Z"},
    ///   "monthly":{"status":"ok","percent":44,"resetsAt":"2026-09-07T07:15:09Z"}}}
    /// ```
    /// `status` other than "ok" (e.g. "over_limit") is not an error here — the
    /// window still carries its percentage and reset, which is exactly what a
    /// user needs to see when they've hit a limit.
    public static func parse(data: Data, now: Date) throws -> ProviderQuota {
        let response: UsageResponse
        do {
            // The Zen API emits fractional-second ISO8601 timestamps
            // (e.g. `2026-08-15T23:00:20.504Z`), which the default decoder
            // rejects. A fractional-aware formatter is required.
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let raw = try container.decode(String.self)
                let fractional = ISO8601DateFormatter()
                fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = fractional.date(from: raw) { return date }
                let whole = ISO8601DateFormatter()
                whole.formatOptions = [.withInternetDateTime]
                if let date = whole.date(from: raw) { return date }
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unparseable ISO8601 timestamp: \(raw)"
                )
            }
            response = try decoder.decode(UsageResponse.self, from: data)
        } catch {
            // The endpoint returns `{"type":"error",...}` for auth failures.
            if let errorBody = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                switch errorBody.error.type.lowercased() {
                case "autherror", "invalid_api_key":
                    throw SourceUnavailable.notSignedIn(.openCodeGo)
                default:
                    throw SourceUnavailable.failed(.openCodeGo)
                }
            }
            throw SourceUnavailable.failed(.openCodeGo)
        }

        let windows = [
            QuotaWindow(label: "Rolling", usedPercent: response.usage.rolling.percent, resetsAt: response.usage.rolling.resetsAt),
            QuotaWindow(label: "Weekly", usedPercent: response.usage.weekly.percent, resetsAt: response.usage.weekly.resetsAt),
            QuotaWindow(label: "Monthly", usedPercent: response.usage.monthly.percent, resetsAt: response.usage.monthly.resetsAt)
        ]

        return ProviderQuota(
            provider: .openCodeGo,
            windows: windows,
            planType: "go",
            capturedAt: now
        )
    }

    // MARK: Key discovery

    private static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Reads the OpenCode Go API key from the file `opencode /connect` writes:
    /// `~/.local/share/opencode/auth.json`, an object keyed by provider.
    private static func discoverAPIKey() -> String? {
        discoverAPIKey(from: HomeDirectory.real
            .appendingPathComponent(".local/share/opencode", isDirectory: true)
            .appendingPathComponent("auth.json"))
    }

    /// The test seam: discovery logic, parameterised by the auth file URL.
    public static func discoverAPIKey(from authURL: URL) -> String? {
        guard let data = try? Data(contentsOf: authURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = object["opencode-go"] as? [String: Any] else {
            return nil
        }
        return normalized(entry["key"] as? String)
    }

    public static func defaultSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }

    // MARK: Decodable

    private struct UsageResponse: Decodable {
        let usage: Usage
    }

    private struct Usage: Decodable {
        let rolling: Window
        let weekly: Window
        let monthly: Window
    }

    private struct Window: Decodable {
        let status: String
        let percent: Double
        let resetsAt: Date?
    }

    private struct ErrorResponse: Decodable {
        let error: ErrorBody
    }

    private struct ErrorBody: Decodable {
        let type: String
    }
}

private extension URLError {
    var isOffline: Bool {
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .dataNotAllowed:
            return true
        default:
            return false
        }
    }
}
