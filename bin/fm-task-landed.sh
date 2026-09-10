#!/usr/bin/env bash
# fm-task-landed.sh - one line per task answering: is any of its work
# unlanded, and is its pull/merge request ready?
#
# The trap this exists to close: `git status` prints task work and debris the
# same way. Tracked modifications and commits on no forge remote are WORK AT
# RISK; untracked files are LEFTOVERS - often debris that predates the task
# and sits in several worktrees of the same project. Every row reports the two
# in separate, labeled fields ("work: ..." and "leftovers: ..."), and no count
# ever folds one into the other.
# An untracked path is not automatically debris, though: a new file a worker
# never `git add`ed looks identical. So each untracked path is classified by
# one structural, read-only signal - whether the same path also sits untracked
# in a sibling worktree of the same repository (`git worktree list`, the
# primary clone included). Shared paths are pre-existing debris; a path found
# only in this worktree may be task work, so the script cannot tell and says so
# with UNKNOWN instead of calling it a leftover. The row shows both counts
# ("leftovers: <n> untracked, <n> only here"), and -v lists every path with its
# classification. Nothing is ever called safe to discard. The harness artifacts
# fm-teardown.sh already ignores (.claude/, .fm-grok-turnend, .fm-kimi-turnend)
# are not counted at all.
#
# "Landed" uses fm-teardown.sh's meaning, read without its fetch: a commit has
# landed when it is reachable from a forge remote-tracking ref, when the task's
# PR is merged with a head containing it, or when its changes are already in
# the default branch. The no-mistakes gate remote is a local validation copy,
# not a forge, so a commit reachable only from `no-mistakes/*` is NOT landed.
# Unpushed commits are counted against every forge remote at once, never as
# `origin/<branch>..HEAD`, so a branch whose own remote ref was deleted after
# its merge is still evaluated rather than erroring on an ambiguous argument.
#
# Verdicts - a closed set, first match wins:
#   UNKNOWN         landing could not be established: no meta, no worktree=
#                   key, an unreadable worktree, unpushed commits whose
#                   remote branch is gone with no proof the work landed, or
#                   untracked paths found in no sibling worktree.
#                   A real outcome with its reason in the notes - never a guess.
#   NO-WORKTREE     the meta names a worktree path that no longer exists;
#                   nothing local is left to lose or to inspect.
#   UNLANDED-WORK   tracked uncommitted changes, or commits on no forge remote
#                   and not proven landed. Tearing down would lose them.
#   PR-CONFLICT     no local work at risk; the PR/MR is open with conflicts.
#   PR-OPEN         no local work at risk; the PR/MR is open without
#                   conflicts (its merge status is in the pr: field).
#   PR-UNCHECKED    no local work at risk; a pr= is recorded but its state
#                   was not read (a sweep without --remote, or a failed lookup).
#   LEFTOVERS-ONLY  no local work at risk and no open PR; untracked files
#                   remain, every one also untracked in a sibling worktree
#                   (what fm-teardown.sh refuses on as "uncommitted").
#   LANDED-CLEAN    no local work at risk, no open PR, nothing untracked.
# A merged or closed PR/MR does not change the local verdict; its state is
# still shown in the pr: field. PR-* verdicts cover GitLab merge requests too.
#
# Read-only by construction: git runs with GIT_OPTIONAL_LOCKS=0 so `git status`
# never refreshes the index, nothing is fetched, and the default-branch content
# check compares existing trees with `git diff` rather than writing a merge tree.
# The only network access is the PR/MR lookup: `gh pr view` for a GitHub pull
# URL, `glab api` for a GitLab `/-/merge_requests/` URL, each bounded by
# FM_TASK_LANDED_TIMEOUT seconds (default 20). A missing tool, timeout, or
# unreadable response prints pr: UNREACHABLE rather than a state.
#
# Network policy: a named task looks its PR up by default (--no-remote skips
# it); the no-argument fleet sweep never touches the network unless --remote is
# given, because one API call per task is slow and rate-limited.
#
# Usage:
#   fm-task-landed.sh [-v] [--no-remote] <task-id> [<task-id>...]
#   fm-task-landed.sh [-v] [--remote]               every task with a state/*.meta
#   fm-task-landed.sh -h | --help
#
# Options:
#   -v, --verbose   add indented detail under each row: worktree, branch, own
#                   remote ref, forge refs holding HEAD, each tracked change,
#                   each leftover, and the full PR/MR URL and fields
#   --remote        look PRs up during the fleet sweep
#   --no-remote     skip PR lookups for named tasks
#
# Row format:
#   <task>  <VERDICT>  <kind>  work: <n> unpushed, <n> tracked  |  leftovers: <n> untracked, <n> only here  |  pr: <summary>[ - notes]
# A "?" count means that fact could not be read. pr: is "-" when no pr= is
# recorded, "not-checked" when lookups are off, "UNREACHABLE" when the lookup
# failed, otherwise the number, state, and merge status.
#
# Exit status: 0 when every row was fully established, whatever its verdict;
# 1 when any row is UNKNOWN or any PR lookup failed; 2 on a usage error.
#
# Honors FM_HOME (FM_STATE_OVERRIDE for the state directory) like the other
# bin/ scripts. Requires git and python3; gh or glab only for PR lookups.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

