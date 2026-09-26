#!/usr/bin/env bash
# Manual end-to-end demo of Jev shadow mode with a fake curl (no network).
set -u
R=$1 T=$2
KEY=sk-or-v1-demo0000000000
mk() { mkdir -p "$T/$1/state" "$T/$1/config" "$T/$1/bin" "$T/$1/curl"; cat > "$T/$1/bin/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG/argv"; cat > "$FAKE_LOG/stdin.cfg"
out='' body=''; while [ $# -gt 0 ]; do case $1 in -o) out=$2; shift;; --data-binary) body=${2#@}; shift;; esac; shift; done
cp "$body" "$FAKE_LOG/body.json"
case "${MODE:-ok}" in timeout) exit 28;; esac
printf '{"model":"typesafe/jev-1.13","answers":{"handling":{"type":"choice","choice":"absorbable","confidence":0.83,"probabilities":{"firstmate":0.1,"absorbable":0.83,"captain":0.07}}},"usage":{"cost":0.0000196}}' > "$out"; printf 200
SH
chmod +x "$T/$1/bin/curl"; }
run() { h=$T/$1; shift; FM_HOME=$h FM_STATE_OVERRIDE=$h/state PATH=$h/bin:$PATH FAKE_LOG=$h/curl FM_JEV_FOREGROUND=1 "$@"; }
mk off; mk on
printf 'OPENROUTER_API_KEY=%s\n' "$KEY" > "$T/on/.env"
for h in off on; do
  printf 'done: PR https://github.com/o/r/pull/7 green, notes in /home/me/wt/report.md\n' > "$T/$h/state/task2.status"
  printf '1790000000\t1\tsignal\ttask2.status\tsignal: task2.status: done: PR https://github.com/o/r/pull/7 green\n' > "$T/$h/state/.wake-queue"
done
echo '### 1. status without key (ambient OPENROUTER_API_KEY set) vs with .env key'
run off env OPENROUTER_API_KEY=$KEY "$R/bin/fm-jev.sh" status; run on "$R/bin/fm-jev.sh" status
echo; echo '### 2. drain output: Jev off vs Jev on (must be identical)'
A=$(run off env OPENROUTER_API_KEY=$KEY "$R/bin/fm-wake-drain.sh" 2>&1); B=$(run on "$R/bin/fm-wake-drain.sh" 2>&1)
printf '%s\n' "$B"; norm() { sed -E "s/--recovery-generation [^ ]+/--recovery-generation <nonce>/"; }; [ "$(printf "%s" "$A" | norm)" = "$(printf "%s" "$B" | norm)" ] && echo "=> IDENTICAL presentation (recovery-generation nonce normalized)" || { echo "=> DIFFERENT"; printf "%s\n" "$A"; }
echo "off home: state/jev exists? $([ -e $T/off/state/jev ] && echo yes || echo no); curl calls: $(cat $T/off/curl/argv 2>/dev/null | wc -l)"
echo; echo '### 3. request body sent to OpenRouter (masked) and curl argv (key absent?)'
jq . "$T/on/curl/body.json"; cat "$T/on/curl/argv"; grep -q "$KEY" "$T/on/curl/argv" && echo 'KEY IN ARGV!' || echo '=> key not in argv'
grep -rq "$KEY" "$T/on/state" && echo 'KEY ON DISK in state!' || echo '=> key not in state/'
echo; echo '### 4. ack, then shadow log'
ack=$(printf '%s\n' "$B" | sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run //p'); run on "$R/"$ack >/dev/null 2>&1
ls -l "$T/on/state/jev/"; cat "$T/on/state/jev/shadow.jsonl"
echo; echo '### 5. report'
run on "$R/bin/fm-jev.sh" report --days 7 || true
echo; echo '### 6. timeout pauses Jev for the day; wake still presented'
mk to; printf 'OPENROUTER_API_KEY=%s\n' "$KEY" > "$T/to/.env"; printf 'working\n' > $T/to/state/t3.status
printf '1790000000\t1\tsignal\tt3.status\tsignal: t3.status: working\n' > "$T/to/state/.wake-queue"
run to env MODE=timeout "$R/bin/fm-wake-drain.sh" 2>/dev/null | head -3
run to "$R/bin/fm-jev.sh" status; cat "$T/to/state/jev/shadow.jsonl" | grep -E 'skipped|disabled'
