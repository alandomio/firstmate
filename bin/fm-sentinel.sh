#!/usr/bin/env bash
# fm-sentinel.sh - supervision watchdog that runs outside every agent session.
#
# Firstmate's watcher lives inside the primary agent session (on Claude, the
# Stop hook parks it between turns). When that chain dies, nothing inside the
# session notices, and on 24/11/2026 it stayed down about five hours. This
# script runs from a systemd user timer every five minutes instead:
#
#   tick     1. sends due deadline alerts (bin/fm-promise.sh alerts) and
#               re-syncs the cloud check's armed state (bin/fm-promise.sh
#               cloud), so a failed arm or disarm is retried;
#            2. touches state/.sentinel-beat and runs the optional cloud
#               heartbeat command in config/sentinel-heartbeat (one shell line,
#               bounded to 20 s), so an outside dead-man's switch can tell the
#               laptop is alive;
#            3. when the home needs supervision (bin/fm-supervision-lib.sh owns
#               that) and the model-aware watcher verdict
#               (fm_watcher_supervision_verdict in bin/fm-wake-lib.sh, the same
#               one bin/fm-guard.sh uses, evaluated for the session-lock
#               holder's harness) says it is down, it opens a down episode,
#               asks the primary session to recover, and alerts the captain.
#   digest   sends the morning message "Sorveglianza attiva, impegni di oggi:
#            ..." (08:30 timer); a missing message means something is broken.
#   drill    start|report - the end-to-end proof: `start` kills this home's
#            own supervision process group on purpose, `report` prints the
#            timeline the next ticks produced.
#   status   timers, the last log lines, and the current verdict.
#   power-off <shutdown|suspend>   the captain's notice that the laptop is
#            going away with dated commitments open (bin/fm-promise.sh
#            offline-notice); run by the system units below. A "shutdown" that
#            is a reboot, or that runs while the system is not stopping (the
#            unit being stopped by hand), sends nothing.
#   systemd-units [--system [--user <name>]] [--dir <path>]   print or write
#            the user units, or with --system the two root-owned units that
#            run power-off before suspend and at shutdown.
#   install | uninstall            write and enable, or disable and remove,
#            the units in ~/.config/systemd/user (systemctl --user).
#   install-power | uninstall-power   the same for the system units in
#            /etc/systemd/system; needs root (sudo), the units run as the
#            invoking user (SUDO_USER).
#
# Recovery uses the session's own path, never a second watcher: the supervision
# instructions' repair line for a Claude primary is Stop-owned recovery, so the
# sentinel wakes the session-lock holder's pane with a Firstmate operational
# input (kind "watcher", record-backed on Claude) telling it to drain and end
# its turn; that turn end re-arms through the Stop hook. It types only into a
# confirmed-empty composer of the lock holder's pane (resolved from its
# environment, bin/fm-supervisor-target-lib.sh), never while a turn is running,
# and at most once per FM_SENTINEL_RETRY_SECS; in away or quiet mode the input
# carries that posture's repair line (ensure its daemon or host runs). It never kills or starts fm-watch.sh.
# With no live session it can only alert: reopening firstmate is the captain's.
#
# Down means the verdict failed with FM_SENTINEL_GRACE (240 s of beacon
# silence, a minute under the guard's 300 s): with the timer every five
# minutes, recovery is asked for at most nine minutes after the last sign of
# life, leaving a minute for the session's own turn to re-arm inside the ten
# the drill must prove (a 300 s grace measured 11 min in the first drill). A running turn is never
# typed into, but past FM_SENTINEL_BUSY_SECS (600) of down time it is alerted. The captain gets one Telegram
# alert per episode, a repeat every FM_SENTINEL_REALERT_SECS (3600), and one
# "ripristinata" message when it ends. Every action is logged to
# state/sentinel.log as "<epoch> <event> <detail>".
#
# Environment:
#   FM_HOME                    operational home (default: this checkout)
#   FM_SENTINEL_NOW            fixed "now" epoch (tests)
#   FM_SENTINEL_HARNESS        primary harness override (tests)
#   FM_SENTINEL_TARGET         "<backend> <target>" pane override (tests)
#   FM_SENTINEL_SUBMIT         command run with the input as $1 instead of
#                              typing it into the pane (tests)
#   FM_SENTINEL_RETRY_SECS     minimum gap between recovery requests (600)
#   FM_SENTINEL_REALERT_SECS   repeat alert interval while down (3600)
#   FM_SENTINEL_BUSY_SECS      running-turn tolerance before alerting (600)
#   FM_SENTINEL_GRACE          beacon silence that counts as down (240)
#   FM_SENTINEL_SYSTEM_STATE   `systemctl is-system-running` override (tests)
#   FM_SENTINEL_REBOOTING      1 or 0 overrides the reboot-job check (tests)
#   FM_PROMISE_SEND            alert delivery seam, see bin/fm-promise.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
export FM_HOME
GRACE=${FM_SENTINEL_GRACE:-240}
RETRY=${FM_SENTINEL_RETRY_SECS:-600}
REALERT=${FM_SENTINEL_REALERT_SECS:-3600}
BUSY_MAX=${FM_SENTINEL_BUSY_SECS:-600}
EPISODE="$STATE/.sentinel-episode"
SLOG="$STATE/sentinel.log"
PROMISE="$SCRIPT_DIR/fm-promise.sh"
WATCH="$FM_HOME/bin/fm-watch.sh"
[ -f "$WATCH" ] || WATCH="$SCRIPT_DIR/fm-watch.sh"

