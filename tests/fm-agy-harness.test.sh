#!/usr/bin/env bash
# Behavior tests for the agy (Antigravity CLI) crewmate/scout adapter:
# harness detection and its ordering-hazard fix, the control-plane tables
# (interrupt, exit, secondmate refusal), and the semantic busy-state fold
# over agy's own per-conversation SQLite database.
#
# agy is not installed in CI, so these tests fake its process identity (a
# copied `bash` binary named `agy`, the same technique fm-muse-harness.test.sh
# uses) and its conversation database (a real sqlite3 fixture, skipped
# gracefully when the sqlite3 CLI itself is not installed - the same
# degradation bin/fm-busy-lib.sh's fold uses in production).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry. Drop the
# ambient markers so the asserted verdict does not depend on which harness
# launched the suite.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS ANTIGRAVITY_AGENT AI_AGENT

HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-agy-harness)

# --- harness detection -------------------------------------------------

# The ordering hazard this adapter shares with Cursor: agy does not clear a
# foreign primary's CLAUDECODE/AI_AGENT markers, so whichever is tested first
# wins. bin/fm-harness.sh must test ANTIGRAVITY_AGENT before CLAUDECODE.
test_env_marker_wins_over_inherited_claude_markers() {
  local out
  out=$(CLAUDECODE=1 ANTIGRAVITY_AGENT=1 AI_AGENT=claude-code_test "$HARNESS")
  [ "$out" = agy ] || fail "ANTIGRAVITY_AGENT did not outrank inherited CLAUDECODE/AI_AGENT: got '$out'"
  pass "agy's env marker is tested before the inherited claude markers"
}

test_no_marker_falls_back_to_claude() {
  local out
  out=$(CLAUDECODE=1 "$HARNESS")
  [ "$out" = claude ] || fail "expected claude with no antigravity marker present, got '$out'"
  pass "claude is still detected when no antigravity marker is present"
}

# agy's own process resolves unwrapped - tmux and ps both report its comm as
# the literal "agy" (verified live, agy 1.1.28) - so ancestry detection needs
# only an exact match, unlike cursor-agent's node-wrapper problem.
test_detects_agy_process_ancestor() {
  local dir out
  dir="$TMP_ROOT/detect"
  mkdir -p "$dir"
  cp "$(command -v bash)" "$dir/agy"
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u ANTIGRAVITY_AGENT -u AI_AGENT \
    "$dir/agy" -c "r=\$(\"$HARNESS\"); printf '%s' \"\$r\"")
  [ "$out" = agy ] || fail "fm-harness.sh under process 'agy' reported '$out', expected agy"
  pass "agy is detected through its own unwrapped process ancestor"
}

# --- control-plane tables (bin/fm-control-lib.sh) -----------------------

test_control_lib_tables() {
  local out
  out=$(
    # shellcheck source=bin/fm-control-lib.sh
    . "$ROOT/bin/fm-control-lib.sh"
    fm_control_harness_supported agy && echo supported
    fm_control_harness_supports_kind agy ship && echo ship-ok
    fm_control_harness_supports_kind agy scout && echo scout-ok
    fm_control_harness_supports_kind agy secondmate || echo secondmate-refused
    fm_control_interrupt_key agy
    fm_control_interrupt_repeat agy
    fm_control_interrupt_clear_key agy; echo "clear-key-rc-$?"
    fm_control_exit_command agy
  )
  assert_contains "$out" "supported" "agy missing from fm_control_harness_supported"
  assert_contains "$out" "ship-ok" "agy should support ship kind"
  assert_contains "$out" "scout-ok" "agy should support scout kind"
  assert_contains "$out" "secondmate-refused" "agy must be refused for secondmate kind"
  assert_contains "$out" "Escape" "agy interrupt key must be Escape"
  assert_contains "$out" "clear-key-rc-0" "agy interrupt clear key must return success with no key (verified: composer left empty)"
  assert_contains "$out" "/exit" "agy exit command must be /exit"
  pass "fm-control-lib.sh tables carry agy's verified interrupt/exit/kind facts"
}

