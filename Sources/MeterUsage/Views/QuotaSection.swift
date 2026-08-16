import SwiftUI

/// Per-provider quota card.
///
/// THE CENTRAL UX RULE HERE: a provider having nothing to report is the *normal*
/// state, not a failure. Most machines have exactly one of the two CLIs
/// installed, and a fresh install has run nothing yet. Only `.failed` — "we
/// tried and it genuinely went wrong" — gets a warning tone; every other
/// `SourceUnavailable` renders as a calm, grey, one-line note.
///
/// All user-visible wording for unavailability comes from
/// `SourceUnavailable.userFacingMessage`. Nothing here invents error text, and
/// no underlying error is ever displayed — provider errors can carry URLs,
/// headers and account hints into a screenshot.
struct QuotaSection: View {

    let provider: Provider
    let state: Loaded<ProviderQuota>
    /// Subscription tier, where the provider exposes one separately from its
    /// quota. Defaults to `.idle` so a build with no plan source is a no-op.
    var plan: Loaded<PlanTier> = .idle
    /// Ticks each minute so "resets in" labels stay honest between refreshes.
    let now: Date
    /// Optional so demo/read-only quota sources can render the same rows
    /// without pretending they can mutate the provider account.
    let onUseReset: ((String) async throws -> Void)?
    /// Codex-only: the session-count heatmap rendered at the card's foot, so
    /// all Codex figures live in one card. Empty for every other provider,
    /// which leaves their cards unchanged.
    var codexHeatmapDaily: [DailyActivity] = []

    @State private var resetPrompt: ResetPrompt?
    @State private var consumingResetID: String?

    @AppStorage(PrefKey.showHeatmap) private var showHeatmap: Bool = true

    init(
        provider: Provider,
        state: Loaded<ProviderQuota>,
        plan: Loaded<PlanTier> = .idle,
        now: Date,
        onUseReset: ((String) async throws -> Void)? = nil,
        codexHeatmapDaily: [DailyActivity] = []
    ) {
        self.provider = provider
        self.state = state
        self.plan = plan
        self.now = now
        self.onUseReset = onUseReset
        self.codexHeatmapDaily = codexHeatmapDaily
    }

    var body: some View {
        Card {
            header
            content
        }
        // Keep confirmation, success, and failure in one presenter. Multiple
        // `.alert` modifiers on the same SwiftUI view can compete on macOS,
        // leaving the reset button looking inert.
        .alert(item: $resetPrompt) { prompt in
            switch prompt.kind {
            case .confirmation(let credit):
                return Alert(
                    title: Text("Use reset?"),
                    message: Text("This will consume one reset credit and reset your Codex usage limits."),
                    primaryButton: .destructive(Text("Use reset")) {
                        beginUseReset(creditID: credit.id)
                    },
                    secondaryButton: .cancel()
                )
            case .success:
                return Alert(
                    title: Text("Reset applied"),
                    message: Text("Codex usage limits were reset and the dashboard was refreshed."),
                    dismissButton: .default(Text("OK"))
                )
            case .failure(let title, let message):
                return Alert(
                    title: Text(title),
                    message: Text(message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 6) {
            StatusDot(color: providerColor(provider), diameter: 7)
            Text(provider.displayName)
                .font(.muTitle)
                .foregroundColor(MU.text)

            if let label = planLabel {
                PlanBadge(text: label)
            }

            Spacer(minLength: 0)

            if let quota = state.value, let peak = quota.windows.map(\.usedPercent).max() {
                Text(provider == .codex ? Fmt.remainingPercent(peak) : Fmt.percent(peak))
                    .font(.muNumber)
                    .foregroundColor(headroomColor(usedPercent: peak))
            }
        }
    }

    /// The plan to show beside the provider name, or `nil` to show nothing.
    ///
    /// Two providers, two routes to the same fact: Claude's tier arrives from a
    /// dedicated `PlanSource`, Codex reports its own inline with the quota. Both
    /// land in the same badge so the popover doesn't present the same idea two
    /// different ways.
    ///
    /// A plan that is absent, unreadable, or blank renders *nothing at all*. An
    /// "Unknown plan" badge would occupy the same space as real information
    /// while carrying none, and the percentages beside it are correct with or
    /// without it.
    private var planLabel: String? {
        if let tier = plan.value {
            return Self.nonEmpty(tier.displayName)
        }
        // Reported verbatim: this is the provider's own word for the plan, and
        // reshaping it risks turning an unfamiliar tier into a familiar-looking
        // one that doesn't exist.
        return Self.nonEmpty(state.value?.planType ?? "")
    }

    private static func nonEmpty(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            contentBody
            heatmapFooter
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        switch state {
        case .idle:
            // Distinct from "no data": we simply haven't looked yet.
            InfoState(message: "Checking…")
                .transition(.opacity)

        case .missing(let reason):
            InfoState(
                message: reason.userFacingMessage,
                hint: Self.hint(for: reason, provider: provider),
                isWarning: Self.isWarning(reason)
            )
            .transition(.opacity)

        case .value(let quota):
            let groups = quota.groups.isEmpty
                ? (quota.windows.isEmpty
                    ? []
                    : [QuotaGroup(id: "legacy", title: "", windows: quota.windows)])
                : quota.groups

            let hasResetCredits = (quota.resetCreditCount ?? 0) > 0 || !quota.resetCredits.isEmpty
            if groups.isEmpty && quota.credits == nil && !hasResetCredits {
                InfoState(message: SourceUnavailable.noData.userFacingMessage,
                          hint: "Usage appears once you've made some requests.")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(groups, id: \.id) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            if !group.title.isEmpty {
                                Text(group.title)
                                    .font(.muBody.weight(.semibold))
                                    .foregroundColor(MU.text)
                            }
                            ForEach(Array(group.windows.enumerated()), id: \.offset) { _, window in
                                WindowRow(provider: provider, window: window, now: now)
                            }
                        }
                    }
                    if let count = quota.resetCreditCount, count > 0 {
                        ResetCreditsSection(
                            count: count,
                            credits: quota.resetCredits,
                            now: now,
                            canUseReset: onUseReset != nil,
                            consumingResetID: consumingResetID,
                            onRequestUse: { resetPrompt = ResetPrompt(kind: .confirmation($0)) }
                        )
                    }
                    if let credits = quota.credits {
                        CreditsRow(provider: provider, credits: credits)
                    }
                }
                .transition(.opacity)
            }
        }
    }

