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
# FM_TEST_MR_JSON, the `.../pipelines?per_page=30` lookup from
# FM_TEST_PIPELINES_JSON, the `.../approvals` read from FM_TEST_APPROVALS_JSON,
# and the bare `projects/<path>` read from FM_TEST_PROJECT_JSON, so each case
# drives fixed fixture bytes with no network and no real GitLab host. The last
# two default to "nobody approved, none required" and "CI enabled, pipelines
# must succeed" so a case about something else need not spell them out. Every
# api call's arguments are appended to FM_TEST_GLAB_LOG, so a case can assert
# which project path and host were actually requested - the observable effect
# of shortname and URL resolution - and that an unresolved shortname produced
# no request at all. FM_TEST_GLAB_RC lets a case drive a non-zero glab exit,
# and FM_TEST_GLAB_PIPELINES_RC one for the pipelines call alone.
make_case() {
  local case_dir="$TMP_ROOT/$1" fakebin
  mkdir -p "$case_dir"
  fakebin=$(fm_fakebin "$case_dir")
  cat > "$fakebin/glab" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = api ]; then
  shift
  [ -n "${FM_TEST_GLAB_LOG:-}" ] && printf '%s\n' "$*" >> "$FM_TEST_GLAB_LOG"
  case "${1:-}" in
    *pipelines*) cat "${FM_TEST_PIPELINES_JSON:-/dev/null}"
                 exit "${FM_TEST_GLAB_PIPELINES_RC:-${FM_TEST_GLAB_RC:-0}}" ;;
    */approvals)
      if [ -n "${FM_TEST_APPROVALS_JSON:-}" ]; then cat "$FM_TEST_APPROVALS_JSON"
      else printf '{"approved":true,"approvals_required":0,"approvals_left":0,"approved_by":[]}'; fi ;;
    */merge_requests/*) cat "${FM_TEST_MR_JSON:-/dev/null}" ;;
    *)
      if [ -n "${FM_TEST_PROJECT_JSON:-}" ]; then cat "$FM_TEST_PROJECT_JSON"
      else printf '{"id":7,"jobs_enabled":true,"builds_access_level":"enabled","only_allow_merge_if_pipeline_succeeds":true}'; fi ;;
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
    FM_TEST_GLAB_PIPELINES_RC="${FM_TEST_GLAB_PIPELINES_RC:-}" \
    FM_TEST_APPROVALS_JSON="${FM_TEST_APPROVALS_JSON:-}" \
    FM_TEST_PROJECT_JSON="${FM_TEST_PROJECT_JSON:-}" \
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
 "head_pipeline":{"sha":"aaaaaaaa1111","status":"success","source":"push"}}
JSON
cat > "$case_a/pipelines.json" <<'JSON'
[{"id":1,"sha":"aaaaaaaa1111","ref":"feature/a","status":"success","source":"push"}]
JSON
out=$(run_case "$case_a" "$case_a/mr.json" "$case_a/pipelines.json" g/a!1)
assert_contains "$out" "green(head)" "green(head): a run on the real head is reported"
assert_contains "$out" "approval=not-required" "zero-approvals-required: nobody approved and none required reads not-required, not NOT-APPROVED"
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
 "head_pipeline":{"sha":"bbbbbbbb1111","status":"failed","source":"push"}}
JSON
cat > "$case_b/pipelines.json" <<'JSON'
[{"id":2,"sha":"bbbbbbbb1111","ref":"feature/b","status":"failed","source":"push"}]
JSON
out=$(run_case "$case_b" "$case_b/mr.json" "$case_b/pipelines.json" g/b!2)
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
 "head_pipeline":{"sha":"cccccccc1111","status":"manual","source":"push"}}
JSON
cat > "$case_c/pipelines.json" <<'JSON'
[{"id":3,"sha":"cccccccc1111","ref":"feature/c","status":"manual","source":"push"}]
JSON
out=$(run_case "$case_c" "$case_c/mr.json" "$case_c/pipelines.json" g/c!3)
assert_contains "$out" "manual(head)" "manual(head): a head run blocked on manual jobs is not reported as passed"
assert_contains "$out" "conflicts=YES" "a real conflict is surfaced in its own column"
pass "case C: manual(head) verdict and a real conflict"

# --- fixture D: badge is a merge-result run and it failed; nothing ever ran
# against the real head at all, so NO-HEAD-RUN is reported (never a badge
# reading), alongside a draft state note. ------------------------------------
case_d=$(make_case d)
cat > "$case_d/mr.json" <<'JSON'
{"iid":4,"state":"opened","draft":true,"work_in_progress":false,
 "sha":"dddddddd1111","detailed_merge_status":"draft_status",
 "approved":false,"approved_by":[],"has_conflicts":false,"merged_at":null,
 "head_pipeline":{"sha":"eeeeeeee2222","status":"failed","source":"merge_request_event","ref":"refs/merge-requests/4/merge"}}
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
 "head_pipeline":{"sha":"22223333bbbb","status":"success","source":"merge_request_event","ref":"refs/merge-requests/5/merge"}}
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
assert_contains "$out" " merged " "an already-merged request reports merged"
pass "case F: a merged merge request short-circuits to MERGED"

# --- fixture G: a raw control character in MR text must not break parsing -
# it broke `jq` mid-parse repeatedly before the response was scrubbed first. -
case_g=$(make_case g)
printf '{"iid":7,"state":"opened","draft":false,"work_in_progress":false,\n "sha":"aaaaaaaa1111","detailed_merge_status":"mergeable",\n "approved":false,"approved_by":[],"has_conflicts":false,"merged_at":null,\n "description":"broken by a raw control char ->\x01<- right there",\n "head_pipeline":{"sha":"aaaaaaaa1111","status":"success","source":"push"}}' \
  > "$case_g/mr.json"
cat > "$case_g/pipelines.json" <<'JSON'
[{"id":7,"sha":"aaaaaaaa1111","ref":"feature/g","status":"success","source":"push"}]
JSON
out=$(run_case "$case_g" "$case_g/mr.json" "$case_g/pipelines.json" g/g!7)
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
 "head_pipeline":{"sha":"9999ccccdddd","status":"success","source":"merge_request_event","ref":"refs/merge-requests/8/merge"}}
JSON
cat > "$case_h/pipelines.json" <<'JSON'
[{"sha":"1111aaaabbbb","ref":"fix/merge-conflicts","status":"failed","source":"push"},
 {"sha":"9999ccccdddd","ref":"refs/merge-requests/8/merge","status":"success","source":"merge_request_event"}]
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
 "head_pipeline":{"sha":"8888ccccdddd","status":"failed","source":"merge_request_event","ref":"refs/merge-requests/9/merge"}}
JSON
cat > "$case_i/pipelines.json" <<'JSON'
[{"sha":"8888ccccdddd","ref":"refs/merge-requests/9/merge","status":"failed","source":"merge_request_event"},
 {"sha":"2222aaaabbbb","ref":"refs/merge-requests/9/head","status":"success","source":"merge_request_event"}]
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
 "head_pipeline":{"sha":"abcdef1222220000","status":"success","source":"merge_request_event","ref":"refs/merge-requests/10/merge"}}
JSON
printf '[]' > "$case_j/pipelines.json"
out=$(run_case "$case_j" "$case_j/mr.json" "$case_j/pipelines.json" g/j!10)
assert_contains "$out" "NO-HEAD-RUN" "commits sharing a short prefix are different commits: no head run here"
assert_not_contains "$out" "green(head)" "a short-prefix collision must not be reported as a run on the real head"
pass "case J: shas are compared in full, not by their displayed 8-char prefix"

# --- fixture K: no head pipeline badge at all (head_pipeline:null) and no
# runs in the list either. The verdict is still NO-HEAD-RUN, but the note must
# not claim a merge-result run that does not exist. -------------------------
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
assert_contains "$out" "no head pipeline badge recorded on this merge request" "the note states which record is missing"
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
cat > "$case_o/pipelines.json" <<'JSON'
[{"id":15,"sha":"6666aaaabbbb","ref":"feature/o","status":"success","source":"push"}]
JSON
out=$(run_case "$case_o" "$case_o/mr.json" "$case_o/pipelines.json" widget!15)
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
cat > "$case_p/pipelines.json" <<'JSON'
[{"id":16,"sha":"7777aaaabbbb","ref":"feature/p","status":"success","source":"push"}]
JSON
out=$(run_case "$case_p" "$case_p/mr.json" "$case_p/pipelines.json" gadget!16)
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
cat > "$case_r/pipelines.json" <<'JSON'
[{"id":17,"sha":"8888aaaabbbb","ref":"feature/r","status":"success","source":"push"}]
JSON
out=$(run_case "$case_r" "$case_r/mr.json" "$case_r/pipelines.json" --repo group/sub/project 17)
unset FM_PROJECTS_OVERRIDE FM_TEST_GLAB_LOG
assert_grep "projects/group%2Fsub%2Fproject/merge_requests/17" "$case_r/glab.log" \
  "a path containing '/' is used verbatim as the project path"
assert_contains "$out" "green(head)" "a verbatim project path still produces a normal verdict"
pass "case R: a full group/project path is used verbatim without resolution"

# --- fixture S: the head-run lookup itself fails. A token that can read merge
# requests but not pipelines gets a non-zero glab exit here; reporting
# NO-HEAD-RUN would assert "never tested" from a response nobody read. ------
case_s=$(make_case s)
cat > "$case_s/mr.json" <<'JSON'
{"iid":18,"state":"opened","draft":false,"work_in_progress":false,
 "sha":"aaaa1111cccc","detailed_merge_status":"mergeable",
 "approved":true,"approved_by":["someone"],"has_conflicts":false,"merged_at":null,
 "head_pipeline":{"sha":"bbbb2222dddd","status":"success","source":"merge_request_event","ref":"refs/merge-requests/18/merge"}}
JSON
printf '{"message":"403 Forbidden"}' > "$case_s/pipelines.json"
export FM_TEST_GLAB_PIPELINES_RC=1
out=$(run_case "$case_s" "$case_s/mr.json" "$case_s/pipelines.json" g/s!18); rc=$?
unset FM_TEST_GLAB_PIPELINES_RC
assert_contains "$out" "UNVERIFIED" "a failed head-run lookup is reported as unverified"
assert_not_contains "$out" "NO-HEAD-RUN" "a failed lookup must not be reported as 'nothing ever ran against the head'"
assert_not_contains "$out" "(head)" "a failed lookup must not produce any head-attributed verdict"
expect_code 1 "$rc" "a failed head-run lookup fails the run"
pass "case S: a failing pipelines lookup reports UNVERIFIED, never NO-HEAD-RUN"

# --- fixture T: the pipelines lookup succeeds but answers with a well-formed
# body that is not a list - glab printing an error object on stdout. Parsing
# it as "no runs found" is the same fabrication, without even an exit code. --
case_t=$(make_case t)
cat > "$case_t/mr.json" <<'JSON'
{"iid":19,"state":"opened","draft":false,"work_in_progress":false,
 "sha":"aaaa3333cccc","detailed_merge_status":"mergeable",
 "approved":true,"approved_by":["someone"],"has_conflicts":false,"merged_at":null,
 "head_pipeline":{"sha":"bbbb4444dddd","status":"success","source":"merge_request_event","ref":"refs/merge-requests/19/merge"}}
JSON
printf '{"message":"403 Forbidden"}' > "$case_t/pipelines.json"
out=$(run_case "$case_t" "$case_t/mr.json" "$case_t/pipelines.json" g/t!19); rc=$?
assert_contains "$out" "UNVERIFIED" "a non-list pipelines body is reported as unverified"
assert_not_contains "$out" "NO-HEAD-RUN" "a non-list pipelines body must not be read as 'no runs found'"
expect_code 1 "$rc" "an unreadable pipelines body fails the run"
pass "case T: a non-list pipelines body reports UNVERIFIED, never NO-HEAD-RUN"

# --- fixture U: no head_pipeline at all, but the pipeline list does carry a
# real CI run on the head. The verdict comes from that run, and no note may
# describe a merge-result badge that does not exist. ------------------------
case_u=$(make_case u)
cat > "$case_u/mr.json" <<'JSON'
{"iid":20,"state":"opened","draft":false,"work_in_progress":false,
 "sha":"aaaa5555cccc","detailed_merge_status":"mergeable",
 "approved":true,"approved_by":["someone"],"has_conflicts":false,"merged_at":null,
 "head_pipeline":null}
JSON
cat > "$case_u/pipelines.json" <<'JSON'
[{"sha":"aaaa5555cccc","ref":"feature/u","status":"failed","source":"push"}]
JSON
out=$(run_case "$case_u" "$case_u/mr.json" "$case_u/pipelines.json" g/u!20)
assert_contains "$out" "FAILED(head)" "the head's own failed CI run drives the verdict"
assert_contains "$out" "no head pipeline badge recorded on this merge request" "the absent badge is described as an absent badge, not an absent pipeline"
assert_not_contains "$out" "merge-result" "no note may claim a merge-result badge when head_pipeline is null"
pass "case U: with head_pipeline null, no arm invents a merge-result badge"

# --- fixture V: a response with no sha at all. Both sha fields default to the
# same "-" sentinel, which would compare equal and produce a head verdict
# derived from two absent values. -------------------------------------------
case_v=$(make_case v)
cat > "$case_v/mr.json" <<'JSON'
{"iid":21,"state":"opened","draft":false,"work_in_progress":false,
 "detailed_merge_status":"mergeable",
 "approved":true,"approved_by":["someone"],"has_conflicts":false,"merged_at":null,
 "head_pipeline":null}
JSON
out=$(run_case "$case_v" "$case_v/mr.json" "" g/v!21); rc=$?
assert_contains "$out" "UNREACHABLE" "a response with no head sha is a read failure"
assert_not_contains "$out" "(head)" "two absent shas must not compare equal into a head verdict"
expect_code 1 "$rc" "a response with no head sha fails the run"
pass "case V: a missing head sha is reported as unreachable, not as none(head)"

# --- fixture W: the shape observed on platform-infra !1740. The head carries
# only source=external entries (Atlantis reporting through the commit status
# API) and no CI pipeline at all. An external red says nothing about whether
# this repo's CI ran, so the verdict must be NO-HEAD-RUN - never FAILED(head)
# - with the external red disclosed as its own distinct signal. -------------
case_w=$(make_case w)
cat > "$case_w/mr.json" <<'JSON'
{"iid":22,"state":"opened","draft":false,"work_in_progress":false,
 "sha":"9c0ede5f0000","detailed_merge_status":"mergeable",
 "approved":true,"approved_by":["someone"],"has_conflicts":false,"merged_at":null,
 "head_pipeline":{"sha":"9c0ede5f0000","status":"failed","source":"external"}}
JSON
cat > "$case_w/pipelines.json" <<'JSON'
[{"sha":"9c0ede5f0000","ref":"feature/w","status":"failed","source":"external","name":"atlantis/plan"},
 {"sha":"9c0ede5f0000","ref":"feature/w","status":"failed","source":"external","name":"atlantis/apply"}]
JSON
out=$(run_case "$case_w" "$case_w/mr.json" "$case_w/pipelines.json" g/w!22)
assert_contains "$out" "NO-HEAD-RUN" "a head carrying only external entries was never tested by CI"
assert_not_contains "$out" "FAILED(head)" "a failed external status must not be reported as a failed CI run on the head"
assert_contains "$out" "external status red: atlantis/plan, atlantis/apply" "the failed external statuses are disclosed as their own signal"
pass "case W: failed external statuses never substitute for a CI verdict"

# --- fixture X: the head has a real CI run AND a failed external entry. The
# CI run alone decides the verdict; the external red is still disclosed. ----
case_x=$(make_case x)
cat > "$case_x/mr.json" <<'JSON'
{"iid":23,"state":"opened","draft":false,"work_in_progress":false,
 "sha":"aaaa6666cccc","detailed_merge_status":"mergeable",
 "approved":true,"approved_by":["someone"],"has_conflicts":false,"merged_at":null,
 "head_pipeline":{"sha":"bbbb7777dddd","status":"success","source":"merge_request_event","ref":"refs/merge-requests/23/merge"}}
JSON
cat > "$case_x/pipelines.json" <<'JSON'
[{"sha":"aaaa6666cccc","ref":"feature/x","status":"failed","source":"external","name":"atlantis/plan"},
 {"sha":"aaaa6666cccc","ref":"feature/x","status":"success","source":"push"}]
JSON
out=$(run_case "$case_x" "$case_x/mr.json" "$case_x/pipelines.json" g/x!23)
assert_contains "$out" "green(head)" "the real CI run on the head decides the verdict"
assert_contains "$out" "external status red: atlantis/plan" "a failed external status is never silently dropped"
pass "case X: external entries are excluded from the CI verdict but still disclosed"

# --- fixture Y: the badge IS a real CI run on the head (the fast path), and a
# failed Atlantis check sits on the same commit with a lower pipeline id. The
# CI verdict is right, but the red external status must not vanish just
# because the badge happened to look trustworthy. ---------------------------
case_y=$(make_case y)
cat > "$case_y/mr.json" <<'JSON'
{"iid":24,"state":"opened","draft":false,"work_in_progress":false,
 "sha":"cafe0001aaaa","detailed_merge_status":"mergeable",
 "approved":true,"approved_by":["someone"],"has_conflicts":false,"merged_at":null,
 "head_pipeline":{"sha":"cafe0001aaaa","status":"success","source":"push","ref":"feature/y"}}
JSON
cat > "$case_y/pipelines.json" <<'JSON'
[{"id":100,"sha":"cafe0001aaaa","ref":"feature/y","status":"success","source":"push"},
 {"id":99,"sha":"cafe0001aaaa","ref":"feature/y","status":"failed","source":"external","name":"atlantis/plan"}]
JSON
out=$(run_case "$case_y" "$case_y/mr.json" "$case_y/pipelines.json" g/y!24)
assert_contains "$out" "green(head)" "a trustworthy badge on the head still decides the CI verdict"
assert_contains "$out" "external status red: atlantis/plan" "a red external status is disclosed even when the badge alone could answer"
pass "case Y: a failed external status is never dropped on the badge-matches-head path"

# --- fixture Z: the badge is a stale push pipeline from an earlier commit -
# the new head produced no pipeline at all (a [skip ci] commit, or rules that
# match no job). The verdict is right, but calling that badge a merge-result
# run states a provenance the data contradicts. -----------------------------
case_z=$(make_case z)
cat > "$case_z/mr.json" <<'JSON'
{"iid":25,"state":"opened","draft":false,"work_in_progress":false,
 "sha":"cafe0002aaaa","detailed_merge_status":"mergeable",
 "approved":true,"approved_by":["someone"],"has_conflicts":false,"merged_at":null,
 "head_pipeline":{"sha":"beef0002bbbb","status":"success","source":"push","ref":"feature/z"}}
JSON
printf '[]' > "$case_z/pipelines.json"
out=$(run_case "$case_z" "$case_z/mr.json" "$case_z/pipelines.json" g/z!25)
assert_contains "$out" "NO-HEAD-RUN" "a stale badge on an older commit is not a run against the head"
assert_contains "$out" "badge is a push run" "the badge is named for what it actually is"
assert_not_contains "$out" "merge-result" "a push pipeline on an older commit must not be called a merge-result run"
pass "case Z: a stale push badge is described as a push run, not a merge-result run"

# --- fixture AA: two failed external entries on the head with no pipeline
# name, as commit-status-created pipelines generally have. Naming them by
# their shared branch would print the same string twice and identify neither.
case_aa=$(make_case aa)
cat > "$case_aa/mr.json" <<'JSON'
{"iid":26,"state":"opened","draft":false,"work_in_progress":false,
 "sha":"cafe0003aaaa","detailed_merge_status":"mergeable",
 "approved":true,"approved_by":["someone"],"has_conflicts":false,"merged_at":null,
 "head_pipeline":{"sha":"cafe0003aaaa","status":"failed","source":"external","ref":"feature/aa"}}
JSON
cat > "$case_aa/pipelines.json" <<'JSON'
[{"id":99,"sha":"cafe0003aaaa","ref":"feature/aa","status":"failed","source":"external"},
 {"id":98,"sha":"cafe0003aaaa","ref":"feature/aa","status":"failed","source":"external"}]
JSON
out=$(run_case "$case_aa" "$case_aa/mr.json" "$case_aa/pipelines.json" g/aa!26)
assert_contains "$out" "NO-HEAD-RUN" "a head carrying only external entries was never tested by CI"
assert_contains "$out" "external status red: #99, #98" "unnamed external entries are identified by pipeline id, so they stay distinguishable"
assert_not_contains "$out" "feature/aa, feature/aa" "the branch name identifies neither entry and must not stand in for one"
pass "case AA: unnamed external entries are identified individually, not by their shared branch"

# --- fixture AB: two CI pipelines on the head - an earlier failure and a
# later re-run that passed - returned in ascending id order. "The head's run"
# means the most recent one, not whichever the response listed first. -------
case_ab=$(make_case ab)
cat > "$case_ab/mr.json" <<'JSON'
{"iid":27,"state":"opened","draft":false,"work_in_progress":false,
 "sha":"cafe0004aaaa","detailed_merge_status":"mergeable",
 "approved":true,"approved_by":["someone"],"has_conflicts":false,"merged_at":null,
 "head_pipeline":{"sha":"beef0004bbbb","status":"success","source":"merge_request_event","ref":"refs/merge-requests/27/merge"}}
JSON
cat > "$case_ab/pipelines.json" <<'JSON'
[{"id":100,"sha":"cafe0004aaaa","ref":"feature/ab","status":"failed","source":"push"},
 {"id":105,"sha":"cafe0004aaaa","ref":"feature/ab","status":"success","source":"push"}]
JSON
out=$(run_case "$case_ab" "$case_ab/mr.json" "$case_ab/pipelines.json" g/ab!27)
assert_contains "$out" "green(head)" "the most recent CI run on the head decides the verdict"
assert_not_contains "$out" "FAILED(head)" "an earlier failed run must not outrank a later passing one because of list order"
pass "case AB: the head's CI status comes from the newest run, not the first listed"

# --- fixture AC: the --help text is the tool's own generated interface, and
# it is the only place a user learns what a row can say. It advertised a
# green(merge) verdict no code path can print and a `conflicts` output column
# the row never emits - so the surface that exists to keep the operator from
# trusting a wrong pipeline reading was itself wrong. Both claims are checked
# against what the tool actually prints for the fixtures above, rather than
# against a copy of the text. -----------------------------------------------
help=$("$SCRIPT" --help); rc=$?
expect_code 0 "$rc" "--help exits cleanly"

# Every literal verdict the help advertises, excluding the <status>(head)
# placeholder that stands for the arbitrary-status fallback.
advertised=$(printf '%s\n' "$help" \
  | awk '/(verdicts:|one of:)$/ {f=1; next} f && /^[[:space:]]*$/ {exit} f {print $1}' \
  | grep -E '^([A-Za-z<>-]+\([a-z]+\)|[A-Z][A-Z-]{2,})$' \
  | grep -vx '<status>(head)' | sort -u)

# Every verdict the tool actually prints, taken from the verdict column of the
# rows the verdict fixtures above produce.
verdict_of() { printf '%s\n' "$1" | awk 'NF {sub(/^ci=/, "", $4); print $4}'; }
printed=$(
  { verdict_of "$(run_case "$case_a" "$case_a/mr.json" "$case_a/pipelines.json" g/a!1)"
    verdict_of "$(run_case "$case_b" "$case_b/mr.json" "$case_b/pipelines.json" g/b!2)"
    verdict_of "$(run_case "$case_c" "$case_c/mr.json" "$case_c/pipelines.json" g/c!3)"
    verdict_of "$(run_case "$case_e" "$case_e/mr.json" "$case_e/pipelines.json" g/e!5)"
    verdict_of \
      "$(FM_TEST_GLAB_PIPELINES_RC=1 run_case "$case_s" "$case_s/mr.json" "$case_s/pipelines.json" g/s!18)"
  } | sort -u
)
[ -n "$advertised" ] || fail "--help no longer lists the verdicts a row can report"
[ "$advertised" = "$printed" ] || fail \
  "--help advertises verdicts the tool does not print (or omits ones it does)"$'\n'"--- advertised ---"$'\n'"$advertised"$'\n'"--- printed ---"$'\n'"$printed"

# The documented column list, minus the optional trailing "[- notes]", must
# name exactly as many columns as a notes-free row emits fields.
documented=$(printf '%s\n' "$help" | sed -n 's/^Output columns: *//p' \
  | sed 's/\[[^]]*\]//' | wc -w | tr -d ' ')
