#!/usr/bin/env bash
# Behavior tests for bin/fm-bearings-board.sh: fail-closed payload validation,
# slot-injection round-trip through the built page, bind-before-arm, and
# idempotent re-arm of the stable board source.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-bearings-board.sh"
TMP_ROOT=$(fm_test_tmproot fm-bearings-board)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/state" "$home/data"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" lavish-axi
  printf '%s\n' "$home"
}

run_board() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" "$@"
}

run_procevent() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" "$@"
}

run_decisions() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-decision-hold.sh" "$@"
}

# A realistic payload: a cross-origin full-identity decision key past the old
# 64-char cap, a merge card, a dispatchable charted row, and a string that
# tries to terminate the data block early.
write_valid_payload() {  # <path>
  cat > "$1" <<'EOF'
{
  "schema": "fm-bearings-board.v1",
  "home": "test-home",
  "generated": "2026-08-19T00:00Z",
  "prs_live": false,
  "captains_call": [
    {
      "key": "sample-instruction-layer-refinement-review-decision-perishable-first-admission-choice",
      "type": "decision",
      "repo": "sample",
      "title": "Perishable-first admission",
      "about": "A payload string that tries to break out: </script><b>x</b>",
      "decide": "Adopt it?",
      "options": [
        { "value": "yes", "label": "Adopt", "hint": "recommended" },
        { "value": "no", "label": "Keep current" }
      ],
      "allow_freeform": true
    },
    {
      "key": "merge.sample-task",
      "type": "merge",
      "repo": "sample",
      "title": "Merge: sample change",
      "detail": "validation green",
      "task_id": "sample-task",
      "pr_url": "https://github.com/example/sample/pull/1",
      "checks": "green",
      "risk": "low",
      "options": [
        { "value": "merge", "label": "Merge now" },
        { "value": "hold", "label": "Not yet" }
      ],
      "allow_freeform": true
    }
  ],
  "underway": [],
  "landed": [],
  "charted": [
    { "id": "sample-queued", "repo": "sample", "title": "Queued work", "reason": "", "dispatchable": true }
  ],
  "charted_more": 0
}
EOF
}

# Extract the injected payload back out of a built board page.
extract_payload() {  # <board-path>
  sed -n '/<script id="bearings-data" type="application\/json">/,/<\/script>/p' "$1" \
    | sed '1d;$d'
}

test_path_is_stable_and_home_scoped() {
  local home
  home=$(make_home path)
  [ "$(run_board "$home" path)" = "$home/.lavish/bearings-board.html" ] \
    || fail "the board path is not the stable home-scoped location"
  pass "path prints the stable home-scoped board location"
}

test_build_refuses_malformed_payloads_before_touching_the_board() {
  local home data board rc out
  home=$(make_home refusal)
  board="$home/.lavish/bearings-board.html"
  data="$home/payload.json"

  printf 'not json\n' > "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-JSON payload was accepted"
  assert_contains "$out" "not valid JSON" "the non-JSON refusal did not say why: $out"

  printf '{"schema":"fm-bearings-board.v2"}\n' > "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a wrong-schema payload was accepted"
  assert_contains "$out" "fm-bearings-board.v1" "the schema refusal did not name the contract: $out"

  write_valid_payload "$data"
  jq '.captains_call[0].key = (reduce range(129) as $i (""; . + "x"))' "$data" > "$data.tmp" \
    && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a 129-char captains_call key was accepted"

  write_valid_payload "$data"
  jq 'del(.charted[0].dispatchable)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a charted row without a dispatchable boolean was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].type = "verdict"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an unknown captains_call type was accepted"

  write_valid_payload "$data"
  jq 'del(.captains_call[0].options[0].value)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a captains_call option without an answer value was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].options[0].label = ""' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a captains_call option with an empty label was accepted"

  write_valid_payload "$data"
  jq 'del(.charted[0].repo)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a fleet row without an explicit repo marker was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].allow_freeform = "yes"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-boolean renderer field was accepted"

  write_valid_payload "$data"
  jq 'del(.captains_call[0].allow_freeform)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a captains_call item with no allow_freeform was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].allow_freeform = false' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a captains_call item with allow_freeform false was accepted"

  write_valid_payload "$data"
  jq '.captains_call[1].pr_url = "javascript:alert(1)"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-HTTPS Captain’s Call PR URL was accepted"

  write_valid_payload "$data"
  jq '.landed = [{
    "id": "sample-landed",
    "repo": "sample",
    "what": "Landed work",
    "owner": "firstmate",
    "pr_url": "data:text/html,unsafe"
  }]' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-HTTPS Landed PR URL was accepted"

  assert_absent "$board" "a refused payload still produced a board"
  pass "build refuses malformed payloads before touching the board"
}

test_build_injects_binds_then_arms() {
  local home data board out sid
  home=$(make_home build)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"

  out=$(run_board "$home" build "$data") || fail "a valid payload did not build"
  assert_contains "$out" "board: $board" "build did not report the board path: $out"
  assert_contains "$out" "served: $board" "build did not establish the Lavish session: $out"
  assert_contains "$out" "bound: " "build did not report the answer binding: $out"
  assert_contains "$out" "armed: " "the first build did not arm the board source: $out"
  assert_present "$board" "build reported success without a board"

  # Round-trip: the payload extracted from the built page is byte-for-byte the
  # same JSON document, and the escaped </script> string can no longer
  # terminate the data block.
  extract_payload "$board" | jq -S . > "$home/extracted.json" \
    || fail "the built board does not carry parseable payload JSON"
  jq -S . "$data" > "$home/expected.json"
  diff -u "$home/expected.json" "$home/extracted.json" >/dev/null \
    || fail "the injected payload does not round-trip to the input document"
  grep -qF '</script><b>' "$board" \
    && fail "a payload string embedded a live closing script tag in the page"
  grep -qxF '__FM_BEARINGS_BOARD_DATA__' "$board" \
    && fail "the data slot survived injection"

  sid=$(run_lavish_source_id "$home" "$board")
  assert_contains "$out" "bound: $sid" "the binding does not name the board source: $out"
  [ "$(run_decisions "$home" binding "$sid")" = "(any)" ] \
    || fail "the board source is not bound any-origin"
  run_procevent "$home" list | awk 'NR > 1 { print $1 }' | grep -Fxq "$sid" \
    || fail "the board source is not registered after build"
  pass "build injects the payload, binds any-origin, then arms the source"
}

test_registration_cannot_consume_before_any_origin_binding() {
  local home data runtime origin key hold board sid show
  home=$(make_home order-proof)
  data="$home/payload.json"
  runtime="$home/runtime"
  origin=order-proof-review
  key=captain-choice
  hold="$origin-decision-$key"
  board="$home/.lavish/bearings-board.html"

  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fm_write_meta "$home/state/$origin.meta" "project=$home/projects/sample" "kind=scout"
  run_decisions "$home" hold "$origin" "$key" \
    --title "Choose the order proof" --reason "captain choice pending" --repo sample >/dev/null \
    || fail "could not create the order-proof captain hold"

  write_valid_payload "$data"
  jq --arg hold "$hold" '.captains_call[0].key = $hold' "$data" > "$data.tmp" \
    && mv "$data.tmp" "$data"

  mkdir -p "$runtime"
  cp -R "$ROOT/bin" "$runtime/bin"
  cat > "$runtime/bin/fm-procevent-lavish.sh" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = arm ]; then
  artifact=${2:-}
  "$REAL_LAVISH_ADAPTER" arm "$artifact" >/dev/null
  sid=$("$REAL_LAVISH_ADAPTER" source-id "$artifact")
  "$REAL_PROCEVENT" start "$sid" >/dev/null
  exit 0
fi
exec "$REAL_LAVISH_ADAPTER" "$@"
SH
  chmod +x "$runtime/bin/fm-procevent-lavish.sh"
  cat > "$home/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" != poll ]; then
  exit 0
fi
cat <<EOF
session:
  status: feedback
  session_ended: false
prompts[1]{uid,prompt,selector,tag,text}:
  "2","Order proof: yes\\n\\nContext data:\\n{\\n  \\"question\\": \\"$ORDER_PROOF_HOLD\\",\\n  \\"answer\\": \\"yes\\"\\n}","form",choice,"Order proof: yes"
EOF
SH
  chmod +x "$home/fakebin/lavish-axi"

  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$runtime" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    FM_BEARINGS_BOARD_TEMPLATE="$ROOT/.agents/skills/bearings/assets/board-template.html" \
    REAL_LAVISH_ADAPTER="$ROOT/bin/fm-procevent-lavish.sh" \
    REAL_PROCEVENT="$ROOT/bin/fm-procevent.sh" ORDER_PROOF_HOLD="$hold" \
    "$runtime/bin/fm-bearings-board.sh" build "$data" >/dev/null \
    || fail "the order-proof board build failed"

  show=$(cd "$home" && tasks-axi show "$hold" --full) \
    || fail "the order-proof captain hold disappeared"
  assert_contains "$show" "state: done" \
    "registration consumed its answer before the any-origin binding existed"
  assert_contains "$show" "Resolution mode: answered" \
    "the answer was not closed through the real keyed-answer intake"
  sid=$(run_lavish_source_id "$home" "$board")
  [ "$(run_decisions "$home" binding "$sid")" = "(any)" ] \
    || fail "the order-proof source did not retain its any-origin binding"
  pass "registration can consume answers only after any-origin binding exists"
}

