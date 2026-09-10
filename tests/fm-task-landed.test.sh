#!/usr/bin/env bash
# tests/fm-task-landed.test.sh - fm-task-landed.sh's verdicts against real git
# fixtures: a local repo, a bare file:// origin, and a task worktree, with fake
# gh/glab standing in for the forge so no case touches the network.
#
# The cases pin the distinctions the script exists to keep apart: tracked work
# versus untracked leftovers (and leftovers versus untracked files that may be
# unadded work), a deleted remote branch that landed versus one that cannot be
# proven, the no-mistakes gate remote never counting as a landing, and a read
# that must not rewrite the worktree index.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-task-landed.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-landed)
BASE_PATH=$PATH
fm_git_identity

# Fake forge CLIs: print FM_TEST_PR_JSON, exit FM_TEST_FORGE_RC, and log every
# invocation to FM_TEST_FORGE_LOG so a case can assert whether one happened.
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
for tool in gh glab; do
  cat > "$FAKEBIN/$tool" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >> "${FM_TEST_FORGE_LOG:-/dev/null}"
cat "${FM_TEST_PR_JSON:-/dev/null}"
exit "${FM_TEST_FORGE_RC:-0}"
SH
  chmod +x "$FAKEBIN/$tool"
done

# new_case <name> <branch>: fresh home, repo with a bare origin, and a task
# worktree on <branch>. Sets C_DIR C_HOME C_REPO C_WT MAIN.
new_case() {
  C_DIR="$TMP_ROOT/$1" C_HOME="$TMP_ROOT/$1/home" C_REPO="$TMP_ROOT/$1/repo" C_WT="$TMP_ROOT/$1/wt"
  mkdir -p "$C_HOME/state"
  fm_git_worktree "$C_REPO" "$C_WT" "$2" >/dev/null 2>&1 || fail "fixture $1: worktree setup"
  MAIN=$(git -C "$C_REPO" symbolic-ref --short HEAD)
  git -C "$C_REPO" fetch -q origin || fail "fixture $1: fetch"
  git -C "$C_REPO" remote set-head origin "$MAIN" >/dev/null || fail "fixture $1: set-head"
}

wt_commit() {  # <file> <content>
  printf '%s\n' "$2" > "$C_WT/$1"
  if ! git -C "$C_WT" add "$1" || ! git -C "$C_WT" commit -qm "change $1"; then
    fail "commit $1"
  fi
}

meta() {  # <id> <key=val>...
  local id=$1
  shift
  fm_write_meta "$C_HOME/state/$id.meta" "$@"
}

# run_tl <home> [args...]: sets OUT (stdout+stderr) and RC.
run_tl() {
  local home=$1
  shift
  OUT=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$home" "$SCRIPT" "$@" 2>&1)
  RC=$?
}

expect_rc() {  # <want> <msg>
  [ "$RC" -eq "$1" ] || fail "$2: exit $RC, want $1; output: $OUT"
}

# --- 1. clean landed: every commit pushed, nothing dirty -------------------
new_case clean fm/clean
wt_commit a.txt one
git -C "$C_WT" push -q origin fm/clean || fail "push"
meta clean "worktree=$C_WT" kind=ship
run_tl "$C_HOME" clean
expect_rc 0 "clean"
assert_contains "$OUT" "LANDED-CLEAN" "clean: verdict"
assert_contains "$OUT" "work:  0 unpushed,  0 tracked" "clean: work counts"
assert_contains "$OUT" "leftovers:  0 untracked,  0 only here" "clean: leftover counts"
pass "clean landed task is LANDED-CLEAN"

# --- 2. unpushed commits are work at risk ----------------------------------
new_case unpushed fm/unpushed
wt_commit a.txt one
wt_commit b.txt two
meta unpushed "worktree=$C_WT" kind=ship
run_tl "$C_HOME" unpushed
expect_rc 0 "unpushed"
assert_contains "$OUT" "UNLANDED-WORK" "unpushed: verdict"
assert_contains "$OUT" "work:  2 unpushed,  0 tracked" "unpushed: counts both commits"
pass "unpushed commits are UNLANDED-WORK"