# Never let a read refresh the index or take an optional lock in a live worktree.
export GIT_OPTIONAL_LOCKS=0

GATE_REMOTE=no-mistakes
REMOTE_TIMEOUT=${FM_TASK_LANDED_TIMEOUT:-20}
case "$REMOTE_TIMEOUT" in ''|*[!0-9]*|0) REMOTE_TIMEOUT=20 ;; esac

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

meta_get() {  # <file> <key>: last value of key= in the meta file
  awk -v k="$2" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { print v }' "$1"
}

tl_git() { git -C "$WT" "$@"; }

# Print the forge remotes of $WT, one per line: every remote except the gate.
tl_forge_remotes() {
  tl_git remote 2>/dev/null | while IFS= read -r r; do
    [ -n "$r" ] && [ "$r" != "$GATE_REMOTE" ] && printf '%s\n' "$r"
  done
}

# Print the default-branch ref to compare content against, or nothing.
tl_default_ref() {
  local r target
  while IFS= read -r r; do
    target=$(tl_git symbolic-ref -q "refs/remotes/$r/HEAD" 2>/dev/null) || continue
    [ -n "$target" ] && { printf '%s\n' "$target"; return 0; }
  done <<EOF
$(tl_forge_remotes)
EOF
  if [ "$MODE" = local-only ]; then
    for target in refs/heads/main refs/heads/master; do
      tl_git rev-parse -q --verify "$target" >/dev/null 2>&1 && { printf '%s\n' "$target"; return 0; }
    done
  fi
  return 0
}

# Are the changes HEAD makes since its merge-base with <ref> already present,
# byte for byte, in <ref>? Read-only: compares only the paths the branch
# touched. Returns non-zero when unproven (no ref, or <ref> differs on any of
# those paths, e.g. because it changed them again later), never a guess.
tl_content_in_default() {  # <ref>
  local ref=$1 base touched p
  local -a paths=()
  [ -n "$ref" ] || return 1
  base=$(tl_git merge-base HEAD "$ref" 2>/dev/null) || return 1
  touched=$(tl_git diff --no-renames --name-only "$base" HEAD 2>/dev/null) || return 1
  [ -n "$touched" ] || return 0
  while IFS= read -r -d '' p; do
    paths+=("$p")
  done < <(tl_git diff --no-renames --name-only -z "$base" HEAD 2>/dev/null)
  [ "${#paths[@]}" -gt 0 ] || return 1
  GIT_LITERAL_PATHSPECS=1 tl_git diff --quiet HEAD "$ref" -- "${paths[@]}" 2>/dev/null
}

# Classify each untracked path of $WT: shared when the same path is also
# untracked in a sibling worktree of the same repository, otherwise only-here.
# Sets SHARED and rewrites LEFTOVER_LIST as "<class><TAB><path>" lines.
tl_classify_leftovers() {
  local self sibs p sib class out=''
  SHARED=0
  [ -n "$LEFTOVER_LIST" ] || return 0
  self=$(cd "$WT" && pwd -P)
  sibs=$(tl_git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' |
    while IFS= read -r p; do
      [ -d "$p" ] || continue
      [ "$(cd "$p" && pwd -P)" = "$self" ] || printf '%s\n' "$p"
    done)
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    class='only-here'
    case "$p" in
      '"'*) ;;  # git quoted an unusual name: never match it, so never call it debris
      *)
        while IFS= read -r sib; do
          [ -n "$sib" ] || continue
          if [ -e "$sib/${p%/}" ] &&
            ! GIT_LITERAL_PATHSPECS=1 git -C "$sib" ls-files --error-unmatch -- "${p%/}" >/dev/null 2>&1; then
            class=shared; break
          fi
        done <<EOF
