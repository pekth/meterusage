import SwiftUI

/// The status-item content: a small meter glyph plus the tightest quota figure.
///
/// Constraints that shaped this:
///
/// * It is hosted inside the menu bar, whose appearance is independent of the
///   app's. Every colour is a dynamic token (see `SharedComponents`), so the
///   glyph stays legible on both a light and a dark bar without any observation.
/// * The status item's width is recomputed whenever the view resizes. Numbers
///   change every refresh, so the label is monospaced-digit *and* the numeric
///   slot has a fixed width — otherwise the whole right side of the user's menu
///   bar would shuffle sideways once a minute.
struct MenuBarLabel: View {

    @ObservedObject var coordinator: AppCoordinator
    /// The host reports the label's natural width so the `NSStatusItem` can
    /// match it: too narrow a slot clips "100%" to "10", and a wider fixed
    /// slot pads short figures like "9%" away from the gauge.
    var onWidthChange: (CGFloat) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 4) {
            MeterGlyph(fraction: fraction, tint: tint)
            Text(display)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundColor(hasReading ? tint : MU.neutral)
        }
        .padding(.horizontal, 5)
        .frame(height: 22)
        // Natural width regardless of the hosting slot, so the measurement
        // below reports what the label really needs instead of a clipped size.
        .fixedSize(horizontal: true, vertical: false)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { onWidthChange(proxy.size.width) }
                    .onChange(of: proxy.size.width) { newWidth in
                        onWidthChange(newWidth)
                    }
            }
        )
        .animation(.easeOut(duration: 0.3), value: fraction)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: Derived

    private var reading: (provider: Provider, window: QuotaWindow)? {
        coordinator.mostConstrained
    }

    private var hasReading: Bool { reading != nil }

    private var fraction: Double { reading?.window.fraction ?? 0 }

    private var tint: Color {
        guard let reading else { return MU.neutral }
        // A degraded service is worth flagging even when quota is healthy, but
        // it must not masquerade as a quota warning — hence tint only escalates,
        // never de-escalates, the headroom colour.
        let quotaTint = headroomColor(usedPercent: reading.window.usedPercent)
        if let status = coordinator.worstStatus, status.severity >= .partialOutage {
            return MU.alert
        }
        return quotaTint
    }

    /// An em dash, not "0%", when nothing has been read: zero is a claim.
    private var display: String {
        guard let reading else { return "—" }
        return Fmt.percent(reading.window.usedPercent)
    }

    private var accessibilityText: String {
        guard let reading else { return "Usage unavailable" }
        return "\(reading.provider.displayName) \(reading.window.label) window, \(Fmt.percent(reading.window.usedPercent)) used"
    }
}

/// Vertical fill gauge, drawn rather than composed from SF Symbols so the fill
/// level is continuous instead of snapping between symbol variants.
private struct MeterGlyph: View {
    let fraction: Double
    let tint: Color

    private let size = CGSize(width: 9, height: 13)

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .strokeBorder(tint.opacity(0.45), lineWidth: 1)
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(tint)
                .frame(height: max(1.5, (size.height - 4) * fraction.clamped(to: 0...1)))
                .padding(2)
        }
        .frame(width: size.width, height: size.height)
    }
}
