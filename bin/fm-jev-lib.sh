#!/usr/bin/env bash
# fm-jev-lib.sh - hook-side helpers for the Jev shadow wake classifier.
#
# bin/fm-jev.sh owns the contract: what is enabled, what leaves the machine,
# the limits, the private log, and how ground truth is measured. This file is
# sourced by the production scripts that feed that log and holds only the
# cheap enabled test plus the event appends they call inline:
#   fm_jev_enabled <home> <state>                    - 0 when this home opted into either backend
#   fm_jev_backend <home> <state>                    - prints "local" or "openrouter"; exit 1 when off
#   fm_jev_observe <home> <state> <steer|decision> [task]
#                                                    - skipped under FM_JEV_OBSERVE=0,
#                                                      which automated senders set
#   fm_jev_observe_ack <home> <state> <through-seq>
#   fm_jev_observe_turn_end <home> <state> <hook-payload-json>
#   fm_jev_observe_drain <home> <state> <deduped-raw-rows>
#   fm_jev_absorb_try <home> <state> <signal|stale> <task> <reason>
#                                                    - synchronous, bounded gate
#                                                      check for bin/fm-watch.sh's
#                                                      two allowlisted call sites
#   fm_jev_absorb_digest_surface <state>              - printed by
#                                                      bin/fm-wake-drain.sh on
#                                                      every drain
#
# Every function is best effort and silent: it never prints, always returns 0
# (except fm_jev_enabled's own answer), and costs one file test when the home
# has not opted in. A Jev problem can therefore never change a caller's output,
# exit status, ordering, or timing, and the classification itself always runs
# detached from the caller.

FM_JEV_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Opt-in is either a non-empty config/jev-endpoint (local backend, no secret to
# gate on) or a non-empty OPENROUTER_API_KEY in this home's private .env
# (OpenRouter backend), and only for the home's own state directory, so a test
# or tool that points STATE elsewhere can never use either backend. config/
# jev-endpoint takes priority when both are present. Neither value's content is
# validated here (loopback-only enforcement lives in bin/fm-jev.sh, which reads
# both only at request time).
fm_jev_backend() {  # <home> <state> -> prints "local" or "openrouter"
  local home=${1:-} state=${2:-}
  [ -n "$home" ] && [ -n "$state" ] || return 1
  [ "$state" -ef "$home/state" ] || return 1
  if [ -s "$home/config/jev-endpoint" ] && grep -q '[^[:space:]]' "$home/config/jev-endpoint" 2>/dev/null; then
    printf 'local\n'
    return 0
  fi
  [ -f "$home/.env" ] || return 1
  if grep -Eq "^[[:space:]]*(export[[:space:]]+)?OPENROUTER_API_KEY=[[:space:]]*[\"']?[A-Za-z0-9]" "$home/.env" 2>/dev/null; then
    printf 'openrouter\n'
    return 0
  fi
  return 1
}

fm_jev_enabled() {  # <home> <state>
  fm_jev_backend "${1:-}" "${2:-}" >/dev/null
}

_fm_jev_append() {  # <state> <json-line>
  local dir="$1/jev"
  if [ ! -d "$dir" ]; then
    (umask 077 && mkdir -p "$dir") 2>/dev/null || return 0
  fi
  (umask 077 && printf '%s\n' "$2" >> "$dir/shadow.jsonl") 2>/dev/null || true
  return 0
}

# The durable digest of absorption (bin/fm-jev.sh's absorb-try is the sole
# writer): one JSON line per wake absorbed before it ever reached the wake
# queue, so a captain reading the digest can always see what quiet cleaning
# actually did, even though the wake itself never surfaced.
_fm_jev_absorb_append() {  # <state> <json-line>
  local dir="$1/jev"
  if [ ! -d "$dir" ]; then
    (umask 077 && mkdir -p "$dir") 2>/dev/null || return 0
  fi
  (umask 077 && printf '%s\n' "$2" >> "$dir/absorbed.jsonl") 2>/dev/null || true
  return 0
}

# Ask bin/fm-jev.sh whether an eligible wake, about to be queued and to wake
# the supervising session, should instead be absorbed: a synchronous, bounded
# (the existing per-request classify timeout) call made ONLY from
# bin/fm-watch.sh's two allowlisted call sites (a routine working/paused
# "signal" wake, or a declared-pause "stale" recheck), never for anything
# else - bin/fm-jev.sh's absorb-try owns every eligibility rule and the go-live
# gate. 0 when absorbed: the caller must skip its own fm_wake_append + wake and
# leave the durable digest above to carry the record. 1 for every other
# outcome - off, ineligible, doubtful, or a classifier problem - so the caller
# always falls through to today's unconditional behavior. The cheap
# fm_jev_enabled test below means a home that never opted in pays no fork at
# all on this hot path.
fm_jev_absorb_try() {  # <home> <state> <signal|stale> <task> <reason>
  local home=${1:-} state=${2:-} kind=${3:-} task=${4:-} reason=${5:-}
  [ -n "$home" ] && [ -n "$state" ] || return 1
  [ "$state" -ef "$home/state" ] || return 1
  fm_jev_enabled "$home" "$state" || return 1
  case "$kind" in signal|stale) ;; *) return 1 ;; esac
  [ -n "$task" ] || return 1
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    "$FM_JEV_LIB_DIR/fm-jev.sh" absorb-try --kind "$kind" --task "$task" --reason "$reason" \
    </dev/null >/dev/null 2>&1
}

