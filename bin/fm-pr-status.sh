#!/usr/bin/env bash
# fm-pr-status.sh - one compact line per GitLab merge request: its state,
# target branch, approvals, merge status, conflicts, whether its pipeline is
# ACTUALLY green on the real head, and whether its project runs CI at all and
# requires a passing pipeline to merge. Read-only: it never merges, approves,
# or comments. Read merge request state with this tool rather than a
# hand-rolled glab/jq pipeline, which has misread each trap below.
#
# The trap this exists to close: GitLab's head_pipeline is frequently a
# MERGE-RESULT run against a synthetic merge commit, not the branch head, so a
# green badge can sit on top of a head that failed or was never tested at all.
# This script never reports the badge. It establishes whether a run existed
# against the real head and reports one of:
#   green(head)     a run on the real branch head succeeded - trustworthy
#   FAILED(head)    a run on the real head failed, whatever the badge says
#   manual(head)    the head's run is blocked on manual jobs - not "passed"
#   <status>(head)  any other head-run status, printed under its own name
#   NO-HEAD-RUN     nothing ever ran against the head; "never tested" is not
#                   "passed"
#   UNVERIFIED      the head-run lookup itself could not be read, so no
#                   pipeline verdict is claimed at all
#
# There is deliberately no green verdict for a merge-result run: a green badge
# over an unverified head prints NO-HEAD-RUN, and the badge appears only in the
# notes under its own status and origin ("badge is merge-result (success on
# <sha>)"), so a green merge-result run is never mistakable for a green head.
#
# A verdict is only ever printed from data that was actually read. When a call
# fails or returns something unreadable the row says UNREACHABLE (the merge
# request itself could not be read) or UNVERIFIED (the head-run lookup could
# not be read) and the run exits non-zero, rather than reporting "never tested"
# for a response nobody managed to look at. The one case where an unreadable
# response still leaves a head verdict standing is a badge that already ran
# against the head: the verdict is real, but the same unreadable list was also
# the only view of any external status, so the note says those could not be
# checked and that row exits non-zero too.
#
# Three further traps stay encoded because they were each got wrong by hand:
#   - merge request descriptions routinely carry raw control characters that
#     break `jq`/`json.load` mid-parse; the API response is scrubbed first.
#   - approval is never read from the `approved` flag: approved==true with an
#     empty approved_by list means zero approvals were REQUIRED, not that anyone
#     signed off. The approvals endpoint's approved_by and approvals_left decide
#     it, with detailed_merge_status=not_approved always winning:
#       approved(<n>)          n people approved and none are still required
#       not-required           nobody approved and none are required
#       NOT-APPROVED[(<k>-left)]  approval is still required
#       none-given             nobody approved; whether any is required could
#                              not be told from the response
#       UNVERIFIED             the approvals could not be read at all
#   - a merge request's pipeline list mixes real CI runs with source=external
#     entries that third-party tools (Atlantis and friends) post through the
#     commit status API. Only non-external runs decide a verdict; a red
#     external status is disclosed in the notes on its own terms, and a head
#     carrying nothing but external entries is still NO-HEAD-RUN.
#
# GitLab-only by design: the merge-result-vs-head gap above is this script's
# entire reason to exist, and GitHub has no equivalent - its checks attach
# directly to the head commit, so there is no comparable trap to close, and a
# GitHub path would add an unrelated, un-hardened code path for no verdict this
# tool needs to make. fm-pr-check.sh / fm-pr-merge.sh / fm-pr-poll.sh remain
# the forge-agnostic family for arming and landing a PR/MR once it is ready.
#
# A repo argument containing "/" is used verbatim as a GitLab project path.
# A bare shortname instead resolves from a local clone at projects/<name> (the
# same registry firstmate already keeps for project management): its origin
# remote is read and its path extracted, regardless of host, so this script
# carries no hardcoded organization. An unresolvable shortname fails with a
# clear message naming what it looked for rather than guessing a prefix.
#
# A full merge request URL (https://<host>/<group>/<project>/-/merge_requests/<iid>)
# is parsed by bin/fm-pr-lib.sh and read from that URL's own host, so any
# instance works; every other form reads glab's configured default host.
#
# Usage:
#   fm-pr-status.sh <mr-url> [<mr-url>...]
#   fm-pr-status.sh <repo> <iid> [<iid>...]
#   fm-pr-status.sh <repo!iid> [<repo!iid>...]
#   fm-pr-status.sh --repo group/subgroup/project <iid>...
#   fm-pr-status.sh -h | --help
#
# Output columns: repo!num state into=<target> ci=<verdict> approval=<approval> merge=<detailed_merge_status> conflicts=<no|YES> head=<sha> jobs=<enabled|DISABLED|?> must-succeed=<yes|no|?> [- notes]
# jobs= is DISABLED when the project's jobs_enabled or builds_access_level
# says CI can never run there, and must-succeed= is the project's "Pipelines
# must succeed" setting; either prints ? when the project could not be read
# or did not say (as GitLab's reduced view for low-permission tokens does),
# and into= prints ? when the response named no target branch. Every ? fails
# the run just as an unreadable read does.
# A merged merge request prints just "repo!num merged into=<target> on=<date>",
# and an unreadable one just "repo!num UNREACHABLE (<why>)". Draft state, what
# the badge actually is, and any failed external status are all disclosed as
# their own notes - never folded into the pipeline verdict.
# Exit status is non-zero when any row, or any part of one, could not be read.
#
# Requires: glab (authenticated against the target GitLab host), python3.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

