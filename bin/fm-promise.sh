#!/usr/bin/env bash
# fm-promise.sh - durable, dated commitments ("promesse") with deadline alerts.
#
# Every deadline the captain gives in chat ("entro il pomeriggio", "domani alle
# 10") and every "ti avviso quando ..." firstmate says becomes one record here,
# in the same turn, so it survives compaction, restarts, and a dead watcher.
# The records drive four consumers:
#   - the deadline alerts (`alerts`), run by bin/fm-sentinel.sh every few
#     minutes outside any agent session, sent to the captain over Telegram;
#   - the watcher check each promise registers, which wakes firstmate at the
#     same thresholds and keeps the home "needing supervision" while open;
#   - the blocking-decision banner (`blocking`), which a captain-facing reply
#     leads with ("BLOCCA SCADENZA hh:mm") until the captain answers;
#   - the morning digest (`digest`), sent by bin/fm-sentinel.sh at 08:30.
# bin/fm-promise-turnend.sh reads the registration log to decide whether a
# captain message with a time expression was registered.
#
# Usage:
#   fm-promise.sh add <id> --due <when> --text <what> [--ref <source>]
#                 [--every <minutes> --cond <shell>]
#   fm-promise.sh add <id> <every-minutes> <cond-shell> <message>   (legacy form)
#   fm-promise.sh list [--open] [--today] [--json]
#   fm-promise.sh done <id>               close and archive (kept or withdrawn)
#   fm-promise.sh block <id> --decision <text> [--task <backlog-id>]
#   fm-promise.sh unblock <id>            the captain answered the decision
#   fm-promise.sh blocking                one "BLOCCA SCADENZA hh:mm" line each
#   fm-promise.sh none <reason>           record the "nessuna scadenza" override
#   fm-promise.sh alerts [--dry-run]      send due deadline alerts (sentinel)
#   fm-promise.sh digest                  print the 08:30 morning digest text
#   fm-promise.sh tick <id>               the registered watcher check body
#   fm-promise.sh notify                  send stdin to the captain's alert chat
#   fm-promise.sh cloud                   arm or disarm the cloud check to match
#   fm-promise.sh offline-notice [--dry-run]   "Portatile spento con N impegni aperti"
#
# <when> accepts "YYYY-MM-DD HH:MM", "YYYY-MM-DDTHH:MM", "HH:MM" (today),
# "domani HH:MM", "+<N>m", "+<N>h", or "@<epoch>". Times are local.
# <id> is lowercase letters, digits, and dashes.
#
# Records live in $FM_HOME/data/promesse/ (the directory the local 07/11 tool
# used, so its records stay readable): <id>.msg (the commitment text), <id>.meta
# (key=value lines: created, due, ref, every), optional <id>.cond (legacy
# condition check), <id>.block (the blocking decision), alert markers
# <id>.alerted-<stage>, and registro.log (one tab-separated line per event:
# epoch, event, id, detail). `done` moves every <id>.* file to archivio/.
#
# Alert stages: 2h before the due time, 30m before, and overdue; each is sent
# once, and a stage already passed when a later one fires is marked silently,
# so a promise registered 40 minutes before its deadline gets one 30m alert,
# not two. Telegram delivery goes through bin/fm-telegram.sh send; the target
# chat is FM_PROMISE_CHAT, else the configured owner's private chat when it is
# in allowed_chats. A Telegram reply is information only, never authorization.
#
# Cloud arming: the outside dead-man's switch should alert only while a dated
# commitment is open, because the laptop is often off on purpose. When the
# first open dated promise is registered, `add` runs the one shell line in the
# optional, gitignored config/sentinel-arm; when the last one is closed, `done`
# runs config/sentinel-disarm. `cloud` reconciles the same way and is run by the
# sentinel every few minutes, so a failed or skipped call is retried. Both are
# bounded to 30 s; the state last applied is in data/promesse/.cloud-state and
# each change is logged as cloud-arm or cloud-disarm. A missing file means that
# direction is not configured and nothing runs.
#
# `offline-notice` sends "Portatile spento con N impegni aperti: ..." when at
# least one dated promise is open, and nothing otherwise; the sentinel's
# shutdown and suspend units call it (bin/fm-sentinel.sh power-off).
#
# Environment:
#   FM_HOME                operational home (default: this checkout)
#   FM_PROMISE_NOW         fixed "now" epoch, for tests
#   FM_PROMISE_SEND        command that receives alert text on stdin instead of
#                          Telegram (tests; "discard" drops it)
#   FM_PROMISE_CHAT        Telegram chat id for alerts
#   FM_PROMISE_NO_CHECK=1  do not register a watcher check (tests)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
D="$FM_HOME/data/promesse"
LOG="$D/registro.log"

