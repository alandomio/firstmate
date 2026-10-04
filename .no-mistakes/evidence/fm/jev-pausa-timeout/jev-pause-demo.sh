#!/usr/bin/env bash
# Manual end-to-end walk through the Jev pause rule, driving the real
# bin/fm-wake-drain.sh and bin/fm-jev.sh against a fake curl (no network).
# Run from the worktree root: bash jev-pause-demo.sh <path-to-stripped-test-lib>
set -u
. "$1"
say() { printf '\n### %s\n' "$*"; }
show() { printf '$ %s\n' "$*"; }
st() { show "fm-jev.sh status"; in_home "$1" "$JEV" status | grep -i -E 'backend|paus|streak|shadow' ; }
dis() { show "cat state/jev/disabled"; if [ -f "$1/state/jev/disabled" ]; then cat -A "$1/state/jev/disabled"; else echo "(no such file)"; fi; }
wk() { show "jev wakes in state/.wake-queue"; local w; w=$(queued_wakes "$1" jev- | cut -f3-); [ -n "$w" ] && printf '%s\n' "$w" || echo "(none)"; }

say "1. OpenRouter backend: ONE timeout does not pause"
h=$(jev_case demo-or with-key)
timeout_drain "$h" 1 1
dis "$h"; st "$h"; wk "$h"

say "2. A success resets the streak"
timeout_drain "$h" 2 1 ok
st "$h"

say "3. Three CONSECUTIVE timeouts start a ~60 minute pause, announced once"
timeout_drain "$h" 3 4
echo "now: $(date '+%F %H:%M')   network calls so far: $(calls "$h") (1 timeout + 1 ok + 3 timeouts; 4th wake skipped)"
dis "$h"; st "$h"; wk "$h"
show "fm-jev.sh pause-state"; in_home "$h" "$JEV" pause-state
show "fm-jev.sh report | grep -i -E 'paus|skipped|disabled|timeout'"; in_home "$h" "$JEV" report | grep -i -E 'paus|skipped|disabled|timeout'

say "4. What the supervising firstmate sees on its next drain (the pause wake is presented, never classified)"
before=$(calls "$h")
show "fm-wake-drain.sh"; in_home "$h" env FM_JEV_FOREGROUND=1 FAKE_CURL_MODE=ok "$DRAIN" 2>/dev/null | grep -i 'jev-pause'
echo "network calls: before=$before after=$(calls "$h")"

say "5. Pause runs out by itself; a failed retry sends NO resume; the first success does, once"
printf '%s\ttimeout\t%s\n' "$(date +%F)" "$(( $(date +%s) - 5 ))" > "$h/state/jev/disabled"
st "$h"
timeout_drain "$h" 7 1
echo "after one failed retry:"; wk "$h"
timeout_drain "$h" 8 1 ok
echo "after first successful classification:"; wk "$h"; st "$h"
timeout_drain "$h" 9 1 ok
echo "resume wakes after another success: $(queued_wakes "$h" jev-resume: | wc -l | tr -d ' ')"

say "6. Repeat episode with no success in between backs off (doubling)"
h=$(jev_case demo-backoff with-key)
timeout_drain "$h" 1 3; echo "first pause:  $(( ($(pause_until "$h") - $(date +%s) + 30) / 60 )) min"
printf '%s\ttimeout\t%s\n' "$(date +%F)" "$(( $(date +%s) - 5 ))" > "$h/state/jev/disabled"
timeout_drain "$h" 4 3; echo "second pause: $(( ($(pause_until "$h") - $(date +%s) + 30) / 60 )) min"
wk "$h"
h=$(jev_case demo-daycap with-key); printf '99999\n' > "$h/config/jev-timeout-pause"
timeout_drain "$h" 1 3
echo "config/jev-timeout-pause=99999 -> pause until $(date -d "@$(pause_until "$h")" '+%F %H:%M:%S') (today is $(date +%F))"

say "7. Configurable thresholds: config/jev-timeout-streak=2, config/jev-timeout-pause=10"
h=$(jev_case demo-cfg with-key); printf '2\n' > "$h/config/jev-timeout-streak"; printf '10\n' > "$h/config/jev-timeout-pause"
timeout_drain "$h" 1 2; echo "pause after 2 timeouts: $(( ($(pause_until "$h") - $(date +%s) + 30) / 60 )) min"; st "$h"

say "8. Spend cap is unchanged: holds until tomorrow, and is announced"
h=$(jev_case demo-cap with-key); printf '0.000015\n' > "$h/config/jev-daily-cap"
queue_row "$h" 1 check inbox:1 'check: captain inbox note 1 - hi'; queue_row "$h" 2 check inbox:2 'check: captain inbox note 2 - hi'
in_home "$h" env FM_JEV_FOREGROUND=1 FAKE_COST=0.00002 "$DRAIN" >/dev/null 2>&1
dis "$h"; st "$h"; wk "$h"

say "9. API error still pauses for the day (OpenRouter)"
h=$(jev_case demo-500 with-key); timeout_drain "$h" 1 2 http500
dis "$h"; st "$h"; wk "$h"

say "10. Local loopback backend: a drain with 3 timed-out wakes counts ONCE; 3 such drains pause"
h=$(jev_local_case demo-local)
timeout_drain "$h" 1 3; st "$h"; dis "$h"
timeout_drain "$h" 4 1; timeout_drain "$h" 5 1
dis "$h"; st "$h"; wk "$h"

say "11. Legacy state/jev/disabled files"
h=$(jev_case demo-legacy with-key); mkdir -p "$h/state/jev"
printf '%s\ttimeout\n' "$(date +%F)" > "$h/state/jev/disabled"; dis "$h"; st "$h"
show "fm-jev.sh pause-state"; echo "[$(in_home "$h" "$JEV" pause-state)]"
printf '%s\tapi-error\n' "$(date +%F)" > "$h/state/jev/disabled"; dis "$h"; st "$h"
