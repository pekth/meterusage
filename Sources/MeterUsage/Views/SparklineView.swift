import SwiftUI

/// Compact 7-day usage sparkline for a provider's quota card.
///
/// Answers "am I burning faster than usual?" at a glance — a question the
/// 26-week heatmap is too wide to answer. Bars are scaled against the window's
/// own peak (never an absolute token count), so the shape reads correctly for
/// both heavy and light users.
///
/// The bucketing lives in `Model`, a testable value type; the view body does
/// no calendar work.
struct SparklineView: View {

    /// What a bar measures, matching `HeatmapView.Intensity` semantics:
    /// token-less providers (Codex) plot sessions.
    enum Intensity {
        case tokens
        case sessions
    }

    let daily: [DailyActivity]
    /// Anchors "today" so the window doesn't drift mid-session.
    let today: Date
    var intensity: Intensity = .tokens

    var body: some View {
        let model = Model(daily: daily, today: today, intensity: intensity)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(model.bars.indices, id: \.self) { index in
                    let bar = model.bars[index]
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(bar.value > 0 ? MU.accent.opacity(0.55) : MU.well)
                        .frame(height: Self.barHeight(for: bar.value, peak: model.peak))
                        .frame(maxWidth: .infinity)
                        .help(Self.readout(bar))
                }
            }
            .frame(height: 22, alignment: .bottom)
            Text(caption(model))
                .font(.muCaption)
                .foregroundColor(MU.textTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(model))
    }

    private static func barHeight(for value: Int, peak: Int) -> CGFloat {
        guard peak > 0, value > 0 else { return 2 }
        // A floor keeps a quiet-but-present day visible instead of vanishing.
        return max(3, CGFloat(value) / CGFloat(peak) * 20)
    }

    private static func readout(_ bar: Model.Bar) -> String {
        let date = Fmt.dayLabel.string(from: bar.day)
        if bar.tokens == 0 && bar.sessions == 0 { return "\(date) · no activity" }
        var parts: [String] = []
        if bar.tokens > 0 { parts.append("\(Fmt.compactCount(bar.tokens)) tokens") }
        if bar.sessions > 0 { parts.append("\(bar.sessions) session\(bar.sessions == 1 ? "" : "s")") }
        return "\(date) · \(parts.joined(separator: " · "))"
    }

    private func caption(_ model: Model) -> String {
        var parts = ["Last 7 days"]
        switch intensity {
        case .tokens:
            if model.windowTokens > 0 { parts.append("\(Fmt.compactCount(model.windowTokens)) tokens") }
        case .sessions:
            if model.windowSessions > 0 { parts.append("\(Fmt.count(model.windowSessions)) sessions") }
        }
        return parts.joined(separator: " · ")
    }

    private func accessibilityLabel(_ model: Model) -> String {
        "\(caption(model)). Peak day \(Fmt.compactCount(intensity == .tokens ? model.peak : model.windowSessions)) units."
    }

    // MARK: Layout model

    /// Buckets daily activity into the last seven calendar days ending today,
    /// including empty days so gaps stay visible as flat bars.
    struct Model {
        struct Bar {
            let day: Date
            let tokens: Int
            let sessions: Int
            /// The plotted metric (tokens or sessions per `intensity`).
            let value: Int
        }

        let bars: [Bar]
        let peak: Int
        let windowTokens: Int
        let windowSessions: Int

        init(daily: [DailyActivity], today: Date, intensity: SparklineView.Intensity) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current

            var totals: [Date: (tokens: Int, sessions: Int)] = [:]
            for entry in daily {
                let key = calendar.startOfDay(for: entry.day)
                let existing = totals[key] ?? (0, 0)
                totals[key] = (existing.tokens + entry.tokens.total,
                               existing.sessions + entry.sessionCount)
            }

            var built: [Bar] = []
            var peakValue = 0
            var totalTokens = 0
            var totalSessions = 0
            for offset in -6...0 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: today)) else { continue }
                let entry = totals[day] ?? (0, 0)
                totalTokens += entry.tokens
                totalSessions += entry.sessions
                let value = intensity == .tokens ? entry.tokens : entry.sessions
                peakValue = max(peakValue, value)
                built.append(Bar(day: day, tokens: entry.tokens, sessions: entry.sessions, value: value))
            }
            bars = built
            peak = peakValue
            windowTokens = totalTokens
            windowSessions = totalSessions
        }
    }
}
