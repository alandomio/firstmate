# retrospective — reference

Looked up, not memorised. `SKILL.md` holds the decisions and the safety gates; this file holds
the mechanics. If something here is needed to make a *judgment*, it is in the wrong file.

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

**Approval:** `feedback` and `user` files are shown before writing; any overwrite is shown as a
diff. `project` and `reference` creations are automatic. That gate lives in `SKILL.md`.

### Firstmate-home override

Resolve `home_root` the way `stow` does: `$FM_HOME` when set, else the Firstmate code root. The
override in `SKILL.md` applies only when `home_root/.agents/skills/stow/SKILL.md` exists.

- `feedback` / `user`-shaped finding -> append to `home_root/data/captain.md`, gated exactly as
  the generic case (show before writing). No marker — that file's default tier is `pinned`, per
  `stow`.
- `project` / `reference`-shaped finding -> append to `home_root/data/learnings.md`, auto-create,
  no gate — same as the generic case. Stamp it `<!--a:YYYY-MM-DD-->` (today) unless the finding
  names a checkable expiry condition (a backlog id, a version floor, a dated expectation), in
  which case stamp `<!--p:YYYY-MM-DD-->` and put that condition in the prose. Both the letter
  choice and the format are `stow`'s marking rules, not this skill's own; on any doubt, default to
  `<!--a:...-->` and let the next `/stow` pass re-tier it.
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
- `memory_reflect(project)` — synthesises across concept clusters. Worth one call after a
  substantial session; skip it when the store is nearly empty, since clustering noise yields noise.
- `memory_consolidate(tier)` — runs agentmemory's **own** four tiers
  (working -> episodic -> semantic -> procedural). **Unrelated to Axis A** despite the matching
  count; never report one as the other.

`project` is a **known-inconsistent field** — the documentation and the live data have disagreed.
Call `memory_sessions()` first and reuse whatever identifier the current session was actually
registered under; if none exists, **omit it** rather than invent one. Detail: Brain `02a16f`.

## PP Brain

Company-wide, cross-repo, cross-machine, human-readable — the only layer a colleague can read.

- Search before writing. The convention is to link, not fork.
- `add_knowledge(title, summary, body, tags, links)` — title >= 5 chars, summary >= 20 (aim ~500,
  key information **first**, because it is sentence-truncated server-side), body >= 50. Tags are
  namespaced: `type:pattern`, `domain:payment`. Default `sync: true` returns
  `{ok, id, slug, permalink}` for the report.
- Link it — `links: [{targetSlug, linkType}]` on create, or `link_knowledge` afterwards. An
  unlinked Brain item is nearly invisible.
- Very large payloads have failed JSON validation. Keep the body focused and point at the canonical
  file rather than embedding it wholesale.
- A 422 is the sensitivity gate. What it refuses is in `SKILL.md`.