$sibs
EOF
        ;;
    esac
    [ "$class" = shared ] && SHARED=$((SHARED + 1))
    out="$out$class"$'\t'"$p"$'\n'
  done <<EOF
$LEFTOVER_LIST
EOF
  LEFTOVER_LIST=$out
}

# Control characters in PR/MR descriptions break JSON parsers mid-parse.
scrub() { tr -d '\000-\010\013\014\016-\037'; }

# Look the PR/MR at <url> up and set PR_STATE PR_DRAFT PR_CONFLICT PR_MERGE
# PR_HEAD PR_LABEL, or PR_ERR with the reason nothing could be read.
tl_pr_lookup() {  # <url>
  local url=$1 rest host path proj iid enc raw rc=0 parsed
  PR_STATE='' PR_DRAFT='' PR_CONFLICT='' PR_MERGE='' PR_HEAD='' PR_ERR='' PR_LABEL=''
  case "$url" in
    */-/merge_requests/*)
      rest=${url#*://}; host=${rest%%/*}; path=${rest#*/}
      proj=${path%%/-/merge_requests/*}
      iid=${path##*/-/merge_requests/}; iid=${iid%%[!0-9]*}
      PR_LABEL="!$iid"
      [ -n "$iid" ] && [ -n "$proj" ] || { PR_ERR="unparseable GitLab URL"; return; }
      command -v glab >/dev/null 2>&1 || { PR_ERR="glab not installed"; return; }
      enc=$(printf '%s' "$proj" | sed 's|/|%2F|g')
      raw=$(fm_run_timed "$REMOTE_TIMEOUT" glab api --hostname "$host" "projects/$enc/merge_requests/$iid" </dev/null 2>/dev/null) || rc=$?
      parsed=$(printf '%s' "$raw" | scrub | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("UNREADABLE"); raise SystemExit(0)
if not isinstance(d,dict) or "iid" not in d or "state" not in d:
    print("UNREADABLE"); raise SystemExit(0)
state={"opened":"OPEN","merged":"MERGED","closed":"CLOSED"}.get(d.get("state"),str(d.get("state")).upper())
print(" ".join((state,
  "yes" if d.get("draft") or d.get("work_in_progress") else "no",
  "yes" if d.get("has_conflicts") else "no",
  str(d.get("detailed_merge_status") or "?"),
  str(d.get("sha") or "-"))))
' 2>/dev/null)
      ;;
    */pull/[0-9]*)
      iid=${url##*/pull/}; iid=${iid%%[!0-9]*}
      PR_LABEL="#$iid"
      command -v gh >/dev/null 2>&1 || { PR_ERR="gh not installed"; return; }
      raw=$(GH_PROMPT_DISABLED=1 fm_run_timed "$REMOTE_TIMEOUT" gh pr view "$url" --json state,isDraft,mergeable,mergeStateStatus,headRefOid </dev/null 2>/dev/null) || rc=$?
      parsed=$(printf '%s' "$raw" | scrub | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("UNREADABLE"); raise SystemExit(0)
if not isinstance(d,dict) or "state" not in d:
    print("UNREADABLE"); raise SystemExit(0)
m=d.get("mergeable")
print(" ".join((str(d.get("state")).upper(),
  "yes" if d.get("isDraft") else "no",
  {"CONFLICTING":"yes","MERGEABLE":"no"}.get(m,"?"),
  str(d.get("mergeStateStatus") or "?").lower(),
  str(d.get("headRefOid") or "-"))))
' 2>/dev/null)
      ;;
    *)
      PR_LABEL='pr'
      PR_ERR="not a GitHub pull or GitLab merge request URL"
      return
      ;;
  esac
  if [ "$rc" -eq 124 ]; then
    PR_ERR="lookup timed out after ${REMOTE_TIMEOUT}s"
    return
  fi
  if [ "$rc" -ne 0 ] || [ -z "$parsed" ] || [ "$parsed" = UNREADABLE ]; then
    PR_ERR="lookup failed or unreadable"
    return
  fi
  read -r PR_STATE PR_DRAFT PR_CONFLICT PR_MERGE PR_HEAD <<EOF
$parsed
EOF
}

