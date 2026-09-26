#!/usr/bin/env bash
# tests/fm-jev.test.sh - the Jev shadow wake classifier (bin/fm-jev.sh and its
# hooks in bin/fm-jev-lib.sh). Portable: the network is always a fake curl on
# PATH, so no case can reach OpenRouter or spend money. Pins the off-by-default
# switch, that shadow mode never changes what a drain presents or how fast it
# returns, the limits (timeout, API error, missing cost, daily cap, next-day
# resume), what leaves the machine (masking, only two state fields, the key
# never in argv or on disk), and the ground-truth report over a fixture log.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

JEV="$ROOT/bin/fm-jev.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
FAKE_KEY=sk-or-v1-fmjevtestkey0123456789

TMP_ROOT=$(fm_test_tmproot fm-jev-tests)
unset OPENROUTER_API_KEY FM_JEV_FOREGROUND

# jev_case <name> [with-key]: a home with its own state dir, a fake curl, and
# (optionally) an opted-in .env. Prints the home path.
jev_case() {
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/state" "$home/config" "$home/curl"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
# Fake OpenRouter: records each call, never touches the network.
log=${FAKE_CURL_LOG:?}
printf 'call\n' >> "$log/calls"
n=$(wc -l < "$log/calls" | tr -d ' ')
printf '%s\n' "$@" >> "$log/argv"
cfg=$(cat)
case "$cfg" in *"Authorization: Bearer ${FAKE_CURL_EXPECT_KEY:-none}"*) printf 'ok\n' >> "$log/auth" ;; esac
out='' body=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift ;;
    --data-binary) body=${2#@}; shift ;;
  esac
  shift
done
cp "$body" "$log/body.$n"
case "${FAKE_CURL_MODE:-ok}" in
  timeout) exit 28 ;;
  hang) sleep 3; exit 28 ;;
  refused) exit 7 ;;
  http500) printf '{"error":{"message":"boom"}}' > "$out"; printf '500' ;;
  nocost) printf '{"answers":{"handling":{"type":"choice","choice":"absorbable","confidence":0.9}},"usage":{}}' > "$out"; printf '200' ;;
  ok)
    printf '{"id":"gen-dec-1","model":"typesafe/jev-1.13-20260917","answers":{"handling":{"type":"choice","choice":"%s","confidence":%s,"probabilities":{"firstmate":0.1,"absorbable":0.8,"captain":0.1}}},"usage":{"input_tokens":300,"output_tokens":10,"cost":%s}}' \
      "${FAKE_CHOICE:-absorbable}" "${FAKE_CONF:-0.8}" "${FAKE_COST:-0.00001}" > "$out"
    printf '200'
    ;;
esac
SH
  chmod +x "$fakebin/curl"
  if [ "${2:-}" = with-key ]; then
    printf 'OTHER_SECRET=do-not-read\nOPENROUTER_API_KEY=%s\n' "$FAKE_KEY" > "$home/.env"
  fi
  printf '%s\n' "$home"
}

# Run a command against <home> with the fake network.
in_home() {  # <home> <cmd...>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" PATH="$home/fakebin:$PATH" \
    FAKE_CURL_LOG="$home/curl" FAKE_CURL_EXPECT_KEY="$FAKE_KEY" "$@"
}

# Queue one wake row with a fixed epoch so two homes present identical bytes.
queue_row() {  # <home> <seq> <kind> <key> <payload>
  printf '1790000000\t%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" >> "$1/state/.wake-queue"
}

calls() {  # <home>
  if [ -f "$1/curl/calls" ]; then wc -l < "$1/curl/calls" | tr -d ' '; else printf '0\n'; fi
}

jev_events() {  # <home> <outcome-or-why-jq-filter>
  jq -c "select(.ev == \"jev\") | $2" "$1/state/jev/shadow.jsonl" 2>/dev/null
}

test_off_by_default_and_not_enabled_by_the_environment() {
  local home out
  home=$(jev_case off)
  printf 'working: halfway\n' > "$home/state/task1.status"
  queue_row "$home" 1 signal task1.status 'signal: task1.status: working: halfway'
  out=$(in_home "$home" env OPENROUTER_API_KEY="$FAKE_KEY" FM_JEV_FOREGROUND=1 "$DRAIN" 2>/dev/null) \
    || fail "drain failed with Jev off"
  assert_contains "$out" 'task1.status' "the wake was not presented with Jev off"
  assert_absent "$home/state/jev" "Jev wrote state without an opted-in .env (ambient key must not enable it)"
  [ "$(calls "$home")" = 0 ] || fail "Jev called the network without an opted-in .env"
  assert_contains "$(in_home "$home" "$JEV" status)" 'off (no OPENROUTER_API_KEY' "status did not report off"
  pass "off by default: an ambient OPENROUTER_API_KEY neither logs nor calls the network"
}

