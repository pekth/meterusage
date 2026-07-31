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

    var body: some View {
        Card {
            header
            content
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(provider.displayName)
                .font(.muTitle)
                .foregroundColor(MU.text)

            if let label = planLabel {
                PlanBadge(text: label)
            }

            Spacer(minLength: 0)

            if let quota = state.value, let peak = quota.windows.map(\.usedPercent).max() {
                Text(Fmt.percent(peak))
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
            if quota.windows.isEmpty && quota.credits == nil {
                InfoState(message: SourceUnavailable.noData.userFacingMessage,
                          hint: "Usage appears once you've made some requests.")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(quota.windows.enumerated()), id: \.offset) { _, window in
                        WindowRow(window: window, now: now)
                    }
                    if let credits = quota.credits {
                        CreditsRow(credits: credits)
                    }
                }
                .transition(.opacity)
            }
        }
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
            return "Sign in with the \(provider.displayName) CLI to read limits."
        case .offline:
            return "Live limits need a connection. Local activity still works."
        case .failed:
            return "Will retry on the next refresh."
        case .noData:
            return "Usage appears once you've made some requests."
        }
    }
}

// MARK: - Rows

private struct WindowRow: View {
    let window: QuotaWindow
    let now: Date

    private var tint: Color { headroomColor(usedPercent: window.usedPercent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(window.label)
                    .font(.muBody)
                    .foregroundColor(MU.textSecondary)
                Spacer(minLength: 4)
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
            MeterBar(fraction: window.fraction, tint: tint)
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
        guard let absolute = absoluteLabel else { return window.label }
        return "\(window.label) window resets \(absolute)"
    }

    private var accessibilityLabel: String {
        var parts = ["\(window.label): \(Fmt.percent(window.usedPercent)) used"]
        if !countdownLabel.isEmpty { parts.append(countdownLabel) }
        if let absolute = absoluteLabel { parts.append("at \(absolute)") }
        return parts.joined(separator: ". ")
    }
}

/// The usage-credits bucket, distinct from the 5h/7d plan-allowance windows
/// above it — this is where anything billed outside that allowance draws
/// from. Fable is NOT an example of this: it has its own weekly
/// plan-allowance window (see `OptionalQuotaFileSource`'s per-model
/// `weekly` handling), confirmed 2026-07-31 against the machine owner's own
/// Claude app usage screenshot. An earlier version of this comment claimed
/// Fable billed here instead — that was wrong, based on an absence-of-
/// evidence read of the CLI binary rather than the actual usage API.
///
/// Renders a used/limit meter, mirroring `WindowRow`, ONLY when both
/// `usedDollars` and `limitDollars` are known. When the source can only
/// report a remaining `balance` (or nothing at all), this falls back to the
/// older plain-text line rather than fabricating a meter it can't back up.
private struct CreditsRow: View {
    let credits: CreditBalance

    private var tint: Color {
        guard let usedPercent else { return MU.calm }
        return headroomColor(usedPercent: usedPercent)
    }

    private var usedPercent: Double? {
        guard let used = credits.usedDollars, let limit = credits.limitDollars, limit > 0 else { return nil }
        return (used / limit) * 100
    }

    var body: some View {
        if let used = credits.usedDollars, let limit = credits.limitDollars, limit > 0 {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Credits")
                        .font(.muBody)
                        .foregroundColor(MU.textSecondary)
                    Spacer(minLength: 4)
                    Text("\(Fmt.usd(used)) / \(Fmt.usd(limit))")
                        .font(.muNumber)
                        .foregroundColor(MU.text)
                        .lineLimit(1)
                }
                MeterBar(fraction: (usedPercent ?? 0) / 100, tint: tint)
            }
            .help(caption)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Credits: \(Fmt.usd(used)) of \(Fmt.usd(limit)) used. \(caption)")
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Credits")
                    .font(.muBody)
                    .foregroundColor(MU.textSecondary)
                Spacer(minLength: 4)
                Text(label)
                    .font(.muNumber)
                    .foregroundColor(MU.text)
            }
            .help(caption)
        }
    }

    private var label: String {
        if credits.unlimited { return "Unlimited" }
        if !credits.hasCredits { return "None" }
        return Fmt.usd(credits.balance)
    }

    /// Factual and brief on purpose. Does not name Fable: Fable is not
    /// billed here — it has its own weekly plan-allowance window shown as
    /// an ordinary `WindowRow` above, not a credits draw (see the header
    /// comment on this file and on `OptionalQuotaFileSource`).
    private var caption: String {
        "Usage credits cover models billed outside the plan allowance."
    }
}
