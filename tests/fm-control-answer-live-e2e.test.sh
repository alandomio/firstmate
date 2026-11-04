#!/usr/bin/env bash
# Live guard for fm-control's `prompt` and `answer` verbs (live-harness-optin
# family).
#
# Whether a confirmation prompt is showing is read from Claude Code's rendered
# screen, and whether one digit answers it is a key Claude binds, so a stub can
# only confirm what its fixture already says. This guard launches real Claude
# Code in an isolated Herdr lab, asks it to run two shell commands in default
# permission mode, and drives both permission prompts through bin/fm-control.sh:
# it approves the first with option 1, refuses a stale sha on the second
# without sending anything, then declines the second with its "No" option.
# The files the commands create prove which answers landed.
# It fails naming the harness and Herdr versions rather than degrading quietly.
#
# Opt-in, because it submits a prompt to a model: run it with
# FM_CONTROL_ANSWER_LIVE=1 after a Claude Code or Herdr upgrade, and before
# trusting a refreshed docs/verification/runtime-backends.md "Claude
# confirmation prompts" entry. The checkout it runs from must already be a
# trusted Claude folder; the guard refuses rather than accept the trust dialog.
# Every Herdr call, including the adapter's, is routed through bin/fm-herdr-lab.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate opt-in FM_CONTROL_ANSWER_LIVE herdr jq claude

[ -x "$LAB_HELPER" ] || fail "FM_CONTROL_ANSWER_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name control-answer-live)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-control-answer-live.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$FAKEBIN" "$HOME_DIR/state" "$HOME_DIR/data"

cleanup() {
  local rc=$?
  trap - EXIT
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

# Every herdr call made by the adapter must name this lab session, and is
# re-routed through the guarded lab helper.
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session $SESSION" >&2
  exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
export PATH="$FAKEBIN:$ORIGINAL_PATH"
export HERDR_SESSION="$SESSION"

VERSION=$(PATH="$ORIGINAL_PATH" claude --version 2>/dev/null | head -1 || printf 'version-unknown')
HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')
where="Claude Code ($VERSION) on $HERDR_VER"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }

WS_JSON=$(lab workspace create --cwd "$ROOT" --label fm-ansl --no-focus) \
  || fail "could not create the isolated answer workspace"
PANE_ID=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a pane id: $WS_JSON"
WORKSPACE_ID=$(printf '%s' "$WS_JSON" | jq -er '.result.workspace.workspace_id // .result.root_pane.workspace_id') \
  || fail "workspace create did not return a workspace id: $WS_JSON"
TAB_ID=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.tab_id // .result.tab.tab_id') \
  || fail "workspace create did not return a tab id: $WS_JSON"
{
  echo "window=$SESSION:$PANE_ID"
  echo "endpoint_task_id=ansl"
  echo "worktree=$ROOT"
  echo "project=$ROOT"
  echo "harness=claude"
  echo "kind=ship"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE_ID"
} > "$HOME_DIR/state/ansl.meta"

FIRST="$TMP_ROOT/first-approved"
SECOND="$TMP_ROOT/second-declined"
# Default permission mode, no user or project settings (their hooks would gate
# the tool call), no MCP servers, and the cheapest model.
lab pane run "$PANE_ID" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --setting-sources local --strict-mcp-config --permission-mode default --model haiku 'Use the Bash tool twice, one command per call, in this order, and nothing else: touch $FIRST then touch $SECOND'" >/dev/null \
  || fail "could not launch $where in the lab pane"

run_control() {
  env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_CONTROL_POLL=0.5 FM_CONTROL_ANSWER_WAIT=15 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

# wait_prompt <label>: poll `prompt` until it reports a prompt. Sets PROMPT_OUT.
wait_prompt() {
  local i=0 screen
  while [ "$i" -lt 90 ]; do
    if PROMPT_OUT=$(run_control ansl prompt); then
      return 0
    fi
    screen=$(lab pane read "$PANE_ID" --source visible 2>/dev/null || true)
    case "$screen" in
      *'Yes, I trust this folder'*|*'Allow external CLAUDE.md file imports'*)
        fail "$where stopped on a folder consent dialog for $ROOT; run this guard from a checkout already trusted in Claude, it will not answer that dialog"
        ;;
    esac
    i=$((i + 1))
    sleep 1
  done
  fail "$where never showed the $1 permission prompt that fm-control prompt could read; last read: $PROMPT_OUT"
}

wait_prompt first
SHA=$(printf '%s' "$PROMPT_OUT" | jq -er .sha) || fail "prompt did not print a sha: $PROMPT_OUT"
printf '%s' "$PROMPT_OUT" | jq -er '.prompt | contains("first-approved")' >/dev/null \
  || fail "$where: the first prompt text should name the command being approved: $PROMPT_OUT"
OUT=$(run_control ansl answer 1 --expect-prompt-sha "$SHA") \
  || fail "$where: answer 1 to the first prompt failed: $OUT"
case "$OUT" in *"prompt=gone"*) ;; *) fail "$where: answer did not confirm the prompt left: $OUT" ;; esac
i=0
while [ ! -e "$FIRST" ] && [ "$i" -lt 30 ]; do i=$((i + 1)); sleep 1; done
[ -e "$FIRST" ] || fail "$where: option 1 was reported delivered but the approved command never ran"
pass "live answer: $where approves a permission prompt with its option digit through fm-control"

wait_prompt second
SHA2=$(printf '%s' "$PROMPT_OUT" | jq -er .sha) || fail "prompt did not print a sha: $PROMPT_OUT"
[ "$SHA2" != "$SHA" ] || fail "$where: two prompts for different commands share a sha"
OUT=$(run_control ansl answer 1 --expect-prompt-sha "$SHA") \
  && fail "$where: answer with the first prompt's sha must refuse on the second prompt: $OUT"
case "$OUT" in *"prompt changed since it was shown"*) ;; *) fail "$where: a stale sha should refuse as a changed prompt: $OUT" ;; esac
run_control ansl prompt >/dev/null || fail "$where: the refused answer must leave the second prompt showing"
NO=$(printf '%s' "$PROMPT_OUT" | jq -er '[.options[] | select(.label == "No")][0].option') \
  || fail "$where: the second prompt shows no option labelled No: $PROMPT_OUT"
OUT=$(run_control ansl answer "$NO" --expect-prompt-sha "$SHA2") \
  || fail "$where: answer $NO to the second prompt failed: $OUT"
sleep 3
[ ! -e "$SECOND" ] || fail "$where: the declined command ran anyway"
pass "live answer: $where refuses a stale sha and declines a prompt with its No option"

STATUS=$(cat "$HOME_DIR/state/ansl.status" 2>/dev/null || true)
[ "$(printf '%s\n' "$STATUS" | grep -c 'fm-control answered the on-screen prompt')" = 2 ] \
  || fail "both delivered answers should be logged in the task's status file, got: $STATUS"
pass "live answer: both delivered answers are logged and the refused one is not"