test_foreign_state_dir_never_uses_the_key() {
  local home other
  home=$(jev_case foreign with-key)
  other="$TMP_ROOT/foreign-other-state"
  mkdir -p "$other"
  printf '1790000000\t1\tcheck\tinbox:1\tcheck: captain inbox note 1 - hi\n' > "$other/.wake-queue"
  FM_HOME="$home" FM_STATE_OVERRIDE="$other" PATH="$home/fakebin:$PATH" FAKE_CURL_LOG="$home/curl" \
    FM_JEV_FOREGROUND=1 "$DRAIN" >/dev/null 2>&1 || fail "drain failed on a foreign state dir"
  assert_absent "$other/jev" "Jev logged into a state dir that is not the key home's own"
  [ "$(calls "$home")" = 0 ] || fail "Jev spent the home key for a foreign state dir"
  pass "a STATE other than the key home's own state never enables Jev"
}

test_shadow_classifies_without_changing_the_presentation() {
  local off on out_off out_on log ack
  off=$(jev_case same-off)
  on=$(jev_case same-on with-key)
  for h in "$off" "$on"; do
    printf 'done: PR https://github.com/o/r/pull/7 checks green, see /home/me/wt/report.md\n' > "$h/state/task2.status"
    queue_row "$h" 1 signal task2.status 'signal: task2.status: done: PR https://github.com/o/r/pull/7 checks green'
  done
  out_off=$(in_home "$off" env FM_JEV_FOREGROUND=1 "$DRAIN" 2>/dev/null) || fail "drain failed with Jev off"
  out_on=$(in_home "$on" env FM_JEV_FOREGROUND=1 "$DRAIN" 2>"$on/drain.err") || fail "drain failed with Jev on"
  [ "$out_on" = "$out_off" ] || fail "Jev changed the drain's presentation:"$'\n'"off: $out_off"$'\n'"on:  $out_on"
  [ "$(calls "$on")" = 1 ] || fail "expected exactly one classification request, got $(calls "$on")"
  log="$on/state/jev/shadow.jsonl"
  assert_present "$log" "no shadow log was written"
  [ "$(stat -c '%a' "$log" 2>/dev/null || stat -f '%Lp' "$log")" = 600 ] || fail "shadow log is not private (0600)"
  jq -e 'select(.ev == "presented" and .id == "1790000000:1" and .task == "task2")' "$log" >/dev/null \
    || fail "the presented wake was not recorded with its task: $(cat "$log")"
  jq -e 'select(.ev == "jev" and .outcome == "classified" and .choice == "absorbable" and .cost == 0.00001)' "$log" >/dev/null \
    || fail "the classification was not logged: $(cat "$log")"
  [ "$(wc -l < "$on/state/.wake-queue" | tr -d ' ')" = 1 ] || fail "Jev consumed or altered the durable wake queue"
  ack=$(sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run //p' "$on/drain.err")
  [ -n "$ack" ] || fail "drain printed no acknowledgement command"
  # shellcheck disable=SC2086 # the printed command is word-split on purpose
  in_home "$on" "$ROOT/"$ack >/dev/null 2>&1 || fail "acknowledgement failed with Jev on"
  jq -e 'select(.ev == "ack" and .through == 1)' "$log" >/dev/null || fail "the acknowledgement was not recorded"
  # A second drain of an already-classified row never asks again.
  queue_row "$on" 1 signal task2.status 'signal: task2.status: done: PR https://github.com/o/r/pull/7 checks green'
  in_home "$on" env FM_JEV_FOREGROUND=1 "$DRAIN" >/dev/null 2>&1 || fail "re-drain failed"
  [ "$(calls "$on")" = 1 ] || fail "a re-presented wake was classified twice"
  pass "shadow mode logs presentation, answer and acknowledgement without changing the drain"
}

test_only_masked_reason_and_status_leave_the_machine() {
  local home body
  home=$(jev_case masking with-key)
  printf 'working: editing /home/alan/proj/src/app.ts\nblocked: push rejected by https://gitlab.example.com/g/p/-/merge_requests/9 see ~/notes/x.md\n' \
    > "$home/state/task3.status"
  queue_row "$home" 4 check "$home/state/task3.check.sh" "check: $home/state/task3.check.sh: merged https://github.com/o/r/pull/3"
  in_home "$home" env FM_JEV_FOREGROUND=1 "$DRAIN" >/dev/null 2>&1 || fail "drain failed"
  body=$(cat "$home/curl/body.1") || fail "no request body was captured"
  jq -e '.model == "typesafe/jev-1.13" and (.state | keys) == ["wake_reason", "worker_last_status"]' <<< "$body" >/dev/null \
    || fail "the request carried more than the two allowed state fields: $body"
  jq -e '.state.wake_reason == "check: <path> merged <url>"' <<< "$body" >/dev/null \
    || fail "the wake reason was not masked: $body"
  jq -e '.state.worker_last_status == "blocked: push rejected by <url> see <path>"' <<< "$body" >/dev/null \
    || fail "the last status line was not masked: $body"
  jq -e '.questions.handling.type == "choice" and (.questions.handling.criteria | keys) == ["absorbable", "captain", "firstmate"]' <<< "$body" >/dev/null \
    || fail "the question is not the three-way choice: $body"
  assert_not_contains "$body" 'OTHER_SECRET' "another .env value leaked into the request"
  assert_not_contains "$body" "$FAKE_KEY" "the key leaked into the request body"
  assert_no_grep "$FAKE_KEY" "$home/curl/argv" "the key was passed on curl's argv"
  assert_grep ok "$home/curl/auth" "the key did not reach curl on stdin"
  grep -F -- '--max-time' "$home/curl/argv" >/dev/null && grep -Fx 2 "$home/curl/argv" >/dev/null \
    || fail "the request was not bounded by the 2 second timeout"
  ! grep -rF "$FAKE_KEY" "$home/state" >/dev/null || fail "the key was written under state/"
  assert_contains "$(printf 'see http://a.b/c and ./x/y and C:\\tmp\\z plain\n' | "$JEV" mask)" \
    'see <url> and <path> and <path> plain' "mask did not mask URLs and paths"
  pass "only the masked reason and last status line are sent; the key stays off argv and disk"
}

test_timeout_pauses_until_the_next_day() {
  local home
  home=$(jev_case timeout with-key)
  queue_row "$home" 1 heartbeat heartbeat heartbeat
  in_home "$home" env FM_JEV_FOREGROUND=1 FAKE_CURL_MODE=timeout "$DRAIN" >/dev/null 2>&1 || fail "drain failed on a timeout"
  jev_events "$home" 'select(.outcome == "skipped" and .why == "timeout")' | grep -q . || fail "timeout was not logged"
  [ "$(cut -f1 "$home/state/jev/disabled")" = "$(date +%F)" ] || fail "a timeout did not pause Jev for today"
  queue_row "$home" 2 heartbeat heartbeat heartbeat
  in_home "$home" env FM_JEV_FOREGROUND=1 "$DRAIN" >/dev/null 2>&1 || fail "drain failed while paused"
  [ "$(calls "$home")" = 1 ] || fail "a paused Jev still called the network"
  jev_events "$home" 'select(.id == "1790000000:2" and .why == "disabled")' | grep -q . || fail "the paused wake was not logged as skipped"
  assert_contains "$(in_home "$home" "$JEV" status)" 'paused until tomorrow: timeout' "status did not report the pause"
  printf '2000-01-01\ttimeout\n' > "$home/state/jev/disabled"
  queue_row "$home" 3 heartbeat heartbeat heartbeat
  in_home "$home" env FM_JEV_FOREGROUND=1 "$DRAIN" >/dev/null 2>&1 || fail "drain failed the next day"
  [ "$(calls "$home")" = 2 ] || fail "Jev did not resume on a later day"
  pass "a timeout skips the wake and pauses Jev until the next day"
}

test_api_errors_pause_until_the_next_day() {
  local mode home
  for mode in http500 refused nocost; do
    home=$(jev_case "api-$mode" with-key)
    queue_row "$home" 1 heartbeat heartbeat heartbeat
    queue_row "$home" 2 stale default:w1:p1 'stale: default:w1:p1'
    in_home "$home" env FM_JEV_FOREGROUND=1 FAKE_CURL_MODE="$mode" "$DRAIN" >/dev/null 2>&1 || fail "drain failed on $mode"
    jev_events "$home" 'select(.why == "api-error")' | grep -q . || fail "$mode was not logged as an API error"
    [ "$(cut -f2 "$home/state/jev/disabled")" = api-error ] || fail "$mode did not pause Jev"
    [ "$(calls "$home")" = 1 ] || fail "$mode: Jev kept calling after an API error"
  done
  pass "HTTP errors, transport errors and a missing cost pause Jev until the next day"
}

test_daily_cap_pauses_after_the_spend_is_reached() {
  local home
  home=$(jev_case cap with-key)
  printf '0.000015\n' > "$home/config/jev-daily-cap"
  queue_row "$home" 1 heartbeat heartbeat heartbeat
  queue_row "$home" 2 stale default:w1:p1 'stale: default:w1:p1'
  queue_row "$home" 3 check inbox:9 'check: captain inbox note 9 - hi'
  in_home "$home" env FM_JEV_FOREGROUND=1 FAKE_COST=0.00001 "$DRAIN" >/dev/null 2>&1 || fail "drain failed under the cap"
  [ "$(calls "$home")" = 2 ] || fail "expected two paid requests before the cap, got $(calls "$home")"
  [ "$(cut -f2 "$home/state/jev/disabled")" = cap ] || fail "reaching the cap did not pause Jev"
  jev_events "$home" 'select(.id == "1790000000:3" and .outcome == "skipped")' | grep -q . \
    || fail "the wake after the cap was not skipped"
  assert_contains "$(in_home "$home" "$JEV" status)" 'USD 0.00002' "status did not report today's spend"
  pass "the daily spend cap stops requests and pauses Jev until the next day"
}

test_drain_never_waits_for_jev() {
  local home start elapsed i
  home=$(jev_case detached with-key)
  queue_row "$home" 1 heartbeat heartbeat heartbeat
  start=$(date +%s)
  in_home "$home" env FAKE_CURL_MODE=hang "$DRAIN" >/dev/null 2>&1 || fail "drain failed with a hanging Jev"
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -lt 3 ] || fail "the drain waited ${elapsed}s for a hanging Jev request"
  for i in $(seq 1 60); do
    jev_events "$home" 'select(.why == "timeout")' | grep -q . && break
    sleep 0.2
  done
  jev_events "$home" 'select(.why == "timeout")' | grep -q . || fail "the detached classifier never finished"
  pass "the drain returns immediately while a slow Jev request runs detached"
}

