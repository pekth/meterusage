import SwiftUI

/// Locally-computed activity: token totals, an estimated cost, the heatmap, and
/// the most recent sessions.
///
/// PRIVACY: the only identifying-ish string rendered anywhere below is
/// `SessionSummary.projectName`, which the source has already reduced to a bare
/// directory name. No path, no session id, no host, no account.
///
/// HONESTY: cost is an *estimate* derived from public list prices and local token
/// counts. It is labelled as such at the point of display, not in a footnote —
/// people screenshot this, and an unqualified dollar figure next to a provider's
/// name reads as a bill.
struct ActivitySection: View {

    let activities: [Provider: Loaded<LocalActivity>]
    let providers: [Provider]
    let now: Date

    @AppStorage(PrefKey.showHeatmap) private var showHeatmap: Bool = true

    private var loaded: [LocalActivity] {
        providers.compactMap { activities[$0]?.value }
    }

    /// Every provider that reported nothing, with its reason — shown only when
    /// there is nothing at all to display, so a working provider isn't cluttered
    /// by a note about the other one.
    private var reasons: [ProviderNote] {
        providers.compactMap { provider in
            activities[provider]?.unavailable.map { ProviderNote(provider: provider, reason: $0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Local activity")
            Card {
                if loaded.isEmpty {
                    emptyState
                } else {
                    totals
                    // Immediately under the totals it decomposes, and above the
                    // heatmap: this answers "what am I spending it on?", which
                    // is the question the totals provoke. The heatmap answers
                    // "when?", which nobody asks first.
                    Divider().overlay(MU.hairline)
                    ModelBreakdown(models: byModel)
                    if hasUnpricedModels {
                        UnpricedNote()
                    }
                    if showHeatmap {
                        Divider().overlay(MU.hairline)
                        HeatmapView(daily: loaded.flatMap(\.daily), today: now)
                    }
                }
            }
            if !loaded.isEmpty {
                SessionsCard(sessions: recentSessions, now: now)
            }
        }
    }

    // MARK: Empty

    @ViewBuilder
    private var emptyState: some View {
        if reasons.isEmpty {
            InfoState(message: "Reading local activity…")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(reasons) { note in
                    InfoState(
                        message: "\(note.provider.displayName): \(note.reason.userFacingMessage)",
                        hint: nil,
                        isWarning: note.isWarning
                    )
                }
            }
        }
    }

    // MARK: Totals

    private var combinedTokens: TokenTotals {
        loaded.reduce(TokenTotals()) { $0 + $1.totalTokens }
    }

    private var combinedCost: Double {
        loaded.reduce(0) { $0 + $1.totalCostUSD }
    }

    /// Whether any session ran on a model we recognise but have no published
    /// per-token rate for (Fable, as of now).
    ///
    /// Such a session contributes real tokens and exactly `$0` of cost, so the
    /// total below is a floor, not a figure. That has to be visible: an
    /// unqualified dollar amount that quietly omits a heavily-used model is a
    /// more damaging lie than a missing number, because it looks complete.
    private var hasUnpricedModels: Bool {
        loaded.flatMap(\.sessions).contains {
            Pricing.availability(forModel: $0.model) == .knownUnpriced
        }
    }

    private var totals: some View {
        HStack(alignment: .top, spacing: 0) {
            Stat(
                title: "Tokens",
                value: Fmt.compactCount(combinedTokens.total),
                caption: "\(Fmt.compactCount(combinedTokens.input)) in · \(Fmt.compactCount(combinedTokens.output)) out"
            )
            Divider().frame(height: 34).overlay(MU.hairline)
            Stat(
                // The trailing "+" is the qualifier: this is at least this
                // much. It sits on the number itself rather than only in the
                // note below, because the number is what gets screenshotted.
                title: "Est. cost",
                value: hasUnpricedModels ? "\(Fmt.usd(combinedCost))+" : Fmt.usd(combinedCost),
                caption: hasUnpricedModels ? "at least — see note" : "estimate, not billing",
                tint: MU.text
            )
            Divider().frame(height: 34).overlay(MU.hairline)
            Stat(
                title: "Sessions",
                value: String(loaded.reduce(0) { $0 + $1.sessions.count }),
                caption: "in local history"
            )
        }
    }

    /// Per-model totals, heaviest first.
    ///
    /// Grouped on the raw model string, not on a normalised family. Two
    /// spellings the app can't prove are the same model stay separate rows: a
    /// wrong merge invents usage that never happened, and the display name is
    /// already the only thing shortened.
    private var byModel: [ModelUsage] {
        var order: [String] = []
        var buckets: [String: ModelUsage] = [:]

        for session in loaded.flatMap(\.sessions) {
            if var existing = buckets[session.model] {
                existing.tokens = existing.tokens + session.tokens
                existing.costUSD += session.estimatedCostUSD
                existing.sessionCount += 1
                buckets[session.model] = existing
            } else {
                order.append(session.model)
                buckets[session.model] = ModelUsage(
                    model: session.model,
                    tokens: session.tokens,
                    costUSD: session.estimatedCostUSD,
                    sessionCount: 1
                )
            }
        }

        return order
            .compactMap { buckets[$0] }
            // Tokens, not cost: cost is unavailable for some models, so sorting
            // by it would push exactly the models this section exists to
            // surface to the bottom of the list.
            .sorted { $0.tokens.total > $1.tokens.total }
    }

    /// Newest first, capped: the popover is a glance surface, not a log viewer.
    private var recentSessions: [SessionSummary] {
        loaded
            .flatMap(\.sessions)
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(6)
            .map { $0 }
    }
}

/// One model's share of local activity.
struct ModelUsage: Identifiable {
    let model: String
    var tokens: TokenTotals
    var costUSD: Double
    var sessionCount: Int

