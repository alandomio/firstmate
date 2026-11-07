---
name: knowledge-routing
description: Agent-only map of where each kind of durable knowledge belongs. Load before routing a worker's `note: CANDIDATE` line, before writing a fact into any knowledge store or captain-preference file, and when firstmate works around an error or trap.
user-invocable: false
metadata:
  internal: true
---

# Knowledge routing

This skill is the single owner of knowledge destinations.
`AGENTS.md` section 6 keeps the always-loaded boundaries: firstmate never writes a project's `AGENTS.md`, crewmates only correct it, and crewmates never write a shared knowledge store themselves.

## Destinations

Route durable knowledge to its most specific owner:

- A home may declare authoritative external memory tiers in a `Memory layering` section of its captain-preference files ([`docs/configuration.md`](../../../docs/configuration.md) owns the schema); each declared tier owns the knowledge classes it names, this home's `data/` is then only a per-machine cache for those classes, capture to the tier is never skipped because a local file also received the fact, and a correction follows the tier's declared rule rather than an in-place edit.
- When a worker's harness cannot reach a declared tier, firstmate captures on the worker's behalf from its report.
- Home-domain captain preferences and working style belong in `data/captain.md` after inspect-then-update.
- Captain preferences shared across secondmate domains belong in the primary home's `data/captain-shared.md` under the `secondmate-provisioning` contract.
- Fleet-local operational facts no declared tier owns belong in curated, home-local `data/learnings.md`.
- Task-scoped notes belong with the backlog item, and investigation findings belong in the scout report.
- Knowledge useful to almost every contributor to one project belongs in that project's committed `AGENTS.md`, which only deliberate human edits extend.
- Knowledge general to every firstmate user belongs in this repo's shared tracked surface, which a user/operator home can only reach through an authorized contribution - otherwise it stays in `data/learnings.md` or a local draft for the captain.

## Worker candidates

A ship or scout brief has the worker raise each durable finding as a `note: CANDIDATE - {finding}` status line; routing that candidate to its owner above is firstmate's work, on the single drain that presents it.
A worker also raises each worked-around error as a `note: CANDIDATE - prevenzione: ...` when it cannot prevent the repeat itself; route that to the change it names or to a follow-up work item.
When firstmate itself works around an error or trap, it likewise fixes the cause, adds a clear error or check, or opens that follow-up, never only the workaround.

## Project memory corrections

A crewmate's correction to a project's `AGENTS.md` or `CLAUDE.md` edits only the wrong text and never runs `bin/fm-ensure-agents-md.sh`, a manual project-initialization utility whose inserted sections and created pointer are themselves additions.
Keep fleet delivery posture and captain-private strategy out of project memory.
