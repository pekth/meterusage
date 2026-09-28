# ADR 0010: Show OpenAI API spend in the side notch

- Status: Accepted
- Date: 2026-09-27

Add OpenAI API to the side notch with the existing provider Notch control.
Keep it out of menu-bar quota clusters. Enabling the provider selects its
notch entry by default; users can hide it independently.

The entry shows reported spend for the last 30 UTC calendar days. Its mark has
no progress arc, percentage, reset, or pace. Reuse the popover's usage details
and unavailable-state guidance in the hover card. Keep measured zero distinct
from missing data and retain the reading's own capture time.

This extends the display locations in ADR 0007 while preserving its
organization billing boundary. Anthropic remains popover-only. The anchor,
geometry, and capture requirements in ADR 0004 remain unchanged.
