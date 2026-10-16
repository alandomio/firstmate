#!/usr/bin/env bash
# Task teleport between a local home and a remote secondmate home, end to end
# through bin/fm-teleport.sh with real git, real tasks-axi, and the real
# bin/fm-teleport-lib.sh restore path. The worker, the spawn backend, teardown,
# and the SSH route are fixtures under FM_TELEPORT_BIN: fm-on.sh runs the named
# command in the remote home, fm-spawn.sh stands in for a treehouse-backed spawn
# and calls fm_teleport_prepare_worktree exactly as bin/fm-spawn.sh --teleport
# does, and fm-teardown.sh refuses a dirty worktree the way the landed-work
# check would.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-teleport)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
fm_git_identity
FAKE="$TMP_ROOT/fake"
mkdir -p "$FAKE"
export FM_TELEPORT_BIN="$FAKE"
export FM_TELEPORT_PROBE="$FAKE/probe"
export FM_TELEPORT_IDLE_WAIT=2 FM_TELEPORT_LAUNCH_WAIT=2
export FAKE_LOG="$TMP_ROOT/calls.log"
export FM_TEST_ROOT="$ROOT"

cat > "$FAKE/probe" <<'SH'
#!/usr/bin/env bash
case "$1" in
  busy) printf 'idle\n' ;;
  agent) if [ -f "$FM_HOME/state/$2.meta" ] && [ ! -f "$FM_HOME/state/$2.dead" ]; then printf 'alive\n'; else printf 'dead\n'; fi ;;
esac
SH
cat > "$FAKE/fm-control.sh" <<'SH'
#!/usr/bin/env bash
printf 'control %s %s %s\n' "$FM_HOME" "$1" "$2" >> "$FAKE_LOG"
SH
cat > "$FAKE/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_CREW_STATE:-state: working · source: pane}"
SH
cat > "$FAKE/fm-on.sh" <<'SH'
#!/usr/bin/env bash
[ "$1" = "$FAKE_SECONDMATE" ] || { echo "error: no route $1" >&2; exit 1; }
shift
printf 'on %s\n' "$*" >> "$FAKE_LOG"
FM_HOME="$FAKE_REMOTE_HOME" CLAUDE_CONFIG_DIR="$FAKE_REMOTE_CLAUDE" exec "$FM_TEST_ROOT/bin/$1" "${@:2}"
SH
cat > "$FAKE/fm-backlog-handoff.sh" <<'SH'
#!/usr/bin/env bash
printf 'handoff %s %s\n' "$1" "$2" >> "$FAKE_LOG"
[ -z "${FAKE_HANDOFF_FAIL:-}" ] || exit 1
tasks-axi mv "$2" --file "$FM_HOME/data/backlog.md" --to "$FAKE_REMOTE_HOME/data/backlog.md" >/dev/null
SH
cat > "$FAKE/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
# Stand-in for a treehouse-backed fm-spawn.sh --teleport.
set -eu
printf 'spawn %s %s\n' "$FM_HOME" "$*" >> "$FAKE_LOG"
[ -z "${FAKE_SPAWN_FAIL:-}" ] || { echo "error: no backend" >&2; exit 1; }
id=$1 proj=$2 harness='' kind=ship mode='' yolo=''
shift 2
while [ "$#" -gt 0 ]; do
  case "$1" in
    --harness) harness=$2; shift 2 ;;
    --mode) mode=$2; shift 2 ;;
    --yolo) yolo=$2; shift 2 ;;
    --scout) kind=scout; shift ;;
    --model|--effort|--advisor) shift 2 ;;
    --teleport) shift ;;
    *) echo "unexpected $1" >&2; exit 1 ;;
  esac
