#!/usr/bin/env bash
# fm-jev-lib.sh - hook-side helpers for the Jev shadow wake classifier.
#
# bin/fm-jev.sh owns the contract: what is enabled, what leaves the machine,
# the limits, the private log, and how ground truth is measured. This file is
# sourced by the production scripts that feed that log and holds only the
# cheap enabled test plus the event appends they call inline:
#   fm_jev_enabled <home> <state>                    - 0 when this home opted in
#   fm_jev_observe <home> <state> <steer|decision> [task]
#                                                    - skipped under FM_JEV_OBSERVE=0,
#                                                      which automated senders set
#   fm_jev_observe_ack <home> <state> <through-seq>
#   fm_jev_observe_turn_end <home> <state> <hook-payload-json>
#   fm_jev_observe_drain <home> <state> <deduped-raw-rows>
#
# Every function is best effort and silent: it never prints, always returns 0
# (except fm_jev_enabled's own answer), and costs one file test when the home
# has not opted in. A Jev problem can therefore never change a caller's output,
# exit status, ordering, or timing, and the classification itself always runs
# detached from the caller.

FM_JEV_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Opt-in is the presence of a non-empty OPENROUTER_API_KEY assignment in this
# home's private .env, and only for the home's own state directory, so a test or
# tool that points STATE elsewhere can never spend this home's key. The value is
# never read here; bin/fm-jev.sh reads it only at request time.
fm_jev_enabled() {  # <home> <state>
  local home=${1:-} state=${2:-}
  [ -n "$home" ] && [ -n "$state" ] || return 1
  [ -f "$home/.env" ] || return 1
  [ "$state" -ef "$home/state" ] || return 1
  grep -Eq "^[[:space:]]*(export[[:space:]]+)?OPENROUTER_API_KEY=[[:space:]]*[\"']?[A-Za-z0-9]" "$home/.env" 2>/dev/null
}

_fm_jev_append() {  # <state> <json-line>
  local dir="$1/jev"
  if [ ! -d "$dir" ]; then
    (umask 077 && mkdir -p "$dir") 2>/dev/null || return 0
  fi
  (umask 077 && printf '%s\n' "$2" >> "$dir/shadow.jsonl") 2>/dev/null || true
  return 0
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
