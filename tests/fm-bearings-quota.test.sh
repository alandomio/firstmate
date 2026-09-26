#!/usr/bin/env bash
# Behavior tests for bin/fm-bearings-quota.sh: the /bearings lavish board's
# provider-quota reader. Every case drives a fake quota-axi (no network) and
# asserts the printed section, including the degraded paths - tool missing,
# timeout, failed, unreadable - which must still print a board-valid section
# and exit 0 without inventing any number.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

QUOTA="$ROOT/bin/fm-bearings-quota.sh"
BOARD="$ROOT/bin/fm-bearings-board.sh"
TMP_ROOT=$(fm_test_tmproot fm-bearings-quota)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# PATH with every directory that holds a real quota-axi removed, so the
# missing-tool case holds on a machine that has it installed.
path_without_quota_axi() {
  local out="" dir
  local IFS=:
  for dir in $PATH; do
    [ -n "$dir" ] || continue
    [ -x "$dir/quota-axi" ] && continue
    out="${out:+$out:}$dir"
  done
  printf '%s\n' "$out"
}
BASE_PATH=$(path_without_quota_axi)

# fake_quota_axi <name> <script body> - prints the fakebin dir.
fake_quota_axi() {
  local dir="$TMP_ROOT/$1/fakebin"
  mkdir -p "$dir"
  {
    printf '#!/usr/bin/env bash\n'
    printf '%s\n' "$2"
  } > "$dir/quota-axi"
  chmod +x "$dir/quota-axi"
  printf '%s\n' "$dir"
}

run_quota() {  # <fakebin or ""> [env assignments...]
  local fakebin=$1
  shift
  env PATH="${fakebin:+$fakebin:}$BASE_PATH" "$@" "$QUOTA"
}

# A payload the board accepts, carrying the given quota section.
assert_board_accepts() {  # <quota-json-file> <label>
  local home="$TMP_ROOT/board-$2" payload out
  mkdir -p "$home"
  payload="$home/payload.json"
  jq '{schema: "fm-bearings-board.v1", home: "test-home", generated: "2026-09-26T00:00Z",
       prs_live: false, captains_call: [], underway: [], landed: [], charted: [], quota: .}' \
    "$1" > "$payload"
  # Validation happens before the Lavish step; a lavish-axi that refuses makes
  # build stop right after the board is published, which is all this needs,
  # and keeps a real Lavish session from ever starting.
  mkdir -p "$home/fakebin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$home/fakebin/lavish-axi"
  chmod +x "$home/fakebin/lavish-axi"
  out=$(PATH="$home/fakebin:$BASE_PATH" FM_HOME="$home" "$BOARD" build "$payload" 2>&1)
  assert_contains "$out" "board: " "the board refused the reader's $2 section: $out"
}

FIXTURE='{
  "generatedAt": "2026-09-26T14:35:03.033Z",
  "schemaVersion": 5,
  "providers": [
    { "provider": "claude", "plan": "max",
      "windows": [
        { "id": "five_hour", "label": "session", "kind": "session", "percentRemaining": 48,
          "resetsAt": "2026-09-26T16:40:00Z" },
        { "id": "seven_day", "label": "week", "kind": "weekly", "percentRemaining": 67,
          "resetsAt": "2026-10-02T07:00:00Z" },
        { "id": "model:fable", "label": "Fable week", "kind": "model" }
      ],
      "state": { "status": "stale", "stale": true, "error": "fetch failed" },
      "quotaSemantics": { "status": "unknown", "effectiveAvailability": [
        { "scope": "all_models", "status": "unknown" } ] } },
    { "provider": "codex", "windows": [],
      "state": { "status": "auth_required", "stale": false, "error": "Codex sign-in required" } },
    { "provider": "cursor", "windows": [], "state": { "status": "auth_required" } }
  ]
}'