# --- 3. a tracked modification is work, counted apart from leftovers --------
new_case tracked fm/tracked
printf 'edited\n' >> "$C_WT/README.md"
printf 'x\n' > "$C_WT/stray.log"
printf 'x\n' > "$C_REPO/stray.log"
meta tracked "worktree=$C_WT" kind=ship
run_tl "$C_HOME" tracked -v
assert_contains "$OUT" "UNLANDED-WORK" "tracked: verdict"
assert_contains "$OUT" "work:  0 unpushed,  1 tracked  |  leftovers:  1 untracked" "tracked: work and leftovers stay separate"
assert_contains "$OUT" "WORK tracked:  M README.md" "tracked: -v names the tracked change as work"
assert_contains "$OUT" "leftover (untracked here and in a sibling worktree): stray.log" "tracked: -v names the leftover apart"
pass "tracked change is work and is never folded into the leftover count"

# --- 4. leftovers only: the untracked debris also sits in a sibling worktree
new_case leftovers fm/leftovers
wt_commit a.txt one
git -C "$C_WT" push -q origin fm/leftovers || fail "push"
for d in "$C_WT" "$C_REPO"; do
  mkdir -p "$d/chatbot-service/lib" && printf 'x\n' > "$d/chatbot-service/app.py"
  printf 'y\n' > "$d/chatbot-service/lib/util.py"
  printf 'x\n' > "$d/docker-compose.test.yaml"
done
meta leftovers "worktree=$C_WT" kind=ship
run_tl "$C_HOME" leftovers
expect_rc 0 "leftovers"
assert_contains "$OUT" "LEFTOVERS-ONLY" "leftovers: verdict"
assert_contains "$OUT" "work:  0 unpushed,  0 tracked  |  leftovers:  2 untracked,  0 only here" "leftovers: counts"
pass "shared untracked debris alone is LEFTOVERS-ONLY, not work"

# --- 5. an untracked file found in no sibling may be unadded work -----------
new_case onlyhere fm/onlyhere
wt_commit a.txt one
git -C "$C_WT" push -q origin fm/onlyhere || fail "push"
printf 'new feature\n' > "$C_WT/new-feature.sh"
meta onlyhere "worktree=$C_WT" kind=ship
run_tl "$C_HOME" onlyhere -v
expect_rc 1 "onlyhere"
assert_contains "$OUT" "UNKNOWN" "onlyhere: cannot tell, says so"
assert_not_contains "$OUT" "LEFTOVERS-ONLY" "onlyhere: never calls possible work a leftover"
assert_contains "$OUT" "leftovers:  1 untracked,  1 only here" "onlyhere: counts"
assert_contains "$OUT" "UNTRACKED ONLY HERE (may be work never added): new-feature.sh" "onlyhere: -v flags the path"
pass "untracked path in no sibling worktree is UNKNOWN, not a leftover"

# --- 5b. a debris directory name in a sibling does not cover a new file in it
new_case dirmix fm/dirmix
wt_commit a.txt one
git -C "$C_WT" push -q origin fm/dirmix || fail "push"
for d in "$C_WT" "$C_REPO"; do
  mkdir -p "$d/svc" && printf 'debris\n' > "$d/svc/old.py"
done
printf 'handler\n' > "$C_WT/svc/new_handler.py"
meta dirmix "worktree=$C_WT" kind=ship
run_tl "$C_HOME" dirmix -v
expect_rc 1 "dirmix"
assert_contains "$OUT" "UNKNOWN" "dirmix: cannot tell, says so"
assert_not_contains "$OUT" "LEFTOVERS-ONLY" "dirmix: the worker's file is never called a leftover"
assert_contains "$OUT" "leftovers:  1 untracked,  1 only here" "dirmix: the collapsed entry counts once"
assert_contains "$OUT" "UNTRACKED ONLY HERE (may be work never added): svc/" "dirmix: -v flags the entry"
assert_contains "$OUT" "file only here (no identical untracked copy in a sibling): svc/new_handler.py" "dirmix: -v names the new file"
assert_not_contains "$OUT" "svc/old.py" "dirmix: the proven debris file is not flagged"
pass "a new file inside a same-named debris directory is UNKNOWN and named"