tl_note() { NOTES="${NOTES:+$NOTES; }$1"; }

# Evaluate one task into the row globals, then print it.
tl_task() {  # <task-id>
  local id=$1 meta status line default_ref gate_holds upstream track branch_ref r
  local own_ref="" meta_branch
  VERDICT='' KIND='-' UNPUSHED='?' TRACKED='?' LEFTOVERS='?' SHARED='?' PRSUM='-' NOTES=''
  WT='' MODE='' PR_URL='' BRANCH='' TRACKED_LIST='' LEFTOVER_LIST='' ON_REMOTE='' DETAIL_REF=''
  PR_STATE='' PR_DRAFT='' PR_CONFLICT='' PR_MERGE='' PR_HEAD='' PR_ERR='' PR_LABEL=''
  meta="$STATE/$id.meta"

  if [ ! -f "$meta" ]; then
    VERDICT='UNKNOWN'; tl_note "no meta at state/$id.meta"
    tl_print "$id"; return
  fi
  WT=$(meta_get "$meta" worktree)
  KIND=$(meta_get "$meta" kind); [ -n "$KIND" ] || KIND=-
  MODE=$(meta_get "$meta" mode)
  PR_URL=$(meta_get "$meta" pr)
  meta_branch=$(meta_get "$meta" branch)

  if [ -n "$PR_URL" ]; then
    if [ "$LOOKUP" = on ]; then
      tl_pr_lookup "$PR_URL"
      if [ -n "$PR_ERR" ]; then
        PRSUM="$PR_LABEL UNREACHABLE"; tl_note "pr lookup: $PR_ERR"; EXIT=1
      else
        PRSUM="$PR_LABEL $PR_STATE"
        [ "$PR_DRAFT" = yes ] && PRSUM="$PRSUM draft"
        if [ "$PR_STATE" = OPEN ]; then
          if [ "$PR_CONFLICT" = yes ]; then PRSUM="$PRSUM CONFLICT"; else PRSUM="$PRSUM $PR_MERGE"; fi
        fi
      fi
    else
      PRSUM=not-checked
    fi
  fi

  if [ -z "$WT" ]; then
    VERDICT='UNKNOWN'; tl_note "meta has no worktree="
    tl_print "$id"; return
  fi
  if [ ! -d "$WT" ]; then
    VERDICT='NO-WORKTREE'
    tl_print "$id"; return
  fi
  if ! tl_git rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    ! tl_git rev-parse -q --verify HEAD >/dev/null 2>&1; then
    VERDICT='UNKNOWN'
    tl_note "not a readable git checkout with a commit ($(tl_git rev-parse HEAD 2>&1 >/dev/null | head -1))"
    tl_print "$id"; return
  fi
  BRANCH=$(tl_git symbolic-ref -q --short HEAD 2>/dev/null || true)
  if [ -n "$meta_branch" ] && [ "$meta_branch" != "$BRANCH" ]; then
    tl_note "meta branch $meta_branch but ${BRANCH:-a detached HEAD} is checked out"
  fi

  # Work at risk (1): tracked changes, staged or not. Leftovers: untracked.
  if ! status=$(tl_git status --porcelain=v1 --untracked-files=normal 2>/dev/null); then
    VERDICT='UNKNOWN'; tl_note "git status failed"
    tl_print "$id"; return
  fi
  TRACKED=0 LEFTOVERS=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      '!! '*) ;;
      '?? .claude/'|'?? .claude/'*|'?? .fm-grok-turnend'|'?? .fm-kimi-turnend') ;;
      '?? '*) LEFTOVERS=$((LEFTOVERS + 1)); LEFTOVER_LIST="$LEFTOVER_LIST${line#?? }"$'\n' ;;
      *) TRACKED=$((TRACKED + 1)); TRACKED_LIST="$TRACKED_LIST$line"$'\n' ;;
    esac
  done <<EOF
