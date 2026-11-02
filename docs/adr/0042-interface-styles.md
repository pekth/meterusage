# ADR 0042: Selectable interface styles

- Status: Accepted implementation direction; browser demo captures taken, native acceptance pending
- Date: 2026-11-02

## Context

Users said the renderer looked generic, and the quota heatmap was mostly empty
cells when history was short. A single redesign would replace one generic look
with another. People also disagree on taste.

## Decision

- Settings → Appearance offers a **Style** choice, saved as `interfaceStyle`
  (default `classic`). The registry in `src/shared/styles.ts` lists Classic,
  Flight Deck, Orbit, Ledger, Terminal, Blueprint, Departures and Arcade. Main
  and IPC accept only registered values. An unknown stored value falls back to
  Classic.
- Each style picks one quota meter, one side-notch gauge and one activity
  chart from a small shared set. It does not fork components. Meters keep the
  same `progressbar` role, value and text in every style. Arcade shows quota
  left as hit points; its accessible text still says percent used.
- Activity charts other than Classic's grid collapse a leading run of seven or
  more quiet days into one labelled block, such as "21 quiet weeks". They read
  the same cells, readouts and Day/Week/Total modes as the heatmap. Arrow keys
  step through days with a live readout.
- Palettes: Classic follows Theme and Accent. Ledger follows Theme as paper
  (Light) or ink (Dark). The other styles bring a fixed dark palette, so Accent
  is shown only for Classic. The notch and share card stay dark, as before.
  The tray image always renders Classic.
- Service status keeps its row, labels and status-page links in every style.
  Styles add a severity light.
- Style CSS lives in `src/renderer/interface-styles.css`, unlayered. This
  amends ADR 0041's layering for this file only: every rule is scoped to a
  style class or a style-only part, and must override the shadcn utility layer
  that Classic keeps.

## Amendment (beta.15 feedback)

- The notch and share windows are transparent. Ledger, Blueprint and Orbit make
  panel cards transparent or translucent, so in those windows every
  non-Classic card is opaque. Otherwise the desktop shows through the card and
  washes out its text.
- Settings opens 780 px wide (was 620), and the Style picker uses four
  compact columns, so the eight options take two rows.
- The activity chart's outer modifier class is `strip-kind-<kind>`. It must
  not reuse `strip-bars` or `strip-spark`, the inner row classes.

## Constraints kept

ADR 0004 and 0019: the strip stays 36 px and the card 220 px. Every gauge fits
the strip width, and the anchor and hover-only details are unchanged. ADR 0002:
provider marks are unchanged. Styles do not change polling, data or the JSON
report.

## Evidence and limits

Synthetic tests cover the registry, IPC and preference validation, saving,
meter accessibility in every style, notch gauges, Settings previews, accent
visibility, the quiet-week collapse and the service status row. Browser demo
captures cover the flyout, notch and Settings for every style, plus Ledger in
Light. Native window chrome still follows Theme: changing `nativeTheme` for a
style could also change the tray reading of the system appearance, so a Light
Theme with a fixed dark style keeps a light Settings title bar. Native Electron captures of two providers with different card heights
(ADR 0004), and a Windows check, remain separate acceptance gates.