test_build_does_not_bind_or_arm_when_session_start_fails() {
  local home data rc sid
  home=$(make_home serve-failure)
  data="$home/payload.json"
  write_valid_payload "$data"
  cat > "$home/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$home/fakebin/lavish-axi"

  set +e
  run_board "$home" build "$data" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "build continued after Lavish session establishment failed"
  sid=$(run_lavish_source_id "$home" "$home/.lavish/bearings-board.html")
  ! run_decisions "$home" binding "$sid" >/dev/null 2>&1 \
    || fail "build bound the board before its Lavish session existed"
  ! run_procevent "$home" list | awk 'NR > 1 { print $1 }' | grep -Fxq "$sid" \
    || fail "build armed the board before its Lavish session existed"
  pass "build establishes the Lavish session before binding and arming"
}

run_lavish_source_id() {  # <home> <artifact>
  local home=$1
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent-lavish.sh" source-id "$2"
}

test_rebuild_is_idempotent_and_does_not_double_arm() {
  local home data board out records
  home=$(make_home rearm)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  run_board "$home" build "$data" >/dev/null || fail "the first build failed"

  jq '.generated = "2026-08-19T01:00Z"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  out=$(run_board "$home" build "$data") || fail "the rebuild failed"
  assert_contains "$out" "already-armed: " "the rebuild re-armed an already registered source: $out"
  extract_payload "$board" | jq -e '.generated == "2026-08-19T01:00Z"' >/dev/null \
    || fail "the rebuild did not refresh the board payload in place"
  records=$(find "$home/state/procevent" -name '*.source' | wc -l | tr -d ' ')
  [ "$records" = 1 ] || fail "rebuilding left $records source registrations instead of 1"
  pass "rebuild refreshes the board in place without double-arming"
}

extract_runtime_script() {  # <template-path> <out-file>
  # The template carries exactly two <script> blocks: the id="bearings-data"
  # JSON payload slot, and the unlabeled runtime script this pulls out.
  awk '/^<script>$/ { flag = 1; next } /^<\/script>$/ { if (flag) exit } flag' "$1" > "$2"
}

write_dom_decision_payload() {  # <path>
  cat > "$1" <<'EOF'
{
  "schema": "fm-bearings-board.v1",
  "home": "dom-test",
  "generated": "2026-09-11T00:00Z",
  "prs_live": false,
  "captains_call": [
    {
      "key": "dom-harness-decision",
      "type": "decision",
      "repo": "sample",
      "title": "Pick one",
      "options": [
        { "value": "yes", "label": "Yes" },
        { "value": "no", "label": "No" }
      ],
      "allow_freeform": true
    }
  ],
  "underway": [],
  "landed": [],
  "charted": [],
  "charted_more": 0
}
EOF
}

# The shape the freeform rule unlocks: no options at all, answerable only
# through the response box every card must carry.
write_dom_freeform_only_payload() {  # <path>
  cat > "$1" <<'EOF'
{
  "schema": "fm-bearings-board.v1",
  "home": "dom-test",
  "generated": "2026-09-11T00:00Z",
  "prs_live": false,
  "captains_call": [
    {
      "key": "dom-harness-freeform-only",
      "type": "decision",
      "repo": "sample",
      "title": "Say it in your own words",
      "options": [],
      "allow_freeform": true,
      "freeform_hint": "your orders, captain"
    }
  ],
  "underway": [],
  "landed": [],
  "charted": [],
  "charted_more": 0
}
EOF
}

write_dom_dispatch_payload() {  # <path>
  cat > "$1" <<'EOF'
{
  "schema": "fm-bearings-board.v1",
  "home": "dom-test",
  "generated": "2026-09-11T00:00Z",
  "prs_live": false,
  "captains_call": [],
  "underway": [],
  "landed": [],
  "charted": [
    { "id": "dom-harness-charted", "repo": "sample", "title": "Queued work", "reason": "", "dispatchable": true }
  ],
  "charted_more": 0
}
EOF
}

# A lost Lavish bridge (window.lavish or window.lavish.queuePrompt absent)
# must never let the UI claim an answer was queued: these run the template's
# REAL runtime script, extracted verbatim, inside a minimal DOM shim
# (fm-bearings-board-dom-harness.js) so the assertions exercise actual
# behavior rather than the source text.
test_decision_card_refuses_to_queue_without_a_lavish_bridge() {
  command -v node >/dev/null 2>&1 || { echo "skip: node not found (DOM harness)"; return 0; }
  local runtime data out
  runtime="$TMP_ROOT/decision-runtime.js"
  data="$TMP_ROOT/decision-payload.json"
  extract_runtime_script "$ROOT/.agents/skills/bearings/assets/board-template.html" "$runtime"
  write_dom_decision_payload "$data"

  out=$(node "$ROOT/tests/fm-bearings-board-dom-harness.js" "$runtime" "$data" 0 decision 2>&1) \
    || fail "the DOM harness crashed without a Lavish bridge: $out"
  [ "$(printf '%s' "$out" | jq -r .isQueued)" = "false" ] \
    || fail "a decision card was marked queued with no Lavish bridge present: $out"
  [ "$(printf '%s' "$out" | jq -r .errorVisible)" = "true" ] \
    || fail "no error was surfaced when the Lavish bridge was missing: $out"
  [ "$(printf '%s' "$out" | jq -r .queueCalls)" = "0" ] \
    || fail "queuePrompt was somehow invoked with no bridge present: $out"

  out=$(node "$ROOT/tests/fm-bearings-board-dom-harness.js" "$runtime" "$data" 1 decision 2>&1) \
    || fail "the DOM harness crashed with a Lavish bridge present: $out"
  [ "$(printf '%s' "$out" | jq -r .isQueued)" = "true" ] \
    || fail "a decision card was not marked queued despite a working Lavish bridge: $out"
  [ "$(printf '%s' "$out" | jq -r .errorVisible)" = "false" ] \
    || fail "an error was left visible on the card despite a working Lavish bridge: $out"
  [ "$(printf '%s' "$out" | jq -r .queueCalls)" = "1" ] \
    || fail "queuePrompt was not invoked despite a working Lavish bridge: $out"
  pass "a decision card refuses to queue and surfaces an error without a Lavish bridge"
}

test_dispatch_bar_refuses_to_queue_without_a_lavish_bridge() {
  command -v node >/dev/null 2>&1 || { echo "skip: node not found (DOM harness)"; return 0; }
  local runtime data out
  runtime="$TMP_ROOT/dispatch-runtime.js"
  data="$TMP_ROOT/dispatch-payload.json"
  extract_runtime_script "$ROOT/.agents/skills/bearings/assets/board-template.html" "$runtime"
  write_dom_dispatch_payload "$data"

  out=$(node "$ROOT/tests/fm-bearings-board-dom-harness.js" "$runtime" "$data" 0 dispatch 2>&1) \
    || fail "the DOM harness crashed without a Lavish bridge: $out"
  [ "$(printf '%s' "$out" | jq -r .isQueued)" = "false" ] \
    || fail "the dispatch bar was marked queued with no Lavish bridge present: $out"
  [ "$(printf '%s' "$out" | jq -r .errorVisible)" = "true" ] \
    || fail "no error was surfaced when the Lavish bridge was missing: $out"
  [ "$(printf '%s' "$out" | jq -r .queueCalls)" = "0" ] \
    || fail "queuePrompt was somehow invoked with no bridge present: $out"

  out=$(node "$ROOT/tests/fm-bearings-board-dom-harness.js" "$runtime" "$data" 1 dispatch 2>&1) \
    || fail "the DOM harness crashed with a Lavish bridge present: $out"
  [ "$(printf '%s' "$out" | jq -r .isQueued)" = "true" ] \
    || fail "the dispatch bar was not marked queued despite a working Lavish bridge: $out"
  [ "$(printf '%s' "$out" | jq -r .errorVisible)" = "false" ] \
    || fail "an error was surfaced despite a working Lavish bridge: $out"
  [ "$(printf '%s' "$out" | jq -r .queueCalls)" = "1" ] \
    || fail "queuePrompt was not invoked despite a working Lavish bridge: $out"
  pass "the dispatch bar refuses to queue and surfaces an error without a Lavish bridge"
}