    /// The raw model string is the identity; the shortened name is only ever a
    /// label, so two models that shorten alike still can't collide here.
    var id: String { model }
    var displayName: String { Fmt.shortModel(model) }
}

/// Per-model breakdown of local activity.
///
/// WHY THIS EXISTS: before it, a model's name appeared only in the recent-session
/// rows, which sit below the fold in a 340×600 popover. A heavily-used model with
/// no published rate was therefore counted correctly and displayed nowhere — the
/// user could see a "some models have no rate" footnote without ever learning
/// which models, or how much of their work ran on one. Counting something and
/// never naming it is indistinguishable from not tracking it.
private struct ModelBreakdown: View {
    let models: [ModelUsage]

    /// Five rows covers the realistic case (most people run two or three models
    /// and a stray) while keeping this section shorter than the totals above it.
    private static let collapsedLimit = 5

    @State private var expanded = false

    private var visible: [ModelUsage] {
        expanded ? models : Array(models.prefix(Self.collapsedLimit))
    }

    private var hiddenCount: Int {
        max(models.count - Self.collapsedLimit, 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            columnHeader
            ForEach(visible) { model in
                ModelRow(usage: model)
            }
            if hiddenCount > 0 {
                disclosure
            }
        }
    }

    /// Named columns, because two right-aligned numeric columns are otherwise
    /// ambiguous — a bare "1.2M / ~$4.10" pair doesn't say which is which.
    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text("MODEL")
            Spacer(minLength: 4)
            Text("TOKENS").frame(width: MU.tokenColumn, alignment: .trailing)
            Text("COST").frame(width: MU.costColumn, alignment: .trailing)
        }
        .font(.muSectionTitle)
        .tracking(0.6)
        .foregroundColor(MU.textTertiary)
    }

    private var disclosure: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() }
        } label: {
            Text(expanded ? "Show fewer" : "+\(hiddenCount) more")
                .font(.muCaption)
                .foregroundColor(MU.accent)
        }
        .buttonStyle(.plain)
        .padding(.top, 1)
    }
}

private struct ModelRow: View {
    let usage: ModelUsage

