#!/usr/bin/env bash
# tests/fm-pr-status.test.sh - fm-pr-status.sh's verdict and parsing logic.
#
# The tool exists to close one gap: a green head_pipeline badge is often a
# MERGE-RESULT run against a synthetic commit, not the branch head, so a green
# badge can sit on a head that failed or was never run at all. Every case here
# drives that distinction against fixture JSON through a fake glab, never the
# network, plus the two smaller traps that were got wrong by hand: control
# characters in MR text breaking the parser, and approval read from
# detailed_merge_status rather than the misleading `approved` flag.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-pr-status.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-status)

# A fake glab that answers `api projects/.../merge_requests/<iid>` from
# FM_TEST_MR_JSON and the `.../pipelines?per_page=30` lookup from
# FM_TEST_PIPELINES_JSON, so each case drives fixed fixture bytes with no
# network and no real GitLab host. Every api path it is asked for is appended to
# FM_TEST_GLAB_LOG, so a case can assert which project path was actually
# requested - the observable effect of shortname resolution - and that an
# unresolved shortname produced no request at all. FM_TEST_GLAB_RC lets a case
# drive a non-zero glab exit.
make_case() {
  local case_dir="$TMP_ROOT/$1" fakebin
  mkdir -p "$case_dir"
  fakebin=$(fm_fakebin "$case_dir")
  cat > "$fakebin/glab" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = api ]; then
  [ -n "${FM_TEST_GLAB_LOG:-}" ] && printf '%s\n' "${2:-}" >> "$FM_TEST_GLAB_LOG"
  case "${2:-}" in
    *pipelines*) cat "${FM_TEST_PIPELINES_JSON:-/dev/null}" ;;
    *)           cat "${FM_TEST_MR_JSON:-/dev/null}" ;;
  esac
fi
exit "${FM_TEST_GLAB_RC:-0}"
SH
  chmod +x "$fakebin/glab"
  printf '%s\n' "$case_dir"
}

# run_case <case-dir> <mr-json-file> [pipelines-json-file] -- <script args...>
run_case() {
  local case_dir=$1 mr_json=$2 pipelines_json=$3
  shift 3
  [ "${1:-}" = -- ] && shift
  PATH="$case_dir/fakebin:$BASE_PATH" \
    FM_TEST_MR_JSON="$mr_json" \
    FM_TEST_PIPELINES_JSON="$pipelines_json" \
    FM_TEST_GLAB_LOG="${FM_TEST_GLAB_LOG:-}" \
    FM_TEST_GLAB_RC="${FM_TEST_GLAB_RC:-0}" \
    FM_PROJECTS_OVERRIDE="${FM_PROJECTS_OVERRIDE:-}" \
    "$SCRIPT" "$@"
}
BASE_PATH=$PATH

# --- fixture A: a run on the real head succeeded, and nothing was approval-
# required (approved:false, approved_by:[] but detailed_merge_status:mergeable
# - the exact shape that makes a naive read of the `approved` flag alone say
# NOT-APPROVED when the merge status says it is fine to merge). -------------
case_a=$(make_case a)
cat > "$case_a/mr.json" <<'JSON'
{"iid":1,"state":"opened","draft":false,"work_in_progress":false,
 "sha":"aaaaaaaa1111","detailed_merge_status":"mergeable",
 "approved":false,"approved_by":[],"has_conflicts":false,"merged_at":null,
 "head_pipeline":{"sha":"aaaaaaaa1111","status":"success"}}
JSON
out=$(run_case "$case_a" "$case_a/mr.json" "" g/a!1)
assert_contains "$out" "green(head)" "green(head): a run on the real head is reported"
assert_contains "$out" " ok " "zero-approvals-required: mergeable status reports ok, not NOT-APPROVED"
assert_not_contains "$out" "NOT-APPROVED" "zero-approvals-required: the approved:false flag alone must not drive the verdict"
pass "case A: green(head) verdict and zero-approvals-required mergeable status"

# --- fixture B: a run on the real head failed, whatever a badge would say,
# and detailed_merge_status:not_approved is honored even though approved:true
# with an empty approved_by list would mislead a naive reader. -------------
case_b=$(make_case b)
cat > "$case_b/mr.json" <<'JSON'
{"iid":2,"state":"opened","draft":false,"work_in_progress":false,
 "sha":"bbbbbbbb1111","detailed_merge_status":"not_approved",
 "approved":true,"approved_by":[],"has_conflicts":false,"merged_at":null,
 "head_pipeline":{"sha":"bbbbbbbb1111","status":"failed"}}