# A bridge that comes back mid-session must leave the bar telling one story:
# the earlier refusal cannot outlive the dispatch that then really queued.
test_dispatch_bar_clears_a_stale_refusal_once_the_bridge_returns() {
  command -v node >/dev/null 2>&1 || { echo "skip: node not found (DOM harness)"; return 0; }
  local runtime data out
  runtime="$TMP_ROOT/dispatch-runtime.js"
  data="$TMP_ROOT/dispatch-payload.json"
  extract_runtime_script "$ROOT/.agents/skills/bearings/assets/board-template.html" "$runtime"
  write_dom_dispatch_payload "$data"

  out=$(node "$ROOT/tests/fm-bearings-board-dom-harness.js" "$runtime" "$data" 0 dispatch-regained 2>&1) \
    || fail "the DOM harness crashed when the bridge returned mid-session: $out"
  [ "$(printf '%s' "$out" | jq -r .queueCalls)" = "1" ] \
    || fail "the retried dispatch did not reach queuePrompt once the bridge returned: $out"
  [ "$(printf '%s' "$out" | jq -r .isQueued)" = "true" ] \
    || fail "the dispatch bar was not marked queued once the bridge returned: $out"
  [ "$(printf '%s' "$out" | jq -r .errorVisible)" = "false" ] \
    || fail "the dispatch bar still showed the earlier refusal beside its queued mark: $out"
  pass "the dispatch bar drops a stale refusal once the bridge returns"
}

# The card's own mirror case: an answer the bridge refused cannot leave the
# card - or the deal count in the stack header - claiming an earlier one.
test_decision_card_drops_its_queued_mark_when_a_later_answer_is_refused() {
  command -v node >/dev/null 2>&1 || { echo "skip: node not found (DOM harness)"; return 0; }
  local runtime data out unanswered_stack
  runtime="$TMP_ROOT/decision-runtime.js"
  data="$TMP_ROOT/decision-payload.json"
  extract_runtime_script "$ROOT/.agents/skills/bearings/assets/board-template.html" "$runtime"
  write_dom_decision_payload "$data"

  unanswered_stack=$(node "$ROOT/tests/fm-bearings-board-dom-harness.js" "$runtime" "$data" 0 decision 2>&1 | jq -r .stackText) \
    || fail "the DOM harness crashed reading the unanswered stack header"

  out=$(node "$ROOT/tests/fm-bearings-board-dom-harness.js" "$runtime" "$data" 1 decision-lost 2>&1) \
    || fail "the DOM harness crashed when the bridge died mid-session: $out"
  [ "$(printf '%s' "$out" | jq -r .queueCalls)" = "1" ] \
    || fail "the refused resubmit still reached queuePrompt after the bridge died: $out"
  [ "$(printf '%s' "$out" | jq -r .errorVisible)" = "true" ] \
    || fail "no error was surfaced when the bridge died after an earlier answer: $out"
  [ "$(printf '%s' "$out" | jq -r .isQueued)" = "false" ] \
    || fail "the earlier answer left its queued mark standing beside the refusal: $out"
  [ "$(printf '%s' "$out" | jq -r .stackText)" = "$unanswered_stack" ] \
    || fail "the stack header still counted the refused card as answered: $out"
  pass "a decision card drops its queued mark when a later answer is refused"
}

# The mirror case: a bridge lost after a dispatch went through must not leave
# the queued mark standing next to the refusal of the dispatch that did not.
test_dispatch_bar_drops_its_queued_mark_when_a_later_dispatch_is_refused() {
  command -v node >/dev/null 2>&1 || { echo "skip: node not found (DOM harness)"; return 0; }
  local runtime data out
  runtime="$TMP_ROOT/dispatch-runtime.js"
  data="$TMP_ROOT/dispatch-payload.json"
  extract_runtime_script "$ROOT/.agents/skills/bearings/assets/board-template.html" "$runtime"
  write_dom_dispatch_payload "$data"

  out=$(node "$ROOT/tests/fm-bearings-board-dom-harness.js" "$runtime" "$data" 1 dispatch-lost 2>&1) \
    || fail "the DOM harness crashed when the bridge died mid-session: $out"
  [ "$(printf '%s' "$out" | jq -r .queueCalls)" = "1" ] \
    || fail "the refused retry still reached queuePrompt after the bridge died: $out"
  [ "$(printf '%s' "$out" | jq -r .errorVisible)" = "true" ] \
    || fail "no error was surfaced when the bridge died after an earlier dispatch: $out"
  [ "$(printf '%s' "$out" | jq -r .isQueued)" = "false" ] \
    || fail "the earlier dispatch left its queued mark standing beside the refusal: $out"
  pass "the dispatch bar drops its queued mark when a later dispatch is refused"
}

test_an_option_less_card_is_built_and_answerable_through_its_freeform_box() {
  local home data rc out
  home=$(make_home freeformonly)
  data="$home/payload.json"
  write_dom_freeform_only_payload "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -eq 0 ] || fail "a captains_call item with no options but allow_freeform was refused: $out"

  command -v node >/dev/null 2>&1 || { echo "skip: node not found (DOM harness)"; return 0; }
  local runtime
  runtime="$TMP_ROOT/freeform-only-runtime.js"
  extract_runtime_script "$ROOT/.agents/skills/bearings/assets/board-template.html" "$runtime"
  out=$(node "$ROOT/tests/fm-bearings-board-dom-harness.js" "$runtime" "$data" 1 decision 2>&1) \
    || fail "the DOM harness crashed on an option-less card: $out"
  [ "$(printf '%s' "$out" | jq -r .hasFreeform)" = "true" ] \
    || fail "an option-less card rendered without a response box: $out"
  [ "$(printf '%s' "$out" | jq -r .queueCalls)" = "1" ] \
    || fail "a freeform-only answer never reached queuePrompt: $out"
  [ "$(printf '%s' "$out" | jq -r .isQueued)" = "true" ] \
    || fail "a freeform-only card was not marked queued after answering: $out"
  case "$(printf '%s' "$out" | jq -r .queuedText)" in
    *"hold this course"*) : ;;
    *) fail "the queued answer did not carry the words typed into the box: $out" ;;
  esac

  # the validator keeps allow_freeform out of a composer's hands, but a card
  # reaching the renderer without it must still give the captain the box
  jq 'del(.captains_call[0].allow_freeform)' "$data" > "$data.noflag"
  out=$(node "$ROOT/tests/fm-bearings-board-dom-harness.js" "$runtime" "$data.noflag" 1 decision 2>&1) \
    || fail "the DOM harness crashed on a card with no allow_freeform flag: $out"
  [ "$(printf '%s' "$out" | jq -r .hasFreeform)" = "true" ] \
    || fail "a card reaching the renderer without allow_freeform lost its response box: $out"
  pass "an option-less card is built and answerable through its freeform box"
}

