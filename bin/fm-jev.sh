#!/usr/bin/env bash
# fm-jev.sh - Jev (TypeSafe's decision model on OpenRouter) as a SHADOW-ONLY,
# advisory classifier of supervision wakes, plus the measurement that decides
# whether it may ever do more.
#
# Usage:
#   fm-jev.sh status
#   fm-jev.sh report [--log <file>] [--days <n>] [--min-confidence <p>] [--limit <n>] [--now <epoch>]
#   fm-jev.sh mask                          (stdin -> the masked text that would leave the machine)
#   fm-jev.sh observe-drain <spool> <epoch> (internal: called detached by bin/fm-jev-lib.sh)
#
# Switch. Off by default. A home opts in only by carrying a non-empty
# OPENROUTER_API_KEY in its private, gitignored .env, the same presence gate
# Relay uses for FMX_PAIRING_TOKEN (docs/configuration.md "Jev shadow wake
# triage"). The ambient environment never enables it, and a STATE directory
# other than the home's own never uses it (bin/fm-jev-lib.sh fm_jev_enabled).
# The key is read from .env only at request time, is handed to curl on stdin
# rather than argv, and is never printed, logged, or written anywhere; no other
# .env value is read.
#
# Shadow contract. For every wake row a drain presents, this script asks Jev
# one three-way choice - "firstmate" (needs firstmate), "absorbable", or
# "captain" (urgent for the captain) - and logs the answer next to what
# firstmate actually did. It acts on nothing: it never delays, drops, reorders,
# absorbs, or alters a wake, and nothing reads its answer to decide a merge, a
# destructive or security-sensitive action, or a captain call. The drain hands
# rows over through a detached process (fm_jev_observe_drain), so a slow or
# failing Jev cannot slow or break the wake path.
#
# What leaves the machine: the wake's reason line and the worker's last status
# line, each masked (URLs -> <url>, any token containing a path separator ->
# <path>) and cut to 500 characters, plus this script's fixed question text.
# Nothing else is sent. `mask` prints exactly the masking applied.
#
# Limits. Each request has a hard 2 second timeout. A daily spend cap (USD,
# default 1; override with a decimal number in config/jev-daily-cap) is summed
# from the usage.cost each response reports. A timeout, an API or transport
# error, a response without a cost, or reaching the cap pauses classification
# until the next local calendar day (state/jev/disabled). The wake itself is
# untouched in every case because shadow mode never held it.
#
# Private log: state/jev/shadow.jsonl, append-only, mode 0600, one JSON object
# per line:
#   {"ev":"presented","t","id":"<epoch>:<seq>","seq","kind","task","batch"}
#   {"ev":"jev","t","day","id","outcome":"classified"|"skipped",
#    "choice","confidence","probabilities","cost","ms","model",
#    "why","reason","status"}         (reason/status are the masked text)
#   {"ev":"steer"|"decision","t","task"} from bin/fm-send.sh, bin/fm-control.sh,
#                                        bin/fm-captain-hold.sh
#   {"ev":"ack","t","through"}           from bin/fm-wake-drain.sh --ack-through
#   {"ev":"turn_end","t","outcome":"ack"|"message"|"unknown"}
#                                        from bin/fm-turnend-guard.sh
#   {"ev":"disabled","t","day","why"}
#
# Ground truth (report). A presented wake "needed firstmate" when its handling
# turn - from its first presentation through the first turn end after the
# acknowledgement that covers it - produced a steer or a decision attributed to
# it, and "captain" when that turn ended in a captain-facing message; it was
# "absorbable" when the turn ended with the plain acknowledgement
# ("Captain, shipshape." or no final text) and nothing else happened. A wake is
# open from its first presentation through that turn end (or its acknowledgement
# when no turn end was recorded, or indefinitely while it is unacknowledged), and
# every presented wake in the log counts as open, not only those the report
# window lists. A steer or decision naming a task attributes
# only to that task's open wakes, from any drain; an unnamed one, or one naming a
# task with no open wake, attributes to every open wake and is flagged shared. A
# captain message attributes to every wake whose handling turn it ends, flagged
# shared when that is more than one wake. Shared attributions only ever make
# the truth stricter. A turn end whose harness payload has no
# last_assistant_message, or a wake never acknowledged, leaves the truth
# unknown and excluded from agreement.
#
# The report prints, over the window: agreement between "Jev would absorb" and
# "the wake was absorbable"; the count of wakes Jev would have absorbed that
# actually needed firstmate (must be zero for go-live); a three-way breakdown;
# the go-live criteria (zero wrongly absorbable, at least 90% agreement, one
# week of data); and up to --limit (default 20) doubtful cases for the captain.
# An answer below --min-confidence (default 0.6) or outside the three options
# counts as doubt, which surfaces, like every skipped request.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-x-lib.sh
. "$SCRIPT_DIR/fm-x-lib.sh"
# shellcheck source=bin/fm-jev-lib.sh
. "$SCRIPT_DIR/fm-jev-lib.sh"

CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
JEV_DIR="$STATE/jev"
JEV_LOG="$JEV_DIR/shadow.jsonl"
JEV_DISABLED="$JEV_DIR/disabled"
JEV_LOCK="$JEV_DIR/.classify.lock"
JEV_MODEL=typesafe/jev-1.13
JEV_ENDPOINT=https://openrouter.ai/api/alpha/decisions
JEV_TIMEOUT=2
JEV_DEFAULT_CAP=1

# The single definition of what may leave the machine; `mask` exposes it.
JEV_JQ_MASK='def fm_jev_mask:
  gsub("[A-Za-z][A-Za-z0-9+.-]*://[^\\s]+"; "<url>")
  | gsub("[^\\s]*[/\\\\][^\\s]*"; "<path>")
  | .[0:500];'

usage() {
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
}

die() {
  printf 'fm-jev: %s\n' "$*" >&2
  exit 2
}

jev_now_ms() {
  if [ -n "${EPOCHREALTIME:-}" ]; then
    local r=${EPOCHREALTIME/,/.}
    printf '%s\n' "$(( ${r%.*} * 1000 + 10#$(printf '%.3s' "${r#*.}000") ))"
  else
    printf '%s\n' "$(( $(date +%s) * 1000 ))"
  fi
}

jev_cap() {
  local v
  v=
  [ -f "$CONFIG/jev-daily-cap" ] && v=$(tr -d '[:space:]' < "$CONFIG/jev-daily-cap" 2>/dev/null)
  if [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    printf '%s\n' "$v"
  else
    printf '%s\n' "$JEV_DEFAULT_CAP"
  fi
}

jev_spend_today() {  # <day>
  [ -f "$JEV_LOG" ] || { printf '0\n'; return 0; }
  jq -n -R --arg d "$1" '
    [inputs | fromjson? | select(type == "object" and .ev == "jev" and .day == $d)
      | (.cost // 0) | select(type == "number")] | add // 0' "$JEV_LOG" 2>/dev/null || printf '0\n'
}

jev_ge() {  # <a> <b> -> 0 when a >= b
  awk -v a="$1" -v b="$2" 'BEGIN { exit !((a + 0) >= (b + 0)) }'
}

jev_paused_today() {  # <day> -> 0 when classification is paused for <day>
  local day
  [ -f "$JEV_DISABLED" ] || return 1
  day=$(cut -f1 < "$JEV_DISABLED" 2>/dev/null) || return 1
  [ "$day" = "$1" ]
}

jev_pause() {  # <day> <why>
  (umask 077 && printf '%s\t%s\n' "$1" "$2" > "$JEV_DISABLED") 2>/dev/null || true
  _fm_jev_append "$STATE" "$(jq -cn --argjson t "$(date +%s)" --arg day "$1" --arg why "$2" \
    '{ev: "disabled", t: $t, day: $day, why: $why}')"
}

jev_mask() {
  jq -R -r "$JEV_JQ_MASK"' fm_jev_mask'
}

# The task a wake row is about, when this home can name it: the status or
# turn-ended file of a signal, the check script of a check, the window a task's
# metadata records for a stale wake.
jev_task_for_row() {  # <kind> <key>
  local kind=$1 key=$2 task='' meta
  case "$kind" in
    signal) task=${key%.status}; task=${task%.turn-ended} ;;
    check) task=$(basename "$key" .check.sh) ;;
    stale)
      meta=$(grep -lxF "window=$key" "$STATE"/*.meta 2>/dev/null | head -n1) || meta=
      [ -z "$meta" ] || task=$(basename "$meta" .meta)
      ;;
  esac
  case "$task" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  if [ -f "$STATE/$task.status" ] || [ -f "$STATE/$task.meta" ]; then
    printf '%s\n' "$task"
  fi
}

jev_last_status() {  # <task>
  [ -n "$1" ] && [ -f "$STATE/$1.status" ] || return 0
  tail -n 50 "$STATE/$1.status" 2>/dev/null | awk 'NF { l = $0 } END { print l }'
}

jev_log_skip() {  # <id> <why> <detail> <reason> <status>
  _fm_jev_append "$STATE" "$(jq -cn --argjson t "$(date +%s)" --arg day "$(date +%F)" \
    --arg id "$1" --arg why "$2" --arg detail "$3" --arg reason "$4" --arg status "$5" \
    '{ev: "jev", t: $t, day: $day, id: $id, outcome: "skipped", why: $why, detail: $detail,
      reason: $reason, status: $status}')"
}

jev_request_body() {  # <reason> <status>
  jq -cn --arg model "$JEV_MODEL" --arg r "$1" --arg s "$2" '{
    model: $model,
    state: ({wake_reason: $r} + (if $s == "" then {} else {worker_last_status: $s} end)),
    questions: {
      handling: {
        type: "choice",
        instructions: "A supervisor agent (firstmate) coordinates autonomous coding workers and reports to a human captain. This wake notification just arrived. How must it be handled?",
        criteria: {
          firstmate: "Firstmate must act: steer, answer, unblock or recover a worker, review or land its work, or otherwise do something beyond acknowledging.",
          absorbable: "Routine, duplicate or informational progress with nothing to do: firstmate would only acknowledge it.",
          captain: "The captain must hear about it now: a decision only the captain can make, work ready for review, a real failure, a needed credential or login, or anything destructive or security-sensitive."
        }
      }
    }
  }'
}

# One request. Prints nothing; logs a classified or skipped event and pauses
# for the day on timeout, API error, missing cost, or the cap.
jev_classify_row() {  # <id> <reason-masked> <status-masked> <spend-before> <cap>
  local id=$1 reason=$2 status=$3 spend=$4 cap=$5 day key body resp code rc start ms cost event
  day=$(date +%F)
  key=$(fmx_env_get OPENROUTER_API_KEY "$FM_HOME/.env")
  case "$key" in
    ''|*[!A-Za-z0-9._-]*)
      key=
      jev_log_skip "$id" api-error "unusable OPENROUTER_API_KEY value" "$reason" "$status"
      jev_pause "$day" api-error
      return 0
      ;;
  esac
  body=$(umask 077 && mktemp "$JEV_DIR/.body.XXXXXX") || return 0
  resp=$(umask 077 && mktemp "$JEV_DIR/.resp.XXXXXX") || { rm -f "$body"; return 0; }
  jev_request_body "$reason" "$status" > "$body" || { rm -f "$body" "$resp"; return 0; }
  start=$(jev_now_ms)
  rc=0
  code=$(printf 'header = "Authorization: Bearer %s"\n' "$key" \
    | curl -sS -K - --max-time "$JEV_TIMEOUT" --connect-timeout "$JEV_TIMEOUT" \
        -H 'Content-Type: application/json' --data-binary "@$body" \
        -o "$resp" -w '%{http_code}' "$JEV_ENDPOINT" 2>/dev/null) || rc=$?
  key=
  ms=$(( $(jev_now_ms) - start ))
  rm -f "$body"
  if [ "$rc" -eq 28 ]; then
    rm -f "$resp"
    jev_log_skip "$id" timeout "no answer within ${JEV_TIMEOUT}s" "$reason" "$status"
    jev_pause "$day" timeout
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    rm -f "$resp"
    jev_log_skip "$id" api-error "transport error (curl exit $rc)" "$reason" "$status"
    jev_pause "$day" api-error
    return 0
  fi
  case "$code" in
    2??) ;;
    *)
      rm -f "$resp"
      jev_log_skip "$id" api-error "HTTP $code" "$reason" "$status"
      jev_pause "$day" api-error
      return 0
      ;;
  esac
  cost=$(jq -r '.usage.cost | select(type == "number")' "$resp" 2>/dev/null) || cost=
  if [ -z "$cost" ]; then
    rm -f "$resp"
    jev_log_skip "$id" api-error "response carried no usage.cost" "$reason" "$status"
    jev_pause "$day" api-error
    return 0
  fi
  event=$(jq -c --argjson t "$(date +%s)" --arg day "$day" --arg id "$id" --argjson ms "$ms" \
    --arg reason "$reason" --arg status "$status" '
    (.answers.handling // {}) as $a
    | {ev: "jev", t: $t, day: $day, id: $id, outcome: "classified",
       choice: (if ($a.choice | type) == "string" and (["firstmate", "absorbable", "captain"] | index($a.choice)) != null
                then $a.choice else "doubt" end),
       confidence: ($a.confidence | if type == "number" then . else null end),
       probabilities: ($a.probabilities | if type == "object" then . else null end),
       cost: .usage.cost, ms: $ms, model: (.model // null),
       reason: $reason, status: $status}' "$resp" 2>/dev/null) || event=
  rm -f "$resp"
  if [ -z "$event" ]; then
    jev_log_skip "$id" api-error "unreadable response" "$reason" "$status"
    jev_pause "$day" api-error
    return 0
  fi
  _fm_jev_append "$STATE" "$event"
  JEV_SPEND=$(awk -v a="$spend" -v b="$cost" 'BEGIN { printf "%.9f", a + b }')
  if jev_ge "$JEV_SPEND" "$cap"; then
    jev_pause "$day" cap
  fi
}

cmd_observe_drain() {  # <spool> <epoch>
  local spool=${1:-} now=${2:-} batch epoch seq kind key payload id task reason status day cap
  [ -n "$spool" ] && [ -f "$spool" ] || exit 0
  case "$now" in ''|*[!0-9]*) now=$(date +%s) ;; esac
  batch=$(basename "$spool")
  batch=${batch#.spool.}
  fm_jev_enabled "$FM_HOME" "$STATE" || { rm -f "$spool"; exit 0; }
  command -v jq >/dev/null 2>&1 || { rm -f "$spool"; exit 0; }

  while IFS=$(printf '\t') read -r epoch seq kind key payload; do
    case "$epoch:$seq" in *[!0-9:]*|:*|*:) continue ;; esac
    task=$(jev_task_for_row "$kind" "$key")
    _fm_jev_append "$STATE" "$(jq -cn --argjson t "$now" --arg id "$epoch:$seq" --argjson seq "$seq" \
      --arg kind "$kind" --arg task "$task" --arg batch "$batch" \
      '{ev: "presented", t: $t, id: $id, seq: $seq, kind: $kind, task: $task, batch: $batch}')"
  done < "$spool"

  fm_lock_acquire_wait "$JEV_LOCK" || { rm -f "$spool"; exit 0; }
  day=$(date +%F)
  cap=$(jev_cap)
  JEV_SPEND=$(jev_spend_today "$day")
  while IFS=$(printf '\t') read -r epoch seq kind key payload; do
    case "$epoch:$seq" in *[!0-9:]*|:*|*:) continue ;; esac
    id="$epoch:$seq"
    if [ -f "$JEV_LOG" ] && grep -qF "\"ev\":\"jev\",\"t\":" "$JEV_LOG" \
      && jq -n -R -e --arg id "$id" \
        'any(inputs | fromjson? | select(type == "object"); .ev == "jev" and .id == $id)' \
        "$JEV_LOG" >/dev/null 2>&1; then
      continue
    fi
    task=$(jev_task_for_row "$kind" "$key")
    reason=$(printf '%s' "$payload" | jev_mask)
    status=$(jev_last_status "$task" | jev_mask)
    if jev_paused_today "$day"; then
      jev_log_skip "$id" disabled "$(cut -f2 < "$JEV_DISABLED" 2>/dev/null)" "$reason" "$status"
      continue
    fi
    if jev_ge "$JEV_SPEND" "$cap"; then
      jev_pause "$day" cap
      jev_log_skip "$id" cap "daily cap of USD $cap reached" "$reason" "$status"
      continue
    fi
    jev_classify_row "$id" "$reason" "$status" "$JEV_SPEND" "$cap"
  done < "$spool"
  fm_lock_release "$JEV_LOCK"
  rm -f "$spool"
}

cmd_status() {
  local day cap spend
  day=$(date +%F)
  if fm_jev_enabled "$FM_HOME" "$STATE"; then
    printf 'Jev shadow triage: on (OPENROUTER_API_KEY present in %s/.env)\n' "$FM_HOME"
  else
    printf 'Jev shadow triage: off (no OPENROUTER_API_KEY in %s/.env)\n' "$FM_HOME"
  fi
  cap=$(jev_cap)
  spend=$(awk -v s="$(jev_spend_today "$day")" 'BEGIN { printf "%.6f", s }')
  printf 'spend today: USD %s of a USD %s daily cap\n' "$spend" "$cap"
  if jev_paused_today "$day"; then
    printf 'paused until tomorrow: %s\n' "$(cut -f2 < "$JEV_DISABLED")"
  fi
  printf 'shadow log: %s\n' "$JEV_LOG"
}

# shellcheck disable=SC2016 # a jq program; its $names are jq variables, not shell ones.
JEV_JQ_REPORT='
def pct(a; b): if b == 0 then "n/a" else ((a * 1000 / b | round) / 10 | tostring) + "%" end;
def iso: todate;
def jev_label($minconf):
  if . == null then "none"
  elif .outcome != "classified" then "skipped"
  elif .choice == "doubt" then "doubt"
  elif (.confidence // 0) < $minconf then "doubt"
  else .choice end;

[ .[] | select(type == "object" and (.t | type) == "number") ]
| to_entries | map(.value + {i: .key}) | sort_by([.t, .i])
| to_entries | map(.value + {o: .key}) as $all
| ($all | map(select(.ev == "presented")) | group_by(.id) | map(min_by(.o))) as $wakes
| ($all | map(select(.ev == "jev")) | group_by(.id) | map({key: .[0].id, value: .[0]}) | from_entries) as $jev
| [ $wakes[] as $w
    | ($all | map(select(.ev == "ack" and .o > $w.o and .through >= $w.seq)) | first) as $ack
    | (if $ack == null then null
       else ($all | map(select(.ev == "turn_end" and .o > $ack.o)) | first) end) as $te
    | $w + {ack: $ack, te: $te,
            end: (if $ack == null then null elif $te == null then $ack.o else $te.o end)} ] as $wins
| ([ $all[] | select(.ev == "steer" or .ev == "decision") as $a
     | ($wins | map(select($a.o > .o and (.end == null or $a.o <= .end)))) as $open
     | ($open | map(select($a.task != "" and .task == $a.task))) as $named
     | if ($named | length) > 0 then ($named[] | {key: .id, ev: $a.ev, shared: false})
       else ($open[] | {key: .id, ev: $a.ev, shared: true}) end ]
   | group_by(.key) | map({key: .[0].key, value: map(del(.key))}) | from_entries) as $credit
| [ $wins[] | select(.t >= $since and .t <= $now) as $w
    | $w.ack as $ack | $w.te as $te
    | ($credit[$w.id] // []) as $mine
    | (if $ack == null then {truth: "unknown", why: "never acknowledged"}
       elif ($te != null and $te.outcome == "message") then
         {truth: "captain", why: "turn ended in a captain message",
          shared: (($wins | map(select(.te != null and .te.o == $te.o)) | length) > 1)}
       elif ($mine | length) > 0 then
         {truth: "firstmate", why: ($mine | map(.ev) | unique | join("+")), shared: ($mine | any(.shared))}
       elif $te == null then {truth: "unknown", why: "no turn end recorded"}
       elif $te.outcome == "unknown" then {truth: "unknown", why: "harness did not report the final message"}
       else {truth: "absorbable", why: "plain acknowledgement"} end) as $truth
    | ($jev[$w.id]) as $j
    | ($j | jev_label($minconf)) as $lab
    | {id: $w.id, t: $w.t, seq: $w.seq, kind: $w.kind, task: $w.task,
       truth: $truth.truth, why: $truth.why, shared: ($truth.shared // false),
       jev: $lab, conf: ($j.confidence // null), skip: ($j.why // null),
       reason: ($j.reason // ""), status: ($j.status // "")}
    | . + {scored: ((.jev | IN("absorbable", "firstmate", "captain", "doubt")) and .truth != "unknown")}
    | . + {absorb: (.jev == "absorbable")}
    | . + {agree: (.scored and (.absorb == (.truth == "absorbable"))),
           wrong: (.scored and .absorb and (.truth != "absorbable"))}
    | . + {prio: (if .wrong then 1
                  elif .scored and (.agree | not) then 2
                  elif .jev == "doubt" then 3
                  elif .shared and .scored then 4
                  elif .truth == "unknown" and .jev != "skipped" and .jev != "none" then 5
                  else 9 end)}
  ] as $rows
| ($rows | map(select(.scored))) as $scored
| ($scored | map(select(.agree)) | length) as $agree
| ($rows | map(select(.wrong)) | length) as $wrong
| ($scored | map(select(.jev != "doubt" and .jev == .truth)) | length) as $three
| (if ($rows | length) == 0 then 0 else (($rows | map(.t) | max) - ($rows | map(.t) | min)) / 86400 end) as $span
| ($rows | map(select(.jev == "skipped")) | group_by(.skip) | map("\(.[0].skip) \(length)") | join(", ")) as $skips
| [
  "Jev shadow report, \($since | iso) to \($now | iso)",
  "wakes presented: \($rows | length); classified: \($rows | map(select(.jev | IN("absorbable", "firstmate", "captain", "doubt"))) | length); skipped: \($rows | map(select(.jev == "skipped")) | length)\(if $skips == "" then "" else " (" + $skips + ")" end); not sent: \($rows | map(select(.jev == "none")) | length); actual handling known: \($rows | map(select(.truth != "unknown")) | length)",
  "agreement (absorb vs surface): \(pct($agree; $scored | length)) (\($agree) of \($scored | length))",
  "wrongly absorbable (Jev would absorb, firstmate had to act): \($wrong)",
  "three-way agreement: \(pct($three; $scored | length))",
  "breakdown, Jev answer -> actual handling (absorbable/firstmate/captain/unknown):",
  ( ["absorbable", "firstmate", "captain", "doubt", "skipped", "none"][] as $l
    | ($rows | map(select(.jev == $l))) as $r
    | select(($r | length) > 0)
    | "  \($l): \(["absorbable", "firstmate", "captain", "unknown"] | map(. as $t | $r | map(select(.truth == $t)) | length) | map(tostring) | join("/"))" ),
  "go-live criteria: zero wrongly absorbable \(if $wrong == 0 then "met" else "NOT met" end); agreement at least 90% \(if ($scored | length) > 0 and ($agree * 100 >= 90 * ($scored | length)) then "met" else "NOT met" end); one week of shadow data \(if $span >= 7 then "met" else "NOT met (\($span * 10 | floor / 10) days)" end)",
  ( ($rows | map(select(.prio < 9)) | sort_by([.prio, -.t]) | .[:$limit]) as $d
    | if ($d | length) == 0 then "doubtful cases: none"
      else "doubtful cases for the captain (\($d | length), most important first):",
        ( $d | to_entries[] | .key as $k | .value
          | "  \($k + 1). \(.t | iso) \(.kind) seq \(.seq)\(if .task != "" then " task " + .task else "" end): Jev \(.jev)\(if .conf != null then " (" + (.conf | tostring) + ")" else "" end), actual \(.truth) (\(.why))\(if .shared then ", shared with other open wakes" else "" end)\(if .reason != "" then " | wake: " + .reason else "" end)\(if .status != "" then " | worker: " + .status else "" end)" )
      end )
] | .[]
'

cmd_report() {
  local log=$JEV_LOG days=7 minconf=0.6 limit=20 now since
  now=$(date +%s)
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --log) [ "$#" -ge 2 ] || die "--log needs a file"; log=$2; shift 2 ;;
      --days) [ "$#" -ge 2 ] || die "--days needs a number"; days=$2; shift 2 ;;
      --min-confidence) [ "$#" -ge 2 ] || die "--min-confidence needs a number"; minconf=$2; shift 2 ;;
      --limit) [ "$#" -ge 2 ] || die "--limit needs a number"; limit=$2; shift 2 ;;
      --now) [ "$#" -ge 2 ] || die "--now needs an epoch"; now=$2; shift 2 ;;
      *) die "unknown report option: $1" ;;
    esac
  done
  case "$days" in ''|*[!0-9]*) die "--days must be a whole number" ;; esac
  case "$limit" in ''|*[!0-9]*) die "--limit must be a whole number" ;; esac
  case "$now" in ''|*[!0-9]*) die "--now must be an epoch" ;; esac
  [[ "$minconf" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "--min-confidence must be a number such as 0.6"
  [ -f "$log" ] || die "no shadow log at $log"
  command -v jq >/dev/null 2>&1 || die "jq is required"
  since=$((now - days * 86400))
  jq -n -R -r --argjson now "$now" --argjson since "$since" --argjson minconf "$minconf" \
    --argjson limit "$limit" "[inputs | fromjson?] | $JEV_JQ_REPORT" "$log"
}

case "${1:-}" in
  status) shift; cmd_status "$@" ;;
  report) shift; cmd_report "$@" ;;
  mask) shift; command -v jq >/dev/null 2>&1 || die "jq is required"; jev_mask ;;
  observe-drain) shift; cmd_observe_drain "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
