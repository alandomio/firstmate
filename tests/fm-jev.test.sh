#!/usr/bin/env bash
# tests/fm-jev.test.sh - the Jev shadow wake classifier (bin/fm-jev.sh and its
# hooks in bin/fm-jev-lib.sh). Portable: the network is always a fake curl on
# PATH, so no case can reach OpenRouter, Rizzo Flow, or spend money. Pins the
# off-by-default switch, that shadow mode never changes what a drain presents
# or how fast it returns, the limits (timeout, API error, missing cost, daily
# cap, next-day resume) for the OpenRouter backend and (no key, missing cost is
# not an error, loopback-only enforcement, no day pause on load/timeout/API
# error - only invalid-endpoint still pauses - native /v1/decisions with
# abstention mapped to doubt) for the local backend, what leaves the machine
# (masking, only two state fields, the key never in argv or on disk), and the
# ground-truth report over a fixture log.
# tests/fm-jev-local-rizzo-live.test.sh is the opt-in live counterpart against
# a real `rizzo serve`.
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
# Fake network target (OpenRouter or a local Rizzo Flow server): records
# each call and never touches the network.
log=${FAKE_CURL_LOG:?}
printf 'call\n' >> "$log/calls"
n=$(wc -l < "$log/calls" | tr -d ' ')
printf '%s\n' "$@" >> "$log/argv"
has_k=0
for a in "$@"; do [ "$a" = -K ] && has_k=1; done
if [ "$has_k" = 1 ]; then
  cfg=$(cat)
  case "$cfg" in *"Authorization: Bearer ${FAKE_CURL_EXPECT_KEY:-none}"*) printf 'ok\n' >> "$log/auth" ;; esac
else
  printf 'no-auth-header\n' >> "$log/noauth"
fi
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
  localok)
    printf '{"model":{"source":"XHToken/Spark-X2.5-1.7B","weights":"flow","precision":"q8_0"},"answers":{"handling":{"type":"choice","status":"ok","choice":"%s","probabilities":{"firstmate":0.1,"absorbable":0.8,"captain":0.1,"__insufficient__":0.0},"uncertainty":{"top_probability":%s}}}}' \
      "${FAKE_CHOICE:-absorbable}" "${FAKE_CONF:-0.8}" > "$out"
    printf '200'
    ;;
  localdoubt)
    printf '{"model":{"source":"XHToken/Spark-X2.5-1.7B","weights":"flow","precision":"q8_0"},"answers":{"handling":{"type":"choice","status":"uncertain","choice":null,"probabilities":{"firstmate":0.4,"absorbable":0.35,"captain":0.1,"__insufficient__":0.15},"uncertainty":{"top_probability":0.4}}}}' > "$out"
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

# jev_local_case <name> [endpoint]: a home configured for the local backend
# (config/jev-endpoint), reusing the same fake network as jev_case.
jev_local_case() {
  local home
  home=$(jev_case "$1")
  printf '%s\n' "${2:-http://127.0.0.1:8017}" > "$home/config/jev-endpoint"
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
  assert_contains "$(in_home "$home" "$JEV" status)" 'off (no config/jev-endpoint and no OPENROUTER_API_KEY' "status did not report off"
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
  if ! grep -F -- '--max-time' "$home/curl/argv" >/dev/null || ! grep -Fx 5 "$home/curl/argv" >/dev/null; then
    fail "the request was not bounded by the default 5 second timeout"
  fi
  ! grep -rF "$FAKE_KEY" "$home/state" >/dev/null || fail "the key was written under state/"
  assert_contains "$(printf 'see http://a.b/c and ./x/y and C:\\tmp\\z plain\n' | "$JEV" mask)" \
    'see <url> and <path> and <path> plain' "mask did not mask URLs and paths"
  pass "only the masked reason and last status line are sent; the key stays off argv and disk"
}

