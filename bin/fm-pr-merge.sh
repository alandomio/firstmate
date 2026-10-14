#!/usr/bin/env bash
# Merge a task's PR or MR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical URL is parsed by bin/fm-pr-lib.sh. A GitHub pull request is
# addressed through gh-axi by the derived owner and repository; a GitLab merge
# request is addressed through glab by the project URL rebuilt from the parsed
# host and path, so any instance works and no host is hardcoded.
#
# Merge method on GitHub defaults to --squash when the caller passes none of
# --squash, --merge, --rebase, or --method after the optional -- separator.
# GitLab adds no method flag at all: its merge method is the project's own
# setting, which the merge API applies, and imposing squash there would override
# that convention rather than mirror the GitHub default.
#
# A GitLab merge is refused unless every pre-merge condition holds, each read
# live at merge time rather than taken from recorded metadata: the merge request
# is open, detailed_merge_status is mergeable, has_conflicts is false,
# blocking_discussions_resolved is true, and the head pipeline succeeded for the
# exact current head commit. That pipeline is accepted in one of two shapes:
#   - a branch pipeline that ran at the current head itself, or
#   - a merge-result pipeline, the only kind some projects run: source
#     merge_request_event and ref exactly refs/merge-requests/<iid>/merge, the
#     shape bin/fm-pr-status.sh reports as "badge is merge-result", classified
#     by the shared predicate in bin/fm-pr-lib.sh. Its synthetic merge commit,
#     read live from the repository, must have exactly two parents with the
#     current head second, proving the run was built for this head and not an
#     older one, and no branch pipeline at the current head may be anything but
#     success, so a green merge-result badge never hides a red head run. Its
#     first parent, the target tip it was built on, is not compared, just as a
#     branch pipeline at head is not re-run when the target moves.
# The pipeline condition has one live-checked exception: a merge request with
# no head pipeline at all is refused unless the project's own
# jobs_enabled/builds_access_level settings, read fresh from the forge, confirm
# CI cannot run there for any commit; a pipeline that ran and failed, is still
# running, or ran at or was built for a stale commit is always refused
# regardless of that project setting, because a pipeline plainly can run there.
# Every failing condition is reported, not just the first. The verified head is
# then passed to glab as --sha, so a push that lands between that read and the
# merge fails the merge instead of landing commits nothing verified. A recorded
# pr_head that disagrees with the live head is reported rather than trusted,
# because a rebase moves the head and leaves the recorded value stale. Reading
# that state needs glab and jq, and either one absent stops the merge before
# any state is recorded.
#
# Extra args must not include --repo or -R in any form, including a bundled
# short-option cluster such as -yR, because the repository comes only from the
# URL, nor --sha on GitLab because the head comes only from the live read.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra forge merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
# glab resolves the instance from the project URL passed to -R, so the host is
# rebuilt from the parsed identity rather than read from any ambient default.
PROJECT_URL="https://$FM_PR_HOST/$FM_PR_PATH"
shift 2
[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
      --*) ;;
      # A single-dash argument is a short-option cluster, which both CLIs expand
      # one character at a time, so -yR carries --repo exactly as a bare -R does.
      -*R*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_head_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --sha|--sha=*)
        echo "error: extra merge arguments must not override the head commit" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1
[ "$PROVIDER" != gitlab ] || reject_head_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# Reading the merge request state needs both tools. Report them together and
# before anything is recorded, so a missing tool is a named prerequisite rather
# than a merge that is armed and then refused for an unexplained reason.
GITLAB_MISSING=
if [ "$PROVIDER" = gitlab ]; then
  command -v glab >/dev/null 2>&1 || GITLAB_MISSING="glab"
  if ! command -v jq >/dev/null 2>&1; then
    GITLAB_MISSING="${GITLAB_MISSING:+$GITLAB_MISSING and }jq"
  fi
  if [ -n "$GITLAB_MISSING" ]; then
    echo "error: merging a GitLab merge request requires $GITLAB_MISSING on PATH" >&2
    exit 1
  fi