# Resolve a bare shortname to its GitLab project path from a local clone's
# origin remote. A path containing "/" is treated as already resolved.
fm_prstat_repo_path() {  # <shortname-or-path>
  local input=$1 dir url rest
  case "$input" in
    */*) printf '%s' "$input"; return 0 ;;
  esac
  dir="$PROJECTS/$input"
  if [ ! -d "$dir/.git" ] && [ ! -f "$dir/.git" ]; then
    echo "error: unknown repo '$input' - no clone at projects/$input; pass a full group/project path instead" >&2
    return 1
  fi
  url=$(git -C "$dir" remote get-url origin 2>/dev/null) || {
    echo "error: projects/$input has no readable origin remote" >&2
    return 1
  }
  case "$url" in
    https://*|http://*|ssh://*|git://*)
      rest=${url#*://}; rest=${rest#*@}; rest=${rest#*/} ;;
    *@*:*|*:*)
      rest=${url#*:} ;;
    *)
      echo "error: could not parse a project path from projects/$input's origin remote: $url" >&2
      return 1 ;;
  esac
  rest=${rest%.git}
  rest=${rest#/}
  if [ -z "$rest" ]; then
    echo "error: could not parse a project path from projects/$input's origin remote: $url" >&2
    return 1
  fi
  printf '%s' "$rest"
}

urlenc() { printf '%s' "$1" | sed 's|/|%2F|g'; }
# Control characters routinely appear in merge request descriptions and break
# jq/json.load mid-parse; strip them before anything touches the response.
scrub() { tr -d '\000-\010\013\014\016-\037'; }

# One GitLab API read, scrubbed. ROW_HOST is the host a full URL named, or
# empty for glab's configured default. The exit status is glab's own.
fm_prstat_api() {  # <api-path>
  local out rc=0
  if [ -n "$ROW_HOST" ]; then
    out=$(glab api "$1" --hostname "$ROW_HOST" 2>/dev/null) || rc=$?
  else
    out=$(glab api "$1" 2>/dev/null) || rc=$?
  fi
  printf '%s' "$out" | scrub
  return "$rc"
}