die() { printf 'fm-promise: %s\n' "$1" >&2; exit "${2:-1}"; }
usage() { sed -n '/^# Usage:/,/^# <id>/p' "$0" | sed 's/^# \{0,1\}//'; }

now() { printf '%s' "${FM_PROMISE_NOW:-$(date +%s)}"; }

valid_id() { [[ ${1-} =~ ^[a-z0-9][a-z0-9-]*$ ]]; }

# Local-time epoch for "YYYY-MM-DD HH:MM" on GNU or BSD date.
epoch_of() {  # <YYYY-MM-DD> <HH:MM>
  date -d "$1 $2" +%s 2>/dev/null || date -j -f '%Y-%m-%d %H:%M' "$1 $2" +%s 2>/dev/null
}

day_of() {  # <epoch> -> YYYY-MM-DD
  date -d "@$1" +%Y-%m-%d 2>/dev/null || date -r "$1" +%Y-%m-%d
}

hm_of() {  # <epoch> -> HH:MM
  date -d "@$1" +%H:%M 2>/dev/null || date -r "$1" +%H:%M
}

when_label() {  # <epoch> -> "oggi 16:00" | "domani 10:00" | "26/11 10:00"
  local e=$1 n today
  n=$(now)
  today=$(day_of "$n")
  if [ "$(day_of "$e")" = "$today" ]; then
    printf 'oggi %s' "$(hm_of "$e")"
  elif [ "$(day_of "$e")" = "$(day_of $((n + 86400)))" ]; then
    printf 'domani %s' "$(hm_of "$e")"
  else
    printf '%s %s' "$(date -d "@$e" +%d/%m 2>/dev/null || date -r "$e" +%d/%m)" "$(hm_of "$e")"
  fi
}

parse_when() {  # <when> -> epoch
  local w=$1 n
  n=$(now)
  case "$w" in
    @*) w=${w#@}; [[ $w =~ ^[0-9]+$ ]] && { printf '%s' "$w"; return 0; } ;;
    +*m) w=${w#+}; w=${w%m}; [[ $w =~ ^[0-9]+$ ]] && { printf '%s' $((n + w * 60)); return 0; } ;;
    +*h) w=${w#+}; w=${w%h}; [[ $w =~ ^[0-9]+$ ]] && { printf '%s' $((n + w * 3600)); return 0; } ;;
  esac
  if [[ $w =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})[T\ ]([0-9]{1,2}:[0-9]{2})$ ]]; then
    epoch_of "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"; return
  fi
  if [[ $w =~ ^([0-9]{1,2}:[0-9]{2})$ ]]; then
    epoch_of "$(day_of "$n")" "${BASH_REMATCH[1]}"; return
  fi
  if [[ $w =~ ^(domani|tomorrow)\ ([0-9]{1,2}:[0-9]{2})$ ]]; then
    epoch_of "$(day_of $((n + 86400)))" "${BASH_REMATCH[2]}"; return
  fi
  return 1
}

log_event() {  # <event> <id> <detail>
  local detail=${3-}
  detail=${detail//$'\n'/ }
  detail=${detail//$'\t'/ }
  printf '%s\t%s\t%s\t%s\n' "$(now)" "$1" "$2" "$detail" >> "$LOG"
}

meta_get() {  # <id> <key>
  awk -v k="$2=" '{ for (i = 1; i <= NF; i++) if (index($i, k) == 1) { print substr($i, length(k) + 1); exit } }' \
    "$D/$1.meta" 2>/dev/null
}

# Telegram delivery, or the test seam. Text on stdin.
send_alert() {
  local text chat
  text=$(cat)
  case "${FM_PROMISE_SEND:-}" in
    discard) return 0 ;;
    '') ;;
    *) printf '%s\n' "$text" | sh -c "$FM_PROMISE_SEND"; return ;;
  esac
  chat=${FM_PROMISE_CHAT:-}
  if [ -z "$chat" ]; then
    chat=$(jq -r '.owner_user_id as $o | if ([.allowed_chats[]?] | index($o)) then $o else empty end' \
      "$FM_HOME/config/telegram.json" 2>/dev/null) || chat=
  fi
  [ -n "$chat" ] || { printf 'fm-promise: no Telegram chat for alerts (set FM_PROMISE_CHAT or add the owner chat to config/telegram.json)\n' >&2; return 1; }
  printf '%s\n' "$text" | FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-telegram.sh" send --chat "$chat" --file - >/dev/null
}