# A decision card must let the captain judge the call from its text alone, so
# every decision-card element the composer supplies has to reach the page:
# the stakes, the question, each option's consequence, the recommendation's
# reason, and the PR link.
test_a_decision_card_shows_every_decision_card_element() {
  local home data rc out
  home=$(make_home fullcard)
  data="$home/payload.json"
  write_dom_decision_payload "$data"
  jq '.captains_call[0] += {
        "about": "Whether the sample project keeps nightly exports",
        "detail": "If nobody decides, exports keep failing every night",
        "decide": "Keep nightly exports?",
        "recommend_value": "yes",
        "recommend_reason": "customers read the export each morning",
        "pr_url": "https://github.com/example/sample/pull/7"
      }
      | .captains_call[0].options[0].hint = "exports resume tonight"
      | .captains_call[0].options[1].hint = "exports stop for good"' \
    "$data" > "$data.full"
  set +e; out=$(run_board "$home" build "$data.full" 2>&1); rc=$?; set -e
  [ "$rc" -eq 0 ] || fail "a decision card carrying every card element was refused: $out"

  command -v node >/dev/null 2>&1 || { echo "skip: node not found (DOM harness)"; return 0; }
  local runtime texts want
  runtime="$TMP_ROOT/full-card-runtime.js"
  extract_runtime_script "$ROOT/.agents/skills/bearings/assets/board-template.html" "$runtime"
  out=$(node "$ROOT/tests/fm-bearings-board-dom-harness.js" "$runtime" "$data.full" 1 decision 2>&1) \
    || fail "the DOM harness crashed on a full decision card: $out"
  texts=$(printf '%s' "$out" | jq -r '.cardTexts[]')
  for want in "Whether the sample project keeps nightly exports" \
    "If nobody decides, exports keep failing every night" \
    "Keep nightly exports?" \
    "customers read the export each morning" \
    "exports resume tonight" \
    "exports stop for good"; do
    printf '%s\n' "$texts" | grep -Fxq -- "$want" \
      || fail "the decision card did not show '$want': $out"
  done
  [ "$(printf '%s' "$out" | jq -r '.linkHrefs | index("https://github.com/example/sample/pull/7") != null')" = "true" ] \
    || fail "the decision card did not link its PR: $out"

  jq '.captains_call[0].recommend_reason = 7' "$data.full" > "$data.badreason"
  set +e; out=$(run_board "$home" build "$data.badreason" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-string recommend_reason was accepted: $out"
  pass "a decision card shows every decision-card element"
}

# A bridge that takes the call and then throws is as lossy as one that was
# never there, so both surfaces must refuse rather than claim a queued answer.
test_a_throwing_bridge_is_refused_like_a_missing_one() {
  command -v node >/dev/null 2>&1 || { echo "skip: node not found (DOM harness)"; return 0; }
  local runtime data out
  runtime="$TMP_ROOT/failing-bridge-runtime.js"
  extract_runtime_script "$ROOT/.agents/skills/bearings/assets/board-template.html" "$runtime"

  data="$TMP_ROOT/decision-payload.json"
  write_dom_decision_payload "$data"
  out=$(node "$ROOT/tests/fm-bearings-board-dom-harness.js" "$runtime" "$data" throw decision 2>&1) \
    || fail "the DOM harness crashed on a queuePrompt that threw: $out"
  [ "$(printf '%s' "$out" | jq -r .isQueued)" = "false" ] \
    || fail "a decision card claimed queued though queuePrompt threw: $out"
  [ "$(printf '%s' "$out" | jq -r .errorVisible)" = "true" ] \
    || fail "no error was surfaced though queuePrompt threw: $out"

  data="$TMP_ROOT/dispatch-payload.json"
  write_dom_dispatch_payload "$data"
  out=$(node "$ROOT/tests/fm-bearings-board-dom-harness.js" "$runtime" "$data" throw dispatch 2>&1) \
    || fail "the DOM harness crashed on a queuePrompt that threw: $out"
  [ "$(printf '%s' "$out" | jq -r .isQueued)" = "false" ] \
    || fail "the dispatch bar claimed queued though queuePrompt threw: $out"
  [ "$(printf '%s' "$out" | jq -r .errorVisible)" = "true" ] \
    || fail "no error was surfaced though queuePrompt threw: $out"
  pass "a queuePrompt that throws is refused like a missing bridge"
}

# The queued mark belongs to the answer that was sent, so changing the
# selection afterwards must take the mark - and the deal count - with it.
test_changing_the_selection_drops_a_stale_queued_mark() {
  command -v node >/dev/null 2>&1 || { echo "skip: node not found (DOM harness)"; return 0; }
  local runtime data out unanswered_stack
  runtime="$TMP_ROOT/repick-runtime.js"
  extract_runtime_script "$ROOT/.agents/skills/bearings/assets/board-template.html" "$runtime"

  data="$TMP_ROOT/decision-payload.json"
  write_dom_decision_payload "$data"
  unanswered_stack=$(node "$ROOT/tests/fm-bearings-board-dom-harness.js" "$runtime" "$data" 0 decision 2>&1 | jq -r .stackText) \
    || fail "the DOM harness crashed reading the unanswered stack header"
  out=$(node "$ROOT/tests/fm-bearings-board-dom-harness.js" "$runtime" "$data" 1 decision-repick 2>&1) \
    || fail "the DOM harness crashed repicking an answered card: $out"
  [ "$(printf '%s' "$out" | jq -r .queueCalls)" = "1" ] \
    || fail "repicking an option queued a second answer on its own: $out"
  [ "$(printf '%s' "$out" | jq -r .isQueued)" = "false" ] \
    || fail "a card kept its queued mark beside a selection it never sent: $out"
  [ "$(printf '%s' "$out" | jq -r .stackText)" = "$unanswered_stack" ] \
    || fail "the stack header still counted the repicked card as answered: $out"

  data="$TMP_ROOT/dispatch-payload.json"
  write_dom_dispatch_payload "$data"
  out=$(node "$ROOT/tests/fm-bearings-board-dom-harness.js" "$runtime" "$data" 1 dispatch-repick 2>&1) \
    || fail "the DOM harness crashed unpicking a dispatched item: $out"
  [ "$(printf '%s' "$out" | jq -r .queueCalls)" = "1" ] \
    || fail "changing the picks queued a second dispatch on its own: $out"
  [ "$(printf '%s' "$out" | jq -r .isQueued)" = "false" ] \
    || fail "the dispatch bar kept its queued mark beside picks it never sent: $out"
  pass "changing the selection drops a stale queued mark"
}

# A board-valid quota section as bin/fm-bearings-quota.sh prints it: one stale
# provider with an unreported value, one signed out, one fresh.
write_quota_section() {  # <path>
  cat > "$1" <<'EOF'
{
  "source": "quota-axi",
  "generated": "2026-09-26T14:35:03.033Z",
  "available": true,
  "status": "ok",
  "providers": [
    { "provider": "claude", "label": "Anthropic", "available": true, "status": "stale",
      "detail": "fetch failed", "plan": "max",
      "windows": [
        { "id": "five_hour", "label": "session", "kind": "session",
          "percent_used": 52, "percent_remaining": 48, "resets_at": "2026-09-26T16:40:00Z" },
        { "id": "model:fable", "label": "Fable week", "kind": "model",
          "percent_used": null, "percent_remaining": null, "resets_at": null }
      ],
      "attention": [ { "kind": "stale", "detail": "fetch failed" },
                     { "kind": "headroom_unknown", "detail": "all_models" } ] },
    { "provider": "codex", "label": "OpenAI", "available": false, "status": "auth_required",
      "detail": "Codex sign-in required", "plan": null, "windows": [], "attention": [] },
    { "provider": "agy", "label": "Google", "available": true, "status": "fresh", "plan": "Google AI Pro",
      "windows": [
        { "id": "model:gemini-3.6-flash-high", "label": "Gemini 3.6 Flash (High)", "kind": "model",
          "percent_used": 12, "percent_remaining": 88, "resets_at": "2026-09-26T19:11:43.000Z" }
      ],
      "attention": [] }
  ]
}
EOF
}

test_build_accepts_an_optional_quota_section_and_refuses_a_malformed_one() {
  local home data rc out bad
  home=$(make_home quota)
  data="$home/payload.json"
  write_valid_payload "$data"
  write_quota_section "$home/quota.json"
  jq --slurpfile q "$home/quota.json" '.quota = $q[0]' "$data" > "$data.quota"
  set +e; out=$(run_board "$home" build "$data.quota" 2>&1); rc=$?; set -e
  [ "$rc" -eq 0 ] || fail "a payload carrying a valid quota section was refused: $out"
  [ "$(extract_payload "$home/.lavish/bearings-board.html" | jq -r '.quota.providers[2].windows[0].percent_remaining')" = "88" ] \
    || fail "the quota section did not survive injection"

  for bad in '.quota.providers[0].windows[0].percent_used = 150' \
    '.quota.providers[0].windows[0].percent_remaining = "48"' \
    '.quota.providers[1].available = "no"' \
    'del(.quota.providers)' \
    '.quota.providers[0].attention[0].kind = ""' \
    '.quota.providers[0].windows[0].label = ""' \
    '.quota = "unavailable"'; do
    jq "$bad" "$data.quota" > "$data.bad"
    set +e; out=$(run_board "$home" build "$data.bad" 2>&1); rc=$?; set -e
    [ "$rc" -ne 0 ] || fail "a malformed quota section was accepted ($bad)"
  done
  pass "build accepts an optional quota section and refuses a malformed one"
}

# The quota panel runs the REAL template runtime (same DOM shim as the Captain's
# Call tests) and must show reported numbers, say "non disponibile" with the
# reason wherever a value or provider is missing, and never take the rest of
# the board down with it.
test_quota_panel_renders_values_and_says_why_anything_is_unavailable() {
  command -v node >/dev/null 2>&1 || { echo "skip: node not found (DOM harness)"; return 0; }
  local runtime data out texts want
  runtime="$TMP_ROOT/quota-runtime.js"
  extract_runtime_script "$ROOT/.agents/skills/bearings/assets/board-template.html" "$runtime"
  data="$TMP_ROOT/quota-payload.json"
  write_valid_payload "$data"
  write_quota_section "$TMP_ROOT/quota.json"
  jq --slurpfile q "$TMP_ROOT/quota.json" '.quota = $q[0]' "$data" > "$data.quota"

  out=$(node "$ROOT/tests/fm-bearings-board-dom-harness.js" "$runtime" "$data.quota" 1 quota 2>&1) \
    || fail "the DOM harness crashed on a quota section: $out"
  texts=$(printf '%s' "$out" | jq -r '.providers[0][]')
  for want in "Anthropic" "5 ore" "usato 52% · restante 48%" "Fable week" "non disponibile" \
    "dati non aggiornati: fetch failed" "margine residuo non misurabile: all_models"; do
    printf '%s\n' "$texts" | grep -Fxq -- "$want" || fail "the Anthropic card did not show '$want': $out"
  done
  printf '%s\n' "$texts" | grep -q '^si azzera ' || fail "the Anthropic card did not show its reset time: $out"
  printf '%s' "$out" | jq -r '.providers[1][]' \
    | grep -Fxq "non disponibile - accesso richiesto: Codex sign-in required" \
    || fail "the signed-out OpenAI card did not say it is unavailable and why: $out"
  printf '%s' "$out" | jq -r '.providers[2][]' | grep -Fxq "usato 12% · restante 88%" \
    || fail "the Google card did not show its Gemini window: $out"
  [ "$(printf '%s' "$out" | jq -c '.fillStyles')" = '["width:52%","width:12%"]' ] \
    || fail "usage bars were drawn for a value that was not reported: $out"

  jq '.quota.providers[2].windows = [
        {id: "gemini_5h", label: "Gemini 5-hour", kind: "session", percent_used: 10, percent_remaining: 90, resets_at: null},
        {id: "other_5h", label: "Claude/GPT 5-hour", kind: "session", percent_used: 40, percent_remaining: 60, resets_at: null},
        {id: "gemini_week", label: "Gemini weekly", kind: "weekly", percent_used: 20, percent_remaining: 80, resets_at: null},
        {id: "plain_week", label: "", kind: "weekly", percent_used: 5, percent_remaining: 95, resets_at: null}]' \
    "$data.quota" > "$data.grouped"
  out=$(node "$ROOT/tests/fm-bearings-board-dom-harness.js" "$runtime" "$data.grouped" 1 quota 2>&1) \
    || fail "the DOM harness crashed on grouped Google windows: $out"
  texts=$(printf '%s' "$out" | jq -r '.providers[2][]')
  for want in "Gemini 5-hour" "Claude/GPT 5-hour" "Gemini weekly" "settimana"; do
    printf '%s\n' "$texts" | grep -Fxq -- "$want" || fail "the Google card did not label a grouped window '$want': $out"
  done

  jq '.quota = {source: "quota-axi", generated: null, available: false, status: "tool_missing",
        detail: "quota-axi is not installed",
        providers: [{provider: "claude", label: "Anthropic", available: false, status: "tool_missing",
                     detail: "quota-axi is not installed", plan: null, windows: [], attention: []}]}' \
    "$data" > "$data.missing"
  out=$(node "$ROOT/tests/fm-bearings-board-dom-harness.js" "$runtime" "$data.missing" 1 quota 2>&1) \
    || fail "the DOM harness crashed on a missing-tool quota section: $out"
  printf '%s' "$out" | jq -r '.providers[0][]' \
    | grep -Fxq "non disponibile - quota-axi non è installato: quota-axi is not installed" \
    || fail "a missing quota-axi was not shown as unavailable with its reason: $out"
  [ "$(printf '%s' "$out" | jq -r .subText)" = "non disponibile" ] \
    || fail "the panel header did not say the quota is unavailable: $out"

  out=$(node "$ROOT/tests/fm-bearings-board-dom-harness.js" "$runtime" "$data" 1 quota 2>&1) \
    || fail "the DOM harness crashed on a payload without quota: $out"
  printf '%s' "$out" | jq -r '.providers[0][]' | grep -Fq "non contiene i dati di quota" \
    || fail "a payload without quota did not say the quota is unavailable: $out"
  [ "$(printf '%s' "$out" | jq -r .stats)" = "4" ] \
    || fail "the rest of the board did not render beside an absent quota section: $out"

  jq '.quota = {providers: [{label: "Anthropic", windows: "garbage"}]}' "$data" > "$data.garbage"
  out=$(node "$ROOT/tests/fm-bearings-board-dom-harness.js" "$runtime" "$data.garbage" 1 quota 2>&1) \
    || fail "the DOM harness crashed on a malformed quota section: $out"
  printf '%s' "$out" | jq -r '.providers[0][]' | grep -Fxq "non disponibile - stato sconosciuto" \
    || fail "a malformed provider did not degrade to unavailable: $out"
  [ "$(printf '%s' "$out" | jq -r .stats)" = "4" ] \
    || fail "a malformed quota section took the rest of the board down: $out"
  pass "the quota panel shows reported values and says why anything is unavailable"
}

