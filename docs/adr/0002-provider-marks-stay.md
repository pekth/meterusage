# ADR 0002 — Provider marks and logos stay

- Status: Accepted
- Date: 2026-09-12

## Decision

Provider icons and logos are frozen as product identity. Feature work and any cross-platform shell must reuse the existing marks; they must not replace them with a new icon set.

## Assets

- `Resources/codex-logo.png`
- `Resources/grok-logo.png`
- `Resources/opencode-logo.png`
- `Resources/antigravity-logo.png`
- `Resources/AppIcon.png` / `Resources/AppIcon.icns`
- Rendered via `ProviderMark` (`Sources/MeterUsage/Views/MenuBarLabel.swift`)

## Consequences

- Menu bar, popover, settings, side notch, notifications, and future Windows UI load these assets (or lossless copies).
- Headroom and pacing cues attach to `%`, rings, chips, and copy — not to redesigned brand marks.
- Providers that today use an SF Symbol stand-in may later gain a real logo asset; that is additive, not a redesign of existing logos.

## References

- [docs/mockups/README.md](../mockups/README.md)
- [docs/plans/feature-and-windows-pipeline.md](../plans/feature-and-windows-pipeline.md)
