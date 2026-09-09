#!/usr/bin/env bash
# Dispatch pickup latency, base worker vs fixed worker.
set -u
WT=/Users/a.domio/.no-mistakes/worktrees/38493c8a7325/01M244GMF3418Y96ZAMWMZMQGH
BASE_REF=55db226eb644b50ae1157b5f56f7fe542eb25fa0
SAMPLES=${SAMPLES:-10}
TMP=$(mktemp -d /tmp/fm-pickup-XXXXXX); TMP=$(cd "$TMP" && pwd -P)
trap 'pkill -f "$TMP/" 2>/dev/null; rm -rf -- "$TMP"' EXIT

build_root() {
  local v=$1 ref=$2 root="$TMP/$1-root" f
  mkdir -p "$root/bin"
  for f in fm-remote-job-lib.sh fm-remote-job-worker.sh fm-remote-delta-read.sh; do
    if [ "$ref" = WORKTREE ]; then cp "$WT/bin/$f" "$root/bin/$f"
    else git -C "$WT" show "$ref:bin/$f" > "$root/bin/$f"; fi
  done
  cat > "$root/bin/fm-touch-job.sh" <<'SH'
#!/bin/bash
printf 'ran\n' > "$1"
SH
  chmod +x "$root/bin"/*.sh
  printf 'fixture\n' > "$root/AGENTS.md"
  git -C "$root" init -q -b main
  git -C "$root" config user.email t@example.com
  git -C "$root" config user.name T
  git -C "$root" add AGENTS.md bin
  git -C "$root" commit -qm fixture
  printf '%s\n' "$root"
}

now() { perl -MTime::HiRes=time -e 'printf "%.6f", time'; }

measure() { # <variant> <root>
  local v=$1 root=$2 home="$TMP/$1-home" rhome="$TMP/$1-remote-home" state="$TMP/$1-jobs"
  mkdir -p "$home" "$rhome"; chmod 700 "$home"
  HOME="$home" PATH=/usr/bin:/bin:/usr/sbin:/sbin FM_ROOT_OVERRIDE="$root" \
    FM_REMOTE_JOB_STATE_ROOT="$state" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
    "$root/bin/fm-remote-job-worker.sh" --serve > "$TMP/$v.out" 2> "$TMP/$v.err" &
  local pid=$! i
  for i in $(seq 1 300); do [ -f "$state/worker.ready" ] && break; sleep 0.05; done
  [ -f "$state/worker.ready" ] || { echo "FATAL: $v not ready: $(cat "$TMP/$v.err")" >&2; exit 1; }
  (
    export FM_REMOTE_JOB_STATE_ROOT="$state" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
    # shellcheck source=/dev/null
    . "$root/bin/fm-remote-job-lib.sh"
    for i in $(seq 1 "$SAMPLES"); do
      local_marker="$TMP/$v-marker-$i"
      t0=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
      fm_remote_job_stage "$home" "$root" "$rhome" fm-touch-job.sh "$local_marker" </dev/null >/dev/null || exit 1
      job="$state/jobs/$FM_REMOTE_JOB_ID"
      perl -e '
        use Time::HiRes qw(time sleep);
        my ($job,$t0)=@ARGV; my ($run,$done);
        while (1) {
          my $s=""; if (open my $fh,"<","$job/state") { $s=<$fh>||""; chomp $s; close $fh; }
          $run  = time - $t0 if !defined($run)  && $s ne "queued" && $s ne "";
          if ($s eq "done") { $done = time - $t0; last }
          last if time - $t0 > 20;
          sleep 0.001;
        }
        printf "%.3f %.3f\n", ($run//-1)*1000, ($done//-1)*1000;
      ' "$job" "$t0"
    done
  ) > "$TMP/$v.samples"
  kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  awk -v v="$v" '{r[NR]=$1; d[NR]=$2; sr+=$1; sd+=$2}
    END{n=NR; asort_r=0;
      # simple min/max
      minr=r[1]; maxr=r[1]; mind=d[1]; maxd=d[1];
      for(i=1;i<=n;i++){ if(r[i]<minr)minr=r[i]; if(r[i]>maxr)maxr=r[i];
                         if(d[i]<mind)mind=d[i]; if(d[i]>maxd)maxd=d[i] }
      printf "%-6s n=%d  pickup(queued->running) mean %6.1fms  min %6.1f  max %6.1f   |  end-to-end(stage->done) mean %6.1fms  min %6.1f  max %6.1f\n",
        v, n, sr/n, minr, maxr, sd/n, mind, maxd }' "$TMP/$v.samples"
}

BASE_ROOT=$(build_root base "$BASE_REF")
NEW_ROOT=$(build_root new WORKTREE)
echo "dispatch pickup latency, $SAMPLES trivial jobs per variant (defaults: poll=0.05s)"
measure base "$BASE_ROOT"
measure new  "$NEW_ROOT"