test_build_refuses_a_template_without_exactly_one_slot() {
  local home data rc out
  home=$(make_home badslot)
  data="$home/payload.json"
  write_valid_payload "$data"
  printf '<html><body>no slot</body></html>\n' > "$home/broken-template.html"
  set +e
  out=$(FM_BEARINGS_BOARD_TEMPLATE="$home/broken-template.html" run_board "$home" build "$data" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a template with no data slot was accepted"
  assert_contains "$out" "data slot" "the slot refusal did not say why: $out"
  assert_absent "$home/.lavish/bearings-board.html" "a refused template still produced a board"
  pass "build refuses a template without exactly one data slot"
}

# ---- live board: deterministic refresh ------------------------------------

# A runtime copy of bin/ whose snapshot and quota readers print fixtures, so
# refresh composes from a known fleet without a real fleet or network.
make_live_runtime() {  # <home>
  local home=$1 runtime="$1/runtime"
  mkdir -p "$runtime"
  cp -R "$ROOT/bin" "$runtime/bin"
  cat > "$runtime/bin/fm-bearings-snapshot.sh" <<'SH'
#!/usr/bin/env bash
[ -n "${LIVE_SNAPSHOT_FAIL:-}" ] && { echo "fm-bearings-snapshot: simulated failure" >&2; exit 1; }
all_decisions=false all_in_flight=false all_prs=false
for arg in "$@"; do
  case "$arg" in
    --all-decisions) all_decisions=true ;;
    --all-in-flight) all_in_flight=true ;;
    --all-recorded-prs) all_prs=true ;;
  esac
done
jq --argjson cap "${LIVE_SNAPSHOT_CAP:-20}" --argjson d "$all_decisions" \
  --argjson f "$all_in_flight" --argjson p "$all_prs" '
  (if $d then . else .decisions_open |= .[:$cap] end)
  | (if $f then . else .in_flight |= .[:$cap] end)
  | (if $p then . else .recorded_prs |= .[:$cap] end)' "$LIVE_SNAPSHOT_FIXTURE"
SH
  cat > "$runtime/bin/fm-bearings-quota.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"source":"quota-axi","generated":null,"available":false,"status":"tool_missing","detail":"quota-axi is not installed","providers":[]}'
SH
  chmod +x "$runtime/bin/fm-bearings-snapshot.sh" "$runtime/bin/fm-bearings-quota.sh"
  cat > "$home/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${LAVISH_CALLS:-/dev/null}"
exit 0
SH
  chmod +x "$home/fakebin/lavish-axi"
  printf '%s\n' "$runtime"
}

run_live_board() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    FM_BEARINGS_BOARD_TEMPLATE="$ROOT/.agents/skills/bearings/assets/board-template.html" \
    LIVE_SNAPSHOT_FIXTURE="$home/snapshot.json" LAVISH_CALLS="$home/lavish-calls" \
    "$home/runtime/bin/fm-bearings-board.sh" "$@"
}

write_live_snapshot() {  # <path>
  cat > "$1" <<'EOF'
{
  "schema": "fm-bearings.v1",
  "home": "alan/test-home",
  "generated": "2026-09-30T07:00:00Z",
  "prs": "not_requested",
  "in_flight": [
    { "id": "ship-a", "kind": "ship", "state": "done", "doing": "checks green: PR ready for review" },
    { "id": "scout-b", "kind": "scout", "state": "working", "doing": "reading the export job" }
  ],
  "secondmates": [
    { "id": "android", "state": "active_child_work", "doing": "one child task working", "age_seconds": 120 },
    { "id": "ios", "state": "unknown", "doing": "structured home state invalid", "reason": "home state unreadable", "age_seconds": 5 }
  ],
  "decisions_open": [
    { "id": "composed-call", "key": "composed-call", "verb": "captain-hold", "summary": "terse raw reason", "owner": "(main)" },
    { "id": "new-call", "key": "new-call", "verb": "captain-hold", "summary": "Pick the export window: nightly or weekly, why now - the disk fills on Friday", "owner": "(main)" }
  ],
  "landed": [
    { "id": "old-fix", "what": "Old fix", "artifact": "https://github.com/example/widget/pull/7", "owner": "(main)" }
  ],
  "gates": [
    { "id": "free-work", "title": "Free work", "blocked_by": "-", "reason": "-", "owner": "(main)" },
    { "id": "blocked-work", "title": "Blocked work", "blocked_by": "free-work", "reason": "-", "owner": "(main)" },
    { "id": "(main-inventory)", "title": "in-flight backlog item has no child metadata", "blocked_by": "-", "reason": "main inventory", "owner": "(main)" }
  ],
  "reports": [],
  "recorded_prs": [
    { "id": "ship-a", "url": "https://github.com/example/widget/pull/9" },
    { "id": "landed-already", "url": "https://gitlab.com/example/api/-/merge_requests/3" }
  ],
  "omitted": [ { "surface": "gates showing 3 of 6", "reveal": "--all-queued" } ]
}
EOF
}