# --- 5c. a same-named file with different content in the sibling -----------
new_case differ fm/differ
wt_commit a.txt one
git -C "$C_WT" push -q origin fm/differ || fail "push"
printf 'services: {}\n' > "$C_REPO/docker-compose.test.yaml"
printf 'services: {worker: {}}\n' > "$C_WT/docker-compose.test.yaml"
meta differ "worktree=$C_WT" kind=ship
run_tl "$C_HOME" differ -v
expect_rc 1 "differ"
assert_contains "$OUT" "UNKNOWN" "differ: cannot tell, says so"
assert_contains "$OUT" "leftovers:  1 untracked,  1 only here" "differ: counted only here"
assert_contains "$OUT" "UNTRACKED ONLY HERE (may be work never added): docker-compose.test.yaml" "differ: -v flags it"
pass "an untracked file whose sibling copy differs is only here"

# --- 5d. a bare primary is not a sibling checkout ---------------------------
C_DIR="$TMP_ROOT/bare" C_HOME="$TMP_ROOT/bare/home" C_WT="$TMP_ROOT/bare/wt"
mkdir -p "$C_HOME/state"
fm_git_init_commit "$C_DIR/src" >/dev/null 2>&1 || fail "fixture bare: source repo"
git init -q --bare "$C_DIR/primary.git" || fail "fixture bare: init"
git -C "$C_DIR/primary.git" remote add origin "$C_DIR/src" || fail "fixture bare: remote"
git -C "$C_DIR/primary.git" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
git -C "$C_DIR/primary.git" fetch -q origin || fail "fixture bare: fetch"
BARE_MAIN=$(git -C "$C_DIR/src" symbolic-ref --short HEAD)
git -C "$C_DIR/primary.git" worktree add -q -b fm/bare "$C_WT" "origin/$BARE_MAIN" >/dev/null 2>&1 || fail "fixture bare: worktree"
mkdir -p "$C_WT/config" && printf 'key: value\n' > "$C_WT/config/new.yaml"
meta bare "worktree=$C_WT" kind=ship
run_tl "$C_HOME" bare -v
expect_rc 1 "bare"
assert_contains "$OUT" "UNKNOWN" "bare: cannot tell, says so"
assert_not_contains "$OUT" "LEFTOVERS-ONLY" "bare: the bare repo's own config never makes config/ debris"
assert_contains "$OUT" "leftovers:  1 untracked,  1 only here" "bare: counted only here"
pass "untracked entries matching a bare primary's files are UNKNOWN, not leftovers"

# --- 6a. remote branch gone after a merge: landed, and no ambiguous-arg error
new_case gone fm/gone
wt_commit a.txt one
git -C "$C_WT" push -q -u origin fm/gone || fail "push"
git -C "$C_REPO" push -q origin "fm/gone:$MAIN" || fail "merge on origin"
git -C "$C_REPO" push -q origin --delete fm/gone || fail "delete remote branch"
git -C "$C_REPO" fetch -q --prune origin || fail "prune"
git -C "$C_REPO" rev-parse -q --verify refs/remotes/origin/fm/gone >/dev/null && fail "gone: fixture still has the remote ref"
meta gone "worktree=$C_WT" kind=ship
run_tl "$C_HOME" gone -v
expect_rc 0 "gone"
assert_contains "$OUT" "LANDED-CLEAN" "gone: merged work is landed"
assert_contains "$OUT" "own remote ref: gone" "gone: reports the deleted remote ref"
assert_not_contains "$OUT" "fatal" "gone: no git error escapes"
pass "deleted remote branch whose work merged is LANDED-CLEAN without erroring"

# --- 6b. squash-merged then deleted: commits on no remote, content in main --
new_case squash fm/squash
wt_commit a.txt one
wt_commit b.txt two
git -C "$C_WT" push -q -u origin fm/squash || fail "push"
git -C "$C_REPO" merge -q --squash fm/squash >/dev/null || fail "squash"
git -C "$C_REPO" commit -qm squashed || fail "squash commit"
git -C "$C_REPO" push -q origin "$MAIN" || fail "push main"
git -C "$C_REPO" push -q origin --delete fm/squash || fail "delete remote branch"
git -C "$C_REPO" fetch -q --prune origin || fail "prune"
meta squash "worktree=$C_WT" kind=ship
run_tl "$C_HOME" squash --no-remote
expect_rc 0 "squash"
assert_contains "$OUT" "LANDED-CLEAN" "squash: content in the default branch is landed"
assert_contains "$OUT" "work:  2 unpushed" "squash: the raw unpushed count is still shown"
assert_contains "$OUT" "already in origin/$MAIN" "squash: the note says why"
pass "squash-merged branch with its remote ref gone is LANDED-CLEAN by content"

