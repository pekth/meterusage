import SwiftUI

/// Compact usage rows for providers whose native history is not a quota window.
///
/// The row uses a provider accent for identity and a written metric label for
/// meaning. Grok stays count-based because its local store does not expose
/// billable token totals; Antigravity and OpenCode Go show the measured totals
/// they have.
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

struct ProviderUsageRow: View {
    let provider: Provider
    let state: Loaded<ProviderUsage>
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ProviderMark(provider: provider, tint: providerColor(provider))
                .frame(width: 13, height: 13)
                .padding(.top, 2)
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
            if provider != .anthropic {
                Text(provider == .openAI ? "\(Fmt.count(usage.messageCount)) requests" : Fmt.count(usage.messageCount))
                    .font(.muNumber)
                    .foregroundColor(providerColor(provider))
            }
        case .idle, .missing:
            EmptyView()
        }
    }

    @ViewBuilder
    var detail: some View {
        switch state {
        case .idle:
            Text(provider.isOrganizationAPI ? "Checking API usage…" : "Checking local history…")
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
            if provider.isOrganizationAPI {
                APIUsageDetails(usage: usage, now: now)
            } else if let windows = usage.usageWindows, !windows.isEmpty {
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
            return "\(provider.displayName): checking usage"
        case .missing(let reason):
            return "\(provider.displayName): \(reason.userFacingMessage)"
        case .value(let usage):
            if provider == .anthropic {
                return "Anthropic API, last 30 days, \(usage.tokens?.total ?? 0) tokens, reported spend \(Fmt.usd(usage.estimatedCostUSD ?? 0)), excludes Priority Tier costs"
            }
            if provider == .openAI {
                return "OpenAI API, last 30 days, \(usage.messageCount) completion requests, \(usage.tokens?.total ?? 0) tokens, reported spend \(Fmt.usd(usage.estimatedCostUSD ?? 0))"
            }
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
        if provider.isOrganizationAPI {
            switch reason {
            case .dataNotFound, .notSignedIn:
                if provider == .anthropic {
                    return "Connect in Settings → Providers → Anthropic API with a Console organization Admin key. Individual accounts, workspace keys, and Claude subscription logins cannot supply this reading."
                }
                return "Connect in Settings → Providers → OpenAI API with an organization Admin key that has usage access. A project API key or Codex login cannot supply this reading."
            case .offline: return "Connect to the internet, then refresh API usage."
            default: return "API usage is unavailable. Will retry on the next refresh."
            }
        }
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

/// Organization spend and endpoint-specific tokens, without invented request counts.
private struct APIUsageDetails: View {
    let usage: ProviderUsage
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(usage.usageWindows ?? [], id: \.label) { window in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(window.label == "last 30d" ? "Last 30 days (UTC)" : window.label)
                        Spacer(minLength: 4)
                        Text(Fmt.usd(window.estimatedCostUSD)).monospacedDigit()
                    }
                    .font(.muBody)
                    .foregroundColor(MU.text)
                    Text(usage.provider == .anthropic
                         ? "\(Fmt.compactCount(window.tokens.total)) tokens"
                         : "\(Fmt.compactCount(window.tokens.total)) tokens · \(Fmt.count(window.messageCount)) completion requests")
                        .font(.muCaption)
                        .foregroundColor(MU.textSecondary)
                }
            }
            Text(usage.provider == .anthropic
                 ? "Reported API spend excludes Priority Tier. Tokens cover Messages API. Reporting can lag."
                 : "Organization spend reported by OpenAI. Tokens cover completions only. Reporting can lag.")
                .font(.muCaption)
                .foregroundColor(MU.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Updated \(Fmt.timeSince(usage.capturedAt, now: now))")
                .font(.muCaption)
                .foregroundColor(MU.textTertiary)
            Link("Open usage dashboard", destination: URL(string: usage.provider == .anthropic
                 ? "https://platform.claude.com/usage" : "https://platform.openai.com/usage")!)
                .font(.muCaption)
        }
    }
}

/// Rolling usage windows as bars.
///
/// For providers without quota limits (like OpenCode Go), percentages reflect
/// the share of the last-30-day reference window. If monetary spend is available,
/// cost is used; otherwise token totals are used.
private struct UsageWindowBars: View {
    let windows: [UsageWindow]
    let provider: Provider
    let now: Date

    private var referenceCost: Double {
        windows.first { $0.label == "last 30d" }?.estimatedCostUSD ?? 0
    }

    private var referenceTokens: Int {
        windows.first { $0.label == "last 30d" }?.tokens.total ?? 0
    }

    private var usesCost: Bool {
        referenceCost > 0
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
            Text(summaryLine)
                .font(.muCaption)
                .foregroundColor(MU.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(captionLine)
                .font(.muCaption)
                .foregroundColor(MU.textTertiary)
        }
    }

    private var summaryLine: String {
        var parts = [
            "\(Fmt.count(count(of: "last 30d"))) sessions",
            "\(Fmt.count(messages(of: "last 30d"))) messages",
            "\(Fmt.compactCount(tokens(of: "last 30d").total)) tokens"
        ]
        if usesCost {
            parts.append("~\(Fmt.usd(referenceCost))")
        }
        parts.append("updated \(Fmt.timeSince(now))")
        return parts.joined(separator: " · ")
    }

    private var captionLine: String {
        usesCost
            ? "Share of last 30d usage · est. \(Pricing.snapshotLabel) rates"
            : "Share of last 30d tokens"
    }

    private func percent(of window: UsageWindow) -> Double {
        fraction(of: window) * 100
    }

    private func fraction(of window: UsageWindow) -> Double {
        if usesCost {
            return window.shareOf30Days(referenceCost: referenceCost)
        }
        return window.shareOf30Days(referenceTokens: referenceTokens)
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