test_control_lib_wiring_paths() {
  local out
  out=$(
    # shellcheck source=bin/fm-control-lib.sh
    . "$ROOT/bin/fm-control-lib.sh"
    fm_control_harness_wiring_paths agy /wt /state taskid
  )
  assert_contains "$out" "/state/taskid.agy-session" "agy wiring paths must include the session binding sidecar"
  assert_contains "$out" "/state/taskid.agy-session-current" "agy wiring paths must include the cached resolution sidecar"
  pass "fm-control-lib.sh retires both agy busy-binding sidecars on a harness change"
}

# --- busy-state fold (bin/fm-busy-lib.sh) -------------------------------

test_agy_trusts_no_record_source() {
  local out
  out=$(
    # shellcheck source=bin/fm-busy-lib.sh
    . "$ROOT/bin/fm-busy-lib.sh"
    fm_busy_sources_for_harness agy
  )
  [ -z "$out" ] || fail "agy trusts record sources it has no writer for: '$out'"
  pass "agy trusts no busy record source (a pull source, like muse and cursor)"
}

# agy_workspace_field_hex <workspace-root>: the workspace path encoded the way
# agy's own database carries it - a protobuf length-delimited string field:
# a tag byte, then a base-128 varint holding the payload's exact byte length,
# then the raw path bytes. The trailing `7a 01 41` reproduces the measured
# live shape the binding predicate has to survive: the byte immediately after
# a genuine occurrence is the NEXT field's tag, which was observed to be an
# ordinary alphanumeric (0x7a, ASCII 'z'), so no trailing-delimiter assumption
# holds. docs/verification/runtime-backends.md owns that measurement.
agy_workspace_field_hex() {  # <workspace-root>
  local ws=$1 len n hex
  len=$(printf '%s' "$ws" | wc -c)
  len=$((len))
  hex=12
  n=$len
  while [ "$n" -ge 128 ]; do
    hex="$hex$(printf '%02x' $(((n % 128) + 128)))"
    n=$((n / 128))
  done
  hex="$hex$(printf '%02x' "$n")"
  hex="$hex$(printf '%s' "$ws" | od -An -tx1 -v | tr -d ' \n')"
  printf '%s7a0141' "$hex"
}

# make_conversation_db <path> <workspace-root> <status-rows...>: a minimal
# fixture reproducing agy's real conversation database shape closely enough
# for the fold under test - a `steps` table with the exact schema, plus the
# workspace path stored as a protobuf-framed blob, which is the byte contract
# the resolver decodes.
make_conversation_db() {
  local path=$1 ws=$2 idx=0 status
  shift 2
  sqlite3 "$path" "CREATE TABLE steps (idx integer, step_type integer, status integer, PRIMARY KEY (idx));" || return 1
  sqlite3 "$path" "CREATE TABLE workspace_marker (blob blob);"
  sqlite3 "$path" "INSERT INTO workspace_marker (blob) VALUES (X'$(agy_workspace_field_hex "$ws")');"
  for status in "$@"; do
    sqlite3 "$path" "INSERT INTO steps (idx, step_type, status) VALUES ($idx, 15, $status);"
    idx=$((idx + 1))
  done
}

test_busy_fold_resolves_and_reads_status() {
  if ! command -v sqlite3 >/dev/null 2>&1; then
    pass "agy busy fold: sqlite3 not installed in this environment, skipped"
    return 0
  fi
  local case_dir root state ws db out
  case_dir="$TMP_ROOT/busy-resolve"
  root="$case_dir/conversations"
  state="$case_dir/state"
  ws="$case_dir/workspace"
  mkdir -p "$root" "$state" "$ws"
  db="$root/11111111-1111-1111-1111-111111111111.db"
  make_conversation_db "$db" "$ws" 3 3 8 || fail "could not build the sqlite3 fixture"
  {
    printf 'conversations_root=%s\n' "$root"
    printf 'workspace_root=%s\n' "$ws"
  } > "$state/task1.agy-session"
  out=$(
    # shellcheck source=bin/fm-busy-lib.sh
    . "$ROOT/bin/fm-busy-lib.sh"
    resolved=$(fm_busy_agy_conversation "$state" task1) || { echo "resolve-failed"; exit 0; }
    [ "$resolved" = "$db" ] && echo "resolve-ok"
    fm_busy_agy_run_state "$resolved"
  )
  assert_contains "$out" "resolve-ok" "the single matching conversation was not resolved"
  assert_contains "$out" "busy" "a last step with status 8 must fold to busy"
  pass "agy busy fold resolves the bound conversation and reads a running step as busy"
}

