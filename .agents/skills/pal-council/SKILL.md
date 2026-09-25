---
name: pal-council
description: >-
  Convene a pal-council: 1-5 expert voices from different model providers, run as read-only scout workers, debating one question in written rounds while firstmate moderates and writes the synthesis.
  Use when the captain invokes /pal-council <topic> or asks for a council of models or experts to debate a decision, and on any wake from a council worker (task id pal-<council>-<seat>) or from a council's purge watch.
user-invocable: true
metadata:
  internal: true
---

# pal-council

Firstmate is the council's **moderator**: it convenes the voices, runs the rounds, summarises each one, and writes the synthesis once at the close.
It never votes: the merits are argued and contested in the voices' turns, and firstmate's own words appear only under its own headings.

`bin/fm-pal-council.sh --help` owns every command, flag, exit code, and the council folder layout; this skill owns when to run each one.
Each council lives in `data/pal-<id>/`, and each voice is an ordinary scout task `pal-<id>-<seat>` supervised by the normal watcher: no other supervision cycle is needed.

## Ground rules

- **Trust boundary.** Clear text reaches only Anthropic: firstmate, the claude-harness voices, and the pseudonymiser model.
  Everything sent to any other voice or to the researcher passes `pseudo` and the send gate; never weaken the gate, and never send a secret or credential to any worker.
  The gate covers what the council sends: voices run on this machine with read access, so material that must not reach another provider stays out of the council folder and out of the project the voices read.
- **Verbatim record.** `verbale.md` is append-only and the script appends every turn exactly as written.
- **Honest failure.** A missing, late, or lost voice is recorded as such; nobody writes a turn on its behalf.
- **Language.** The council's outputs - turns, summaries, synthesis - use `--language`, taken from the captain's recorded language preference and English when none is recorded; the instructions workers read stay in English.
- **Captain-facing.** Report outcomes, never mechanics, under `AGENTS.md` section 9; every captain intervention reaches the council through firstmate.

## Step 1: Convene

1. Read the request: the topic, a tier (`fast`, `best` by default, `pro`) or an explicit participant list, rounds (default 6, at most 20), budget, attachments (text files), earlier councils to inherit, the project the question is about (default: this firstmate repo), and whether the captain called the material private (`--sensitive`).
2. For an explicit list, write it as a JSON array of `{harness, model, persona, instructions}` and pass `--participants`.
3. Run `bin/fm-pal-council.sh new "<topic>" ... --language <code>`.
4. Exit 5 means one provider would be left for two or more voices, or no voice at all: ask the captain one question, and rerun with `--single-provider-ok` only on their word.

Done when `new` succeeded and every excluded seat and every uncertain quota line is noted for the captain.

## Step 2: Earlier councils

1. Run `rag-query <id>` and search the RAG with `query_rag_hybrid`, that query text, and `user_roles` `admin,dev`; search again with the question's own words.
2. For every earlier council synthesis that bears on this question, save its text to a file and run `prior <id> <prior-id> --file <file>`; a council still on disk needs no `--file`.
3. When nothing relevant comes back, run `prior <id> --none`.

Done when the search is recorded; `launch` refuses until it is.

## Step 3: Brief and personas

1. Write `brief.md` in the council's language, within the configured limit (10,000 characters by default): the question, the decision needed, the context and constraints the voices cannot find themselves, where to look (files, tickets, logs), and what is out of scope.
   State the question neutrally, with no leaning of the captain's or of firstmate's; larger material goes in attachments.
2. Write `persone/<seat>.md` for every planned voice following [`references/persona-template.md`](references/persona-template.md).
   The researcher's persona arrives prefilled from [`references/researcher-persona.md`](references/researcher-persona.md) and stays neutral.

Done when the brief is within the limit and every planned seat has a persona.

## Step 4: Pseudonymise

1. Run `pseudo <id>`.
2. Read every file under `psevdo/`; for an identifier that survived, run `pseudo <id> --skip-model --add TYPE=FORM`.
3. Any later edit to the brief, a persona, or an attachment needs `pseudo` again; `launch` refuses a stale copy.

Done when the literal recheck passed and a read of `psevdo/` finds no identifier left.

## Step 5: Estimate

1. Run `estimate <id>`.
2. Within budget: tell the captain the seats (model and provider), the expected cost and the figure at the round limit against the budget, and any excluded seat or uncertain quota, then go on to Step 6 in the same turn.
3. Refused: offer fewer rounds, a lower tier, a dropped seat, or a higher budget (at most 50 EUR), and wait for the captain's choice.

Done when the captain has the estimate, and a refused one has a chosen way forward.

## Step 6: Launch