# The project's CI capability and "Pipelines must succeed" setting, left in
# PROJ_CACHE_VAL as "<jobs> <must-succeed>". Called directly, never in a
# subshell, so consecutive rows of one project reuse one read and an
# unreadable project still marks the run failed.
PROJ_CACHE_KEY=""
PROJ_CACHE_VAL=""
fm_prstat_project() {  # <repo-path> <encoded-path>
  local key="$ROW_HOST|$1" raw rc=0 val
  [ "$key" != "$PROJ_CACHE_KEY" ] || return 0
  raw=$(fm_prstat_api "projects/$2") || rc=$?
  val=$(printf '%s' "$raw" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: d=None
if not isinstance(d,dict) or "id" not in d:
    print("UNREADABLE"); raise SystemExit(0)
je=d.get("jobs_enabled"); bal=d.get("builds_access_level")
if je is False or bal == "disabled": jobs="DISABLED"
elif je is True or bal in ("enabled", "private"): jobs="enabled"
else: jobs="?"
m=d.get("only_allow_merge_if_pipeline_succeeds")
print(jobs, "yes" if m is True else "no" if m is False else "?")
' 2>/dev/null)
  if [ "$rc" -ne 0 ] || [ -z "$val" ] || [ "$val" = UNREADABLE ]; then
    STATUS=1
    val="? ?"
  fi
  case "$val" in *'?'*) STATUS=1 ;; esac
  PROJ_CACHE_KEY=$key
  PROJ_CACHE_VAL=$val
}