JSON
out=$(run_case "$case_b" "$case_b/mr.json" "" g/b!2)
assert_contains "$out" "FAILED(head)" "FAILED(head): a failed run on the real head is reported, whatever the badge says"
assert_contains "$out" "NOT-APPROVED" "approval reads detailed_merge_status, not an approved:true flag with an empty approved_by"
pass "case B: FAILED(head) verdict and not_approved read from merge status"

# --- fixture C: the head's own run is blocked on manual jobs - not "passed" -
# alongside a real conflict, both reported in the same line. ----------------
case_c=$(make_case c)
cat > "$case_c/mr.json" <<'JSON'
{"iid":3,"state":"opened","draft":false,"work_in_progress":false,
 "sha":"cccccccc1111","detailed_merge_status":"conflict",
 "approved":false,"approved_by":[],"has_conflicts":true,"merged_at":null,
 "head_pipeline":{"sha":"cccccccc1111","status":"manual"}}
JSON
out=$(run_case "$case_c" "$case_c/mr.json" "" g/c!3)
assert_contains "$out" "manual(head)" "manual(head): a head run blocked on manual jobs is not reported as passed"
assert_contains "$out" "CONFLICTS" "a real conflict is surfaced in the notes"
pass "case C: manual(head) verdict and a real conflict"

# --- fixture D: badge is a merge-result run and it failed; nothing ever ran
# against the real head at all, so NO-HEAD-RUN is reported (never a badge
# reading), alongside a draft state note. ------------------------------------
case_d=$(make_case d)
cat > "$case_d/mr.json" <<'JSON'
{"iid":4,"state":"opened","draft":true,"work_in_progress":false,
 "sha":"dddddddd1111","detailed_merge_status":"draft_status",
 "approved":false,"approved_by":[],"has_conflicts":false,"merged_at":null,
 "head_pipeline":{"sha":"eeeeeeee2222","status":"failed"}}
JSON
printf '[]' > "$case_d/pipelines.json"
out=$(run_case "$case_d" "$case_d/mr.json" "$case_d/pipelines.json" g/d!4)
assert_contains "$out" "NO-HEAD-RUN" "NO-HEAD-RUN: nothing ran against the real head"
assert_contains "$out" "DRAFT" "a draft merge request is flagged as not mergeable yet"
pass "case D: NO-HEAD-RUN with a failed merge-result badge and a draft note"

# --- fixture E: the trap this tool exists to close. The badge itself is
# green (a merge-result run succeeded), but nothing ever ran against the real
# head, so this must still say NO-HEAD-RUN - never a green verdict - with the
# badge's own green status disclosed only in the notes. ---------------------
case_e=$(make_case e)
cat > "$case_e/mr.json" <<'JSON'
{"iid":5,"state":"opened","draft":false,"work_in_progress":false,
 "sha":"11112222aaaa","detailed_merge_status":"mergeable",
 "approved":true,"approved_by":["someone"],"has_conflicts":false,"merged_at":null,
 "head_pipeline":{"sha":"22223333bbbb","status":"success"}}
JSON
printf '[]' > "$case_e/pipelines.json"
out=$(run_case "$case_e" "$case_e/mr.json" "$case_e/pipelines.json" g/e!5)
assert_contains "$out" "NO-HEAD-RUN" "the green-badge trap: an untested head is never reported as green"
assert_not_contains "$out" "green(head)" "the green-badge trap: a merge-result-only green badge must not read as a head verdict"
assert_contains "$out" "success" "the badge's own green status is disclosed honestly in the notes"
pass "case E: a green badge on an unverified head is still reported as NO-HEAD-RUN"

# --- fixture F: an already-merged request reports MERGED, not a pipeline
# verdict computed against a branch that no longer needs one. ---------------
case_f=$(make_case f)
cat > "$case_f/mr.json" <<'JSON'
{"iid":6,"state":"merged","draft":false,"work_in_progress":false,
 "sha":"ffffffff1111","detailed_merge_status":"mergeable",
 "approved":true,"approved_by":["someone"],"has_conflicts":false,
 "merged_at":"2026-08-01T00:00:00Z",
 "head_pipeline":{"sha":"ffffffff1111","status":"success"}}
JSON
out=$(run_case "$case_f" "$case_f/mr.json" "" g/f!6)
assert_contains "$out" "MERGED" "an already-merged request reports MERGED"
pass "case F: a merged merge request short-circuits to MERGED"