1. Load `harness-adapters`, then run `launch <id>`.
2. Within about 20 seconds, check each new worker for a trust dialog and handle it as `harness-adapters` says.
3. Record the council as one backlog work item carrying its id; the voices are not separate items.

Done when every voice and the researcher is working on its brief or recorded as failed.

## Step 7: Rounds

Run this loop on every wake from a council worker, and on a heartbeat while a round is open.

1. Run `barrier <id>`.
   Voices still pending with time left means nothing to do and nothing to tell the captain; a wedged voice goes through `stuck-crewmate-recovery`.
2. When the round is complete or its time is up, run `close-round <id>`.
3. Read every turn of the round in full.
4. Write `riassunti/<n>.md` in the council's language: each voice's findings by number, where they agree and diverge, changed positions, questions raised, and any reasoning built on a placeholder; it reports and never rules.
   Then run `summary <id> riassunti/<n>.md`.
5. Run `research <id>`; when requests went out, wait for the researcher's `done: research <n>` wake and run `dossier <id>`, or `dossier <id> --failed` when the researcher cannot deliver.
6. Close the council when any condition holds: every voice `DONE`; a round with no new finding and no changed position, confirmed by reading; the round limit; the budget exceeded; the captain says so.
   Otherwise run `next <id>`.
7. A `[BLOCKER]` asking for a write goes to the captain as a decision under `captain-hold-lifecycle` while the rounds continue; `[QUESTION]` lines for the captain wait for the synthesis.

Done when a closing condition holds, every closed round has its summary, and every requested dossier is in the record or recorded as not delivered.

## Captain interventions

- **Message to every voice or to one**: write it to a file in the council's language and run `message <id> --all|--seat <seat> --file <file>`; it travels with the next packets, or at once with `--now`.
- **Change of topic**: a `message --all` stating the new question, noted in the next summary.
- **Close now**: `close-round <id> --force` when a round is open, then Step 8.
- **Cancel**: `cancel <id>`, then Step 10; a cancelled council has no synthesis and no knowledge payloads.
- **Resume a finished council with a new direction**: `new "<topic>" --like <id>` starts a linked council that inherits the synthesis, composition, and personas; continue from Step 2 with the new direction in its brief.
- **Withdraw a voice**: `drop <id> <seat> --reason <text>`.

## Step 8: Synthesis

1. Run `close <id> --reason "<how the council ended>"`.
2. Write `sintesi.md` following [`references/synthesis-template.md`](references/synthesis-template.md).
3. Turn every question for the captain into a captain-held task under `captain-hold-lifecycle`.
4. Run `finalize <id>`.

Done when `finalize` succeeded.

## Step 9: Knowledge

1. For every payload in `rag/`, call `ingest_document` with its `chunk_text`, `metadata_json`, and `user_roles` exactly as written; visibility stays internal (`admin,dev`), never public.
   If the server rejects a metadata field, retry once without that field, since the tags also live in the chunk text, and record the rejection in `data/learnings.md`.
2. Run `rag-done <id> <payload> <point-id>` for each.
3. Query `query_rag_hybrid` with `pal-council <topic>` and `admin,dev`.

Done when every payload is recorded and the query returns this council's synthesis.

## Step 10: Cleanup

1. Run `complete <id> --none`, or `complete <id> <held-task-id>...` with the tasks from Step 8.
2. Run `cleanup <id>`; a refusal is investigated, never forced.
3. For a sensitive council, load `process-event-sources` and run `arm-purge <id>`.
4. Mark the backlog item done with `sintesi.md` as its artifact.

Done when `cleanup` reports every worker cleaned up, and a sensitive council has its purge watch.

## Step 11: Report

Tell the captain, in their language: the recommendation, the disagreements still open and who holds each, the questions waiting for them, the rounds run, the cost against the budget, any voice that was excluded, late, or lost, and where the synthesis is.

## Purge

A sensitive council keeps its placeholder table and original attachments for the configured hours after its close (12 by default); `purge` then leaves only the pseudonymised form.

- On the wake of the council's purge watch (`when-pal-purge-<id>`, classified `fired`), run `purge <id>`, then acknowledge and retire the watch as `process-event-sources` says.
- On the captain's request after a close or cancel, run `purge <id>`.
- On a heartbeat, `purge-due --all` lists a council whose watch was never armed; purge it.

## Errors

- Exit 3 from the send gate: the named placeholder's clear form, or a secret, is in an outgoing text; pseudonymise it (`pseudo --add`) or remove it, then rerun the step.
  Exit 3 from the budget: return to Step 5's options.
- Exit 4: a tool or worker failed; the message names it, and a catalog that cannot be read means that tool is missing or signed out, which is the captain's to fix or to route around with `--participants`.
- Exit 5: the captain decides.
