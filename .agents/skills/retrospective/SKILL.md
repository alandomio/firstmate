---
name: retrospective
description: Analyzes the active session for failure receipts, captain corrections, repeated work and shared-instruction gaps, turns them into agentmemory lessons, feedback memory, scripts and CLAUDE.md proposals, and writes a dated retrospective report. Invoke when the user asks for a retrospective, when a session that produced a captain correction or a failure receipt is ending, or when a supervising agent needs to close out its own session's learnings.
user-invocable: true
metadata:
  internal: true
---

# Session Retrospective Protocol

Extracts what this session learned that nothing else captures, routes each learning to the substrate whose reach matches it, and writes a dated report, so no session re-derives what an earlier one learned ("NPC Mode").

Durable knowledge reaches the org store through the daily memory-board pass, so this skill never drafts, batches or writes org-store items; it only notes in its report any knowledge it saw that the board should pick up.
Run the steps in order. Step 0 decides how many of them apply.

## Who invoked this, and what that changes

This skill runs three ways, and the difference matters only at the approval gates.

- **A human is present** (the user typed `/retrospective`, or a supervising session closing out its own work). Everything below applies unchanged.
- **No human reachable** — a subagent, a scheduled run, an autonomous loop, the compaction hook. Every gated write is **skipped, not assumed**.

With no human reachable, and only then:

- Skip the Step 2 substantive questions and say in the report that they were not asked. Do not invent the answers you would have got.
- The **auto-detector alone** chooses full vs short. A missing answer never counts as "routine".
- `CLAUDE.md` / `AGENTS.md` edits, ADRs and `feedback`/`user` memory files are **not written**. Draft each one verbatim into section 4 as pending, with the approver named. An absent human is a withheld answer, never an implied yes.
- Ungated writes still happen: the report, agentmemory lessons and memories, and `project` / `reference` memory creations.
- Never open a review surface, post to a channel, or message anyone to obtain the approval. Leave it pending and let the invoking session carry it to its human.

If you cannot tell which case you are in, assume the second.

## Step 0 — Cheap evidence scan, then triage

Run the free part of Step 2 FIRST — `git status --short`, `git diff --stat`, `git log --oneline <base>..HEAD`, and a transcript scan for errors and corrections — then decide.

**Triage is deterministic**, decided from that evidence, and its bar depends on who invoked the run.

- **A human is present**: take the **full** path if ANY of these is observably true: a captain correction or failure receipt exists (a command that errored, an assumption corrected); a decision was made that a future session would need explained; the diff touches >=3 files, or the branch carries >=1 commit.
- **No human reachable** (the compaction hook and every other unattended run): take the **full** path only if the session shows at least one **captain correction** or one **failure receipt**.

