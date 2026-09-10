# Whole-brief diffs (base b82fc57 -> HEAD f2458b5)

Only the Grounding additions and the scout `note` state differ; Herdr section, worktree-isolation rule, {TASK} placeholder and Definition of done are untouched (remaining diff lines are the fixture home path).

## Ship brief
```diff
--- ./before/ship-brief.md	2026-09-10 09:50:33.393692741 +0200
+++ ./after/ship-brief.md	2026-09-10 09:50:33.066286635 +0200
@@ -4,8 +4,9 @@
 {TASK}
 
 # Grounding
-Before your first substantive action, search PP Brain (`search_knowledge` with both `query` and `prompt` populated - one alone kills two of six retrieval paths) and the local memory store for prior decisions, refuted approaches, and known traps on this subject.
+Before your first substantive action, search PP Brain (`search_knowledge` with both `query` and `prompt` populated - one alone kills two of six retrieval paths) and the local memory store for prior decisions, refuted approaches, and known traps on this subject; searching costs only latency, so search again whenever a new obstacle or subject comes up rather than treating this as one-shot.
 Treat the `# Task` section above as firstmate's assembly of that context, a starting point rather than a substitute.
+When you hit an obstacle, surprising behavior, or trap, check PP Brain before working around it - cite it if documented, or append `note: CANDIDATE - {finding}` if it is not; never write to PP Brain or any shared memory directly, only firstmate promotes candidates.
 Report what you found and what it changed in your next status line, or state plainly that both were silent.
 If the session-start banner reports `pp-brain: auth_missing`, or anything else suggests PP Brain is unauthenticated, treat that alone as a known false positive: make ONE real `search_knowledge` call before acting on it.
 Only a failing live call is evidence - never stop, and never proceed without org context, on the banner alone.
@@ -31,7 +32,7 @@
 2. Stay inside this worktree; modify nothing outside it.
 3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
 4. Report status by appending one line:
-   `echo "{state}: {one short line}" >> './before-home/state/ship-demo.status'`
+   `echo "{state}: {one short line}" >> './after-home/state/ship-demo.status'`
    States: working, note, needs-decision, blocked, paused, done, failed.
    Each append wakes firstmate, so report sparingly: only phase changes a supervisor
    would act on (setup done, bug reproduced, fix implemented, validation passed) and the
```

## Scout brief
```diff
--- ./before/scout-brief.md	2026-09-10 09:50:33.397802263 +0200
+++ ./after/scout-brief.md	2026-09-10 09:50:33.070316949 +0200
@@ -4,8 +4,9 @@
 {TASK}
 
 # Grounding
-Before your first substantive action, search PP Brain (`search_knowledge` with both `query` and `prompt` populated - one alone kills two of six retrieval paths) and the local memory store for prior decisions, refuted approaches, and known traps on this subject.
+Before your first substantive action, search PP Brain (`search_knowledge` with both `query` and `prompt` populated - one alone kills two of six retrieval paths) and the local memory store for prior decisions, refuted approaches, and known traps on this subject; searching costs only latency, so search again whenever a new obstacle or subject comes up rather than treating this as one-shot.
 Treat the `# Task` section above as firstmate's assembly of that context, a starting point rather than a substitute.
+When you hit an obstacle, surprising behavior, or trap, check PP Brain before working around it - cite it if documented, or append `note: CANDIDATE - {finding}` if it is not; never write to PP Brain or any shared memory directly, only firstmate promotes candidates.
 Report what you found and what it changed in your next status line, or state plainly that both were silent.
 
 # Herdr lifecycle declaration - NOT ENABLED
@@ -24,8 +25,8 @@
 2. Stay inside this worktree; the only files you may write outside it are the report and the status file below.
 3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
 4. Report status by appending one line:
-   `echo "{state}: {one short line}" >> './before-home/state/scout-demo.status'`
-   States: working, needs-decision, blocked, paused, done, failed.
+   `echo "{state}: {one short line}" >> './after-home/state/scout-demo.status'`
+   States: working, note, needs-decision, blocked, paused, done, failed.
    Each append wakes firstmate, so report sparingly: only phase changes a supervisor
    would act on and the needs-decision/blocked/paused/done/failed states. No step-by-step
    FYI progress lines; firstmate reads your pane for that.
@@ -47,7 +48,7 @@
    daemon error, append `blocked: {the daemon error}` and stop; only firstmate manages the daemon.
 
 # Definition of done
-Write your findings to `./before-home/data/scout-demo/report.md`.
+Write your findings to `./after-home/data/scout-demo/report.md`.
 The report must stand alone: what you did, what you found, the evidence (commands run, output, file:line references), and what you recommend.
 If your deliverable is a visual artifact the captain will review and iterate on, you may host the Lavish review loop yourself (poll, revise, re-serve, staying alive) instead of handing it back to firstmate.
 Before reporting done, read and follow `/Users/a.domio/.no-mistakes/worktrees/38493c8a7325/01M252PH9W9NP6X0NY769YTD4W/.agents/skills/captain-hold-lifecycle/SKILL.md` and pass its shared completion gate for the report and any visual review.
```

## Secondmate charter
```diff
--- ./before/secondmate-charter.md	2026-09-10 09:50:33.401642620 +0200
+++ ./after/secondmate-charter.md	2026-09-10 09:50:33.074406263 +0200
@@ -33,7 +33,7 @@
 # Escalation to main firstmate
 Handle routine work yourself.
 Report only true captain-relevant outcomes or a declared external wait by appending one line:
-   `echo "{state}: {one short line}" >> './before-home/state/second-demo.status'`
+   `echo "{state}: {one short line}" >> './after-home/state/second-demo.status'`
 States: working, needs-decision, blocked, paused, done, failed.
 Use `paused: {why}` (distinct from `blocked:`) only when your domain is deliberately idling on a known external wait you expect to clear on its own; use `blocked:` when you are stuck and need firstmate to act.
 Use this only for material phase changes, a captain decision, a real blocker, a failure, or work ready for review.
```
