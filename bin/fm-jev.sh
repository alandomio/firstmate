#!/usr/bin/env bash
# fm-jev.sh - Jev (TypeSafe's decision model on OpenRouter, or a local
# Rizzo Flow server) as a SHADOW-ONLY, advisory classifier of supervision
# wakes, plus the measurement that decides whether it may ever do more, plus
# (config/jev-absorb) the gated absorption that measurement can eventually earn.
#
# Usage:
#   fm-jev.sh status
#   fm-jev.sh report [--log <file>] [--days <n>] [--min-confidence <p>] [--limit <n>] [--now <epoch>]
#   fm-jev.sh absorb-gate [--log <file>] [--days <n>] [--min-confidence <p>] [--min-sample <n>] [--now <epoch>] [--json]
#   fm-jev.sh absorb-try --kind signal|stale --task <id> --reason <text>
#                                            (internal: called synchronously by bin/fm-watch.sh)
#   fm-jev.sh mask                          (stdin -> the masked text that would leave the machine)
#   fm-jev.sh observe-drain <spool> <epoch> (internal: called detached by bin/fm-jev-lib.sh)
#
# Absorption (config/jev-absorb). Off by default, and a wholly separate act
# from the shadow measurement above: shadow mode only ever WATCHES and never
# changes what a drain presents. Absorption lets bin/fm-watch.sh skip queuing
# (and waking the supervising session for) a wake at exactly two allowlisted
# call sites - a routine working/paused "signal" wake whose crew is not
# provably working, and a declared-pause "stale" recheck - never a
# needs-decision, blocked, done, failed, merge/check result, heartbeat,
# captain inbox note, Relay or process-event wake, and never a task with any
# open decision. It requires ALL of:
#   - `config/jev-absorb`'s first non-blank line is exactly "on";
#   - the LOCAL backend specifically (never OpenRouter - absorption changes
#     real behavior, so it never runs on a request that could leave the
#     machine), with config/jev-endpoint a valid loopback URL;
#   - config/jev-absorb-threshold (default 0.9) is a number no lower than 0.9;
#   - EITHER the go-live gate (absorb-gate above; see its own header for the
#     exact criteria) is met, OR `config/jev-absorb`'s second non-blank line
#     is exactly "override" - a captain override that skips the measured gate
#     but never the other requirements above;
#   - for THIS wake: the Rizzo native answer's status is "ok", its choice is
#     "absorbable", and its top probability is at or above the threshold.
# Any doubt anywhere in that chain - disabled, ineligible, an unmet gate, a
# classifier timeout, error, or low-confidence answer - falls through to
# today's unconditional behavior; absorb-try's own header owns the exact
# rules. Absorption adds no latency beyond the existing per-request classify
# timeout, and only for a wake it might absorb: the go-live gate's own
# (separately bounded) computation is cached (state/jev/.absorb-gate-cache)
# rather than re-scanned on every wake.
# Nothing is lost: every absorbed wake is appended, masked, to
# state/jev/absorbed.jsonl (bin/fm-jev-lib.sh's fm_jev_absorb_digest_surface),
# which bin/fm-wake-drain.sh prints - count plus one line each - the next time
# ANY drain runs, whether that is a real wake or a heartbeat, so nothing
# absorbed can rot unseen and no absorption itself ever wakes the supervising
# session on its own.
#
# Switch. Off by default, and only one backend runs per home. A home opts into
# the OpenRouter backend by carrying a non-empty OPENROUTER_API_KEY in its
# private, gitignored .env, the same presence gate Relay uses for
# FMX_PAIRING_TOKEN (docs/configuration.md "Jev shadow wake triage"); the
# ambient environment never enables it, no other .env value is read, and the
# key is read from .env only at request time, handed to curl on stdin rather
# than argv, and never printed, logged, or written anywhere. A home opts into
# the LOCAL backend instead by carrying a base URL in its private, gitignored
# config/jev-endpoint - a Rizzo Flow server (`rizzo serve`), which must
# expose Rizzo Flow's native typed-decision API (POST /v1/decisions, on
# 127.0.0.1:8017 by default; see the rizzo-flow skill) - a server offering
# only the Jev-compatible /v1/systemone answers every row as an api-error.
# That file takes priority when present: no key is read or required for it. A STATE directory
# other than the home's own never uses either backend (bin/fm-jev-lib.sh
# fm_jev_backend/fm_jev_enabled).
#
# Loopback-only enforcement. config/jev-endpoint must resolve to
# 127.0.0.1/localhost/::1 with no path (jev_local_url_ok); anything else is
# refused outright rather than dialed, logged as a skipped "invalid-endpoint"
# row, and pauses classification for the day - the one local-backend
# condition that still does (see Limits) - this file must never become a
# back door to a hosted API.
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
# Nothing else is sent. `mask` prints exactly the masking applied. For the
# local backend nothing leaves the machine at all (no egress); masking is kept
# anyway for prompt-length hygiene, not data governance.
#
# Limits. Each request, on either backend, has a hard timeout (default 5
# seconds; override with a positive number in config/jev-timeout, an invalid
# value keeps the default and `status` says so) - warm local requests measured
# well under a second, so the 5 second default still stops a stuck local
# server hanging the classify loop. The OpenRouter backend pauses
# classification until the next local calendar day (state/jev/disabled) on
# its timeout, an API/transport error, a response without a usage.cost, or
# reaching its daily spend cap (USD, default 1; override with a decimal
# number in config/jev-daily-cap), summed from the usage.cost each response
# reports - unchanged. The local backend has no per-request cost and no
# monotonic quota to protect, so none of its own failure reasons ever pauses
# it for the day: a 1-minute load average at or above config/jev-max-load
# (default 8; checked before each request), a timeout, or an API/transport
# error each only skip that one row (why=load/timeout/api-error), and the
# very next drain tries again. A timeout also skips the rest of that same
# drain's rows (why=timeout) without dialing, so a stuck server costs one
# timeout per drain rather than one per row, and the classify lock is never
# held long enough for detached drains to pile up behind it. The sole exception is an invalid
# config/jev-endpoint, which still pauses the local backend for the day
# because that is a configuration mistake to surface, not a transient
# condition to retry. The wake itself is untouched in every case because
# shadow mode never held it.
#
# The local backend asks through Rizzo Flow's native /v1/decisions API (the
# rizzo-flow skill's references/api.md) rather than the Jev-compatible
# /v1/systemone the OpenRouter backend still uses, with allow_abstain and a
# policy.min_top_probability of 0.6 (JEV_LOCAL_MIN_TOP_PROBABILITY, matching
# `report`'s own --min-confidence default): a response the server itself
# could not decide (status insufficient_evidence) or answered under that
# confidence floor (status uncertain) carries no choice, which this script
# logs as "doubt" exactly like a low-confidence OpenRouter answer.
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
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
JEV_DIR="$STATE/jev"
JEV_LOG="$JEV_DIR/shadow.jsonl"
JEV_DISABLED="$JEV_DIR/disabled"
JEV_LOCK="$JEV_DIR/.classify.lock"
JEV_OR_MODEL=typesafe/jev-1.13
JEV_OR_ENDPOINT=https://openrouter.ai/api/alpha/decisions
JEV_DEFAULT_TIMEOUT=5
JEV_DEFAULT_CAP=1
JEV_DEFAULT_MAX_LOAD=8
JEV_LOCAL_MIN_TOP_PROBABILITY=0.6
JEV_ABSORB_THRESHOLD_DEFAULT=0.9
JEV_ABSORB_MIN_SAMPLE_DEFAULT=300
JEV_ABSORB_GATE_DAYS_DEFAULT=30
JEV_ABSORB_GATE_CACHE_TTL=300
JEV_ABSORB_GATE_TIMEOUT=${FM_JEV_ABSORB_GATE_TIMEOUT:-10}

