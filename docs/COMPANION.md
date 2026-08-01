# Feeding the Claude quota bars

meterusage never calls Anthropic for quota. The Claude quota card is driven
entirely by a JSON file that some *other* tool on your machine writes:

```
~/.claude/claudewatch-usage.json     # checked first
~/.claude/meterusage-usage.json      # checked if the first is absent
```

No file means no Claude quota card. That is the normal, expected state — the
app is useful without it, and its absence is never reported as an error.

This document is for people who already have such a writer and want the
per-model weekly windows (Fable's own weekly quota among them) to show up.

## Why the Fable bar is usually missing

Claude Code's usage API returns a `limits` array alongside the older
`five_hour` / `seven_day` blocks:

```json
{
  "limits": [
    { "kind": "session",       "group": "session", "percent": 10, "scope": null },
    { "kind": "weekly_all",    "group": "weekly",  "percent": 22, "scope": null },
    { "kind": "weekly_scoped", "group": "weekly",  "percent": 30,
      "scope": { "model": { "id": null, "display_name": "Fable" } } }
  ]
}
```

`limits` is the **only** place per-model weekly windows exist. The commonly
used statusline writers extract just `five_hour`, `seven_day`, and
`extra_usage`, and discard the rest of the response — so the file they write
cannot express a Fable window, and no reader can show one.

meterusage parses `limits` whenever it is present. If your writer emits it,
the bars appear; if it doesn't, you get the legacy windows and nothing is
broken. The app never invents a window it wasn't given.

## Making a writer emit it

Pass the array through **verbatim**. meterusage already understands the API's
own `kind` values, so reshaping it into a bespoke schema only creates a second
dialect to keep in sync.

If your writer caches the raw API response, merging it in is a few lines. This
runs after the existing writer, so it needs no changes to that writer at all —
useful when the writer is managed by something that overwrites your edits:

```sh
merge_usage_limits() {
    command -v jq >/dev/null 2>&1 || return 0

    target="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/claudewatch-usage.json"
    cache="/path/to/your/cached-api-response.json"
    [ -f "$target" ] && [ -f "$cache" ] || return 0

    # Only merge a non-empty array: an API hiccup must not blank out a good
    # previous value.
    jq -e '(.limits | type == "array") and (.limits | length > 0)' \
        "$cache" >/dev/null 2>&1 || return 0

    tmp="${target}.tmp.$$"
    if jq --slurpfile cached "$cache" '. + { limits: $cached[0].limits }' "$target" > "$tmp" 2>/dev/null \
       && [ -s "$tmp" ] && jq -e . "$tmp" >/dev/null 2>&1; then
        mv "$tmp" "$target"   # atomic: a reader never sees a half-written file
    else
        rm -f "$tmp"
    fi
}
```

Three properties worth keeping if you write your own version:

- **Fail silently and leave the file alone.** These are bonus fields. Nothing
  here is worth corrupting the 5h/7d data that already works.
- **Write to a temp file, validate, then `mv`.** meterusage may read the file
  at any moment; a half-written file must never be observable.
- **Never write a placeholder.** A missing percentage should be absent, not
  `0` — see below.

## What meterusage does with it

| Entry | Rendered as |
|---|---|
| `kind: "session"` | `5-hour` |
| `kind: "weekly_all"` | `Weekly · All models` |
| `kind: "weekly_scoped"` | `Weekly · <scope.model.display_name>` |
| unknown `kind` with a model name | `<group> · <model name>` |
| unknown `kind` with no model name | skipped |

Behaviour that is pinned by tests, so you can rely on it:

- **Render order is imposed by the app, not inherited from your array.**
  Session first, then the all-models weekly window, then per-model weekly
  windows. Order your array however you like.
- **`limits` fully replaces the legacy keys** when it yields at least one
  displayable window — otherwise the same window would appear twice under two
  names. If nothing in it is displayable, the legacy `five_hour` / `seven_day`
  keys are used as usual.
- **An entry with no `percent` is skipped, never drawn as 0%.** An empty bar
  is a positive claim of full headroom, which is exactly backwards if the real
  figure is 99%.
- **`resets_at` accepts either shape** — an ISO-8601 string (what `limits`
  uses) or an integer epoch (what the legacy blocks use).
- **Unknown keys are ignored**, including `severity` and `is_active`. An
  `is_active: false` entry is still displayed; the real API sets it on windows
  the usage screen shows.

## Privacy

meterusage only ever reads this file. It never writes it, never creates it,
and never asks you to install a writer. See [PRIVACY.md](PRIVACY.md) for the
full boundary.