test_hooks_record_actions_and_turn_ends_without_text() {
  local home log
  home=$(jev_case hooks with-key)
  log="$home/state/jev/shadow.jsonl"
  FM_HOME="$home" bash -c '
    . "$1/bin/fm-jev-lib.sh"
    fm_jev_observe "$FM_HOME" "$FM_HOME/state" steer task5
    fm_jev_observe "$FM_HOME" "$FM_HOME/state" decision task5
    fm_jev_observe "$FM_HOME" "$FM_HOME/state" bogus task5
    fm_jev_observe_turn_end "$FM_HOME" "$FM_HOME/state" "{\"last_assistant_message\":\"  Captain, shipshape.\n\"}"
    fm_jev_observe_turn_end "$FM_HOME" "$FM_HOME/state" "{\"last_assistant_message\":\"Captain, the PR is ready: secret-words\"}"
    fm_jev_observe_turn_end "$FM_HOME" "$FM_HOME/state" "{\"stop_hook_active\":false}"
  ' _ "$ROOT" || fail "hook helpers failed"
  [ "$(jq -r '.ev' "$log" | tr '\n' ' ')" = 'steer decision turn_end turn_end turn_end ' ] \
    || fail "unexpected hook events: $(cat "$log")"
  [ "$(jq -r 'select(.ev == "turn_end") | .outcome' "$log" | tr '\n' ' ')" = 'ack message unknown ' ] \
    || fail "turn ends were not classified ack/message/unknown: $(cat "$log")"
  assert_no_grep 'secret-words' "$log" "a turn end recorded the message text"
  pass "hooks record steers, decisions and how a turn ended, never its text"
}

