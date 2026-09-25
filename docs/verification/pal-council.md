# Pal council catalog verification

Audience: maintainer verification.

This record supports tier resolution in `bin/fm-pal-council.sh`, which reads each harness's own model catalog instead of naming model ids.
It records only facts that must be re-established when a harness version changes; refresh it with the live guard below.

## Catalog surfaces

| Harness | Catalog read | Order the tier patterns rely on |
|---|---|---|
| claude | the `--model` paragraph of `claude --help`, whose quoted aliases name the latest model of each family | the order of the aliases in that paragraph |
| codex | `codex debug models`, the raw catalog as JSON; entries with `visibility` `list` | ascending `priority` |
| agy | `agy models`, one `id<TAB>label` line per model after a `Fetching` line | listing order, newest first within a family; the catalog also lists Claude and GPT-OSS ids, which the default `exclude` patterns drop to keep the Google seat on Gemini |
| grok, cursor | `grok models`, `cursor-agent --list-models`, one model per line | listing order; not yet verified live |

## Live result

Verified 2026-09-25 with the live guard:

```sh
FM_PAL_COUNCIL_LIVE_E2E=1 tests/fm-pal-council-catalog-live-e2e.test.sh
```

```text
ok - claude 2.1.282 (Claude Code): top model fable
ok - codex codex-cli 0.152.1: top model gpt-5.6-sol
ok - agy 1.2.11: top model gemini-3.1-pro-high
absent: grok (grok not on PATH)
absent: cursor (cursor-agent not on PATH)
checked 3 installed harness catalog(s)
```

The default economy picks on the same versions were `sonnet` for claude, `gpt-5.6-luna` for codex (its catalog description reads "fast and efficient"), and `gemini-3.8-flash-low` for agy, from `bin/fm-pal-council.sh catalog <harness>`.
