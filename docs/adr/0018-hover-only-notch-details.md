# ADR 0018: Hover-only Electron notch details

- Status: Superseded by [ADR 0019](0019-single-design-notch.md). The text below preserves the prior candidate decision.
- Date: 2026-10-11

## Decision

The Electron candidate opens provider details on hover and closes them after
450 ms outside the panel. Moving between rings selects that provider. The
native cursor check remains the fallback for a missed renderer exit.

Settings offers Usage and Compact dots for the resting strip. Usage is the
default for new and existing profiles without a saved choice. It keeps rings
and percentages visible while details are closed. Dots reuses the folded pill.
Invalid saved choices fall back to Usage.

Remove Pin detail card and Keep open controls. Retain legacy stored pin data
without using it to open or retain details. Temporary share, reset confirmation
and drag guards remain. No account or sign-in state changes.

Use explicit integer pixel sizes for Small, Medium and Large notch content.
Small has an 11 px body and 10 px secondary text. Do not scale notch content
with CSS zoom. Retain flyout and Settings scaling and original share rendering.

## Scope and evidence

This decision supersedes the Electron candidate pin behavior and fractional
notch sizing described in SIDE-NOTCH.md. It leaves the retained Swift behavior
and ADR 0004's anchor invariant unchanged: a 44 px strip, a 250 px card, and a
fixed top and strip edge when details change.

Synthetic checks must cover old pin=true data, preference validation, both
resting modes, two-provider selection, delayed closure and temporary guards.
Browser captures and native two-provider anchors, cursor events, reset/share
menus and drag recovery remain separate acceptance gates.