# --- fixture G: a raw control character in MR text must not break parsing -
# it broke `jq` mid-parse repeatedly before the response was scrubbed first. -
case_g=$(make_case g)
printf '{"iid":7,"state":"opened","draft":false,"work_in_progress":false,\n "sha":"aaaaaaaa1111","detailed_merge_status":"mergeable",\n "approved":false,"approved_by":[],"has_conflicts":false,"merged_at":null,\n "description":"broken by a raw control char ->\x01<- right there",\n "head_pipeline":{"sha":"aaaaaaaa1111","status":"success"}}' \
  > "$case_g/mr.json"
out=$(run_case "$case_g" "$case_g/mr.json" "" g/g!7)
assert_contains "$out" "green(head)" "a control character in MR text is scrubbed rather than breaking the parse"
pass "case G: a raw control character in the response does not break parsing"

# --- fixture H: the head run lives on a source branch whose NAME contains
# "merge" (fix/merge-conflicts). A substring test for "/merge" over the ref
# discards that real head run and reports NO-HEAD-RUN for a head that was
# genuinely tested; only the merge-result ref form may be filtered out. ------
case_h=$(make_case h)
cat > "$case_h/mr.json" <<'JSON'
{"iid":8,"state":"opened","draft":false,"work_in_progress":false,
 "sha":"1111aaaabbbb","detailed_merge_status":"mergeable",
 "approved":true,"approved_by":["someone"],"has_conflicts":false,"merged_at":null,
 "source_branch":"fix/merge-conflicts",
 "head_pipeline":{"sha":"9999ccccdddd","status":"success"}}
JSON
cat > "$case_h/pipelines.json" <<'JSON'
[{"sha":"1111aaaabbbb","ref":"fix/merge-conflicts","status":"failed"},
 {"sha":"9999ccccdddd","ref":"refs/merge-requests/8/merge","status":"success"}]
JSON
out=$(run_case "$case_h" "$case_h/mr.json" "$case_h/pipelines.json" g/h!8)
assert_contains "$out" "FAILED(head)" "a head run on a branch named fix/merge-conflicts is found, not discarded as a merge-result ref"
assert_not_contains "$out" "NO-HEAD-RUN" "a branch whose name merely contains 'merge' must not be mistaken for a merge-result ref"
pass "case H: a source branch containing 'merge' is not misread as a merge-result run"

# --- fixture I: a detached merge request pipeline runs against the real head
# under refs/merge-requests/<iid>/head. That ref contains "/merge" inside
# "merge-requests", so a substring filter drops every detached head run; only
# the exact /merge suffix identifies a merge-result run. --------------------
case_i=$(make_case i)
cat > "$case_i/mr.json" <<'JSON'
{"iid":9,"state":"opened","draft":false,"work_in_progress":false,
 "sha":"2222aaaabbbb","detailed_merge_status":"mergeable",
 "approved":true,"approved_by":["someone"],"has_conflicts":false,"merged_at":null,
 "head_pipeline":{"sha":"8888ccccdddd","status":"failed"}}
JSON
cat > "$case_i/pipelines.json" <<'JSON'
[{"sha":"8888ccccdddd","ref":"refs/merge-requests/9/merge","status":"failed"},
 {"sha":"2222aaaabbbb","ref":"refs/merge-requests/9/head","status":"success"}]
JSON
out=$(run_case "$case_i" "$case_i/mr.json" "$case_i/pipelines.json" g/i!9)
assert_contains "$out" "green(head)" "a detached refs/merge-requests/<iid>/head run counts as a run against the real head"
assert_contains "$out" "badge is merge-result" "the merge-result badge is still disclosed in the notes"
pass "case I: a refs/merge-requests/<iid>/head run is recognised as a head run"

# --- fixture J: two distinct commits that share their first 8 characters.
# Comparing truncated shas would read the merge-result run as a head run and
# report a green verdict for a head nothing ran against. --------------------
case_j=$(make_case j)
cat > "$case_j/mr.json" <<'JSON'
{"iid":10,"state":"opened","draft":false,"work_in_progress":false,
 "sha":"abcdef1211110000","detailed_merge_status":"mergeable",
 "approved":true,"approved_by":["someone"],"has_conflicts":false,"merged_at":null,
 "head_pipeline":{"sha":"abcdef1222220000","status":"success"}}