done
wt="$FM_HOME/pool/$id"
mkdir -p "$FM_HOME/pool"
git -C "$proj" fetch --quiet origin
git -C "$proj" worktree add --quiet --detach "$wt" origin/main
. "$FM_TEST_ROOT/bin/fm-backend.sh"
. "$FM_TEST_ROOT/bin/fm-teleport-lib.sh"
fm_teleport_prepare_worktree "$wt" "$id" "$FM_HOME/data" "$FM_HOME" "$FM_HOME/state"
printf 'worktree=%s\nproject=%s\nharness=%s\nkind=%s\nmode=%s\nyolo=%s\n' "$wt" "$proj" "$harness" "$kind" "$mode" "$yolo" > "$FM_HOME/state/$id.meta"
[ -z "${FAKE_SPAWN_DEAD:-}" ] || : > "$FM_HOME/state/$id.dead"
echo "spawned $id"
SH
cat > "$FAKE/fm-teardown.sh" <<'SH'
#!/usr/bin/env bash
# Refuses uncommitted work like the real landed-work check, then returns the worktree.
printf 'teardown %s %s\n' "$FM_HOME" "$1" >> "$FAKE_LOG"
meta="$FM_HOME/state/$1.meta"
wt=$(sed -n 's/^worktree=//p' "$meta")
proj=$(sed -n 's/^project=//p' "$meta")
[ -z "$(git -C "$wt" status --porcelain)" ] || { echo "refusing: uncommitted work in $wt" >&2; exit 1; }
git -C "$wt" branch -r --contains HEAD | grep -q . || { echo "refusing: HEAD not on any remote" >&2; exit 1; }
git -C "$proj" worktree remove --force "$wt"
rm -f "$meta" "$FM_HOME/state/$1.dead"
SH
chmod +x "$FAKE"/*

# --- fixture: one origin, a local home and a remote home each with a clone ----

ORIGIN="$TMP_ROOT/origin.git"
SEED="$TMP_ROOT/seed"
fm_git_init_commit "$SEED"
printf 'ignored.log\n' > "$SEED/.gitignore"
git -C "$SEED" add .gitignore && git -C "$SEED" commit -qm ignore
git -C "$SEED" branch -M main
git clone --quiet --bare "$SEED" "$ORIGIN"

LOCAL="$TMP_ROOT/local"
REMOTE="$TMP_ROOT/remote"
export FAKE_REMOTE_HOME="$REMOTE" FAKE_SECONDMATE=alwayson
export FAKE_REMOTE_CLAUDE="$TMP_ROOT/remote-claude"
LOCAL_CLAUDE="$TMP_ROOT/local-claude"
for home in "$LOCAL" "$REMOTE"; do
  mkdir -p "$home/state" "$home/data" "$home/projects"
  git clone --quiet "file://$ORIGIN" "$home/projects/alpha"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
done

# A running local worker: a commit on its branch, a tracked edit, a new file,
# and an ignored file.
new_local_task() { # <task> <harness>
  local task=$1 harness=$2 wt="$LOCAL/pool/$1"
  mkdir -p "$LOCAL/pool"
  git -C "$LOCAL/projects/alpha" worktree add --quiet -b "feat/$task" "$wt" origin/main
  printf 'committed\n' > "$wt/committed.txt"
  git -C "$wt" add committed.txt && git -C "$wt" commit -qm "work on $task"
  printf 'edited\n' >> "$wt/README.md"
  printf 'new\n' > "$wt/untracked.txt"
  printf 'noise\n' > "$wt/ignored.log"
  fm_write_meta "$LOCAL/state/$task.meta" "worktree=$wt" "project=$LOCAL/projects/alpha" \
    "harness=$harness" "kind=ship" "mode=no-mistakes" "yolo=off" "model=default" "effort=high"
  mkdir -p "$LOCAL/data/$task"
  printf 'Report to %s/state/%s.status\nDelivery contract: mode=no-mistakes\n' "$LOCAL" "$task" > "$LOCAL/data/$task/brief.md"
  printf 'context for %s\n' "$task" > "$LOCAL/data/$task/context.md"
  printf 'working: started\n' > "$LOCAL/state/$task.status"
  tasks-axi add "$task" "teleport fixture $task" --start --file "$LOCAL/data/backlog.md" >/dev/null
}

local_tp() { FM_HOME="$LOCAL" CLAUDE_CONFIG_DIR="$LOCAL_CLAUDE" "$ROOT/bin/fm-teleport.sh" "$@"; }
remote_tp() { FM_HOME="$REMOTE" CLAUDE_CONFIG_DIR="$FAKE_REMOTE_CLAUDE" "$ROOT/bin/fm-teleport.sh" "$@"; }
encoded() { printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g'; }

SESSION=0b5c1c97-19bf-962b-0000-teleport0001
new_local_task t1 claude
WT1="$LOCAL/pool/t1"
TRANSCRIPT="$LOCAL_CLAUDE/projects/$(encoded "$WT1")/$SESSION.jsonl"
mkdir -p "$(dirname "$TRANSCRIPT")"
printf '{"cwd":"%s","text":"append to %s/state/t1.status"}\n' "$WT1" "$LOCAL" > "$TRANSCRIPT"
HEAD_BEFORE=$(git -C "$WT1" rev-parse HEAD)

# --- refusal on a dirty remote ------------------------------------------------------

printf 'stray\n' > "$REMOTE/projects/alpha/stray.txt"
: > "$FAKE_LOG"
out=$(local_tp t1 2>&1); rc=$?
expect_code 1 "$rc" "teleport into a dirty remote clone"
assert_contains "$out" "uncommitted changes" "dirty remote refusal names the cause"
assert_no_grep "control" "$FAKE_LOG" "a refused teleport never touches the local worker"
git -C "$WT1" ls-remote --exit-code origin refs/heads/fm/teleport/t1 >/dev/null 2>&1 && fail "a refused teleport pushed a snapshot"
rm -f "$REMOTE/projects/alpha/stray.txt"

fm_write_meta "$REMOTE/state/t1.meta" "worktree=/elsewhere"
out=$(local_tp t1 2>&1); rc=$?
expect_code 1 "$rc" "teleport into a remote that already records the task"
assert_contains "$out" "already records task t1" "duplicate task refusal names the cause"
rm -f "$REMOTE/state/t1.meta"
pass "teleport refuses a dirty or already-occupied remote before touching the worker"

# --- failure leaves the local task intact ---------------------------------------------

: > "$FAKE_LOG"
out=$(FAKE_SPAWN_FAIL=1 local_tp t1 2>&1); rc=$?
expect_code 1 "$rc" "teleport whose remote launch fails"
assert_contains "$out" "stays here" "launch failure reports the task stays local"
assert_present "$LOCAL/state/t1.meta" "local record survives a failed teleport"
assert_present "$TRANSCRIPT" "local transcript survives a failed teleport"
assert_grep "edited" "$WT1/README.md" "local uncommitted edit survives a failed teleport"
assert_present "$WT1/untracked.txt" "local untracked file survives a failed teleport"
[ "$(git -C "$WT1" rev-parse HEAD)" = "$HEAD_BEFORE" ] || fail "a failed teleport moved the worker's HEAD"
[ "$(git -C "$WT1" symbolic-ref --short HEAD)" = feat/t1 ] || fail "a failed teleport moved the worker off its branch"
assert_grep "control $LOCAL t1 interrupt" "$FAKE_LOG" "the worker is interrupted before packing"
assert_no_grep "control $LOCAL t1 exit" "$FAKE_LOG" "a failed teleport never stops the local worker"
assert_no_grep "teardown" "$FAKE_LOG" "a failed teleport never tears anything down"
assert_absent "$REMOTE/state/t1.meta" "the remote keeps no record of a failed adoption"
assert_absent "$REMOTE/data/t1" "the remote keeps no task data from a failed adoption"
assert_absent "$REMOTE/state/teleport/t1/in" "the remote keeps no half-finished receipt"
backlog_line=$(tasks-axi show t1 --file "$LOCAL/data/backlog.md" 2>&1 || true)
assert_contains "$backlog_line" "t1" "the backlog item stays local after a failed teleport"
pass "a failed teleport leaves the local task intact and runnable"

# --- WIP ref creation -------------------------------------------------------------

WIP=$(git -C "$WT1" ls-remote origin refs/heads/fm/teleport/t1 | awk '{print $1}')
[ -n "$WIP" ] || fail "pack pushed no fm/teleport/t1 ref"
[ "$(git -C "$WT1" rev-parse "$WIP^1")" = "$HEAD_BEFORE" ] || fail "the WIP snapshot is not a child of the worker's HEAD"
git -C "$WT1" show "$WIP:README.md" | grep -q edited || fail "the WIP snapshot lacks the tracked edit"
git -C "$WT1" show "$WIP:untracked.txt" >/dev/null 2>&1 || fail "the WIP snapshot lacks the untracked file"
git -C "$WT1" show "$WIP:ignored.log" >/dev/null 2>&1 && fail "the WIP snapshot carried an ignored file"
msg=$(git -C "$WT1" log -1 --format=%B "$WIP")
assert_contains "$msg" "Firstmate-Teleport: t1" "the snapshot names its task"
assert_contains "$msg" "Teleport-Branch: feat/t1" "the snapshot names the worker's branch"
pass "pack snapshots tracked and untracked work onto fm/teleport/<task> without moving the worker"

# --- successful outbound teleport, Claude transcript resumed -------------------------

: > "$FAKE_LOG"
out=$(local_tp t1 2>&1) || fail "teleport out failed: $out"
assert_contains "$out" "teleported t1 to alwayson" "teleport reports the destination"
RWT="$REMOTE/pool/t1"
assert_present "$REMOTE/state/t1.meta" "the remote records the adopted task"
[ "$(git -C "$RWT" symbolic-ref --short HEAD)" = feat/t1 ] || fail "the remote worker is not on the task's branch"
[ "$(git -C "$RWT" rev-parse HEAD)" = "$HEAD_BEFORE" ] || fail "the remote branch does not sit at the worker's last commit"
assert_grep "edited" "$RWT/README.md" "the tracked edit arrived uncommitted"
assert_present "$RWT/untracked.txt" "the untracked file arrived"
git -C "$RWT" diff --quiet && fail "the carried edit was committed instead of left uncommitted"
assert_grep "--teleport" "$FAKE_LOG" "the remote worker launches through fm-spawn --teleport"
assert_grep "--mode no-mistakes --yolo off --harness claude --effort high" "$FAKE_LOG" "the remote spawn keeps the delivery contract and profile"
RTRANSCRIPT="$FAKE_REMOTE_CLAUDE/projects/$(encoded "$RWT")/$SESSION.jsonl"
assert_present "$RTRANSCRIPT" "the transcript is installed for the remote worktree"
assert_grep "\"cwd\":\"$RWT\"" "$RTRANSCRIPT" "the transcript's worktree path is mapped"
assert_grep "$REMOTE/state/t1.status" "$RTRANSCRIPT" "the transcript's home path is mapped"
assert_grep "$RWT" "$REMOTE/data/t1/teleport/arrival.md" "the arrival note names the new worktree"
assert_grep "$REMOTE/state/t1.status" "$REMOTE/data/t1/brief.md" "the brief's paths are mapped to the remote home"
assert_present "$REMOTE/data/t1/context.md" "the task's other records travel"
assert_absent "$TRANSCRIPT" "the local transcript is deleted after takeover"
assert_absent "$LOCAL/state/t1.meta" "the local copy is torn down after takeover"
assert_absent "$WT1" "the local worktree is returned after takeover"
assert_grep "control $LOCAL t1 exit" "$FAKE_LOG" "the local worker is stopped after takeover"
git -C "$LOCAL/projects/alpha" ls-remote --exit-code origin refs/heads/fm/teleport/t1 >/dev/null 2>&1 && fail "the WIP ref was left on origin"
tasks-axi show t1 --file "$REMOTE/data/backlog.md" >/dev/null 2>&1 || fail "the backlog item did not move to the remote"
tasks-axi show t1 --file "$LOCAL/data/backlog.md" >/dev/null 2>&1 && fail "the backlog item stayed in the local backlog"
grep -A3 '^## In flight' "$REMOTE/data/backlog.md" | grep -q 't1' || fail "the remote backlog does not show t1 in flight"
pass "teleport out moves work, records, transcript, and backlog item to the remote and cleans up here"

# --- back-teleport -------------------------------------------------------------------

printf 'more remote work\n' >> "$RWT/remote.txt"
: > "$FAKE_LOG"
out=$(local_tp t1 --back 2>&1) || fail "teleport back failed: $out"
assert_contains "$out" "teleported t1 back from alwayson" "back-teleport reports its source"
BWT="$LOCAL/pool/t1"
assert_present "$LOCAL/state/t1.meta" "the local home records the returned task"
assert_present "$BWT/remote.txt" "work done on the remote comes back"
assert_grep "edited" "$BWT/README.md" "earlier uncommitted work comes back"
[ "$(git -C "$BWT" symbolic-ref --short HEAD)" = feat/t1 ] || fail "the returned worker is not on its branch"
assert_present "$LOCAL_CLAUDE/projects/$(encoded "$BWT")/$SESSION.jsonl" "the transcript comes back for the local worktree"
assert_absent "$RTRANSCRIPT" "the remote transcript is deleted after the return"
assert_absent "$REMOTE/state/t1.meta" "the remote copy is torn down after the return"
assert_grep "control $REMOTE t1 interrupt" "$FAKE_LOG" "the remote worker is interrupted before packing"
assert_grep "$LOCAL/state/t1.status" "$LOCAL/data/t1/brief.md" "the brief's paths map back to the local home"
tasks-axi show t1 --file "$LOCAL/data/backlog.md" >/dev/null 2>&1 || fail "the backlog item did not come back"
tasks-axi show t1 --file "$REMOTE/data/backlog.md" >/dev/null 2>&1 && fail "the backlog item stayed on the remote"
pass "teleport --back reverses the move"

# --- non-Claude fallback ----------------------------------------------------------------

new_local_task t2 codex
: > "$FAKE_LOG"
out=$(local_tp t2 2>&1) || fail "codex teleport failed: $out"
assert_grep "--harness codex" "$FAKE_LOG" "a codex task relaunches on codex"
assert_absent "$REMOTE/data/t2/teleport/arrival.md" "a codex task gets no resume arrival note"
assert_grep "## Teleport note" "$REMOTE/data/t2/brief.md" "a codex task's brief carries a progress note"
assert_grep "work on t2" "$REMOTE/data/t2/brief.md" "the progress note lists recent commits"
assert_grep "untracked.txt" "$REMOTE/data/t2/brief.md" "the progress note lists carried uncommitted files"
assert_grep "working: started" "$REMOTE/data/t2/brief.md" "the progress note carries the last status lines"
session=$(sed -n 's/^session=//p' "$REMOTE/data/t2/teleport/manifest")
[ -z "$session" ] || fail "a codex manifest promised a session"
pass "a non-Claude task relaunches from its brief plus a generated progress note"

# A Claude task with no transcript falls back the same way.
new_local_task t3 claude
out=$(local_tp t3 2>&1) || fail "transcript-less claude teleport failed: $out"
assert_contains "$out" "no Claude transcript" "a missing transcript is reported"
assert_grep "## Teleport note" "$REMOTE/data/t3/brief.md" "a transcript-less Claude task gets a progress note"
pass "a Claude task without a transcript falls back to brief plus progress note"

# --- guards ------------------------------------------------------------------------------

new_local_task t4 claude
out=$(FAKE_CREW_STATE='state: working · source: run-step · step=review' local_tp t4 2>&1); rc=$?
expect_code 1 "$rc" "teleport during an active validation run"
assert_contains "$out" "active validation run" "validation-run refusal names the cause"
WIP4=$(git -C "$LOCAL/pool/t4" ls-remote origin refs/heads/fm/teleport/t4)
[ -z "$WIP4" ] || fail "a refused pack pushed a snapshot"
pass "teleport refuses mid-validation"

# abort never rolls back a task this home did not adopt.
out=$(local_tp abort t4 2>&1); rc=$?
expect_code 1 "$rc" "abort of a task that was never adopted"
assert_present "$LOCAL/state/t4.meta" "abort leaves a native task alone"
pass "abort refuses a task this home did not adopt"

# --- sleep reminder ---------------------------------------------------------------------

REC="$TMP_ROOT/alerts.log"
cat > "$FAKE/alert" <<SH
#!/usr/bin/env bash
printf '%s|%s\n' "\$1" "\$2" >> "$REC"
SH
chmod +x "$FAKE/alert"
out=$(FM_WEDGE_ALARM_EXEC="$FAKE/alert" FM_WEDGE_ALARM_CHANNEL=herdr local_tp remind 2>&1) || fail "remind failed: $out"
assert_contains "$out" "2 tasks running, teleport out?" "remind counts live local workers"
assert_grep "herdr|2 tasks running, teleport out?" "$REC" "remind notifies through the configured channel"
: > "$REC"
FM_WEDGE_ALARM_EXEC="$FAKE/alert" FM_WEDGE_ALARM_CHANNEL=herdr local_tp remind >/dev/null 2>&1
[ ! -s "$REC" ] || fail "remind did not rate-limit a second notification"
rm -f "$LOCAL/state/.teleport-reminded" "$LOCAL/state"/*.meta
FM_WEDGE_ALARM_EXEC="$FAKE/alert" FM_WEDGE_ALARM_CHANNEL=herdr local_tp remind >/dev/null 2>&1
[ ! -s "$REC" ] || fail "remind notified with no running workers"
pass "remind raises one rate-limited notification only while workers run"

# --- fm-spawn --teleport refusals -------------------------------------------------------

SPAWN_HOME="$TMP_ROOT/spawn-home"
mkdir -p "$SPAWN_HOME/state" "$SPAWN_HOME/data"
spawn_refusal() { # <expected-text> <args...>
  local want=$1 out rc
  shift
  # An unknown backend stops any spawn that slips past the refusal before an
  # endpoint could exist.
  out=$(FM_SPAWN_NO_GUARD=1 FM_BACKEND=fm-teleport-test-none FM_HOME="$SPAWN_HOME" "$ROOT/bin/fm-spawn.sh" "$@" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "fm-spawn accepted: $*"
  assert_contains "$out" "$want" "fm-spawn $* refusal"
}
spawn_refusal "cannot be combined with --relaunch" t9 --relaunch --teleport
spawn_refusal "not --secondmate" t9 "$SPAWN_HOME" --secondmate --teleport
spawn_refusal "never a batch" a=b c=d --scout --teleport
pass "fm-spawn refuses --teleport with relaunch, secondmate, or batch spawns"
