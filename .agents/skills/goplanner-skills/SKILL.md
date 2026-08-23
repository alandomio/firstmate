---
name: goplanner-skills
description: Pointer inventory of project-specific skills that exist in the GOPlanner repo (projects/GOPlanner). Load before starting work on GOPlanner to check whether an existing project skill already covers the task instead of re-deriving domain knowledge from scratch.
---

# GOPlanner project skills

This is a thin pointer, not a copy of any listed skill's own instructions.
Each skill's own `SKILL.md` remains the one owner of its content; read it directly when it applies.
Re-verify this inventory by hand next time it looks stale - firstmate does not auto-refresh it.

## Branch caveat

GOPlanner's own git default branch is `master`, and `master` is nearly bare of skills.
Almost every skill below lives only on the `php8` branch, which is where active chatbot-service and ticket-flow work actually happens (see GOP-189/GOP-190 precedent: base worktrees off `php8`, not `master`, for that kind of work).
Skills marked "both branches" below are the exception.

## `.agents/skills/` (agent-only)

- `chatbot-tuning` (php8 only) - simulates, judges, and cures chatbot behavioral regressions without auto-ingesting evidence (ADR-28).
- `cloudwatch-log-investigator` (php8 only) - investigates GOPlanner incidents/regressions via AWS CloudWatch logs across web and mobile channels, tenant-aware.
- `create-new-tenant` (both branches) - creates and configures a new GOPlannerWeb tenant end-to-end (DB, custom folder, config, mappings, admin user).
- `goplanner-browser-mcp-tests` (php8 only) - validates GOPlanner's web UI with Chrome DevTools MCP (login, tenant switch, navigation, XHR/console checks, smoke tests).
- `goplanner-docs` (both branches) - workspace-local knowledge router for the `docs/` tree; also see this project's own mandated session-start protocol in its `AGENTS.md`.
- `goplanner-e2e-test` (php8 only) - full field-service E2E cycle: back-office provisioning, mobile app download/close-out, sync, server-side verification; combines this repo with `goplanner-android`.
- `goplanner-headless-tests` (php8 only) - headless (no-browser) login, tenant switch, DB seeding, and API smoke tests; complements `goplanner-browser-mcp-tests`.
- `grill-with-docs` (php8 only) - adversarial "grilling" session that stress-tests an implementation plan against the domain model and updates docs as decisions settle.
- `implement-ticket` (php8 only) - the Jira ticket-implementation orchestrator used for GOP-189/GOP-190; drives a GOP-xxx ticket end-to-end, task or epic, with agentmemory-backed context.
- `skill-creator` (php8 only) - meta-skill for creating, editing, and benchmarking other skills.

## `.claude/skills/` (Claude-harness only, not mirrored under `.agents/skills/`)

Present on `php8` only:

- `debug-issue` - systematic debugging via graph-powered code navigation.
- `explore-codebase` - codebase navigation/understanding via the knowledge graph.
- `refactor-safely` - plans and executes safe refactoring using dependency analysis.
- `review-changes` - structured code review using change detection and impact analysis.

These four are only reachable by a Claude-harness worker; a non-Claude worker on `php8` will not see them.
