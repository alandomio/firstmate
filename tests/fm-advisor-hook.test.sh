#!/usr/bin/env bash
# Behavior tests for bin/fm-advisor-hook.sh's skip/guard/cap paths and reviewer
# call, driven with synthetic Stop-hook payloads and transcripts (no real
# executor or crewmate worktree) - the fixture shapes are lifted from the
# scout prototype's own synthetic verification (data/scout-advisor-hook/report.md).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOOK="$ROOT/bin/fm-advisor-hook.sh"
TMP_ROOT=$(fm_test_tmproot fm-advisor-hook)

make_fake_claude() {  # <dir> -> writes fakebin/claude, prints fakebin path
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/claude" <<'SH'
#!/usr/bin/env bash
set -u
cat >/dev/null
[ -z "${FM_FAKE_CLAUDE_CALLED:-}" ] || : > "$FM_FAKE_CLAUDE_CALLED"
if [ "${FM_FAKE_CLAUDE_RC:-0}" != 0 ]; then
  exit "${FM_FAKE_CLAUDE_RC}"
fi
result_json=$(printf '%s' "${FM_FAKE_CLAUDE_RESULT:-OK}" | jq -Rs .)
printf '[{"type":"system"},{"type":"result","result":%s,"total_cost_usd":0.0044,"duration_ms":1800}]\n' "$result_json"
SH
  chmod +x "$fakebin/claude"
  printf '%s\n' "$fakebin"
}

new_case() {  # <name> -> prints case dir
  local dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

# A normal (non-status-only) transcript: the last assistant turn edits a file
# and writes real prose, so it is never mistaken for a status-line-only turn.
write_normal_transcript() {  # <path>
  {
    printf '%s\n' '{"type":"user","message":{"content":[{"type":"text","text":"do the task"}]}}'
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"foo.py"}},{"type":"text","text":"Implemented the requested change and updated the return type annotation to match."}]}}'
  } > "$1"
}

# A status-line-only transcript: the last assistant turn only ran a Bash
# status append, with negligible prose - the hook must skip this without
# spending a reviewer call.
write_status_only_transcript() {  # <path>
  {
    printf '%s\n' '{"type":"user","message":{"content":[{"type":"text","text":"continue"}]}}'
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo \"working: setup done\" >> state/foo.status"}},{"type":"text","text":"noted"}]}}'
  } > "$1"
}

run_hook() {  # <case-dir> <payload-json> [extra env "NAME=val" ...]
  local dir=$1 payload=$2
  shift 2
  printf '%s' "$payload" | env "$@" \
    FM_ADVISOR_COUNTER="$dir/counter" FM_ADVISOR_LOG="$dir/log.jsonl" \
    FM_ADVISOR_BRIEF="$dir/BRIEF.md" \
    "$HOOK"
}

log_verdicts() {  # <case-dir> -> newline-separated verdict values, in order
  [ -f "$1/log.jsonl" ] || return 0
  jq -r '.verdict' "$1/log.jsonl"
}

test_stop_hook_active_skips_without_a_reviewer_call() {
  local dir fakebin payload rc called
  dir=$(new_case active)
  fakebin=$(make_fake_claude "$dir")
  write_normal_transcript "$dir/transcript.jsonl"
  payload=$(jq -cn --arg tp "$dir/transcript.jsonl" '{stop_hook_active:true,transcript_path:$tp}')
  called="$dir/claude-called"

  run_hook "$dir" "$payload" PATH="$fakebin:$PATH" FM_FAKE_CLAUDE_CALLED="$called" >/dev/null 2>&1
  rc=$?
  expect_code 0 "$rc" "stop_hook_active must exit 0"
  assert_absent "$called" "stop_hook_active must never invoke the reviewer"
  [ "$(log_verdicts "$dir")" = skip ] || fail "stop_hook_active must log a skip verdict, got: $(log_verdicts "$dir")"
  assert_grep stop_hook_active "$dir/log.jsonl" "the logged skip must name stop_hook_active as the reason"
  pass "the loop guard skips the continuation its own exit-2 caused, with no reviewer call"
}