die() { printf 'fm-sentinel: %s\n' "$1" >&2; exit "${2:-1}"; }
now() { printf '%s' "${FM_SENTINEL_NOW:-$(date +%s)}"; }
slog() { printf '%s %s %s\n' "$(now)" "$1" "${2-}" >> "$SLOG" 2>/dev/null || true; }
usage() { sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

load_libs() {
  # shellcheck source=bin/fm-supervision-lib.sh
  . "$SCRIPT_DIR/fm-supervision-lib.sh"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$SCRIPT_DIR/fm-session-lock-lib.sh"
  # shellcheck source=bin/fm-supervisor-target-lib.sh
  . "$SCRIPT_DIR/fm-supervisor-target-lib.sh"
  # shellcheck source=bin/fm-operational-input.sh
  . "$SCRIPT_DIR/fm-operational-input.sh"
}

notify() {  # <text>
  printf '%s\n' "$1" | "$PROMISE" notify
}

episode_get() {  # <key>
  sed -n "s/^$1=//p" "$EPISODE" 2>/dev/null | head -n 1
}

episode_set() {  # <key> <value>
  local tmp
  tmp=$(mktemp "$STATE/.sentinel-episode.XXXXXX") || return 1
  { grep -v "^$1=" "$EPISODE" 2>/dev/null; printf '%s=%s\n' "$1" "$2"; } > "$tmp"
  mv -f "$tmp" "$EPISODE"
}

# Harness of the live session-lock holder, or empty.
holder_harness() {
  local out
  if [ -n "${FM_SENTINEL_HARNESS:-}" ]; then printf '%s' "$FM_SENTINEL_HARNESS"; return 0; fi
  fm_session_lock_inspect "$STATE"
  [ "$FM_LOCK_INSPECT_STATE" = held ] || return 1
  out=$("$SCRIPT_DIR/fm-harness.sh" ancestry "$FM_LOCK_INSPECT_PID" 2>/dev/null) || return 1
  out=${out##* }
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

holder_target() {  # -> "<backend> <target>"
  if [ -n "${FM_SENTINEL_TARGET:-}" ]; then printf '%s' "$FM_SENTINEL_TARGET"; return 0; fi
  discover_supervisor_from_lock "$STATE"
}

model_for() {  # <harness>
  case "$1" in
    claude|cursor) printf autoarm ;;
    pi|pi-signed|omp) printf extension ;;
    *) printf persistent ;;
  esac
}

