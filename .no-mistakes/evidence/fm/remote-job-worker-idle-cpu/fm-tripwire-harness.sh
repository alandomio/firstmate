#!/usr/bin/env bash
# Deleted state root: does the worker fail fast, or does the reap sweep
# silently recreate an unowned state tree behind a still-serving worker?
set -u
WT=/Users/a.domio/.no-mistakes/worktrees/38493c8a7325/01M244GMF3418Y96ZAMWMZMQGH
TMP=$(mktemp -d /tmp/fm-trip-XXXXXX); TMP=$(cd "$TMP" && pwd -P)
trap 'pkill -f "$TMP/" 2>/dev/null; rm -rf -- "$TMP"' EXIT

check() { # <label> <ref|WORKTREE>
  local label="$1" ref="$2" root="$TMP/r$RANDOM" f
  local home="$root-home" state="$root-jobs"
  mkdir -p "$root/bin" "$home"; chmod 700 "$home"
  for f in fm-remote-job-lib.sh fm-remote-job-worker.sh fm-remote-delta-read.sh; do
    if [ "$ref" = WORKTREE ]; then cp "$WT/bin/$f" "$root/bin/$f"
    else git -C "$WT" show "$ref:bin/$f" > "$root/bin/$f"; fi
  done
  chmod +x "$root/bin"/*.sh
  printf 'fixture\n' > "$root/AGENTS.md"
  HOME="$home" PATH=/usr/bin:/bin:/usr/sbin:/sbin FM_ROOT_OVERRIDE="$root" \
    FM_REMOTE_JOB_STATE_ROOT="$state" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
    FM_REMOTE_JOB_HEARTBEAT_INTERVAL_SECONDS=9 FM_REMOTE_JOB_REAP_INTERVAL_SECONDS=1 \
    "$root/bin/fm-remote-job-worker.sh" --serve >/dev/null 2>"$root.err" &
  local pid=$! i
  for i in $(seq 1 300); do [ -f "$state/worker.ready" ] && break; sleep 0.05; done
  [ -f "$state/worker.ready" ] || { echo "FATAL: not ready: $(cat "$root.err")" >&2; exit 1; }
  rm -rf -- "$state"
  for i in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  local alive=no recreated=no owned=no rc=
  if kill -0 "$pid" 2>/dev/null; then
    alive=yes
    [ -d "$state" ] && recreated=yes
    { [ -e "$state/worker.lock" ] || [ -e "$state/worker.pid" ]; } && owned=yes
    kill -KILL "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  else
    rc=0; wait "$pid" 2>/dev/null || rc=$?
    [ -d "$state" ] && recreated=yes
  fi
  printf '%-22s worker still serving: %-3s | state root recreated: %-3s | recreated tree owned (lock/pid): %-3s | exit: %s\n' \
    "$label" "$alive" "$recreated" "$owned" "${rc:-killed}"
  printf '   worker stderr: %s\n' "$(tail -1 "$root.err" 2>/dev/null)"
}

echo "heartbeat=9s reap=1s; state root deleted right after the worker reports ready"
check "pre-fix(d5062fc)" d5062fc
check "fixed(2621c0f)"   WORKTREE
