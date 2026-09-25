#!/usr/bin/env bash
# fm-pal-council.sh - mechanics of a pal-council: a council of 1-5 expert voices
# from different model providers, run as read-only scout workers, debating one
# question in written rounds that firstmate moderates and synthesises.
#
# The moderator's procedure, its gates, and when to run each command are owned by
# .agents/skills/pal-council/SKILL.md; the texts a voice or the researcher reads
# are owned by that skill's references/, which this script inlines. This header
# owns the commands, exit codes, and environment knobs. The implementation is
# bin/fm_pal_council.py (Python 3 standard library only).
#
# Every council lives in data/pal-<id>/ under the active FM_HOME:
#   consiglio.json   composition, state, rounds, messages, prior councils, knowledge records
#   brief.md         the question (moderator-written, at most brief_max_chars)
#   allegati/        original attachments; persone/ one persona per seat
#   precedenti/      syntheses of earlier councils; psevdo/ pseudonymised copies
#   entita.md        placeholder table (never sent to any worker); pseudo.json source hashes
#   turni/<n>-<seat>.md  voice turns; pacchetti/ what each voice was sent per round
#   riassunti/<n>.md moderator summaries; ricerca/ requests, packets, dossiers
#   verbale.md       append-only record; dossier-ricerca.md; sintesi.md; costi.json; rag/ payloads
# Each voice and the researcher is an ordinary scout task pal-<id>-<seat> with its
# own data/<task-id>/brief.md, spawned through bin/fm-spawn.sh --scout with an
# explicit harness, model, and effort. Supervision is the normal watcher: a voice
# appends "done: turn <n> ..." and firstmate is woken like for any worker.
#
# Usage: fm-pal-council.sh <command> [args]
#   new "<topic>" [--tier fast|best|pro | --participants <file.json> | --like <id>]
#       [--rounds N] [--budget EUR] [--attach <file>]... [--inherit <id>]...
#       [--project <dir>] [--sensitive] [--language <code>] [--slug <slug>]
#       [--round-timeout <minutes>] [--single-provider-ok]
#       Create a draft council. A tier resolves one seat per rule from each
#       harness's own model catalog (claude --help aliases, codex debug models,
#       agy models, grok models, cursor-agent --list-models) through the
#       configured patterns; no model id is hard-coded. --participants takes a
#       JSON array of {harness, model, persona, instructions, effort, provider,
#       seat}. --like copies another council's composition, personas, project,
#       and language and inherits its synthesis. quota-axi evidence excludes a
#       seat only on concrete exhaustion; missing evidence is reported as
#       uncertainty. A council left with one provider for two or more voices,
#       or left with one provider by a quota exclusion whatever its size,
#       exits 5 unless --single-provider-ok records the captain's word.
#       Without --budget the budget is the configured per-seat default.
#   prior <id> (--none | <prior-id> [--file <synthesis>])
#       Record the RAG search for earlier councils; launch refuses until done.
#   pseudo <id> [--source <rel-path>]... [--add TYPE=FORM]... [--skip-model]
#       Pseudonymise the texts bound for workers outside Anthropic (default:
#       brief.md, allegati/, precedenti/, persone/): the pseudonymiser model
#       lists identifying forms, this script replaces them with stable
#       placeholders into psevdo/, and a deterministic literal recheck refuses
#       (exit 3) if any mapped form survives. A non-empty map marks the council
#       sensitive. TYPE is PERSON ORG ADDRESS PLACE ID CONTACT AMOUNT CASE DATE OTHER.
#       While the council runs, --add also takes a form found only in a turn, so
#       the next send carries its placeholder.
#   check <id> <file>... [--trusted]
#       Run the send gate on files: secrets for every worker, plus mapped forms
#       and structural personal data for workers outside Anthropic. Exit 3 on a hit.
#   estimate <id>
#       Euro estimate per seat from the configured list prices; exit 3 when the
#       expected-rounds estimate exceeds the budget.
#   launch <id>
#       Gate everything (brief size, prior search, personas, current pseudonymised
#       copies, estimate within budget, every generated brief through the send
#       gate) before the first worker starts, then spawn each voice and the
#       researcher and open round 1 (blind).
#   barrier <id>              Which voices delivered the current round, and whether its time is up.
#   close-round <id> [--force]
#       Append every delivered turn verbatim to the record, record a missing or
#       late voice as such, collect [RESEARCH] requests, update the spend, and
#       print the closing conditions. Refuses while voices are pending and the
#       round's time is not up, unless --force.
#   summary <id> <file>       Append the moderator summary of the last closed round.
#   research <id>             Send the round's research requests to the researcher (pseudonymised).
#   dossier <id> [--failed]   Append the delivered dossier, or record research as not delivered.
#   next <id>                 Build, gate, and send each voice's delta packet and open the next round.
#   message <id> (--all | --seat <seat>) --file <file> [--now]
#       Record a captain message; it travels with the next packets, or at once with --now.
#   drop <id> <seat> --reason <text>   Withdraw a voice from later rounds.
#   close <id> --reason <text>         Stop the rounds; the synthesis comes next.
#   cancel <id> [--reason <text>]
#       Cancel the council; an open round is first closed into the record as
#       close-round --force would close it.
#   finalize <id>
#       Require sintesi.md with the headings references/synthesis-template.md
#       lists for the council's language, close the record, and write the
#       knowledge payloads (rag/*.json, pseudonymised when sensitive).
#   rag <id>                  Rebuild the knowledge payloads.
#   rag-done <id> <payload> <point-id>  Record one payload as ingested.
#   rag-query <id>            Print the query for earlier councils on the same topic.
#   complete <id> (--none | <held-task-id>...)
#       Run bin/fm-captain-hold.sh complete for every worker of the council.
#   cleanup <id>
#       Refuse unless every delivered turn is in the record and every worker
#       passed the completion gate; then write each worker's pointer report and
#       run bin/fm-teardown.sh for it. A teardown refusal is reported, never forced.
#   arm-purge <id>
#       Register a process-event condition watch that wakes firstmate once a
#       sensitive council is purge_after_hours past its close; its action only
#       prints status, and firstmate runs purge on the wake.
#   purge-due (<id> | --all)  Exit 0 when the council is due for purge (--all prints due ids).
#   purge <id> [--force]
#       Rewrite every council text and worker brief through the placeholder
#       table, delete the original attachments and the table, and record the
#       purge. Refuses while the council is open unless --force.
#   status <id>               Print the council's state, seats, and spend.
#   catalog <harness>
#       Print the models the harness's own catalog lists, in its order, and the
#       top and economy picks the configured patterns make (claude, codex, agy,
#       grok, cursor). Exit 4 when the catalog cannot be read.
#
# Exit codes: 0 success; 2 usage or precondition not met; 3 refused by a gate
# (identifying data or a secret in an outgoing text, the budget); 4 a tool or
# worker failed; 5 the captain must decide (a single-provider council, no voice left).
#
# Configuration: config/pal-council.json under FM_HOME when present, otherwise
# the tracked docs/examples/pal-council.json; docs/configuration.md owns its schema.
# Environment: FM_HOME, FM_DATA_OVERRIDE, FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE,
# and FM_ROOT_OVERRIDE resolve the home like every firstmate script. Test seams:
# FM_PAL_CATALOG_DIR (a directory of raw catalog outputs named by harness),
# FM_PAL_QUOTA_JSON (a quota-axi --json output file), FM_PAL_PSEUDONYMISER_CMD
# (a command that reads the prompt on stdin and prints a claude -p JSON
# envelope), FM_PAL_NOW (epoch seconds), and FM_PAL_{SPAWN,SEND,BRIEF,HOLD,
# TEARDOWN,WHEN}_BIN replacing the firstmate scripts this one calls.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  ''|-h|--help)
    usage
    [ -n "${1:-}" ] || exit 2
    exit 0
    ;;
esac

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required for fm-pal-council.sh" >&2; exit 4; }
exec python3 "$SCRIPT_DIR/fm_pal_council.py" "$@"