test_status_only_turn_skips_without_a_reviewer_call() {
  local dir fakebin payload rc called
  dir=$(new_case statusonly)
  fakebin=$(make_fake_claude "$dir")
  write_status_only_transcript "$dir/transcript.jsonl"
  payload=$(jq -cn --arg tp "$dir/transcript.jsonl" '{stop_hook_active:false,transcript_path:$tp}')
  called="$dir/claude-called"

  run_hook "$dir" "$payload" PATH="$fakebin:$PATH" FM_FAKE_CLAUDE_CALLED="$called" >/dev/null 2>&1
  rc=$?
  expect_code 0 "$rc" "a status-line-only turn must exit 0"
  assert_absent "$called" "a status-line-only turn must never invoke the reviewer"
  assert_grep status-line-only-turn "$dir/log.jsonl" "the logged skip must name the status-line-only reason"
  assert_absent "$dir/counter" "a status-line-only skip must not spend a unit of the reviewer call cap"
  pass "a turn that only appended a status line is skipped with no reviewer call spent"
}

test_max_calls_cap_skips_without_a_reviewer_call() {
  local dir fakebin payload rc called
  dir=$(new_case maxcalls)
  fakebin=$(make_fake_claude "$dir")
  write_normal_transcript "$dir/transcript.jsonl"
  payload=$(jq -cn --arg tp "$dir/transcript.jsonl" '{stop_hook_active:false,transcript_path:$tp}')
  called="$dir/claude-called"
  printf '2' > "$dir/counter"

  run_hook "$dir" "$payload" PATH="$fakebin:$PATH" FM_FAKE_CLAUDE_CALLED="$called" \
    FM_ADVISOR_MAX_CALLS=2 >/dev/null 2>&1
  rc=$?
  expect_code 0 "$rc" "an exhausted call cap must exit 0"
  assert_absent "$called" "an exhausted call cap must never invoke the reviewer"
  assert_grep "max-calls-exhausted:2" "$dir/log.jsonl" "the logged skip must name the exhausted cap"
  [ "$(cat "$dir/counter")" = 3 ] || fail "the counter must still advance past the cap so the skip is durable"
  pass "the per-worktree call cap skips further reviews once exhausted, with no reviewer call spent"
}

test_empty_payload_exits_silently_with_no_log_entry() {
  local dir fakebin rc
  dir=$(new_case emptypayload)
  fakebin=$(make_fake_claude "$dir")

  run_hook "$dir" "" PATH="$fakebin:$PATH" >/dev/null 2>&1
  rc=$?
  expect_code 0 "$rc" "an empty stdin payload must exit 0"
  assert_absent "$dir/log.jsonl" "an empty payload must never write a log entry"
  pass "an empty Stop-hook payload exits silently before any logging or reviewer call"
}

test_missing_transcript_exits_silently_with_no_log_entry() {
  local dir fakebin payload rc
  dir=$(new_case notranscript)
  fakebin=$(make_fake_claude "$dir")
  payload=$(jq -cn --arg tp "$dir/does-not-exist.jsonl" '{stop_hook_active:false,transcript_path:$tp}')

  run_hook "$dir" "$payload" PATH="$fakebin:$PATH" >/dev/null 2>&1
  rc=$?
  expect_code 0 "$rc" "a missing transcript file must exit 0"
  assert_absent "$dir/log.jsonl" "a missing transcript must never write a log entry"
  pass "a missing or empty transcript path exits silently with no log entry"
}

test_reviewer_ok_verdict_exits_zero() {
  local dir fakebin payload rc
  dir=$(new_case okverdict)
  fakebin=$(make_fake_claude "$dir")
  write_normal_transcript "$dir/transcript.jsonl"
  payload=$(jq -cn --arg tp "$dir/transcript.jsonl" '{stop_hook_active:false,transcript_path:$tp}')

  run_hook "$dir" "$payload" PATH="$fakebin:$PATH" FM_FAKE_CLAUDE_RESULT="OK" >/dev/null 2>&1
  rc=$?
  expect_code 0 "$rc" "an OK reviewer verdict must exit 0"
  [ "$(log_verdicts "$dir")" = ok ] || fail "an OK verdict must log verdict=ok, got: $(log_verdicts "$dir")"
  pass "a reviewer verdict of OK exits 0 and logs the ok verdict"
}