# The single definition of what may leave the machine; `mask` exposes it.
JEV_JQ_MASK='def fm_jev_mask:
  gsub("[A-Za-z][A-Za-z0-9+.-]*://[^\\s]+"; "<url>")
  | gsub("[^\\s]*[/\\\\][^\\s]*"; "<path>")
  | .[0:500];'

usage() {
  sed -n '6,13p' "$0" | sed 's/^# \{0,1\}//'
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

jev_timeout_raw() {
  [ -f "$CONFIG/jev-timeout" ] && tr -d '[:space:]' < "$CONFIG/jev-timeout" 2>/dev/null
  return 0
}

jev_timeout_valid() {  # <value> -> 0 when a positive decimal number
  [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk -v a="$1" 'BEGIN { exit !((a + 0) > 0) }'
}

jev_timeout() {
  local v
  v=$(jev_timeout_raw)
  if jev_timeout_valid "$v"; then
    printf '%s\n' "$v"
  else
    printf '%s\n' "$JEV_DEFAULT_TIMEOUT"
  fi
}

jev_max_load() {
  local v
  v=
  [ -f "$FM_HOME/config/jev-max-load" ] && v=$(tr -d '[:space:]' < "$FM_HOME/config/jev-max-load" 2>/dev/null)
  if [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    printf '%s\n' "$v"
  else
    printf '%s\n' "$JEV_DEFAULT_MAX_LOAD"
  fi
}

# 1-minute load average, portable across Linux (/proc/loadavg) and macOS
# (sysctl vm.loadavg); FM_JEV_LOAD_OVERRIDE is a test-only stand-in for both.
jev_load_avg() {
  if [ -n "${FM_JEV_LOAD_OVERRIDE:-}" ]; then
    printf '%s\n' "$FM_JEV_LOAD_OVERRIDE"
  elif [ -r /proc/loadavg ]; then
    awk '{print $1}' /proc/loadavg 2>/dev/null
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}'
  fi
}

# Refuses anything but a bare loopback origin (scheme://host[:port], no path)
# so config/jev-endpoint can never become a back door to a hosted API.
jev_local_url_ok() {  # <base-url>
  printf '%s' "$1" | grep -Eq '^https?://(127\.0\.0\.1|localhost|\[::1\])(:[0-9]+)?/?$'
}

# 0 when config/jev-absorb's first non-blank line requests absorption. Absent,
# empty, or any other content leaves absorption off - the safe default.
jev_absorb_requested() {
  local line
  line=$(grep -v '^[[:space:]]*$' "$CONFIG/jev-absorb" 2>/dev/null | head -n1) || return 1
  [ "$line" = on ]
}

# 0 when config/jev-absorb's second non-blank line is the literal captain
# override that skips the measured go-live gate (never the other
# requirements: still local backend, still a valid threshold, still this
# wake's own classify answer).
jev_absorb_override() {
  local line
  line=$(grep -v '^[[:space:]]*$' "$CONFIG/jev-absorb" 2>/dev/null | sed -n '2p') || return 1
  [ "$line" = override ]
}

# Prints config/jev-absorb-threshold, or the default when absent.
jev_absorb_threshold_raw() {
  [ -f "$CONFIG/jev-absorb-threshold" ] && tr -d '[:space:]' < "$CONFIG/jev-absorb-threshold" 2>/dev/null
  return 0
}

# 0 when <value> is a number no lower than 0.9 - the documented floor: this
# threshold must be calibrated against a home's own shadow report before
# activation, never guessed low.
jev_absorb_threshold_valid() {  # <value>
  [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]] && jev_ge "$1" "$JEV_ABSORB_THRESHOLD_DEFAULT"
}

# Prints the effective threshold, or nothing (exit 1) when config/jev-absorb-threshold
# is present but invalid - a misconfiguration that must fail closed, never
# silently fall back to the default.
jev_absorb_threshold() {
  local v
  v=$(jev_absorb_threshold_raw)
  if [ -z "$v" ]; then
    printf '%s\n' "$JEV_ABSORB_THRESHOLD_DEFAULT"
    return 0
  fi
  jev_absorb_threshold_valid "$v" || return 1
  printf '%s\n' "$v"
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

JEV_HANDLING_INSTRUCTIONS="A supervisor agent (firstmate) coordinates autonomous coding workers and reports to a human captain. This wake notification just arrived. How must it be handled?"
JEV_HANDLING_FIRSTMATE_DESC="Firstmate must act: steer, answer, unblock or recover a worker, review or land its work, or otherwise do something beyond acknowledging."
JEV_HANDLING_ABSORBABLE_DESC="Routine, duplicate or informational progress with nothing to do: firstmate would only acknowledge it."
JEV_HANDLING_CAPTAIN_DESC="The captain must hear about it now: a decision only the captain can make, work ready for review, a real failure, a needed credential or login, or anything destructive or security-sensitive."

# <reason> <status> <model> <backend> - OpenRouter/systemone (any backend but
# "local") sends a top-level model and criteria object; the local backend's
# native /v1/decisions has no model field and wants an options array plus a
# policy asking it to abstain and flag low-confidence answers itself.
jev_request_body() {
  local reason=$1 status=$2 model=$3 backend=$4
  if [ "$backend" = local ]; then
    jq -cn --arg r "$reason" --arg s "$status" --argjson minp "$JEV_LOCAL_MIN_TOP_PROBABILITY" \
      --arg instr "$JEV_HANDLING_INSTRUCTIONS" --arg fm "$JEV_HANDLING_FIRSTMATE_DESC" \
      --arg ab "$JEV_HANDLING_ABSORBABLE_DESC" --arg cap "$JEV_HANDLING_CAPTAIN_DESC" '{
      state: ({wake_reason: $r} + (if $s == "" then {} else {worker_last_status: $s} end)),
      questions: {
        handling: {
          type: "choice",
          instructions: $instr,
          options: [
            {id: "firstmate", description: $fm},
            {id: "absorbable", description: $ab},
            {id: "captain", description: $cap}
          ],
          policy: {allow_abstain: true, min_top_probability: $minp}
        }
      }
    }'
  else
    jq -cn --arg model "$model" --arg r "$reason" --arg s "$status" \
      --arg instr "$JEV_HANDLING_INSTRUCTIONS" --arg fm "$JEV_HANDLING_FIRSTMATE_DESC" \
      --arg ab "$JEV_HANDLING_ABSORBABLE_DESC" --arg cap "$JEV_HANDLING_CAPTAIN_DESC" '{
      model: $model,
      state: ({wake_reason: $r} + (if $s == "" then {} else {worker_last_status: $s} end)),
      questions: {
        handling: {
          type: "choice",
          instructions: $instr,
          criteria: {firstmate: $fm, absorbable: $ab, captain: $cap}
        }
      }
    }'
  fi
}

