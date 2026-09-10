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
SPAWN="$ROOT/bin/fm-spawn.sh"
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
  local path=$1 ws=$2 idx=0 row type status
  shift 2
  sqlite3 "$path" "CREATE TABLE steps (idx integer, step_type integer, status integer, PRIMARY KEY (idx));" || return 1
  sqlite3 "$path" "CREATE TABLE workspace_marker (blob blob);"
  sqlite3 "$path" "INSERT INTO workspace_marker (blob) VALUES (X'$(agy_workspace_field_hex "$ws")');"
  for row in "$@"; do
    case "$row" in
      *:*) type=${row%%:*}; status=${row#*:} ;;
      *) type=15; status=$row ;;
    esac
    sqlite3 "$path" "INSERT INTO steps (idx, step_type, status) VALUES ($idx, $type, $status);"
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

# agy's busy code is step-type dependent, so the fold reads the (step_type,
# status) PAIR: (15,8) is a running text step and (132,2) a running tool call,
# while status 3 is settled for EVERY step_type. Anything outside that
# measured set stays unknown rather than being guessed at.
test_run_state_reads_the_step_type_status_pair() {
  if ! command -v sqlite3 >/dev/null 2>&1; then
    pass "agy run state (step-type pairs): sqlite3 not installed in this environment, skipped"
    return 0
  fi
  local case_dir ws out
  case_dir="$TMP_ROOT/run-state-pairs"
  ws="$case_dir/workspace"
  mkdir -p "$case_dir" "$ws"

  make_conversation_db "$case_dir/text-busy.db" "$ws" 15:3 15:8 || fail "fixture a"
  make_conversation_db "$case_dir/tool-busy.db" "$ws" 15:3 132:2 || fail "fixture b"
  make_conversation_db "$case_dir/tool-settled.db" "$ws" 15:8 132:3 || fail "fixture c"
  make_conversation_db "$case_dir/other-settled.db" "$ws" 101:3 || fail "fixture d"
  make_conversation_db "$case_dir/text-two.db" "$ws" 132:3 15:2 || fail "fixture e"
  make_conversation_db "$case_dir/unknown-pair.db" "$ws" 15:3 21:8 || fail "fixture f"

  out=$(
    # shellcheck source=bin/fm-busy-lib.sh
    . "$ROOT/bin/fm-busy-lib.sh"
    printf 'text-busy=%s\n' "$(fm_busy_agy_run_state "$case_dir/text-busy.db" || echo unknown)"
    printf 'tool-busy=%s\n' "$(fm_busy_agy_run_state "$case_dir/tool-busy.db" || echo unknown)"
    printf 'tool-settled=%s\n' "$(fm_busy_agy_run_state "$case_dir/tool-settled.db" || echo unknown)"
    printf 'other-settled=%s\n' "$(fm_busy_agy_run_state "$case_dir/other-settled.db" || echo unknown)"
    printf 'text-two=%s\n' "$(fm_busy_agy_run_state "$case_dir/text-two.db" || echo unknown)"
    printf 'unknown-pair=%s\n' "$(fm_busy_agy_run_state "$case_dir/unknown-pair.db" || echo unknown)"
  )
  assert_contains "$out" "text-busy=busy" "a running text step (15,8) must be busy"
  assert_contains "$out" "tool-busy=busy" "a running tool call (132,2) must be busy"
  assert_contains "$out" "tool-settled=idle" "a settled tool call (132,3) must be idle"
  assert_contains "$out" "other-settled=idle" "status 3 must settle any step_type, including 101"
  assert_contains "$out" "text-two=unknown" "status 2 on a TEXT step is not a measured busy pair"
  assert_contains "$out" "unknown-pair=unknown" "an unmeasured (step_type, status) pair must not be guessed"
  pass "agy run state reads the (step_type, status) pair, not status alone"
}

