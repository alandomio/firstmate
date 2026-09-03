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
# network and no real GitLab host.
make_case() {
  local case_dir="$TMP_ROOT/$1" fakebin
  mkdir -p "$case_dir"
  fakebin=$(fm_fakebin "$case_dir")
  cat > "$fakebin/glab" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = api ]; then
  case "${2:-}" in
    *pipelines*) cat "${FM_TEST_PIPELINES_JSON:-/dev/null}" ;;
    *)           cat "${FM_TEST_MR_JSON:-/dev/null}" ;;
  esac
fi
exit 0
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
    "$SCRIPT" "$@"
}
BASE_PATH=$PATH

# --- fixture A: a run on the real head succeeded, and nothing was approval-
# required (approved:false, approved_by:[] but detailed_merge_status:mergeable
# - the exact shape that makes a naive read of the `approved` flag alone say
# NOT-APPROVED when the merge status says it is fine to merge). -------------
case_a=$(make_case a)
cat > "$case_a/mr.json" <<'JSON'
{"state":"opened","draft":false,"work_in_progress":false,
 "sha":"aaaaaaaa1111","detailed_merge_status":"mergeable",
 "approved":false,"approved_by":[],"has_conflicts":false,"merged_at":null,
 "head_pipeline":{"sha":"aaaaaaaa2222","status":"success"}}
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
{"state":"opened","draft":false,"work_in_progress":false,
 "sha":"bbbbbbbb1111","detailed_merge_status":"not_approved",
 "approved":true,"approved_by":[],"has_conflicts":false,"merged_at":null,
 "head_pipeline":{"sha":"bbbbbbbb2222","status":"failed"}}
JSON
out=$(run_case "$case_b" "$case_b/mr.json" "" g/b!2)
assert_contains "$out" "FAILED(head)" "FAILED(head): a failed run on the real head is reported, whatever the badge says"
assert_contains "$out" "NOT-APPROVED" "approval reads detailed_merge_status, not an approved:true flag with an empty approved_by"
pass "case B: FAILED(head) verdict and not_approved read from merge status"

# --- fixture C: the head's own run is blocked on manual jobs - not "passed" -
# alongside a real conflict, both reported in the same line. ----------------
case_c=$(make_case c)
cat > "$case_c/mr.json" <<'JSON'
{"state":"opened","draft":false,"work_in_progress":false,
 "sha":"cccccccc1111","detailed_merge_status":"conflict",
 "approved":false,"approved_by":[],"has_conflicts":true,"merged_at":null,
 "head_pipeline":{"sha":"cccccccc2222","status":"manual"}}
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
{"state":"opened","draft":true,"work_in_progress":false,
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
{"state":"opened","draft":false,"work_in_progress":false,
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
{"state":"merged","draft":false,"work_in_progress":false,
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
printf '{"state":"opened","draft":false,"work_in_progress":false,\n "sha":"aaaaaaaa1111","detailed_merge_status":"mergeable",\n "approved":false,"approved_by":[],"has_conflicts":false,"merged_at":null,\n "description":"broken by a raw control char ->\x01<- right there",\n "head_pipeline":{"sha":"aaaaaaaa2222","status":"success"}}' \
  > "$case_g/mr.json"
out=$(run_case "$case_g" "$case_g/mr.json" "" g/g!7)
assert_contains "$out" "green(head)" "a control character in MR text is scrubbed rather than breaking the parse"
pass "case G: a raw control character in the response does not break parsing"
