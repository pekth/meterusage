# Side notch panel

The side notch is the floating strip of provider rings on the screen edge. This
document describes the retained Swift behavior and the Electron candidate. The decision
record is [`docs/adr/0004`](adr/0004-side-notch-anchor-invariant.md).

## Retained Swift states

| State | Trigger | What shows |
| --- | --- | --- |
| Folded pill | Resting, no pointer | A capsule of up to five tinted dots, one per provider ring. |
| Strip | Unfolded | One ring per menu-bar provider, with the used percent and, when the reading warrants it, an ETA chip. |
| Detail card | Pointer on a ring, or the accessibility "Show details" action | The provider's rate-limit windows, reset times, pacing, telemetry, and reset credits. |

## Tints

The panel's chrome — body, hover card, ring disc and track — is tinted by the
selected accent theme, so the strip's whole colour follows the accent. The mix
takes the accent's hue and saturation and then pins the result at the base's
Rec. 709 relative luminance, so each theme renders at the same perceived
brightness as the popover's grey surfaces it stands in for; a saturated hue at a
fixed channel otherwise reads darker than a grey and made the tinted themes look
near-black. The bases are the popover's own dark values (`MU.canvas`,
`MU.surface`, `MU.well`), so strip and window are the same dark grey. Legibility
of the white figures and status bands follows from that match. The window forces
`darkAqua` (`SideNotchPanelController`) so the shared `MU` headroom scale resolves
its high-contrast variants on the dark chrome.

Within that chrome, the ring and percents carry quota headroom, while the
provider mark keeps its identity colour until a service check diverges from
healthy — degraded or outage repaints the mark (amber/red), an unreadable check
greys it, and an operational check recolours nothing. This is shared with the
menu bar by `MenuBarLabel.statusTint`.

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
  the drag, the strip stays against its side of the retained frame, and the
  side settles on drop.
  On macOS 15 and later, an explicit native window-drag gesture handles this
  alongside the context menu and buttons. Older systems keep AppKit's
  background-window dragging. The final strip corner is saved before the
  panel settles, including when the final move arrives after mouse release.
- Right-click for the context menu: keep open, refresh now, or hide panel.
  Codex reset credits are available in the Codex detail card.
- The share button captures the hovered card at 2x and opens macOS share
  services. The capture crops to the card and excludes the ring strip.

The panel is a borderless, non-activating `NSPanel`. It joins every space,
floats at the status-bar level, and accepts mouse events only on itself. Because
the window never takes key focus, each ring is an accessibility element with an
explicit "Show details" action rather than a focusable control.

## Electron candidate interaction

The candidate panel is non-focusable and uses `showInactive`, so it cannot rely
on a window blur event to dismiss a card. Pointer exit hides the detail card
through the existing 450 ms fold delay and leaves the usage strip.
During an open hover or selection interaction, main checks the native cursor
against the panel bounds every 100 ms. A missed renderer exit therefore enters
the same fold path on the next cursor check. The check stops on exit, hide, close, drag or
quit. It does not install a global input hook.

The Electron strip is a neutral charcoal 36 px rail. Each 22 px usage ring
contains its provider mark, with the used percentage below. Settings is a gear
at the bottom. The rail stays visible while details are closed or open. There is one design, with no dots markup or design selector.
Small, Medium and Large change size only. Hover opens details, ring hover
switches providers, and pointer exit closes details after 450 ms.
Disable/hide clears expanded state, so re-enabling with the pointer outside
starts with the 36 px strip and the next hover opens details normally.

The candidate has no Pin detail card or Keep open control. Legacy saved
`sideNotchPanelPinned=true` remains stored but cannot open or retain details.
The share menu, reset confirmation and drag retain their temporary guards.
Drag completion reads the current cursor rather than restoring stale hover
state. Dismissal does not change a preference. [ADR 0019](adr/0019-single-design-notch.md)
records this candidate correction; the retained Swift implementation is unchanged.

