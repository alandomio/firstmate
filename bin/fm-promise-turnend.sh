#!/usr/bin/env bash
# fm-promise-turnend.sh - make every captain deadline a registered promise.
#
# A deadline the captain gives in chat ("dobbiamo rilasciare entro il
# pomeriggio") must become a dated promise (bin/fm-promise.sh add) in the same
# turn, echoed back as "Registrato: ... entro ...". Remembering to do it failed,
# so this hook enforces it mechanically on a Claude primary:
#
#   prompt  (UserPromptSubmit) prints, as context for the turn, every
#           "BLOCCA SCADENZA hh:mm" line from `fm-promise.sh blocking` (the
#           reply leads with them) and, when the captain's message has a time
#           expression, the exact commands that register it or record the
#           override.
#   stop    (Stop) blocks the turn end (exit 2, reason on stderr) when the last
#           captain message has a time expression and nothing was registered
#           after it: no `fm-promise.sh add` and no `fm-promise.sh none`
#           override in data/promesse/registro.log at or after the message's
#           timestamp. It blocks at most twice per message, then lets the turn
#           end and logs an `unregistered` event, so a broken registry can
#           never wedge the session.
#   match   reads text on stdin and prints the matched time expression, exit 1
#           when there is none (tests and manual checks).
#
# Scope: only a genuine primary home (bin/fm-primary-scope-lib.sh), the same
# scope as bin/fm-turnend-guard.sh; crew and scout worktrees stay inert. A
# Cursor payload is the Claude-settings duplicate and stands down. Missing jq,
# payload, or transcript fails open.
#
# Captain messages are the transcript's user entries with human text; tool
# results, meta entries, task notifications, slash-command wrappers, and
# Firstmate operational input (the U+2063 marker or its record doorbell) are
# not the captain. <system-reminder> blocks are removed before matching.
#
# Time expressions (Italian, case-insensitive). Strong ones match alone:
# "entro", "scadenza", "in giornata", "alle <ora>", a dd/mm date, "tra/fra N
# minuti|ore|giorni", "per oggi|domani|stasera|<weekday>". Weak ones - oggi,
# domani, dopodomani, stasera, stamattina, mattina, pomeriggio, weekday names -
# match only next to a commitment cue (dobbiamo, bisogna, rilascio,
# consegna, pronto, finire, mandare, ...), so "stamattina compro il robot da
# cucina" does not count. A false positive costs one `fm-promise.sh none
# '<why>'` line, recorded in the log.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOG="$FM_HOME/data/promesse/registro.log"
MAX_BLOCKS=${FM_PROMISE_TURNEND_MAX_BLOCKS:-2}

B='(^|[^[:alnum:]])'
E='([^[:alnum:]]|$)'
WEEKDAY='(luned[iì]|marted[iì]|mercoled[iì]|gioved[iì]|venerd[iì]|sabato|domenica)'
STRONG=(
  "${B}entro${E}"
  "${B}scadenz[ae]${E}"
  "${B}in giornata${E}"
  "${B}alle (ore )?[0-9]{1,2}([:.][0-9]{2})?${E}"
  "${B}[0-3]?[0-9]/[01]?[0-9](/[0-9]{2,4})?${E}"
  "${B}(tra|fra) ([0-9]+|un|una|due|tre|mezz) ?'?(ora|ore|oretta|minuti|giorni|giorno)${E}"
  "${B}per (oggi|domani|dopodomani|stasera|stamattina|${WEEKDAY})${E}"
)
WEAK="${B}(oggi|domani|dopodomani|stasera|stamattina|mattina|mattinata|pomeriggio|${WEEKDAY})${E}"
CUE="${B}(dobbiamo|bisogna|occorre|va fatt[oa]|rilasci[a-z]*|consegn[a-z]*|pront[oaie]|finir[a-z]*|finisc[a-z]*|mand[a-z]*|invi[a-z]*|chiud[a-z]*|pubblic[a-z]*|deploy|promess[oa]|promesso)${E}"

time_expression() {  # <text> -> prints the matched expression, exit 1 if none
  local text p
  text=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  for p in "${STRONG[@]}"; do
    if [[ $text =~ $p ]]; then
      printf '%s\n' "${BASH_REMATCH[0]}" | sed 's/^[^[:alnum:]]*//; s/[^[:alnum:]]*$//'
      return 0
    fi
  done
  if [[ $text =~ $WEAK ]]; then
    local weak=${BASH_REMATCH[0]}
    if [[ $text =~ $CUE ]]; then
      printf '%s\n' "$weak" | sed 's/^[^[:alnum:]]*//; s/[^[:alnum:]]*$//'
      return 0
    fi
  fi
  return 1
}

# Strip reminders and decide whether a user text is the captain's.
captain_text() {  # <text> -> cleaned text, exit 1 when not the captain
  local t=$1
  case "$t" in
    $'\xE2\x81\xA3'*|': Firstmate operational input'*|'<task-notification>'*|'<command-'*|'<local-command'*|'Caveat:'*|'[Request interrupted'*|'Stop hook feedback'*)
      return 1 ;;
  esac
  t=$(printf '%s' "$t" | perl -0pe 's/<system-reminder>.*?<\/system-reminder>//gs' 2>/dev/null || printf '%s' "$t")
  t=$(printf '%s' "$t" | sed '/^[[:space:]]*$/d')
  [ -n "$t" ] || return 1
  printf '%s' "$t"
}

