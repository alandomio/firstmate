#!/usr/bin/env bash
# End-to-end overnight-AFK scenario for the "note: ... merged ..." supervision hole.
#
# Drives the REAL bin/fm-supervise-daemon.sh functions (sourced, main loop skipped)
# against a real state dir, exactly as the away-mode daemon does at runtime:
#   1. worker writes a nonterminal `note:` whose free text contains "merged"
#   2. daemon takes the signal wake for that status write
#   3. worker hangs; daemon takes two stale wakes for the unchanged line
#   4. time passes past FM_STALE_ESCALATE_SECS; housekeeping rechecks the idle pane
#   5. the escalation digest is injected into the captain's supervisor pane
#
# Usage: note-wedge-scenario.sh <repo-tree-root> <label>
set -u
ROOT=$1; LABEL=$2
WIN="sess:fm-wishlist-w2"
TASK="wishlist-w2"
KEY="$TASK"
NOTE='note: CANDIDATE - upstream already merged the same fix'

dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-note-wedge-XXXXXX")
state="$dir/state"; fakebin="$dir/fakebin"
mkdir -p "$state" "$fakebin"
sent="$dir/captain-pane-received.log"; : > "$sent"
worker_pane="$dir/worker-pane.txt"; printf 'idle prompt $\n' > "$worker_pane"
composer="$dir/captain-composer.txt"
printf '╭─────╮\n│ >   │\n╰─────╯\n' > "$composer"

cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
COMPOSER="$FM_FAKE_COMPOSER"; WORKER="$FM_FAKE_WORKER_PANE"
write_composer() {
  text=$1; width=$((${#text} + 4)); border=; i=0
  while [ "$i" -lt "$width" ]; do border="${border}─"; i=$((i + 1)); done
  printf '╭%s╮\n│ > %s │\n╰%s╯\n' "$border" "$text" "$border" > "$COMPOSER"
}
target_of() { t=""; while [ "$#" -gt 0 ]; do case "$1" in -t) t="${2:-}"; shift 2; continue ;; esac; shift; done; printf '%s' "$t"; }
case "${1:-}" in
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    for a in "$@"; do [ "$a" = "-p" ] && printf 'fakepane\n'; done
    exit 0 ;;
  list-windows) printf '%s\n' "$FM_FAKE_TMUX_WINDOW"; exit 0 ;;
  capture-pane)
    shift; t=$(target_of "$@")
    case "$t" in
      "$FM_FAKE_TMUX_WINDOW"*) cat "$WORKER" 2>/dev/null ;;
      *) cat "$COMPOSER" 2>/dev/null ;;
    esac
    exit 0 ;;
  send-keys)
    shift; text=""; is_enter=0; lit=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) shift ;; -l) lit=1 ;; Enter) is_enter=1 ;;
        *) [ "$lit" = 1 ] && text="$1" ;;
      esac
      shift
    done
    if [ "$is_enter" = 1 ]; then printf '[SUBMIT]\n' >> "$FM_FAKE_SENT"; write_composer ""
    elif [ "$lit" = 1 ]; then printf '%s\n' "$text" >> "$FM_FAKE_SENT"; write_composer "$text"; fi
    exit 0 ;;
esac
exit 1
SH
chmod +x "$fakebin/tmux"

export FM_TEST_DAEMON_SOURCED=1
# shellcheck source=/dev/null
. "$ROOT/bin/fm-supervise-daemon.sh"

export PATH="$fakebin:$PATH"
export FM_STATE_OVERRIDE="$state" FM_HOME="$dir"
export FM_FAKE_TMUX_WINDOW="$WIN" FM_FAKE_WORKER_PANE="$worker_pane"
export FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent"
export FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET="firstmate:0"
export FM_STALE_ESCALATE_SECS=240 FM_ESCALATE_BATCH_SECS=90
export FM_INJECT_CONFIRM_SLEEP=0.05 FM_WEDGE_ALARM_CHANNEL=off
afk_enter "$state" >/dev/null 2>&1

say() { printf '%s\n' "$*"; }
marker_state() {
  if [ -e "$state/.subsuper-stale-$KEY" ]; then say "        possible-wedge marker: PRESENT (worker still being aged for a hang)"
  else say "        possible-wedge marker: ABSENT  (no hang timer running for this worker)"; fi
}

say "=============================================================="
say " $LABEL"
say "=============================================================="
say ""
say "[00:00] captain is AFK; worker window $WIN is under daemon supervision."
say "        worker appends its own status line:"
say "          $NOTE"
printf '%s\n' "$NOTE" > "$state/$TASK.status"
say ""
say "[00:00] daemon wake #1 (signal: the status file changed)"
d=$(classify_signal "$state/$TASK.status" "$state")
say "        classify_signal -> $d"
handle_wake "signal: $state/$TASK.status" "$state"
marker_state
say ""

say "[00:04] worker has produced nothing since. daemon wake #2 (stale: $WIN)"
d=$(classify_stale "$WIN" "$state")
say "        classify_stale  -> $d"
handle_wake "stale: $WIN" "$state"
marker_state
say ""

say "[00:08] still nothing. daemon wake #3 (stale: $WIN, status unchanged)"
d=$(classify_stale "$WIN" "$state")
say "        classify_stale  -> $d"
handle_wake "stale: $WIN" "$state"
marker_state
say ""

say "[00:12] >4 min of silence. housekeeping rechecks the worker pane (idle)."
if [ -e "$state/.subsuper-stale-$KEY" ]; then
  echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$KEY"
fi
housekeeping "$state" >/dev/null 2>&1
say "        escalation buffer now holds:"
if [ -s "$state/.subsuper-escalations" ]; then sed 's/^/          | /' "$state/.subsuper-escalations"
else say "          | (empty)"; fi
say ""

say "[00:13] daemon flushes the digest into the captain's supervisor pane."
: > "$sent"
if escalate_flush "$state" >/dev/null 2>&1; then :; fi
say ""
say "--------------------------------------------------------------"
say "WHAT THE CAPTAIN ACTUALLY RECEIVES IN THEIR PANE:"
say "--------------------------------------------------------------"
if [ -s "$sent" ]; then grep -v '^\[SUBMIT\]$' "$sent" | sed 's/^/  /'
else say "  (nothing - the captain is never told this worker is wedged)"; fi
say ""
if grep -q 'possible wedge' "$sent" 2>/dev/null; then
  say "RESULT: the hung worker IS surfaced as a possible wedge."
else
  say "RESULT: the hung worker is NEVER surfaced as a possible wedge."
fi
rm -rf "$dir"