test_busy_fold_settled_reads_idle() {
  if ! command -v sqlite3 >/dev/null 2>&1; then
    pass "agy busy fold (settled): sqlite3 not installed in this environment, skipped"
    return 0
  fi
  local case_dir root state ws db out
  case_dir="$TMP_ROOT/busy-settled"
  root="$case_dir/conversations"
  state="$case_dir/state"
  ws="$case_dir/workspace"
  mkdir -p "$root" "$state" "$ws"
  db="$root/22222222-2222-2222-2222-222222222222.db"
  make_conversation_db "$db" "$ws" 3 3 3 || fail "could not build the sqlite3 fixture"
  {
    printf 'conversations_root=%s\n' "$root"
    printf 'workspace_root=%s\n' "$ws"
  } > "$state/task2.agy-session"
  out=$(
    # shellcheck source=bin/fm-busy-lib.sh
    . "$ROOT/bin/fm-busy-lib.sh"
    resolved=$(fm_busy_agy_conversation "$state" task2) || exit 0
    fm_busy_agy_run_state "$resolved"
  )
  [ "$out" = idle ] || fail "a fully settled conversation must fold to idle, got '$out'"
  pass "agy busy fold reads a settled conversation as idle"
}

# A conversation that PRE-EXISTED at spawn time (recorded as prior_conversation
# in the sidecar) must never be treated as this task's own, even though it
# matches the same workspace path - this is what lets a relaunch into a reused
# worktree fold its OWN conversation instead of its predecessor's.
test_busy_fold_excludes_prior_conversation() {
  if ! command -v sqlite3 >/dev/null 2>&1; then
    pass "agy busy fold (prior exclusion): sqlite3 not installed in this environment, skipped"
    return 0
  fi
  local case_dir root state ws prior_db new_db out
  case_dir="$TMP_ROOT/busy-prior"
  root="$case_dir/conversations"
  state="$case_dir/state"
  ws="$case_dir/workspace"
  mkdir -p "$root" "$state" "$ws"
  prior_db="$root/33333333-3333-3333-3333-333333333333.db"
  new_db="$root/44444444-4444-4444-4444-444444444444.db"
  make_conversation_db "$prior_db" "$ws" 3 || fail "could not build the prior sqlite3 fixture"
  make_conversation_db "$new_db" "$ws" 8 || fail "could not build the new sqlite3 fixture"
  {
    printf 'conversations_root=%s\n' "$root"
    printf 'workspace_root=%s\n' "$ws"
    printf 'prior_conversation=%s\n' "$(basename -- "$prior_db")"
  } > "$state/task3.agy-session"
  out=$(
    # shellcheck source=bin/fm-busy-lib.sh
    . "$ROOT/bin/fm-busy-lib.sh"
    fm_busy_agy_conversation "$state" task3
  )
  [ "$out" = "$new_db" ] || fail "expected the new conversation '$new_db', resolved '$out'"
  pass "agy busy fold excludes a conversation recorded as pre-existing at spawn time"
}

