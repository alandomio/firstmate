---
name: goplanner-android-skills
description: Pointer inventory of project-specific skills that exist in the goplanner-android repo (projects/goplanner-android). Load before starting work on goplanner-android to check whether an existing project skill already covers the task instead of re-deriving domain knowledge from scratch.
---

# goplanner-android project skills

This is a thin pointer, not a copy of any listed skill's own instructions.
Re-verify this inventory by hand next time it looks stale - firstmate does not auto-refresh it.

## Odd default branch

This repo's remote default branch is unusually set to a feature branch, `GOPLANNER-1204-gestione-timbrature`, not `main` or `master` - there is no `main`/`master` branch at all in this clone.
Confirm the current default before assuming it, since a feature branch as default is fragile fleet knowledge that can change.

## Current skills

The default branch (`GOPLANNER-1204-gestione-timbrature`) has no `.claude/skills/` or `.agents/skills/` directory.

Two other remote branches, `origin/gestione-avvisi` and `origin/magazzino-fix`, each carry the same six skills under `.agents/skills/`:

- `cloudwatch-log-investigator` - investigates GOPlanner incidents/regressions via AWS CloudWatch logs across web and mobile channels, tenant-aware (same skill as GOPlanner's `php8` copy; see `[[goplanner-skills]]`).
- `crash-investigation` - investigates Android ACRA crash reports in CloudWatch for a specific app version, verifies root cause against source, suggests fixes, persists findings to the LLM wiki/RAG store.
- `goplanner-browser-mcp-tests` - validates GOPlanner's web UI with Chrome DevTools MCP: login, tenant switch, navigation, XHR/console checks, smoke tests.
- `grill-with-docs` - adversarial "grilling" session that stress-tests an implementation plan against the domain model and updates docs as decisions settle.
- `handoff` - compacts the current conversation into a handoff document for another agent to pick up.
- `skill-creator` - meta-skill for creating, editing, and benchmarking other skills.

No skill is reachable from the current default branch without checking out one of those two branches.
