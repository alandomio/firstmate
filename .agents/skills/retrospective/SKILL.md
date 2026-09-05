---
name: retrospective
description: Performs comprehensive analysis of the active session, examines git logs, updates codebase guidelines (CLAUDE.md), persists lessons to agentmemory and PP Brain, and writes a detailed retrospective report. Invoke when the user asks for a retrospective, when a session that produced durable learnings or a failure receipt is ending, or when a supervising agent needs to close out its own session's learnings.
user-invocable: true
metadata:
  internal: true
---

# Session Retrospective Protocol

Extracts what this session learned, routes each learning to the substrate whose reach matches it, and writes a dated report. The point is to stop "NPC Mode" — the failure where every session re-derives what a previous session already learned.

Run the steps in order. Step 0 decides how many of them apply.

## Who invoked this, and what that changes

This skill runs three ways, and the difference matters only at the approval gates.

- **User typed `/retrospective`** — a human is present. Everything below applies unchanged.
- **An agent invoked it while a human is in the conversation** (a supervising session closing out
  its own work). Same as above: ask the questions, wait for the answers.
- **An agent invoked it with no human reachable** — a subagent, a scheduled run, an autonomous
  loop. There is nobody to answer, so every gated write is **skipped, not assumed**.

In that third case, and only in it:

- Skip the Step 2 substantive questions. Say in the report that they were not asked and why. Do
  not invent the answers you would have got.
- The **auto-detector alone** chooses full vs quick. A missing answer never counts as "routine".
- `CLAUDE.md` / `AGENTS.md` edits, ADRs, PP Brain writes, and `feedback`/`user` memory files are
  **not written**. Draft each one verbatim into section 4 as pending, with the approver named.
  These gates exist because the write changes behaviour or reaches the whole org; an absent human
  is a withheld answer, never an implied yes.
- Ungated writes still happen: the report, agentmemory lessons and memories, and `project` /
  `reference` memory creations, which are auto-create by design.
- Never open a review surface, post to a channel, or message anyone to obtain the approval. Leave
  it pending and let the invoking session carry it to its human.

If you cannot tell which case you are in, assume the third. The cost of a wrongly-skipped write is
one pending line in a report; the cost of a wrongly-assumed approval is an unreviewed rule in a
shared repo or an unapproved publication to the org.

## Step 0 — Cheap evidence scan, then triage

Depth cannot be chosen before the evidence that decides it exists. So run the free part of Step 2 FIRST — `git status --short`, `git diff --stat`, `git log --oneline <base>..HEAD`, and a scan of the transcript for errors and corrections — then decide. This costs a handful of read-only calls on any path.


**Triage is deterministic — there is no question to ask.** It is decided from the evidence
above, because a judgment made at the end of a long session is worse than the diff. Take the
**full** path if ANY of these is observably true:

- a failure receipt exists — a command that errored, an assumption corrected, a user correction;
- a decision was made that a future session would need explained;
- the diff touches >=3 files, or the branch carries >=1 commit;

Otherwise take the **quick** path: pre-flight recall (Step 1), one `memory_lesson_save`, a **short dated report** (sections 1, 4 and 5 only), and a short chat summary. No Brain write, no `CLAUDE.md` proposal, no ADR.

**Flags override the detector**: `/retrospective --full` or `/retrospective --quick`.

**The quick path is where knowledge goes to die, so it is not silent, and it never claims an unverified write.** State what is being skipped and quote the identifier you got back: *"Quick retrospective — lesson `lsn_…` saved, no Brain write. Say `--full` for the write-up."* If the save returned no id, say the save failed. If a failure receipt turns up after quick was chosen, **stop and escalate**: *"This has a failure worth recording — switch to full, or confirm quick?"* Never downgrade silently.

## Step 1 — Pre-flight recall (before drafting anything)

Query what is already known first, so learnings *reinforce* rather than duplicate, and so recurrence becomes visible. "Third time this migration lock bit us" is a far stronger finding than "this failed today".

- `memory_recall(query, format: 'compact')` — past session observations on the same files/concepts.
- `memory_lesson_recall(query, minConfidence: 0.1)` — lessons already learned. A hit means **re-save the identical content** (duplicates auto-strengthen confidence) rather than writing a near-duplicate variant.
- `memory_patterns(project)` — recurring cross-session patterns; this is what turns "it happened" into "it keeps happening".
- `search_knowledge(query, prompt)` — PP Brain, with **both** fields populated. Company conventions here supersede in-repo docs, so a hit often means "follow the existing convention", not "add a new `CLAUDE.md` rule".
- **The most recent prior report** for the target repo (path in Step 6) — the newest one only, not the whole directory. It carries the last run's Next Steps and any unresolved pending writes. If there is none, say "no prior report" rather than implying a continuity that does not exist.

