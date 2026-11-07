---
name: backlog-management
description: Agent-only procedure for keeping the durable backlog current. Load before filing or editing a backlog work item or its note, before holding one for the captain, and when re-evaluating queued work after a cleanup, heartbeat, or PR-ready handoff.
user-invocable: false
metadata:
  internal: true
---

# Backlog management

`AGENTS.md` section 10 keeps the always-loaded backlog boundaries; this skill owns the upkeep procedure.
`.tasks.toml`, `docs/configuration.md`, and current `tasks-axi --help` own the backlog schema, compatibility, retention, and routine command syntax.

## Filing and holding

Use compatible `tasks-axi` when the configured backend selects it, always through `bin/fm-tasks-axi.sh` so the call reaches this home's backlog from any directory, and the documented manual path otherwise; keep only the configured recent Done entries.
A decision is simply a task held for the captain: create the task with `bin/fm-tasks-axi.sh add` when needed, then always hold it through `bin/fm-captain-hold.sh hold <id> --reason "<reason>"`, with `--until <date>` when the captain defers it; the reason is the decision card `captain-hold-lifecycle` owns.
When a main-side thread such as a pending captain decision or relay reminder is worth durable tracking, file it as its own work item and hold it through that wrapper.
Captain calls discovered by investigations or visual reviews follow `captain-hold-lifecycle`, which owns their completion gate and recorded-answer rules.
When the automatic transition gate applies, dispatch and completion move the item themselves - `bin/fm-spawn.sh` and `bin/fm-teardown.sh` own those transitions and refuse rather than report success without them - so what remains yours is filing the item before dispatch, recording decisions, and keeping notes current; `docs/configuration.md` owns gate applicability and the manual-backend exception.
`secondmate-provisioning` and `bin/fm-backlog-handoff.sh` own cross-home handoff safety.

## Re-evaluating queued work

Re-evaluate queued work after every teardown and heartbeat, and also after a recorded PR-ready handoff when `config/project-capacity` caps that project, dispatching items only when dependencies, time gates, and project capacity have cleared.

## Note hygiene

Keep free-form notes free of temporary paths, moving versions, ephemeral identifiers, and copied state that will rot.
Inspect the current task note before replacing its considered body, and archive the superseded body when recoverability matters rather than appending by default.
Verify volatile details against their authoritative config, live system, or API before acting, and correct or delete stale prose immediately.
Preserve durable structured identifiers, dependencies, and completion artifact links, and route reusable knowledge under `knowledge-routing` rather than scattering it through task notes.