Heatmap cells show a dated readout immediately on hover or keyboard focus.
Daily cells name their date, weekly cells name the week starting Sunday, and
cumulative cells name the date through which the displayed history is summed.
Counts use the existing history scope and full numeric formatting. OpenRouter
ledger dates retain their UTC calendar day. Count-only
providers show session counts and report token totals unavailable. The readout
uses a natural-height row below the grid. Long exact counts wrap and may grow
the card without moving its top edge or rail. No blank readout area is reserved.
Keyboard focus has a visible outline. The non-activating native notch's keyboard
access still needs native proof; source fixtures cover focus labels and styles.
Codex Use reset uses the same base 11 px font and padding as compact footer
buttons. Settings panel size uses explicit integer pixel sizes for notch
text, buttons and spacing, without CSS zoom. Small uses an 11 px body and
10 px secondary text; Medium uses 13 px and 10 px; Large uses 15 px and
12 px. The visible card stays 220 pixels wide and the strip stays 36 pixels
wide. Changing size preserves their horizontal anchor. Content scrolls within
the display work area. Flyout and Settings retain their existing scaling.
Shared cards keep their original scale. Eligibility, account labels and Cancel-default confirmation remain.

Secondary labels in the Electron notch card use `#b0b0b8`, without changing
provider status or quota colors. Telemetry starts with a border and 6/8/10 px
of top padding for Small/Medium/Large. Existing metric margins remain.
Enabled detail buttons transition only the background color for 120 ms on
fine-pointer hover when reduced motion is off. Strip Settings text color
changes immediately. Press and keyboard focus stay
immediate, and reduced motion disables transitions. Card, window, ring and
provider-switch states do not animate. Browser and native checks must verify
these rendered states and scrolling after the added telemetry spacing.

Live cards use the natural-height heatmap readout and show Daily, Weekly and
Cumulative choices with their existing values. Quota, eligible reset actions and
heatmaps remain visible. Recorded activity starts with two available metrics;
More activity opens the remaining metrics. Usage by period and Active window
breakdown open the existing period and burn details. These rows start closed.
Tighter spacing and a shorter sparkline reduce card height without changing the
saved font-size choice or the rail. Static exports retain all metrics and full
period/burn data. Recorded activity headings and
Recorded sessions/messages labels distinguish telemetry from account/local
summary counts. Static shared cards omit footer actions, reset buttons and the
heatmap selector while retaining credit details and the 26 weeks label. They
also omit the unused hover readout space. Export width, full-height sizing and
frozen selected-account behavior retain their existing implementation. Native
export completeness remains a separate check.

## Verifying a change

The Electron candidate bounds the card and strip independently. The native
window supplies the display work-area height; the browser demo uses the viewport
height when that value is absent. Tall content scrolls inside each column. The
candidate hides scrollbar indicators throughout its windows while retaining
scrolling. The strip is 36 pixels wide around the provider marks and rings. The shared-card
capture keeps its 250-pixel width, full height and does not use the notch's scrolling bounds.

Automated tests cover geometry and in-process drag events, but cannot see the
rendered result. For any change to side notch layout or motion, capture the
panel for at least two providers whose cards differ in height, and confirm the
top edge renders on the same row and the strip does not move. Report the
captures in the pull request.

The macOS 15+ event test sends mouse-down, drag, and mouse-up through the real
hosted panel in folded and pinned states. It checks initiation, release, and
ordinary clicks without setting the drag state itself. It does not prove
physical pointer movement by the Window Server. A simulated frame move before
release also checks that the drop keeps its new position.

A native bitmap test renders the strip inside a retained expanded window for
both card sides and two heights. It checks the visible strip's anchored edge
and top row, catching horizontal recentering when the card hides during drag.

Drag from both the strip and an open card. Release once inside the panel and
once outside it. After each drop, hover a provider to reopen its card and drag
again. The panel must follow the pointer, settle on release, and reopen cards
at their full width without moving the saved strip anchor.

The bug fixed in 0.2.32 was found by logging requested and applied window frames
on the reporter's machine after six inspection-based attempts failed. Prefer a
measured frame over a plausible cause.

## References

- `Sources/MeterUsage/App/SideNotchPanelController.swift`
- `Sources/MeterUsage/Views/SideNotchPanelView.swift`
- `Tests/MeterUsageTests/SideNotchPanelTests.swift`