# The prefix-collision class measured live (docs/verification/runtime-backends.md):
# sibling worktrees are numbered pool slots, so slot 1's path occurs as a raw
# byte substring inside slot 10's own conversation database. Only slot 10's
# database exists here, so an unanchored byte match would hand slot 1 its
# sibling's conversation - and then cache it, mislabeling that task for life.
test_busy_fold_ignores_sibling_slot_path_prefix() {
  if ! command -v sqlite3 >/dev/null 2>&1; then
    pass "agy busy fold (sibling slot): sqlite3 not installed in this environment, skipped"
    return 0
  fi
  local case_dir root state ws sibling out status
  case_dir="$TMP_ROOT/busy-sibling-slot"
  root="$case_dir/conversations"
  state="$case_dir/state"
  ws="$case_dir/pool/1"
  sibling="$case_dir/pool/10"
  mkdir -p "$root" "$state" "$ws" "$sibling"
  make_conversation_db "$root/77777777-7777-7777-7777-777777777777.db" "$sibling" 8 \
    || fail "could not build the sibling sqlite3 fixture"
  grep -aqF -- "$ws" "$root/77777777-7777-7777-7777-777777777777.db" \
    || fail "fixture does not reproduce the collision: slot 1's path is not a raw substring of slot 10's database"
  {
    printf 'conversations_root=%s\n' "$root"
    printf 'workspace_root=%s\n' "$ws"
  } > "$state/task5.agy-session"
  out=$(
    # shellcheck source=bin/fm-busy-lib.sh
    . "$ROOT/bin/fm-busy-lib.sh"
    fm_busy_agy_conversation "$state" task5
  )
  status=$?
  [ "$status" -ne 0 ] || fail "slot 1 bound to sibling slot 10's conversation: '$out'"
  [ ! -e "$state/task5.agy-session-current" ] \
    || fail "a sibling slot's conversation was cached as this task's binding"
  pass "agy busy fold never binds a task to a sibling pool slot's conversation"
}

# The other half of the same measurement: the database's OWN workspace must
# still resolve even though the byte following the path is alphanumeric.
test_busy_fold_resolves_across_an_alphanumeric_successor_byte() {
  if ! command -v sqlite3 >/dev/null 2>&1; then
    pass "agy busy fold (alphanumeric successor): sqlite3 not installed in this environment, skipped"
    return 0
  fi
  local case_dir root state ws db out
  case_dir="$TMP_ROOT/busy-successor"
  root="$case_dir/conversations"
  state="$case_dir/state"
  ws="$case_dir/pool/10"
  mkdir -p "$root" "$state" "$ws"
  db="$root/88888888-8888-8888-8888-888888888888.db"
  make_conversation_db "$db" "$ws" 8 || fail "could not build the sqlite3 fixture"
  {
    printf 'conversations_root=%s\n' "$root"
    printf 'workspace_root=%s\n' "$ws"
  } > "$state/task6.agy-session"
  out=$(
    # shellcheck source=bin/fm-busy-lib.sh
    . "$ROOT/bin/fm-busy-lib.sh"
    fm_busy_agy_conversation "$state" task6
  )
  [ "$out" = "$db" ] || fail "the task's own conversation did not resolve, got '$out'"
  pass "agy busy fold resolves its own conversation despite an alphanumeric successor byte"
}

# A workspace path longer than 127 bytes is framed with a MULTI-byte varint,
# which the single-byte decode would miss entirely.
test_busy_fold_decodes_a_multibyte_length_prefix() {
  if ! command -v sqlite3 >/dev/null 2>&1; then
    pass "agy busy fold (multi-byte length): sqlite3 not installed in this environment, skipped"
    return 0
  fi
  local case_dir root state ws deep db out
  case_dir="$TMP_ROOT/busy-longpath"
  root="$case_dir/conversations"
  state="$case_dir/state"
  deep=$(printf 'd%.0s' $(seq 1 140))
  ws="$case_dir/$deep/wt"
  mkdir -p "$root" "$state" "$ws"
  [ "$(printf '%s' "$ws" | wc -c)" -gt 127 ] \
    || fail "fixture workspace path is not long enough to need a multi-byte varint"
  db="$root/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb.db"
  make_conversation_db "$db" "$ws" 8 || fail "could not build the sqlite3 fixture"
  {
    printf 'conversations_root=%s\n' "$root"
    printf 'workspace_root=%s\n' "$ws"
  } > "$state/task9.agy-session"
  out=$(
    # shellcheck source=bin/fm-busy-lib.sh
    . "$ROOT/bin/fm-busy-lib.sh"
    fm_busy_agy_conversation "$state" task9
  )
  [ "$out" = "$db" ] || fail "a multi-byte length prefix did not resolve, got '$out'"
  pass "agy busy fold decodes a multi-byte varint length prefix"
}

