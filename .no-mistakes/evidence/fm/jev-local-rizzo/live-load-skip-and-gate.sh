#!/usr/bin/env bash
# Live demo: load-spike skip (no day pause) then same-day resume against rizzo serve on 127.0.0.1:8017,
# and proof the backend gate forks no process for a home without config/jev-endpoint.
set -u
ROOT=${ROOT:?}
T=$(mktemp -d); home=$T/home; mkdir -p $home/state $home/config
printf 'http://127.0.0.1:8017\n' > $home/config/jev-endpoint
printf '4\n' > $home/config/jev-max-load
run() { FM_HOME=$home FM_STATE_OVERRIDE=$home/state FM_JEV_FOREGROUND=1 "$@"; }
q() { printf '%s\t%s\tsignal\tlive1.status\tsignal: live1.status: working: step %s\n' 1790000000 "$1" "$1" >> $home/state/.wake-queue; }
printf 'working: implementing the fix\n' > $home/state/live1.status
echo "== drain 1: 1-minute load 9.5 >= ceiling 4 =="
q 1; run env FM_JEV_LOAD_OVERRIDE=9.5 "$ROOT/bin/fm-wake-drain.sh" >/dev/null
jq -c 'select(.ev=="jev") | {id,outcome,why}' $home/state/jev/shadow.jsonl
[ -e $home/state/jev/disabled ] && echo "state/jev/disabled: PRESENT ($(cat $home/state/jev/disabled))" || echo "state/jev/disabled: absent (no day pause)"
echo "== drain 2: load back to 0.5, same day =="
q 2; run env FM_JEV_LOAD_OVERRIDE=0.5 "$ROOT/bin/fm-wake-drain.sh" >/dev/null
jq -c 'select(.ev=="jev") | {id,outcome,why,model,choice,cost,ms}' $home/state/jev/shadow.jsonl
[ -e $home/state/jev/disabled ] && echo "state/jev/disabled: PRESENT" || echo "state/jev/disabled: absent"
echo "== status =="
run "$ROOT/bin/fm-jev.sh" status
echo "== backend gate process cost (fake grep on PATH logs every exec) =="
mkdir -p $T/bin; printf '#!/bin/sh\necho grep >> %s/grep.log\nexec /usr/bin/grep "$@"\n' $T > $T/bin/grep; chmod +x $T/bin/grep
for case in none blank local; do
  h=$T/g-$case; mkdir -p $h/state $h/config; : > $T/grep.log
  case $case in blank) printf '  \n' > $h/config/jev-endpoint;; local) printf 'http://127.0.0.1:8017\n' > $h/config/jev-endpoint;; esac
  r=$(PATH=$T/bin:$PATH bash -c ". $ROOT/bin/fm-jev-lib.sh; fm_jev_backend $h $h/state || echo disabled")
  echo "$case endpoint file -> backend=$r, grep execs=$(wc -l < $T/grep.log | tr -d ' ')"
done
rm -rf $T
