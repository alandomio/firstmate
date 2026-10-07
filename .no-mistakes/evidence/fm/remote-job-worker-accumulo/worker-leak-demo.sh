#!/usr/bin/env bash
# Manual end-to-end demo: drive the remote job library the way a caller does
# against a throwaway fixture root, and count the worker processes it leaves.
# usage: worker-leak-demo.sh <code-root>
set -u
CODE=$1
T=$(mktemp -d /tmp/fm-leak-demo-XXXXXX)
ROOT="$T/remote-root"; HOMEDIR="$T/account"; FMHOME="$T/remote-home"
mkdir -p "$ROOT/bin" "$HOMEDIR" "$FMHOME"; chmod 700 "$HOMEDIR"
cp "$CODE/bin/fm-remote-job-lib.sh" "$CODE/bin/fm-remote-job-worker.sh" "$CODE/bin/fm-remote-delta-read.sh" "$ROOT/bin/"
printf '#!/bin/bash\nprintf "job ran\\n"\n' > "$ROOT/bin/fm-hello-job.sh"; chmod +x "$ROOT/bin"/*.sh
printf 'fixture\n' > "$ROOT/AGENTS.md"
git -C "$ROOT" init -q -b main; git -C "$ROOT" -c user.email=t@example.com -c user.name=T add -A
git -C "$ROOT" -c user.email=t@example.com -c user.name=T commit -qm fixture
export FM_REMOTE_JOB_STATE_ROOT="$T/remote-jobs" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
export FM_REMOTE_JOB_QUEUE_TIMEOUT=5 FM_REMOTE_JOB_TIMEOUT=5 FM_REMOTE_JOB_IDLE_TIMEOUT_SECONDS=3
. "$ROOT/bin/fm-remote-job-lib.sh"
workers() { pgrep -f "$ROOT/bin/fm-remote-job-worker.sh" | tr '\n' ' '; }
count() { pgrep -f "$ROOT/bin/fm-remote-job-worker.sh" | wc -l; }
serving() { pgrep -f "$ROOT/bin/fm-remote-job-worker.sh --serve" | wc -l; }
show() { printf '%-58s worker processes=%s (serving=%s) owner pid=%s\n' "$1" "$(count)" "$(serving)" "$(cat "$FM_REMOTE_JOB_STATE_ROOT/worker.pid" 2>/dev/null || echo none)"; }

fm_remote_job_ensure_worker "$ROOT" "$HOMEDIR" || echo "ensure failed: $FM_REMOTE_JOB_ERROR"
show "1. first caller ensures a worker"
OWNER=$(cat "$FM_REMOTE_JOB_STATE_ROOT/worker.pid")
kill -STOP "$OWNER"; touch -t 200001010000 "$FM_REMOTE_JOB_STATE_ROOT/worker.ready"
for i in 1 2 3 4 5; do fm_remote_job_start_linux_worker "$ROOT" "$HOMEDIR" >/dev/null 2>&1 || true; done
show "2. five callers arrive while its heartbeat is stale"
kill -CONT "$OWNER"
fm_remote_job_ensure_worker "$ROOT" "$HOMEDIR" || echo "ensure failed: $FM_REMOTE_JOB_ERROR"
fm_remote_job_stage "$HOMEDIR" "$ROOT" "$FMHOME" fm-hello-job.sh </dev/null >/dev/null
fm_remote_job_wait "$HOMEDIR" "$FM_REMOTE_JOB_ID" && printf '   job exit=%s stdout=%s\n' "$FM_REMOTE_JOB_EXIT" "$(cat "$FM_REMOTE_JOB_STATE_ROOT/jobs/$FM_REMOTE_JOB_ID/stdout" 2>/dev/null)"
show "3. a job completed, client now goes away"
sleep 8
show "4. 8s later (idle timeout configured to 3s)"
[ -d "$FM_REMOTE_JOB_STATE_ROOT/worker.lock" ] && echo "   worker.lock: still held" || echo "   worker.lock: released"
# cleanup: only the exact pids of this fixture's own worker script path
for p in $(workers); do kill -KILL "$p" 2>/dev/null; done
rm -rf "$T"
