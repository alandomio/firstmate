# retrospective — reference

Mechanics, looked up not memorised. `SKILL.md` holds the decisions and safety gates.

## Axis A contribution conventions

- `.claude/skills/` — write or patch the file, then state its new line count so the change is verifiable.
- `docs/` — follow the repo's own convention.
- `llm/kb/` — requires the next `FACT`/`PATTERN`/`CASE` number plus an `index.md` entry. Check the
  existing numbering before inventing one.
- ADR — hand off to the `adr-draft` skill. Do not hand-roll one.

## Harness auto-memory

Path: `~/.claude/projects/<project-slug>/memory/`. One fact per file, plus a one-line pointer in
`MEMORY.md`. Frontmatter: `name`, `description`, `metadata.type` where type is one of
`user` | `feedback` | `project` | `reference`.

This layer loads at every session start, which makes it the highest-leverage place for corrections
to working style (`feedback`, written with **Why:** and **How to apply:** lines) and for non-obvious
project constraints (`project`, with relative dates converted to absolute).

Check for an existing file on the same fact and update it rather than duplicating. Do not write
what the repo already records.

### Firstmate-home override

Resolve `home_root` the way `stow` does: `$FM_HOME` when set, else the Firstmate code root. The
override in `SKILL.md` applies only when `home_root/.agents/skills/stow/SKILL.md` exists.

- `feedback` / `user`-shaped finding -> append to `home_root/data/captain.md`, gated exactly as
  the generic case (show before writing). No marker — that file's default tier is `pinned`, per
  `stow`.
- `project` / `reference`-shaped finding -> append to `home_root/data/learnings.md`, auto-create,
  no gate — same as the generic case. Stamp it `<!--a:YYYY-MM-DD-->` (today) unless the finding
  names a checkable expiry condition (a backlog id, a version floor, a dated expectation), in
  which case stamp `<!--p:YYYY-MM-DD-->` and put that condition in the prose. The marking rules are `stow`'s; on any doubt, default to `<!--a:...-->`.
- Never write `data/captain-shared.md` — read-only from here, exactly as `stow` treats it in a
  secondmate home. A shared-preference finding routes to the primary through whatever channel this
  session already uses to reach it (a marked status line, a document pointer) — this skill does
  not invent a new one.
- A finding this override does not clearly fit (ambiguous scope, unclear tier) falls back to the
  generic `~/.claude/projects/<slug>/memory/` path rather than guessing at a firstmate-home file.

## agentmemory

Workstation-local, cross-project, confidence-scored, decaying.

- `memory_save(content, type, concepts, files, project)` — `type` is one of
  `pattern` | `preference` | `architecture` | `bug` | `workflow` | `fact`. Pass `files` and
  `concepts` or later recall will not find it.
- `memory_lesson_save(content, context, confidence, tags, project)` — `context` must state *when
  the lesson applies*, or it is unactionable when recalled cold months later. Confidence values are
  in `SKILL.md`; they are a judgment, not a parameter default.
- `memory_lesson_recall(query, minConfidence)` / `memory_recall(query, format)` /
  `memory_smart_search` / `memory_patterns(project)` — the recall verbs. More than one; the lesson
  store alone misses things.
- `memory_reflect(project)` — worth one call after a substantial session; skip on a near-empty store.
- `memory_consolidate(tier)` — runs agentmemory's **own** four tiers
  (working -> episodic -> semantic -> procedural). **Unrelated to Axis A** despite the matching
  count; never report one as the other.

`project` is a **known-inconsistent field** — the documentation and the live data have disagreed.
Call `memory_sessions()` first and reuse whatever identifier the current session was actually
registered under; if none exists, **omit it** rather than invent one. Detail, on a PP Brain home: item `02a16f`.

## Org knowledge store

Company-wide, cross-repo, cross-machine, human-readable — the only layer a colleague can read.
Which store that is comes from `bin/fm-knowledge-store.sh read` (`SKILL.md`, "Resolve the org store first"); use only the section below that matches its `backend`.
Search before writing in every backend: the convention is to link, not fork.

### `backend=rag` — the RAG (`rag_qdrant_server`)

- Recall: `query_rag_hybrid(query_text, user_roles)`, falling back to `query_rag` with the same arguments.
  Pass `user_roles` even when empty.
- Write: `ingest_document(chunk_text, metadata_json, user_roles)`.
  `metadata_json` is a JSON string and must carry `document_type`, one of `guida` | `policy` | `info` | `ticket`; any other value is rejected.
  A retrospective learning is normally `info`, and a stable convention a colleague must follow is `guida`.
  Also set `file_path` (a stable logical path such as `retrospective/<repo>/<slug>`), a `slug`, `tags`, and `document_date` (today), so the item is findable and linkable later.
  `user_roles` sets who can read it; keep it internal (for example `admin,dev`), never public.
- The identifier to record in the report is the `slug` the call accepted, or whatever id it returned; no id back means the write is not claimed.
- Keep `chunk_text` focused, key information first; point at the canonical file.
- No update, link or related-items verb is known for this backend: skip the related-recall step, and draft a correction as a new item that names the stale `slug`.

### `backend=pp-brain` — PP Brain

- Recall: `search_knowledge(query, prompt)`, with **both** fields populated.
- `add_knowledge(title, summary, body, tags, links)` — title >= 5 chars, summary >= 20 (aim ~500,
  key information **first**, because it is sentence-truncated server-side), body >= 50. Tags are
  namespaced: `type:pattern`, `domain:payment`. Default `sync: true` returns
  `{ok, id, slug, permalink}` for the report.
- Link it — `links: [{targetSlug, linkType}]` on create, or `link_knowledge(sourceSlug, targetSlug, linkType)`
  afterwards. An unlinked Brain item is nearly invisible. A correction or replacement carries a
  `supersedes` link to the item it replaces.
- Session case record: title `CASE: YYYY-MM-DD — <subject>`, tags `type:case` and `date:YYYY-MM-DD`
  plus the usual `domain:` / `service:` tags.
- Correction: `update_knowledge(slug, updates, changeReason)` with only the changed fields; pass
  `structuredSummary` with a changed `body`. Show the before/after in the batch list; changed text is
  re-screened by the sensitivity gate.
- Related recall: `get_related_knowledge(slug)` on a good hit and its best neighbours;
  `get_knowledge(slug)` before citing or correcting one.
- Very large payloads have failed JSON validation; keep the body focused and point at the canonical file.
- A 422 is the sensitivity gate. What it refuses is in `SKILL.md`.

### `backend=other`

Recall through the `search=` instructions the command printed.
No write contract is known here, so every org-store write stays pending in the report, naming the store.