# Last captain message in the transcript: prints "<epoch>\t<text>" on one line
# (newlines folded), exit 1 when none is found.
last_captain_message() {  # <transcript>
  local f=$1 line ts text epoch
  [ -f "$f" ] || return 1
  while IFS= read -r line; do
    ts=$(printf '%s' "$line" | jq -r '.timestamp // empty' 2>/dev/null)
    text=$(printf '%s' "$line" | jq -r '.text' 2>/dev/null)
    text=$(captain_text "$text") || continue
    epoch=$(date -d "$ts" +%s 2>/dev/null) || epoch=0
    printf '%s\t%s\n' "$epoch" "$(printf '%s' "$text" | tr '\n\t' '  ')"
    return 0
  done < <(tail -n "${FM_PROMISE_TRANSCRIPT_TAIL:-3000}" "$f" | jq -cR '
      fromjson? | select(type == "object" and .type == "user" and (.isMeta != true) and (.isCompactSummary != true))
      | .message.content as $c
      | (if ($c | type) == "string" then $c
         elif ($c | type) == "array" and ([$c[] | select(.type == "tool_result")] | length) == 0
           then ([$c[] | select(.type == "text") | .text] | join("\n"))
         else empty end) as $t
      | select(($t | length) > 0)
      | {timestamp, text: $t}' 2>/dev/null | awk '{ l[NR] = $0 } END { for (i = NR; i > 0; i--) print l[i] }')
  return 1
}

registered_since() {  # <epoch>
  [ -f "$LOG" ] || return 1
  awk -F '\t' -v t="$1" '($2 == "add" || $2 == "none") && $1 + 0 >= t + 0 { found = 1 } END { exit found ? 0 : 1 }' "$LOG"
}

in_scope() {
  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$SCRIPT_DIR/fm-primary-scope-lib.sh"
  # shellcheck source=bin/fm-hook-host-lib.sh
  . "$SCRIPT_DIR/fm-hook-host-lib.sh"
  command -v jq >/dev/null 2>&1 || return 1
  [ -n "$PAYLOAD" ] || return 1
  fm_hook_payload_is_foreign_host "$PAYLOAD" && return 1
  [ "${FM_PROMISE_TURNEND_FORCE_SCOPE:-0}" = 1 ] && return 0
  fm_primary_scope_matches "$FM_ROOT" "$STATE"
}

register_hint() {  # <expression>
  printf 'Il messaggio del capitano contiene un tempo ("%s"). Nello stesso turno registralo e ripetilo al capitano:\n' "$1"
  printf '  bin/fm-promise.sh add <id> --due "<YYYY-MM-DD HH:MM|HH:MM|domani HH:MM>" --text "<impegno>" --ref chat\n'
  printf '  e rispondi con la riga "Registrato: ... entro ..." che stampa.\n'
  printf 'Se non è una scadenza: bin/fm-promise.sh none "<perché>" (resta nel registro).\n'
}

cmd_prompt() {
  local blocking prompt expr
  in_scope || exit 0
  blocking=$("$SCRIPT_DIR/fm-promise.sh" blocking 2>/dev/null || true)
  if [ -n "$blocking" ]; then
    printf 'Decisioni del capitano che bloccano una scadenza: metti queste righe in cima alla risposta finché non risponde (non decidere al suo posto):\n%s\n' "$blocking"
  fi
  prompt=$(printf '%s' "$PAYLOAD" | jq -r '.prompt // empty' 2>/dev/null)
  prompt=$(captain_text "$prompt") || exit 0
  if expr=$(time_expression "$prompt"); then
    register_hint "$expr"
  fi
  exit 0
}

cmd_stop() {
  local transcript msg epoch text expr counter n
  in_scope || exit 0
  transcript=$(printf '%s' "$PAYLOAD" | jq -r '.transcript_path // empty' 2>/dev/null)
  [ -n "$transcript" ] || exit 0
  msg=$(last_captain_message "$transcript") || exit 0
  epoch=${msg%%$'\t'*}
  text=${msg#*$'\t'}
  expr=$(time_expression "$text") || exit 0
  registered_since "$epoch" && exit 0
  counter="$STATE/.promise-turnend-$epoch"
  n=$(cat "$counter" 2>/dev/null || echo 0)
  [[ $n =~ ^[0-9]+$ ]] || n=0
  if [ "$n" -ge "$MAX_BLOCKS" ]; then
    # Give up on this message for good: log it once and keep the counter so
    # later turns answering other wakes are not blocked by the same message.
    if [ "$n" -eq "$MAX_BLOCKS" ]; then
      mkdir -p "${LOG%/*}"
      printf '%s\tunregistered\t-\t%s\n' "$(date +%s)" "turn ended without registering \"$expr\" from the captain message at $epoch" >> "$LOG"
      printf '%s\n' $((n + 1)) > "$counter"
    fi
    exit 0
  fi
  find "$STATE" -maxdepth 1 -name '.promise-turnend-*' -mtime +2 -delete 2>/dev/null || true
  printf '%s\n' $((n + 1)) > "$counter"
  {
    printf 'Turno non chiuso: '
    register_hint "$expr"
  } >&2
  exit 2
}

PAYLOAD=
case "${1-}" in
  prompt) PAYLOAD=$(cat 2>/dev/null || true); cmd_prompt ;;
  stop) PAYLOAD=$(cat 2>/dev/null || true); cmd_stop ;;
  match) t=$(cat); time_expression "$t" ;;
  -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//' ;;
  *) printf 'usage: fm-promise-turnend.sh prompt|stop|match\n' >&2; exit 2 ;;
esac