$status
EOF
  tl_classify_leftovers

  # Work at risk (2): commits reachable from no forge remote ref.
  default_ref=$(tl_default_ref)
  local -a not_refs
  not_refs=(--not "--exclude=$GATE_REMOTE/*" --remotes)
  if [ "$MODE" = local-only ] && [ -n "$default_ref" ]; then
    not_refs+=("$default_ref")
  fi
  if ! UNPUSHED=$(tl_git rev-list --count HEAD "${not_refs[@]}" 2>/dev/null); then
    UNPUSHED='?'; VERDICT='UNKNOWN'; tl_note "could not count commits missing from the forge remotes"
    tl_print "$id"; return
  fi
  ON_REMOTE=$(tl_git for-each-ref --contains HEAD --format='%(refname)' refs/remotes/ 2>/dev/null |
    while IFS= read -r r; do
      case "$r" in
        refs/remotes/"$GATE_REMOTE"/*|refs/remotes/*/HEAD) ;;
        *) printf '%s\n' "${r#refs/remotes/}" ;;
      esac
    done)
  gate_holds=$(tl_git for-each-ref --contains HEAD --count=1 --format=x "refs/remotes/$GATE_REMOTE/" 2>/dev/null)

  if [ -n "$BRANCH" ]; then
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      if tl_git rev-parse -q --verify "refs/remotes/$r/$BRANCH" >/dev/null 2>&1; then
        own_ref="$r/$BRANCH"; break
      fi
    done <<EOF
$(tl_forge_remotes)
EOF
    branch_ref=$(tl_git for-each-ref --format='%(upstream:short)%09%(upstream:track)' "refs/heads/$BRANCH" 2>/dev/null)
    upstream=${branch_ref%%$'\t'*}; track=${branch_ref#*$'\t'}
  else
    upstream='' track=''
  fi
  if [ -n "$own_ref" ]; then
    DETAIL_REF="$own_ref present"
  elif [ "$track" = "[gone]" ]; then
    DETAIL_REF="gone (upstream $upstream was deleted)"
  else
    DETAIL_REF="absent${upstream:+ (tracks $upstream)}"
  fi

  if [ "$TRACKED" -gt 0 ]; then
    VERDICT='UNLANDED-WORK'
  elif [ "$UNPUSHED" -gt 0 ]; then
    [ -n "$gate_holds" ] && tl_note "HEAD is on the $GATE_REMOTE gate only, which is not a landing"
    if [ "$PR_STATE" = MERGED ] && [ -n "$PR_HEAD" ] && [ "$PR_HEAD" != - ] &&
      tl_git merge-base --is-ancestor HEAD "$PR_HEAD" >/dev/null 2>&1; then
      tl_note "unpushed commits are contained in the merged $PR_LABEL head"
    elif tl_content_in_default "$default_ref"; then
      tl_note "unpushed commits' changes are already in ${default_ref#refs/remotes/}"
    elif [ "$PR_STATE" = MERGED ] && [ -n "$PR_HEAD" ] && [ "$PR_HEAD" != - ] &&
      tl_git cat-file -e "$PR_HEAD^{commit}" 2>/dev/null; then
      VERDICT='UNLANDED-WORK'; tl_note "commits beyond the merged $PR_LABEL head"
    elif [ "$PR_STATE" = OPEN ]; then
      VERDICT='UNLANDED-WORK'
    elif [ "$track" = "[gone]" ] || [ "$PR_STATE" = MERGED ] ||
      { [ -n "$PR_URL" ] && [ -z "$PR_STATE" ]; }; then
      VERDICT='UNKNOWN'
      tl_note "commits on no forge remote; the branch was pushed once but landing is unproven - run with the PR lookup or let fm-teardown.sh decide"
    else
      VERDICT='UNLANDED-WORK'
    fi
  fi

  if [ -z "$VERDICT" ] && [ "$LEFTOVERS" -gt "$SHARED" ]; then
    VERDICT='UNKNOWN'
    tl_note "$((LEFTOVERS - SHARED)) untracked path(s) in no sibling worktree - may be task work never added; inspect with -v"
  fi

  if [ -z "$VERDICT" ]; then
    if [ "$PR_STATE" = OPEN ] && [ "$PR_CONFLICT" = yes ]; then
      VERDICT='PR-CONFLICT'
    elif [ "$PR_STATE" = OPEN ]; then
      VERDICT='PR-OPEN'
    elif [ -n "$PR_URL" ] && [ -z "$PR_STATE" ]; then
      VERDICT='PR-UNCHECKED'
    elif [ "$LEFTOVERS" -gt 0 ]; then
      VERDICT='LEFTOVERS-ONLY'
    else
      VERDICT='LANDED-CLEAN'
    fi
  fi
  tl_print "$id"
}