# --- 6c. remote branch gone and nothing proves the work landed -------------
new_case unproven fm/unproven
wt_commit a.txt one
git -C "$C_WT" push -q -u origin fm/unproven || fail "push"
git -C "$C_REPO" push -q origin --delete fm/unproven || fail "delete remote branch"
git -C "$C_REPO" fetch -q --prune origin || fail "prune"
meta unproven "worktree=$C_WT" kind=ship
run_tl "$C_HOME" unproven --no-remote
expect_rc 1 "unproven"
assert_contains "$OUT" "UNKNOWN" "unproven: cannot tell, says so"
assert_contains "$OUT" "landing is unproven" "unproven: the note says why"
assert_not_contains "$OUT" "fatal" "unproven: no git error escapes"
pass "deleted remote branch with unproven landing is UNKNOWN"

# --- 7. missing meta, and a worktree that no longer exists ------------------
mkdir -p "$TMP_ROOT/nometa/home/state"
run_tl "$TMP_ROOT/nometa/home" ghost
expect_rc 1 "missing meta"
assert_contains "$OUT" "UNKNOWN" "missing meta: verdict"
assert_contains "$OUT" "no meta at state/ghost.meta" "missing meta: reason"
C_HOME="$TMP_ROOT/nometa/home"
meta vanished "worktree=$TMP_ROOT/nometa/does-not-exist" kind=ship
run_tl "$C_HOME" vanished
expect_rc 0 "vanished"
assert_contains "$OUT" "NO-WORKTREE" "vanished: verdict"
pass "missing meta is UNKNOWN and a vanished worktree is NO-WORKTREE"

# --- 7b. a stale non-git directory nested in another checkout ---------------
new_case nested fm/nested
wt_commit a.txt one
mkdir -p "$C_REPO/wts/gone-task" && printf 'x\n' > "$C_REPO/wts/gone-task/f.txt"
meta nested "worktree=$C_REPO/wts/gone-task" kind=ship
run_tl "$C_HOME" nested
expect_rc 1 "nested"
assert_contains "$OUT" "UNKNOWN" "nested: no verdict about the enclosing repo"
assert_contains "$OUT" "not a git worktree root" "nested: the note names the mismatch"
assert_not_contains "$OUT" "UNLANDED-WORK" "nested: the enclosing repo's commits are not reported"
pass "a directory that is not itself a checkout root is UNKNOWN"

# --- 8. the no-mistakes gate remote is not a landing ------------------------
new_case gate fm/gate
wt_commit a.txt one
git clone -q --bare "$C_REPO" "$C_DIR/gate.git" || fail "gate clone"
git -C "$C_REPO" remote add no-mistakes "file://$C_DIR/gate.git" || fail "gate remote"
git -C "$C_WT" push -q no-mistakes fm/gate || fail "gate push"
meta gate "worktree=$C_WT" kind=ship
run_tl "$C_HOME" gate
assert_contains "$OUT" "UNLANDED-WORK" "gate: gate-only commits are unlanded"
assert_contains "$OUT" "work:  1 unpushed" "gate: counted as unpushed"
assert_contains "$OUT" "no-mistakes gate only" "gate: the note says why"
pass "commits only on the no-mistakes gate remote are UNLANDED-WORK"

# --- 8b. local-only work merged into local main, with origin/HEAD present ---
new_case localff fm/localff
wt_commit a.txt one
git -C "$C_REPO" merge -q --ff-only fm/localff || fail "local ff merge"
meta localff "worktree=$C_WT" kind=ship mode=local-only
run_tl "$C_HOME" localff
expect_rc 0 "localff"
assert_contains "$OUT" "LANDED-CLEAN" "localff: work in local main is landed"
assert_contains "$OUT" "work:  0 unpushed" "localff: local main counts as a landing"