fi

# The recorded head is read before bin/fm-pr-check.sh rewrites the metadata,
# because that script re-records pr= and drops a pr_head= it cannot resolve.
RECORDED_HEAD=
if [ "$PROVIDER" = gitlab ]; then
  RECORDED_HEAD=$(grep '^pr_head=' "$META" | tail -1 | cut -d= -f2- || true)
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

# True (0) only when this GitLab project's own settings make it structurally
# impossible to produce a pipeline for any commit, never merely when this one
# merge request happens to lack a pipeline: job rules can skip a commit, or a
# pipeline can simply not have started yet, on a project that runs CI fine.
# Read live, on every call, because the capability is a project-level forge
# fact rather than a caller-asserted flag: a live re-read cannot go stale the
# way a remembered or passed-in claim could. Called only when the merge
# request's own head pipeline is absent, so a project that can run CI but
# has none at head still hits the ordinary refusal below. Prints a loud
# notice and returns 0 when the project is confirmed incapable of running
# jobs at all; returns 1 (falling back to the ordinary refusal) whenever that
# is not confirmed, including when the capability itself cannot be read.
gitlab_ci_disabled_at_project_level() {
  local encoded project_json jobs_enabled builds_access
  encoded=$(jq -rn --arg v "$FM_PR_PATH" '$v|@uri' 2>/dev/null) || return 1
  if ! project_json=$(glab api "projects/$encoded" --hostname "$FM_PR_HOST" 2>/dev/null) \
    || [ -z "$project_json" ]; then
    return 1
  fi
  if ! jobs_enabled=$(printf '%s' "$project_json" | jq -r '
      if type == "object" then ((.jobs_enabled) | tostring) else error("not an object") end
      ' 2>/dev/null); then
    return 1
  fi
  builds_access=$(printf '%s' "$project_json" | jq -r '(.builds_access_level // "") | tostring' 2>/dev/null) || builds_access=""
  if [ "$jobs_enabled" = false ] || [ "$builds_access" = disabled ]; then
    printf 'notice: %s has CI disabled at the project level (jobs_enabled=%s, builds_access_level=%s); merging with no pipeline check because none can ever run\n' \
      "$PROJECT_URL" "$jobs_enabled" "${builds_access:-unset}" >&2
    return 0
  fi
  return 1
}

# Whether a successful merge-result head pipeline was built for live_head, read
# live from the forge. Appends to the caller's refusals for every reason it
# was not, and leaves them untouched when it was. The synthetic merge commit's
# parents are [target tip, source head], so its second parent names the head
# the run tested. A branch pipeline at the live head is read too, because a
# green merge-result badge can sit on top of a failed run of the head itself.
gitlab_check_merge_result_head() {  # <pipeline-sha> <live-head>
  local merge_sha=$1 head=$2 encoded commit_json built_for pipelines_json runs ref status
  if ! encoded=$(jq -rn --arg v "$FM_PR_PATH" '$v|@uri' 2>/dev/null) \
    || ! commit_json=$(glab api "projects/$encoded/repository/commits/$merge_sha" --hostname "$FM_PR_HOST" 2>/dev/null) \
    || ! built_for=$(printf '%s' "$commit_json" | jq -r '
        if type == "object" and (.parent_ids | type) == "array" and (.parent_ids | length) == 2
        then (.parent_ids[1] | tostring) else error("not a two-parent merge commit") end
        ' 2>/dev/null) \
    || ! fm_pr_head_valid "$built_for"; then
    refusals="$refusals  - could not read which head the merge-result pipeline at \"$merge_sha\" was built for
"
  elif [ "$built_for" != "$head" ]; then
    refusals="$refusals  - the head pipeline is a merge-result run built for \"$built_for\", not for the current head $head
"
  fi
  # Newest first, external statuses dropped: those are third-party tools
  # reporting through the commit status API, not this project's own CI.
  if ! pipelines_json=$(glab api "projects/$encoded/merge_requests/$PR_NUMBER/pipelines?per_page=100" --hostname "$FM_PR_HOST" 2>/dev/null) \
    || ! runs=$(printf '%s' "$pipelines_json" | jq -r --arg head "$head" '
        if type == "array" then
          [.[] | select(type == "object" and (.sha | tostring) == $head
                        and (.source | tostring) != "external")]
          | sort_by(.id) | reverse | .[]
          | ((.ref // "") | tostring | gsub("[\t\n]"; " ")) + "\t" + ((.status // "") | tostring)
        else error("not a list") end' 2>/dev/null); then
    refusals="$refusals  - could not read whether a branch pipeline ran at the current head $head
"
    return
  fi
  while IFS=$(printf '\t') read -r ref status; do
    [ -n "$ref$status" ] || continue
    fm_pr_gitlab_ref_is_merge_result "$ref" && continue
    [ "$status" = success ] \
      || refusals="$refusals  - a branch pipeline at the current head $head is \"${status:-unreadable}\", not success
"
    break
  done <<RUNS
$runs
RUNS
}

# Pre-merge conditions for a GitLab merge request, read from one live view of
# the merge request. Sets FM_PR_MERGE_HEAD to the verified head on success and
# returns non-zero after reporting every condition that failed.
FM_PR_MERGE_HEAD=
gitlab_verify_mergeable() {
  local json fields line
  local total=0 named=0 refusals=''
  local state='' detail='' conflicts='' discussions=''
  local live_head='' pipeline_sha='' pipeline_status='' pipeline_source='' pipeline_ref=''
  local accepted_shape=''

  # GITLAB_HOST is set to the same host the project URL already carries, so the
  # instance is taken from the parsed URL by both signals and never from the
  # operator's configured default.
  if ! json=$(GITLAB_HOST="$FM_PR_HOST" glab mr view "$PR_NUMBER" -R "$PROJECT_URL" -F json 2>/dev/null) \
    || [ -z "$json" ]; then
    echo "error: could not read the GitLab merge request state before merging" >&2
    return 1
  fi
  # One named field per line. The names keep a trailing empty value readable
  # after command substitution strips blank lines, and an absent or null field
  # becomes an empty string or the literal "null", neither of which satisfies any
  # check below, so an unreadable field refuses the merge instead of passing it.
  if ! fields=$(printf '%s' "$json" | jq -r '
      if type == "object" then
        "state=" + ((.state // "") | tostring),
        "detail=" + ((.detailed_merge_status // "") | tostring),
        "conflicts=" + (.has_conflicts | tostring),
        "discussions=" + (.blocking_discussions_resolved | tostring),
        "head=" + ((.sha // "") | tostring),
        "pipeline_sha=" + ((.head_pipeline.sha // "") | tostring),
        "pipeline_status=" + ((.head_pipeline.status // "") | tostring),
        "pipeline_source=" + ((.head_pipeline.source // "") | tostring),
        "pipeline_ref=" + ((.head_pipeline.ref // "") | tostring)
      else
        error("merge request payload is not an object")
      end' 2>/dev/null); then
    echo "error: could not read the GitLab merge request state before merging" >&2
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=} ;;
      detail=*) detail=${line#detail=} ;;
      conflicts=*) conflicts=${line#conflicts=} ;;
      discussions=*) discussions=${line#discussions=} ;;
      head=*) live_head=${line#head=} ;;
      pipeline_sha=*) pipeline_sha=${line#pipeline_sha=} ;;
      pipeline_status=*) pipeline_status=${line#pipeline_status=} ;;
      pipeline_source=*) pipeline_source=${line#pipeline_source=} ;;
      pipeline_ref=*) pipeline_ref=${line#pipeline_ref=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  # Every field named exactly once and no unnamed line: a value carrying a
  # newline would split into a line no name matches, so it is refused here
  # rather than silently truncated into a value a check could accept.
  if [ "$named" -ne 9 ] || [ "$total" -ne 9 ]; then
    echo "error: could not read the GitLab merge request state before merging" >&2
    return 1
  fi

  if ! fm_pr_head_valid "$live_head"; then
    echo "error: could not read the GitLab merge request head commit before merging" >&2
    return 1
  fi
  # A rebase moves the head and leaves the recorded value behind, so the
  # disagreement is reported and the live head is what gets verified and merged.
  if [ -n "$RECORDED_HEAD" ] && [ "$RECORDED_HEAD" != "$live_head" ]; then
    printf 'notice: recorded head %s disagrees with the live head %s; verifying the live head\n' \
      "$RECORDED_HEAD" "$live_head" >&2
  fi

  [ "$state" = opened ] \
    || refusals="$refusals  - state is \"${state:-unreadable}\", not open
"
  [ "$detail" = mergeable ] \
    || refusals="$refusals  - detailed_merge_status is \"${detail:-unreadable}\", not mergeable
"
  [ "$conflicts" = false ] \
    || refusals="$refusals  - has_conflicts is \"${conflicts:-unreadable}\", not false
"
  [ "$discussions" = true ] \
    || refusals="$refusals  - blocking_discussions_resolved is \"${discussions:-unreadable}\", not true
"
  # An empty pipeline_status means head_pipeline is null: this merge request
  # has no pipeline at all, which is refused below unless the project itself
  # is confirmed incapable of ever running one. Any other status (failed,
  # canceled, running) or a status of success at the wrong commit means a
  # pipeline exists or ran, so the project can plainly run CI and both checks
  # apply exactly as before regardless of project capability.
  if [ -n "$pipeline_status" ] || ! gitlab_ci_disabled_at_project_level; then
    [ "$pipeline_status" = success ] \
      || refusals="$refusals  - the head pipeline status is \"${pipeline_status:-none}\", not success
"
    if [ "$pipeline_sha" = "$live_head" ]; then
      accepted_shape="a successful pipeline at head $live_head"
    elif [ "$pipeline_source" = merge_request_event ] \
      && fm_pr_gitlab_ref_is_merge_result "$pipeline_ref" "$PR_NUMBER" \
      && fm_pr_head_valid "$pipeline_sha"; then
      # Read only for a green run: a failed or running merge-result pipeline is
      # already refused above, and its parents cannot change that.
      if [ "$pipeline_status" = success ]; then
        gitlab_check_merge_result_head "$pipeline_sha" "$live_head"
      fi
      accepted_shape="a successful merge-result pipeline ($pipeline_sha) built for head $live_head"
    else
      refusals="$refusals  - the head pipeline ran at \"${pipeline_sha:-none}\", not at the current head $live_head
"
    fi
  fi

  if [ -n "$refusals" ]; then
    printf 'error: refusing to merge %s\n' "$URL" >&2
    printf '%s' "$refusals" >&2
    return 1
  fi
  if [ -n "$pipeline_status" ]; then
    printf 'verified: %s is open and mergeable, with %s\n' "$URL" "$accepted_shape" >&2
  else
    printf 'verified: %s is open and mergeable at head %s; merging with no pipeline check, per the notice above\n' \
      "$URL" "$live_head" >&2
  fi
  FM_PR_MERGE_HEAD=$live_head
}

case "$PROVIDER" in
  github)
    merge_args=()
    if ! caller_has_merge_method "$@"; then
      merge_args=(--squash)
    fi
    gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
    ;;
  gitlab)
    gitlab_verify_mergeable || exit 1
    # --sha binds the merge to the head this run verified, so a push that lands
    # in between is refused by GitLab instead of merged unverified. --yes only
    # skips the interactive confirmation, which no supervised run can answer;
    # the conditions above are what authorize the merge.
    GITLAB_HOST="$FM_PR_HOST" glab mr merge "$PR_NUMBER" -R "$PROJECT_URL" \
      --sha "$FM_PR_MERGE_HEAD" --yes "$@"
    ;;
  *)
    echo "error: invalid PR merge request" >&2
    exit 2
    ;;
esac
