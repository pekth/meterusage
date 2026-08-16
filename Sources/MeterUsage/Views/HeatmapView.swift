import SwiftUI

/// GitHub-style contribution grid over the last 26 weeks.
///
/// Columns are weeks (oldest left), rows are weekdays. 26 weeks × ~11pt cells is
/// the widest grid that fits the popover without horizontal scrolling, and half a
/// year is long enough to show a rhythm without turning the cells into dust.
///
/// Intensity is bucketed against the period's own maximum rather than an absolute
/// token count: usage varies by orders of magnitude between users, and a fixed
/// scale would render most people's history as a uniform block.
struct HeatmapView: View {

    /// What a cell's shade measures. Providers with no token accounting (Codex)
    /// shade by session count; token-bearing sources (Claude) shade by tokens.
    enum Intensity {
        case tokens
        case sessions
    }

    let daily: [DailyActivity]
    /// Anchors "today" so the grid doesn't drift mid-session.
    let today: Date
    /// Defaults to tokens so existing callers are unchanged.
    var intensity: Intensity = .tokens

    private let weeks = 26
    // 26 × (8 + 2.2) ≈ 263pt, which clears the card's ~288pt content width.
    private let cell: CGFloat = 8
    private let spacing: CGFloat = 2.2

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            grid
            legend
        }
    }

    // MARK: Grid

    private var grid: some View {
        let model = Model(daily: daily, today: today, weeks: weeks, intensity: intensity)
        return HStack(alignment: .top, spacing: spacing) {
            ForEach(0..<model.columns.count, id: \.self) { column in
                VStack(spacing: spacing) {
                    ForEach(0..<7, id: \.self) { row in
                        cellView(model.columns[column][row])
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func cellView(_ day: Model.Cell?) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(fill(for: day))
            .frame(width: cell, height: cell)
            .help(day.map(Self.tooltip) ?? "")
    }

    private func fill(for day: Model.Cell?) -> Color {
        guard let day, day.intensity > 0 else { return MU.well }
        // Four steps, not a continuous ramp: discrete buckets are far easier to
        // compare at 10pt than subtly different alphas.
        let step = min(4, max(1, Int(ceil(day.intensity * 4))))
        return MU.accent.opacity([0.28, 0.48, 0.72, 1.0][step - 1])
    }

    /// Tooltips never carry a project name or path — only a date and totals.
    private static func tooltip(_ day: Model.Cell) -> String {
        let date = Fmt.dayLabel.string(from: day.date)
        if day.tokens == 0 && day.sessions == 0 { return "\(date): no activity" }
        var parts: [String] = []
        if day.tokens > 0 { parts.append("\(Fmt.compactCount(day.tokens)) tokens") }
        if day.sessions > 0 { parts.append("\(day.sessions) session\(day.sessions == 1 ? "" : "s")") }
        return "\(date): \(parts.joined(separator: ", "))"
    }

    // MARK: Legend

    private var legend: some View {
        HStack(spacing: 5) {
            Text("26 weeks")
                .font(.muCaption)
                .foregroundColor(MU.textTertiary)
            Spacer(minLength: 0)
            Text("Less")
                .font(.muCaption)
                .foregroundColor(MU.textTertiary)
            ForEach(0..<5, id: \.self) { step in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(step == 0 ? MU.well : MU.accent.opacity([0.28, 0.48, 0.72, 1.0][step - 1]))
                    .frame(width: 8, height: 8)
            }
            Text("More")
                .font(.muCaption)
                .foregroundColor(MU.textTertiary)
        }
    }

    // MARK: Layout model

    /// Buckets daily activity into week columns.
    ///
    /// Built as a value type so the arithmetic is testable and so the view body
    /// stays free of calendar work.
    struct Model {
        struct Cell {
            let date: Date
            let tokens: Int
            let sessions: Int
            /// 0...1 relative to the busiest day in the window.
            let intensity: Double
        }

        /// `columns[week][weekday]`, oldest week first. `nil` means the slot is
        /// outside the window (before the start, or after today).
        let columns: [[Cell?]]

        init(daily: [DailyActivity], today: Date, weeks: Int, intensity: HeatmapView.Intensity = .tokens) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current

            let endOfToday = calendar.startOfDay(for: today)
            // Align the last column so today lands on its own weekday row.
            let weekdayIndex = calendar.component(.weekday, from: endOfToday) - 1
            let daysBack = (weeks - 1) * 7 + weekdayIndex
            guard let start = calendar.date(byAdding: .day, value: -daysBack, to: endOfToday) else {
                columns = []
                return
            }

            var totals: [Date: (tokens: Int, sessions: Int)] = [:]
            for entry in daily {
                let key = calendar.startOfDay(for: entry.day)
                let existing = totals[key] ?? (0, 0)
                totals[key] = (existing.tokens + entry.tokens.total,
                               existing.sessions + entry.sessionCount)
            }
            // Bucket against the metric that actually varies: a token-less
            // source (Codex) has zero tokens everywhere, so its peak would
            // otherwise flatten every cell to empty.
            let valueFor: (Int, Int) -> Int
            switch intensity {
            case .tokens:   valueFor = { tokens, _ in tokens }
            case .sessions: valueFor = { _, sessions in sessions }
            }
            let peak = max(totals.values.map { valueFor($0.tokens, $0.sessions) }.max() ?? 0, 1)

            var built: [[Cell?]] = []
            for week in 0..<weeks {
                var column: [Cell?] = []
                for weekday in 0..<7 {
                    guard let date = calendar.date(byAdding: .day, value: week * 7 + weekday, to: start),
                          date <= endOfToday else {
                        column.append(nil)
                        continue
                    }
                    let entry = totals[date] ?? (0, 0)
                    let value = valueFor(entry.tokens, entry.sessions)
                    column.append(Cell(
                        date: date,
                        tokens: entry.tokens,
                        sessions: entry.sessions,
                        intensity: Double(value) / Double(peak)
                    ))
                }
                built.append(column)
            }
            columns = built
        }
    }
}