# Sets VERDICT_OK (true/false), VERDICT_REASON, HARNESS, BEACON_AGE.
evaluate() {
  HARNESS=$(holder_harness 2>/dev/null) || HARNESS=
  if [ -n "$HARNESS" ]; then
    FM_SUPERVISION_MODEL=$(model_for "$HARNESS")
    export FM_SUPERVISION_MODEL
  fi
  fm_watcher_supervision_verdict "$STATE" "$WATCH" "$GRACE" "$FM_HOME" "$FM_HOME"
  VERDICT_OK=$FM_WATCHER_VERDICT_OK
  VERDICT_REASON=$FM_WATCHER_VERDICT_REASON
  BEACON_AGE=$(fm_path_age "$STATE/.last-watcher-beat")
  case "$BEACON_AGE" in ''|*[!0-9]*) BEACON_AGE=unknown ;; esac
}

# The repair line the supervision instructions emit for this harness and
# posture; in away or quiet mode with a daemon it names that daemon's owner.
repair_line() {
  local afk=0 mode=away
  if [ -e "$STATE/.afk" ]; then afk=1; mode=$(fm_afk_mode "$STATE"); fi
  "$SCRIPT_DIR/fm-supervision-instructions.sh" --harness "$HARNESS" --afk "$afk" --afk-mode "$mode" --repair-line 2>/dev/null
}