test_automated_sends_record_no_steer() {
  local home fb
  home=$(jev_case sends with-key)
  fb="$home/fakebin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fb/tmux"
  chmod +x "$fb/tmux"
  fm_write_meta "$home/state/t1.meta" "window=sess:fm-t1" "kind=ship"
  FM_JEV_OBSERVE=0 in_home "$home" env FM_ROOT_OVERRIDE="$home" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" t1 'automated resend' >/dev/null 2>&1
  [ ! -s "$home/state/jev/shadow.jsonl" ] || fail "an automated send recorded a steer: $(cat "$home/state/jev/shadow.jsonl")"
  in_home "$home" env FM_ROOT_OVERRIDE="$home" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" t1 'firstmate steer' >/dev/null 2>&1
  [ "$(jq -c '[.ev, .task]' "$home/state/jev/shadow.jsonl")" = '["steer","t1"]' ] \
    || fail "a firstmate send did not record exactly one steer: $(cat "$home/state/jev/shadow.jsonl")"
  pass "only sends firstmate itself makes count as steers; FM_JEV_OBSERVE=0 senders record nothing"
}

# Fixture: six wakes over eight days with every kind of ground truth.
write_fixture() {  # <file>
  local d=86400 t0=1790000000
  {
    # Batch A (one wake): Jev absorbable, turn ends with the plain ack -> agree.
    printf '{"ev":"presented","t":%s,"id":"e:1","seq":1,"kind":"signal","task":"a","batch":"A"}\n' "$t0"
    printf '{"ev":"jev","t":%s,"id":"e:1","outcome":"classified","choice":"absorbable","confidence":0.9,"reason":"signal: a working","status":"working: x"}\n' "$t0"
    printf '{"ev":"ack","t":%s,"through":1}\n' $((t0 + 5))
    printf '{"ev":"turn_end","t":%s,"outcome":"ack"}\n' $((t0 + 6))
    # Batch B (one wake): Jev absorbable but firstmate steered -> wrongly absorbable.
    printf '{"ev":"presented","t":%s,"id":"e:2","seq":2,"kind":"stale","task":"b","batch":"B"}\n' $((t0 + d))
    printf '{"ev":"jev","t":%s,"id":"e:2","outcome":"classified","choice":"absorbable","confidence":0.8,"reason":"stale: default:w1:p2","status":"working: tests"}\n' $((t0 + d))
    printf '{"ev":"steer","t":%s,"task":"b"}\n' $((t0 + d + 3))
    printf '{"ev":"ack","t":%s,"through":2}\n' $((t0 + d + 4))
    printf '{"ev":"turn_end","t":%s,"outcome":"ack"}\n' $((t0 + d + 5))
    # Batch C (two wakes): a decision for c1 only; turn ends with the ack.
    printf '{"ev":"presented","t":%s,"id":"e:3","seq":3,"kind":"signal","task":"c1","batch":"C"}\n' $((t0 + 2 * d))
    printf '{"ev":"presented","t":%s,"id":"e:4","seq":4,"kind":"signal","task":"c2","batch":"C"}\n' $((t0 + 2 * d))
    printf '{"ev":"jev","t":%s,"id":"e:3","outcome":"classified","choice":"firstmate","confidence":0.7,"reason":"signal: c1 needs-decision","status":""}\n' $((t0 + 2 * d))
    printf '{"ev":"jev","t":%s,"id":"e:4","outcome":"classified","choice":"absorbable","confidence":0.95,"reason":"signal: c2 working","status":""}\n' $((t0 + 2 * d))
    printf '{"ev":"decision","t":%s,"task":"c1"}\n' $((t0 + 2 * d + 2))
    printf '{"ev":"ack","t":%s,"through":4}\n' $((t0 + 2 * d + 3))
    printf '{"ev":"turn_end","t":%s,"outcome":"ack"}\n' $((t0 + 2 * d + 4))
    # Batch D: Jev says captain with low confidence (doubt); turn ends with a captain message.
    printf '{"ev":"presented","t":%s,"id":"e:5","seq":5,"kind":"check","task":"d","batch":"D"}\n' $((t0 + 8 * d))
    printf '{"ev":"jev","t":%s,"id":"e:5","outcome":"classified","choice":"captain","confidence":0.4,"reason":"check: <path> merged","status":"done: PR <url>"}\n' $((t0 + 8 * d))
    printf '{"ev":"ack","t":%s,"through":5}\n' $((t0 + 8 * d + 3))
    printf '{"ev":"turn_end","t":%s,"outcome":"message"}\n' $((t0 + 8 * d + 4))
    # Batch E: timed out, and never acknowledged.
    printf '{"ev":"presented","t":%s,"id":"e:6","seq":6,"kind":"heartbeat","task":"","batch":"E"}\n' $((t0 + 8 * d + 60))
    printf '{"ev":"jev","t":%s,"id":"e:6","outcome":"skipped","why":"timeout","reason":"heartbeat","status":""}\n' $((t0 + 8 * d + 62))
    printf 'not json at all\n'
  } > "$1"
}

