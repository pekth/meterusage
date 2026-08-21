import Foundation
import UserNotifications

// MARK: - Quota alerts
//
// Local notifications when a quota window crosses a threshold, or an earned
// reset credit is about to expire. The whole feature is opt-in: the toggle in
// Settings both stores the preference and triggers the permission prompt, so
// a fresh install never asks for notification access unprompted.
//
// Delivery is edge-triggered, not level-triggered: an alert fires on the
// refresh where usage *crosses* a threshold upward, and never again while it
// stays above it. A level-triggered design would post the same notification
// every 60 seconds for the rest of the window.

/// Thresholds for one window's consumed percentage. Ordered ascending; the
/// highest crossed threshold wins so a single jump from 40% to 96% posts one
/// critical alert, not two.
enum QuotaAlertThreshold: Int, CaseIterable {
    case warning = 80
    case critical = 95

    var title: String {
        switch self {
        case .warning: return "Quota getting low"
        case .critical: return "Quota almost gone"
        }
    }
}

/// One alertable observation, produced by the evaluator.
enum QuotaAlertEvent: Equatable {
    /// A window crossed `threshold` upward this refresh.
    case threshold(provider: Provider, windowLabel: String, usedPercent: Double, threshold: QuotaAlertThreshold)
    /// A reset credit will expire within `ExpiringCredit.window`.
    case expiringCredit(provider: Provider, creditID: String, creditTitle: String)

    var provider: Provider {
        switch self {
        case .threshold(let provider, _, _, _): return provider
        case .expiringCredit(let provider, _, _): return provider
        }
    }
}

/// Pure crossing detection, split from delivery so it is testable without
/// notification permissions.
struct QuotaAlertEvaluator {

    /// How far ahead an expiring reset credit is worth flagging.
    static let expiringCreditWindow: TimeInterval = 24 * 60 * 60

    /// Highest used percent already alerted per `provider + window label`.
    /// Keyed by label rather than identity because `QuotaWindow` has no stable
    /// id across refreshes; labels are provider-stable ("5-hour", "Weekly").
    private var highWater: [String: Double] = [:]
    /// Reset credits already flagged as expiring, so one credit warns once.
    private var flaggedCredits: Set<String> = []

    /// Compares this refresh's quotas against prior state and returns the new
    /// events to deliver. Must be called with every enabled provider's latest
    /// result each sweep — a provider missing from `quotas` keeps its old
    /// high-water mark rather than being silently re-armed.
    mutating func events(for quotas: [Provider: Loaded<ProviderQuota>], now: Date) -> [QuotaAlertEvent] {
        var events: [QuotaAlertEvent] = []

        for (provider, state) in quotas {
            guard let quota = state.value else { continue }

            for window in quota.windows {
                let key = "\(provider.rawValue)/\(window.label)"
                let previous = highWater[key] ?? 0

                // A drop below the last alerted threshold re-arms the ladder:
                // after the window resets (or usage otherwise falls), a fresh
                // climb past a threshold alerts again.
                if window.usedPercent < previous - 0.001 {
                    highWater[key] = 0
                }

                let rearmedPrevious = highWater[key] ?? 0
                if window.usedPercent > rearmedPrevious,
                   let threshold = QuotaAlertThreshold.allCases.last(where: { window.usedPercent >= Double($0.rawValue) }),
                   rearmedPrevious < Double(threshold.rawValue) {
                    events.append(.threshold(
                        provider: provider,
                        windowLabel: window.label,
                        usedPercent: window.usedPercent,
                        threshold: threshold
                    ))
                }
                highWater[key] = max(rearmedPrevious, window.usedPercent)
            }

            for credit in quota.resetCredits {
                let key = "\(provider.rawValue)/\(credit.id)"
                guard !flaggedCredits.contains(key),
                      let expiresAt = credit.expiresAt,
                      expiresAt > now,
                      expiresAt.timeIntervalSince(now) <= Self.expiringCreditWindow else { continue }
                flaggedCredits.insert(key)
                events.append(.expiringCredit(
                    provider: provider,
                    creditID: credit.id,
                    creditTitle: credit.title
                ))
            }
        }

        return events
    }
}

/// Delivers evaluator events as local notifications, gated on the user
/// preference. Owns authorization so the rest of the app never touches
/// `UNUserNotificationCenter`.
@MainActor
final class QuotaAlertService {

    private let preferences: Preferences
    private var evaluator = QuotaAlertEvaluator()
    /// `nil` when notifications are unavailable — notably under a bare
    /// `swift run` binary, where touching `UNUserNotificationCenter.current()`
    /// traps because the process has no bundle. Alert delivery then becomes a
    /// no-op instead of crashing the whole app at launch.
    private let center: UNUserNotificationCenter?

    init(preferences: Preferences, center: UNUserNotificationCenter? = nil) {
        self.preferences = preferences
        self.center = center ?? Self.defaultCenterIfAvailable()
    }

    private static func defaultCenterIfAvailable() -> UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return .current()
    }

    /// Called by the coordinator after each sweep with the full quota map.
    func process(quotas: [Provider: Loaded<ProviderQuota>], now: Date = Date()) {
        guard preferences.quotaAlertsEnabled, let center else { return }
        let events = evaluator.events(for: quotas, now: now)
        guard !events.isEmpty else { return }
        Task {
            // Authorization is requested lazily on the first eligible event
            // after the user opts in. If they denied it at the system level,
            // delivery is simply a no-op — no second prompt, no error surface.
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }
            for event in events {
                let request = Self.request(for: event)
                try? await center.add(request)
            }
        }
    }

    /// Asks the system for notification permission. Invoked from Settings when
    /// the user switches alerts on, so the prompt appears in direct response
    /// to their action.
    func requestAuthorization() {
        guard let center else { return }
        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    /// Builds the delivered notification. Bodies carry percentages and labels
    /// only — never account detail, paths, or raw provider payloads.
    private static func request(for event: QuotaAlertEvent) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        switch event {
        case .threshold(let provider, let windowLabel, let usedPercent, let threshold):
            content.title = threshold.title
            content.body = "\(provider.displayName) \(windowLabel) window is at \(Fmt.percent(usedPercent)) used."
            content.sound = threshold == .critical ? .default : nil
        case .expiringCredit(let provider, _, let creditTitle):
            content.title = "Reset credit expiring"
            content.body = "A \(provider.displayName) reset credit (\(creditTitle)) expires within 24 hours."
        }
        return UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    }
}