# Type one operational input into the lock holder's pane. Exit 0 only when the
# backend confirmed the submit; RECOVER_RESULT names the outcome either way.
request_recovery() {
  local resolved backend target composer busy body input
  RECOVER_RESULT=
  if [ -z "$HARNESS" ]; then RECOVER_RESULT="no live firstmate session holds this home: it must be reopened"; return 1; fi
  resolved=$(holder_target 2>/dev/null) || { RECOVER_RESULT="the session's pane could not be resolved"; return 1; }
  backend=${resolved%% *}
  target=${resolved#* }
  body="Sentinel: watcher supervision for $FM_HOME has been down since $(date -d "@$(( $(now) - ${BEACON_AGE/unknown/0} ))" +%H:%M 2>/dev/null || printf 'unknown') (verdict: $VERDICT_REASON). Run bin/fm-wake-drain.sh, handle what it presents, then end the turn so the harness's own supervision path re-arms the watcher; $(repair_line) The captain was alerted on Telegram."
  if [ -n "${FM_SENTINEL_SUBMIT:-}" ]; then
    if fm_operational_harness_needs_record "$HARNESS"; then
      fm_operational_record_write "$STATE" watcher "$body" input || { RECOVER_RESULT="could not write the operational record"; return 1; }
    else
      fm_operational_input_encode watcher "$body" input || { RECOVER_RESULT="could not encode the input"; return 1; }
    fi
    if sh -c "$FM_SENTINEL_SUBMIT" sentinel "$input"; then RECOVER_RESULT="recovery requested in the session"; return 0; fi
    RECOVER_RESULT="test submit failed"; return 1
  fi
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh"
  fm_backend_target_exists "$backend" "$target" || { RECOVER_RESULT="the session's pane $target is gone"; return 1; }
  busy=$(fm_backend_busy_state "$backend" "$target" 2>/dev/null)
  if [ "$busy" = busy ]; then RECOVER_RESULT="busy"; return 1; fi
  composer=$(fm_backend_composer_state "$backend" "$target" 2>/dev/null)
  if [ "$composer" != empty ]; then RECOVER_RESULT="the session's input box is not empty (${composer:-unknown}); not typing over it"; return 1; fi
  if fm_operational_harness_needs_record "$HARNESS"; then
    fm_operational_record_write "$STATE" watcher "$body" input || { RECOVER_RESULT="could not write the operational record"; return 1; }
  else
    fm_operational_input_encode watcher "$body" input || { RECOVER_RESULT="could not encode the input"; return 1; }
  fi
  if [ "$(fm_backend_send_text_submit "$backend" "$target" "$input" 3 1 1 2>/dev/null)" = empty ]; then
    RECOVER_RESULT="recovery requested in the session"
    return 0
  fi
  RECOVER_RESULT="typing into the session was not confirmed"
  return 1
}

heartbeat() {
  local cmd
  touch "$STATE/.sentinel-beat" 2>/dev/null || true
  [ -f "$FM_HOME/config/sentinel-heartbeat" ] || return 0
  cmd=$(grep -v '^[[:space:]]*#' "$FM_HOME/config/sentinel-heartbeat" | sed '/^[[:space:]]*$/d' | head -n 1)
  [ -n "$cmd" ] || return 0
  if ! timeout 20 sh -c "$cmd" >/dev/null 2>&1; then
    slog heartbeat-failed "config/sentinel-heartbeat exited non-zero"
  fi
}

minutes() { printf '%s' $(( ($1 + 59) / 60 )); }

cmd_tick() {
  local n start alerted last_try down_for msg
  [ -d "$STATE" ] || die "state directory missing: $STATE"
  load_libs
  "$PROMISE" alerts >/dev/null 2>>"$SLOG" || slog alerts-failed "bin/fm-promise.sh alerts"
  "$PROMISE" cloud >/dev/null 2>>"$SLOG" || slog cloud-sync-failed "bin/fm-promise.sh cloud"
  heartbeat
  n=$(now)
  fm_supervision_status "$STATE" "$GRACE"
  if [ "$FM_SUP_NEEDED" = true ]; then
    evaluate
  else
    VERDICT_OK=true; VERDICT_REASON=idle; HARNESS=; BEACON_AGE=unknown
  fi
  if [ "$VERDICT_OK" = true ]; then
    if [ -f "$EPISODE" ]; then
      start=$(episode_get start)
      if [ -n "$(episode_get alerted)" ]; then
        notify "Sorveglianza firstmate ripristinata dopo $(minutes $((n - ${start:-$n}))) min." \
          || slog notify-failed recovered
      fi
      slog recovered "down_for=$((n - ${start:-$n}))s"
      rm -f "$EPISODE"
    fi
    return 0
  fi
  if [ ! -f "$EPISODE" ]; then
    start=$n
    [ "$BEACON_AGE" != unknown ] && start=$((n - BEACON_AGE))
    episode_set start "$start"
    slog down "reason=$VERDICT_REASON beacon_age=$BEACON_AGE harness=${HARNESS:-none}"
  fi
  start=$(episode_get start); down_for=$((n - start))
  last_try=$(episode_get tried)
  if [ -z "$last_try" ] || [ $((n - last_try)) -ge "$RETRY" ]; then
    if request_recovery; then
      episode_set tried "$n"
      slog recovery-requested "$RECOVER_RESULT"
    elif [ "$RECOVER_RESULT" = busy ]; then
      slog busy "a turn is running; down_for=${down_for}s"
      [ "$down_for" -lt "$BUSY_MAX" ] && return 0
      RECOVER_RESULT="a turn has been running for $(minutes "$down_for") min without supervision"
    else
      episode_set tried "$n"
      slog recovery-unavailable "$RECOVER_RESULT"
    fi
  else
    RECOVER_RESULT="recovery already requested $(minutes $((n - last_try))) min ago"
  fi
  alerted=$(episode_get alerted)
  if [ -z "$alerted" ] || [ $((n - alerted)) -ge "$REALERT" ]; then
    msg="Sorveglianza firstmate ferma da $(minutes "$down_for") min ($VERDICT_REASON). Azione: $RECOVER_RESULT."
    if notify "$msg"; then
      episode_set alerted "$n"
      slog alerted "$msg"
    else
      slog notify-failed "$msg"
    fi
  fi
}

cmd_digest() {
  local head body
  [ -d "$STATE" ] || die "state directory missing: $STATE"
  load_libs
  fm_supervision_status "$STATE" "$GRACE"
  if [ "$FM_SUP_NEEDED" = true ]; then
    evaluate
    if [ "$VERDICT_OK" = true ]; then
      head="Sorveglianza attiva"
    else
      head="ATTENZIONE: sorveglianza firstmate NON attiva ($VERDICT_REASON)"
    fi
  else
    head="Sorveglianza attiva (nessun lavoro in corso)"
  fi
  body=$("$PROMISE" digest)
  if notify "$head, $body"; then
    slog digest-sent "$head"
  else
    slog digest-failed "$head"
    return 1
  fi
}

# --- drill ------------------------------------------------------------------
# start: kill the process group of this home's Claude Stop auto-arm owner (the
# hook, the supervision host or arm, and the watcher it parks), exactly what a
# hook timeout or a crashed hook leaves behind. The pid comes from the home's
# own auto-arm ledger and must be a live fm-claude-stop-autoarm.sh whose
# command line names this home, so no other home is touched.
cmd_drill() {
  local sub=${1-} owner cmdline pgid since
  case "$sub" in
    start)
      owner=$(sed -n 's/.*owner_pid=\([0-9]*\).*/\1/p' "$STATE/.claude-autoarm-epoch" 2>/dev/null)
      { [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; } || die "no live Claude auto-arm owner in $STATE/.claude-autoarm-epoch (the drill needs a Claude primary whose watcher is parked)"
      cmdline=$(tr '\0' ' ' < "/proc/$owner/cmdline" 2>/dev/null)
      case "$cmdline" in
        *"$FM_HOME/bin/fm-claude-stop-autoarm.sh"*) : ;;
        *) die "pid $owner is not this home's auto-arm hook: $cmdline" ;;
      esac
      pgid=$(ps -o pgid= -p "$owner" | tr -d ' ')
      [ "$pgid" = "$owner" ] || die "auto-arm owner $owner does not lead its process group ($pgid)"
      slog drill-start "killing supervision process group $pgid"
      # KILL, not TERM: the hook translates TERM into its own failure rewake,
      # which would recover without the sentinel and prove nothing.
      kill -KILL -- "-$pgid" || die "kill failed"
      printf 'drill: supervision process group %s killed at %s; run "%s drill report" after the next two timer runs\n' \
        "$pgid" "$(date +%H:%M:%S)" "$0"
      ;;
    report)
      since=$(awk '$2 == "drill-start" { t = $1 } END { print t }' "$SLOG" 2>/dev/null)
      [ -n "$since" ] || die "no drill-start in $SLOG"
      awk -v t="$since" '$1 >= t' "$SLOG" | while read -r e ev rest; do
        printf '%s +%ss %s %s\n' "$(date -d "@$e" +%H:%M:%S)" $((e - since)) "$ev" "$rest"
      done
      printf 'watcher beacon age now: %ss\n' "$(stat -c %Y "$STATE/.last-watcher-beat" 2>/dev/null | xargs -I{} expr "$(date +%s)" - {})"
      ;;
    *) die "usage: drill start|report" 2 ;;
  esac
}

