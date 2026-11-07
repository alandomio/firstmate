---
name: captain-reporting
description: Agent-only reference for wording captain-facing messages. Load before the first captain-facing reply of a session, and before any reply that relays worker, tool, fleet, review, or validation state to the captain.
user-invocable: false
metadata:
  internal: true
---

# Captain reporting

`AGENTS.md` section 9 owns the duties: talk in outcomes, read before asserting, a standalone final message, the full PR URL, and no internal vocabulary in captain chat.
This skill owns the reference that carries those duties out: the internal-term rewrite table and the worked examples.

## Internal terms and their rewrites

Do not expose internal terms such as startup machinery, locks, watchers, polling, crewmates, task ids, briefs, worktrees, checkouts, status or metadata files, teardown, promotion, harness names, runtime backend names, context budgets, delivery-mode names, autonomy flags, wake types, status prefixes, decision holds, pipeline step names, validation-state labels, or compressed safety labels such as fail-closed, fails closed, fail-open, fails open, fail loudly, or close variants.
Scout and second mate are accepted Firstmate nautical house vocabulary and do not need translation when they naturally name that work or role.
Use the captain's nouns: the investigation, the scout, the fix, the PR, the review, the decision, the blocker, the credential, the local copy, the worker, or the project.
When evidence uses an internal label, rewrite it before sending:

- worktree, checkout, primary checkout, or local-main -> local copy, isolated copy, or local branch, only if the location matters.
- teardown -> cleanup.
- wake, watcher, heartbeat, stale, signal, or check -> notification, monitoring, waiting too long, or stopped responding.
- hold, gate, ask-user, needs-decision, blocked, or paused -> the concrete decision, wait, approval, blocker, or external delay.
- done, failed, fix-review, checks-passed, cancelled, validation step, or pipeline state -> the concrete result, review finding, passing checks, failed check, or stopped validation.
- brief -> instructions.
- crewmate -> worker, only when naming the helper matters.
- harness, backend, runtime, or adapter -> worker runtime or tool, only when the tool choice itself blocks work.
- status file, metadata, state, task id, or raw path -> durable record, local record, or omit it unless the captain needs the file path to act.
- fail-closed, fails closed, fail loudly, or refuses loudly -> stops safely when something goes wrong, refuses rather than proceeding, or reports the concrete missing requirement.
- fail-open, fails open, passive fail-open, or degraded-open -> steps aside and lets work continue when the check cannot complete, or continues without that optional protection.

Private evidence reports may retain exact identifiers, paths, status lines, validation labels, and internal terms when they are useful, but the captain-facing chat summary that points to the report still follows this translation rule.

## The final message

The final-message rule is a visibility recap: it may list all outstanding decisions and their URLs, but it does not override, replace, or combine any separate per-decision ask messages required by a harness's no-batching rule.
Protocol regression example: reporting a completed fix and its recorded PR URL mid-turn, then using tools and ending with only `Awaiting your merge call.`, is incomplete; the final message must name the completed fix, include that same full PR URL, and ask whether to merge.

## Choosing the surface

Use plain chat for a yes-or-no decision and `lavish-axi` only when several options or a structured report benefit from a visual surface.
Batch non-urgent updates into the next natural reply.
Mention cost as a courtesy when unusually much work is running, but never block on it.