open_ids() {
  local m
  for m in "$D"/*.msg; do
    [ -e "$m" ] || continue
    m=${m##*/}
    printf '%s\n' "${m%.msg}"
  done
}

write_check() {  # <id>
  local id=$1 f="$STATE/promessa-$1.check.sh"
  [ "${FM_PROMISE_NO_CHECK:-0}" = 1 ] && return 0
  [ -d "$STATE" ] || return 0
  umask 077
  cat > "$f" <<EOF
#!/usr/bin/env bash
# Durable promise $id (bin/fm-promise.sh). Wakes firstmate at its deadline thresholds.
FM_HOME='$FM_HOME' exec '$SCRIPT_DIR/fm-promise.sh' tick '$id'
EOF
  chmod 700 "$f"
  "$SCRIPT_DIR/fm-check-register.sh" "promessa-$id" >/dev/null \
    || printf 'fm-promise: warning: watcher check for %s not registered\n' "$id" >&2
}

# Open promises that have a due time (the ones that arm the cloud check),
# earliest deadline first.
dated_open_ids() {
  local id due
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    [ -e "$D/$id.kept" ] && continue
    due=$(meta_get "$id" due)
    [ -n "$due" ] && printf '%s %s\n' "$due" "$id"
  done < <(open_ids) | sort -n | cut -d' ' -f2
}

# First non-comment, non-blank line of config/<name>, or nothing.
config_line() {  # <name>
  local f="$FM_HOME/config/$1"
  [ -f "$f" ] || return 0
  grep -v '^[[:space:]]*#' "$f" | sed '/^[[:space:]]*$/d' | head -n 1
}

# Arm the cloud check while a dated promise is open, disarm it otherwise.
# Returns 1 only when the configured command failed (retried next run).
cmd_cloud() {
  local want cur cmd
  if [ -n "$(dated_open_ids)" ]; then want=armed; else want=disarmed; fi
  cur=$(cat "$D/.cloud-state" 2>/dev/null || true)
  [ "$cur" = "$want" ] && return 0
  if [ "$want" = armed ]; then cmd=$(config_line sentinel-arm); else cmd=$(config_line sentinel-disarm); fi
  [ -n "$cmd" ] || return 0
  if timeout 30 sh -c "$cmd" >/dev/null 2>&1; then
    mkdir -p "$D"
    printf '%s\n' "$want" > "$D/.cloud-state"
    log_event "cloud-${want%ed}" - ""
    return 0
  fi
  printf 'fm-promise: cloud %s command failed; retrying next run\n' "${want%ed}" >&2
  return 1
}

cmd_offline_notice() {
  local dry=0 ids id due n=0 items='' text
  [ "${1-}" = --dry-run ] && dry=1
  ids=$(dated_open_ids)
  [ -n "$ids" ] || return 0
  while IFS= read -r id; do
    due=$(meta_get "$id" due)
    text=$(head -n 1 "$D/$id.msg")
    n=$((n + 1))
    items="${items:+$items; }$text (entro $(when_label "$due"))"
  done <<< "$ids"
  if [ "$n" -eq 1 ]; then
    text="Portatile spento con 1 impegno aperto: $items"
  else
    text="Portatile spento con $n impegni aperti: $items"
  fi
  if [ "$dry" = 1 ]; then printf '%s\n' "$text"; return 0; fi
  printf '%s\n' "$text" | send_alert
}