# The length prefix alone is not proof of a protobuf field: a coincidental byte
# whose value equals the path length would accept an occurrence sitting in
# another task's captured tool output. A real length-delimited field carries a
# wire-type-2 tag byte before its varint, and that is required too.
test_binding_rejects_a_coincidental_length_byte() {
  local case_dir root state ws db out status len
  case_dir="$TMP_ROOT/binding-tagless"
  root="$case_dir/conversations"
  state="$case_dir/state"
  ws="$case_dir/wt"
  db="$root/cccccccc-cccc-cccc-cccc-cccccccccccc.db"
  mkdir -p "$root" "$state" "$ws"
  len=$(printf '%s' "$ws" | wc -c)
  len=$((len))
  [ "$len" -lt 128 ] || fail "fixture workspace path must fit a single-byte varint"
  {
    printf 'captured tool output: '
    printf 'A'
    printf "\\$(printf '%03o' "$len")"
    printf '%s and more\n' "$ws"
  } > "$db"
  grep -aqF -- "$ws" "$db" \
    || fail "fixture does not contain the workspace path as a raw substring"
  {
    printf 'conversations_root=%s\n' "$root"
    printf 'workspace_root=%s\n' "$ws"
  } > "$state/taskA.agy-session"
  out=$(
    # shellcheck source=bin/fm-busy-lib.sh
    . "$ROOT/bin/fm-busy-lib.sh"
    fm_busy_agy_conversation "$state" taskA
  )
  status=$?
  [ "$status" -ne 0 ] || fail "a coincidental length byte with no wire-type-2 tag was accepted: '$out'"

  # The same bytes with the preceding byte replaced by a real wire-type-2 tag
  # (0x12, low 3 bits = 2): the genuine encoding must still resolve.
  {
    printf 'captured tool output: '
    printf '\022'
    printf "\\$(printf '%03o' "$len")"
    printf '%s and more\n' "$ws"
  } > "$db"
  out=$(
    # shellcheck source=bin/fm-busy-lib.sh
    . "$ROOT/bin/fm-busy-lib.sh"
    fm_busy_agy_conversation "$state" taskA
  )
  [ "$out" = "$db" ] || fail "a genuine tag+varint framed path did not resolve, got '$out'"
  pass "agy binding requires a wire-type-2 tag, not just a matching length byte"
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

# --- live WAL binding ---------------------------------------------------
#
# SQLite in WAL mode keeps a running session's freshly written pages in the
# sibling `<uuid>.db-wal` until a checkpoint, so for the whole of an agy
# session's first turn the workspace bytes exist ONLY there. The fixtures
# below reproduce that state honestly: the schema is created and checkpointed
# first, then the workspace blob and step row are written through a
# connection that STAYS OPEN.

LIVE_PID=
LIVE_LOG=

# make_wal_conversation_db <path>: an agy-shaped conversation database in WAL
# journal mode, with no workspace blob written yet.
make_wal_conversation_db() {  # <path>
  sqlite3 "$1" "PRAGMA journal_mode=WAL;
    CREATE TABLE steps (idx integer, step_type integer, status integer, PRIMARY KEY (idx));
    CREATE TABLE workspace_marker (blob blob);" >/dev/null
}

# open_live_conversation <db> <workspace-root> <step-type> <status>: write the
# workspace blob and one step row through a connection left open, leaving
# those pages uncheckpointed in `<db>-wal`. Returns once sqlite3 has
# acknowledged the writes; close_live_conversation ends the session.
open_live_conversation() {
  local db=$1 ws=$2 type=$3 status=$4 scratch fifo i
  scratch=$(mktemp -d "$TMP_ROOT/live-writer.XXXXXX") || return 1
  fifo="$scratch/sql"
  LIVE_LOG="$scratch/out"
  mkfifo "$fifo" || return 1
  sqlite3 "$db" < "$fifo" > "$LIVE_LOG" 2>&1 &
  LIVE_PID=$!
  exec 9> "$fifo"
  {
    printf 'PRAGMA journal_mode=WAL;\n'
    printf 'PRAGMA wal_autocheckpoint=0;\n'
    printf "INSERT INTO workspace_marker (blob) VALUES (X'%s');\n" "$(agy_workspace_field_hex "$ws")"
    printf 'INSERT INTO steps (idx, step_type, status) VALUES ((SELECT count(*) FROM steps), %s, %s);\n' \
      "$type" "$status"
    printf "SELECT 'live-writer-ready';\n"
  } >&9
  i=0
  while [ "$i" -lt 200 ]; do
    grep -q live-writer-ready "$LIVE_LOG" 2>/dev/null && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

close_live_conversation() {
  exec 9>&-
  wait "$LIVE_PID" 2>/dev/null || true
  LIVE_PID=
}

# The first-turn blind spot: while the session is live its workspace bytes are
# in the -wal only, so a scan restricted to *.db resolves nothing and the whole
# first turn - the one that consumes a crewmate's brief - reports unknown. The
# fold itself is unaffected (sqlite3 reads through the WAL), so the resolver
# must find the conversation via the -wal and report the plain .db path.
test_busy_fold_resolves_a_conversation_still_writing_to_its_wal() {
  if ! command -v sqlite3 >/dev/null 2>&1; then
    pass "agy busy fold (live WAL): sqlite3 not installed in this environment, skipped"
    return 0
  fi
  local case_dir root state ws db in_db in_wal out folded
  case_dir="$TMP_ROOT/busy-live-wal"
  root="$case_dir/conversations"
  state="$case_dir/state"
  ws="$case_dir/workspace"
  mkdir -p "$root" "$state" "$ws"
  db="$root/cccccccc-cccc-cccc-cccc-cccccccccccc.db"
  make_wal_conversation_db "$db" || fail "could not build the sqlite3 fixture"
  {
    printf 'conversations_root=%s\n' "$root"
    printf 'workspace_root=%s\n' "$ws"
  } > "$state/taskwal.agy-session"
  open_live_conversation "$db" "$ws" 15 8 || fail "the live sqlite3 writer never acknowledged its writes"
  in_db=$(grep -acF -- "$ws" "$db" 2>/dev/null || true)
  in_wal=$(grep -acF -- "$ws" "$db-wal" 2>/dev/null || true)
  out=$(
    # shellcheck source=bin/fm-busy-lib.sh
    . "$ROOT/bin/fm-busy-lib.sh"
    resolved=$(fm_busy_agy_conversation "$state" taskwal) || exit 0
    printf '%s\n' "$resolved"
    fm_busy_agy_run_state "$resolved"
  )
  close_live_conversation
  [ "${in_db:-0}" -eq 0 ] \
    || fail "fixture does not reproduce a live session: the workspace bytes already reached the .db"
  [ "${in_wal:-0}" -gt 0 ] \
    || fail "fixture does not reproduce a live session: no workspace bytes in the -wal"
  folded=${out#*$'\n'}
  out=${out%%$'\n'*}
  [ "$out" = "$db" ] \
    || fail "a conversation whose workspace bytes are still in its -wal did not resolve to '$db', got '$out'"
  [ "$folded" = busy ] \
    || fail "the resolved path must be the readable .db, folding the running step to busy, got '$folded'"
  pass "agy busy fold resolves a live conversation whose workspace bytes are still in its -wal"
}

# Once a checkpoint has landed the workspace bytes are in BOTH files, and both
# name the same conversation. Counting them separately would push the
# candidate count to two and make the task permanently unresolvable - the
# ambiguity refusal firing on a single conversation.
test_busy_fold_counts_a_db_and_wal_match_as_one_conversation() {
  if ! command -v sqlite3 >/dev/null 2>&1; then
    pass "agy busy fold (db+wal dedupe): sqlite3 not installed in this environment, skipped"
    return 0
  fi
  local case_dir root state ws db in_db in_wal out
  case_dir="$TMP_ROOT/busy-db-and-wal"
  root="$case_dir/conversations"
  state="$case_dir/state"
  ws="$case_dir/workspace"
  mkdir -p "$root" "$state" "$ws"
  db="$root/dddddddd-dddd-dddd-dddd-dddddddddddd.db"
  make_wal_conversation_db "$db" || fail "could not build the sqlite3 fixture"
  # a first turn, checkpointed into the .db when its connection closed
  sqlite3 "$db" "INSERT INTO workspace_marker (blob) VALUES (X'$(agy_workspace_field_hex "$ws")');
    INSERT INTO steps (idx, step_type, status) VALUES (0, 15, 3);" >/dev/null
  {
    printf 'conversations_root=%s\n' "$root"
    printf 'workspace_root=%s\n' "$ws"
  } > "$state/taskboth.agy-session"
  # a second turn still in flight, its pages only in the -wal
  open_live_conversation "$db" "$ws" 132 2 || fail "the live sqlite3 writer never acknowledged its writes"
  in_db=$(grep -acF -- "$ws" "$db" 2>/dev/null || true)
  in_wal=$(grep -acF -- "$ws" "$db-wal" 2>/dev/null || true)
  out=$(
    # shellcheck source=bin/fm-busy-lib.sh
    . "$ROOT/bin/fm-busy-lib.sh"
    fm_busy_agy_conversation "$state" taskboth
  )
  close_live_conversation
  [ "${in_db:-0}" -gt 0 ] && [ "${in_wal:-0}" -gt 0 ] \
    || fail "fixture does not reproduce the overlap: .db=$in_db -wal=$in_wal occurrences"
  [ "$out" = "$db" ] \
    || fail "one conversation matching in both its .db and its -wal must resolve once, got '$out'"
  pass "agy busy fold counts a conversation matching in both its .db and its -wal only once"
}

# Prior-conversation exclusion is keyed on the .db basename the spawn-time
# snapshot recorded. A predecessor that is live again - matching only through
# its -wal - is still the same conversation and must stay excluded, or a
# relaunch into a reused worktree would fold its predecessor's state.
test_busy_fold_excludes_a_prior_conversation_matching_only_in_its_wal() {
  if ! command -v sqlite3 >/dev/null 2>&1; then
    pass "agy busy fold (prior via -wal): sqlite3 not installed in this environment, skipped"
    return 0
  fi
  local case_dir root state ws prior_db new_db in_db out
  case_dir="$TMP_ROOT/busy-prior-wal"
  root="$case_dir/conversations"
  state="$case_dir/state"
  ws="$case_dir/workspace"
  mkdir -p "$root" "$state" "$ws"
  prior_db="$root/eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee.db"
  new_db="$root/ffffffff-ffff-ffff-ffff-ffffffffffff.db"
  make_wal_conversation_db "$prior_db" || fail "could not build the prior sqlite3 fixture"
  make_conversation_db "$new_db" "$ws" 8 || fail "could not build the new sqlite3 fixture"
  {
    printf 'conversations_root=%s\n' "$root"
    printf 'workspace_root=%s\n' "$ws"
    printf 'prior_conversation=%s\n' "$(basename -- "$prior_db")"
  } > "$state/taskpw.agy-session"
  open_live_conversation "$prior_db" "$ws" 15 8 || fail "the live sqlite3 writer never acknowledged its writes"
  in_db=$(grep -acF -- "$ws" "$prior_db" 2>/dev/null || true)
  out=$(
    # shellcheck source=bin/fm-busy-lib.sh
    . "$ROOT/bin/fm-busy-lib.sh"
    fm_busy_agy_conversation "$state" taskpw
  )
  close_live_conversation
  [ "${in_db:-0}" -eq 0 ] \
    || fail "fixture does not reproduce a live predecessor: its bytes already reached the .db"
  [ "$out" = "$new_db" ] \
    || fail "expected this task's own conversation '$new_db', resolved '$out'"
  pass "agy busy fold keeps excluding a prior conversation that now matches only through its -wal"
}

# --- launch mechanics (bin/fm-spawn.sh) ---------------------------------

# The spawn cases below drive the real bin/fm-spawn.sh against a fake tmux that
# records the launch command line it is asked to type into the pane. That line
# IS the adapter's launch contract - the exact string a crewmate's shell runs -
# so asserting on it exercises the emitted interface rather than the source.

make_agy_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  send-keys)
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then
        printf '%s\n' "$arg" >> "$FM_FAKE_LAUNCH_LOG"
        break
      fi
      prev=$arg
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

run_agy_spawn() {  # <case-name> <id> [extra spawn args...]
  local name=$1 id=$2 case_dir home proj wt fakebin
  shift 2
  case_dir="$TMP_ROOT/spawn-$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_agy_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$home/launch.log" \
    AGY_CONVERSATIONS_ROOT_OVERRIDE="$case_dir/conversations" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --harness agy "$@" 2>&1
}

# agy rejects a bare positional prompt (verified live, agy 1.1.28/1.2.0), so the
# brief has to reach it through -i. A launch that lost the -i would start an
# empty interactive session and silently drop the crewmate's whole brief.
test_spawn_launch_delivers_the_brief_through_dash_i() {
  local out status launch log
  log="$TMP_ROOT/spawn-launch/home/launch.log"
  out=$(run_agy_spawn launch agy-launch-x1 --mode no-mistakes --yolo off \
    --model gemini-3.7-flash --effort high)
  status=$?
  expect_code 0 "$status" "agy crewmate spawn should succeed: $out"
  launch=$(cat "$log")
  assert_contains "$launch" ' -i "' "agy launch must deliver the brief through -i, not a bare positional"
  assert_contains "$launch" '--dangerously-skip-permissions' \
    "agy launch must carry its documented autonomy flag"
  assert_contains "$launch" "--model 'gemini-3.7-flash'" "agy launch must map --model"
  assert_contains "$launch" "--effort 'high'" "agy launch must map --effort"
  assert_contains "$launch" 'env -u CLAUDECODE' \
    "agy launch must clear the foreign primary markers it does not clear itself"
  pass "agy crewmate launch delivers the brief via -i with its autonomy, model and effort flags"
}

# agy's own --help documents only low|medium|high. A captain asking for xhigh
# must not have that value passed through to a CLI that rejects it - the axis is
# omitted from the launch instead, leaving agy on its own default.
test_spawn_omits_an_effort_agy_does_not_support() {
  local out status launch log
  log="$TMP_ROOT/spawn-effort/home/launch.log"
  out=$(run_agy_spawn effort agy-effort-x1 --mode no-mistakes --yolo off --effort xhigh)
  status=$?
  expect_code 0 "$status" "agy crewmate spawn with xhigh should still launch: $out"
  launch=$(cat "$log")
  assert_not_contains "$launch" '--effort' \
    "agy launch must omit an effort level its CLI rejects rather than passing it through"
  assert_contains "$launch" ' -i "' "agy launch must still deliver the brief"
  pass "agy launch omits xhigh rather than passing a level its CLI rejects"
}

# agy has no hook, plugin lifecycle, notify flag, or app-server surface to build
# a primary supervision protocol on, so fm-spawn refuses the kind outright
# rather than launching a secondmate that could never be supervised.
test_spawn_refuses_secondmate() {
  local case_dir home fakebin id out status
  case_dir="$TMP_ROOT/spawn-secondmate"
  home="$case_dir/home"
  fakebin=$(make_agy_spawn_fakebin "$case_dir/fake")
  id="agy-secondmate-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'charter\n' > "$home/data/$id/brief.md"
  out=$(cd "$case_dir" && FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_LAUNCH_LOG="$home/launch.log" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" --harness agy --secondmate 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "agy was accepted as a secondmate harness"
  assert_contains "$out" "crewmate/scout adapter only" \
    "agy secondmate refusal did not explain the boundary"
  assert_absent "$home/launch.log" "a refused agy secondmate spawn must launch nothing"
  pass "agy is refused as a secondmate harness"
}

test_env_marker_wins_over_inherited_claude_markers
test_no_marker_falls_back_to_claude
test_detects_agy_process_ancestor
test_control_lib_tables
test_control_lib_wiring_paths
test_agy_trusts_no_record_source
test_busy_fold_resolves_and_reads_status
test_busy_fold_settled_reads_idle
test_busy_fold_resolves_a_conversation_still_writing_to_its_wal
test_busy_fold_counts_a_db_and_wal_match_as_one_conversation
test_busy_fold_excludes_a_prior_conversation_matching_only_in_its_wal
test_busy_fold_excludes_prior_conversation
test_busy_fold_ignores_sibling_slot_path_prefix
test_busy_fold_resolves_across_an_alphanumeric_successor_byte
test_busy_fold_decodes_a_multibyte_length_prefix
test_binding_rejects_a_coincidental_length_byte
test_run_state_reads_the_step_type_status_pair
test_busy_fold_ambiguous_resolution_fails
test_busy_classify_reports_the_agy_conversation_source
test_spawn_launch_delivers_the_brief_through_dash_i
test_spawn_omits_an_effort_agy_does_not_support
test_spawn_refuses_secondmate