    var body: some View {
        HStack(spacing: 8) {
            Text(usage.displayName)
                .font(.muBody)
                .foregroundColor(MU.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(Fmt.compactCount(usage.tokens.total))
                .font(.muNumber)
                .foregroundColor(MU.textSecondary)
                .frame(width: MU.tokenColumn, alignment: .trailing)
            Text(CostDisplay.label(model: usage.model, costUSD: usage.costUSD))
                .font(.muNumber)
                .foregroundColor(MU.textSecondary)
                .frame(width: MU.costColumn, alignment: .trailing)
        }
        .help(CostDisplay.help(model: usage.model))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let cost = CostDisplay.isUnpriced(usage.model)
            ? "cost unavailable, no published rate"
            : "about \(Fmt.usd(usage.costUSD))"
        let sessions = "\(usage.sessionCount) session\(usage.sessionCount == 1 ? "" : "s")"
        return "\(usage.displayName): \(Fmt.compactCount(usage.tokens.total)) tokens, \(cost), \(sessions)"
    }
}

/// One provider's "nothing to show" note, wrapped so `ForEach` has a stable id.
private struct ProviderNote: Identifiable {
    let provider: Provider
    let reason: SourceUnavailable
    var id: String { provider.rawValue }
    /// Only a genuine failure earns a warning tone.
    var isWarning: Bool {
        if case .failed = reason { return true }
        return false
    }
}

// MARK: - Pieces

/// The single place a model's cost becomes text.
///
/// Two surfaces render a per-model cost — the breakdown and the session list —
/// and they must never disagree about what an unpriced model looks like. One
/// showing "—" while the other showed "$0.00" would make the em-dash read as a
/// glitch rather than as a statement.
enum CostDisplay {

    static func isUnpriced(_ model: String) -> Bool {
        Pricing.availability(forModel: model) == .knownUnpriced
    }

    /// An em-dash, never "$0.00".
    ///
    /// The token count beside it is real and measured; the cost simply is not
    /// something we can state. A zero would claim the work was free.
    static func label(model: String, costUSD: Double) -> String {
        isUnpriced(model) ? "\u{2014}" : "~\(Fmt.usd(costUSD))"
    }

    static func help(model: String) -> String {
        isUnpriced(model)
            ? "No public per-token rate is published for this model, so no cost is estimated. The token count is exact."
            : "Estimated from public list prices — not a bill."
    }
}

/// Explains both the "+" on the total and the em-dash in the session list.
///
/// Some models are recognised but have no public per-token rate. The honest
/// rendering is to count their tokens (which are measured, and exact) and to
/// decline to price them (which would be invented). "$0.00" is the one thing
/// this must never show: a zero reads as a verified fact, and it would drag the
/// visible total down towards a number the user has no reason to doubt.
struct UnpricedNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            Text("\u{2014}")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundColor(MU.textTertiary)
            Text("Some models have no published per-token rate. Their tokens are counted; their cost isn't, so the total above understates real spend.")
                .font(.system(size: 9.5))
                .foregroundColor(MU.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct Stat: View {
    let title: String
    let value: String
    let caption: String
    var tint: Color = MU.text

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.muSectionTitle)
                .tracking(0.6)
                .foregroundColor(MU.textTertiary)
            Text(value)
                .font(.muBigNumber)
                .foregroundColor(tint)
            Text(caption)
                .font(.system(size: 9.5))
                .foregroundColor(MU.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
    }
}

private struct SessionsCard: View {
    let sessions: [SessionSummary]
    let now: Date

    var body: some View {
        Card {
            SectionHeader("Recent sessions")
            if sessions.isEmpty {
                InfoState(message: SourceUnavailable.noData.userFacingMessage)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        if index > 0 {
                            Divider().overlay(MU.hairline).padding(.vertical, 6)
                        }
                        SessionRow(session: session, now: now)
                    }
                }
            }
        }
    }
}

private struct SessionRow: View {
    let session: SessionSummary
    let now: Date

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                // `projectName` is already a bare directory name (see Privacy).
                Text(session.projectName)
                    .font(.muBody)
                    .foregroundColor(MU.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    Text(Fmt.timeSince(session.startedAt, now: now))
                    Text("·")
                    Text("\(session.messageCount) msg")
                    Text("·")
                    // Shown verbatim apart from the vendor prefix, so an
                    // unfamiliar model reads as itself rather than as a guess.
                    Text(Fmt.shortModel(session.model))
                }
                .font(.muCaption)
                .foregroundColor(MU.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.compactCount(session.tokens.total))
                    .font(.muNumber)
                    .foregroundColor(MU.textSecondary)
                Text(costLabel)
                    .font(.muCaption)
                    .foregroundColor(MU.textTertiary)
            }
            .help(costHelp)
        }
    }

    private var costLabel: String {
        CostDisplay.label(model: session.model, costUSD: session.estimatedCostUSD)
    }

    private var costHelp: String {
        CostDisplay.help(model: session.model)
    }
}
