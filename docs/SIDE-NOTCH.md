# Side notch panel

The side notch is the floating strip of provider rings on the screen edge. This
document describes what it does and the geometry it must hold. The decision
record is [`docs/adr/0004`](adr/0004-side-notch-anchor-invariant.md).

## States

| State | Trigger | What shows |
| --- | --- | --- |
| Folded pill | Resting, no pointer | A capsule of up to five tinted dots, one per provider ring. |
| Strip | Unfolded | One ring per menu-bar provider, with the used percent and, when the reading warrants it, an ETA chip. |
| Detail card | Pointer on a ring, or the accessibility "Show details" action | The provider's rate-limit windows, reset times, pacing, telemetry, and reset credits. |

The panel unfolds while pinned, while the pointer is on it, or while a reset
action is active. A pointer exit schedules a fold after 450ms so a brief exit
does not collapse the card.

## Anchor and geometry

The panel is anchored by the strip's top-right corner. A drag records that
corner, and it persists across launches. Expanding the card grows the window
away from the corner, so the strip stays where the user parked it.

Invariants, asserted in `Tests/MeterUsageTests/SideNotchPanelTests.swift`:

- The top edge (`maxY`) is identical for every card height, on both card sides.
- The strip's outer edge is identical for every card height.
- Frames use whole-point sizes. The strip width is a fixed constant, and strip
  and card heights are rounded up before placement. AppKit rounds a fractional
  window frame up, which would leave the window taller than its content.
- The panel content anchors to the top of the window. A residual height
  difference then falls below the card instead of moving the visible edge.
- Clamping is the one exception: a panel with no room on the card side shifts
  inward so it stays on screen.

The card docks on the side with room. It flips when the strip crosses far
enough left that the card would leave the screen.

## Motion

Panel sizing is not animated. The rings use springs, and the pointer beak
follows the hovered ring with the ring's own animation. The 0.2.26 AppKit frame
glide stuttered on rapid hover, and the 0.2.27 SwiftUI glide fed animated
intermediate sizes back into placement and never settled. Both were reverted in
0.2.28, and the real cause was fixed in 0.2.32.

## Interaction

- Hover a ring to open its card. Move between rings to read another provider.
- Drag anywhere on the strip or card to move the panel. The card hides during
  the drag and the side settles on drop.
- Right-click for the context menu: use a Codex reset, keep open, refresh now,
  hide panel.
- The share button captures the hovered card at 2x and opens macOS share
  services. The capture crops to the card and excludes the ring strip.

The panel is a borderless, non-activating `NSPanel`. It joins every space,
floats at the status-bar level, and accepts mouse events only on itself. Because
the window never takes key focus, each ring is an accessibility element with an
explicit "Show details" action rather than a focusable control.

## Verifying a change

Unit tests cover the geometry and cannot see the rendered result. For any change
to side notch layout or motion, capture the panel for at least two providers
whose cards differ in height, and confirm the top edge renders on the same row
and the strip does not move. Report the captures in the pull request.

The bug fixed in 0.2.32 was found by logging requested and applied window frames
on the reporter's machine after six inspection-based attempts failed. Prefer a
measured frame over a plausible cause.

## References

- `Sources/MeterUsage/App/SideNotchPanelController.swift`
- `Sources/MeterUsage/Views/SideNotchPanelView.swift`
- `Tests/MeterUsageTests/SideNotchPanelTests.swift`
