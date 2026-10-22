import XCTest
@testable import MeterUsage

/// The accent palette table. Persistence of the choice is covered by
/// `SupplementalUsageSourceTests`; here we prove the table itself is sane, so a
/// copy-pasted colour or a renamed case fails a test instead of shipping.
final class AccentThemeTests: XCTestCase {

    func testBlueIsTheDefaultAccent() {
        XCTAssertEqual(AccentTheme.allCases.first, .blue)
    }

    func testRawValuesAreUniqueAndRoundTrip() {
        let rawValues = AccentTheme.allCases.map(\.rawValue)
        XCTAssertEqual(Set(rawValues).count, rawValues.count)
        for theme in AccentTheme.allCases {
            XCTAssertEqual(AccentTheme(rawValue: theme.rawValue), theme)
        }
    }

    func testEveryThemeHasADistinctAccentColour() {
        let colors = AccentTheme.allCases.map(\.color)
        for i in colors.indices {
            for j in colors.indices where j > i {
                XCTAssertNotEqual(
                    colors[i],
                    colors[j],
                    "\(AccentTheme.allCases[i].displayName) and \(AccentTheme.allCases[j].displayName) share an accent colour"
                )
            }
        }
    }
}