    /// Codex's weekly session heatmap, sharing the card its usage windows live
    /// in. Governed by the same "Show heatmap" preference as the Local
    /// activity grid, so one toggle controls every heatmap in the popover.
    @ViewBuilder
    private var heatmapFooter: some View {
        if provider == .codex, showHeatmap, !codexHeatmapDaily.isEmpty {
            Divider().overlay(MU.hairline).padding(.vertical, 12)
            HeatmapView(daily: codexHeatmapDaily, today: now, intensity: .sessions)
            HStack(spacing: 5) {
                Text("\(Fmt.count(heatmapSessions)) sessions in local history")
                    .font(.muCaption)
                    .foregroundColor(MU.textTertiary)
                Spacer(minLength: 0)
            }
        }
    }

    private var heatmapSessions: Int {
        codexHeatmapDaily.reduce(0) { $0 + $1.sessionCount }
    }

    // MARK: Tone

    /// The one case that means something actually broke. Everything else is an
    /// ordinary fact about this machine.
    private static func isWarning(_ reason: SourceUnavailable) -> Bool {
        if case .failed = reason { return true }
        return false
    }

    /// One line of context, never a restatement of the message.
    private static func hint(for reason: SourceUnavailable, provider: Provider) -> String? {
        switch reason {
        case .cliNotFound:
            return "Install it to see live \(provider.displayName) limits here."
        case .notSignedIn:
            return provider == .openRouter
                ? "Set OPENROUTER_API_KEY or configure a local OpenRouter key."
                : "Sign in with the \(provider.displayName) CLI to read limits."
        case .offline:
            return "Live limits need a connection. Local activity still works."
        case .failed:
            return "Will retry on the next refresh."
        case .noData:
            return "Usage appears once you've made some requests."
        case .dataNotFound(let name):
            if name == "OpenRouter API key" {
                return "Set OPENROUTER_API_KEY or configure a local OpenRouter key."
            }
            return "\(name) will appear when its local companion is available."
        }
    }

    private func beginUseReset(creditID: String) {
        resetPrompt = nil
        guard let onUseReset else {
            resetPrompt = ResetPrompt(kind: .failure(
                title: "Reset unavailable",
                message: "Codex reset actions are not available in this session."
            ))
            return
        }

        consumingResetID = creditID
        Task { @MainActor in
            do {
                try await onUseReset(creditID)
                consumingResetID = nil
                resetPrompt = ResetPrompt(kind: .success)
            } catch {
                consumingResetID = nil
                resetPrompt = ResetPrompt(kind: .failure(
                    title: "Could not use reset",
                    message: "Refresh Codex limits and try again."
                ))
            }
        }
    }
}