cmd_add() {
  local id=${1-} due='' text='' ref='' every='' cond='' due_e
  shift || true
  valid_id "$id" || die "id: lowercase letters, digits, dashes" 2
  if [ "$#" -eq 3 ] && [ "${1#--}" = "$1" ]; then
    every=$1; cond=$2; text=$3
  else
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --due) due=${2-}; shift ;;
        --text) text=${2-}; shift ;;
        --ref) ref=${2-}; shift ;;
        --every) every=${2-}; shift ;;
        --cond) cond=${2-}; shift ;;
        *) die "unknown option: $1" 2 ;;
      esac
      shift
    done
  fi
  [ -n "$text" ] || die "--text is required" 2
  [ -n "$due" ] || [ -n "$cond" ] || die "a promise needs --due (a date and time) or --every with --cond" 2
  if [ -n "$cond" ]; then [[ $every =~ ^[0-9]+$ ]] || die "--every needs minutes with --cond" 2; fi
  [ -e "$D/$id.msg" ] && die "promise $id already exists; close it with done first" 2
  due_e=
  if [ -n "$due" ]; then
    due_e=$(parse_when "$due") || die "cannot read --due '$due' (YYYY-MM-DD HH:MM, HH:MM, domani HH:MM, +Nm, +Nh, @epoch)" 2
  fi
  mkdir -p "$D"
  printf '%s\n' "$text" > "$D/$id.msg"
  {
    printf 'created=%s' "$(date -d "@$(now)" -Iseconds 2>/dev/null || date -Iseconds)"
    printf ' created_epoch=%s' "$(now)"
    [ -n "$due_e" ] && printf ' due=%s' "$due_e"
    [ -n "$every" ] && printf ' every=%s' "$every"
    [ -n "$ref" ] && printf ' ref=%s' "${ref// /_}"
    printf '\n'
  } > "$D/$id.meta"
  [ -n "$cond" ] && printf '%s\n' "$cond" > "$D/$id.cond"
  log_event add "$id" "${due_e:+due=$due_e }$text"
  write_check "$id"
  [ -n "$due_e" ] && { cmd_cloud || true; }
  if [ -n "$due_e" ]; then
    printf 'Registrato: %s entro %s (promessa %s)\n' "$text" "$(when_label "$due_e")" "$id"
  else
    printf 'Registrato: %s (promessa %s, controllo ogni %s min)\n' "$text" "$id" "$every"
  fi
}

status_of() {  # <id>
  if [ -e "$D/$1.kept" ]; then printf kept; return; fi
  local due
  due=$(meta_get "$1" due)
  if [ -n "$due" ] && [ "$(now)" -ge "$due" ]; then printf overdue; else printf open; fi
}

cmd_list() {
  local only_open=0 today=0 json=0 id due st text block n day first=1
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --open) only_open=1 ;;
      --today) today=1 ;;
      --json) json=1 ;;
      *) die "unknown option: $1" 2 ;;
    esac
    shift
  done
  n=$(now); day=$(day_of "$n")
  [ "$json" = 1 ] && printf '['
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    st=$(status_of "$id")
    [ "$only_open" = 1 ] && [ "$st" = kept ] && continue
    due=$(meta_get "$id" due)
    if [ "$today" = 1 ]; then
      # Today's view: due today, already overdue, or undated condition watches.
      if [ -n "$due" ] && [ "$(day_of "$due")" != "$day" ] && [ "$due" -gt "$n" ]; then continue; fi
    fi
    text=$(head -n 1 "$D/$id.msg")
    block=$(sed -n 's/^decision=//p' "$D/$id.block" 2>/dev/null | head -n 1)
    if [ "$json" = 1 ]; then
      [ "$first" = 1 ] || printf ','
      first=0
      printf '%s' "$(jq -cn --arg id "$id" --arg st "$st" --arg due "$due" --arg text "$text" --arg block "$block" \
        '{id:$id,status:$st,due:(if $due=="" then null else ($due|tonumber) end),text:$text,blocked_by:(if $block=="" then null else $block end)}')"
    else
      printf '%s [%s]%s %s%s\n' "$id" "$st" "${due:+ entro $(when_label "$due")}" "$text" "${block:+ - BLOCCATA da decisione: $block}"
    fi
  done < <(open_ids)
  [ "$json" = 1 ] && printf ']\n'
  return 0
}

