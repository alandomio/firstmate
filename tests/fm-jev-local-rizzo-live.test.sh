#!/usr/bin/env bash
# tests/fm-jev-local-rizzo-live.test.sh - opt-in live proof that bin/fm-jev.sh's
# local backend classifies a real wake through a real Jev-compatible server
# (Rizzo Flow's `rizzo serve`), not just the fake curl the portable suite
# (tests/fm-jev.test.sh) uses.
#
# Run explicitly with FM_JEV_RIZZO_LIVE=1 against a server already listening on
# FM_JEV_RIZZO_LIVE_URL (default http://127.0.0.1:8017; docs/configuration.md
# "Jev shadow wake triage" documents the loopback-only contract this exercises).
# This test never starts, stops, or otherwise manages that server's lifecycle -
# it must already be up, and stays up afterward. No cost is incurred: a local
# model has no per-request price.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

JEV="$ROOT/bin/fm-jev.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
URL="${FM_JEV_RIZZO_LIVE_URL:-http://127.0.0.1:8017}"

if [ "${FM_JEV_RIZZO_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_JEV_RIZZO_LIVE=1 (and optionally FM_JEV_RIZZO_LIVE_URL) to run the live Rizzo Flow guard"
  exit 0
fi

command -v jq >/dev/null 2>&1 || { echo "not ok - jq is required" >&2; exit 1; }
curl -sS --max-time 3 "$URL/v1/models" >/dev/null 2>&1 \
  || { echo "not ok - FM_JEV_RIZZO_LIVE=1 but no server answered $URL/v1/models; start one with 'rizzo serve' first" >&2; exit 1; }

TMP_ROOT=$(fm_test_tmproot fm-jev-rizzo-live)
home="$TMP_ROOT/home"
mkdir -p "$home/state" "$home/config"
printf '%s\n' "$URL" > "$home/config/jev-endpoint"
# The load ceiling itself is covered deterministically by the portable suite
# (FM_JEV_LOAD_OVERRIDE); raise it here so this machine's own, possibly
# elevated, real load never masks whether the live classify path works.
printf '1000\n' > "$home/config/jev-max-load"
printf 'working: implementing the fix\n' > "$home/state/live1.status"
printf '1790000000\t1\tsignal\tlive1.status\tsignal: live1.status: working: implementing the fix\n' \
  > "$home/state/.wake-queue"

out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_JEV_FOREGROUND=1 "$DRAIN" 2>"$TMP_ROOT/drain.err") \
  || fail "the drain failed against the live server: $(cat "$TMP_ROOT/drain.err")"
[[ "$out" == *live1.status* ]] || fail "the wake was not presented: $out"

log="$home/state/jev/shadow.jsonl"
[ -s "$log" ] || fail "no shadow log was written against the live server"
row=$(jq -c 'select(.ev == "jev" and .outcome == "classified")' "$log" 2>/dev/null | head -n1)
[ -n "$row" ] || fail "the live server did not classify the wake: $(cat "$log")"

model=$(printf '%s' "$row" | jq -r '.model')
choice=$(printf '%s' "$row" | jq -r '.choice')
cost=$(printf '%s' "$row" | jq -r '.cost')
ms=$(printf '%s' "$row" | jq -r '.ms')
case "$choice" in
  firstmate|absorbable|captain|doubt) ;;
  *) fail "unexpected choice from the live server: $choice" ;;
esac
[ "$cost" = null ] \
  || fail "a local response reported a cost ($cost); the no-spend-cap assumption needs re-checking before go-live"
[ -n "$model" ] && [ "$model" != null ] || fail "the response carried no model, so the log could not show which backend answered"

status_out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$JEV" status)
[[ "$status_out" == *"local backend (config/jev-endpoint = $URL)"* ]] \
  || fail "status did not report the live local backend: $status_out"

pass "classified live against $URL in ${ms}ms: model=$model choice=$choice cost=$cost"