# One synchronous request against the LOCAL backend only, for absorb-try.
# Deliberately separate from jev_classify_row below: this call must never touch
# shadow.jsonl, the daily-pause state, or the id/day bookkeeping that owns the
# report's ground-truth pairing, because it runs BEFORE a wake is ever queued
# and so has no wake id to pair against. It shares jev_request_body (the one
# owner of the wire format) and the same bounded timeout as every other Jev
# request. Prints "<status>\t<choice>\t<confidence>" on any readable answer
# (confidence -1 when the response carried none); prints nothing and returns 1
# on a timeout, a transport error, a non-2xx response, or an unreadable body -
# every one of those must fall through, never raise an error.
jev_dial_local() {  # <reason-masked> <status-masked> <endpoint-base> <timeout>
  local reason=$1 status=$2 base=$3 timeout=$4 endpoint body resp code rc event
  endpoint="${base%/}/v1/decisions"
  body=$(umask 077 && mktemp "$JEV_DIR/.body.XXXXXX") || return 1
  resp=$(umask 077 && mktemp "$JEV_DIR/.resp.XXXXXX") || { rm -f "$body"; return 1; }
  jev_request_body "$reason" "$status" "" local > "$body" || { rm -f "$body" "$resp"; return 1; }
  rc=0
  code=$(curl -q --noproxy '*' -sS --max-time "$timeout" --connect-timeout "$timeout" \
      -H 'Content-Type: application/json' --data-binary "@$body" \
      -o "$resp" -w '%{http_code}' "$endpoint" 2>/dev/null) || rc=$?
  rm -f "$body"
  if [ "$rc" -ne 0 ]; then
    rm -f "$resp"
    return 1
  fi
  case "$code" in
    2??) ;;
    *) rm -f "$resp"; return 1 ;;
  esac
  event=$(jq -r '
    (.answers.handling // {}) as $a
    | ($a.status // "error") as $st
    | ($a.choice // "") as $ch
    | (if ($a.confidence | type) == "number" then $a.confidence
       elif ($a.uncertainty.top_probability | type) == "number" then $a.uncertainty.top_probability
       else -1 end) as $conf
    | "\($st)\t\($ch)\t\($conf)"' "$resp" 2>/dev/null) || event=
  rm -f "$resp"
  [ -n "$event" ] || return 1
  printf '%s\n' "$event"
}

# One request against either backend. Prints nothing; logs a classified or
# skipped event. Only the OpenRouter backend ever pauses for the day here
# (timeout, API error, or a missing cost); the local backend only skips this
# one row on any of those (a timeout also sets JEV_LOCAL_TIMED_OUT so the
# caller skips the rest of this drain), and the caller applies its
# load-ceiling skip before ever calling this.
jev_classify_row() {  # <id> <reason-masked> <status-masked> <backend> <spend-before> <cap>
  local id=$1 reason=$2 status=$3 backend=$4 spend=$5 cap=$6
  local day key model endpoint timeout body resp code rc start ms cost event
  day=$(date +%F)
  timeout=$JEV_TIMEOUT
  if [ "$backend" = local ]; then
    key=
    model=
    endpoint=$JEV_LOCAL_ENDPOINT
  else
    key=$(fmx_env_get OPENROUTER_API_KEY "$FM_HOME/.env")
    case "$key" in
      ''|*[!A-Za-z0-9._-]*)
        key=
        jev_log_skip "$id" api-error "unusable OPENROUTER_API_KEY value" "$reason" "$status"
        jev_pause "$day" api-error
        return 0
        ;;
    esac
    model=$JEV_OR_MODEL
    endpoint=$JEV_OR_ENDPOINT
  fi
  body=$(umask 077 && mktemp "$JEV_DIR/.body.XXXXXX") || return 0
  resp=$(umask 077 && mktemp "$JEV_DIR/.resp.XXXXXX") || { rm -f "$body"; return 0; }
  jev_request_body "$reason" "$status" "$model" "$backend" > "$body" || { rm -f "$body" "$resp"; return 0; }
  start=$(jev_now_ms)
  rc=0
  if [ -n "$key" ]; then
    code=$(printf 'header = "Authorization: Bearer %s"\n' "$key" \
      | curl -sS -K - --max-time "$timeout" --connect-timeout "$timeout" \
          -H 'Content-Type: application/json' --data-binary "@$body" \
          -o "$resp" -w '%{http_code}' "$endpoint" 2>/dev/null) || rc=$?
  else
    code=$(curl -q --noproxy '*' -sS --max-time "$timeout" --connect-timeout "$timeout" \
        -H 'Content-Type: application/json' --data-binary "@$body" \
        -o "$resp" -w '%{http_code}' "$endpoint" 2>/dev/null) || rc=$?
  fi
  key=
  ms=$(( $(jev_now_ms) - start ))
  rm -f "$body"
  if [ "$rc" -eq 28 ]; then
    rm -f "$resp"
    jev_log_skip "$id" timeout "no answer within ${timeout}s" "$reason" "$status"
    if [ "$backend" = local ]; then
      JEV_LOCAL_TIMED_OUT=1
    else
      jev_pause "$day" timeout
    fi
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    rm -f "$resp"
    jev_log_skip "$id" api-error "transport error (curl exit $rc)" "$reason" "$status"
    [ "$backend" = local ] || jev_pause "$day" api-error
    return 0
  fi
  case "$code" in
    2??) ;;
    *)
      rm -f "$resp"
      jev_log_skip "$id" api-error "HTTP $code" "$reason" "$status"
      [ "$backend" = local ] || jev_pause "$day" api-error
      return 0
      ;;
  esac
  cost=$(jq -r '.usage.cost | select(type == "number")' "$resp" 2>/dev/null) || cost=
  if [ "$backend" != local ] && [ -z "$cost" ]; then
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
       confidence: (if ($a.confidence | type) == "number" then $a.confidence
                    elif ($a.uncertainty.top_probability | type) == "number" then $a.uncertainty.top_probability
                    else null end),
       probabilities: ($a.probabilities | if type == "object" then . else null end),
       cost: .usage.cost, ms: $ms,
       model: (if (.model | type) == "string" then .model
               elif (.model | type) == "object"
               then ((.model.source // "unknown") + "/" + (.model.weights // "unknown") + "/" + (.model.precision // "unknown"))
               else null end),
       reason: $reason, status: $status}' "$resp" 2>/dev/null) || event=
  rm -f "$resp"
  if [ -z "$event" ]; then
    jev_log_skip "$id" api-error "unreadable response" "$reason" "$status"
    [ "$backend" = local ] || jev_pause "$day" api-error
    return 0
  fi
  _fm_jev_append "$STATE" "$event"
  if [ "$backend" != local ]; then
    JEV_SPEND=$(awk -v a="$spend" -v b="${cost:-0}" 'BEGIN { printf "%.9f", a + b }')
    if jev_ge "$JEV_SPEND" "$cap"; then
      jev_pause "$day" cap
    fi
  fi
}

cmd_observe_drain() {  # <spool> <epoch>
  local spool=${1:-} now=${2:-} batch epoch seq kind key payload id task reason status
  local day cap backend base maxload load
  [ -n "$spool" ] && [ -f "$spool" ] || exit 0
  case "$now" in ''|*[!0-9]*) now=$(date +%s) ;; esac
  batch=$(basename "$spool")
  batch=${batch#.spool.}
  backend=$(fm_jev_backend "$FM_HOME" "$STATE") || { rm -f "$spool"; exit 0; }
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
  JEV_TIMEOUT=$(jev_timeout)
  JEV_LOCAL_TIMED_OUT=
  if [ "$backend" = local ]; then
    base=$(tr -d '[:space:]' < "$FM_HOME/config/jev-endpoint" 2>/dev/null)
    if jev_local_url_ok "$base"; then
      JEV_LOCAL_ENDPOINT="${base%/}/v1/decisions"
    else
      JEV_LOCAL_ENDPOINT=
    fi
    maxload=$(jev_max_load)
  else
    cap=$(jev_cap)
    JEV_SPEND=$(jev_spend_today "$day")
  fi
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
    if [ "$backend" = local ]; then
      if [ -z "$JEV_LOCAL_ENDPOINT" ]; then
        jev_log_skip "$id" invalid-endpoint "config/jev-endpoint must be a loopback URL with no path" "$reason" "$status"
        jev_pause "$day" invalid-endpoint
        continue
      fi
      if [ -n "$JEV_LOCAL_TIMED_OUT" ]; then
        jev_log_skip "$id" timeout "an earlier row in this drain got no answer within ${JEV_TIMEOUT}s" "$reason" "$status"
        continue
      fi
      load=$(jev_load_avg)
      if [ -n "$load" ] && jev_ge "$load" "$maxload"; then
        jev_log_skip "$id" load "1-minute load average $load at or above the $maxload ceiling" "$reason" "$status"
        continue
      fi
      jev_classify_row "$id" "$reason" "$status" local 0 0
    else
      if jev_ge "$JEV_SPEND" "$cap"; then
        jev_pause "$day" cap
        jev_log_skip "$id" cap "daily cap of USD $cap reached" "$reason" "$status"
        continue
      fi
      jev_classify_row "$id" "$reason" "$status" openrouter "$JEV_SPEND" "$cap"
    fi
  done < "$spool"
  fm_lock_release "$JEV_LOCK"
  rm -f "$spool"
}

# The sole entry point for gated absorption (bin/fm-jev-lib.sh's
# fm_jev_absorb_try, called synchronously ONLY from bin/fm-watch.sh's two
# allowlisted call sites). Owns every eligibility rule and the go-live gate;
# exit 0 means the caller must skip its own fm_wake_append + wake because this
# wake was absorbed (and is already recorded in the durable digest); exit 1
# means fall through to today's unconditional behavior, for ANY reason -
# disabled, ineligible, an unmet gate, or a classifier problem. Never dies:
# every failure path is a plain `return 1`, because a bug here must degrade to
# "surface it" and never to "crash the watcher".
cmd_absorb_try() {
  local kind='' task='' reason=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --kind) kind=${2:-}; shift 2 ;;
      --task) task=${2:-}; shift 2 ;;
      --reason) reason=${2:-}; shift 2 ;;
      *) return 1 ;;
    esac
  done
  case "$kind" in signal|stale) ;; *) return 1 ;; esac
  case "$task" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  command -v jq >/dev/null 2>&1 || return 1

  local statusf="$STATE/$task.status" last verb
  [ -f "$statusf" ] || return 1

  # Never a secondmate's routed-reply channel: every append there is
  # parent-directed content firstmate must read (mirrors
  # signal_crew_provably_working's own secondmate exclusion in
  # bin/fm-classify-lib.sh).
  [ "$(grep '^kind=' "$STATE/$task.meta" 2>/dev/null | tail -1 | cut -d= -f2-)" != secondmate ] || return 1

  # Never a task with any open decision (needs-decision/blocked).
  [ -z "$(status_open_decisions "$statusf" 2>/dev/null)" ] || return 1

  last=$(last_status_line "$statusf")
  verb=$(status_line_verb "$last")
  case "$verb" in
    working) ;;
    "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}") ;;
    *) return 1 ;;
  esac
  # Belt and braces: never a captain-relevant line, whatever its verb.
  status_is_captain_relevant "$last" && return 1

  jev_absorb_requested || return 1
  [ "$(fm_jev_backend "$FM_HOME" "$STATE" 2>/dev/null)" = local ] || return 1

  local threshold
  threshold=$(jev_absorb_threshold) || return 1

  local base
  base=$(tr -d '[:space:]' < "$FM_HOME/config/jev-endpoint" 2>/dev/null)
  jev_local_url_ok "$base" || return 1

  if ! jev_absorb_override; then
    jev_absorb_gate_cached || return 1
  fi

  local masked_reason masked_status result rstatus rchoice rconf
  masked_reason=$(printf '%s' "$reason" | jev_mask)
  masked_status=$(printf '%s' "$last" | jev_mask)
  [ -d "$JEV_DIR" ] || (umask 077 && mkdir -p "$JEV_DIR") 2>/dev/null || return 1
  result=$(jev_dial_local "$masked_reason" "$masked_status" "$base" "$(jev_timeout)") || return 1
  IFS=$(printf '\t') read -r rstatus rchoice rconf <<< "$result"
  [ "$rstatus" = ok ] || return 1
  [ "$rchoice" = absorbable ] || return 1
  case "$rconf" in ''|*[!0-9.]*) return 1 ;; esac
  jev_ge "$rconf" "$threshold" || return 1

  _fm_jev_absorb_append "$STATE" "$(jq -cn --argjson t "$(date +%s)" --arg kind "$kind" --arg task "$task" \
    --arg reason "$masked_reason" --arg status "$masked_status" --arg choice "$rchoice" --argjson conf "$rconf" \
    '{t: $t, kind: $kind, task: $task, reason: $reason, status: $status, choice: $choice, confidence: $conf}')"
  return 0
}