Record whether recall actually changed anything. That is what the kill criterion at the bottom of this file measures.

## Step 2 — Collect session evidence

- **Git**: `git status --short`, `git diff --stat`, `git log --oneline <base>..HEAD` against the main branch (`dev` or `main`). Not just the working tree — a session that committed as it went shows an empty diff.
- **Transcript**: commands run, errors hit, how they were resolved.
- **Build/tests**: run the repo's own commands (read `CLAUDE.md` / `package.json` / `Makefile`). Never invent one. If nothing was run, that is "not run" — see Guardrails.
- **The substantive questions**: now ask the user **1 or 2** targeted questions, and only what the diff cannot answer — their goal, their satisfaction, a judgment call you cannot infer.

## Step 3 — Extract learnings with failure receipts

- Save the **exact** failing command or compiler error alongside its resolution. Abstract advice ages badly; concrete receipts do not.
- Mark each learning **new** or **recurring** against Step 1. Recurring earns a `CLAUDE.md` rule and a confidence bump; new usually earns just a lesson.
- A retrospective with no failures recorded is almost always incomplete. Look harder before concluding there were none.

## Step 3b — Repetition audit: what did this session pay for twice?

Steps 1–3 ask *what went wrong*. This asks a different and orthogonal question: **what was needlessly expensive?** Sessions leak tokens on work that was never a judgment call — the same read issued twenty times, a four-call sequence assembled by hand to answer one recurring question, output parsed by eye that a script could parse once and correctly.

Scan the transcript for **shape repetition**, not topic repetition:

- The same command or API sequence run **3+ times** with only an argument changing.
- A multi-step derivation you performed more than once to answer the *same kind* of question.
- Output you read and interpreted by hand where the interpretation followed a fixed rule.
- A fact re-derived that a command could simply print.

**Count them. Do not estimate.** "It was only a few calls" is how this stays invisible; the transcript has the real number.

### The bar a candidate must clear

A script is code someone has to maintain, and a *wrong* script is worse than a slow manual check because it is trusted. So promote a repetition to a script only when all three hold:

1. **Repeated at least three times**, or once but certain to recur every session.
2. **Mechanically decidable** — the answer follows a fixed rule with no judgment in it. If answering requires reasoning about context, a script gives false confidence and belongs nowhere near this step. *Never script judgment.*
3. **A wrong answer would be visible**, not silent. Where a wrong answer would pass unnoticed, the script must encode the check that catches it, or it makes things worse.

### The payoff is usually correctness, not tokens

This is the part worth internalising. Repetition done by hand is repetition done *differently each time*, and the variance is where errors live. A script encodes the trap **once**.

Worked receipt (2026-09-03): a supervision session hand-rolled `glab api … | jq` to answer "is this merge request merged, approved, conflicted, and green?" dozens of times. It reported four merge requests as green that were not — because GitLab's `head_pipeline` is often a merge-result run against a synthetic commit, so a green badge can sit on a branch head that failed or was never tested. A ~100-line `mrstat` script replaced the whole pattern with one line per merge request and, more importantly, made the trap unmissable: it always reports whether a run existed against the **real head** (`green(head)`, `FAILED(head)`, `manual(head)`, `NO-HEAD-RUN`, merge-result-only). Two further hand-errors got encoded for free — scrubbing control characters that break `jq` mid-parse, and reading approval from merge status so an "approved" flag that really means *no approval was required* cannot mislead.

Tokens were the presenting symptom. The defect was that a fixed rule was being re-applied from memory, badly.

### Route it

A promoted repetition is an **Axis A** artifact in Step 4 — a script or a skill, not a memory entry. Prefer:

- a small executable on `PATH` for something used across projects;
- a repo script where it depends on that repo's layout;
- a `.claude/skills/` procedure where the repetition is a *sequence of judgments* rather than a command (that is the case where scripting is wrong and a written procedure is right).

Record the candidates you **rejected** and why, in one line each. A rejected candidate with its reason stops the next session re-proposing it, and "this needs judgment" is the most valuable rejection to have written down.

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

**Axis B — persistent memory**, routed by **blast radius**. Ask "who needs to know this?" before "which tool saves this?":

| Layer | Scope | Route here when |
|---|---|---|
| harness auto-memory | this workstation, this project | it must load into context at every session start |
| agentmemory | this workstation, cross-project | it is true of *how you work here* — local env, tooling, personal workflow |
| PP Brain | the whole company, every repo and machine | a colleague on a different machine would need it |

The failure is asymmetric and silent both ways. agentmemory writes **never reach a teammate or your other machine** — a colleague-relevant learning filed only there is lost to the org, which is NPC Mode one level up. Brain writes reach **everyone** — workstation noise (local ports, Docker state, `$HOME` paths, machine-only env vars) is unfalsifiable for anyone else and pollutes org search. A learning with both a general rule and a local detail gets split: rule to Brain, detail to agentmemory, cross-referenced in the report.

