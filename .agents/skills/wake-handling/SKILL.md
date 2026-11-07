---
name: wake-handling
description: Agent-only procedure for handling fleet wakes. Load at the start of every wake-handling turn, before reading the wake drain's sections or acting on a signal, stale, check, or heartbeat wake.
user-invocable: false
metadata:
  internal: true
---

# Wake handling

This skill owns how firstmate reads the wake drain and handles each wake type.
`AGENTS.md` section 8 keeps the always-loaded supervision rules: one live cycle, drain before acting, acknowledge only after handling, and no turn ends blind.
`docs/architecture.md`, `docs/turnend-guard.md`, the emitted session-start block, and script help own the mechanisms.

## Read the drain

Session start is the only turn that skips the drain, because its one-shot digest already presented the queue while locked or deliberately left it untouched in lock-refused read-only mode.
Read the drain's whole output and never pipe it through `grep`, `cut`, `tail`, or `head`; shorten the output in the script, never in the command.

- Treat any `OPEN DECISIONS` section from the drain as actionable reconciliation input even when no wake record was queued.
- Treat any `UNREAD STATUS` section as newly surfaced status that must be read this turn; those lines are not re-printed after this presentation.
- Treat any `PENDING INBOX NOTES` section as captain notes still unhandled: act on each and acknowledge it with `bin/fm-inbox.sh drain --ack <id>`, or it is listed and re-announced again.
- Treat any `RECORD DIVERGENCE` section as a contradiction between two records of one captain call, never as proof the captain ruled; load `captain-hold-lifecycle` and reconcile it in whichever direction the evidence supports.
- After handling all emitted wakes and reconciling the OPEN DECISIONS and UNREAD STATUS sections, run the exact generation-bound `--ack-through` command printed as `WAKE_ACK_REQUIRED`; interruption before that acknowledgement deliberately leaves the work durable for idempotent re-handling.
- After any supervision-branch acknowledgement succeeds or reports that a sequence is already processed, never acknowledge that sequence again or retry the refusal.
- `bin/fm-classify-lib.sh` owns the distinction between declared `paused:` waits and `blocked:` events needing firstmate action; `bin/fm-brief.sh` owns worker declaration instructions.

## Handle each wake type

1. For `signal:`, read the listed event lines first, then reconcile current state only where action depends on it.
2. For `stale:`, inspect the recorded endpoint and load `stuck-crewmate-recovery` for a stopped, looping, confused, or unresponsive worker; a deep-inspection reason also requires current-state and validation-log inspection.
3. For `check:`, act on the named poll result, including merges, contribution signals, Relay events, process-to-event source results, and captain inbox notes; a handled inbox note is also acknowledged with `bin/fm-inbox.sh drain --ack <id>`, or it stays counted as still waiting for firstmate.
   A `check: secondmate <id> auto-relaunched` wake records a recovery that already completed - reconcile the mate's current state rather than relaunching again, and treat a repeat or a paused-bound wake as the signal to investigate why the mate keeps exiting.
   When the note needs a durable answer the submitter can read, publish it with `bin/fm-inbox.sh reply <id>` (the script header owns the reply contract) rather than leaving the answer only in this transcript.
4. For `heartbeat:`, review the whole fleet from the structured fleet view, reconcile suspicious tasks and PR state, update the backlog under `backlog-management`, and never report an unchanged fleet as progress.

## Wakes that belong to another owner

- Load `bearings` on a contributions check wake or when filing work linked to an upstream issue; its contribution-follow-up section owns triage and exact signal acknowledgement.
- When any wake reports a merged PR for a project cloned in this home, refresh that clone through the guarded fleet-sync path.
- When Relay-linked work reaches a milestone or terminal state, load `fmx-respond`; before terminal teardown, use its promised-final reconciliation when a typed public commitment exists, otherwise post the final completion follow-up so the link clears even if earlier follow-ups were spent.
- A wake from a council worker (task id `pal-<council>-<seat>`) or from a council's purge watch belongs to the `pal-council` moderation loop: load that skill before acting, and clean those workers up only through its cleanup.
- Load `process-event-sources` on any `procevent` check wake and on a stranded or failed process-event source wake.

## Quiet endpoints

A secondmate's idle endpoint is healthy, and parent supervision relies on its routed status rather than treating a quiet pane as stale.
Waiting on a healthy supervision cycle is silent; empty polls, elapsed time, and no-change updates are not captain-facing progress.
