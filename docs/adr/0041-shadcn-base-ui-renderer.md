# ADR 0041: shadcn/ui on Base UI for renderer components

- Status: Accepted; usage panel migrated, Settings and side-notch strip unchanged
- Date: 2026-11-01

## Context

The Electron renderer used hand-written CSS for buttons, tabs, disclosure rows
and native `<select>` menus. User feedback said the usage panel was too big and
the quota heatmap looked broken. Rebuilding that UI by hand would mean more
roving-focus, toggle and scroll code to maintain.

## Decision

- Renderer components come from [shadcn/ui](https://ui.shadcn.com/) with
  [Base UI](https://base-ui.com/) (`@base-ui/react`) as the primitive layer,
  installed with `shadcn init --base base` (style `base-nova`). Generated files
  live in `src/renderer/components/ui` and may be edited. `components.json`
  points the CLI aliases there.
- shadcn tokens (`--background`, `--primary`, `--muted-foreground` and the rest)
  are derived from the app theme on `.app`, so components follow the System,
  Light and Dark themes and the chosen accent. The app's own variables that
  shared shadcn names are renamed: `--accent` to `--brand`, `--muted` to
  `--text-muted`. The Tailwind `dark:` variant follows `.theme-dark` and
  `.theme-system` under a dark system appearance.
- Hand-written styles sit in Tailwind's `components` layer, so utility classes
  on shadcn components override them where both apply.
- The shadcn CLI is a dev dependency. The Geist web font is not used; the
  system font stays.
- Popover-style components that portal to `<body>` are not used yet. Adding one
  requires putting the theme tokens on its portal container.

## Consequences

- The usage panel uses Button, Badge, Tabs, ToggleGroup, Collapsible and
  ScrollArea. Base UI injects a small inline `<style>` element for ScrollArea,
  which the existing `style-src 'unsafe-inline'` policy allows.
- The side-notch detail card shares ProviderCard, so it also gets the heatmap
  ToggleGroup. Strip geometry and the anchor rules in
  [ADR 0004](0004-side-notch-anchor-invariant.md) are unchanged.
- The renderer bundle includes Base UI, class-variance-authority, `cn` and
  lucide-react.
