---
name: task-intake
description: Agent-only intake procedure for new work. Load at every new task or follow-up intake, before resolving its project or secondmate route, classifying it as ship, scout, or council, resolving its delivery mode, dispatch profile, or concurrency, writing its brief, or spawning it.
user-invocable: false
metadata:
  internal: true
---

# Task intake

This skill owns the intake procedure that turns a captain request into a dispatched task.
`AGENTS.md` section 7 keeps the always-loaded authority rules (merge authority, delivery-path rigor, isolation) and points here for the procedure.

## Resolve the project and the route

Resolve the project independently for every request.
An explicit project wins, a clear follow-up inherits its referent, and otherwise match the request against the registry, work under way, and project code or README.
Proceed on one confident match while naming the project in plain language; ask one concise question when multiple or no projects plausibly match.

Route by the nature of the work against each registered secondmate scope, not by a non-exclusive clone list.
Keep `local-only` work in the main home.
Send in-scope work to the fitting secondmate unless it is blocked or the captain explicitly redirects it; do not read the secondmate's chat because marked routed replies return through its status or referenced document.
If no secondmate scope fits, use the main home or discuss creating an appropriate persistent secondmate.
For one-off or infrequent operational work, start with the simplest direct end-to-end path.
Do not build wrappers, control planes, policy layers, custom verifiers, or automation unless the direct path exposes a concrete blocker or repeated need that justifies the added machinery.

## Classify the deliverable

Before commissioning an investigation, consult existing reports and established evidence.

- **Ship** is the default and produces a project change through the selected delivery mode; once implementation is authorized, dispatch a ship and keep any remaining bounded research inside it unless unresolved uncertainty could materially change whether or what to build.
- **Scout** produces knowledge in `data/<id>/report.md`, never a PR, and is appropriate for investigation, diagnosis, planning, reproduction, or audit work when the captain explicitly requests a separate knowledge or design deliverable, unresolved uncertainty could materially change whether or what to build, or the standing direct-PR review in `ship-landing` applies.
- **Council** is a debate among 1-5 voices from different model providers that ends in a synthesis; when the captain invokes `/pal-council` or asks for a council of models or experts on a decision, load `pal-council`, which runs the voices as read-only scouts.

- If established evidence already answers an informational question, relay it without a design-only scout; when implementation intent is unclear, answer and ask one concise implementation question when useful rather than dispatching speculative design work.
- Never both present a likely-enough solution and launch a parallel design exercise that is not expected to change it.
- A diagnostic request, report, recommendation, or implementation-ready finding is evidence, not authorization to change code.
- Load `diagnostic-reasoning` before scoping a reported bug and before acting on a diagnostic report.

## Resolve delivery mode, yolo, and branches

Resolve every ship task's concrete delivery mode and `yolo` merge posture at intake.
Pass the mode explicitly to the brief, and pass both values explicitly to the spawn and any scout promotion; each command refuses to guess the values it consumes.
A current explicit captain instruction wins; otherwise the project's registry entry is the captain's standing posture, and dropping below its rigor needs a reason you can state.
Resolve the project's registered ship-branch prefix the same way, via `bin/fm-project-mode.sh --branch-prefix <project>`, and pass it explicitly to the brief, ship spawn, and scout promotion as `--branch-prefix` (default `fm/` needs no flag).
When the work must start from and target a branch other than the project's default, such as a named feature or release branch, pass it to the ship or scout brief and spawn as `--base-branch <branch>`; any promotion reads it from task meta.
For a ship task whose project is this firstmate repository, pass the project directory to the brief as `--project` and record any captain-approved one-task contribution consent as `--upstream-consent <host>/<owner>/<repo>` on the brief, spawn, and promotion; `bin/fm-spawn.sh` refuses a publishing contract this home's role does not authorize.
On a `no-mistakes-prod-only` project, classify the task's surface: internal-only tooling, automation, contributor or operator process, and release or submission work ships `direct-PR`, while product-facing, mixed, and uncertain work ships `no-mistakes`; never infer internal-only from file location or project name.
An unregistered project or absent registry resolves to `no-mistakes` with yolo off, and the registration gap goes to the captain.
Record the resulting mode, `yolo` merge posture, and the one-line reason for any deviation in the backlog item note.