# The real classifier entry point, not the fold helpers: agy must reach its
# pull source ahead of the record read and label the verdict agy-conversation.
test_busy_classify_reports_the_agy_conversation_source() {
  if ! command -v sqlite3 >/dev/null 2>&1; then
    pass "agy classify entry point: sqlite3 not installed in this environment, skipped"
    return 0
  fi
  local case_dir root state ws out
  case_dir="$TMP_ROOT/classify"
  root="$case_dir/conversations"
  state="$case_dir/state"
  ws="$case_dir/workspace"
  mkdir -p "$root" "$state" "$ws"
  make_conversation_db "$root/99999999-9999-9999-9999-999999999999.db" "$ws" 3 8 \
    || fail "could not build the busy sqlite3 fixture"
  {
    printf 'conversations_root=%s\n' "$root"
    printf 'workspace_root=%s\n' "$ws"
  } > "$state/task7.agy-session"
  out=$(
    # shellcheck source=bin/fm-busy-lib.sh
    . "$ROOT/bin/fm-busy-lib.sh"
    fm_busy_classify tmux none agy task7 "$state"
  )
  [ "$out" = "busy agy-conversation" ] || fail "expected 'busy agy-conversation', got '$out'"

  mkdir -p "$case_dir/idle-root" "$case_dir/idle-state"
  make_conversation_db "$case_dir/idle-root/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.db" "$ws" 3 3 \
    || fail "could not build the idle sqlite3 fixture"
  {
    printf 'conversations_root=%s\n' "$case_dir/idle-root"
    printf 'workspace_root=%s\n' "$ws"
  } > "$case_dir/idle-state/task8.agy-session"
  out=$(
    # shellcheck source=bin/fm-busy-lib.sh
    . "$ROOT/bin/fm-busy-lib.sh"
    fm_busy_classify tmux none agy task8 "$case_dir/idle-state"
  )
  [ "$out" = "idle agy-conversation" ] || fail "expected 'idle agy-conversation', got '$out'"
  pass "fm_busy_classify routes an agy task to its conversation fold and names the source"
}

# Zero or more than one currently-matching, non-prior conversation is a genuine
# ambiguity and must resolve to failure (unknown at the classifier), never a
# guess.
test_busy_fold_ambiguous_resolution_fails() {
  if ! command -v sqlite3 >/dev/null 2>&1; then
    pass "agy busy fold (ambiguity): sqlite3 not installed in this environment, skipped"
    return 0
  fi
  local case_dir root state ws out status
  case_dir="$TMP_ROOT/busy-ambiguous"
  root="$case_dir/conversations"
  state="$case_dir/state"
  ws="$case_dir/workspace"
  mkdir -p "$root" "$state" "$ws"
  make_conversation_db "$root/55555555-5555-5555-5555-555555555555.db" "$ws" 3 \
    || fail "could not build fixture a"
  make_conversation_db "$root/66666666-6666-6666-6666-666666666666.db" "$ws" 3 \
    || fail "could not build fixture b"
  {
    printf 'conversations_root=%s\n' "$root"
    printf 'workspace_root=%s\n' "$ws"
  } > "$state/task4.agy-session"
  out=$(
    # shellcheck source=bin/fm-busy-lib.sh
    . "$ROOT/bin/fm-busy-lib.sh"
    fm_busy_agy_conversation "$state" task4
  )
  status=$?
  [ "$status" -ne 0 ] || fail "two matching conversations with neither recorded as prior must not resolve, got '$out'"
  pass "agy busy fold refuses to guess between two ambiguous conversations"
}

test_env_marker_wins_over_inherited_claude_markers
test_no_marker_falls_back_to_claude
test_detects_agy_process_ancestor
test_control_lib_tables
test_control_lib_wiring_paths
test_agy_trusts_no_record_source
test_busy_fold_resolves_and_reads_status
test_busy_fold_settled_reads_idle
test_busy_fold_excludes_prior_conversation
test_busy_fold_ignores_sibling_slot_path_prefix
test_busy_fold_resolves_across_an_alphanumeric_successor_byte
test_busy_fold_decodes_a_multibyte_length_prefix
test_busy_fold_ambiguous_resolution_fails
test_busy_classify_reports_the_agy_conversation_source