emitted=$(run_case "$case_a" "$case_a/mr.json" "$case_a/pipelines.json" g/a!1 | awk 'NF {print NF; exit}')
[ "$documented" = "$emitted" ] || fail \
  "--help documents $documented mandatory output columns but a notes-free row emits $emitted fields"
pass "case AC: --help describes the verdicts and columns the tool really emits"

# A green open merge request on the real head, shared by the cases below that
# are about something other than the pipeline verdict.
write_green_mr() {  # <file> <iid>
  cat > "$1" <<JSON
{"iid":$2,"state":"opened","draft":false,"work_in_progress":false,
 "sha":"abcd0000$2","target_branch":"release/2.x","detailed_merge_status":"mergeable",
 "approved":true,"approved_by":[],"has_conflicts":false,"merged_at":null,
 "head_pipeline":{"sha":"abcd0000$2","status":"success","source":"push","ref":"feature/x"}}
JSON
}

# --- fixture AD: a full merge request URL on a self-hosted instance. Its host
# must be the one every read goes to, so glab's configured default host never
# answers for a different instance, and the target branch is reported. ------
case_ad=$(make_case ad)
write_green_mr "$case_ad/mr.json" 30
printf '[{"id":1,"sha":"abcd000030","ref":"feature/x","status":"success","source":"push"}]' \
  > "$case_ad/pipelines.json"
