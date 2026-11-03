# ADR 0043: Wide Settings layout

- Status: Accepted; layout checked on a Mac with a test build of `67fa252`; first-show clamp covered by tests only
- Date: 2026-11-02
- Amends: [ADR 0042](0042-interface-styles.md) (Settings width of 780 px)

## Context

ADR 0042's amendment opened Settings at 780 px. On a Mac, beta.16's Settings
window still measured 780 × 1006 px. The page CSS capped content at 760 px,
and every category stacked its rows vertically, so Settings grew taller rather
than wider.

## Decision

- Settings opens 1040 px wide. Before the first show, the window is narrowed
  to its display's work area and moved inside it (`fitWidth`), because
  `sizeSettings` waits for the renderer's first resize. Its content may use
  1000 px.
- Appearance places the Style grid across the page, with panel size and Theme
  side by side below it.
- Connections and API connections lay their cards out in two columns when the
  content is at least 820 px wide.
- Providers stays a single column, because it is a drag-to-reorder list.
- These layout rules apply to every interface style. They live in
  `style.css`, in the components layer, before Tailwind's `@theme` block.

## Evidence and limits

In the browser demo build at 780 and 1040 px, Connections dropped from 902 to
643 px tall, API connections from 924 to 673 px, and Appearance from 663 to
615 px.

On 2026-11-02, a local test build of revision `67fa252` opened Settings on a
2560-pixel-wide Mac display at 1040 px, with two columns of connection cards.
The build was Developer ID signed, not notarized, and labelled
0.3.0-beta.16, build 9105. Later commits change docs and add the
first-show clamp. The clamp has not been seen on a display narrower than
1040 px. Unit tests cover it on narrow and offset work areas, and a
lifecycle test covers the 1040 px window. A renderer test covers the
markup, CSS rules and layer placement.