cmd_status() {
  local day cap spend backend base traw
  day=$(date +%F)
  backend=$(fm_jev_backend "$FM_HOME" "$STATE") || backend=
  case "$backend" in
    local)
      base=$(tr -d '[:space:]' < "$FM_HOME/config/jev-endpoint" 2>/dev/null)
      printf 'Jev shadow triage: on, local backend (config/jev-endpoint = %s)\n' "$base"
      jev_local_url_ok "$base" || printf 'config/jev-endpoint is not a loopback URL: classification is refused\n'
      printf 'load ceiling: %s (1-minute average)\n' "$(jev_max_load)"
      ;;
    openrouter)
      printf 'Jev shadow triage: on, OpenRouter backend (OPENROUTER_API_KEY present in %s/.env)\n' "$FM_HOME"
      cap=$(jev_cap)
      spend=$(awk -v s="$(jev_spend_today "$day")" 'BEGIN { printf "%.6f", s }')
      printf 'spend today: USD %s of a USD %s daily cap\n' "$spend" "$cap"
      ;;
    *)
      printf 'Jev shadow triage: off (no config/jev-endpoint and no OPENROUTER_API_KEY in %s/.env)\n' "$FM_HOME"
      ;;
  esac
  if [ -n "$backend" ]; then
    traw=$(jev_timeout_raw)
    if [ -n "$traw" ] && ! jev_timeout_valid "$traw"; then
      printf 'request timeout: %ss (config/jev-timeout value "%s" is not a positive number, default kept)\n' "$JEV_DEFAULT_TIMEOUT" "$traw"
    else
      printf 'request timeout: %ss\n' "$(jev_timeout)"
    fi
  fi
  if jev_paused_today "$day"; then
    printf 'paused until tomorrow: %s\n' "$(cut -f2 < "$JEV_DISABLED")"
  fi
  printf 'shadow log: %s\n' "$JEV_LOG"
  if jev_absorb_requested; then
    if [ "$backend" != local ]; then
      printf 'absorption: requested (config/jev-absorb) but refused - requires the local backend, not %s\n' "${backend:-off}"
    elif ! jev_local_url_ok "$(tr -d '[:space:]' < "$FM_HOME/config/jev-endpoint" 2>/dev/null)"; then
      printf 'absorption: requested but refused - config/jev-endpoint is not a loopback URL\n'
    else
      local threshold
      if ! threshold=$(jev_absorb_threshold); then
        printf 'absorption: requested but refused - config/jev-absorb-threshold must be a number at or above %s\n' "$JEV_ABSORB_THRESHOLD_DEFAULT"
      else
        printf 'absorption: requested, threshold %s\n' "$threshold"
        if jev_absorb_override; then
          printf 'absorption: captain override set - the go-live gate is skipped\n'
        elif jev_absorb_gate_cached; then
          printf 'absorption: go-live gate met - active\n'
        else
          printf 'absorption: go-live gate NOT met - inactive (see: bin/fm-jev.sh absorb-gate)\n'
        fi
      fi
    fi
  else
    printf 'absorption: off (config/jev-absorb is absent or not "on")\n'
  fi
}