# Who approved and whether any approval is still required, left in
# ROW_APPROVAL; the verdicts are listed in the header and
# detailed_merge_status=not_approved always wins. Called directly, never in a
# subshell, so an unreadable response still marks the run failed.
ROW_APPROVAL=""
fm_prstat_approval() {  # <encoded-path> <iid> <detailed_merge_status>
  local raw rc=0 val
  raw=$(fm_prstat_api "projects/$1/merge_requests/$2/approvals") || rc=$?
  [ "$rc" -eq 0 ] || raw=""
  val=$(printf '%s' "$raw" | python3 -c '
import json,sys
dms=sys.argv[1]
try: d=json.load(sys.stdin)
except Exception: d=None
if not isinstance(d,dict) or not ("approved_by" in d or "approvals_left" in d):
    print("NOT-APPROVED" if dms == "not_approved" else "UNVERIFIED"); raise SystemExit(0)
by=d.get("approved_by")
n=len(by) if isinstance(by,list) else 0
left=d.get("approvals_left")
if isinstance(left,bool) or not isinstance(left,int): left=None
if dms == "not_approved" or (left is not None and left > 0):
    print("NOT-APPROVED(%d-left)" % left if left else "NOT-APPROVED")
elif n > 0: print("approved(%d)" % n)
elif left == 0 or dms == "mergeable": print("not-required")
else: print("none-given")
' "$3" 2>/dev/null)
  if [ -z "$val" ]; then
    val="UNVERIFIED"
  fi
  [ "$val" != UNVERIFIED ] || STATUS=1
  ROW_APPROVAL=$val
}

fm_prstat_unreachable() {  # <repo-path> <iid> <why>
  printf '%-34s  %s\n' "$(basename "$1")!$2" "UNREACHABLE ($3 - check repo/number/auth)"
  STATUS=1
}

ROW_HOST=""
fm_prstat_one() {  # <repo-path> <iid>
  local repo="$1" iid="$2" enc j rc=0 state sha pipe_sha pipe pipe_source pipe_ref dms conflicts merged draft target
  enc=$(urlenc "$repo")

  j=$(fm_prstat_api "projects/$enc/merge_requests/$iid") || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$j" ]; then
    fm_prstat_unreachable "$repo" "$iid" "no data"
    return
  fi

  # The parser emits a lone UNREADABLE sentinel rather than defaulted fields:
  # `glab api` prints an error body on stdout for a non-2xx, and defaulting
  # that to "- / - / none" would compare equal and fabricate a head verdict.
  read -r state draft sha pipe_sha pipe pipe_source pipe_ref dms conflicts merged target <<EOF
$(printf '%s' "$j" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("UNREADABLE"); raise SystemExit(0)
if not isinstance(d,dict) or "iid" not in d or "state" not in d:
    print("UNREADABLE"); raise SystemExit(0)
hp=d.get("head_pipeline") or {}
print(" ".join(str(x) for x in (
  d.get("state") or "?",
  "draft" if d.get("draft") or d.get("work_in_progress") else "ready",
  d.get("sha") or "-",
  hp.get("sha") or "-",
  hp.get("status") or "none",
  hp.get("source") or "-",
  hp.get("ref") or "-",
  d.get("detailed_merge_status") or "?",
  "yes" if d.get("has_conflicts") else "no",
  (d.get("merged_at") or "-")[:10],
  "".join(str(d.get("target_branch") or "?").split()) or "?",
)))
' 2>/dev/null)
EOF
  if [ -z "$state" ] || [ "$state" = "UNREADABLE" ]; then
    fm_prstat_unreachable "$repo" "$iid" "unreadable response"
    return
  fi
  [ "$target" != "?" ] || STATUS=1

  if [ "$merged" != "-" ] && [ -n "$merged" ]; then
    printf '%-34s  %-7s into=%s on=%s\n' "$(basename "$repo")!$iid" "merged" "$target" "$merged"
    return
  fi

  if [ "$sha" = "-" ]; then
    fm_prstat_unreachable "$repo" "$iid" "no head sha in response"
    return
  fi

  # Was there ever a run against the REAL head, and how did it go? Shas are
  # compared in full and truncated only for display, so two distinct commits
  # sharing a short prefix are never read as the same run.
  local verdict notes="" sha_short=${sha:0:8} pipe_short=${pipe_sha:0:8}
  local praw prc=0 plook ci_status ext_red pipe_kind badge lookup_ok=yes

  # The pipeline list is read for every row, not only when the badge looks
  # wrong: it is the only place a red external status is visible, and dropping
  # it on the rows whose badge happens to match would hide exactly the signal
  # the notes promise to disclose.
  praw=$(fm_prstat_api "projects/$enc/merge_requests/$iid/pipelines?per_page=30") || prc=$?
  plook=$(printf '%s' "$praw" | python3 -c '
import json,sys
want,badge_ref,badge_source,badge_sha=sys.argv[1:5]
def is_merge_result(ref):
    # Merge-result runs carry refs/merge-requests/<iid>/merge exactly; a
    # substring test would also discard a source branch called fix/merge-foo.
    ref=str(ref or "")
    return ref.startswith("refs/merge-requests/") and ref.endswith("/merge")
if badge_sha == "-": kind="none"
elif badge_source == "external": kind="external"
elif is_merge_result(badge_ref): kind="merge-result"
else: kind=badge_source
ci="-"; ext=[]; ok=True
try: rs=json.load(sys.stdin)
except Exception: ok=False
if ok and not isinstance(rs,list): ok=False
if ok:
    # Newest first: the endpoint does not document an order, and "the head run"
    # means the most recent one, not whichever the response happened to list.
    for r in sorted((x for x in rs if isinstance(x,dict)),
                    key=lambda x: x.get("id") or 0, reverse=True):
        if str(r.get("sha","")) != want: continue
        # source=external is a third-party tool reporting through the commit
        # status API; it says nothing about whether the repo own CI ran.
        if str(r.get("source","")) == "external":
            if str(r.get("status","")) == "failed":
                ext.append(str(r.get("name") or
                               ("#%s" % r.get("id") if r.get("id") is not None else "external")))
            continue
        if is_merge_result(r.get("ref")): continue
        if ci == "-": ci=str(r.get("status") or "?")
print(ci if ok else "UNREADABLE")
print(", ".join(ext))
print(kind)
' "$sha" "$pipe_ref" "$pipe_source" "$pipe_sha" 2>/dev/null)
  ci_status=$(printf '%s\n' "$plook" | sed -n 1p)
  ext_red=$(printf '%s\n' "$plook" | sed -n 2p)
  pipe_kind=$(printf '%s\n' "$plook" | sed -n 3p)
  if [ "$prc" -ne 0 ] || [ -z "$plook" ] || [ "$ci_status" = UNREADABLE ]; then
    lookup_ok=no
    ext_red=""
  fi
  [ -n "$pipe_kind" ] || pipe_kind="-"

  # Say what the badge actually is. Only a merge-result ref makes it a
  # merge-result run; a stale push or schedule run on an older commit is a
  # different situation and is named as one.
  case "$pipe_kind" in
    none)         badge="no head pipeline badge recorded on this merge request" ;;
    external)     badge="badge is an external status ($pipe on $pipe_short)" ;;
    merge-result) badge="badge is merge-result ($pipe on $pipe_short)" ;;
    -)            badge="badge is a run of unrecorded origin ($pipe on $pipe_short)" ;;
    *)            badge="badge is a $pipe_kind run ($pipe on $pipe_short)" ;;
  esac

  if [ "$sha" = "$pipe_sha" ] && [ "$pipe_source" != external ]; then
    case "$pipe" in
      success) verdict="green(head)" ;;
      failed)  verdict="FAILED(head)" ;;
      manual)  verdict="manual(head)" ;;
      *)       verdict="$pipe(head)" ;;
    esac
    if [ "$lookup_ok" = no ]; then
      notes="external statuses could not be checked - the pipeline list could not be read"
      STATUS=1
    fi
  elif [ "$lookup_ok" = no ]; then
    verdict="UNVERIFIED"
    notes="$badge; head-run lookup failed - the pipeline list could not be read"
    STATUS=1
  else
    case "$ci_status" in
      success) verdict="green(head)"; notes="head run is green too" ;;
      failed)  verdict="FAILED(head)" ;;
      manual)  verdict="manual(head)" ;;
      -)       verdict="NO-HEAD-RUN" ;;
      *)       verdict="$ci_status(head)" ;;
    esac
    notes="${badge}${notes:+; $notes}"
  fi
  [ -n "$ext_red" ] && notes="${notes:+$notes; }external status red: $ext_red"

  fm_prstat_approval "$enc" "$iid" "$dms"
  fm_prstat_project "$repo" "$enc"
  local jobs must conflict_col=no
  [ "$conflicts" = yes ] && conflict_col=YES
  read -r jobs must <<EOF