test_projects_reported_providers_without_inventing_values() {
  local fakebin out
  fakebin=$(fake_quota_axi fixture "cat <<'EOF'
$FIXTURE
EOF")
  out=$(run_quota "$fakebin") || fail "the reader exited non-zero on a readable report"
  printf '%s\n' "$out" > "$TMP_ROOT/fixture.json"

  [ "$(printf '%s' "$out" | jq -c '[.available, .status, .generated]')" = '[true,"ok","2026-09-26T14:35:03.033Z"]' ] \
    || fail "the section header is wrong: $out"
  [ "$(printf '%s' "$out" | jq -c '[.providers[].provider]')" = '["claude","codex","agy"]' ] \
    || fail "the providers are not exactly Anthropic, OpenAI, Google in order: $out"
  [ "$(printf '%s' "$out" | jq -c '.providers[0].windows[0] | [.percent_used, .percent_remaining, .resets_at]')" \
    = '[52,48,"2026-09-26T16:40:00Z"]' ] || fail "the 5-hour window was not projected: $out"
  [ "$(printf '%s' "$out" | jq -c '.providers[0].windows[2] | [.percent_used, .percent_remaining, .resets_at]')" \
    = '[null,null,null]' ] || fail "an unreported window value was invented: $out"
  [ "$(printf '%s' "$out" | jq -c '[.providers[0].attention[].kind]')" = '["stale","headroom_unknown"]' ] \
    || fail "the stale and unknown-headroom attention lines are missing: $out"
  [ "$(printf '%s' "$out" | jq -c '.providers[1] | [.available, .status, .detail]')" \
    = '[false,"auth_required","Codex sign-in required"]' ] || fail "a signed-out provider was not marked unavailable: $out"
  [ "$(printf '%s' "$out" | jq -c '.providers[2] | [.available, .status, (.windows | length)]')" \
    = '[false,"not_reported",0]' ] || fail "an unreported provider was not marked not_reported: $out"
  assert_board_accepts "$TMP_ROOT/fixture.json" fixture
  pass "the reader projects reported providers and never invents a value"
}

# assert_degraded <label> <expected status> <reader output>
assert_degraded() {
  local out=$3
  printf '%s\n' "$out" > "$TMP_ROOT/$1.json"
  [ "$(printf '%s' "$out" | jq -c '[.available, .status]')" = "[false,\"$2\"]" ] \
    || fail "the $1 path did not report status $2: $out"
  [ "$(printf '%s' "$out" | jq -c '[.providers[] | [.provider, .available, .status, (.windows | length)]]')" \
    = "[[\"claude\",false,\"$2\",0],[\"codex\",false,\"$2\",0],[\"agy\",false,\"$2\",0]]" ] \
    || fail "the $1 path did not mark every provider unavailable: $out"
  assert_board_accepts "$TMP_ROOT/$1.json" "$1"
}

test_missing_tool_degrades_without_failing() {
  local out
  out=$(run_quota "") || fail "the reader failed when quota-axi is missing"
  assert_degraded missing tool_missing "$out"
  pass "a missing quota-axi degrades to an unavailable section"
}

test_timeout_degrades_without_failing() {
  local fakebin out
  fakebin=$(fake_quota_axi slow 'sleep 10; echo "{}"')
  out=$(run_quota "$fakebin" FM_BEARINGS_QUOTA_TIMEOUT=1) || fail "the reader failed on a timeout"
  assert_degraded timeout timeout "$out"
  pass "a quota-axi that does not answer in time degrades to an unavailable section"
}

test_failed_and_unreadable_output_degrade_without_failing() {
  local fakebin out
  fakebin=$(fake_quota_axi failed 'echo boom >&2; exit 3')
  out=$(run_quota "$fakebin") || fail "the reader failed when quota-axi failed"
  assert_degraded failed failed "$out"

  fakebin=$(fake_quota_axi unreadable 'echo "not json"')
  out=$(run_quota "$fakebin") || fail "the reader failed on unreadable output"
  assert_degraded unreadable unreadable "$out"
  pass "a failing or unreadable quota-axi degrades to an unavailable section"
}

test_readable_json_wins_over_a_nonzero_exit() {
  local fakebin out
  fakebin=$(fake_quota_axi partial "cat <<'EOF'
$FIXTURE
EOF
exit 1")
  out=$(run_quota "$fakebin") || fail "the reader failed on a partial report"
  [ "$(printf '%s' "$out" | jq -c '[.status, .providers[0].available]')" = '["ok",true]' ] \
    || fail "a readable report with a non-zero exit was thrown away: $out"
  pass "a readable report is used even when quota-axi exits non-zero"
}

test_malformed_provider_entries_never_break_the_section() {
  local fakebin out
  fakebin=$(fake_quota_axi malformed "cat <<'EOF'
{ \"providers\": [
  { \"provider\": \"claude\", \"state\": \"fresh\", \"windows\": \"x\",
    \"quotaSemantics\": { \"effectiveAvailability\": \"x\" } },
  { \"provider\": \"codex\", \"state\": { \"status\": \"fresh\" },
    \"windows\": [ \"x\", { \"id\": \"five_hour\", \"kind\": \"session\", \"percentUsed\": 30 } ],
    \"quotaSemantics\": \"x\" },
  { \"provider\": \"agy\", \"state\": [], \"quotaSemantics\": { \"effectiveAvailability\": [ \"x\", 3 ] } }
] }
EOF")
  out=$(run_quota "$fakebin") || fail "the reader exited non-zero on malformed provider entries"
  printf '%s\n' "$out" > "$TMP_ROOT/malformed.json"
  [ "$(printf '%s' "$out" | jq -c '[.status, [.providers[] | [.provider, .available, .status]]]')" \
    = '["ok",[["claude",false,"no_windows"],["codex",true,"fresh"],["agy",false,"no_windows"]]]' ] \
    || fail "malformed provider entries were not tolerated: $out"
  [ "$(printf '%s' "$out" | jq -c '.providers[1].windows | map([.percent_used, .percent_remaining])')" = '[[30,70]]' ] \
    || fail "the well-formed window next to a malformed one was lost: $out"
  assert_board_accepts "$TMP_ROOT/malformed.json" malformed
  pass "malformed provider entries still yield a board-valid section"
}

test_reported_percent_used_is_kept() {
  local fakebin out
  fakebin=$(fake_quota_axi used "cat <<'EOF'
{ \"providers\": [ { \"provider\": \"claude\", \"state\": { \"status\": \"fresh\" }, \"windows\": [
  { \"id\": \"a\", \"percentUsed\": 0.1 },
  { \"id\": \"b\", \"percentUsed\": 40, \"percentRemaining\": 55 } ] } ] }
EOF")
  out=$(run_quota "$fakebin") || fail "the reader exited non-zero"
  [ "$(printf '%s' "$out" | jq -c '.providers[0].windows | map([.percent_used, .percent_remaining])')" \
    = '[[0.1,99.9],[40,55]]' ] || fail "a reported percentUsed was not kept: $out"
  pass "a reported percentUsed is kept and only the missing value is derived"
}

test_projects_reported_providers_without_inventing_values
test_missing_tool_degrades_without_failing
test_timeout_degrades_without_failing
test_failed_and_unreadable_output_degrade_without_failing
test_readable_json_wins_over_a_nonzero_exit
test_malformed_provider_entries_never_break_the_section
test_reported_percent_used_is_kept
