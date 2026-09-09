#!/usr/bin/env bash
# Base-vs-fixed idle cost harness for bin/fm-remote-job-worker.sh --serve.
set -u
WT=/Users/a.domio/.no-mistakes/worktrees/38493c8a7325/01M244GMF3418Y96ZAMWMZMQGH
BASE_REF=55db226eb644b50ae1157b5f56f7fe542eb25fa0
WINDOW=${WINDOW:-30}
TMP=$(mktemp -d /tmp/fm-idle-XXXXXX); TMP=$(cd "$TMP" && pwd -P)
trap 'pkill -f "$TMP/" 2>/dev/null; rm -rf -- "$TMP"' EXIT

build_root() { # <variant> <ref|WORKTREE>
  local v=$1 ref=$2 root="$TMP/$1-root" f
  mkdir -p "$root/bin"
  for f in fm-remote-job-lib.sh fm-remote-job-worker.sh fm-remote-delta-read.sh; do
    if [ "$ref" = WORKTREE ]; then cp "$WT/bin/$f" "$root/bin/$f"
    else git -C "$WT" show "$ref:bin/$f" > "$root/bin/$f"; fi
  done
  chmod +x "$root/bin"/*.sh
  printf 'fixture\n' > "$root/AGENTS.md"
  git -C "$root" init -q -b main
  git -C "$root" config user.email t@example.com
  git -C "$root" config user.name T
  git -C "$root" add AGENTS.md bin
  git -C "$root" commit -qm fixture
  printf '%s\n' "$root"
}

cputime() { # <root>  -> total CPU seconds of every live worker process
  local root=$1
  ps -A -o pid=,time=,args= | grep -F "$root/bin/fm-remote-job-worker.sh" | grep -v grep \
    | awk '{t=$2; n=split(t,p,":"); s=0; for(i=1;i<=n;i++) s=s*60+p[i]; total+=s} END {printf "%.2f", total+0}'
}

run_idle() { # <variant> <root> <shim: yes|no>
  local v=$1 root=$2 shim=$3 home="$TMP/$1-home" state="$TMP/$1-jobs" bin="$TMP/$1-bin"
  mkdir -p "$home"; chmod 700 "$home"
  local path=/usr/bin:/bin:/usr/sbin:/sbin
  if [ "$shim" = yes ]; then
    mkdir -p "$bin"
    local t
    for t in mktemp date chmod mv; do
      cat > "$bin/$t" <<SH
#!/bin/bash
printf 'c\n' >> "$TMP/$v-$t.count"
exec "$(command -v "$t")" "\$@"
SH
      chmod +x "$bin/$t"; : > "$TMP/$v-$t.count"
    done
    path="$bin:$path"
  fi
  HOME="$home" PATH="$path" FM_ROOT_OVERRIDE="$root" \
    FM_REMOTE_JOB_STATE_ROOT="$state" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
    "$root/bin/fm-remote-job-worker.sh" --serve > "$TMP/$v.out" 2> "$TMP/$v.err" &
  local pid=$!
  local i
  for i in $(seq 1 300); do [ -f "$state/worker.ready" ] && break; sleep 0.05; done
  [ -f "$state/worker.ready" ] || { echo "FATAL: $v worker never became ready; $(cat "$TMP/$v.err")" >&2; exit 1; }
  if [ "$shim" = yes ]; then for t in mktemp date chmod mv; do : > "$TMP/$v-$t.count"; done; fi
  local before; before=$(cputime "$root")
  sleep "$WINDOW"
  local after; after=$(cputime "$root")
  IDLE_CPU=$(awk -v a="$after" -v b="$before" 'BEGIN{printf "%.2f", a-b}')
  kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
}

BASE_ROOT=$(build_root base "$BASE_REF")
NEW_ROOT=$(build_root new WORKTREE)
echo "window=${WINDOW}s  defaults: poll=0.05s heartbeat=3s reap=60s"
echo

echo "=== fork counts over a ${WINDOW}s idle window (shimmed mktemp/chmod/mv/date) ==="
run_idle base-shim "$BASE_ROOT" yes
run_idle new-shim  "$NEW_ROOT"  yes
printf '%-10s %10s %10s %10s %10s\n' tool base fixed reduction ''
for t in mktemp chmod mv date; do
  b=$(wc -l < "$TMP/base-shim-$t.count" | tr -d ' ')
  n=$(wc -l < "$TMP/new-shim-$t.count" | tr -d ' ')
  printf '%-10s %10s %10s %9sx\n' "$t" "$b" "$n" "$(awk -v b="$b" -v n="$n" 'BEGIN{printf "%.0f", (n?b/n:b)}')"
done
bt=0; nt=0
for t in mktemp chmod mv date; do
  bt=$((bt + $(wc -l < "$TMP/base-shim-$t.count" | tr -d ' ')))
  nt=$((nt + $(wc -l < "$TMP/new-shim-$t.count" | tr -d ' ')))
done
printf '%-10s %10s %10s %9sx\n' TOTAL "$bt" "$nt" "$(awk -v b="$bt" -v n="$nt" 'BEGIN{printf "%.0f", (n?b/n:b)}')"
echo

echo "=== idle CPU time over a ${WINDOW}s window (no shims, ps -o time=) ==="
run_idle base-cpu "$BASE_ROOT" no; BASE_CPU=$IDLE_CPU
run_idle new-cpu  "$NEW_ROOT"  no; NEW_CPU=$IDLE_CPU
awk -v b="$BASE_CPU" -v n="$NEW_CPU" -v w="$WINDOW" \
  'BEGIN{printf "base  : %5.2fs CPU over %ss wall = %.2f%% of one core\nfixed : %5.2fs CPU over %ss wall = %.2f%% of one core\n", b,w,100*b/w, n,w,100*n/w}'
