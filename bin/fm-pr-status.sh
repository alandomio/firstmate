#!/usr/bin/env bash
# fm-pr-status.sh - one compact line per GitLab merge request: merged,
# approved, conflicted, and whether its reported pipeline is ACTUALLY green.
#
# The trap this exists to close: GitLab's head_pipeline is frequently a
# MERGE-RESULT run against a synthetic merge commit, not the branch head, so a
# green badge can sit on top of a head that failed or was never tested at all.
# This script never reports the badge. It establishes whether a run existed
# against the real head and returns one of five verdicts:
#   green(head)   a run on the real branch head succeeded - trustworthy
#   FAILED(head)  a run on the real head failed, whatever the badge says
#   manual(head)  the head's run is blocked on manual jobs - not "passed"
#   NO-HEAD-RUN   nothing ever ran against the head; "never tested" is not "passed"
#   green(merge)  only a merge-result run is green; the head is unverified
#
# Two further traps stay encoded because they were each got wrong by hand:
#   - merge request descriptions routinely carry raw control characters that
#     break `jq`/`json.load` mid-parse; the API response is scrubbed first.
#   - approval is read from detailed_merge_status, not the `approved` flag:
#     approved==true with an empty approved_by list means zero approvals were
#     REQUIRED, not that anyone signed off.
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
# Usage:
#   fm-pr-status.sh <repo> <iid> [<iid>...]
#   fm-pr-status.sh <repo!iid> [<repo!iid>...]
#   fm-pr-status.sh --repo group/subgroup/project <iid>...
#   fm-pr-status.sh -h | --help
#
# Output columns: repo!num  state  approval  conflicts  pipeline  head-sha  [notes]
#
# Requires: glab (authenticated against the target GitLab host), python3.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

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

fm_prstat_one() {  # <repo-path> <iid>
  local repo="$1" iid="$2" enc j state sha pipe_sha pipe dms conflicts merged draft
  enc=$(urlenc "$repo")

  j=$(glab api "projects/$enc/merge_requests/$iid" 2>/dev/null | scrub)
  if [ -z "$j" ]; then
    printf '%-34s  %s\n' "$(basename "$repo")!$iid" "UNREACHABLE (no data - check repo/number/auth)"
    return
  fi

  read -r state draft sha pipe_sha pipe dms conflicts merged <<EOF
$(printf '%s' "$j" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("? ? - - none ? ? -"); raise SystemExit(0)
hp=d.get("head_pipeline") or {}
print(" ".join(str(x) for x in (
  d.get("state","?"),
  "draft" if d.get("draft") or d.get("work_in_progress") else "ready",
  (d.get("sha") or "-")[:8],
  (hp.get("sha") or "-")[:8],
  hp.get("status") or "none",
  d.get("detailed_merge_status") or "?",
  "yes" if d.get("has_conflicts") else "no",
  (d.get("merged_at") or "-")[:10],
)))
' 2>/dev/null)
EOF

  if [ "$merged" != "-" ] && [ -n "$merged" ]; then
    printf '%-34s  %-7s %s\n' "$(basename "$repo")!$iid" "MERGED" "on $merged"
    return
  fi

  # Was there ever a run against the REAL head, and how did it go?
  local verdict notes=""
  if [ "$sha" = "$pipe_sha" ]; then
    case "$pipe" in
      success) verdict="green(head)" ;;
      failed)  verdict="FAILED(head)" ;;
      manual)  verdict="manual(head)" ;;
      *)       verdict="$pipe(head)" ;;
    esac
  else
    # Badge is a merge-result run. Ask specifically about the head.
    local hp
    hp=$(glab api "projects/$enc/merge_requests/$iid/pipelines?per_page=30" 2>/dev/null | scrub \
      | python3 -c '
import json,sys
try: rs=json.load(sys.stdin)
except Exception: raise SystemExit(0)
if not isinstance(rs,list): raise SystemExit(0)
want=sys.argv[1]
for r in rs:
    if str(r.get("sha","")).startswith(want) and "/merge" not in str(r.get("ref","")):
        print(r.get("status","?")); break
' "$sha" 2>/dev/null)
    case "${hp:-}" in
      success) verdict="green(head)"; notes="badge is merge-result; head run is green too" ;;
      failed)  verdict="FAILED(head)"; notes="badge shows $pipe on merge-result $pipe_sha" ;;
      "")      verdict="NO-HEAD-RUN"; notes="only a merge-result run exists ($pipe on $pipe_sha)" ;;
      *)       verdict="$hp(head)"; notes="badge is merge-result $pipe_sha" ;;
    esac
  fi

  # Approval, read from the merge status rather than a third API call:
  # approved==true with an empty approved_by list just means none was required.
  local appr
  case "$dms" in
    not_approved)  appr="NOT-APPROVED" ;;
    draft_status)  appr="draft" ;;
    mergeable)     appr="ok" ;;
    conflict)      appr="-" ;;
    checking)      appr="checking" ;;
    *)             appr="$dms" ;;
  esac

  [ "$conflicts" = "yes" ] && notes="${notes:+$notes; }CONFLICTS"
  [ "$draft" = "draft" ] && notes="${notes:+$notes; }DRAFT - cannot merge until marked ready"

  printf '%-34s  %-7s %-13s %-13s %-9s %s\n' \
    "$(basename "$repo")!$iid" "$state" "$appr" "$verdict" "$sha" "${notes:+- $notes}"
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
