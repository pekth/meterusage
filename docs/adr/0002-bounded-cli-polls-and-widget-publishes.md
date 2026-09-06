# ADR-0002: Bounded CLI polls and meaningful widget publishes

- Status: Accepted
- Date: 2026-09-06

## Decision

The JSON CLI races each provider operation against its timeout without waiting for a provider that ignores cancellation. The first result completes the caller. A late provider result is ignored.

The menu-bar app writes the widget snapshot and reloads widget timelines when the report schema or provider payload changes. Unchanged provider data gets a 30-minute heartbeat, before the widget's one-hour stale boundary. The write state advances only after a successful file write.

## Context

The prior task-group timeout cancelled a slow provider but still waited for its task-group scope to finish. A noncooperative provider could therefore keep a script waiting past the intended limit.

The app produces a new report timestamp on every refresh. Treating that timestamp as a widget data change rewrote the same provider payload and requested widget reloads without new quota information. Never writing it again would make a healthy widget appear stale after one hour. A failed write must not suppress its retry.

## Consequences

- The CLI returns at its timeout even if a provider completes later.
- The current in-app report remains fresh on each refresh.
- An unchanged provider payload refreshes the widget snapshot at most once every 30 minutes.
- A failed snapshot write retries on the next app sweep.
- Tests use synthetic held operations and report values. They do not need provider accounts or local provider data.
