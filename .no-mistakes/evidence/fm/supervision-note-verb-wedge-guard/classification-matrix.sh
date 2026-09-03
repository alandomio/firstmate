#!/usr/bin/env bash
# Runs the REAL status_is_captain_relevant() from a given tree over the status
# vocabulary a worker can actually write, so the before/after tables can be
# diffed cell by cell. Env prefix column shows configured-verb overrides.
set -u
ROOT=$1
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

row() {  # <env-assignment-or-"-"> <status line>
  local envs=$1 line=$2 verdict
  if [ "$envs" = "-" ]; then
    if status_is_captain_relevant "$line"; then verdict="captain-relevant"; else verdict="self-handled   "; fi
  else
    if env "$envs" bash -c '. "$0/bin/fm-classify-lib.sh"; status_is_captain_relevant "$1"' "$ROOT" "$line"; then
      verdict="captain-relevant"; else verdict="self-handled   "; fi
  fi
  printf '%-16s | %-42s | %s\n' "${envs}" "$line" "$verdict"
}

printf '%-16s | %-42s | %s\n' "CONFIG OVERRIDE" "STATUS LINE THE WORKER WROTE" "DAEMON VERDICT"
printf '%-16s-+-%-42s-+-%s\n' "----------------" "------------------------------------------" "----------------"
row - 'done: PR https://x/y/pull/1'
row - 'needs-decision [key=q1]: pick A or B'
row - 'blocked: no perms on the deploy key'
row - 'failed: build broke on arm64'
row - 'working: stage 2 setup complete'
row - 'working: rebased onto merged #76'
row - 'resolved [key=q1]: captain picked A'
row - 'captain-held [key=q1]: tracked by captain'
row - 'paused: waiting on upstream review'
row - 'note: plain informational update'
row - 'note: CANDIDATE - upstream already merged it'
row - 'note: PR ready checks green in branch'
row - 'merged'
row - 'PR ready https://x/y/pull/2'
row FM_CLASSIFY_RESOLVE_VERB=closed 'resolved: upstream merged the patch'
row FM_CLASSIFY_RESOLVE_VERB=closed 'closed: upstream merged the patch'
row FM_CLASSIFY_PAUSED_VERB=holding 'holding: merged upstream, awaiting review'