test_report_measures_agreement_and_lists_doubtful_cases() {
  local fixture out
  fixture="$TMP_ROOT/fixture.jsonl"
  write_fixture "$fixture"
  out=$("$JEV" report --log "$fixture" --days 30 --now $((1790000000 + 9 * 86400))) || fail "report failed: $out"
  assert_contains "$out" 'wakes presented: 6; classified: 5; skipped: 1 (timeout 1)' "wrong wake counts"
  assert_contains "$out" 'agreement (absorb vs surface): 80% (4 of 5)' "wrong agreement"
  assert_contains "$out" 'wrongly absorbable (Jev would absorb, firstmate had to act): 1' "wrong wrongly-absorbable count"
  assert_contains "$out" 'zero wrongly absorbable NOT met' "go-live did not fail on a wrongly absorbable wake"
  assert_contains "$out" 'one week of shadow data met' "eight days of data did not count as a week"
  assert_contains "$out" '1. ' "no doubtful cases listed"
  assert_contains "$(printf '%s\n' "$out" | grep -F '1. ')" 'Jev absorbable (0.8), actual firstmate (steer)' \
    "the wrongly absorbable wake is not the first doubtful case"
  assert_contains "$out" 'Jev doubt (0.4), actual captain' "the low-confidence answer is not listed as doubt"
  out=$("$JEV" report --log "$fixture" --days 30 --limit 1 --now $((1790000000 + 9 * 86400))) || fail "limited report failed"
  assert_not_contains "$out" '2. ' "--limit did not bound the doubtful list"
  out=$("$JEV" report --log "$fixture" --days 2 --now $((1790000000 + 9 * 86400))) || fail "windowed report failed"
  assert_contains "$out" 'wakes presented: 2;' "--days did not bound the window"
  pass "the report computes agreement, wrongly absorbable wakes, go-live criteria and doubtful cases"
}

