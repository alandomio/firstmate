#!/usr/bin/env bash
# Manual end-to-end demo of gated Jev absorption against the REAL local Rizzo Flow
# server (http://127.0.0.1:8017). Uses a throwaway home under /tmp.
set -u
WT=/Users/a.domio/.no-mistakes/worktrees/38493c8a7325/01M3JJ086XBMN4XV9A8FMEMZSY
JEV="$WT/bin/fm-jev.sh"; DRAIN="$WT/bin/fm-wake-drain.sh"
H=$(mktemp -d /tmp/fm-jev-absorb-demo.XXXXXX); mkdir -p "$H/state" "$H/config"
export FM_HOME="$H" FM_STATE_OVERRIDE="$H/state"
run() { printf '\n$ %s\n' "$*"; "$@"; printf '[exit %s]\n' "$?"; }
printf 'http://127.0.0.1:8017\n' > "$H/config/jev-endpoint"
printf 'working: compiling step 2 of 5, tests next https://internal.example/ci/42 /Users/me/wt/secret\n' > "$H/state/task.status"

echo "=== 1. absorption off by default (config/jev-absorb absent)"
run "$JEV" status
run "$JEV" absorb-try --kind signal --task task --reason "signal: $H/state/task.status"
ls "$H/state/jev/absorbed.jsonl" 2>/dev/null || echo "(no digest written)"

echo; echo "=== 2. requested (config/jev-absorb=on), no override, no shadow data -> gate NOT met, refuses"
printf 'on\n' > "$H/config/jev-absorb"
run "$JEV" status
run "$JEV" absorb-gate
run "$JEV" absorb-try --kind signal --task task --reason "signal: $H/state/task.status"

echo; echo "=== 3. captain override -> gate skipped; real Rizzo Flow classifies; high threshold 0.9 floor applies"
printf 'on\noverride\n' > "$H/config/jev-absorb"
run "$JEV" status
for i in 1 2 3; do
  run "$JEV" absorb-try --kind signal --task task --reason "signal: $H/state/task.status"
done
echo "--- digest (state/jev/absorbed.jsonl):"; cat "$H/state/jev/absorbed.jsonl" 2>/dev/null || echo "(empty: real classifier did not answer absorbable >= 0.9)"

echo; echo "=== 4. next drain surfaces the digest once; a second drain does not repeat it"
run "$DRAIN"
run "$DRAIN"

echo; echo "=== 5. threshold below the 0.9 floor refuses outright"
printf '0.5\n' > "$H/config/jev-absorb-threshold"
run "$JEV" status
run "$JEV" absorb-try --kind signal --task task --reason "signal: $H/state/task.status"
rm -f "$H/config/jev-absorb-threshold"

echo; echo "=== 6. never-eligible status verbs (override on) -> refuse without dialing"
for line in 'done: shipped PR 12' 'needs-decision: pick base branch' 'blocked: waiting on creds' 'failed: build broke'; do
  printf '%s\n' "$line" > "$H/state/task.status"
  printf '\n# status: %s' "$line"
  run "$JEV" absorb-try --kind signal --task task --reason "signal: $H/state/task.status"
done
printf 'working: compiling\n' > "$H/state/task.status"

echo; echo "=== 7. OpenRouter backend (no jev-endpoint, key present) -> refused even with override"
mv "$H/config/jev-endpoint" "$H/config/jev-endpoint.off"
printf 'OPENROUTER_API_KEY=sk-or-demo-not-real\n' > "$H/.env"
run "$JEV" status
run "$JEV" absorb-try --kind signal --task task --reason "signal: $H/state/task.status"
rm -f "$H/.env"; mv "$H/config/jev-endpoint.off" "$H/config/jev-endpoint"

echo; echo "=== 8. classifier down / hung -> falls through within the per-request timeout"
printf 'http://127.0.0.1:1\n' > "$H/config/jev-endpoint"
printf '\n# nothing listening on 127.0.0.1:1'
start=$(date +%s); run "$JEV" absorb-try --kind signal --task task --reason "signal: x"; echo "elapsed: $(( $(date +%s) - start ))s"
python3 - <<'PY' &
import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(("127.0.0.1",18917)); s.listen(5)
c,_=s.accept(); time.sleep(30)
PY
HPID=$!; sleep 0.5
printf 'http://127.0.0.1:18917\n' > "$H/config/jev-endpoint"; printf '2\n' > "$H/config/jev-timeout"
printf '\n# server accepts but never answers; config/jev-timeout=2'
start=$(date +%s); run "$JEV" absorb-try --kind signal --task task --reason "signal: x"; echo "elapsed: $(( $(date +%s) - start ))s"
kill $HPID 2>/dev/null; wait $HPID 2>/dev/null
echo "--- digest line count after all refusals: $(wc -l < "$H/state/jev/absorbed.jsonl" 2>/dev/null || echo 0)"
rm -rf "$H"
