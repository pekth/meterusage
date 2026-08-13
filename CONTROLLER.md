<!-- ai-skills-managed: CONTROLLER.md -->
<!-- source-commit: e466aa1f7cbee3c6e3e4c6896c11b63a3283442d -->
<!-- source-sha256: 11ab1c26224edde68e81ad14b1126a2386781782dc34763fdbf4f49b63908b98 -->
# CONTROLLER.md: T3 Code orchestration spec

This file governs T3 Code routing, delegation, checkpoints, and worker lifecycle.
It operates beneath `AGENTS.md`; conflicts are resolved in favor of `AGENTS.md`.

## 1. Authority

- The Controller manages execution, not policy.
- The primary agent is the Controller and senior engineer accountable for the whole
  outcome; it delegates according to the mandatory rules in Section 2.
- Keep the Controller and every worker inside the user's authorized scope.
- Tool or provider capability never creates permission.
- Preserve unrelated files, state, and concurrent work.
- An explicit user-supplied thread ID is authoritative; verify thread identity before using handoff state, and let `.handoff/ACTIVE.md` supplement but never redirect or replace that thread.

**PROHIBITED:** weakening `AGENTS.md`, expanding scope to manufacture progress,
silently switching providers, or performing destructive work without authority.

## 2. Delegation

Delegation is mandatory for every top-level T3 Code project session. On the first
substantive project task, including read-only review or diagnosis, follow the
`AGENTS.md` delegation gate before main execution. Publish the execution map,
call `list_agents`, and call `spawn_agent` for at least one useful bounded child
task. A retained child or `followup_task` does not satisfy this mandatory first
delegation. Explicitly spawned child agents are exempt from this startup gate and
do not have to delegate recursively. After the first spawn succeeds, reuse a
compatible retained child for later bounded tasks when its ownership and scope
remain valid.

This requirement applies regardless of project, worktree, task size, or selected
Codex model. It is the explicit `AGENTS.md` authorization required by restrictive
multi-agent modes. The Controller keeps ownership of scope, sequencing,
integration decisions, verification standards, and final synthesis. It delegates
the execution of every substantive implementation, diagnosis, research, test, and
document drafting slice. The Controller MUST NOT use one token child to unlock a
mostly solo execution path. Never create filler, duplicate, or cosmetic workers.
Use a real independent 5 to 10 minute slice such as context verification, a
baseline check, focused research, review, or testing.

- Keep dependent work sequential and assign exactly one writer per path.
- Give each worker one small task targeting 5 to 10 minutes of useful work.
- Every assignment states objective, allowed and preserved scope, owned paths,
  acceptance proof, required evidence, and an explicit stop condition.
- Documentation-only updates go to Luna low/medium: low for simple metadata/copy, medium for technical/policy docs, unless the user/higher authority specifies otherwise or delegation is disproportionate.
- A worker has no authority outside its assignment and cannot declare overall
  completion.

### Visible execution map

Before spawning workers, publish a concise execution map showing:

1. Ordered stages and dependency gates.
2. Every planned worker under its owning stage.
3. Each worker's objective or owned path.
4. Status as `pending`, `active`, `done`, `failed`, or `blocked`.
5. The final Controller-owned reconciliation or synthesis stage.

Use only stages the task needs, such as
`Analyze -> Implement -> Verify -> Judge -> Synthesize`. Prefix worker names with
their stage, for example `analyze_usage` or `verify_windows`, so the T3 Agents panel
remains readable.

Update the map when a worker starts, finishes, fails, or unblocks dependent work.
It must reflect actual state; never present planned, completed, or canceled work as
active. Query live worker state before reporting `active`; otherwise report
`unknown` or `blocked`. A top-level project task always has a worker under the
mandatory delegation gate. A child-agent task with no descendants needs no map.

### Child ownership and lifecycle

The Controller that calls `spawn_agent` owns that child and every descendant for
the lifetime of the owner thread. Ownership cannot be transferred by starting a
new session or by writing a handoff.

- Visibility does not prove ownership. The interrupt allowlist contains only the
  exact canonical paths returned by this Controller's own `spawn_agent` calls in
  the current owner thread. Never infer ownership from a shared `/root` prefix,
  worker name, worktree, age, UI status, or appearance in a global panel.
- Before spawning, call `list_agents`. Reuse a compatible retained idle handle
  with `followup_task` when it belongs to the same owner thread and can receive the
  current scope and artifact identity. Spawn only when no compatible child exists.
- Immediately record the canonical task path returned by `spawn_agent`, owner
  thread, stage, objective, owned paths, current artifact or commit identity, start
  time, stop condition, and expected evidence in the execution map.
- Treat `pending`, `running`, and `waiting` as an active turn. Treat `idle` as a
  retained idle handle: it has no active turn, remains resumable, and is not proof
  that the task was reconciled.
- The collaboration interface may retain an idle handle without exposing a
  retire/close operation. Never claim that such a handle was closed or ask the user
  to perform an operation unavailable in their session. Report it accurately and
  reuse it when compatible.

Run a **cleanup barrier** on every user stop, task replacement or scope reset,
handoff to another session, context recovery after compaction, parent failure or
block, and before the final response:

1. Call `list_agents` for the owned task tree and reconcile it with the execution
   map.
2. Intersect the live results with the interrupt allowlist. Call `interrupt_agent`
   only for an exact owned path whose active turn must not continue, including
   duplicate, superseded, stalled, canceled, or out-of-scope work.
3. Query `list_agents` again. Do not cross the barrier until the owned tree has zero
   active turns and every returned result is reconciled or explicitly discarded.
4. Mark retained idle handles as `idle · resumable`, not `active`, and include their
   canonical paths in the lifecycle receipt.

