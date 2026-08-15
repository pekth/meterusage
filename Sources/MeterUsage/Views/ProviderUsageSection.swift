import SwiftUI

/// Compact usage rows for providers whose native history is not a quota window.
///
/// The row uses a provider accent for identity and a written metric label for
/// meaning. Antigravity/Grok stay count-based because their local stores do not
/// expose billable token totals; OpenCode Go shows the measured totals it has.
struct ProviderUsageSection: View {
    let usages: [Provider: Loaded<ProviderUsage>]
    let providers: [Provider]
    let now: Date

    var body: some View {
        if !providers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("Usage")
                Card {
                    VStack(spacing: 0) {
                        ForEach(Array(providers.enumerated()), id: \.element) { index, provider in
                            if index > 0 {
                                Divider().overlay(MU.hairline).padding(.vertical, 9)
                            }
                            ProviderUsageRow(
                                provider: provider,
                                state: usages[provider] ?? .idle,
                                now: now
                            )
                        }
                    }
                }
            }
        }
    }
}

private struct ProviderUsageRow: View {
    let provider: Provider
    let state: Loaded<ProviderUsage>
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusDot(color: providerColor(provider), diameter: 8)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(provider.displayName)
                        .font(.muTitle)
                        .foregroundColor(MU.text)
                    Spacer(minLength: 4)
                    trailingValue
                }
                detail
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var trailingValue: some View {
        switch state {
        case .value(let usage):
            Text(Fmt.count(usage.messageCount))
                .font(.muNumber)
                .foregroundColor(providerColor(provider))
        case .idle, .missing:
            EmptyView()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch state {
        case .idle:
            Text("Checking local history…")
                .font(.muCaption)
                .foregroundColor(MU.textTertiary)
        case .missing(let reason):
            VStack(alignment: .leading, spacing: 2) {
                Text(reason.userFacingMessage)
                    .font(.muBody)
                    .foregroundColor(reasonIsWarning(reason) ? MU.warn : MU.textSecondary)
                Text(hint(for: reason))
                    .font(.muCaption)
                    .foregroundColor(MU.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .value(let usage):
            if let windows = usage.usageWindows, !windows.isEmpty {
                // Rolling-window view (OpenCode Go): one row per window with a
                // share-of-30d bar + percentage, then counts, then a caption.
                UsageWindowBars(windows: windows, provider: provider, now: now)
            } else {
                HStack(spacing: 5) {
                    Text("\(usage.sessionCount) session\(usage.sessionCount == 1 ? "" : "s")")
                    Text("·")
                    Text("\(Fmt.count(usage.messageCount)) messages")
                    if let tokens = usage.tokens {
                        Text("·")
                        Text("\(Fmt.compactCount(tokens.total)) tokens")
                    }
                    if let cost = usage.estimatedCostUSD {
                        Text("·")
                        Text("~\(Fmt.usd(cost))")
                    }
                }
                .font(.muCaption)
                .foregroundColor(MU.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

                if usage.todayMessageCount > 0 || usage.todaySessionCount > 0 {
                    Text("Today: \(usage.todaySessionCount) session\(usage.todaySessionCount == 1 ? "" : "s") · \(Fmt.count(usage.todayMessageCount)) messages · updated \(Fmt.timeSince(usage.capturedAt, now: now))")
                        .font(.muCaption)
                        .foregroundColor(MU.textTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                } else if usage.tokens != nil {
                    Text("Updated \(Fmt.timeSince(usage.capturedAt, now: now)) · measured token totals")
                        .font(.muCaption)
                        .foregroundColor(MU.textTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                } else {
                    Text("Updated \(Fmt.timeSince(usage.capturedAt, now: now)) · token totals unavailable")
                        .font(.muCaption)
                        .foregroundColor(MU.textTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .idle:
            return "\(provider.displayName): checking local history"
        case .missing(let reason):
            return "\(provider.displayName): \(reason.userFacingMessage)"
        case .value(let usage):
            var parts = [
                provider.displayName,
                "\(usage.sessionCount) sessions",
                "\(usage.messageCount) messages"
            ]
            if let tokens = usage.tokens { parts.append("\(tokens.total) tokens") }
            if let cost = usage.estimatedCostUSD { parts.append("about \(Fmt.usd(cost))") }
            return parts.joined(separator: ", ")
        }
    }

    private func reasonIsWarning(_ reason: SourceUnavailable) -> Bool {
        if case .failed = reason { return true }
        return false
    }

    private func hint(for reason: SourceUnavailable) -> String {
        switch reason {
        case .cliNotFound(let name): return "Install \(name) to read local usage."
        case .dataNotFound: return "Enable this provider after its local history is available."
        case .noData: return "Usage appears after the first session."
        case .notSignedIn: return "Sign in with the \(provider.displayName) CLI."
        case .offline: return "Local usage remains available when the provider is online."
        case .failed: return "Will retry on the next refresh."
        }
    }
}

/// Rolling usage windows (OpenCode Go) as bars.
///
/// OpenCode exposes no quota limit, so a percentage cannot mean "of your
/// allowance". Instead each window's bar is its share of the *last 30 days*
/// cost — the reference window — so "last 24h at 45%" reads as "45% of this
/// month's spend happened in the last day". The 30d row is always 100%.
private struct UsageWindowBars: View {
    let windows: [UsageWindow]
    let provider: Provider
    let now: Date

    private var referenceCost: Double {
        windows.first { $0.label == "last 30d" }?.estimatedCostUSD ?? 0
    }

    private var tint: Color { providerColor(provider) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(windows, id: \.label) { window in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(window.label)
                            .font(.muBody)
                            .foregroundColor(MU.textSecondary)
                        Spacer(minLength: 4)
                        Text(Fmt.percent(percent(of: window)))
                            .font(.muNumber)
                            .foregroundColor(tint)
                    }
                    MeterBar(fraction: fraction(of: window), tint: tint)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(window.label), \(Fmt.percent(percent(of: window))) of last 30 days")
            }
            Text("\(Fmt.count(count(of: "last 30d"))) sessions · \(Fmt.count(messages(of: "last 30d"))) messages · \(Fmt.compactCount(tokens(of: "last 30d").total)) tokens · ~\(Fmt.usd(referenceCost)) · updated \(Fmt.timeSince(now))")
                .font(.muCaption)
                .foregroundColor(MU.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text("Share of last 30d usage")
                .font(.muCaption)
                .foregroundColor(MU.textTertiary)
        }
    }

    private func percent(of window: UsageWindow) -> Double {
        window.shareOf30Days(referenceCost: referenceCost) * 100
    }

    private func fraction(of window: UsageWindow) -> Double {
        window.shareOf30Days(referenceCost: referenceCost)
    }

    private func count(of label: String) -> Int {
        windows.first { $0.label == label }?.sessionCount ?? 0
    }

    private func messages(of label: String) -> Int {
        windows.first { $0.label == label }?.messageCount ?? 0
    }

    private func tokens(of label: String) -> TokenTotals {
        windows.first { $0.label == label }?.tokens ?? TokenTotals()
    }
}