new_case localsq fm/localsq
wt_commit a.txt one
wt_commit b.txt two
git -C "$C_REPO" merge -q --squash fm/localsq >/dev/null || fail "local squash"
git -C "$C_REPO" commit -qm squashed || fail "local squash commit"
meta localsq "worktree=$C_WT" kind=ship mode=local-only
run_tl "$C_HOME" localsq --no-remote
expect_rc 0 "localsq"
assert_contains "$OUT" "LANDED-CLEAN" "localsq: content in local main is landed"
assert_contains "$OUT" "already in local $MAIN" "localsq: the note names local main"
pass "local-only work in the local default branch is landed even with origin/HEAD set"

# --- 9. PR/MR state, and the sweep's network policy -------------------------
new_case pr fm/pr
wt_commit a.txt one
git -C "$C_WT" push -q origin fm/pr || fail "push"
C_PR_HOME=$C_HOME
meta mr "worktree=$C_WT" kind=ship "pr=https://gitlab.example.com/grp/proj/-/merge_requests/7"
meta gh "worktree=$C_WT" kind=ship "pr=https://github.com/o/r/pull/9"
printf '%s\n' '{"iid":7,"state":"opened","draft":false,"has_conflicts":true,"detailed_merge_status":"conflict","sha":"abc","description":"bad"}' > "$C_DIR/mr.json"
printf '%s\n' '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"def"}' > "$C_DIR/gh.json"

FM_TEST_FORGE_LOG="$C_DIR/forge.log" FM_TEST_PR_JSON="$C_DIR/mr.json" run_tl "$C_PR_HOME" mr
expect_rc 0 "mr"
assert_contains "$OUT" "PR-CONFLICT" "mr: open with conflicts"
assert_contains "$OUT" "pr: !7 OPEN CONFLICT" "mr: pr summary"
assert_grep "glab api --hostname gitlab.example.com projects/grp%2Fproj/merge_requests/7" "$C_DIR/forge.log" "mr: glab asked the recorded host and project"

FM_TEST_PR_JSON="$C_DIR/gh.json" run_tl "$C_PR_HOME" gh
expect_rc 0 "gh"
assert_contains "$OUT" "PR-OPEN" "gh: open without conflicts"
assert_contains "$OUT" "pr: #9 OPEN clean" "gh: pr summary"

rm -f "$C_DIR/forge.log"
FM_TEST_FORGE_LOG="$C_DIR/forge.log" FM_TEST_PR_JSON="$C_DIR/gh.json" run_tl "$C_PR_HOME"
expect_rc 0 "sweep"
assert_contains "$OUT" "PR-UNCHECKED" "sweep: PR state not read"
assert_contains "$OUT" "pr: not-checked" "sweep: says it did not check"
assert_absent "$C_DIR/forge.log" "sweep: no forge call without --remote"

FM_TEST_FORGE_RC=1 run_tl "$C_PR_HOME" gh
expect_rc 1 "unreachable"
assert_contains "$OUT" "PR-UNCHECKED" "unreachable: local verdict stands"
assert_contains "$OUT" "#9 UNREACHABLE" "unreachable: no state claimed"
pass "PR/MR state drives PR-CONFLICT/PR-OPEN and the sweep stays offline"

# --- 10. read-only: a stat-dirty worktree's index is not rewritten ----------
new_case readonly fm/readonly
wt_commit a.txt one
git -C "$C_WT" push -q origin fm/readonly || fail "push"
index="$(git -C "$C_WT" rev-parse --absolute-git-dir)/index"
touch -d '2001-01-01' "$index"
before=$(cksum < "$index")
touch "$C_WT/a.txt"
meta readonly "worktree=$C_WT" kind=ship
run_tl "$C_HOME" readonly
expect_rc 0 "readonly"
[ "$(cksum < "$index")" = "$before" ] || fail "readonly: the worktree index was rewritten"
[ -z "$(find "$index" -newermt '2001-01-02')" ] || fail "readonly: the worktree index was touched"
pass "reading a task never rewrites its worktree index"

# --- 11. usage -------------------------------------------------------------
run_tl "$C_HOME" --help
expect_rc 0 "help"
assert_contains "$OUT" "LEFTOVERS-ONLY" "help: documents the verdicts"
run_tl "$C_HOME" --bogus
expect_rc 2 "bad option"
run_tl "$C_HOME" ../escape
expect_rc 2 "path-like id"
pass "usage: --help, unknown option, and path-like id"