## Resolve the dispatch profile

`docs/configuration.md` owns dispatch-profile and runtime-backend schemas, including a profile's optional opt-in per-turn advisor axis, `bin/fm-harness.sh` owns static resolution, and `bin/fm-spawn.sh` owns launch flags and validation.
When dispatch profiles exist, consult them at every crewmate or scout intake and pass the resolved concrete profile required by `fm-spawn`.
Routing precedence is an explicit per-task captain override, then the best-fit configured rule, then the configured default, then the static crewmate harness.
Preserve malformed profile configuration as an actionable error rather than selecting around it.
Firstmate alone resolves a matched profile array: when the matched rule or default is an array, load `quota-array-dispatch`; it owns every-candidate accounting, eligibility, reasoning-class, runway, and tie rules.
Run `bin/fm-dispatch-resolve.sh` directly on the written brief in the same turn, with no preflight, and on `clear` pass its `profile:` line to `fm-spawn` unless you state a reason to override; `ambiguous`, `escalate`, `error`, and off all mean the intake above, unchanged (contract: `docs/configuration.md` "Typed dispatch resolution").
`harness-adapters` owns the generic effort fallback and its precedence; do not add model-specific versions of that policy.

## Concurrency

Treat file or subsystem overlap as a risk signal rather than an automatic reason to wait, and dispatch isolated work immediately with no concurrency cap when each change can be independently implemented and validated and the selected delivery path can reconcile ordinary rebases or conflicts.
A project's declared machine capacity (`config/project-capacity`) still bounds that dispatch: a spawn beyond it exits 75 without launching, and its item stays queued rather than blocked.
Serialize only for a true semantic dependency, shared mutable external state, incompatible concurrent migration, or another concrete condition that makes independent progress or reconciliation unsafe; same-file editing alone is insufficient, and genuine blockers remain durable.

## Write the brief

`bin/fm-brief.sh` and its help own scaffold syntax, generated variants, status protocol, delivery-mode definitions of done, and exact safety mechanics.
Use its scaffold as the contract, then fill `## Captain's intent` (`{TASK}`) with the captain's own ask and any boundary the captain stated, plus the context needed to read it, including the substance of any report, decision, or PR the ask refers to; never widen the ask there into a general goal or an enumerated coverage list, because the reviewer treats that subsection as acceptance criteria.
Fill `## Firstmate spec` (`{FIRSTMATE_SPEC}`) with only the build instructions that ask requires, naming what stays out of scope when the ask is narrow; a generalization, consistency sweep, or extra hardening the captain did not ask for is follow-up work to note, not scope to add.
`bin/fm-dod-lib.sh` owns intent authoring without added speaker labels or direct address, its provenance markers, what a no-mistakes worker may pass as `--intent`, and the string's self-sufficiency rule.
Fill the scaffold's recall placeholders with what you consulted before fixing the task's shape and what that changed, where nothing is a valid answer.
Keep additions task-specific rather than repeating lifecycle instructions, and alter generated sections only when the task genuinely differs from the standard shape.
Never write task text that tells the worker to ignore a scaffold section; scaffold a blind review with `--blind`, and follow the task-text conventions in the script's help.
If a ship task touches firstmate's shared tracked material, explicitly require `firstmate-coding-guidelines` before editing.
If a task will drive Herdr lifecycle behavior, scaffold with `--herdr-lab`; if that need appears after an unguarded scaffold, stop and regenerate rather than adding commands by hand.
The generated Herdr contract must use a named non-`default` isolated lab and its guarded helper for every lifecycle action.
Load `secondmate-provisioning` before creating or using a charter brief and preserve its idle-by-default and marked-return-channel contracts.

## Spawn and confirm

When the configured tasks-axi backlog gate applies, the spawn itself moves the work item to In flight and refuses rather than dispatching work this home has no item for, so recording the dispatch is never a separate step to remember; a manual-backend home retains the hand-editing contract in `docs/configuration.md`.
After spawning, confirm the worker is processing the brief and handle any trust dialog through `harness-adapters`.
A persistent secondmate is recorded in the secondmate registry and runtime state, never as a backlog work item.
Then hand the task to supervision under `AGENTS.md` section 8, and load `validation-supervision` when it is a no-mistakes ship.