# shellcheck disable=SC2016 # a jq program; its $names are jq variables, not shell ones.
# The single owner of "$rows": one row per wake presented in the window, Jev's
# label alongside the measured ground truth. cmd_report's text below and
# cmd_absorb_gate's machine-readable go-live verdict both build on this same
# array rather than each re-deriving it, so the two can never silently drift
# apart on what counts as "scored", "agree", or "wrong".
JEV_JQ_ROWS='
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
'

# shellcheck disable=SC2016 # a jq program; its $names are jq variables, not shell ones.
JEV_JQ_REPORT="$JEV_JQ_ROWS"'
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

# The absorption go-live gate's machine-readable verdict, built on the same
# $rows as the text report above (see JEV_JQ_ROWS's own header). "scored" is
# the sample the gate measures against $minsample: the same rows whose
# agreement the text report's "agreement" line reports, so a home cannot pass
# the gate on rows the report itself would not count as measured.
# shellcheck disable=SC2016 # a jq program; its $names are jq variables, not shell ones.
JEV_JQ_ABSORB_GATE="$JEV_JQ_ROWS"'
| ($rows | map(select(.scored))) as $scored
| ($scored | map(select(.agree)) | length) as $agree
| ($rows | map(select(.wrong)) | length) as $wrong
| {
    classified: ($rows | map(select(.jev | IN("absorbable", "firstmate", "captain", "doubt"))) | length),
    scored: ($scored | length),
    agree: $agree,
    wrong: $wrong,
    agreement_pct: (if ($scored | length) == 0 then 0 else (($agree * 1000 / ($scored | length) | round) / 10) end),
    min_sample: $minsample,
    sample_ok: (($scored | length) >= $minsample),
    wrong_ok: ($wrong == 0),
    agreement_ok: (($scored | length) > 0 and ($agree * 100 >= 90 * ($scored | length)))
  }