cmd_done() {
  local id=${1-}
  valid_id "$id" || die "usage: done <id>" 2
  [ -e "$D/$id.msg" ] || die "no open promise $id" 1
  if [ -e "$STATE/promessa-$id.check.sh" ]; then
    "$SCRIPT_DIR/fm-check-unregister.sh" "promessa-$id" >/dev/null 2>&1 || true
    rm -f "$STATE/promessa-$id.check.sh"
  fi
  mkdir -p "$D/archivio"
  mv "$D/$id".* "$D/archivio/" 2>/dev/null
  log_event "done" "$id" ""
  cmd_cloud || true
  printf 'promise %s closed\n' "$id"
}

cmd_block() {
  local id=${1-} decision='' task=''
  shift || true
  valid_id "$id" || die "usage: block <id> --decision <text> [--task <backlog-id>]" 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision) decision=${2-}; shift ;;
      --task) task=${2-}; shift ;;
      *) die "unknown option: $1" 2 ;;
    esac
    shift
  done
  [ -n "$decision" ] || die "--decision is required" 2
  [ -e "$D/$id.msg" ] || die "no open promise $id" 1
  printf 'decision=%s\n%s\n' "${decision//$'\n'/ }" "${task:+task=$task}" > "$D/$id.block"
  log_event block "$id" "${task:+task=$task }$decision"
  cmd_blocking
}

cmd_unblock() {
  local id=${1-}
  valid_id "$id" || die "usage: unblock <id>" 2
  [ -e "$D/$id.block" ] || die "promise $id has no blocking decision" 1
  rm -f "$D/$id.block"
  log_event unblock "$id" ""
  printf 'promise %s unblocked\n' "$id"
}

# One line per open promise blocked by a captain decision, earliest deadline
# first. Empty output means nothing blocks a deadline.
cmd_blocking() {
  local id due decision task text hm
  while IFS= read -r id; do
    [ -n "$id" ] && [ -e "$D/$id.block" ] || continue
    [ -e "$D/$id.kept" ] && continue
    due=$(meta_get "$id" due)
    decision=$(sed -n 's/^decision=//p' "$D/$id.block" | head -n 1)
    task=$(sed -n 's/^task=//p' "$D/$id.block" | head -n 1)
    text=$(head -n 1 "$D/$id.msg")
    if [ -n "$due" ]; then hm=$(hm_of "$due"); else hm='senza ora'; fi
    printf '%s\tBLOCCA SCADENZA %s - %s (impegno: %s%s)\n' "${due:-9999999999}" \
      "$hm" "$decision" "$text" "${task:+; $task}"
  done < <(open_ids) | sort -n | cut -f2-
}

cmd_none() {
  local reason=${*:-nessuna scadenza}
  mkdir -p "$D"
  log_event none - "$reason"
  printf 'Registrato: nessuna scadenza (%s)\n' "$reason"
}

# Send each deadline stage at most once. A stage reached together with a later
# one is marked without a message so the captain gets only the most urgent.
cmd_alerts() {
  local dry=0 id due n left stage text block msg sent=0
  [ "${1-}" = --dry-run ] && dry=1
  n=$(now)
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    [ -e "$D/$id.kept" ] && continue
    due=$(meta_get "$id" due)
    [ -n "$due" ] || continue
    left=$((due - n))
    stage=
    if [ "$left" -le 0 ]; then stage=overdue
    elif [ "$left" -le 1800 ]; then stage=30m
    elif [ "$left" -le 7200 ]; then stage=2h
    fi
    [ -n "$stage" ] || continue
    [ -e "$D/$id.alerted-$stage" ] && continue
    text=$(head -n 1 "$D/$id.msg")
    block=$(sed -n 's/^decision=//p' "$D/$id.block" 2>/dev/null | head -n 1)
    case "$stage" in
      overdue) msg="SCADUTO alle $(hm_of "$due"): $text" ;;
      30m) msg="Scade tra $(( (left + 59) / 60 )) min ($(hm_of "$due")): $text" ;;
      2h) msg="Scade tra $(( left / 3600 ))h$(printf '%02d' $(( (left % 3600) / 60 ))) ($(hm_of "$due")): $text" ;;
    esac
    [ -n "$block" ] && msg="$msg
BLOCCA SCADENZA $(hm_of "$due"): serve la tua decisione - $block"
    msg="$msg