cmd_power_off() {
  local event=${1-} st
  case "$event" in
    suspend) ;;
    shutdown)
      st=${FM_SENTINEL_SYSTEM_STATE:-$(systemctl is-system-running 2>/dev/null || true)}
      if [ "$st" != stopping ]; then
        slog power-off-skipped "shutdown unit stopped while system is $st"
        return 0
      fi
      if [ "${FM_SENTINEL_REBOOTING:-}" = 1 ] || { [ -z "${FM_SENTINEL_REBOOTING:-}" ] \
        && systemctl list-jobs --no-legend 2>/dev/null | grep -q 'reboot\.target'; }; then
        slog power-off-skipped reboot
        return 0
      fi
      ;;
    *) die "usage: power-off shutdown|suspend" 2 ;;
  esac
  if timeout 25 "$PROMISE" offline-notice 2>>"$SLOG"; then
    slog power-off "$event"
  else
    slog notify-failed "power-off $event"
  fi
  return 0
}

# --- systemd ----------------------------------------------------------------
unit_name() {
  printf 'fm-sentinel-%s' "$(printf '%s' "$(cd "$FM_HOME" && pwd -P)" | cksum | cut -d' ' -f1)"
}

systemd_quoted() {  # <value>
  local v=$1
  v=${v//\\/\\\\}
  v=${v//\"/\\\"}
  v=${v//%/%%}
  printf '%s' "$v"
}

cmd_systemd_units() {
  local dir='' system=0 user='' name home script h p s
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dir) dir=${2-}; shift ;;
      --system) system=1 ;;
      --user) user=${2-}; shift ;;
      *) die "unknown option: $1" 2 ;;
    esac
    shift
  done
  home=$(cd "$FM_HOME" && pwd -P) || die "FM_HOME is not a directory: $FM_HOME"
  script="$SCRIPT_DIR/fm-sentinel.sh"
  name=$(unit_name)
  h=$(systemd_quoted "$home"); p=$(systemd_quoted "$PATH"); s=$(systemd_quoted "$script")
  if [ "$system" = 1 ]; then
    system_units "$dir" "${user:-${SUDO_USER:-$(id -un)}}" "$name" "$h" "$p" "$s"
    return
  fi
  local tick_service tick_timer digest_service digest_timer
  tick_service="[Unit]
