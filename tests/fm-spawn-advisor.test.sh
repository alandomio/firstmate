#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's opt-in per-turn advisor dispatch-profile
# axis (docs/configuration.md "Crew dispatch profiles"; bin/fm-advisor-hook.sh).
#
# These tests drive fm-spawn through meta writing and the written Claude hooks
# JSON with a fake tmux pane and a real isolated git worktree, exactly like
# tests/fm-spawn-dispatch-profile.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-advisor)

make_advisor_fakebin() {
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
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_advisor_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

make_seeded_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$launchlog" \
    GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

run_ship_spawn() {
  run_spawn "$@" --mode no-mistakes --yolo off
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

hooks_json() {
  cat "$1/wt/.claude/settings.local.json"
}

# The written hooks JSON is fm-spawn's owned contract with Claude Code; these
# read it structurally rather than by substring.
stop_hook_command() {  # <json> <stop-entry-index> -> that entry's single command string
  printf '%s' "$1" | jq -r --argjson i "$2" '.hooks.Stop[$i].hooks[0].command'
}

stop_hook_commands() {  # <json> -> every Stop command, one per line
  printf '%s' "$1" | jq -r '.hooks.Stop[].hooks[].command'
}

test_no_advisor_produces_byte_identical_hooks_and_meta() {
  local rec id out status hooks
  id=advisor-off-z1
  rec=$(make_spawn_case advisor-off claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn without --advisor should succeed"
  assert_not_contains "$(cat "$HOME_DIR/state/$id.meta")" "advisor=" \
    "meta must carry no advisor= line when no profile carries the axis"
  hooks=$(hooks_json "$CASE_DIR")
  [ "$(printf '%s' "$hooks" | jq '.hooks.Stop | length')" = 1 ] \
    || fail "default spawn must install exactly one Stop hook entry, got: $hooks"
  assert_not_contains "$(stop_hook_commands "$hooks")" "fm-advisor-hook.sh" "default spawn must not install the advisor hook"
  pass "no --advisor produces byte-identical meta and a single-entry Stop hook"
}

test_advisor_records_meta_and_composes_stop_hook() {
  local rec id out status meta hooks advisor_cmd state_real
  id=advisor-on-z2
  rec=$(make_spawn_case advisor-on claude "$id")
  read_case_record "$rec"
  mkdir -p "$HOME_DIR/state"
  state_real=$(cd "$HOME_DIR/state" && pwd -P)

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --advisor claude-opus-5:low)
  status=$?
  expect_code 0 "$status" "claude spawn with --advisor should succeed"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep "advisor=claude-opus-5:low" "$meta" "meta did not record the advisor axis"

  hooks=$(hooks_json "$CASE_DIR")
  [ "$(printf '%s' "$hooks" | jq '.hooks.Stop | length')" = 2 ] \
    || fail "advisor spawn must install exactly two Stop hook entries, got: $hooks"
  [ "$(printf '%s' "$hooks" | jq -c '[.hooks.Stop[].hooks | length] | unique')" = "[1]" ] \
    || fail "each Stop hook entry must carry exactly one command, got: $hooks"
  assert_contains "$(stop_hook_command "$hooks" 0)" 'fm-busy-event.sh' "advisor spawn must keep the existing turn-end busy hook first"
  advisor_cmd=$(stop_hook_command "$hooks" 1)
  assert_contains "$advisor_cmd" "/bin/fm-advisor-hook.sh" "second Stop entry must run the advisor hook"
  assert_not_contains "$advisor_cmd" 'fm-busy-event.sh' "advisor entry must not also run the turn-end hook"
  assert_contains "$advisor_cmd" "FM_ADVISOR_MODEL='claude-opus-5' " "advisor hook command did not carry the resolved model"
  assert_contains "$advisor_cmd" "FM_ADVISOR_EFFORT='low' " "advisor hook command did not carry the resolved effort"
  assert_contains "$advisor_cmd" "FM_ADVISOR_COUNTER='$state_real/$id.advisor-count' " "advisor counter path is not the per-task state file"
  assert_contains "$advisor_cmd" "FM_ADVISOR_LOG='$HOME_DIR/data/$id/advisor-log.jsonl' " "advisor log path is not under the task's data directory"
  assert_contains "$advisor_cmd" "FM_ADVISOR_BRIEF='$HOME_DIR/data/$id/brief.md' " "advisor brief path is not the task's own brief"
  pass "advisor axis records meta and composes an additional Stop hook entry alongside the turn-end hook"
}

test_advisor_without_effort_omits_effort_env() {
  local rec id out status hooks advisor_cmd
  id=advisor-noeffort-z3
  rec=$(make_spawn_case advisor-noeffort claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --advisor claude-opus-5)
  status=$?
  expect_code 0 "$status" "claude spawn with --advisor and no effort should succeed"
  assert_grep "advisor=claude-opus-5" "$HOME_DIR/state/$id.meta" "meta did not record the effort-less advisor axis"
  assert_not_contains "$(cat "$HOME_DIR/state/$id.meta")" "advisor=claude-opus-5:" \
    "meta must not record a colon-suffixed effort when none was given"
  hooks=$(hooks_json "$CASE_DIR")
  advisor_cmd=$(stop_hook_command "$hooks" 1)
  assert_contains "$advisor_cmd" "FM_ADVISOR_MODEL='claude-opus-5' " "advisor hook command did not carry the resolved model"
  assert_not_contains "$advisor_cmd" 'FM_ADVISOR_EFFORT=' "advisor hook command must omit FM_ADVISOR_EFFORT when no effort was given"
  pass "advisor without an effort omits FM_ADVISOR_EFFORT from the installed hook command"
}

test_advisor_refused_for_non_claude_harness() {
  local rec id out status
  id=advisor-codex-z4
  rec=$(make_spawn_case advisor-codex codex "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --advisor claude-opus-5)
  status=$?
  expect_code 1 "$status" "--advisor on a non-claude harness should refuse"
  assert_contains "$out" "--advisor is only supported for the claude harness" \
    "refusal did not name the claude-only restriction"
  assert_absent "$HOME_DIR/state/$id.meta" "advisor harness refusal wrote task metadata"
  pass "--advisor is refused for a non-claude harness before any metadata is written"
}

test_advisor_refused_for_secondmate() {
  local rec id sm out status
  id=advisor-secondmate-z5
  rec=$(make_spawn_case advisor-secondmate claude "$id")
  read_case_record "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate --advisor claude-opus-5)
  status=$?
  expect_code 1 "$status" "--advisor on a --secondmate spawn should refuse"
  assert_contains "$out" "--advisor is not supported for --secondmate spawns" \
    "refusal did not name the secondmate restriction"
  assert_absent "$HOME_DIR/state/$id.meta" "advisor secondmate refusal wrote task metadata"
  pass "--advisor is refused for --secondmate spawns before any metadata is written"
}

test_advisor_refused_for_malformed_shapes() {
  local rec id out status
  id=advisor-malformed-z6
  rec=$(make_spawn_case advisor-malformed claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --advisor :low)
  status=$?
  expect_code 1 "$status" "--advisor with an empty model should refuse"
  assert_contains "$out" "requires a non-empty model" "empty-model refusal did not name the requirement"
  assert_absent "$HOME_DIR/state/$id.meta" "malformed advisor refusal wrote task metadata"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --advisor claude-opus-5:ultra)
  status=$?
  expect_code 1 "$status" "--advisor with an unsupported effort should refuse"
  assert_contains "$out" "--advisor effort must be one of low, medium, high, xhigh, max" \
    "invalid effort refusal did not name the accepted set"
  assert_absent "$HOME_DIR/state/$id.meta" "invalid advisor effort refusal wrote task metadata"
  pass "--advisor refuses an empty model or an unsupported effort before any metadata is written"
}

test_batch_forwards_advisor_to_every_pair() {
  local rec id1 id2 out status
  id1=advisor-batch-a-z7
  id2=advisor-batch-b-z8
  rec=$(make_spawn_case advisor-batch claude "$id1" "$id2")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id1=$PROJ_DIR" "$id2=$PROJ_DIR" --advisor claude-opus-5:low)
  status=$?
  expect_code 0 "$status" "batch spawn with shared --advisor should succeed"
  assert_grep "advisor=claude-opus-5:low" "$HOME_DIR/state/$id1.meta" "first batch task did not record the shared advisor"
  assert_grep "advisor=claude-opus-5:low" "$HOME_DIR/state/$id2.meta" "second batch task did not record the shared advisor"
  pass "batch dispatch forwards shared --advisor to every pair"
}

test_no_advisor_produces_byte_identical_hooks_and_meta
test_advisor_records_meta_and_composes_stop_hook
test_advisor_without_effort_omits_effort_env
test_advisor_refused_for_non_claude_harness
test_advisor_refused_for_secondmate
test_advisor_refused_for_malformed_shapes
test_batch_forwards_advisor_to_every_pair

echo "# all fm-spawn-advisor tests passed"