# Print an ABSORBED section for every digest line not yet surfaced, then
# advance the cursor so it is never repeated. Called on every drain
# (bin/fm-wake-drain.sh), so an absorbed wake surfaces with the very next real
# wake or heartbeat - whichever comes first, because that is the next time a
# drain runs at all - never forcing a supervision wake of its own. Silent
# (prints and touches nothing) when nothing is pending, which is the common
# case and the case for a home that never enabled absorption.
fm_jev_absorb_digest_surface() {  # <state>
  local state=$1 digest cursor size offset have count
  digest="$state/jev/absorbed.jsonl"
  [ -f "$digest" ] || return 0
  [ ! -e "$state/.afk" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  cursor="$state/jev/.absorbed-cursor"
  size=$(wc -c < "$digest" 2>/dev/null | tr -d ' ') || size=0
  case "$size" in ''|*[!0-9]*) size=0 ;; esac
  offset=0
  [ -f "$cursor" ] && offset=$(cat "$cursor" 2>/dev/null)
  case "$offset" in ''|*[!0-9]*) offset=0 ;; esac
  [ "$offset" -le "$size" ] || offset=0
  if [ "$offset" -eq "$size" ]; then
    return 0
  fi
  have=$(tail -c "+$((offset + 1))" "$digest" 2>/dev/null | head -c "$((size - offset))"; printf x)
  have=${have%x}
  case "$have" in
    *$'\n') ;;
    *$'\n'*) have="${have%$'\n'*}"$'\n' ;;
    *) return 0 ;;
  esac
  size=$((offset + $(printf '%s' "$have" | wc -c | tr -d ' ')))
  count=$(printf '%s' "$have" | grep -c '[^[:space:]]') || count=0
  if [ "$count" -eq 0 ]; then
    (umask 077 && printf '%s\n' "$size" > "$cursor") 2>/dev/null || true
    return 0
  fi
  printf 'ABSORBED (%d wake%s, absorbed by the local Jev classifier before reaching the queue - masked reason/status kept below):\n' \
    "$count" "$([ "$count" -eq 1 ] && printf '' || printf 's')"
  printf '%s' "$have" | jq -Rr '
    select(test("[^[:space:]]"))
    | (fromjson? // null) as $e
    | if ($e | type) == "object" then
        "  \(($e.t | todate?) // "unknown time") \($e.kind) task \($e.task): choice \($e.choice) (\($e.confidence))\(if ($e.reason // "") != "" then " | wake: " + $e.reason else "" end)\(if ($e.status // "") != "" then " | worker: " + $e.status else "" end)"
      else "  (unreadable digest entry)" end
  ' 2>/dev/null
  (umask 077 && printf '%s\n' "$size" > "$cursor") 2>/dev/null || true
}

