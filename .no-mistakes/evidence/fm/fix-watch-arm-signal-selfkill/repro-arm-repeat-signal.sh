#!/usr/bin/env bash
# Manual repro of the arm self-kill: start the REAL bin/fm-watch-arm.sh, hold
# its own cycle-log lock (real production contention), then send TERM twice so
# the second copy lands while handle_arm_signal is still inside cleanup.
set -u
ROOT=$1        # worktree root
OUTDIR=$2      # where to write the transcript
LABEL=$3

ARM="$ROOT/bin/fm-watch-arm.sh"
LIB="$ROOT/bin/fm-wake-lib.sh"
dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-arm-repro.XXXXXX")
state="$dir/state"; mkdir -p "$state"
armout="$OUTDIR/arm-stdout.$LABEL.txt"
FM_ROOT_OVERRIDE=$(mktemp -d "${TMPDIR:-/tmp}/fm-arm-nogit.XXXXXX")
export FM_ROOT_OVERRIDE

is_live() { kill -0 "$1" 2>/dev/null && [ "$(ps -p "$1" -o stat= 2>/dev/null)" != "" ] && case "$(ps -p "$1" -o stat=)" in Z*) return 1;; esac; }

FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$ARM" > "$armout" 2>&1 &
armpid=$!
i=0
while [ "$i" -lt 80 ]; do grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break; sleep 0.1; i=$((i+1)); done
grep -qF 'watcher: started pid=' "$armout" || { echo "ARM DID NOT START"; cat "$armout"; exit 2; }
watcher=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)

FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_lock_try_acquire "$2" && sleep 0.35' _ "$LIB" "$state/.watch-cycle-exits.lock" &
holdpid=$!
sleep 0.05
kill -TERM "$armpid" 2>/dev/null
sleep 0.15
kill -TERM "$armpid" 2>/dev/null
wait "$armpid" 2>/dev/null; status=$?
wait "$holdpid" 2>/dev/null || true

# give an orphan a moment to be reaped if the arm did tear it down
i=0; while [ "$i" -lt 30 ] && kill -0 "$watcher" 2>/dev/null; do sleep 0.1; i=$((i+1)); done

{
  echo "=== $LABEL : bin/fm-watch-arm.sh under a repeat SIGTERM during its own cleanup ==="
  echo
  echo "--- arm stdout (what lands in state/.claude-autoarm-output.*) ---"
  cat "$armout"
  echo
  echo "--- arm exit status ---"
  echo "$status   (128+15 = 143 is the correct TERM status)"
  echo
  echo "--- cycle-exit ledger: state/.watch-cycle-exits.log ---"
  cat "$state/.watch-cycle-exits.log" 2>/dev/null || echo "(no ledger row written)"
  echo
  echo "--- child watcher pid=$watcher still alive? ---"
  if kill -0 "$watcher" 2>/dev/null; then echo "YES - ORPHANED WATCHER ($(ps -p "$watcher" -o stat=,comm= 2>/dev/null))"; else echo "no - watcher torn down"; fi
  echo
  echo "--- stale singleton lock state/.watch.lock present? ---"
  if [ -e "$state/.watch.lock" ]; then echo "YES - STALE LOCK LEFT BEHIND"; else echo "no - lock released"; fi
} > "$OUTDIR/transcript.$LABEL.txt" 2>&1

kill -KILL "$watcher" 2>/dev/null || true
rm -rf "$dir" "$FM_ROOT_OVERRIDE"
cat "$OUTDIR/transcript.$LABEL.txt"
