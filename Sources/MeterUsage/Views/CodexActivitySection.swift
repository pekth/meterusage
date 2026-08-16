import SwiftUI

/// Dedicated Codex activity card: a session-count weekly heatmap.
///
/// Codex gets its own card rather than sharing the Local activity card because
/// it carries no token ledger — its heatmap shades by sessions, which would
/// mislead beside Claude's token-scaled figures in the same grid. The whole
/// card is governed by the shared "Show heatmap" preference.
struct CodexActivitySection: View {

    let state: Loaded<LocalActivity>
    let now: Date

    @AppStorage(PrefKey.showHeatmap) private var showHeatmap: Bool = true

    private var activity: LocalActivity? {
        guard case .value(let activity) = state, !activity.daily.isEmpty else { return nil }
        return activity
    }

    @ViewBuilder
    var body: some View {
        if showHeatmap, let activity {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("Codex activity")
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        HeatmapView(daily: activity.daily, today: now, intensity: .sessions)
                        caption(for: activity)
                    }
                }
            }
        }
    }

    private func caption(for activity: LocalActivity) -> some View {
        let sessions = activity.daily.reduce(0) { $0 + $1.sessionCount }
        return HStack(spacing: 5) {
            Text("\(Fmt.count(sessions)) sessions in local history")
                .font(.muCaption)
                .foregroundColor(MU.textTertiary)
            Spacer(minLength: 0)
        }
    }
}
