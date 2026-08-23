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

Two other remote branches do carry one skill each:

- `origin/gestione-avvisi` and `origin/magazzino-fix` both have `.agents/skills/cloudwatch-log-investigator` - investigates GOPlanner incidents/regressions via AWS CloudWatch logs across web and mobile channels, tenant-aware (same skill as GOPlanner's `php8` copy; see `[[goplanner-skills]]`).

No skill is reachable from the current default branch without checking out one of those two branches.