test_timeout_is_configurable() {
  local home
  home=$(jev_case timeoutcfg with-key)
  assert_contains "$(in_home "$home" "$JEV" status)" 'request timeout: 5s' "default timeout not reported"
  printf '7.5\n' > "$home/config/jev-timeout"
  assert_contains "$(in_home "$home" "$JEV" status)" 'request timeout: 7.5s' "configured timeout not reported"
  queue_row "$home" 1 check inbox:1 'check: captain inbox note 1 - hi'
  in_home "$home" env FM_JEV_FOREGROUND=1 "$DRAIN" >/dev/null 2>&1 || fail "drain failed"
  grep -Fx 7.5 "$home/curl/argv" >/dev/null || fail "the configured timeout was not passed to curl"
  printf 'abc\n' > "$home/config/jev-timeout"
  assert_contains "$(in_home "$home" "$JEV" status)" 'request timeout: 5s (config/jev-timeout value "abc" is not a positive number' "invalid timeout not reported"
  printf '0\n' > "$home/config/jev-timeout"
  assert_contains "$(in_home "$home" "$JEV" status)" 'default kept' "zero timeout accepted"
  pass "config/jev-timeout overrides the 5 second default and invalid values keep it"
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

test_local_backend_takes_priority_needs_no_key_and_records_the_answering_model() {
  local home log
  home=$(jev_local_case local-priority)
  printf 'OPENROUTER_API_KEY=%s\n' "$FAKE_KEY" >> "$home/.env"
  queue_row "$home" 1 signal task9.status 'signal: task9.status: working: halfway'
  in_home "$home" env FM_JEV_FOREGROUND=1 FAKE_CURL_MODE=localok FM_JEV_LOAD_OVERRIDE=0.1 "$DRAIN" >/dev/null 2>"$home/drain.err" \
    || fail "drain failed against the local backend: $(cat "$home/drain.err")"
  [ "$(calls "$home")" = 1 ] || fail "expected exactly one local classification request"
  assert_absent "$home/curl/auth" "the local backend sent an Authorization header"
  assert_present "$home/curl/noauth" "the local backend request was not recorded as key-less"
  log="$home/state/jev/shadow.jsonl"
  jq -e 'select(.ev == "jev" and .outcome == "classified" and .model == "XHToken/Spark-X2.5-1.7B/flow/q8_0" and .cost == null)' "$log" >/dev/null \
    || fail "the local answer was not logged with its model and a null cost: $(cat "$log")"
  grep -Fxq 'http://127.0.0.1:8017/v1/decisions' "$home/curl/argv" || fail "the local request did not dial the native endpoint's /v1/decisions"
  [ "$(head -n 1 "$home/curl/argv")" = -q ] || fail "the local request did not skip ~/.curlrc (-q first)"
  grep -A1 -Fx -- '--noproxy' "$home/curl/argv" | grep -Fxq '*' || fail "the local request could be routed through a proxy"
  jq -e 'has("model") | not' "$home/curl/body.1" >/dev/null || fail "the native request carried a top-level model field: $(cat "$home/curl/body.1")"
  jq -e '(.questions.handling.options | map(.id) | sort) == ["absorbable", "captain", "firstmate"]' "$home/curl/body.1" >/dev/null \
    || fail "the native request did not ask the three-way options question: $(cat "$home/curl/body.1")"
  jq -e '.questions.handling.policy == {allow_abstain: true, min_top_probability: 0.6}' "$home/curl/body.1" >/dev/null \
    || fail "the native request did not set allow_abstain and min_top_probability: $(cat "$home/curl/body.1")"
  pass "config/jev-endpoint selects the local backend over an OPENROUTER_API_KEY, needs no key, and records the answering model"
}

test_local_backend_uncertain_maps_to_doubt() {
  local home
  home=$(jev_local_case local-doubt)
  queue_row "$home" 1 heartbeat heartbeat heartbeat
  in_home "$home" env FM_JEV_FOREGROUND=1 FAKE_CURL_MODE=localdoubt FM_JEV_LOAD_OVERRIDE=0.1 "$DRAIN" >/dev/null 2>&1 || fail "drain failed"
  jq -e 'select(.ev == "jev" and .outcome == "classified" and .choice == "doubt" and .confidence == 0.4)' \
    "$home/state/jev/shadow.jsonl" >/dev/null \
    || fail "an uncertain native answer (null choice) was not logged as doubt with its top_probability as confidence: $(cat "$home/state/jev/shadow.jsonl")"
  assert_absent "$home/state/jev/disabled" "an uncertain answer paused the local backend"
  pass "a native status uncertain/insufficient_evidence answer (null choice) classifies as doubt, never as an error"
}

test_local_backend_timeout_is_configurable() {
  local home
  home=$(jev_local_case local-timeoutcfg)
  assert_contains "$(in_home "$home" "$JEV" status)" 'request timeout: 5s' "default timeout not reported for the local backend"
  printf '3\n' > "$home/config/jev-timeout"
  assert_contains "$(in_home "$home" "$JEV" status)" 'request timeout: 3s' "configured timeout not reported for the local backend"
  queue_row "$home" 1 heartbeat heartbeat heartbeat
  in_home "$home" env FM_JEV_FOREGROUND=1 FAKE_CURL_MODE=localok FM_JEV_LOAD_OVERRIDE=0.1 "$DRAIN" >/dev/null 2>&1 || fail "drain failed"
  grep -Fx 3 "$home/curl/argv" >/dev/null || fail "config/jev-timeout was not passed to curl for the local backend"
  pass "config/jev-timeout also overrides the local backend's request timeout"
}

test_local_backend_endpoint_is_read_from_the_home_not_a_config_override() {
  local home override out
  home=$(jev_local_case local-override)
  override="$TMP_ROOT/local-override-config"
  mkdir -p "$override"
  printf '4\n' > "$home/config/jev-max-load"
  queue_row "$home" 1 heartbeat heartbeat heartbeat
  in_home "$home" env FM_CONFIG_OVERRIDE="$override" FM_JEV_FOREGROUND=1 FAKE_CURL_MODE=localok FM_JEV_LOAD_OVERRIDE=0.1 \
    "$DRAIN" >/dev/null 2>&1 || fail "drain failed under FM_CONFIG_OVERRIDE"
  [ "$(calls "$home")" = 1 ] || fail "the home's config/jev-endpoint was not dialed under FM_CONFIG_OVERRIDE"
  assert_absent "$home/state/jev/disabled" "a valid home config/jev-endpoint was refused under FM_CONFIG_OVERRIDE"
  queue_row "$home" 2 heartbeat heartbeat heartbeat
  in_home "$home" env FM_CONFIG_OVERRIDE="$override" FM_JEV_FOREGROUND=1 FAKE_CURL_MODE=localok FM_JEV_LOAD_OVERRIDE=5 \
    "$DRAIN" >/dev/null 2>&1 || fail "drain failed under load with FM_CONFIG_OVERRIDE"
  [ "$(calls "$home")" = 1 ] || fail "the home's config/jev-max-load was ignored under FM_CONFIG_OVERRIDE"
  jev_events "$home" 'select(.id == "1790000000:2" and .why == "load")' | grep -q . \
    || fail "the home's load ceiling did not skip the wake under FM_CONFIG_OVERRIDE"
  out=$(in_home "$home" env FM_CONFIG_OVERRIDE="$override" "$JEV" status)
  assert_contains "$out" 'config/jev-endpoint = http://127.0.0.1:8017' "status did not read the home's config/jev-endpoint"
  assert_contains "$out" 'load ceiling: 4' "status did not read the home's config/jev-max-load"
  pass "the local endpoint and load ceiling are read from the home's own config/, the same place that selected the backend"
}

test_blank_jev_endpoint_does_not_override_openrouter() {
  local home
  home=$(jev_case local-blank with-key)
  printf '  \n' > "$home/config/jev-endpoint"
  queue_row "$home" 1 heartbeat heartbeat heartbeat
  in_home "$home" env FM_JEV_FOREGROUND=1 "$DRAIN" >/dev/null 2>&1 || fail "drain failed with a blank config/jev-endpoint"
  [ "$(calls "$home")" = 1 ] || fail "a blank config/jev-endpoint stopped the OpenRouter backend"
  assert_grep ok "$home/curl/auth" "a blank config/jev-endpoint did not leave OpenRouter in charge"
  assert_absent "$home/state/jev/disabled" "a blank config/jev-endpoint paused Jev"
  pass "a whitespace-only config/jev-endpoint does not select the local backend"
}

test_local_backend_missing_cost_is_not_an_error() {
  local home
  home=$(jev_local_case local-nocost)
  queue_row "$home" 1 heartbeat heartbeat heartbeat
  in_home "$home" env FM_JEV_FOREGROUND=1 FAKE_CURL_MODE=localok FM_JEV_LOAD_OVERRIDE=0.1 "$DRAIN" >/dev/null 2>&1 || fail "drain failed"
  jev_events "$home" 'select(.outcome == "classified")' | grep -q . || fail "a costless local response was treated as an error"
  assert_absent "$home/state/jev/disabled" "a missing cost paused the local backend as if it were an API error"
  pass "a local response with no usage.cost classifies normally instead of erroring"
}

test_local_backend_refuses_a_non_loopback_endpoint() {
  local home
  home=$(jev_local_case local-nonloopback https://evil.example.com)
  queue_row "$home" 1 heartbeat heartbeat heartbeat
  in_home "$home" env FM_JEV_FOREGROUND=1 "$DRAIN" >/dev/null 2>&1 || fail "drain failed"
  [ "$(calls "$home")" = 0 ] || fail "a non-loopback config/jev-endpoint was dialed"
  jev_events "$home" 'select(.why == "invalid-endpoint")' | grep -q . || fail "the non-loopback endpoint was not logged as invalid"
  [ "$(cut -f2 "$home/state/jev/disabled")" = invalid-endpoint ] || fail "a non-loopback endpoint did not pause Jev"
  home=$(jev_local_case local-path http://127.0.0.1:8017/v1)
  queue_row "$home" 1 heartbeat heartbeat heartbeat
  in_home "$home" env FM_JEV_FOREGROUND=1 "$DRAIN" >/dev/null 2>&1 || fail "drain failed on a path suffix"
  [ "$(calls "$home")" = 0 ] || fail "config/jev-endpoint with a path was dialed"
  pass "a non-loopback or path-carrying config/jev-endpoint is refused, never dialed, and pauses Jev"
}

test_local_backend_load_ceiling_skips_without_a_day_pause() {
  local home
  home=$(jev_local_case local-load)
  printf '4\n' > "$home/config/jev-max-load"
  queue_row "$home" 1 heartbeat heartbeat heartbeat
  queue_row "$home" 2 stale default:w1:p1 'stale: default:w1:p1'
  in_home "$home" env FM_JEV_FOREGROUND=1 FAKE_CURL_MODE=localok FM_JEV_LOAD_OVERRIDE=4 "$DRAIN" >/dev/null 2>&1 \
    || fail "drain failed under load"
  [ "$(calls "$home")" = 0 ] || fail "Jev classified while the load was at the ceiling"
  [ "$(jev_events "$home" 'select(.outcome == "skipped" and .why == "load")' | wc -l | tr -d ' ')" = 2 ] \
    || fail "each wake presented at the load ceiling was not skipped with why=load"
  assert_absent "$home/state/jev/disabled" "a load spike paused Jev for the whole day"
  queue_row "$home" 3 heartbeat heartbeat heartbeat
  in_home "$home" env FM_JEV_FOREGROUND=1 FAKE_CURL_MODE=localok FM_JEV_LOAD_OVERRIDE=0.5 "$DRAIN" >/dev/null 2>&1 \
    || fail "drain failed once the load fell"
  [ "$(calls "$home")" = 1 ] || fail "Jev did not resume the same day once the load fell below the ceiling"
  jev_events "$home" 'select(.id == "1790000000:3" and .outcome == "classified")' | grep -q . \
    || fail "the wake presented after the load fell was not classified"
  assert_absent "$home/state/jev/disabled" "a day pause was set across the load spike"
  pass "a 1-minute load average at or above config/jev-max-load skips only that wake; a later reading below it classifies again"
}

test_local_backend_timeout_and_api_errors_skip_without_a_day_pause() {
  local mode home
  for mode in http500 refused; do
    home=$(jev_local_case "local-$mode")
    queue_row "$home" 1 heartbeat heartbeat heartbeat
    queue_row "$home" 2 stale default:w1:p1 'stale: default:w1:p1'
    in_home "$home" env FM_JEV_FOREGROUND=1 FAKE_CURL_MODE="$mode" FM_JEV_LOAD_OVERRIDE=0.1 "$DRAIN" >/dev/null 2>&1 \
      || fail "drain failed on $mode"
    [ "$(calls "$home")" = 2 ] || fail "$mode: the local backend did not retry the very next row"
    [ "$(jev_events "$home" 'select(.outcome == "skipped" and .why == "api-error")' | wc -l | tr -d ' ')" = 2 ] \
      || fail "$mode: each failed row was not logged as skipped with why=api-error"
    assert_absent "$home/state/jev/disabled" "$mode paused the local backend for the day"
  done
  home=$(jev_local_case local-timeout)
  queue_row "$home" 1 heartbeat heartbeat heartbeat
  queue_row "$home" 2 stale default:w1:p1 'stale: default:w1:p1'
  in_home "$home" env FM_JEV_FOREGROUND=1 FAKE_CURL_MODE=timeout FM_JEV_LOAD_OVERRIDE=0.1 "$DRAIN" >/dev/null 2>&1 \
    || fail "drain failed on a local timeout"
  [ "$(calls "$home")" = 1 ] || fail "a local timeout did not stop the rest of that drain dialing a stuck server"
  [ "$(jev_events "$home" 'select(.outcome == "skipped" and .why == "timeout")' | wc -l | tr -d ' ')" = 2 ] \
    || fail "the timed-out row and the rest of its drain were not logged as skipped with why=timeout"
  assert_absent "$home/state/jev/disabled" "a timeout paused the local backend for the day"
  queue_row "$home" 3 heartbeat heartbeat heartbeat
  in_home "$home" env FM_JEV_FOREGROUND=1 FAKE_CURL_MODE=localok FM_JEV_LOAD_OVERRIDE=0.1 "$DRAIN" >/dev/null 2>&1 \
    || fail "drain failed after a local timeout"
  [ "$(calls "$home")" = 2 ] || fail "the very next drain after a local timeout did not try again"
  jev_events "$home" 'select(.id == "1790000000:3" and .outcome == "classified")' | grep -q . \
    || fail "the wake presented in the drain after a local timeout was not classified"
  pass "a local timeout skips the rest of that drain and an API/transport error only its row, each logged with the reason; the next drain tries again with no day pause, unlike OpenRouter"
}

test_local_backend_status_reports_the_endpoint_and_ceiling() {
  local home out
  home=$(jev_local_case local-status)
  printf '6\n' > "$home/config/jev-max-load"
  out=$(in_home "$home" "$JEV" status)
  assert_contains "$out" 'local backend (config/jev-endpoint = http://127.0.0.1:8017)' "status did not report the local backend"
  assert_contains "$out" 'load ceiling: 6' "status did not report the configured load ceiling"
  home=$(jev_case local-status-off)
  assert_contains "$(in_home "$home" "$JEV" status)" \
    'off (no config/jev-endpoint and no OPENROUTER_API_KEY' "status did not report off with both backends absent"
  pass "status names the active backend, its endpoint or spend, and (for local) its load ceiling"
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
    printf '{"ev":"steer","t":%s,"task":"y"}\n' $((t0 + 3 * d + 4))
    printf '{"ev":"ack","t":%s,"through":3}\n' $((t0 + 3 * d + 5))
    printf '{"ev":"turn_end","t":%s,"outcome":"ack"}\n' $((t0 + 3 * d + 6))
  } > "$fixture"
  out=$("$JEV" report --log "$fixture" --days 1 --now $((t0 + 3 * d + 60))) || fail "report failed: $out"
  assert_contains "$out" 'wakes presented: 3;' "the wake before the window was reported"
  assert_contains "$out" 'wrongly absorbable (Jev would absorb, firstmate had to act): 0' "a steer for an open wake spilled onto an unrelated wake"
  assert_contains "$out" 'agreement (absorb vs surface): 100% (1 of 1)' "the unrelated wake was not a plain acknowledgement"
  assert_contains "$out" 'actual handling known: 2' "the unacknowledged wake's truth was not left unknown"
  pass "unacknowledged and pre-window wakes stay open, so their steers never spill onto unrelated wakes"
}

# --- gated absorption (config/jev-absorb) -----------------------------------
# absorb_case: a local-backend home with a task whose last status line is
# eligible ("working:" by default), plus the option to request absorption
# and/or the captain override via `on` args ("on", "override").
absorb_case() {  # <name> [on] [override]
  local home task
  home=$(jev_local_case "$1")
  task="$home/state/task.status"
  printf 'working: compiling step 2\n' > "$task"
  if [ "${2:-}" = on ] || [ "${3:-}" = override ]; then
    if [ "${3:-}" = override ]; then
      printf 'on\noverride\n' > "$home/config/jev-absorb"
    else
      printf 'on\n' > "$home/config/jev-absorb"
    fi
  fi
  printf '%s\n' "$home"
}

absorb_try() {  # <home> [reason]
  in_home "$1" "$JEV" absorb-try --kind signal --task task --reason "${2:-signal:task.status}"
}

digest_lines() {  # <home>
  wc -l < "$1/state/jev/absorbed.jsonl" 2>/dev/null | tr -d ' ' || printf '0\n'
}

test_absorb_off_by_default_never_dials_or_writes_a_digest() {
  local home
  home=$(absorb_case absorb-off)
  export FAKE_CURL_MODE=localok FAKE_CHOICE=absorbable FAKE_CONF=0.95
  absorb_try "$home" && fail "absorb-try succeeded with config/jev-absorb absent"
  [ "$(calls "$home")" = 0 ] || fail "absorb-try dialed the network with absorption off"
  assert_absent "$home/state/jev/absorbed.jsonl" "a digest was written with absorption off"
  unset FAKE_CURL_MODE FAKE_CHOICE FAKE_CONF
  pass "absorption off by default: no network call, no digest, absorb-try refuses"
}

test_absorb_requires_the_local_backend() {
  local home
  home=$(jev_case absorb-openrouter with-key)
  printf 'on\noverride\n' > "$home/config/jev-absorb"
  printf 'working: step\n' > "$home/state/task.status"
  export FAKE_CURL_MODE=ok
  absorb_try "$home" && fail "absorb-try succeeded on the OpenRouter backend"
  [ "$(calls "$home")" = 0 ] || fail "absorb-try dialed the network on a non-local backend"
  unset FAKE_CURL_MODE
  pass "absorption refuses any backend but local, even when requested"
}

test_absorb_refuses_below_the_measured_gate_without_an_override() {
  local home
  home=$(absorb_case absorb-no-override on)
  export FAKE_CURL_MODE=localok FAKE_CHOICE=absorbable FAKE_CONF=0.95
  absorb_try "$home" && fail "absorb-try succeeded with no shadow data and no override"
  [ "$(calls "$home")" = 0 ] || fail "absorb-try dialed the network before checking the gate"
  unset FAKE_CURL_MODE FAKE_CHOICE FAKE_CONF
  pass "requested absorption without a met gate or an override never dials the classifier"
}

test_absorb_override_skips_the_gate_and_records_a_masked_digest_entry() {
  local home entry
  home=$(absorb_case absorb-override on override)
  export FAKE_CURL_MODE=localok FAKE_CHOICE=absorbable FAKE_CONF=0.95
  absorb_try "$home" "signal:task.status https://internal.example/x /Users/me/wt/secret" \
    || fail "absorb-try refused an eligible, overridden, high-confidence wake"
  [ "$(calls "$home")" = 1 ] || fail "absorb-try did not dial the local classifier exactly once"
  [ "$(digest_lines "$home")" = 1 ] || fail "absorb-try did not record exactly one digest entry"
  entry=$(cat "$home/state/jev/absorbed.jsonl")
  assert_contains "$entry" '"choice":"absorbable"' "digest entry missing its choice"
  assert_contains "$entry" '"task":"task"' "digest entry missing its task"
  assert_contains "$entry" '<url>' "digest entry did not mask a URL"
  assert_contains "$entry" '<path>' "digest entry did not mask a path"
  assert_not_contains "$entry" 'internal.example' "digest entry leaked an unmasked URL"
  assert_not_contains "$entry" '/Users/me' "digest entry leaked an unmasked path"
  unset FAKE_CURL_MODE FAKE_CHOICE FAKE_CONF
  pass "a captain override skips the go-live gate and records a masked digest entry"
}

test_absorb_threshold_floor_is_enforced() {
  local home
  home=$(absorb_case absorb-threshold on override)
  printf '0.5\n' > "$home/config/jev-absorb-threshold"
  export FAKE_CURL_MODE=localok FAKE_CHOICE=absorbable FAKE_CONF=0.95
  absorb_try "$home" && fail "absorb-try accepted a threshold below 0.9"
  [ "$(calls "$home")" = 0 ] || fail "absorb-try dialed the network with an invalid threshold"
  unset FAKE_CURL_MODE FAKE_CHOICE FAKE_CONF
  pass "config/jev-absorb-threshold below 0.9 refuses absorption outright"
}

test_absorb_falls_through_on_low_confidence_or_doubt() {
  local home
  home=$(absorb_case absorb-doubt on override)
  export FAKE_CURL_MODE=localok FAKE_CHOICE=absorbable FAKE_CONF=0.5
  absorb_try "$home" && fail "absorb-try accepted a below-threshold confidence"
  assert_absent "$home/state/jev/absorbed.jsonl" "a digest entry was written for a below-threshold answer"
  FAKE_CURL_MODE=localdoubt absorb_try "$home" && fail "absorb-try accepted an uncertain native answer"
  assert_absent "$home/state/jev/absorbed.jsonl" "a digest entry was written for a doubtful answer"
  unset FAKE_CURL_MODE FAKE_CHOICE FAKE_CONF
  pass "any doubt or below-threshold confidence falls through without a digest entry"
}

test_absorb_never_a_task_with_an_open_decision() {
  local home
  home=$(absorb_case absorb-open-decision on override)
  printf 'needs-decision: pick a base branch\n' > "$home/state/task.status"
  export FAKE_CURL_MODE=localok FAKE_CHOICE=absorbable FAKE_CONF=0.95
  absorb_try "$home" && fail "absorb-try absorbed a task with an open decision"
  [ "$(calls "$home")" = 0 ] || fail "absorb-try dialed the network for a task with an open decision"
  unset FAKE_CURL_MODE FAKE_CHOICE FAKE_CONF
  pass "a task with an open decision is never absorbed"
}

test_absorb_never_a_secondmate_status_signal() {
  local home
  home=$(absorb_case absorb-secondmate on override)
  printf 'kind=secondmate\n' > "$home/state/task.meta"
  export FAKE_CURL_MODE=localok FAKE_CHOICE=absorbable FAKE_CONF=0.95
  absorb_try "$home" && fail "absorb-try absorbed a secondmate's routed-reply signal"
  [ "$(calls "$home")" = 0 ] || fail "absorb-try dialed the network for a secondmate signal"
  unset FAKE_CURL_MODE FAKE_CHOICE FAKE_CONF
  pass "a secondmate's status signal is never absorbed"
}

test_absorb_never_a_non_working_paused_verb() {
  local home
  home=$(absorb_case absorb-verb on override)
  printf 'done: finished\n' > "$home/state/task.status"
  export FAKE_CURL_MODE=localok FAKE_CHOICE=absorbable FAKE_CONF=0.95
  absorb_try "$home" && fail "absorb-try absorbed a captain-relevant done: line"
  [ "$(calls "$home")" = 0 ] || fail "absorb-try dialed the network for a done: line"
  unset FAKE_CURL_MODE FAKE_CHOICE FAKE_CONF
  pass "only a working:/paused: verb is ever eligible for absorption"
}

test_absorb_veto_runs_ahead_of_the_model() {
  local home line reason
  home=$(absorb_case absorb-veto on override)
  export FAKE_CURL_MODE=localok FAKE_CHOICE=absorbable FAKE_CONF=0.99
  for line in 'done: PR https://example.test/pr/1 checks green' 'needs-decision: pick a base' \
    'blocked: no credentials' 'failed: build broke' 'resolved: the base is main'; do
    printf '%s\n' "$line" > "$home/state/task.status"
    absorb_try "$home" && fail "absorb-try absorbed a task whose latest status is '$line'"
  done
  printf 'working: compiling step 2\n' > "$home/state/task.status"
  for reason in 'heartbeat' 'check: startup-network finished' 'signal:task.status merged' \
    'stale: w inactive terminal outcome awaiting captain presentation'; do
    absorb_try "$home" "$reason" && fail "absorb-try absorbed a wake whose reason is '$reason'"
  done
  printf 'note: an answer nobody has read\nworking: compiling step 2\n' > "$home/state/task.status"
  absorb_try "$home" && fail "absorb-try absorbed a task with an unread note"
  [ "$(calls "$home")" = 0 ] || fail "the veto let a vetoed wake reach the classifier"
  assert_absent "$home/state/jev/absorbed.jsonl" "a vetoed wake wrote a digest entry"
  # Control: the same home absorbs the plain working wake once nothing vetoes it.
  printf 'working: compiling step 2\n' > "$home/state/task.status"
  absorb_try "$home" || fail "absorb-try refused the control wake no veto applies to"
  [ "$(calls "$home")" = 1 ] || fail "the control wake did not reach the classifier exactly once"
  unset FAKE_CURL_MODE FAKE_CHOICE FAKE_CONF
  pass "the deterministic veto refuses terminal statuses, check/heartbeat/merge reasons, and unread notes before any model call"
}

test_absorb_gate_reports_met_and_not_met() {
  local fixture out
  fixture="$TMP_ROOT/gate-not-met.jsonl"
  write_fixture "$fixture"
  out=$("$JEV" absorb-gate --log "$fixture" --days 30 --min-sample 2 --now $((1790000000 + 9 * 86400))) \
    && fail "absorb-gate passed a fixture with a wrongly absorbable wake"
  assert_contains "$out" 'wrongly absorbable: 1' "absorb-gate did not report the wrongly absorbable count"
  assert_contains "$out" 'go-live: NOT met' "absorb-gate did not report NOT met"
  out=$("$JEV" absorb-gate --log "$fixture" --days 30 --min-sample 999 --now $((1790000000 + 9 * 86400)) --json) \
    || true
  assert_contains "$out" '"sample_ok":false' "absorb-gate --json did not report the sample as insufficient"

  fixture="$TMP_ROOT/gate-met.jsonl"
  {
    printf '{"ev":"presented","t":1790000000,"id":"g:1","seq":1,"kind":"signal","task":"a","batch":"A"}\n'
    printf '{"ev":"jev","t":1790000000,"id":"g:1","outcome":"classified","choice":"absorbable","confidence":0.95}\n'
    printf '{"ev":"ack","t":1790000005,"through":1}\n'
    printf '{"ev":"turn_end","t":1790000006,"outcome":"ack"}\n'
    printf '{"ev":"presented","t":1790000010,"id":"g:2","seq":2,"kind":"signal","task":"b","batch":"B"}\n'
    printf '{"ev":"jev","t":1790000010,"id":"g:2","outcome":"classified","choice":"absorbable","confidence":0.95}\n'
    printf '{"ev":"ack","t":1790000015,"through":2}\n'
    printf '{"ev":"turn_end","t":1790000016,"outcome":"ack"}\n'
    printf '{"ev":"presented","t":1790000020,"id":"g:3","seq":3,"kind":"stale","task":"c","batch":"C"}\n'
    printf '{"ev":"jev","t":1790000020,"id":"g:3","outcome":"classified","choice":"firstmate","confidence":0.9}\n'
    printf '{"ev":"steer","t":1790000023,"task":"c"}\n'
    printf '{"ev":"ack","t":1790000024,"through":3}\n'
    printf '{"ev":"turn_end","t":1790000025,"outcome":"ack"}\n'
  } > "$fixture"
  out=$("$JEV" absorb-gate --log "$fixture" --days 30 --min-sample 3 --now 1790000100) \
    || fail "absorb-gate failed a clean, fully-agreeing fixture: $out"
  assert_contains "$out" 'agreement: 100% (3 of 3)' "absorb-gate did not compute 100% agreement"
  assert_contains "$out" 'go-live: met' "absorb-gate did not report met on a clean fixture"
  out=$("$JEV" absorb-gate --log "$fixture" --days 30 --min-sample 4 --now 1790000100) \
    && fail "absorb-gate passed below its own minimum sample"
  assert_contains "$out" 'go-live: NOT met' "a sample below --min-sample still reported met"
  pass "absorb-gate reports classified/scored/agreement/wrongly-absorbable and the sample-gated go-live verdict"
}

test_absorb_digest_surfaces_every_entry_past_a_malformed_line_and_holds_a_partial_one() {
  local home out1 out2 digest
  home=$(jev_case absorb-digest-malformed)
  mkdir -p "$home/state/jev"
  digest="$home/state/jev/absorbed.jsonl"
  {
    printf '{"t":1790000000,"kind":"signal","task":"first","choice":"absorbable","confidence":0.95}\n'
    printf '{"t":1790000001,"kind":"sig\n'
    printf '{"t":1790000002,"kind":"stale","task":"third","choice":"absorbable","confidence":0.97}\n'
    printf '{"t":1790000003,"kind":"signal","task":"partial"'
  } > "$digest"
  out1=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$DRAIN" 2>/dev/null) || fail "drain failed with a malformed digest"
  assert_contains "$out1" 'ABSORBED (3 wakes' "the header did not count exactly the complete digest lines"
  assert_contains "$out1" 'task first' "the entry before the malformed line was not surfaced"
  assert_contains "$out1" 'unreadable digest entry' "the malformed line was dropped silently"
  assert_contains "$out1" 'task third' "an entry after the malformed line was lost"
  assert_not_contains "$out1" 'partial' "a partially written line was surfaced before it was complete"
  printf ',"choice":"absorbable","confidence":0.96}\n' >> "$digest"
  out2=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$DRAIN" 2>/dev/null) || fail "second drain failed"
  assert_contains "$out2" 'ABSORBED (1 wake' "the completed line was not surfaced on the next drain"
  assert_contains "$out2" 'task partial' "the completed partial line was lost"
  assert_not_contains "$out2" 'task first' "an already-surfaced entry was printed again"
  pass "a malformed digest line never hides later entries, and a partial line waits until complete"
}

test_absorb_digest_is_held_while_away_mode_owns_the_drain() {
  local home out1 out2
  home=$(jev_case absorb-digest-afk)
  mkdir -p "$home/state/jev"
  printf '{"t":1790000000,"kind":"signal","task":"task","choice":"absorbable","confidence":0.95}\n' \
    > "$home/state/jev/absorbed.jsonl"
  : > "$home/state/.afk"
  out1=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$DRAIN" 2>/dev/null) || fail "drain failed in away mode"
  assert_not_contains "$out1" 'ABSORBED' "an away-mode drain consumed the digest the captain never reads"
  rm -f "$home/state/.afk"
  out2=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$DRAIN" 2>/dev/null) || fail "return drain failed"
  assert_contains "$out2" 'ABSORBED (1 wake' "the held digest entry did not surface once away mode ended"
  pass "the digest is held while away mode drains and surfaces with the first drain after return"
}

test_absorb_digest_surfaces_once_with_the_next_drain_and_never_repeats() {
  local home out1 out2
  home=$(jev_case absorb-digest-surface)
  mkdir -p "$home/state/jev"
  printf '{"t":1790000000,"kind":"signal","task":"task","reason":"signal:task.status","status":"working: x","choice":"absorbable","confidence":0.95}\n' \
    > "$home/state/jev/absorbed.jsonl"
  out1=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$DRAIN" 2>/dev/null) || fail "drain failed with a pending digest"
  assert_contains "$out1" 'ABSORBED (1 wake' "the drain did not surface the pending digest entry"
  assert_contains "$out1" 'task task' "the surfaced digest line did not name its task"
  out2=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$DRAIN" 2>/dev/null) || fail "second drain failed"
  assert_not_contains "$out2" 'ABSORBED' "an already-surfaced digest entry was printed again"
  pass "an absorbed wake surfaces exactly once with the next drain and never repeats"
}

test_absorb_digest_tags_its_source_jev_or_rule() {
  local home out
  home=$(jev_case absorb-digest-source)
  mkdir -p "$home/state/jev"
  {
    printf '{"t":1790000000,"kind":"signal","task":"modeled","reason":"signal:x","status":"","choice":"absorbable","confidence":0.95,"source":"jev"}\n'
    printf '{"t":1790000001,"kind":"stale","task":"ruled","reason":"stale:y","status":"","choice":"absorbable","confidence":null,"source":"rule"}\n'
    printf '{"t":1790000002,"kind":"signal","task":"legacy","reason":"signal:z","status":"","choice":"absorbable","confidence":0.9}\n'
  } > "$home/state/jev/absorbed.jsonl"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$DRAIN" 2>/dev/null) || fail "drain failed with a mixed-source digest"
  assert_contains "$out" 'task modeled via jev' "a jev-sourced entry was not tagged via jev"
  assert_contains "$out" 'task ruled via rule' "a rule-sourced entry was not tagged via rule"
  assert_contains "$out" 'task legacy via jev' "an entry with no source field did not default to via jev"
  pass "the drain tags each digest entry via jev or via rule, defaulting to jev when the field is absent"
}

test_off_by_default_and_not_enabled_by_the_environment
test_foreign_state_dir_never_uses_the_key
test_shadow_classifies_without_changing_the_presentation
test_only_masked_reason_and_status_leave_the_machine
test_timeout_is_configurable
test_timeout_pauses_until_the_next_day
test_api_errors_pause_until_the_next_day
test_daily_cap_pauses_after_the_spend_is_reached
test_local_backend_takes_priority_needs_no_key_and_records_the_answering_model
test_local_backend_uncertain_maps_to_doubt
test_local_backend_timeout_is_configurable
test_local_backend_endpoint_is_read_from_the_home_not_a_config_override
test_blank_jev_endpoint_does_not_override_openrouter
test_local_backend_missing_cost_is_not_an_error
test_local_backend_refuses_a_non_loopback_endpoint
test_local_backend_load_ceiling_skips_without_a_day_pause
test_local_backend_timeout_and_api_errors_skip_without_a_day_pause
test_local_backend_status_reports_the_endpoint_and_ceiling
test_drain_never_waits_for_jev
test_hooks_record_actions_and_turn_ends_without_text
test_automated_sends_record_no_steer
test_report_attributes_actions_to_open_wakes_across_drains
test_report_keeps_unacknowledged_and_earlier_wakes_open
test_report_measures_agreement_and_lists_doubtful_cases
test_absorb_off_by_default_never_dials_or_writes_a_digest
test_absorb_requires_the_local_backend
test_absorb_refuses_below_the_measured_gate_without_an_override
test_absorb_override_skips_the_gate_and_records_a_masked_digest_entry
test_absorb_threshold_floor_is_enforced
test_absorb_falls_through_on_low_confidence_or_doubt
test_absorb_never_a_task_with_an_open_decision
test_absorb_never_a_secondmate_status_signal
test_absorb_never_a_non_working_paused_verb
test_absorb_veto_runs_ahead_of_the_model
test_absorb_gate_reports_met_and_not_met
test_absorb_digest_surfaces_once_with_the_next_drain_and_never_repeats
test_absorb_digest_tags_its_source_jev_or_rule
test_absorb_digest_is_held_while_away_mode_owns_the_drain
test_absorb_digest_surfaces_every_entry_past_a_malformed_line_and_holds_a_partial_one