**Firstmate-home override for harness auto-memory.** When the repo this session modified (Step 6) is a firstmate home — `$FM_HOME` if set, else the Firstmate code root, call it `home_root`, and it qualifies only if `home_root/.agents/skills/stow/SKILL.md` exists — a "harness auto-memory" finding does not go to the generic `~/.claude/projects/<slug>/memory/` path. It goes to that home's own `stow`-tiered memory instead, so the next `/stow` pass finds it already shaped rather than unmarked and paying a grace cycle. Mechanics in `reference.md`; tier semantics and marker spellings stay owned by the `stow` skill and are never restated here. This override applies only to the destination and stamping of a harness-auto-memory finding — agentmemory and PP Brain routing for the same session are unaffected.

## Step 5 — Execute the writes

**Nothing is claimed that was not written.** Draft section 4 *after* the writes return, and record the identifier each gave back (file path, lesson id, permalink). No identifier, no claim. A write that is declined, skipped or fails says so in section 4, and a routed artifact that was not written is **pending**, not done.

**Axis A artifacts are code changes** and follow the same discipline as any other edit. `CLAUDE.md`: show the diff, wait for an answer, then apply — amend an existing rule rather than appending a near-duplicate, link to Brain if it already documents the convention, and never write a rule into a repo this session did not touch. For `.claude/skills/`, `docs/`, `llm/kb/` and ADRs, each has its own contribution convention — see `reference.md`; hand ADRs to `adr-draft`.

**The approval gates. These are this skill's safety boundary; everything else in Step 5 is mechanics.**

- **Show before writing** any `feedback` or `user` memory file — those change how future sessions behave, and a wrong one bends your working style invisibly for months. Inside a firstmate home this maps to `data/captain.md`: same gate, same reason. Never write `data/captain-shared.md` from this skill — it is primary-owned; route a shared-preference finding to the primary the way `stow` does.
- **Show a diff before any overwrite** of an existing memory file, whatever its type.
- **Ask before any Brain write.** Local files and agentmemory are note-taking; Brain is publication to the whole company.
- `project` and `reference` creations proceed automatically and are reported after.

**Three judgment calls, and they are the only judgment here.** *Blast radius* picks the layer via the Step 4 table — wrong is silent in both directions. *Confidence* on a lesson: **0.5** single observation, **0.7** reproduced twice or user-confirmed, **0.8+** only with a failing-to-passing test; do not inflate, because confidence decays unused and an over-confident wrong lesson outranks a correct cautious one. *Sensitivity* before any Brain write: no employee or HR data, no named B2C/parker personal data, no raw plates — use the `plateId`; revenue and B2B operator information are fine, and raw log output belongs in the local report.

**Three traps that have actually bitten.** Never call `submit_session_intel` — despite the name it is plugin telemetry, not a retrospective sink. Never put an agentmemory id in a Brain body — that layer is machine-local and decaying, so it is a dead link for every colleague. Never describe a pointer into agentmemory as permanent retention.

Signatures, required fields, paths and frontmatter live in `reference.md`, deliberately not here.

If a layer is unreachable, **still write the report**, mark the layer, and list the intended writes verbatim as pending. Losing the report because a sink was offline is the worst outcome; silently dropping the writes is the second worst.

## Step 6 — Write the report

**The report is the one unconditional output of this skill.** It is written on every path — full, quick, and runs aborted part-way through an approval prompt. A run that wrote nothing durable still writes a report saying exactly that, with the intended writes listed verbatim as pending. There is no path through this skill that leaves no trace.

Path: `<repo>/.claude/skills/retrospective/reports/YYYY-MM-DD-brief-description-SESSION_ID.md`

- `<repo>` is the repo the session **modified**, derived from the Step 2 diff — *not* `cwd`. A session run from one repo often changes files elsewhere.
  Inside a firstmate home this resolves through the `.claude/skills` -> `.agents/skills` symlink, so no override is needed there.