# Attribution across drains: a named steer credits only its task's open wake,
# even from an earlier drain; an unnamed or unmatched one credits every open
# wake, flagged shared.
test_report_attributes_actions_to_open_wakes_across_drains() {
  local fixture out t0=1790000000
  fixture="$TMP_ROOT/attribution.jsonl"
  {
    printf '{"ev":"presented","t":%s,"id":"e:1","seq":1,"kind":"signal","task":"x","batch":"P"}\n' "$t0"
    printf '{"ev":"jev","t":%s,"id":"e:1","outcome":"classified","choice":"absorbable","confidence":0.9}\n' "$t0"
    printf '{"ev":"presented","t":%s,"id":"e:2","seq":2,"kind":"signal","task":"z","batch":"Q"}\n' $((t0 + 1))
    printf '{"ev":"jev","t":%s,"id":"e:2","outcome":"classified","choice":"absorbable","confidence":0.9}\n' $((t0 + 1))
    printf '{"ev":"steer","t":%s,"task":"x"}\n' $((t0 + 2))
    printf '{"ev":"ack","t":%s,"through":2}\n' $((t0 + 3))
    printf '{"ev":"turn_end","t":%s,"outcome":"ack"}\n' $((t0 + 4))
    printf '{"ev":"presented","t":%s,"id":"e:3","seq":3,"kind":"signal","task":"u","batch":"R"}\n' $((t0 + 10))
    printf '{"ev":"jev","t":%s,"id":"e:3","outcome":"classified","choice":"firstmate","confidence":0.9}\n' $((t0 + 10))
    printf '{"ev":"presented","t":%s,"id":"e:4","seq":4,"kind":"signal","task":"v","batch":"S"}\n' $((t0 + 11))
    printf '{"ev":"jev","t":%s,"id":"e:4","outcome":"classified","choice":"firstmate","confidence":0.9}\n' $((t0 + 11))
    printf '{"ev":"steer","t":%s,"task":"nobody"}\n' $((t0 + 12))
    printf '{"ev":"decision","t":%s,"task":""}\n' $((t0 + 12))
    printf '{"ev":"ack","t":%s,"through":4}\n' $((t0 + 13))
    printf '{"ev":"turn_end","t":%s,"outcome":"ack"}\n' $((t0 + 14))
  } > "$fixture"
  out=$("$JEV" report --log "$fixture" --days 1 --now $((t0 + 60))) || fail "report failed: $out"
  assert_contains "$out" 'wrongly absorbable (Jev would absorb, firstmate had to act): 1' "the named steer was not credited to its own wake alone"
  assert_contains "$out" 'agreement (absorb vs surface): 75% (3 of 4)' "wrong agreement across drains"
  assert_contains "$(printf '%s\n' "$out" | grep -F 'task x:')" 'Jev absorbable (0.9), actual firstmate (steer)' "the named steer was not credited to task x"
  assert_not_contains "$(printf '%s\n' "$out" | grep -F 'task x:')" 'shared' "the named steer was flagged shared"
  assert_not_contains "$out" 'task z' "an unrelated open wake was credited with another task's steer"
  assert_contains "$out" 'task u: Jev firstmate (0.9), actual firstmate (decision+steer), shared with other open wakes' "the unmatched steer was not shared with task u"
  assert_contains "$out" 'task v: Jev firstmate (0.9), actual firstmate (decision+steer), shared with other open wakes' "the unmatched steer was not shared with task v"
  pass "the report credits named actions to their task's open wakes across drains and shares the rest"
}