# The composed payload firstmate built earlier: one card still open, one merge
# card for an in-flight PR, and two cards whose calls are gone.
write_composed_board_payload() {  # <path>
  cat > "$1" <<'EOF'
{
  "schema": "fm-bearings-board.v1",
  "home": "alan/test-home",
  "generated": "2026-09-30T06:00:00Z",
  "prs_live": false,
  "captains_call": [
    { "key": "composed-call", "type": "decision", "repo": "widget", "title": "Composed title",
      "about": "Composed about text", "decide": "Ship it?", "close": "release",
      "options": [ { "value": "yes", "label": "Yes" }, { "value": "no", "label": "No" } ],
      "allow_freeform": true },
    { "key": "merge.ship-a", "type": "merge", "repo": "widget", "title": "Merge: widget fix",
      "detail": "fixes the widget", "risk": "low", "pr_url": "https://github.com/example/widget/pull/9",
      "options": [ { "value": "merge", "label": "Merge now" }, { "value": "hold", "label": "Not yet" } ],
      "allow_freeform": true },
    { "key": "answered-call", "type": "decision", "repo": "widget", "title": "Already answered",
      "options": [], "allow_freeform": true },
    { "key": "merge.landed-already", "type": "merge", "repo": "api", "title": "Merge: gone",
      "risk": "low", "options": [ { "value": "merge", "label": "Merge now" } ], "allow_freeform": true },
    { "key": "raw-copy", "type": "decision", "repo": null, "title": "A raw card copied back",
      "options": [], "allow_freeform": true, "raw": true }
  ],
  "underway": [],
  "landed": [],
  "charted": []
}
EOF
}

# The live data file is a script that hands its payload to the page; pull the
# JSON argument back out of it.
extract_live_payload() {  # <data-file>
  perl -0pe 's/\A.*?\}\)\(//s; s/\);\s*\z//s' "$1"
}

test_refresh_does_nothing_until_enabled_and_published() {
  local home out
  home=$(make_home live-gates)
  make_live_runtime "$home" >/dev/null
  write_live_snapshot "$home/snapshot.json"

  out=$(run_live_board "$home" refresh) || fail "refresh failed while the live board is off: $out"
  assert_contains "$out" "skipped: the live board is off" "refresh did not say the live board is off: $out"
  mkdir -p "$home/config"
  printf 'off\n' > "$home/config/live-board"
  out=$(run_live_board "$home" refresh) || fail "refresh failed with the flag set to off: $out"
  assert_contains "$out" "skipped: the live board is off" "a non-on flag enabled the live board: $out"

  printf '\non\n' > "$home/config/live-board"
  out=$(run_live_board "$home" refresh) || fail "refresh failed before any board was published: $out"
  assert_contains "$out" "skipped: no board has been published" "refresh did not say no board exists: $out"
  assert_absent "$home/.lavish/bearings-board.data.js" "refresh wrote live data with no published board"

  write_composed_board_payload "$home/payload.json"
  run_live_board "$home" build "$home/payload.json" >/dev/null || fail "the composed board did not build"
  : > "$home/state/.afk"
  cp "$home/.lavish/bearings-board.data.js" "$home/data-before.js"
  out=$(run_live_board "$home" refresh) || fail "refresh failed during away mode: $out"
  assert_contains "$out" "skipped: away mode" "refresh did not step aside during away mode: $out"
  cmp -s "$home/data-before.js" "$home/.lavish/bearings-board.data.js" \
    || fail "refresh replaced the live data while away mode held fleet reads"
  pass "refresh does nothing until the flag is on, a board exists, and away mode is clear"
}

test_build_writes_the_live_data_file_and_the_composed_card_store() {
  local home
  home=$(make_home live-build)
  make_live_runtime "$home" >/dev/null
  write_composed_board_payload "$home/payload.json"
  run_live_board "$home" build "$home/payload.json" >/dev/null || fail "the composed board did not build"

  extract_live_payload "$home/.lavish/bearings-board.data.js" | jq -S . > "$home/live.json" \
    || fail "the live data file does not carry a readable payload"
  jq -S . "$home/payload.json" > "$home/expected.json"
  diff -u "$home/expected.json" "$home/live.json" >/dev/null \
    || fail "the live data file written by build is not the built payload"
  jq -e '.schema == "fm-bearings-board-cards.v1"
      and ([.cards[].key] == ["composed-call", "merge.ship-a", "answered-call", "merge.landed-already"])' \
    "$home/data/bearings-board-cards.json" >/dev/null \
    || fail "the composed-card store does not hold exactly the composed (non-raw) cards: $(cat "$home/data/bearings-board-cards.json")"
  [ "$(stat -c %a "$home/data/bearings-board-cards.json" 2>/dev/null \
      || stat -f %Lp "$home/data/bearings-board-cards.json" 2>/dev/null)" = 600 ] \
    || fail "the composed-card store is not private"
  pass "build writes the live data file and the composed-card store"
}

test_refresh_composes_a_live_payload_without_touching_the_page() {
  local home out live board_sum records
  home=$(make_home live-compose)
  make_live_runtime "$home" >/dev/null
  write_live_snapshot "$home/snapshot.json"
  write_composed_board_payload "$home/payload.json"
  mkdir -p "$home/config"
  printf 'on\n' > "$home/config/live-board"
  fm_write_meta "$home/state/ship-a.meta" "project=/somewhere/projects/widget" "kind=ship"
  printf 'done: PR ready\n' > "$home/state/ship-a.status"
  TZ=UTC touch -t 202609300700.00 "$home/state/ship-a.status"
  run_live_board "$home" build "$home/payload.json" >/dev/null || fail "the composed board did not build"
  board_sum=$(cksum < "$home/.lavish/bearings-board.html")
  : > "$home/lavish-calls"
  records=$(find "$home/state/procevent" -name '*.source' | wc -l | tr -d ' ')

  out=$(run_live_board "$home" refresh) || fail "refresh failed: $out"
  assert_contains "$out" "refreshed: $home/.lavish/bearings-board.data.js" "refresh did not report the data file: $out"
  [ "$(cksum < "$home/.lavish/bearings-board.html")" = "$board_sum" ] \
    || fail "refresh rewrote the board page, which would reload it under the captain"
  [ ! -s "$home/lavish-calls" ] || fail "refresh touched the Lavish session: $(cat "$home/lavish-calls")"
  [ "$(find "$home/state/procevent" -name '*.source' | wc -l | tr -d ' ')" = "$records" ] \
    || fail "refresh changed the answer-source registrations"

  live="$home/live.json"
  extract_live_payload "$home/.lavish/bearings-board.data.js" > "$live" \
    || fail "the refreshed data file is not readable"
  jq -e '.source == "live-refresh" and .home == "alan/test-home"' "$live" >/dev/null \
    || fail "the refreshed payload is not marked as a live refresh: $(cat "$live")"
  [ "$(jq -c '[.captains_call[].key]' "$live")" = '["composed-call","merge.ship-a","new-call"]' ] \
    || fail "Captain's Call is not the open composed cards followed by the new raw one: $(jq -c '[.captains_call[].key]' "$live")"
  jq -e '.captains_call[0] | .title == "Composed title" and .about == "Composed about text"
      and .close == "release" and (.raw | not)' "$live" >/dev/null \
    || fail "a still-open call lost firstmate's composed text: $(jq -c '.captains_call[0]' "$live")"
  jq -e '.captains_call[2] | .raw == true and .close == "release" and .options == []
      and .allow_freeform == true and .title == "Pick the export window"
      and (.about | startswith("Pick the export window: nightly or weekly"))' "$live" >/dev/null \
    || fail "a new hold did not become a clearly marked raw card: $(jq -c '.captains_call[2]' "$live")"
  jq -e '[.underway[] | {id, kind, repo}] == [
      {id: "ship-a", kind: "ship", repo: "widget"},
      {id: "scout-b", kind: "scout", repo: null},
      {id: "android", kind: "second mate", repo: null}]' "$live" >/dev/null \
    || fail "Underway is not every in-flight worker plus active second mates: $(jq -c '.underway' "$live")"
  jq -e '.underway[0].since == "2026-09-30T07:00:00Z"' "$live" >/dev/null || fail "a worker's age does not come from its last status event: $(jq -c '.underway[0]' "$live")"
  jq -e '[.prs[] | {id, repo, state}] == [
      {id: "ship-a", repo: "widget", state: "done"},
      {id: "landed-already", repo: "api", state: "not in flight"}]' "$live" >/dev/null \
    || fail "the open PR list is not the recorded PRs with their last state: $(jq -c '.prs' "$live")"
  jq -e '[.charted[] | {id, dispatchable}] == [
      {id: "free-work", dispatchable: true},
      {id: "blocked-work", dispatchable: false},
      {id: "main-inventory", dispatchable: false},
      {id: "ios", dispatchable: false}] and .charted[1].reason == "waiting on free-work"
      and .charted_more == 3' "$live" >/dev/null \
    || fail "Charted Next did not come from the snapshot gates: $(jq -c '{charted, charted_more}' "$live")"
  jq -e '.landed[0] | .repo == "widget" and .pr_url == "https://github.com/example/widget/pull/7"' "$live" >/dev/null \
    || fail "Recently Landed lost its PR link: $(jq -c '.landed' "$live")"
  jq -e '.quota.status == "tool_missing"' "$live" >/dev/null || fail "the quota section was not carried"
  pass "refresh composes a live payload from the fleet without touching the page or its session"
}

