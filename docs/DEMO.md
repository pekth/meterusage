# Demo mode

Demo mode runs the real app against invented data.

It exists so that screenshots — for the README, an issue, a blog post — and
contributor testing never require a real account, a signed-in CLI, or exposing
anyone's actual usage. A maintainer's real popover shows real spend, real
session counts, and a real plan tier; none of that belongs in a public repo.

## Launch it

The app is a bundle, and `open` does **not** pass your shell environment to a
bundled app, so `METERUSAGE_DEMO=1 open -a MeterUsage` silently launches the
normal app. Use `--env`, which `open` forwards for you:

```sh
open -a MeterUsage --env METERUSAGE_DEMO=1
```

Or run the binary directly, where the shell environment does apply:

```sh
METERUSAGE_DEMO=1 /Applications/MeterUsage.app/Contents/MacOS/MeterUsage
```

From a checkout, no build product needed:

```sh
METERUSAGE_DEMO=1 swift run meterusage
```

Quit and relaunch without the variable to go back to your own data.

## What it is, and isn't

It is **not** a mock UI. The real views, the real coordinator, the real
formatters, and the real colour thresholds all run exactly as they do in
production. The only thing swapped is the set of data sources — real ones read
your CLIs and transcripts, demo ones return fixed values from memory.

That means a demo screenshot is a truthful picture of the app. It is just not a
picture of anybody's account.

## Everything you see is fake

All demo data is synthetic and invented:

- **Claude** — Max 5× plan, 5-hour window at 34%, 7-day at 61%.
- **Codex** — Plus plan, 5-hour window at 82%, weekly at 72%, a small credit
  balance.
- **Local activity** — 58 sessions, ~55M tokens, ~$156 estimated, across
  invented project names like `web-app` and `api-server`.
- **Heatmap** — about 20 of the last 26 weeks populated, at varied intensity.

The percentages are picked to make the popover *legible* rather than dramatic:
one window sits in the amber band and the rest are green, so a screenshot shows
that the colour scale distinguishes healthy from tight. Nothing sits near 100%,
which would read as an emergency and flatten the whole scale into one alarming
tint.

Reset times are computed relative to the moment you launch, so a screenshot
retaken next year still shows a sensible countdown. Session and daily figures
come from a fixed seed, so a retake differs only where time has genuinely moved
on.

Costs are computed by the app's own pricing table from the demo token counts,
so demo mode can never display a figure the real code wouldn't have produced.
Some demo sessions deliberately run a model with no published per-token rate,
which is what makes the `—` cost cell and the "the total understates real
spend" footnote appear — two of the most easily misread parts of the UI, and
better shown in the README than discovered later.

## It cannot switch on by accident

- The environment variable must be exactly `1`. `true`, `yes`, `0`, and an
  empty value all mean off.
- It is read once, at launch, in the composition root — so half the popover can
  never be real while the other half is invented.
- A **Demo** badge sits beside the title in the popover header the whole time
  it is on. It is quiet enough not to spoil a screenshot and unmistakable on
  inspection, so a demo shot can't be mistaken for real telemetry and nobody
  files a bug about the numbers being wrong.

## No network, no disk

The demo sources touch nothing. No request is made, no file is read, no
provider CLI is spawned. That is asserted in
`Tests/MeterUsageTests/DemoSourcesTests.swift`, alongside checks that demo mode
is off by default and that no demo project name contains a path separator or a
username.