# A wake still unacknowledged, or presented before the report window, stays open
# for attribution: a steer naming its task never spills onto an unrelated wake.
test_report_keeps_unacknowledged_and_earlier_wakes_open() {
  local fixture out t0=1790000000 d=86400
  fixture="$TMP_ROOT/open-wakes.jsonl"
  {
    printf '{"ev":"presented","t":%s,"id":"e:1","seq":1,"kind":"signal","task":"old","batch":"P"}\n' "$t0"
    printf '{"ev":"presented","t":%s,"id":"e:2","seq":2,"kind":"signal","task":"late","batch":"Q"}\n' $((t0 + 3 * d))
    printf '{"ev":"presented","t":%s,"id":"e:3","seq":3,"kind":"signal","task":"z","batch":"R"}\n' $((t0 + 3 * d + 1))
    printf '{"ev":"jev","t":%s,"id":"e:3","outcome":"classified","choice":"absorbable","confidence":0.9}\n' $((t0 + 3 * d + 1))
    printf '{"ev":"steer","t":%s,"task":"old"}\n' $((t0 + 3 * d + 2))
    printf '{"ev":"decision","t":%s,"task":"late"}\n' $((t0 + 3 * d + 2))
    printf '{"ev":"ack","t":%s,"through":1}\n' $((t0 + 3 * d + 3))
    printf '{"ev":"presented","t":%s,"id":"e:4","seq":4,"kind":"signal","task":"y","batch":"S"}\n' $((t0 + 3 * d + 4))
    printf '{"ev":"ack","t":%s,"through":3}\n' $((t0 + 3 * d + 5))
    printf '{"ev":"turn_end","t":%s,"outcome":"ack"}\n' $((t0 + 3 * d + 6))
  } > "$fixture"
  out=$("$JEV" report --log "$fixture" --days 1 --now $((t0 + 3 * d + 60))) || fail "report failed: $out"
  assert_contains "$out" 'wakes presented: 3;' "the wake before the window was reported"
  assert_contains "$out" 'wrongly absorbable (Jev would absorb, firstmate had to act): 0' "a steer for an open wake spilled onto an unrelated wake"
  assert_contains "$out" 'agreement (absorb vs surface): 100% (1 of 1)' "the unrelated wake was not a plain acknowledgement"
  pass "unacknowledged and pre-window wakes stay open, so their steers never spill onto unrelated wakes"
}

test_off_by_default_and_not_enabled_by_the_environment
test_foreign_state_dir_never_uses_the_key
test_shadow_classifies_without_changing_the_presentation
test_only_masked_reason_and_status_leave_the_machine
test_timeout_pauses_until_the_next_day
test_api_errors_pause_until_the_next_day
test_daily_cap_pauses_after_the_spend_is_reached
test_drain_never_waits_for_jev
test_hooks_record_actions_and_turn_ends_without_text
test_automated_sends_record_no_steer
test_report_attributes_actions_to_open_wakes_across_drains
test_report_keeps_unacknowledged_and_earlier_wakes_open
test_report_measures_agreement_and_lists_doubtful_cases