test_reviewer_advice_exits_two_with_advice_on_stderr() {
  local dir fakebin payload rc err
  dir=$(new_case advice)
  fakebin=$(make_fake_claude "$dir")
  write_normal_transcript "$dir/transcript.jsonl"
  payload=$(jq -cn --arg tp "$dir/transcript.jsonl" '{stop_hook_active:false,transcript_path:$tp}')

  err=$(run_hook "$dir" "$payload" PATH="$fakebin:$PATH" \
    FM_FAKE_CLAUDE_RESULT="- Return annotation is wrong now that partial windows yield None" 2>&1 1>/dev/null)
  rc=$?
  expect_code 2 "$rc" "material advice must exit 2 so Claude continues the turn"
  assert_contains "$err" "Return annotation is wrong" "the advice text must reach stderr"
  [ "$(log_verdicts "$dir")" = advise ] || fail "material advice must log verdict=advise, got: $(log_verdicts "$dir")"
  pass "material reviewer advice exits 2 with the advice on stderr and logs the advise verdict"
}

test_failed_reviewer_call_fails_open() {
  local dir fakebin payload rc
  dir=$(new_case failopen)
  fakebin=$(make_fake_claude "$dir")
  write_normal_transcript "$dir/transcript.jsonl"
  payload=$(jq -cn --arg tp "$dir/transcript.jsonl" '{stop_hook_active:false,transcript_path:$tp}')

  run_hook "$dir" "$payload" PATH="$fakebin:$PATH" FM_FAKE_CLAUDE_RC=1 >/dev/null 2>&1
  rc=$?
  expect_code 0 "$rc" "a failed reviewer call must fail open (exit 0), never block the turn"
  [ "$(log_verdicts "$dir")" = fail-open ] || fail "a failed reviewer call must log verdict=fail-open, got: $(log_verdicts "$dir")"
  pass "a failed reviewer call fails open rather than blocking the crewmate's turn"
}

test_missing_jq_fails_open_before_any_reviewer_call() {
  local dir fakebin_claude fakebin_nojq payload rc called
  dir=$(new_case nojq)
  fakebin_claude=$(make_fake_claude "$dir")
  write_normal_transcript "$dir/transcript.jsonl"
  payload=$(jq -cn --arg tp "$dir/transcript.jsonl" '{stop_hook_active:false,transcript_path:$tp}')
  called="$dir/claude-called"

  fakebin_nojq="$dir/nojq-path"
  mkdir -p "$fakebin_nojq"
  ln -s "$fakebin_claude/claude" "$fakebin_nojq/claude"
  for tool in bash cat timeout tr cut date head; do
    p=$(command -v "$tool" 2>/dev/null) || continue
    ln -sf "$p" "$fakebin_nojq/$tool"
  done

  run_hook "$dir" "$payload" PATH="$fakebin_nojq" FM_FAKE_CLAUDE_CALLED="$called" >/dev/null 2>&1
  rc=$?
  expect_code 0 "$rc" "a missing jq must exit 0 rather than block the turn"
  assert_absent "$called" "a missing jq must never reach the reviewer call"
  assert_absent "$dir/log.jsonl" "a missing jq cannot even log its own skip (jq itself writes the log)"
  pass "a missing jq dependency fails open before any reviewer call, exactly like every other failure mode"
}

test_stop_hook_active_skips_without_a_reviewer_call
test_status_only_turn_skips_without_a_reviewer_call
test_max_calls_cap_skips_without_a_reviewer_call
test_empty_payload_exits_silently_with_no_log_entry
test_missing_transcript_exits_silently_with_no_log_entry
test_reviewer_ok_verdict_exits_zero
test_reviewer_advice_exits_two_with_advice_on_stderr
test_failed_reviewer_call_fails_open
test_missing_jq_fails_open_before_any_reviewer_call

echo "# all fm-advisor-hook tests passed"
