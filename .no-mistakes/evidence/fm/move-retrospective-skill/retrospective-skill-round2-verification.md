# Round 2 evidence: retrospective skill loaded as /retrospective (target d91df1d + audience-inventory fix)

## 1. End-user surface: Claude Code started headless in this worktree with project skills only
Command: claude -p --model haiku --setting-sources project --tools Skill "...list skills in your context..."
afk, ahoy, ask-user-authority, aws-goplanner-skills, bearings, bootstrap-diagnostics, captain-hold-lifecycle, decision-hold-lifecycle, diagnostic-reasoning, firstmate-codexapp, firstmate-coding-guidelines, firstmate-orca, fmx-respond, goplanner-android-skills, goplanner-skills, harness-adapters, process-event-sources, project-management, quota-array-dispatch, retrospective, secondmate-provisioning, stow, stuck-crewmate-recovery, updatefirstmate, dataviz, update-config, keybindings-help, code-review, simplify, fewer-permission-prompts, loop, schedule, claude-api, workflow-authoring, run, init, security-review

Yes.

n/a

Control at base commit e8613e9 (same command, retrospective directory absent):
No.

## 2. .gitignore semantics verified with the real consumer (git)
# git check-ignore -v
.gitignore:14:.agents/skills/retrospective/reports/*	.agents/skills/retrospective/reports/2026-09-06-demo-abcd1234.md
ignored-exit=0
gitkeep-ignored-exit=1 (1 = tracked/not ignored)
# git status --porcelain
(git status --porcelain was empty after writing a report file into reports/)

## 3. Changed-file test selector (CONTRIBUTING workflow), bin/fm-test-run.sh --changed --base e8613e9
FM_TEST_SUMMARY total=32 failed=4 skipped_gate=2 duration_ms=488756
FM_TEST_SUMMARY_FAMILY family=pure-contract-unit count=32 duration_ms=486835 failed=4
Failing scripts and whether they also fail at the base commit:
fm-bearings-board at base exit=1
not ok - could not create the order-proof captain hold
fm-calm-pi-extension at base exit=1
not ok - Pi calm missing-adapter-export test printed output: (node:38490) ExperimentalWarning: Type Stripping is an experimental feature and might change at any time
fm-composer-lib at base exit=1
not ok - a half-block rule row must count as a structural edge
fm-documentation-audiences at base exit=1
not ok - repository documentation audience check failed
(fm-documentation-audiences at base in a real git checkout: base exit=0 -> its failure was introduced by this branch)

## 4. Regression introduced by the branch and fixed in this test round
Before: fm-doc-audience-check: unclassified: .agents/skills/retrospective/SKILL.md, .agents/skills/retrospective/reference.md
Fix: two agent-runtime entries added to docs/documentation-audiences.json
After:
$ bin/fm-doc-audience-check.sh
fm-doc-audience-check: ok surfaces=79 local_links=272
exit=0

$ bash tests/fm-documentation-audiences.test.sh
ok - documentation inventory classifies every maintained prose surface exactly once
ok - classification, setup routing, and maintained-prose scope fail safely
ok - required documentation owner pointers cannot silently disappear
ok - local links resolve while dates, versions, commands, and incident prose remain semantically reviewed
exit=0
