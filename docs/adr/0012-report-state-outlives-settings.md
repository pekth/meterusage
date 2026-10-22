# ADR 0012: Report state outlives Settings

- Status: Accepted; native interaction pending; native-client delivery verified 2026-10-08
- Date: 2026-10-08
- Amends: The view-lifetime retry limit in [ADR 0011](0011-login-free-linear-reports.md)

## Decision

The existing app coordinator owns diagnostic submission state. Settings reads
that state and requests a send. Leaving Settings does not discard an in-flight
report, its UUID and snapshot, or its eventual receipt or error.

A second send is blocked while one is running. An uncertain retry uses the same
UUID and snapshot. A confirmed receipt remains visible when Settings reopens
and keeps Send disabled for the rest of the app session.

## Consequences

- Navigation cannot start a second report while the first is pending.
- Report state stays in memory until the app quits. There is no disk queue,
  automatic retry or restoration after relaunch.
- The relay, privacy allowlist and server receipt checks remain unchanged.
- Deployment and live report verification remain required before distribution.