test_refresh_drops_a_malformed_stored_card_and_keeps_the_last_data_on_failure() {
  local home out rc
  home=$(make_home live-robust)
  make_live_runtime "$home" >/dev/null
  write_live_snapshot "$home/snapshot.json"
  write_composed_board_payload "$home/payload.json"
  mkdir -p "$home/config"
  printf 'on\n' > "$home/config/live-board"
  run_live_board "$home" build "$home/payload.json" >/dev/null || fail "the composed board did not build"
  jq '.cards[0].allow_freeform = false' "$home/data/bearings-board-cards.json" > "$home/cards.tmp" \
    && mv "$home/cards.tmp" "$home/data/bearings-board-cards.json"

  out=$(run_live_board "$home" refresh) || fail "one malformed stored card failed the whole refresh: $out"
  extract_live_payload "$home/.lavish/bearings-board.data.js" \
    | jq -e '.captains_call[] | select(.key == "composed-call") | .raw == true' >/dev/null \
    || fail "an open call whose stored card is malformed did not fall back to its raw card"

  cp "$home/.lavish/bearings-board.data.js" "$home/data-before.js"
  set +e
  out=$(LIVE_SNAPSHOT_FAIL=1 run_live_board "$home" refresh 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "refresh reported success when the fleet snapshot failed"
  assert_contains "$out" "simulated failure" "the snapshot failure was not named: $out"
  cmp -s "$home/data-before.js" "$home/.lavish/bearings-board.data.js" \
    || fail "a failed refresh replaced the last good live data"
  pass "refresh drops a malformed stored card and keeps the last data when the snapshot fails"
}

test_refresh_sees_every_open_hold_and_in_flight_task_past_the_snapshot_caps() {
  local home out live
  home=$(make_home live-uncapped)
  make_live_runtime "$home" >/dev/null
  write_live_snapshot "$home/snapshot.json"
  write_composed_board_payload "$home/payload.json"
  mkdir -p "$home/config"
  printf 'on\n' > "$home/config/live-board"
  run_live_board "$home" build "$home/payload.json" >/dev/null || fail "the composed board did not build"

  out=$(LIVE_SNAPSHOT_CAP=1 run_live_board "$home" refresh) || fail "refresh failed: $out"
  live="$home/live.json"
  extract_live_payload "$home/.lavish/bearings-board.data.js" > "$live" \
    || fail "the refreshed data file is not readable"
  [ "$(jq -c '[.captains_call[].key]' "$live")" = '["composed-call","merge.ship-a","new-call"]' ] \
    || fail "an open hold past the snapshot cap was dropped: $(jq -c '[.captains_call[].key]' "$live")"
  [ "$(jq -c '[.underway[].id]' "$live")" = '["ship-a","scout-b","android"]' ] \
    || fail "an in-flight task past the snapshot cap was dropped: $(jq -c '[.underway[].id]' "$live")"
  [ "$(jq -c '[.prs[].id]' "$live")" = '["ship-a","landed-already"]' ] \
    || fail "a recorded PR past the snapshot cap was dropped: $(jq -c '[.prs[].id]' "$live")"
  pass "refresh sees every open hold, in-flight task, and recorded PR past the snapshot caps"
}

test_systemd_units_escape_quotes_backslashes_and_specifiers() {
  local home out parsed
  home=$(make_home 'live-units-q"b\\s%h')
  out=$(PATH="/odd\\dir:/q\"uote:/pct%n:$PATH" run_board "$home" systemd-units) || fail "systemd-units failed: $out"
  parsed=$(printf '%s\n' "$out" | sed -n 's/^Environment="FM_HOME=\(.*\)"$/\1/p' \
    | perl -pe 's/%%/%/g; s/\\(["\\])/$1/g')
  [ "$parsed" = "$(cd "$home" && pwd -P)" ] || fail "FM_HOME does not round-trip through systemd quoting: $parsed"
  parsed=$(printf '%s\n' "$out" | sed -n 's/^Environment="PATH=\(.*\)"$/\1/p' \
    | perl -pe 's/%%/%/g; s/\\(["\\])/$1/g')
  case "$parsed" in
    *'/odd\dir:/q"uote:/pct%n:'*) ;;
    *) fail "PATH does not round-trip through systemd quoting: $parsed" ;;
  esac
  pass "systemd-units escapes quotes, backslashes, and specifiers in quoted values"
}

test_systemd_units_run_refresh_for_this_home() {
  local home out rc name
  home=$(make_home live-units)
  out=$(run_board "$home" systemd-units) || fail "systemd-units failed: $out"
  assert_contains "$out" "ExecStart=\"$ROOT/bin/fm-bearings-board.sh\" refresh" "the service does not run refresh: $out"
  assert_contains "$out" "Environment=\"FM_HOME=$(cd "$home" && pwd -P)\"" "the service is not bound to this home: $out"
  assert_contains "$out" "OnUnitInactiveSec=90s" "the default cadence is not 90 seconds: $out"
  assert_contains "$out" "WantedBy=timers.target" "the timer cannot be enabled: $out"

  set +e
  run_board "$home" systemd-units --interval 10 >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an interval below the minimum was accepted"

  out=$(run_board "$home" systemd-units --interval 60 --dir "$home/units") || fail "writing the units failed: $out"
  name=$(printf '%s\n' "$out" | sed -n 's/^unit: //p')
  assert_present "$home/units/${name%.timer}.service" "the service unit was not written"
  grep -qxF 'OnUnitInactiveSec=60s' "$home/units/$name" || fail "the written timer does not carry the chosen cadence"
  pass "systemd-units describes a user timer that runs refresh for this home"
}

# ---- live board: the page keeps what the captain is doing -----------------

write_live_dom_payload() {  # <path> <generated> <source> <calls-json> [<charted-json>] [<extra-jq>]
  jq -n --arg generated "$2" --arg source "$3" --argjson calls "$4" --argjson charted "${5:-[]}" '
    { schema: "fm-bearings-board.v1", home: "dom-test", generated: $generated, source: $source,
      prs_live: false, captains_call: $calls, underway: [], landed: [], charted: $charted, charted_more: 0 }' \
    | jq "${6:-.}" > "$1"
}

live_card() {  # <key> <title> [<raw>]
  jq -cn --arg key "$1" --arg title "$2" --arg raw "${3:-}" '
    { key: $key, type: "decision", repo: "sample", title: $title,
      options: [ { value: "yes", label: "Yes" }, { value: "no", label: "No" } ], allow_freeform: true }
    + (if $raw == "" then {} else { raw: true, close: "release", options: [] } end)'
}

run_live_dom() {  # <mode> <bridge> <payload> [<update>...]
  local runtime="$TMP_ROOT/live-runtime.js" mode=$1 bridge=$2
  shift 2
  extract_runtime_script "$ROOT/.agents/skills/bearings/assets/board-template.html" "$runtime"
  node "$ROOT/tests/fm-bearings-board-dom-harness.js" "$runtime" "$1" "$bridge" "$mode" "${@:2}"
}

test_a_live_update_keeps_an_unsent_answer_and_its_card() {
  command -v node >/dev/null 2>&1 || { echo "skip: node not found (DOM harness)"; return 0; }
  local dir="$TMP_ROOT/live-draft" out a b c
  mkdir -p "$dir"
  a=$(live_card call-a "First call"); b=$(live_card call-b "Second call"); c=$(live_card call-c "Third call")
  write_live_dom_payload "$dir/start.json" 2026-09-30T07:00:00Z live-refresh "[$a,$b]"
  a=$(live_card call-a "First call, reworded")
  write_live_dom_payload "$dir/update.json" 2026-09-30T07:01:30Z live-refresh "[$a,$c]"

  out=$(run_live_dom live-draft 1 "$dir/start.json" "$dir/update.json" 2>&1) \
    || fail "the DOM harness crashed on a live update: $out"
  [ "$(printf '%s' "$out" | jq -c '[.cards[].key]')" = '["call-a","call-c"]' ] \
    || fail "the deck is not the updated calls: $out"
  printf '%s' "$out" | jq -e '.cards[0] | .sameNode and .freeform == "half-written answer"
      and .title == "First call" and (.note | test("newer text"))' >/dev/null \
    || fail "a live update rebuilt or lost the card the captain was typing into: $out"
  printf '%s' "$out" | jq -e '.cards[1] | .title == "Third call" and (.queued | not)' >/dev/null \
    || fail "a new call did not appear on a live update: $out"

  write_live_dom_payload "$dir/gone.json" 2026-09-30T07:03:00Z live-refresh "[$c]"
  out=$(run_live_dom live-draft 1 "$dir/start.json" "$dir/gone.json" 2>&1) \
    || fail "the DOM harness crashed when a drafted call left the fleet: $out"
  printf '%s' "$out" | jq -e '[.cards[].key] == ["call-c", "call-a"]
      and (.cards[1] | .freeform == "half-written answer" and (.note | test("no longer open")))' >/dev/null \
    || fail "an unsent answer was dropped when its call left the fleet: $out"
  pass "a live update never rebuilds or drops a card holding an unsent answer"
}

