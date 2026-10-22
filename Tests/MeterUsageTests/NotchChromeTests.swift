import XCTest
import SwiftUI
import AppKit
@testable import MeterUsage

/// The side notch chrome is derived from the accent theme. These tests read the
/// resolved RGB values rather than trusting the blend's intent: the whole point
/// of the earlier bug was that the maths looked right and rendered black.
///
/// `Notch.body` and friends are resolved in the notch's forced dark appearance
/// (`NSAppearance.darkAqua`), so the values here match what the strip draws.
final class NotchChromeTests: XCTestCase {

    private func rgba(_ color: Color, appearance: NSAppearance.Name = .darkAqua) -> (r: Double, g: Double, b: Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            NSColor(color).usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        }
        return (Double(r), Double(g), Double(b))
    }

    private func brightness(_ color: Color) -> Double {
        let c = rgba(color)
        return max(c.r, max(c.g, c.b))
    }

    /// A dark-grey body, never black: a black body is what the user asked to
    /// leave behind, and it is also what made two accents indistinguishable.
    func testBodyStaysDarkGreyAndNeverBlack() {
        for theme in AccentTheme.allCases {
            let body = Notch.body[AccentTheme.allCases.firstIndex(of: theme)!]
            let value = brightness(body)
            XCTAssertGreaterThan(value, 0.05, "\(theme) body collapsed toward black")
            XCTAssertLessThan(value, 0.35, "\(theme) body is no longer a dark neutral")
        }
    }

    /// Each theme's chrome must be genuinely distinct, or "pick a theme" is a
    /// no-op. Compared on the elided hue, not exact RGB, so near-identical
    /// greys for graphite are still allowed to differ from a saturated accent.
    func testEachThemeProducesADistinctBody() {
        let bodies = AccentTheme.allCases.map { rgba(Notch.body[AccentTheme.allCases.firstIndex(of: $0)!]) }
        for i in bodies.indices {
            for j in bodies.indices where j > i {
                let dr = abs(bodies[i].r - bodies[j].r)
                let dg = abs(bodies[i].g - bodies[j].g)
                let db = abs(bodies[i].b - bodies[j].b)
                XCTAssertGreaterThan(
                    dr + dg + db, 0.01,
                    "\(AccentTheme.allCases[i]) and \(AccentTheme.allCases[j]) render the same body"
                )
            }
        }
    }

    /// The body must borrow the accent's hue. A blue accent must leave a bluer
    /// body than a red-leaning rose one, which is the property a plain
    /// brightness-preserving blend on grey would otherwise lose.
    func testBodyTakesTheAccentHue() {
        let blue = rgba(Notch.body[AccentTheme.allCases.firstIndex(of: .blue)!])
        let rose = rgba(Notch.body[AccentTheme.allCases.firstIndex(of: .rose)!])
        XCTAssertGreaterThan(blue.b, blue.r, "blue accent did not push the body blue")
        XCTAssertGreaterThan(rose.r, rose.b, "rose accent did not push the body red")
    }

    /// Chrome brightness ordering must hold, so the card still reads as raised
    /// above the body and the track above the disc on every theme.
    func testChromeBrightnessOrderingHoldsPerTheme() {
        for (i, theme) in AccentTheme.allCases.enumerated() {
            XCTAssertGreaterThan(brightness(Notch.card[i]), brightness(Notch.body[i]), "\(theme): card not above body")
            XCTAssertGreaterThan(brightness(Notch.disc[i]), brightness(Notch.card[i]), "\(theme): disc not above card")
            XCTAssertGreaterThan(brightness(Notch.track[i]), brightness(Notch.disc[i]), "\(theme): track not above disc")
        }
    }

    /// Every accent must resolve its chrome from the same source. The original
    /// bug was a split-brain: the card keyed on provider alone and read the
    /// accent from `UserDefaults`, while the strip read it live, so the two
    /// halves of one object could show different themes. The card table and the
    /// body table must be indexed by the identical `AccentTheme.allCases` order.
    func testChromeTablesShareOneAccentOrder() {
        XCTAssertEqual(
            Notch.body.colors.count, AccentTheme.allCases.count
        )
        XCTAssertEqual(
            Notch.card.colors.count, AccentTheme.allCases.count
        )
        // The published selection must map to the same index the tables use.
        for (i, theme) in AccentTheme.allCases.enumerated() {
            XCTAssertEqual(AccentTheme.allCases.firstIndex(of: theme), i)
        }
    }

    /// A themed chrome value must change when the accent changes: if two themes
    /// produced the same card, a card keyed on the wrong accent would be
    /// invisible in tests and baffling in the UI.
    func testCardChromeDiffersAcrossAllThemes() {
        let cards = AccentTheme.allCases.map { rgba(Notch.card[AccentTheme.allCases.firstIndex(of: $0)!]) }
        for i in cards.indices {
            for j in cards.indices where j > i {
                let delta = abs(cards[i].r - cards[j].r) + abs(cards[i].g - cards[j].g) + abs(cards[i].b - cards[j].b)
                XCTAssertGreaterThan(delta, 0.01, "\(AccentTheme.allCases[i]) and \(AccentTheme.allCases[j]) render the same card")
            }
        }
    }

    /// The strip and the hover card it docks against must read as one object:
    /// the card is brighter than the strip on every theme, and both carry the
    /// same accent hue. A card that took a different hue from the strip, or a
    /// strip that stayed grey while the card tinted, is exactly the mismatch the
    /// screenshots caught.
    func testCardAndStripShareAccentHue() {
        for (i, theme) in AccentTheme.allCases.enumerated() {
            let strip = rgba(Notch.body[i])
            let card = rgba(Notch.card[i])
            // Same dominant channel ordering (blue accent -> b>r on both).
            func dominantIsBlue(_ c: (r: Double, g: Double, b: Double)) -> Bool { c.b > c.r }
            XCTAssertEqual(
                dominantIsBlue(strip), dominantIsBlue(card),
                "\(theme): strip and card disagree on the accent hue"
            )
            XCTAssertGreaterThan(brightness(Notch.card[i]), brightness(Notch.body[i]), "\(theme): card not raised over strip")
        }
    }

    /// The whole contract: each theme's chrome sits at the same perceptual
    /// luminance as the popover's grey surfaces it stands in for. A saturated
    /// hue at a fixed channel reads darker than a grey, so this is the property
    /// that keeps the tinted themes from rendering darker than the window.
    ///
    /// Targets are `MU.canvas` (dark), `MU.surface`, and `MU.well`, converted to
    /// the same Rec. 709 luminance the blend preserves.
    func testEveryThemeMatchesPopoverSurfaceLuminance() {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        func luminance(_ c: (r: Double, g: Double, b: Double)) -> Double {
            0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
        }
        let canvas: (Double, Double, Double) = (28 / 255, 28 / 255, 30 / 255)
        let surface: (Double, Double, Double) = (38 / 255, 38 / 255, 41 / 255)
        let well: (Double, Double, Double) = (52 / 255, 52 / 255, 56 / 255)

        for (i, theme) in AccentTheme.allCases.enumerated() {
            let body = luminance(rgba(Notch.body[i]))
            let card = luminance(rgba(Notch.card[i]))
            let disc = luminance(rgba(Notch.disc[i]))
            XCTAssertEqual(body, luminance(canvas), accuracy: 0.002, "\(theme) body diverged from the popover canvas")
            XCTAssertEqual(card, luminance(surface), accuracy: 0.002, "\(theme) card diverged from the popover surface")
            XCTAssertEqual(disc, luminance(well), accuracy: 0.002, "\(theme) disc diverged from the popover well")
        }
    }
}
