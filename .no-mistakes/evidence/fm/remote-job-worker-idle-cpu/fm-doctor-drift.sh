#!/usr/bin/env bash
# Do fm-remote-doctor and fm_remote_job_probe agree on worker freshness once
# the probe window is reconfigured? Simulates the future config the review
# finding named: FM_REMOTE_JOB_PROBE_FRESHNESS_SECONDS raised 10 -> 30.
set -u
WT=/Users/a.domio/.no-mistakes/worktrees/38493c8a7325/01M244GMF3418Y96ZAMWMZMQGH
BASE_REF=55db226eb644b50ae1157b5f56f7fe542eb25fa0
AGE=${AGE:-15}
TMP=$(mktemp -d /tmp/fm-drift-XXXXXX); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf -- "$TMP"' EXIT

variant() { # <name> <doctor-source: BASE|NEW>
  local v="$1"
  local which="$2"
  local root="$TMP/x$RANDOM"
  local home="$root-home"
  local state="$root-jobs"
  cp -R "$WT/bin" "$root-bin"; mkdir -p "$root"; mv "$root-bin" "$root/bin"
  printf 'fixture\n' > "$root/AGENTS.md"
  [ "$which" = NEW ] || git -C "$WT" show "$BASE_REF:bin/fm-remote-doctor.sh" > "$root/bin/fm-remote-doctor.sh"
  chmod +x "$root/bin/fm-remote-doctor.sh"
  # The reconfiguration under test: widen the probe's freshness window.
  sed -i '' 's/^FM_REMOTE_JOB_PROBE_FRESHNESS_SECONDS=10$/FM_REMOTE_JOB_PROBE_FRESHNESS_SECONDS=30/' "$root/bin/fm-remote-job-lib.sh"
  mkdir -p "$home"; chmod 700 "$home"
  # A real worker publishes the ready/identity/pid trio, then we age only its
  # heartbeat so the probe freshness window is the single thing under test.
  local wpid i
  git -C "$root" init -q -b main
  git -C "$root" config user.email t@example.com
  git -C "$root" config user.name T
  git -C "$root" add -A >/dev/null 2>&1
  git -C "$root" commit -qm fixture >/dev/null 2>&1
  # A 29s heartbeat interval keeps the live worker from rewriting worker.ready
  # while its heartbeat is backdated, so both readers see the same aged file.
  HOME="$home" PATH=/usr/bin:/bin:/usr/sbin:/sbin FM_ROOT_OVERRIDE="$root" \
    FM_REMOTE_JOB_STATE_ROOT="$state" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
    FM_REMOTE_JOB_HEARTBEAT_INTERVAL_SECONDS=29 \
    "$root/bin/fm-remote-job-worker.sh" --serve >/dev/null 2>"$root-worker.err" &
  wpid=$!
  for i in $(seq 1 300); do [ -f "$state/worker.ready" ] && break; sleep 0.05; done
  [ -f "$state/worker.ready" ] || { echo "FATAL: worker not ready: $(cat "$root-worker.err")" >&2; exit 1; }
  [ -f "$state/worker.identity" ] || { echo "FATAL: no identity published" >&2; exit 1; }
  touch -t "$(date -v-${AGE}S '+%Y%m%d%H%M.%S')" "$state/worker.ready"

  local probe doctorline
  if ( export FM_REMOTE_JOB_STATE_ROOT="$state"; unset FM_REMOTE_JOB_ACTIVE
       . "$root/bin/fm-remote-job-lib.sh"; fm_remote_job_probe "$home" ); then
    probe="READY"; else probe="NOT READY"; fi
  doctorline=$(HOME="$home" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    FM_REMOTE_JOB_STATE_ROOT="$state" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
    FM_REMOTE_JOB_ACTIVE= PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    "$root/bin/fm-remote-doctor.sh" 2>&1 | grep '^check remote-job-probe=' || true)
  kill -TERM "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
  printf '%-22s fm_remote_job_probe: %-9s | doctor: %s\n' "$v" "$probe" "${doctorline#check remote-job-probe=}"
  if [ -n "${DEBUG:-}" ]; then
    echo "  file:     $(cat "$state/worker.identity")"
    ( export FM_REMOTE_JOB_STATE_ROOT="$state"; HOME="$home"; PATH=/usr/bin:/bin:/usr/sbin:/sbin
      . "$root/bin/fm-remote-job-lib.sh"; echo "  computed: $(fm_remote_job_code_identity "$root" "$home" || echo FAILED)" )
  fi
}

echo "worker.ready heartbeat aged ${AGE}s; FM_REMOTE_JOB_PROBE_FRESHNESS_SECONDS reconfigured to 30"
variant "base-doctor(55db226)" BASE
variant "fixed-doctor(2621c0f)" NEW