test_a_live_update_keeps_a_queued_answer_until_its_call_closes() {
  command -v node >/dev/null 2>&1 || { echo "skip: node not found (DOM harness)"; return 0; }
  local dir="$TMP_ROOT/live-queued" out a b
  mkdir -p "$dir"
  a=$(live_card call-a "First call"); b=$(live_card call-b "Second call")
  write_live_dom_payload "$dir/start.json" 2026-09-30T07:00:00Z live-refresh "[$a,$b]"
  a=$(live_card call-a "First call, reworded")
  write_live_dom_payload "$dir/reworded.json" 2026-09-30T07:01:30Z live-refresh "[$a,$b]"
  write_live_dom_payload "$dir/closed.json" 2026-09-30T07:03:00Z live-refresh "[$b]"

  out=$(run_live_dom live-queued 1 "$dir/start.json" "$dir/reworded.json" 2>&1) \
    || fail "the DOM harness crashed on a live update after an answer was queued: $out"
  printf '%s' "$out" | jq -e '.cards[0] | .sameNode and .queued and .title == "First call"' >/dev/null \
    || fail "a live update rebuilt a card whose answer is queued: $out"
  printf '%s' "$out" | jq -e '.queued == [{question: "call-a", answer: "yes"}]' >/dev/null \
    || fail "the queued answer was not the one sent: $out"

  out=$(run_live_dom live-queued 1 "$dir/start.json" "$dir/reworded.json" "$dir/closed.json" 2>&1) \
    || fail "the DOM harness crashed when a queued call closed: $out"
  [ "$(printf '%s' "$out" | jq -c '[.cards[].key]')" = '["call-b"]' ] \
    || fail "a closed call's card stayed on the board after its answer was queued: $out"
  pass "a queued answer's card stays as sent until its call closes"
}

test_a_live_update_refreshes_an_idle_card_and_ignores_a_bad_update() {
  command -v node >/dev/null 2>&1 || { echo "skip: node not found (DOM harness)"; return 0; }
  local dir="$TMP_ROOT/live-idle" out a
  mkdir -p "$dir"
  a=$(live_card call-a "First call")
  write_live_dom_payload "$dir/start.json" 2026-09-30T07:00:00Z live-refresh "[$a]"
  a=$(live_card call-a "First call, reworded")
  write_live_dom_payload "$dir/update.json" 2026-09-30T07:01:30Z live-refresh "[$a]"
  printf '{"schema":"fm-bearings-board.v0","generated":"2026-09-30T07:02:00Z"}\n' > "$dir/bad.json"

  out=$(run_live_dom live-idle 1 "$dir/start.json" "$dir/update.json" "$dir/bad.json" 2>&1) \
    || fail "the DOM harness crashed on an idle live update: $out"
  printf '%s' "$out" | jq -e '.cards == [.cards[0]] and (.cards[0] | .title == "First call, reworded" and .note == "")' \
    >/dev/null || fail "an idle card did not take the updated text, or a bad update replaced it: $out"
  pass "an idle card takes new text and a malformed update is ignored"
}

test_a_live_update_keeps_dispatch_picks_that_still_apply() {
  command -v node >/dev/null 2>&1 || { echo "skip: node not found (DOM harness)"; return 0; }
  local dir="$TMP_ROOT/live-dispatch" out row1 row2
  mkdir -p "$dir"
  row1='{"id":"queued-one","repo":"sample","title":"Queued one","reason":"","dispatchable":true}'
  row2='{"id":"queued-two","repo":"sample","title":"Queued two","reason":"","dispatchable":true}'
  write_live_dom_payload "$dir/start.json" 2026-09-30T07:00:00Z live-refresh '[]' "[$row1]"
  write_live_dom_payload "$dir/more.json" 2026-09-30T07:01:30Z live-refresh '[]' "[$row1,$row2]"
  write_live_dom_payload "$dir/gone.json" 2026-09-30T07:03:00Z live-refresh '[]' "[$row2]"

  out=$(run_live_dom live-dispatch 1 "$dir/start.json" "$dir/more.json" 2>&1) \
    || fail "the DOM harness crashed on a live update after a dispatch pick: $out"
  printf '%s' "$out" | jq -e '.picks == ["queued-one"] and .barQueued
      and .chartedTitles == ["Queued one", "Queued two"]' >/dev/null \
    || fail "a live update dropped a dispatch pick or its queued mark: $out"

  out=$(run_live_dom live-dispatch 1 "$dir/start.json" "$dir/more.json" "$dir/gone.json" 2>&1) \
    || fail "the DOM harness crashed when a picked row left Charted Next: $out"
  printf '%s' "$out" | jq -e '.picks == [] and (.barQueued | not)' >/dev/null \
    || fail "a pick for a row that left Charted Next survived, or the bar still claims it queued: $out"
  pass "dispatch picks and their queued mark survive a live update while they still apply"
}

test_a_raw_card_and_freshness_are_shown_plainly() {
  command -v node >/dev/null 2>&1 || { echo "skip: node not found (DOM harness)"; return 0; }
  local dir="$TMP_ROOT/live-raw" out raw
  mkdir -p "$dir"
  raw=$(live_card raw-call "New hold, not yet written up" raw)
  write_live_dom_payload "$dir/start.json" 2020-01-01T00:00:00Z live-refresh "[$raw]" '[]' \
    '.prs = [{id: "ship-a", repo: "widget", url: "https://github.com/example/widget/pull/9", state: "done", doing: "checks green"}]'

  out=$(run_live_dom live-queued 1 "$dir/start.json" 2>&1) \
    || fail "the DOM harness crashed on a raw card: $out"
  printf '%s' "$out" | jq -e '.cards[0].badges | index("raw hold reason") != null' >/dev/null \
    || fail "a raw card is not marked as the raw hold reason: $out"
  printf '%s' "$out" | jq -e '.queued == [{question: "raw-call", answer: "my answer", close: "release"}]' >/dev/null \
    || fail "a raw card's free-text answer did not queue with the release close mode: $out"
  printf '%s' "$out" | jq -e '.freshStale and (.fresh | test("has not run"))' >/dev/null \
    || fail "an old live payload was not flagged as out of date: $out"
  printf '%s' "$out" | jq -e '(.prsHidden | not) and .prs == ["widget #9"]' >/dev/null \
    || fail "the open pull requests section did not render: $out"

  write_live_dom_payload "$dir/composed.json" 2020-01-01T00:00:00Z firstmate '[]'
  out=$(run_live_dom live-idle 1 "$dir/composed.json" 2>&1) || fail "the DOM harness crashed: $out"
  printf '%s' "$out" | jq -e '(.freshStale | not) and .prsHidden and .empty' >/dev/null \
    || fail "a firstmate-built board was flagged stale or showed an empty PR section: $out"
  pass "a raw card is marked plainly, old live data is flagged, and the PR list renders"
}

test_path_is_stable_and_home_scoped
test_build_refuses_malformed_payloads_before_touching_the_board
test_build_injects_binds_then_arms
test_registration_cannot_consume_before_any_origin_binding
test_build_does_not_bind_or_arm_when_session_start_fails
test_rebuild_is_idempotent_and_does_not_double_arm
test_build_refuses_a_template_without_exactly_one_slot
test_decision_card_refuses_to_queue_without_a_lavish_bridge
test_dispatch_bar_refuses_to_queue_without_a_lavish_bridge
test_dispatch_bar_clears_a_stale_refusal_once_the_bridge_returns
test_decision_card_drops_its_queued_mark_when_a_later_answer_is_refused
test_dispatch_bar_drops_its_queued_mark_when_a_later_dispatch_is_refused
test_an_option_less_card_is_built_and_answerable_through_its_freeform_box
test_a_decision_card_shows_every_decision_card_element
test_a_throwing_bridge_is_refused_like_a_missing_one
test_changing_the_selection_drops_a_stale_queued_mark
test_build_accepts_an_optional_quota_section_and_refuses_a_malformed_one
test_quota_panel_renders_values_and_says_why_anything_is_unavailable
test_refresh_does_nothing_until_enabled_and_published
test_build_writes_the_live_data_file_and_the_composed_card_store
test_refresh_composes_a_live_payload_without_touching_the_page
test_refresh_drops_a_malformed_stored_card_and_keeps_the_last_data_on_failure
test_refresh_sees_every_open_hold_and_in_flight_task_past_the_snapshot_caps
test_systemd_units_run_refresh_for_this_home
test_systemd_units_escape_quotes_backslashes_and_specifiers
test_a_live_update_keeps_an_unsent_answer_and_its_card
test_a_live_update_keeps_a_queued_answer_until_its_call_closes
test_a_live_update_refreshes_an_idle_card_and_ignores_a_bad_update
test_a_live_update_keeps_dispatch_picks_that_still_apply
test_a_raw_card_and_freshness_are_shown_plainly