If the current Controller cannot see or interrupt a displayed child because another
owner thread created it, report `ORCHESTRATION BLOCKED` with the exact child path and
owner thread if known. Never interrupt a child created by another thread, even when
it appears stale or shares a name or path prefix. Do not spawn replacement workers,
claim cleanup, or direct the user to inaccessible session controls. The owner
Controller must remain active long enough to complete its cleanup barrier before
any handoff.

### Durable handoff checkpoint

Use `.handoff/ACTIVE.md` in the current worktree as the one canonical handoff for
the current project. The handoff is an operational checkpoint, not an alternate
source of authority. Current user instructions and observed repository state win
whenever they conflict with it.

At the start of a substantive project task, read and reconcile the canonical
handoff as required by `AGENTS.md`. Run a **durable checkpoint barrier** after each material stage and on every proven completion, user stop, task replacement or scope reset, pause or block, handoff to another session, anticipated context compaction or immediate context recovery, parent failure, and before the final response.

Run the child cleanup barrier first so the checkpoint contains final live child
state. Then update the canonical handoff with:

1. The exact `Session`, `Turn`, and `Prompt digest` values injected by the native
   Controller hook for the current turn.
2. The current objective and status: `active`, `paused`, `blocked`, `complete`,
   `superseded`, or `canceled`.
3. The current target and every affected product, platform, or client surface.
4. The latest user decisions, plus any superseded decisions clearly labeled with
   what replaced them.
5. Authorized scope, preserved scope, and acceptance proof.
6. Current worktree, branch, `HEAD`, and dirty state.
7. Files and external artifacts changed, with ownership and current identity.
8. Completed work and verification evidence, including exact commands and
   results; never convert an unverified claim into fact.
9. Failed attempts and do-not-repeat evidence, including the observed failure and
   the new evidence required before another attempt. Never repeat a failed or
   superseded approach merely because a new session started.
10. Unfinished work and the exact next action in dependency order.
11. Blockers and required authorization or user action.
12. Child task paths, states, and cleanup evidence, including retained idle
    handles that are safe to reuse.
13. The current execution map and links to any authoritative plan or decision
    document instead of duplicated status prose.

Write current truth, not an optimistic forecast. Remove or mark obsolete active
claims so one file cannot describe two current realities. After writing, read the canonical handoff back and compare its status, artifact identity, next action, failure history, and child receipt with live state. Do not cross the barrier on a write failure, missing required field, stale read-back, or unresolved contradiction. Report `CONTINUITY BLOCKED` with exact evidence and keep the task status incomplete.

## 3. Time and cost controls

- Use the least costly model and effort that safely fits the task; do not spend for
  visibility or duplicate verification.
- At 15 minutes or twice any stated estimate, whichever comes first, report an
  evidence/scope/next-decision checkpoint.
- At 30 minutes, reassess the approach, remaining scope, delegation, and cost before
  continuing.
- During active or background work, send a proof-of-life update at least every 60
  seconds: current stage, last completed action, and fresh observable evidence.
- Report `RUNNING` only after a live-state query and fresh evidence. Two missed
  heartbeats mean `STALE`: clear running state and immediately report `PAUSED`, the
  missing evidence, and the next action.
- If a worker makes no useful progress for 10 minutes, request status once. Repeated
  no-progress means call `interrupt_agent` and confirm the active turn stopped.
- At every heartbeat and reconciliation, run the child ownership checks above.
- Never keep an active turn open for visibility or defer a cleanup barrier to a new
  session.

## 4. Results and failure handling

Every worker result is evidence, not terminal status. The Controller reconciles it
against the requested outcome, updates dependencies, and continues safe authorized
work until completion or a valid stopping condition.

- If execution pauses, immediately report `PAUSED`, the exact blocker, the exact
  user action required, and the next automatic step. Never stop silently.
- After a worker stops, continue the parent task, start the next bounded stage, or
  report the exact blocker.

Follow the verification and failure loop in `AGENTS.md`. For the same failure, make
only one bounded fix and re-verify. A further attempt requires new evidence and a
different justified approach. Never hide a red check, repeat a contradicted approach,
or treat a child, commit, PR, build, or staging state as completion proof.

Follow the binding global no-repeat rules in [`NO-LOOPS.md`](./NO-LOOPS.md).

## 5. Closeout receipt

Before closing, reread the request and report:

- `Implemented:` what changed, or `N/A`.
- `Applied:` where the change is active, or `N/A`.
- `Verified:` observable proof run, or `unverified` with the reason.
- `Surfaces:` each affected surface checked, or explicit `N/A`.
- `Children:` active turn count, retained idle handle paths, and cleanup evidence,
  or `N/A` when no child was created.
- `Continuity:` canonical handoff path, recorded status, and successful read-back
  evidence, or `CONTINUITY BLOCKED` with the exact failure.
- `Unresolved:` failures, blockers, and decisions, or `none`.

Do not label work done, fixed, working, or complete unless the requested acceptance
items are verified in the real target where required.

## 6. Valid stopping conditions

Continue while safe, authorized, in-scope work remains. Stop only for:

1. **Proven completion:** every requested acceptance item has observable proof.
2. **User stop:** the user explicitly says to stop.
3. **Authorization block:** progress needs new permission, authority, secret access,
   browser access, or destructive-action confirmation.
4. **External dependency block:** required external state, service, device, account,
   or physical system is unavailable.
5. **Safety or legal block:** a binding rule prevents continuation or requires user
   action.

A worker stopping or failing is not an overall stopping condition.
When the user grants the exact requested authorization, report `RESUMED` and take
the next action immediately. Do not request the same permission again.