: > "$case_ad/glab.log"
out=$(FM_TEST_GLAB_LOG="$case_ad/glab.log" run_case "$case_ad" "$case_ad/mr.json" "$case_ad/pipelines.json" \
  https://git.example.org/acme/tools/widget/-/merge_requests/30); rc=$?
expect_code 0 "$rc" "a fully readable URL row exits cleanly"
assert_contains "$out" "widget!30" "the URL's project is reported under its own name"
assert_contains "$out" "into=release/2.x" "the target branch is reported"
assert_contains "$out" "ci=green(head)" "a URL row gets the same head verdict"
assert_grep "projects/acme%2Ftools%2Fwidget/merge_requests/30 --hostname git.example.org" "$case_ad/glab.log" \
  "the merge request is read from the URL's own host"
assert_grep "projects/acme%2Ftools%2Fwidget --hostname git.example.org" "$case_ad/glab.log" \
  "the project settings are read from the URL's own host"
[ "$(grep -c -v -- '--hostname git.example.org' "$case_ad/glab.log")" = 0 ] \
  || fail "every read for a URL row must name the URL's host"
pass "case AD: a full URL is read from its own host and reports the target branch"

# --- fixture AE: a URL that is not a GitLab merge request is refused before
# any read, rather than guessed at. -----------------------------------------
case_ae=$(make_case ae)
: > "$case_ae/glab.log"
out=$(FM_TEST_GLAB_LOG="$case_ae/glab.log" run_case "$case_ae" "" "" \
  https://github.com/acme/widget/pull/3 2>&1); rc=$?
expect_code 1 "$rc" "a non-GitLab URL fails the run"
assert_contains "$out" "not a GitLab merge request URL" "the refusal names what was expected"
[ ! -s "$case_ae/glab.log" ] || fail "a refused URL must not reach glab"
pass "case AE: a GitHub pull request URL is refused without a read"

# --- fixture AF: approvals. "approved" and "no approval required" look the
# same through detailed_merge_status=mergeable, so the approvals read has to
# tell them apart, and each other outcome keeps its own name. --------------
case_af=$(make_case af)
write_green_mr "$case_af/mr.json" 31
printf '[{"id":1,"sha":"abcd000031","ref":"feature/x","status":"success","source":"push"}]' \
  > "$case_af/pipelines.json"
approval_of() {  # <approvals-json> [<detailed_merge_status>]
  printf '%s' "$1" > "$case_af/approvals.json"
  if [ -n "${2:-}" ]; then
    sed "s/\"mergeable\"/\"$2\"/" "$case_af/mr.json" > "$case_af/mr-dms.json"
  else
    cp "$case_af/mr.json" "$case_af/mr-dms.json"
  fi
  FM_TEST_APPROVALS_JSON="$case_af/approvals.json" \
    run_case "$case_af" "$case_af/mr-dms.json" "$case_af/pipelines.json" g/af!31
}
out=$(approval_of '{"approved":true,"approvals_left":0,"approved_by":[{"user":{"username":"a"}},{"user":{"username":"b"}}]}')
assert_contains "$out" "approval=approved(2)" "two sign-offs with none left read approved(2)"
out=$(approval_of '{"approved":true,"approvals_required":0,"approvals_left":0,"approved_by":[]}')
assert_contains "$out" "approval=not-required" "no sign-off and none required reads not-required, never approved"
assert_not_contains "$out" "approved(" "an approved:true flag with an empty approved_by is not an approval"
out=$(approval_of '{"approved":false,"approvals_required":2,"approvals_left":1,"approved_by":[{"user":{"username":"a"}}]}' not_approved)
assert_contains "$out" "approval=NOT-APPROVED(1-left)" "a still-required approval is reported with how many are left"
out=$(approval_of '{"approved":true,"approved_by":[{"user":{"username":"a"}}]}' not_approved)
assert_contains "$out" "approval=NOT-APPROVED" "detailed_merge_status=not_approved wins over a partial sign-off"
out=$(approval_of '{"approved":false,"approved_by":[]}' ci_must_pass)
assert_contains "$out" "approval=none-given" "no sign-off with an unknown requirement is not claimed as not-required"
out=$(approval_of 'not json'); rc=$?
assert_contains "$out" "approval=UNVERIFIED" "an unreadable approvals read makes no approval claim"
expect_code 1 "$rc" "an unreadable approvals read fails the run"
out=$(approval_of 'not json' not_approved)
assert_contains "$out" "approval=NOT-APPROVED" "not_approved is still reported when the approvals read fails"
assert_contains "$out" "merge=not_approved" "detailed_merge_status is reported verbatim"
pass "case AF: approvals distinguish approved, not required, still required, and unreadable"

# --- fixture AG: the project's own CI settings. A project whose builds are
# disabled can never produce a pipeline, "Pipelines must succeed" is shown as
# set, and a project that cannot be read makes no claim either way. The
# project is read once for consecutive rows of the same project. -----------
case_ag=$(make_case ag)
write_green_mr "$case_ag/mr.json" 32
printf '[{"id":1,"sha":"abcd000032","ref":"feature/x","status":"success","source":"push"}]' \
  > "$case_ag/pipelines.json"
printf '{"id":9,"jobs_enabled":true,"builds_access_level":"disabled","only_allow_merge_if_pipeline_succeeds":false}' \
  > "$case_ag/project.json"
: > "$case_ag/glab.log"
out=$(FM_TEST_GLAB_LOG="$case_ag/glab.log" FM_TEST_PROJECT_JSON="$case_ag/project.json" \
  run_case "$case_ag" "$case_ag/mr.json" "$case_ag/pipelines.json" --repo g/ag 32 32)
assert_contains "$out" "jobs=DISABLED" "builds_access_level=disabled reports CI as disabled even with jobs_enabled=true"
assert_contains "$out" "must-succeed=no" "an unset Pipelines must succeed is reported as no"
[ "$(grep -c '^projects/g%2Fag$' "$case_ag/glab.log")" = 1 ] \
  || fail "consecutive rows of one project must read its settings once"
out=$(run_case "$case_ag" "$case_ag/mr.json" "$case_ag/pipelines.json" g/ag!32)
assert_contains "$out" "jobs=enabled must-succeed=yes" "an enabled project with the setting on reports both"
printf '{"message":"404 Project Not Found"}' > "$case_ag/project-err.json"
out=$(FM_TEST_PROJECT_JSON="$case_ag/project-err.json" \
  run_case "$case_ag" "$case_ag/mr.json" "$case_ag/pipelines.json" g/ag!32); rc=$?
assert_contains "$out" "jobs=? must-succeed=?" "an unreadable project makes no CI-settings claim"
expect_code 1 "$rc" "an unreadable project fails the run"
pass "case AG: project CI capability and Pipelines must succeed are reported, or ? when unread"

# --- fixture AH: a merged merge request still names its target branch. -----
case_ah=$(make_case ah)
cat > "$case_ah/mr.json" <<'JSON'
{"iid":33,"state":"merged","sha":"abcd000033","target_branch":"main",
 "merged_at":"2026-09-01T10:00:00Z","head_pipeline":null}
JSON
out=$(run_case "$case_ah" "$case_ah/mr.json" "" g/ah!33)
assert_contains "$out" "merged  into=main on=2026-09-01" "a merged row names its target branch and date"
pass "case AH: a merged merge request reports its target branch"