$PROJ_CACHE_VAL
EOF

  [ "$draft" = "draft" ] && notes="${notes:+$notes; }DRAFT - cannot merge until marked ready"

  printf '%-34s  %-7s into=%s ci=%s approval=%s merge=%s conflicts=%s head=%s jobs=%s must-succeed=%s%s\n' \
    "$(basename "$repo")!$iid" "$state" "$target" "$verdict" "$ROW_APPROVAL" "$dms" \
    "$conflict_col" "$sha_short" "$jobs" "$must" "${notes:+ - $notes}"
}

[ "$#" -gt 0 ] || { usage; exit 0; }

CUR=""
STATUS=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      shift
      [ "$#" -gt 0 ] || { echo "error: --repo requires a value" >&2; exit 2; }
      CUR=$(fm_prstat_repo_path "$1") || exit 1
      ;;
    -h|--help) usage; exit 0 ;;
    https://*)
      if fm_pr_url_parse "$1" && [ "$FM_PR_PROVIDER" = gitlab ]; then
        ROW_HOST=$FM_PR_HOST
        fm_prstat_one "$FM_PR_PATH" "$FM_PR_NUMBER"
        ROW_HOST=""
      else
        echo "error: '$1' is not a GitLab merge request URL (https://<host>/<group>/<project>/-/merge_requests/<iid>)" >&2
        STATUS=1
      fi
      ;;
    *!*)
      repo=$(fm_prstat_repo_path "${1%%!*}") || { STATUS=1; shift; continue; }
      fm_prstat_one "$repo" "${1##*!}"
      ;;
    [0-9]*)
      if [ -n "$CUR" ]; then
        fm_prstat_one "$CUR" "$1"
      else
        echo "  no repo set before '$1' - use 'repo!num' or a repo name first" >&2
        STATUS=1
      fi
      ;;
    *) CUR=$(fm_prstat_repo_path "$1") || exit 1 ;;
  esac
  shift
done

exit "$STATUS"