(promessa $id; una risposta qui è informazione, non un'autorizzazione)"
    if [ "$dry" = 1 ]; then
      printf '%s\n---\n' "$msg"
      continue
    fi
    if printf '%s\n' "$msg" | send_alert; then
      case "$stage" in
        overdue) touch "$D/$id.alerted-overdue" "$D/$id.alerted-30m" "$D/$id.alerted-2h" ;;
        30m) touch "$D/$id.alerted-30m" "$D/$id.alerted-2h" ;;
        2h) touch "$D/$id.alerted-2h" ;;
      esac
      log_event "alert-$stage" "$id" "sent"
      sent=$((sent + 1))
    else
      log_event "alert-$stage" "$id" "send failed"
      printf 'fm-promise: alert for %s (%s) not delivered; retrying next run\n' "$id" "$stage" >&2
    fi
  done < <(open_ids)
  [ "$dry" = 1 ] || printf 'alerts sent: %s\n' "$sent"
}

cmd_digest() {
  local lines blocking
  lines=$(cmd_list --open --today)
  blocking=$(cmd_blocking)
  if [ -n "$blocking" ]; then
    printf '%s\n' "$blocking"
  fi
  if [ -n "$lines" ]; then
    printf 'impegni di oggi:\n%s\n' "$lines"
  else
    printf 'impegni di oggi: nessuno registrato\n'
  fi
}

# Watcher check body: print one wake line per threshold, once each. A promise
# with a condition (the 07/11 "ti avviso quando ..." form) also runs it at most
# every <every> minutes, in the background with a 30 s bound so the watcher
# never waits, and wakes firstmate once when it first holds.
cmd_tick() {
  local id=${1-} due n left stage text every last
  valid_id "$id" || exit 0
  [ -e "$D/$id.msg" ] || exit 0
  if [ -e "$D/$id.cond" ]; then
    if [ -e "$D/$id.kept" ]; then
      if [ ! -e "$D/$id.told" ]; then
        touch "$D/$id.told"
        printf 'promessa %s mantenibile: %s (poi: bin/fm-promise.sh done %s)\n' "$id" "$(head -n 1 "$D/$id.msg")" "$id"
      fi
    else
      every=$(meta_get "$id" every); [[ $every =~ ^[0-9]+$ ]] || every=15
      n=$(now); last=$(cat "$D/$id.last" 2>/dev/null || echo 0)
      [[ $last =~ ^[0-9]+$ ]] || last=0
      if [ $((n - last)) -ge $((every * 60)) ]; then
        printf '%s\n' "$n" > "$D/$id.last"
        # shellcheck disable=SC2016 # Expanded by the inner bash from its own argv.
        setsid nohup bash -c 'timeout 30 bash "$0/$1.cond" >/dev/null 2>&1 && touch "$0/$1.kept"' "$D" "$id" \
          >/dev/null 2>&1 < /dev/null &
      fi
    fi
  fi
  due=$(meta_get "$id" due)
  [ -n "$due" ] || exit 0
  n=$(now); left=$((due - n)); stage=
  if [ "$left" -le 0 ]; then stage=overdue
  elif [ "$left" -le 1800 ]; then stage=30m
  elif [ "$left" -le 7200 ]; then stage=2h
  fi
  [ -n "$stage" ] || exit 0
  [ -e "$D/$id.woke-$stage" ] && exit 0
  touch "$D/$id.woke-$stage"
  text=$(head -n 1 "$D/$id.msg")
  printf 'promessa %s scade %s (%s): %s%s; chiudila con bin/fm-promise.sh done %s quando mantenuta\n' \
    "$id" "$(when_label "$due")" "$stage" "$text" \
    "$([ -e "$D/$id.block" ] && printf '; BLOCCATA da una decisione del capitano: mettila in cima alla risposta')" "$id"
}

cmd=${1-}
[ "$#" -gt 0 ] && shift
case "$cmd" in
  add) cmd_add "$@" ;;
  list) cmd_list "$@" ;;
  done) cmd_done "$@" ;;
  block) cmd_block "$@" ;;
  unblock) cmd_unblock "$@" ;;
  blocking) cmd_blocking ;;
  none) cmd_none "$@" ;;
  alerts) cmd_alerts "$@" ;;
  digest) cmd_digest ;;
  tick) cmd_tick "$@" ;;
  notify) send_alert ;;
  cloud) cmd_cloud ;;
  offline-notice) cmd_offline_notice "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