private struct ResetPrompt: Identifiable {
    enum Kind {
        case confirmation(QuotaResetCredit)
        case success
        case failure(title: String, message: String)
    }

    let id = UUID()
    let kind: Kind
}

// MARK: - Rows

private struct WindowRow: View {
    let provider: Provider
    let window: QuotaWindow
    let now: Date

    private var tint: Color { headroomColor(usedPercent: window.usedPercent) }
    private var isCodex: Bool { provider == .codex }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(isCodex ? "\(window.label) usage limit" : window.label)
                    .font(.muBody)
                    .foregroundColor(MU.textSecondary)
                Spacer(minLength: 4)
                if isCodex {
                    Text(Fmt.remainingPercent(window.usedPercent))
                        .font(.muNumber)
                        .foregroundColor(tint)
                }
                // Countdown and wall-clock on one line rather than two. Two
                // lines per window cost four lines across the popover and
                // pushed the per-model breakdown below the fold — and the two
                // facts are one thought ("in 3h — that's 7:23 this morning"),
                // so splitting them was never worth the height.
                Text(resetLabel)
                    .font(.muCaption)
                    .foregroundColor(MU.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            MeterBar(fraction: isCodex ? 1 - window.fraction : window.fraction, tint: tint)
        }
        .help(helpLabel)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// "resets in 3h 14m · today 7:23 AM", or just the countdown when the
    /// wall-clock adds nothing.
    private var resetLabel: String {
        guard let absolute = absoluteLabel, !countdownLabel.isEmpty else {
            return countdownLabel
        }
        return "\(countdownLabel) · \(absolute)"
    }

    /// Relative, because "resets in 2h 14m" answers the question the user
    /// actually has: can I keep going? Silent when the provider omits the reset
    /// — a countdown is never estimated from anything else.
    private var countdownLabel: String {
        guard let resetsAt = window.resetsAt else { return "" }
        guard let remaining = Fmt.timeUntil(resetsAt, now: now) else { return "resetting" }
        return "resets in \(remaining)"
    }

    /// Wall-clock companion to the countdown, in local time.
    ///
    /// A countdown is right for "now"; it's useless for planning. "resets in
    /// 4d 17h" tells you nothing about whether that lands before Monday's work.
    /// Shown one step down the type hierarchy so it supports the countdown
    /// rather than competing with it.
    private var absoluteLabel: String? {
        guard let resetsAt = window.resetsAt, resetsAt > now else { return nil }
        return Fmt.absoluteMoment(resetsAt, now: now)
    }

    private var helpLabel: String {
        let label = isCodex ? "\(window.label) usage limit" : window.label
        guard let absolute = absoluteLabel else { return label }
        return "\(label) resets \(absolute)"
    }

    private var accessibilityLabel: String {
        let label = isCodex ? "\(window.label) usage limit" : window.label
        var parts = ["\(label): \(Fmt.percent(window.usedPercent)) used"]
        if isCodex { parts.append(Fmt.remainingPercent(window.usedPercent)) }
        if !countdownLabel.isEmpty { parts.append(countdownLabel) }
        if let absolute = absoluteLabel { parts.append("at \(absolute)") }
        return parts.joined(separator: ". ")
    }
}

private struct ResetCreditsSection: View {
    let count: Int
    let credits: [QuotaResetCredit]
    let now: Date
    let canUseReset: Bool
    let consumingResetID: String?
    let onRequestUse: (QuotaResetCredit) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Usage limit resets")
                .font(.muBody.weight(.semibold))
                .foregroundColor(MU.text)