Description=Firstmate sentinel for $h

[Service]
Type=oneshot
Environment=\"FM_HOME=$h\"
Environment=\"PATH=$p\"
ExecStart=\"$s\" tick
TimeoutStartSec=120"
  tick_timer="[Unit]
Description=Firstmate sentinel for $h every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target"
  digest_service="[Unit]
Description=Firstmate morning digest for $h

[Service]
Type=oneshot
Environment=\"FM_HOME=$h\"
Environment=\"PATH=$p\"
ExecStart=\"$s\" digest
TimeoutStartSec=120"
  digest_timer="[Unit]
Description=Firstmate morning digest for $h at 08:30

[Timer]
OnCalendar=*-*-* 08:30:00
Persistent=true

[Install]
WantedBy=timers.target"
  if [ -z "$dir" ]; then
    printf '# %s.service\n%s\n\n# %s.timer\n%s\n\n# %s-digest.service\n%s\n\n# %s-digest.timer\n%s\n' \
      "$name" "$tick_service" "$name" "$tick_timer" "$name" "$digest_service" "$name" "$digest_timer"
    return 0
  fi
  mkdir -p "$dir" || die "cannot create $dir"
  printf '%s\n' "$tick_service" > "$dir/$name.service"
  printf '%s\n' "$tick_timer" > "$dir/$name.timer"
  printf '%s\n' "$digest_service" > "$dir/$name-digest.service"
  printf '%s\n' "$digest_timer" > "$dir/$name-digest.timer"
  printf 'wrote: %s/%s{,-digest}.{service,timer}\n' "$dir" "$name"
}

# Root-owned units: suspend runs power-off before sleep.target; shutdown is an
# active no-op whose stop (at poweroff, while the network is still up because
# it is ordered after network-online.target) runs power-off.
system_units() {  # <dir> <user> <name> <home> <path> <script>
  local dir=$1 user=$2 name=$3 h=$4 p=$5 s=$6 suspend_service shutdown_service
  [[ $user =~ ^[a-z_][a-z0-9_.-]*$ ]] || die "invalid user name: $user" 2
  [ "$user" != root ] || die "power-off units must run as the home's owner, not root (use sudo from that user, or --user)" 2
  suspend_service="[Unit]
Description=Firstmate offline notice before suspend for $h
Before=sleep.target

[Service]
Type=oneshot
User=$user
Environment=\"FM_HOME=$h\"
Environment=\"PATH=$p\"
ExecStart=\"$s\" power-off suspend
TimeoutStartSec=30

[Install]
WantedBy=sleep.target"
  shutdown_service="[Unit]
Description=Firstmate offline notice at shutdown for $h
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=$user
Environment=\"FM_HOME=$h\"
Environment=\"PATH=$p\"
ExecStart=/bin/true
ExecStop=\"$s\" power-off shutdown
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target"
  if [ -z "$dir" ]; then
    printf '# %s-suspend.service\n%s\n\n# %s-shutdown.service\n%s\n' \
      "$name" "$suspend_service" "$name" "$shutdown_service"
    return 0
  fi
  mkdir -p "$dir" || die "cannot create $dir"
  printf '%s\n' "$suspend_service" > "$dir/$name-suspend.service"
  printf '%s\n' "$shutdown_service" > "$dir/$name-shutdown.service"
  printf 'wrote: %s/%s-{suspend,shutdown}.service\n' "$dir" "$name"
}