| . + {all_ok: (.sample_ok and .wrong_ok and .agreement_ok)}
'

# The empty/no-data verdict absorb-gate reports before any shadow log exists
# at all, or on any read/compute failure: always a fail, never a guess.
JEV_ABSORB_GATE_EMPTY='{"classified":0,"scored":0,"agree":0,"wrong":0,"agreement_pct":0,"min_sample":%s,"sample_ok":false,"wrong_ok":true,"agreement_ok":false,"all_ok":false}\n'

# The absorption go-live gate: has the shadow measurement (bin/fm-jev.sh
# report's own criteria, plus a minimum sample so a handful of lucky rows can
# never pass it) earned activation? `--json` prints the JEV_JQ_ABSORB_GATE
# object; otherwise a short human summary. Exit 0 when met, 1 when not (or on
# any failure to compute it at all) - always fail closed, in both formats.
cmd_absorb_gate() {
  local log=$JEV_LOG days=$JEV_ABSORB_GATE_DAYS_DEFAULT minconf=0.6 minsample=$JEV_ABSORB_MIN_SAMPLE_DEFAULT
  local now since fmt=text result
  now=$(date +%s)
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --log) [ "$#" -ge 2 ] || die "--log needs a file"; log=$2; shift 2 ;;
      --days) [ "$#" -ge 2 ] || die "--days needs a number"; days=$2; shift 2 ;;
      --min-confidence) [ "$#" -ge 2 ] || die "--min-confidence needs a number"; minconf=$2; shift 2 ;;
      --min-sample) [ "$#" -ge 2 ] || die "--min-sample needs a number"; minsample=$2; shift 2 ;;
      --now) [ "$#" -ge 2 ] || die "--now needs an epoch"; now=$2; shift 2 ;;
      --json) fmt=json; shift ;;
      *) die "unknown absorb-gate option: $1" ;;
    esac
  done
  case "$days" in ''|*[!0-9]*) die "--days must be a whole number" ;; esac
  case "$minsample" in ''|*[!0-9]*) die "--min-sample must be a whole number" ;; esac
  case "$now" in ''|*[!0-9]*) die "--now must be an epoch" ;; esac
  [[ "$minconf" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "--min-confidence must be a number such as 0.6"
  command -v jq >/dev/null 2>&1 || die "jq is required"
  if [ ! -f "$log" ]; then
    # shellcheck disable=SC2059 # $JEV_ABSORB_GATE_EMPTY is a fixed printf template
    result=$(printf "$JEV_ABSORB_GATE_EMPTY" "$minsample")
  else
    since=$((now - days * 86400))
    result=$(jq -c -n -R --argjson now "$now" --argjson since "$since" --argjson minconf "$minconf" \
      --argjson minsample "$minsample" "[inputs | fromjson?] | $JEV_JQ_ABSORB_GATE" "$log") || result=
    if [ -z "$result" ]; then
      # shellcheck disable=SC2059
      result=$(printf "$JEV_ABSORB_GATE_EMPTY" "$minsample")
    fi
  fi
  if [ "$fmt" = json ]; then
    printf '%s\n' "$result"
  else
    printf '%s\n' "$result" | jq -r '
      "classified: \(.classified)",
      "scored: \(.scored) (minimum \(.min_sample))",
      "agreement: \(.agreement_pct)% (\(.agree) of \(.scored))",
      "wrongly absorbable: \(.wrong)",
      "go-live: \(if .all_ok then "met" else "NOT met" end)"'
  fi
  printf '%s\n' "$result" | jq -e '.all_ok' >/dev/null 2>&1
}

# Bounded, cached wrapper around cmd_absorb_gate so a home with absorption
# requested pays that computation at most once per JEV_ABSORB_GATE_CACHE_TTL
# seconds, never once per wake. Fails closed (0 == pass only on a verified
# recent pass) on a stale/missing cache that a fresh, bounded recompute cannot
# refresh in time - a hung or slow gate computation must never leave
# absorption running on a stale verdict, and must never itself add unbounded
# latency to the wake path.
jev_absorb_gate_cached() {
  local cache="$JEV_DIR/.absorb-gate-cache" now ts verdict result
  now=$(date +%s)
  if [ -f "$cache" ]; then
    IFS=$(printf '\t') read -r ts verdict < "$cache" 2>/dev/null || ts=
    case "$ts" in ''|*[!0-9]*) ts= ;; esac
    if [ -n "$ts" ] && [ "$((now - ts))" -lt "$JEV_ABSORB_GATE_CACHE_TTL" ]; then
      [ "$verdict" = pass ]
      return
    fi
  fi
  if result=$(fm_run_timed "$JEV_ABSORB_GATE_TIMEOUT" "$SCRIPT_DIR/fm-jev.sh" absorb-gate --json 2>/dev/null); then
    verdict=pass
  else
    verdict=fail
  fi
  (umask 077 && printf '%s\t%s\n' "$now" "$verdict" > "$cache") 2>/dev/null || true
  [ "$verdict" = pass ]
}

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
  absorb-gate) shift; cmd_absorb_gate "$@" ;;
  absorb-try) shift; cmd_absorb_try "$@" ;;
  mask) shift; command -v jq >/dev/null 2>&1 || die "jq is required"; jev_mask ;;
  observe-drain) shift; cmd_observe_drain "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