JSON
printf '[]' > "$case_j/pipelines.json"
out=$(run_case "$case_j" "$case_j/mr.json" "$case_j/pipelines.json" g/j!10)
assert_contains "$out" "NO-HEAD-RUN" "commits sharing a short prefix are different commits: no head run here"
assert_not_contains "$out" "green(head)" "a short-prefix collision must not be reported as a run on the real head"
pass "case J: shas are compared in full, not by their displayed 8-char prefix"

# --- fixture K: no pipeline was ever recorded for the request at all
# (head_pipeline:null). The verdict is still NO-HEAD-RUN, but the note must not
# claim a merge-result run that does not exist. -----------------------------
case_k=$(make_case k)
cat > "$case_k/mr.json" <<'JSON'
{"iid":11,"state":"opened","draft":false,"work_in_progress":false,
 "sha":"4444aaaabbbb","detailed_merge_status":"mergeable",
 "approved":true,"approved_by":["someone"],"has_conflicts":false,"merged_at":null,
 "head_pipeline":null}
JSON
printf '[]' > "$case_k/pipelines.json"
out=$(run_case "$case_k" "$case_k/mr.json" "$case_k/pipelines.json" g/k!11)
assert_contains "$out" "NO-HEAD-RUN" "an MR with no pipeline at all has no run against its head"
assert_contains "$out" "no pipeline recorded for this merge request" "the note states no pipeline exists"
assert_not_contains "$out" "merge-result run exists" "the note must not claim a merge-result run that does not exist"
pass "case K: an MR with no pipeline reports that, not a phantom merge-result run"

# --- fixture L: an unparseable response. Defaulting the fields would make the
# MR sha and pipeline sha compare equal and fabricate a head-attributed
# verdict; a read failure must be reported as one, and must fail the run. ---
case_l=$(make_case l)
printf 'not json at all' > "$case_l/mr.json"
out=$(run_case "$case_l" "$case_l/mr.json" "" g/l!12); rc=$?
assert_contains "$out" "UNREACHABLE" "an unparseable response is reported as unreachable"
assert_not_contains "$out" "(head)" "an unparseable response must never produce a head-attributed verdict"
expect_code 1 "$rc" "an unparseable response fails the run"
pass "case L: an unparseable response reports UNREACHABLE and exits non-zero"

# --- fixture M: `glab api` prints the error body on stdout for a non-2xx, so a
# mistyped iid or a revoked token yields well-formed JSON that is not a merge
# request. It parses, but it has none of an MR's fields. --------------------
case_m=$(make_case m)
printf '{"message":"404 Not found"}' > "$case_m/mr.json"
out=$(run_case "$case_m" "$case_m/mr.json" "" g/m!13); rc=$?
assert_contains "$out" "UNREACHABLE" "a well-formed non-MR error body is reported as unreachable"
assert_not_contains "$out" "none(head)" "an error body must not default into a 'none(head)' verdict"
expect_code 1 "$rc" "a non-MR error body fails the run"
pass "case M: a parseable non-MR error body reports UNREACHABLE and exits non-zero"

# --- fixture N: glab itself fails. Even if it wrote something to stdout, a
# non-zero exit means nothing was read and no verdict can be asserted. ------
case_n=$(make_case n)
cat > "$case_n/mr.json" <<'JSON'
{"iid":14,"state":"opened","draft":false,"work_in_progress":false,
 "sha":"5555aaaabbbb","detailed_merge_status":"mergeable",
 "approved":true,"approved_by":["someone"],"has_conflicts":false,"merged_at":null,
 "head_pipeline":{"sha":"5555aaaabbbb","status":"success"}}
JSON
export FM_TEST_GLAB_RC=1
out=$(run_case "$case_n" "$case_n/mr.json" "" g/n!14); rc=$?
unset FM_TEST_GLAB_RC
assert_contains "$out" "UNREACHABLE" "a failing glab call is reported as unreachable"
assert_not_contains "$out" "green(head)" "a failing glab call must not yield a verdict from whatever it printed"
expect_code 1 "$rc" "a failing glab call fails the run"
pass "case N: a non-zero glab exit reports UNREACHABLE and exits non-zero"

# --- fixture O: a bare shortname resolves to a project path from the origin
# remote of the clone at projects/<name>, so the tool carries no hardcoded
# organization. The resolved path is observable in the API path requested. --
case_o=$(make_case o)
mkdir -p "$case_o/projects/widget"
git -C "$case_o/projects/widget" init -q
git -C "$case_o/projects/widget" remote add origin https://gitlab.example.com/acme/tools/widget.git
cat > "$case_o/mr.json" <<'JSON'
{"iid":15,"state":"opened","draft":false,"work_in_progress":false,
 "sha":"6666aaaabbbb","detailed_merge_status":"mergeable",
 "approved":true,"approved_by":["someone"],"has_conflicts":false,"merged_at":null,
 "head_pipeline":{"sha":"6666aaaabbbb","status":"success"}}