tl_print() {  # <task-id>
  local id=$1 line class only='?'
  [ "$VERDICT" = UNKNOWN ] && EXIT=1
  case "$LEFTOVERS$SHARED" in
    *[!0-9]*) ;;
    *) only=$((LEFTOVERS - SHARED)) ;;
  esac
  printf '%-*s  %-14s  %-10s  work: %2s unpushed, %2s tracked  |  leftovers: %2s untracked, %2s only here  |  pr: %s%s\n' \
    "$IDW" "$id" "$VERDICT" "$KIND" "$UNPUSHED" "$TRACKED" "$LEFTOVERS" "$only" "$PRSUM" "${NOTES:+ - $NOTES}"
  [ "$VERBOSE" = yes ] || return 0
  printf '    worktree: %s (%s)\n' "${WT:--}" "$([ -n "$WT" ] && [ -d "$WT" ] && echo present || echo missing)"
  [ -n "$DETAIL_REF" ] || return 0
  printf '    branch: %s; own remote ref: %s\n' "${BRANCH:-detached HEAD}" "$DETAIL_REF"
  if [ -n "$ON_REMOTE" ]; then
    printf '    HEAD on forge refs: %s\n' "$(printf '%s\n' "$ON_REMOTE" | head -3 | paste -sd, - | sed 's/,/, /g')$([ "$(printf '%s\n' "$ON_REMOTE" | wc -l)" -gt 3 ] && echo ", ...")"
  else
    printf '    HEAD on forge refs: none\n'
  fi
  while IFS= read -r line; do
    [ -n "$line" ] && printf '    WORK tracked: %s\n' "$line"
  done <<EOF
$TRACKED_LIST
EOF
  while IFS=$'\t' read -r class line; do
    [ -n "$line" ] || continue
    if [ "$class" = shared ]; then
      printf '    leftover (untracked here and in a sibling worktree): %s\n' "$line"
    else
      printf '    UNTRACKED ONLY HERE (may be work never added): %s\n' "$line"
    fi
  done <<EOF
$LEFTOVER_LIST
EOF
  if [ -n "$PR_URL" ]; then
    if [ -n "$PR_STATE" ]; then
      printf '    pr: %s state=%s draft=%s conflicts=%s merge-status=%s head=%s\n' \
        "$PR_URL" "$PR_STATE" "$PR_DRAFT" "$PR_CONFLICT" "$PR_MERGE" "${PR_HEAD:0:12}"
    else
      printf '    pr: %s (state not read)\n' "$PR_URL"
    fi
  fi
}

VERBOSE=no LOOKUP_FLAG=
IDS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -v|--verbose) VERBOSE=yes ;;
    --remote) LOOKUP_FLAG=on ;;
    --no-remote) LOOKUP_FLAG=off ;;
    --) shift; IDS+=("$@"); break ;;
    -*) echo "error: unknown option $1 (see --help)" >&2; exit 2 ;;
    *) IDS+=("$1") ;;
  esac
  shift
done

if [ "${#IDS[@]}" -gt 0 ]; then
  LOOKUP=${LOOKUP_FLAG:-on}
else
  LOOKUP=${LOOKUP_FLAG:-off}
  for f in "$STATE"/*.meta; do
    [ -f "$f" ] && IDS+=("$(basename "$f" .meta)")
  done
  if [ "${#IDS[@]}" -eq 0 ]; then
    echo "no tasks: no state/*.meta under $STATE"
    exit 0
  fi
fi

IDW=4
for id in "${IDS[@]}"; do
  case "$id" in
    ''|*/*|.*) echo "error: invalid task id '$id'" >&2; exit 2 ;;
  esac
  [ "${#id}" -gt "$IDW" ] && IDW=${#id}
done

EXIT=0
for id in "${IDS[@]}"; do
  tl_task "$id"
done
exit "$EXIT"