Otherwise take the **short** path: Step 1 recall, one `memory_lesson_save`, a **short dated report** (sections 1, 4 and 5 only; section 4 records the lesson id and carries forward the prior report's pending drafts), and a short chat summary. No `CLAUDE.md` proposal, no ADR.

**Flags override the detector**: `/retrospective --full` or `/retrospective --quick` (the short path).

**The short path is not silent, and it never claims an unverified write.** State what is skipped and quote the identifier you got back: *"Short retrospective — lesson `lsn_…` saved. Say `--full` for the write-up."* If the save returned no id, say the save failed. If a correction or failure receipt turns up after the short path was chosen, **stop and escalate**: *"This has a failure worth recording — switch to full, or confirm short?"* With no human reachable, do not ask: switch to full, leaving its gated writes pending. Never downgrade silently.

## Resolve the org store first

The org store is whichever knowledge store this home is configured with, because the same skill runs on machines with different MCP servers installed; this skill only recalls from it.
Before Step 1, run `bin/fm-knowledge-store.sh read` from the Firstmate code root (three directories above this skill, the directory that contains `.agents/`), with `FM_HOME` as the session has it.
It prints `name=`, `backend=` and `search=`; that script and `docs/configuration.md` "Knowledge store naming" own the setting, its default, and the refusals.
Everywhere below, "the org store" means the store it names: call it by `name` in chat and in the report, and take its recall verbs from `reference.md` for that `backend`; for `backend=other`, recall through the `search=` instructions.
If the command is missing or refuses, the org store is unreachable - skip its recall, say so in the report and quote the refusal.
Never call another backend's tools to compensate; they are not installed where they were not configured.

## Step 1 — Pre-flight recall (before drafting anything)

Query what is already known first, so learnings *reinforce* rather than duplicate, and so recurrence becomes visible. "Third time this migration lock bit us" is a far stronger finding than "this failed today".

- `memory_recall(query, format: 'compact')` — past session observations on the same files/concepts.
- `memory_lesson_recall(query, minConfidence: 0.1)` — lessons already learned. A hit means **re-save the identical content** (duplicates auto-strengthen confidence) rather than writing a near-duplicate variant.
- `memory_patterns(project)` — recurring cross-session patterns; this is what turns "it happened" into "it keeps happening".
- The org store's recall verb for its `backend` (`reference.md`). Company conventions here supersede in-repo docs, so a hit often means "follow the existing convention", not "add a new `CLAUDE.md` rule". A hit that already covers a learning means cite it instead of re-recording it.
- **The most recent prior report** for the target repo (path in Step 6) — the newest dated report only. If there is none, say "no prior report". Carry forward its unchecked Next Steps and its pending `CLAUDE.md`/feedback drafts that are still unwritten.

Record whether recall changed anything; the kill criterion below measures it.

## Step 2 — Collect session evidence

- **Git**: `git status --short`, `git diff --stat`, `git log --oneline <base>..HEAD` against the main branch (`dev` or `main`). Not just the working tree — a session that committed as it went shows an empty diff.
- **Transcript**: commands run, errors hit, how they were resolved.
- **Build/tests**: run the repo's own commands (read `CLAUDE.md` / `package.json` / `Makefile`). Never invent one. If nothing was run, that is "not run" — see Guardrails.
  Also note the repo's guardrails: a repo with no hook or CI job running its own lint, typecheck or tests is itself a finding, and so is an existing check that nothing runs. Read its check command first, so an unwired check is reported as unwired rather than as missing.
- **The substantive questions**: now ask the user **1 or 2** targeted questions, and only what the diff cannot answer — their goal, their satisfaction, a judgment call you cannot infer.

## Step 3 — Extract learnings with failure receipts

- Save the **exact** failing command or compiler error alongside its resolution. Abstract advice ages badly; concrete receipts do not.
- Mark each learning **new** or **recurring** against Step 1. Recurring earns a `CLAUDE.md` rule and a confidence bump; new usually earns just a lesson.
- **Information access** is its own category: places the session lacked a source it needed (read-only service access, logs, metrics) or was blocked from one. Record each with the receipt, e.g. an auto-mode production-read block, or a metric the monitoring tool does not carry. The fix is usually access, not a rule.
- A retrospective with no failures recorded is almost always incomplete. Look harder before concluding there were none.

## Step 3b — Repetition audit: what did this session pay for twice?

Steps 1–3 ask *what went wrong*; this asks *what was needlessly expensive?* Scan the transcript for **shape repetition**, not topic repetition, and **count it, do not estimate**:

- The same command or API sequence run **3+ times** with only an argument changing.
- A multi-step derivation repeated to answer the *same kind* of question.
- Output read by hand where the interpretation followed a fixed rule, or a fact re-derived that a command could print.

Promote a repetition to a script only when all three hold, because a wrong script is trusted and so worse than a slow manual check:

1. **Repeated at least three times**, or once but certain to recur every session.
2. **Mechanically decidable** — a fixed rule with no judgment in it. *Never script judgment.*
3. **A wrong answer would be visible**, not silent; otherwise the script must encode the check that catches it.

The payoff is usually correctness, not tokens: hand repetition varies, and the variance is where errors live. Receipt (2026-09-03): hand-rolled `glab api … | jq` reported four merge requests green that were not, because `head_pipeline` is often a merge-result run, not the real head. A small `mrstat` script replaced it and always reports whether a run existed against the real head.

### Route it

A promoted repetition is an **Axis A** artifact in Step 4: an executable on `PATH` (cross-project), a repo script (layout-dependent), or a `.claude/skills/` procedure where the repetition is a *sequence of judgments*. Record each **rejected** candidate and why in one line, so the next session does not re-propose it.

## Step 4 — Route each learning

Two independent axes. Do not conflate them — they share a shape and mean different things.

**Axis A — in-repo artifacts** (versioned, reviewable):

| Substrate | Route here when |
|---|---|
| `CLAUDE.md` | a stable rule every session in this repo needs. Keep it lean; link sub-docs rather than inlining |
| `.claude/skills/` | a repeatable procedure emerged |
| `docs/`, or `llm/kb/` where present | a detail looked up occasionally — reference material, schemas, concept cards |
| an ADR | a fork in the road with alternatives rejected. Hand off to the `adr-draft` skill rather than hand-rolling |

Fits nowhere -> session trivia. Leave it in the report only.

**Before a learning becomes a `CLAUDE.md` / `AGENTS.md` rule, classify it:**

- **Mechanical** (a fixed syntactic pattern, banned API, import shape, file-location rule) -> a lint rule, pre-commit hook or CI job, routed as an Axis A artifact. Prose is the wrong enforcement.
- **Review-time** (a check that matters only when a change is judged) -> give it to the reviewer (review standards, a review skill) rather than the always-loaded file, which every session pays for.
- **Judgement call every session needs** -> only then a written rule.

**No-ops audit.** Scan the always-loaded steering files this session touched for instructions that did not change behaviour (no receipt, already enforced by a check, or only relevant in a nameable situation). Propose deleting them, or moving them to a skill, doc or review standard. Prefer pruning to adding.
This audit and any pruning go through the same show-diff-then-wait gate as every other `CLAUDE.md` edit in Step 5, and are left pending on the unattended path.
Classification, no-ops audit and information-access ideas adapted from Matt Pocock's `/retro`.

**Axis B — persistent memory**, routed by **blast radius**:

| Layer | Scope | Route here when |
|---|---|---|
| harness auto-memory | this workstation, this project | it must load into context at every session start |
| agentmemory | this workstation, cross-project | it is true of *how you work here* — local env, tooling, personal workflow |

Org-store publication is not a route: the daily memory-board pass moves agentmemory's consolidated memories there, so agentmemory always keeps the raw record (lesson save, with concepts and files) and is the source the board reads.
Route a **captain correction** by what it corrects:

- How firstmate itself behaves -> the always-loaded memory (harness auto-memory, or `data/captain.md` in a firstmate home), show-first gate unchanged, because agentmemory and the org store are searched, not loaded every session.
- The domain, or how workers must do things on a project (customer rules, procedures) -> the org store via the board, so workers and the chatbot follow it too: save it to agentmemory as a lesson or memory, which is what the board reads, then note it and its identifier in the report's "For the memory board" line.

Note in the report any other knowledge you saw that the board should pick up (a stale or contradicted org item, a convention worth promoting) and stop there.

**Firstmate-home override for harness auto-memory.** When the repo this session modified (Step 6) is a firstmate home — `$FM_HOME` if set, else the Firstmate code root, call it `home_root`, and it qualifies only if `home_root/.agents/skills/stow/SKILL.md` exists — a "harness auto-memory" finding does not go to the generic `~/.claude/projects/<slug>/memory/` path. It goes to that home's own `stow`-tiered memory instead, so the next `/stow` pass finds it already shaped rather than unmarked and paying a grace cycle. Mechanics in `reference.md`; tier semantics and marker spellings stay owned by the `stow` skill and are never restated here. This override applies only to the destination and stamping of a harness-auto-memory finding.

## Step 5 — Execute the writes

**Nothing is claimed that was not written.** Draft section 4 *after* the writes return, and record the identifier each gave back (file path, lesson id, permalink). No identifier, no claim. A write that is declined, skipped or fails says so in section 4, and a routed artifact that was not written is **pending**, not done.

**Axis A artifacts are code changes** and follow the same discipline as any other edit. `CLAUDE.md`: show the diff, wait for an answer, then apply — amend an existing rule rather than appending a near-duplicate, link to the org store if it already documents the convention, and never write a rule into a repo this session did not touch. For `.claude/skills/`, `docs/`, `llm/kb/` and ADRs, each has its own contribution convention — see `reference.md`; hand ADRs to `adr-draft`.

**The approval gates. These are this skill's safety boundary; everything else in Step 5 is mechanics.**

- **Show before writing** any `feedback` or `user` memory file — those change how future sessions behave, and a wrong one bends your working style invisibly for months. Inside a firstmate home this maps to `data/captain.md`: same gate, same reason. Never write `data/captain-shared.md` from this skill — it is primary-owned; route a shared-preference finding to the primary the way `stow` does.
- **Show a diff before any overwrite** of an existing memory file, whatever its type.
- `project` and `reference` creations proceed automatically and are reported after.

**Two judgment calls.** *Blast radius* picks the layer via the Step 4 table. *Confidence* on a lesson: **0.5** single observation, **0.7** reproduced twice or user-confirmed, **0.8+** only with a failing-to-passing test; do not inflate, because confidence decays unused and an over-confident wrong lesson outranks a correct cautious one.

**Trap that has bitten.** Never call `submit_session_intel` — despite the name it is plugin telemetry, not a retrospective sink.

Signatures, required fields, paths and frontmatter live in `reference.md`, deliberately not here.

If a layer is unreachable, **still write the report**, mark the layer, and list the intended writes verbatim as pending.

## Step 6 — Write the report

**The report is the one unconditional output of this skill.** It is written on every path — full, short, and runs aborted part-way through an approval prompt. A run that wrote nothing durable still writes a report saying exactly that, with the intended writes listed verbatim as pending. There is no path through this skill that leaves no trace.

Path: `<repo>/.claude/skills/retrospective/reports/YYYY-MM-DD-brief-description-SESSION_ID.md`

- `<repo>` is the repo the session **modified**, derived from the Step 2 diff — *not* `cwd`. A session run from one repo often changes files elsewhere.
  Inside a firstmate home this resolves through the `.claude/skills` -> `.agents/skills` symlink, so no override is needed there.
- Changes outside any git repo (`~/.claude`, dotfiles, scratch) -> `~/.claude/skills/retrospective/reports/`, and say so, **unless** the session is running inside a firstmate home (`$FM_HOME` if set, else the Firstmate code root; it qualifies only if that root's `.agents/skills/stow/SKILL.md` exists) — there, write instead to that home's own `.agents/skills/retrospective/reports/`, keeping the report with the fleet it concerns rather than in the generic personal store. Dropping a personal report into an unrelated product repo pollutes someone else's diff, and `.claude/` is not gitignored everywhere.
- Several repos -> the one carrying the primary deliverable, cross-referenced in section 1.
- `mkdir -p` first. `SESSION_ID` is the session UUID truncated to 8 characters (it is the scratchpad path's directory segment), else `HHMM`.

Use the template below.

## Step 7 — Close the loop

In chat: the report path, Axis A artifacts changed, Axis B writes with identifiers, drafts still pending and who must approve them, and the Next Steps.

## Report template

````markdown
# Session Retrospective: [Description]

- **Date**: YYYY-MM-DD
- **Timeframe/Commit Range**: [branch, commit range, or hours]
- **Session ID**: [8 chars]

## 1. Executive Summary
[2-3 sentences: what was accomplished and why this approach.]

## 2. Technical Decisions & ADRs
- **Decision**: [the choice]
  - **Why**: [engineering rationale]
  - **Files Affected**: [paths]

## 3. Failure Directory (The "Mop" Sheet)
- **Symptom/Error Log**:

  ```text
  [exact console error or failing command]
  ```

  - **Root Cause**: [the precise mismatch]
  - **Resolution**: [what fixed it]
  - **Status**: [new | recurring — cite the prior lesson/session if recurring]

## 4. Knowledge Distribution
*Written after the writes returned. Identifier or it did not happen.*

**Axis A** — CLAUDE.md: [rule, or No + why] · Skills: [paths] · Docs: [paths] · ADRs: [path or "offered, declined"]

**Axis B** — Harness auto-memory: [files + shown-first confirmations, or none] · agentmemory: [ids with confidence] · Pending drafts: [verbatim, approver named, or none] · For the memory board: [knowledge seen that the board should pick up, or none]

## 5. Recall Effectiveness (kill-criterion ledger)
- **Did Step 1 change the output?** [yes — how | no]

## 6. Next Steps
- [ ] Specific, concrete, unblocked actions
````

## Guardrails

- **Never** commit or push unless asked. Writing the report and updating memory is the deliverable; version control is the user's call.
- The Step 5 approval gates are absolute; nothing here relaxes them.
- Do not fabricate error logs, test results, commit ranges, memory writes, or an identifier a write did not return. If the build was never run, write "not run" — an invented green checkmark poisons every future session that reads the report.
- Keep it specific: lessons are recalled out of context months later.
- Keep committed reports free of employee or HR data, named personal data and raw plates (use the `plateId`); raw log output stays in the local report.

### Anti-rationalization

| The excuse | The rebuttal |
|---|---|
| "Nothing really failed — this was straightforward." | Check the transcript for retried commands, corrected assumptions, and user corrections. A session containing a user correction is a high-value retrospective, not a quiet one. |
| "This lesson is obviously right — 0.9." | Confidence decays when unused and strengthens on reinforcement. An inflated wrong lesson outranks a correct cautious one. 0.5 unless reproduced or confirmed. |
| "Short path is fine, it was a small session." | A session with a correction or failure receipt takes the full path by rule. Check the transcript before choosing short. |
| "This is a `project` fact, not `feedback` — no need to show it." | If the content tells a future session how to behave — "always", "prefer", "never", "ask before" — it is `feedback` whatever the frontmatter says, and it gets shown first. Type is decided by what the text does, not by which label avoids the prompt. |

## Kill criterion (registered 2026-08-19; redesigned 2026-09-03 — do not silently drop)

**What is measured.** Across the next **10 qualifying runs**, Step 1 recall must change *the work*, not the write-up, in **>= 4**. A qualifying change is: a command not run because recall said it fails; an approach chosen or abandoned on a recalled decision; a failure marked recurring and promoted to a rule; or an existing convention followed instead of a new one invented. **A lesson re-saved to strengthen it does NOT count** — this skill mandates that on every hit, so counting it would make the test self-fulfilling.

**Cold starts are excluded:** a run where the store held nothing relevant is recorded `n/a` and does not consume one of the ten.

**If it fails that bar, Axis B is overhead.** Strip this skill to one lesson write plus the report, and leave the routing in `reference.md` only.

**The graded party does not keep the scoreboard.** Append each run to `reports/KILL-CRITERION.md`, one row, never rewriting an earlier one, and **quote the actual recall output** that did or did not change the run — a verdict with no quoted evidence is a claim, not a verdict. The agent records evidence and a provisional read; **the verdict belongs to the human.**

**Why redesigned, not deleted.** A 2026-09-03 critique (`~/firstmate/data/retro-critique-notebooklm/report.md`) rightly found no cold-start exclusion and a self-fulfilling success condition; both are fixed above. Deleting the test would have removed accountability, and the agent proposing that is the graded party.
