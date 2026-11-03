# ADR 0043: Wide Settings layout

- Status: Accepted; checked on a Mac with a local test build
- Date: 2026-11-02
- Amends: [ADR 0042](0042-interface-styles.md) (Settings width of 780 px)

## Context

ADR 0042's amendment opened Settings at 780 px. On a Mac, beta.16's Settings
window still measured 780 × 1006 px. The page CSS capped content at 760 px,
and every category stacked its rows vertically, so Settings grew taller rather
than wider.

## Decision

- Settings opens 1040 px wide, clamped to the work area. Its content may use
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
615 px. A local, Developer ID signed test build from the change opened
Settings on a Mac at 1040 px, with two columns of connection cards. A test
covers the markup, CSS rules, layer placement and window width.
