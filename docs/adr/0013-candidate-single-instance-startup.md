# ADR 0013: Validate candidate singleton metadata before startup

- Status: Accepted implementation direction; native acceptance pending
- Date: 2026-10-10

## Decision

Amend ADR 0012's blanket symlink rejection for the macOS GUI only. Electron
creates `SingletonSocket`, `SingletonCookie` and `SingletonLock` links directly
under its profile directory. Rejecting those links prevents a second launch
from reaching Electron's single-instance lock.

Accept the three links only as a coherent set owned by the current user. Check
the local hostname and numeric lock PID, matching numeric cookies, and a UNIX
socket below the OS temporary root. Require direct directory ancestors and a
private socket directory owned by the user. Inspect link metadata without
following profile links or deleting them. Reject every other profile symlink,
incomplete or incompatible metadata, and nonregular profile nodes. JSON
entrypoints retain strict symlink rejection.

Select isolated Electron paths before requesting the native lock. A secondary
instance exits before preference loading or collection. The primary instance
coalesces activation requests until startup finishes and ignores activation
during Quit. Catch startup errors and exit with a fixed message instead of an
uncaught exception popup.

This validation is not a sandbox against concurrent filesystem changes by the
same user. It does not add automatic lock cleanup or process termination.

## Acceptance

Synthetic tests cover coherent metadata, rejected links and socket targets,
lock ordering, early activation, and activation during Quit. Native acceptance
requires the packaged candidate to reopen the same isolated profile, route a
duplicate launch to the primary window, retain account allowance and quit.
Installed-app, migration and release holds remain unchanged.
