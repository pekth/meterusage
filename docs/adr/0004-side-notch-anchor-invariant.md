# ADR 0004: Side notch keeps its anchor and whole-point frames

- Status: Accepted
- Date: 2026-09-17

## Decision

The side notch panel keeps a fixed anchor. Folding, unfolding, or switching the
detail card changes only the edge away from the anchor. The anchored edge and
the strip never move, so the panel stays exactly where the user parked it.

## Rules

- The anchor is the strip's top-right corner, persisted across launches.
  `SideNotchPanelLayout.notchFrame` grows the window away from that corner, so
  the top edge (`maxY`) and the strip's right edge (`maxX`) are invariant for
  every card height. `SideNotchPanelTests` asserts this across a range of
  heights.
- Frames use whole-point sizes. The strip has a fixed whole-point width, and
  strip and card heights are rounded up before placement. AppKit rounds a
  fractional window frame up, so a fractional size leaves the window taller
  than its content.
- The content anchors to the top of the window. Any residual height difference
  then falls below the card instead of shifting the visible edge.
- Clamping is the one exception: a panel that would leave the screen moves to
  stay visible.
- Panel sizing is not animated. The 0.2.26 AppKit frame glide stuttered on
  rapid hover, and the 0.2.27 SwiftUI glide fed animated intermediate sizes back
  into placement and never settled. Both were reverted.

## Evidence required

A change that touches side notch layout or motion needs captured frames before
release: capture the panel for at least two providers whose cards differ in
height, and confirm the top edge renders on the same row and the strip does not
move. The unit tests cover the geometry only and cannot see the rendered result.

The 0.2.26 to 0.2.31 series shipped six attempts at this bug without that
evidence. The cause was found by logging requested and applied frames on the
reporter's machine. Prefer a measured frame over a plausible cause.

## Consequences

- The strip stays where the user parked it while cards change.
- A card whose height is fractional cannot appear to move the panel, because the
  window and the content agree on whole points and the content is top-anchored.

## References

- [`docs/SIDE-NOTCH.md`](../SIDE-NOTCH.md): panel states, interaction, and verification steps.
- `Sources/MeterUsage/App/SideNotchPanelController.swift` (`place`, `SideNotchPanelLayout.notchFrame`)
- `Sources/MeterUsage/Views/SideNotchPanelView.swift` (top-anchored body, strip frame)
- `Tests/MeterUsageTests/SideNotchPanelTests.swift`
