<!-- ai-skills-managed: NO-LOOPS.md -->
<!-- source-commit: e466aa1f7cbee3c6e3e4c6896c11b63a3283442d -->
<!-- source-sha256: cf79bf301d205bcac2ad87c7ba0f16fa77aab74b849827c5ab081b822cab1db4 -->
# NO-LOOPS.md: PROHIBITED NO-LOOP RULES

These rules apply to every controller, agent, provider, skill, and tool.

## PROHIBITED

- Do not repeat the same `target + check + result` failure tuple.
- Do not retry without new evidence or a materially different method.
- Do not reuse an assumption after the user corrects it.
- Do not use the wrong path, surface, source, or target.
- Do not let `.handoff/ACTIVE.md` override an explicit thread ID.
- Do not claim a check passed without successful, observable output.
- Do not treat a failed command as evidence.
- Do not repeat setup, login, or manual instructions that already failed.
- Do not guess a tool, MCP, CLI, credential, or secret.
- Do not open UI before checking declared CLI, API, MCP, and authentication state.
- Do not give external or manual instructions before checking local/project facts.
- Do not skip project docs, known-good baselines, or the full requested path.
- Do not switch tools or browsers after failure without authorization and a reason.
- Do not hide red checks or report guessed results.
- Do not mark an unresolved task complete.
- Do not claim `RUNNING` without live proof, fresh evidence, and a heartbeat.
- Do not continue after stale or missing heartbeats; report `PAUSED`.
- Do not stop silently.
- Do not request permission again after it was granted.
- Do not stop the parent task when a worker ends.
- Do not use a worker, commit, build, PR, or staging state as completion proof.
- Do not leave idle, completed, canceled, duplicate, or stalled workers open.
- Do not create oversized, duplicate, filler, or unfocused workers.
- Do not run a long task without a bounded objective and stopping point.
- Do not copy generic rules or duplicate policy prose.

## Required reset after the first failure

1. Record the exact tuple: target, check, and result.
2. Stop that approach. Get new evidence or choose one materially different,
   justified method.
3. Verify successful output before reporting progress.
4. If no safe new method exists, report `PAUSED` or `BLOCKED` with exact
   evidence, required user action, and next action.

User corrections replace contradicted assumptions. Verify the exact path, item,
or state named by the user before giving replacement instructions.