            if credits.isEmpty {
                Text("\(count) available")
                    .font(.muBody)
                    .foregroundColor(MU.textSecondary)
            } else {
                ForEach(Array(credits.enumerated()), id: \.element.id) { index, credit in
                    if index > 0 {
                        Divider()
                            .overlay(MU.hairline)
                    }
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(credit.title)
                                .font(.muBody)
                                .foregroundColor(MU.textSecondary)
                            if let expiresAt = credit.expiresAt {
                                Text("Expires \(Fmt.expiryMoment(expiresAt))")
                                    .font(.muCaption)
                                    .foregroundColor(MU.textTertiary)
                            }
                        }
                        Spacer(minLength: 4)
                        if isAvailable(credit) {
                            Button {
                                onRequestUse(credit)
                            } label: {
                                if consumingResetID == credit.id {
                                    ProgressView()
                                        .controlSize(.small)
                                        .frame(width: 62)
                                } else {
                                    Text("Use reset")
                                }
                            }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                            .disabled(!canUseReset || consumingResetID != nil)
                        } else {
                            Text(statusLabel(for: credit))
                                .font(.muCaption)
                                .foregroundColor(statusColor(for: credit))
                        }
                    }
                }
                if credits.count < count {
                    Text("\(count - credits.count) more available")
                        .font(.muCaption)
                        .foregroundColor(MU.textTertiary)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Usage limit resets: \(count) available")
    }

    private func statusLabel(for credit: QuotaResetCredit) -> String {
        guard let status = credit.status, !status.isEmpty else { return "Available" }
        return status.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func statusColor(for credit: QuotaResetCredit) -> Color {
        credit.status?.lowercased() == "available" ? MU.calm : MU.textTertiary
    }

    private func isAvailable(_ credit: QuotaResetCredit) -> Bool {
        guard credit.status?.lowercased() == "available" else { return false }
        guard let expiresAt = credit.expiresAt else { return true }
        return expiresAt > now
    }
}

/// The usage-credits bucket, distinct from the 5h/7d plan-allowance windows
/// above it — this is where anything billed outside that allowance draws
/// from. Fable is NOT an example of this: it has its own weekly
/// plan-allowance window (see `OptionalQuotaFileSource`'s per-model
/// `weekly` handling), confirmed 2026-07-31 against the Claude app's own
/// usage screen. An earlier version of this comment claimed
/// Fable billed here instead — that was wrong, based on an absence-of-
/// evidence read of the CLI binary rather than the actual usage API.
///
/// Shows the remaining balance first. When a provider also reports spend and a
/// limit, those appear as a secondary detail and a meter so "how much is left"
/// never gets replaced by "how much was spent".
private struct CreditsRow: View {
    let provider: Provider
    let credits: CreditBalance

    private var balanceColor: Color {
        if let usedPercent {
            return headroomColor(usedPercent: usedPercent)
        }
        return providerColor(provider)
    }

    private var tint: Color {
        guard let usedPercent else { return MU.calm }
        return headroomColor(usedPercent: usedPercent)
    }

    private var usedPercent: Double? {
        guard credits.unit == .dollars else { return nil }
        guard let used = credits.usedDollars, let limit = credits.limitDollars, limit > 0 else { return nil }
        return (used / limit) * 100
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Credits")
                    .font(.muBody)
                    .foregroundColor(MU.textSecondary)
                Spacer(minLength: 4)
                Text(balanceLabel)
                    .font(.muNumber)
                    .foregroundColor(balanceColor)
                    .lineLimit(1)
            }
            if let spendDetail {
                HStack {
                    Spacer(minLength: 0)
                    Text(spendDetail)
                        .font(.muCaption)
                        .foregroundColor(MU.textTertiary)
                        .lineLimit(1)
                }
            }
            if let usedPercent {
                MeterBar(fraction: usedPercent / 100, tint: tint)
            }
        }
        .help(caption)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Credits: \(balanceLabel). \(spendDetail ?? "") \(caption)")
    }

    private var balanceLabel: String {
        if credits.unlimited { return "Unlimited" }
        if !credits.hasCredits { return "None" }
        switch credits.unit {
        case .credits:
            let raw = "\(Fmt.credits(credits.balance)) credits"
            if let dollars = credits.dollarBalance {
                return "\(raw) · ≈ \(Fmt.usd(dollars)) available"
            }
            return "\(raw) available"
        case .dollars:
            return "\(Fmt.usd(credits.balance)) available"
        }
    }

    private var spendDetail: String? {
        guard let used = credits.usedDollars else { return nil }
        return creditSpendLabel(used: used, limit: credits.limitDollars)
    }

    private func creditSpendLabel(used: Double, limit: Double?) -> String {
        if let limit, limit > 0 {
            return "Spent \(Fmt.usd(used)) of \(Fmt.usd(limit))"
        }
        return "Spent \(Fmt.usd(used))"
    }

    /// Factual and brief on purpose. Does not name Fable: Fable is not
    /// billed here — it has its own weekly plan-allowance window shown as
    /// an ordinary `WindowRow` above, not a credits draw (see the header
    /// comment on this file and on `OptionalQuotaFileSource`).
    private var caption: String {
        if credits.unit == .credits, credits.dollarBalance != nil {
            return "Codex display conversion: 2,500 credits equals $100."
        }
        return "Available balance is shown first; spend and a limit appear when the provider reports them."
    }
}