cmd_install_power() {
  local dir=/etc/systemd/system name
  [ "$(id -u)" = 0 ] || die "install-power needs root: sudo $SCRIPT_DIR/fm-sentinel.sh install-power" 2
  [ -n "${SUDO_USER:-}" ] || die "run it with sudo from the home owner's account" 2
  name=$(unit_name)
  cmd_systemd_units --system --user "$SUDO_USER" --dir "$dir"
  systemctl daemon-reload
  systemctl enable "$name-suspend.service"
  systemctl enable --now "$name-shutdown.service"
  printf 'installed: %s-suspend.service and %s-shutdown.service\n' "$name" "$name"
}

cmd_uninstall_power() {
  local dir=/etc/systemd/system name
  [ "$(id -u)" = 0 ] || die "uninstall-power needs root: sudo $SCRIPT_DIR/fm-sentinel.sh uninstall-power" 2
  name=$(unit_name)
  systemctl disable --now "$name-suspend.service" "$name-shutdown.service" 2>/dev/null || true
  rm -f "$dir/$name-suspend.service" "$dir/$name-shutdown.service"
  systemctl daemon-reload
  printf 'removed: %s power units\n' "$name"
}

cmd_install() {
  local dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user" name
  name=$(unit_name)
  cmd_systemd_units --dir "$dir"
  systemctl --user daemon-reload
  systemctl --user enable --now "$name.timer" "$name-digest.timer"
  printf 'installed: %s.timer and %s-digest.timer\n' "$name" "$name"
  printf 'for the shutdown and suspend notice also run: sudo %s/fm-sentinel.sh install-power\n' "$SCRIPT_DIR"
}

cmd_uninstall() {
  local dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user" name
  name=$(unit_name)
  systemctl --user disable --now "$name.timer" "$name-digest.timer" 2>/dev/null || true
  rm -f "$dir/$name.service" "$dir/$name.timer" "$dir/$name-digest.service" "$dir/$name-digest.timer"
  systemctl --user daemon-reload
  printf 'removed: %s units\n' "$name"
}

cmd_status() {
  local name
  name=$(unit_name)
  systemctl --user list-timers "$name.timer" "$name-digest.timer" --all --no-pager 2>/dev/null \
    || printf 'systemctl --user unavailable\n'
  load_libs
  fm_supervision_status "$STATE" "$GRACE"
  if [ "$FM_SUP_NEEDED" = true ]; then
    evaluate
    printf 'supervision: needed, verdict ok=%s reason=%s harness=%s beacon_age=%ss\n' "$VERDICT_OK" "$VERDICT_REASON" "${HARNESS:-none}" "$BEACON_AGE"
  else
    printf 'supervision: not needed (no work in flight)\n'
  fi
  [ -f "$EPISODE" ] && printf 'down episode: %s\n' "$(tr '\n' ' ' < "$EPISODE")"
  printf 'last log lines:\n'
  tail -n 10 "$SLOG" 2>/dev/null || printf '  (none)\n'
}

cmd=${1-}
[ "$#" -gt 0 ] && shift
case "$cmd" in
  tick) cmd_tick ;;
  digest) cmd_digest ;;
  drill) cmd_drill "$@" ;;
  status) cmd_status ;;
  systemd-units) cmd_systemd_units "$@" ;;
  install) cmd_install ;;
  install-power) cmd_install_power ;;
  uninstall-power) cmd_uninstall_power ;;
  power-off) cmd_power_off "$@" ;;
  uninstall) cmd_uninstall ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