JSON
: > "$case_o/glab.log"
export FM_PROJECTS_OVERRIDE="$case_o/projects" FM_TEST_GLAB_LOG="$case_o/glab.log"
out=$(run_case "$case_o" "$case_o/mr.json" "" widget!15)
unset FM_PROJECTS_OVERRIDE FM_TEST_GLAB_LOG
assert_grep "projects/acme%2Ftools%2Fwidget/merge_requests/15" "$case_o/glab.log" \
  "an https origin remote resolves the shortname to its full group/project path"
assert_contains "$out" "widget!15" "the resolved project is reported under its own name"
pass "case O: a shortname resolves from an https origin remote of projects/<name>"

# --- fixture P: the same resolution from an scp-style remote, the other form
# git writes for a clone. --------------------------------------------------
case_p=$(make_case p)
mkdir -p "$case_p/projects/gadget"
git -C "$case_p/projects/gadget" init -q
git -C "$case_p/projects/gadget" remote add origin git@gitlab.example.com:acme/tools/gadget.git
cat > "$case_p/mr.json" <<'JSON'
{"iid":16,"state":"opened","draft":false,"work_in_progress":false,
 "sha":"7777aaaabbbb","detailed_merge_status":"mergeable",
 "approved":true,"approved_by":["someone"],"has_conflicts":false,"merged_at":null,
 "head_pipeline":{"sha":"7777aaaabbbb","status":"success"}}
JSON
: > "$case_p/glab.log"
export FM_PROJECTS_OVERRIDE="$case_p/projects" FM_TEST_GLAB_LOG="$case_p/glab.log"
out=$(run_case "$case_p" "$case_p/mr.json" "" gadget!16)
unset FM_PROJECTS_OVERRIDE FM_TEST_GLAB_LOG
assert_grep "projects/acme%2Ftools%2Fgadget/merge_requests/16" "$case_p/glab.log" \
  "an scp-style origin remote resolves the shortname to its full group/project path"
pass "case P: a shortname resolves from an scp-style origin remote of projects/<name>"

# --- fixture Q: a shortname with no clone must fail with a message naming what
# was looked for, and must never guess an organization prefix - the hardcoded
# org map this resolution replaced. No API call may be attempted at all. ----
case_q=$(make_case q)
mkdir -p "$case_q/projects"
: > "$case_q/glab.log"
export FM_PROJECTS_OVERRIDE="$case_q/projects" FM_TEST_GLAB_LOG="$case_q/glab.log"
out=$(run_case "$case_q" /dev/null "" ghost!1 2>&1); rc=$?
unset FM_PROJECTS_OVERRIDE FM_TEST_GLAB_LOG
expect_code 1 "$rc" "an unresolvable shortname fails the run"
assert_contains "$out" "projects/ghost" "the error names the clone it looked for"
[ ! -s "$case_q/glab.log" ] || fail "an unresolvable shortname must not query a guessed project path"$'\n'"$(cat "$case_q/glab.log")"
pass "case Q: an unresolvable shortname fails clearly and never guesses an org prefix"

# --- fixture R: a full group/project path is still accepted verbatim, with no
# clone anywhere and no resolution attempted. -------------------------------
case_r=$(make_case r)
cat > "$case_r/mr.json" <<'JSON'
{"iid":17,"state":"opened","draft":false,"work_in_progress":false,
 "sha":"8888aaaabbbb","detailed_merge_status":"mergeable",
 "approved":true,"approved_by":["someone"],"has_conflicts":false,"merged_at":null,
 "head_pipeline":{"sha":"8888aaaabbbb","status":"success"}}
JSON
: > "$case_r/glab.log"
export FM_PROJECTS_OVERRIDE="$case_r/nonexistent" FM_TEST_GLAB_LOG="$case_r/glab.log"
out=$(run_case "$case_r" "$case_r/mr.json" "" --repo group/sub/project 17)
unset FM_PROJECTS_OVERRIDE FM_TEST_GLAB_LOG
assert_grep "projects/group%2Fsub%2Fproject/merge_requests/17" "$case_r/glab.log" \
  "a path containing '/' is used verbatim as the project path"
assert_contains "$out" "green(head)" "a verbatim project path still produces a normal verdict"
pass "case R: a full group/project path is used verbatim without resolution"