- Changes outside any git repo (`~/.claude`, dotfiles, scratch) -> `~/.claude/skills/retrospective/reports/`, and say so, **unless** the session is running inside a firstmate home (`$FM_HOME` if set, else the Firstmate code root; it qualifies only if that root's `.agents/skills/stow/SKILL.md` exists) — there, write instead to that home's own `.agents/skills/retrospective/reports/`, keeping the report with the fleet it concerns rather than in the generic personal store. Dropping a personal report into an unrelated product repo pollutes someone else's diff, and `.claude/` is not gitignored everywhere.
- Several repos -> the one carrying the primary deliverable, cross-referenced in section 1.
- `mkdir -p` first. `SESSION_ID` is the session UUID truncated to 8 characters (it is the scratchpad path's directory segment), else `HHMM`.

Use the template below.

## Step 7 — Close the loop

In chat: the report path, which Axis A artifacts changed, which Axis B layers were written with their identifiers, and the Next Steps. The report holds the detail.

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

**Axis B** — Harness auto-memory: [files + shown-first confirmations, or none] · agentmemory: [ids with confidence] · PP Brain: [permalinks, or "not approved" / "unreachable — pending: ..."] · Promotion candidates: [local learnings that belong in Brain later, or none]

## 5. Recall Effectiveness (kill-criterion ledger)
- **Did Step 1 change the output?** [yes — how | no]

## 6. Next Steps
- [ ] Specific, concrete, unblocked actions
````

## Guardrails

- **Never** commit or push unless asked. Writing the report and updating memory is the deliverable; version control is the user's call.
- **Never** apply `CLAUDE.md` edits without showing the diff and getting an answer; never write to Brain without approval; never write a `feedback`/`user` memory or overwrite a memory file without showing it first.
- Do not fabricate error logs, test results, commit ranges, memory writes, or a permalink `add_knowledge` did not return. If the build was never run, write "not run" — an invented green checkmark poisons every future session that reads the report.
- Keep it specific. "Improved error handling" is worthless; "wrapped the Prisma call in a transaction because the retry re-inserted the row" is the point. Doubly so for lessons, which get recalled out of context months later.
- The sensitivity gate applies to committed reports too, not only at the Brain boundary.

### Anti-rationalization

| The excuse | The rebuttal |
|---|---|
| "Nothing really failed — this was straightforward." | Check the transcript for retried commands, corrected assumptions, and user corrections. A session containing a user correction is a high-value retrospective, not a quiet one. |
| "The user is in a hurry, skip the recall." | Recall is the entire compounding mechanism; without it this is a diary. It is four calls. |
| "I remember what I learned, I don't need the diff." | Your recollection is a summary of a summary. The diff is the only record of what changed. |
| "This lesson is obviously right — 0.9." | Confidence decays when unused and strengthens on reinforcement. An inflated wrong lesson outranks a correct cautious one. 0.5 unless reproduced or confirmed. |
| "The write probably succeeded." | Report only identifiers you received back. No id, no claim. |
| "This is generally useful, put it in Brain." | Brain reaches everyone. If it is only true on this machine, it is agentmemory. |
| "Quick path is fine, it was a small session." | Small sessions containing a correction are exactly the ones worth recording. State what you are skipping and let the user override. |
| "This is a `project` fact, not `feedback` — no need to show it." | If the content tells a future session how to behave — "always", "prefer", "never", "ask before" — it is `feedback` whatever the frontmatter says, and it gets shown first. Type is decided by what the text does, not by which label avoids the prompt. |
| "It's a quick run, so I don't need to work out the repo target." | The report is written on every path, so the destination is always required. Derive it from the Step 0 diff. |

## Kill criterion (registered 2026-08-19; redesigned 2026-09-03 — do not silently drop)

**What is measured.** Across the next **10 qualifying runs**, Step 1 recall must change *the work*, not the write-up, in **>= 4**. A qualifying change is: a command not run because recall said it fails; an approach chosen or abandoned on a recalled decision; a failure marked recurring and promoted to a rule; or an existing convention followed instead of a new one invented. **A lesson re-saved to strengthen it does NOT count** — this skill mandates that on every hit, so counting it would make the test self-fulfilling.

**Cold starts are excluded.** A run where the store held nothing relevant to the session's subject is recorded `n/a` and does not consume one of the ten. This corrects the original registration, which counted empty-store runs as failures and so was arithmetically unreachable on a fresh machine: it tested the age of the store, not the value of recall.

**If it fails that bar, Axis B is overhead.** Strip this skill to one lesson write plus the report, and leave the routing in `reference.md` only.

**The graded party does not keep the scoreboard.** Append each run to `reports/KILL-CRITERION.md`, one row, never rewriting an earlier one, and **quote the actual recall output** that did or did not change the run — a verdict with no quoted evidence is a claim, not a verdict. The agent records evidence and a provisional read; **the verdict belongs to the human.**

**Why this was redesigned rather than deleted.** An independent critique (2026-09-03, `~/firstmate/data/retro-critique-notebooklm/report.md`) argued the criterion was unsound and should be removed. Two of its objections were correct and are fixed above: no cold-start exclusion, and a success condition the skill itself guarantees. But deleting the test would have removed the accountability rather than the flaw — and the agent proposing that deletion is the graded party, which is the exact conflict this criterion was written to contain. So the design was fixed and the test kept. Recorded here so the reasoning is auditable rather than remembered.
