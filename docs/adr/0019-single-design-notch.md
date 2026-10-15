# ADR 0019: One Electron side-notch design

- Status: Accepted implementation direction; independent review and native acceptance pending
- Date: 2026-10-11
- Supersedes: [ADR 0018](0018-hover-only-notch-details.md)

## Decision

The Electron side notch has one usage-ring and percentage strip. Keep it
visible whether details are open or closed. Remove the candidate dots markup,
CSS, Resting strip selector, preference schema, validation and IPC projection.
Do not migrate or reset real preferences.

Keep hover-only details and the 450 ms leave-close delay. Legacy pin data
cannot retain details. Small, Medium and Large remain size choices with
explicit integer pixel text and controls. Preserve logos, the 44 px strip,
the 250 px detail card and ADR 0004's fixed top and strip edges.

Clear expanded state in the shared disable/hide path. Re-enabling with the
pointer outside must show only the strip; subsequent hover must still open
and close details. Share, reset confirmation and drag guards remain.

## Evidence and limits

Synthetic checks cover the single strip for two providers, removed preference
and IPC rejection, unchanged stored fixture bytes, disable/hide/re-enable and
subsequent hover recovery. TypeScript, renderer build and main/preload packing
verify source inputs. Independent review, browser captures and native cursor,
anchor, package and install proof remain separate Controller-owned gates.
The retained Swift implementation is unchanged.
