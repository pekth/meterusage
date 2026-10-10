# ADR 0014: Keep onboarding in Settings

- Status: Accepted implementation direction; native acceptance pending
- Date: 2026-10-10

First-run setup occupied the main usage panel and duplicated Settings account
connections. Keep setup in Settings so the main panel remains focused on usage.
This refines the setup placement in ADR 0011; account access and consent remain
unchanged.

While `onboardingCompleted` is false, launch and app activation open Settings.
Reuse its account connection controls, add brief first-time guidance and a Done
button, and allow completion without sign-in. Save the existing preference before
hiding Settings and opening usage. A failed save retains setup and shows an error.
Completed profiles keep their existing startup behavior and account controls.

Do not add a new preference, IPC action, setup window or authentication flow.
The published Swift app and migration, provider and release acceptance gates
remain unchanged.