# Ground truth counts only what firstmate itself does in a handling turn, so a
# send the watcher, bootstrap or config reread makes on its own, and the remote
# relay of a send the parent home already recorded, sets FM_JEV_OBSERVE=0 and
# records nothing.
fm_jev_observe() {  # <home> <state> <steer|decision> [task]
  local line
  [ "${FM_JEV_OBSERVE:-1}" != 0 ] || return 0
  fm_jev_enabled "${1:-}" "${2:-}" || return 0
  case "${3:-}" in steer|decision) ;; *) return 0 ;; esac
  command -v jq >/dev/null 2>&1 || return 0
  line=$(jq -cn --arg ev "$3" --arg task "${4:-}" --argjson t "$(date +%s)" \
    '{ev: $ev, t: $t, task: $task}' 2>/dev/null) || return 0
  _fm_jev_append "$2" "$line"
}

fm_jev_observe_ack() {  # <home> <state> <through-seq>
  fm_jev_enabled "${1:-}" "${2:-}" || return 0
  case "${3:-}" in ''|*[!0-9]*) return 0 ;; esac
  _fm_jev_append "$2" "{\"ev\":\"ack\",\"t\":$(date +%s),\"through\":$3}"
}

# Records only how the turn ended, never its text: "ack" for the exact routine
# acknowledgement AGENTS.md section 9 prescribes or an empty final message,
# "message" for any other final text, and "unknown" when the harness payload
# carries no last_assistant_message string.
fm_jev_observe_turn_end() {  # <home> <state> <hook-payload-json>
  local outcome
  fm_jev_enabled "${1:-}" "${2:-}" || return 0
  command -v jq >/dev/null 2>&1 || return 0
  outcome=$(printf '%s' "${3:-}" | jq -r '
    (if type == "object" then .last_assistant_message else null end) as $m
    | if ($m | type) != "string" then "unknown"
      else ($m | gsub("^\\s+|\\s+$"; "")) as $s
        | if $s == "" or $s == "Captain, shipshape." then "ack" else "message" end
      end' 2>/dev/null) || return 0
  case "$outcome" in ack|message|unknown) ;; *) return 0 ;; esac
  _fm_jev_append "$2" "{\"ev\":\"turn_end\",\"t\":$(date +%s),\"outcome\":\"$outcome\"}"
}

# Hands the rows a drain just presented to bin/fm-jev.sh in a detached process
# that records them and classifies them off the wake path. FM_JEV_FOREGROUND=1
# runs it synchronously, for tests only.
fm_jev_observe_drain() {  # <home> <state> <deduped-raw-rows>
  local home=${1:-} state=${2:-} rows=${3:-} spool now
  [ -n "$rows" ] || return 0
  fm_jev_enabled "$home" "$state" || return 0
  (umask 077 && mkdir -p "$state/jev") 2>/dev/null || return 0
  spool=$(umask 077 && mktemp "$state/jev/.spool.XXXXXX" 2>/dev/null) || return 0
  printf '%s\n' "$rows" > "$spool" 2>/dev/null || { rm -f "$spool"; return 0; }
  now=$(date +%s)
  if [ "${FM_JEV_FOREGROUND:-0}" = 1 ]; then
    FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
      "$FM_JEV_LIB_DIR/fm-jev.sh" observe-drain "$spool" "$now" </dev/null >/dev/null 2>&1 || true
  else
    ( FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
      "$FM_JEV_LIB_DIR/fm-jev.sh" observe-drain "$spool" "$now" </dev/null >/dev/null 2>&1 & ) 2>/dev/null || true
  fi
  return 0
}
