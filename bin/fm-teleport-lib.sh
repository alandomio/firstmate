#!/usr/bin/env bash
# Shared git and transcript mechanics for task teleport (bin/fm-teleport.sh).
#
# Sourced by bin/fm-teleport.sh, which owns the transaction, and by
# bin/fm-spawn.sh --teleport, which calls fm_teleport_prepare_worktree on a
# freshly acquired pooled worktree before launching the adopting agent.
#
# The work travels as one WIP commit held under the private ref
# refs/teleport/<task> in each home's project clone, never on any remote. Its
# parent is the worker's HEAD and its tree is the worktree's full content,
# tracked and untracked, honouring .gitignore and info/exclude. The commit is
# built through a private index, so taking the snapshot never moves the
# worker's HEAD, branch, index, or files. Its message is a plain "WIP snapshot"
# and, without a configured identity, its author is "snapshot"; the teleport
# manifest, not the commit, names the task, the snapshot, and the branch.
#
# The commit crosses hosts as a git bundle inside the teleport payload. The
# bundle leaves out history the origin's default branch already holds; the
# receiving clone fetches origin first when it lacks those prerequisites.
#
# Restoring puts the branch back at the WIP parent and the WIP tree back as
# uncommitted changes, so the WIP commit itself never enters the branch.
#
# A Claude transcript lives at <claude-dir>/projects/<encoded-cwd>/<session>.jsonl,
# where <claude-dir> is CLAUDE_CONFIG_DIR or ~/.claude and every
# non-alphanumeric byte of the cwd becomes "-". Installing a transcript rewrites
# the source worktree and source home paths to this host's, longest first, as
# literal strings.

fm_teleport_ref() { # <task>
  printf 'refs/teleport/%s\n' "$1"
}

fm_teleport_valid_task_id() { # <task>
  case "$1" in ''|-*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$1" in *..*) return 1 ;; esac
  return 0
}

fm_teleport_valid_session() { # <session>
  case "$1" in ''|-*|*[!A-Za-z0-9-]*) return 1 ;; esac
  return 0
}

fm_teleport_sha256() { # <file>
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}

fm_teleport_claude_dir() {
  printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
}

fm_teleport_claude_project_dir() { # <cwd>
  printf '%s/projects/%s\n' "$(fm_teleport_claude_dir)" "$(printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
}

# Print the newest transcript path recorded for <worktree>, checking both the
# path as given and its physical form. Prints nothing when none exists.
fm_teleport_claude_latest_transcript() { # <worktree>
  local wt=$1 real dir best='' f
  real=$(CDPATH='' cd -- "$wt" 2>/dev/null && pwd -P) || real=$wt
  for dir in "$(fm_teleport_claude_project_dir "$wt")" "$(fm_teleport_claude_project_dir "$real")"; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*.jsonl; do
      [ -f "$f" ] && [ ! -L "$f" ] || continue
      if [ -z "$best" ] || [ "$f" -nt "$best" ]; then best=$f; fi
    done
  done
  [ -z "$best" ] || printf '%s\n' "$best"
}

# Print the tree the worktree would commit right now, via a private index.
fm_teleport_worktree_tree() { # <worktree>
  local wt=$1 idx tree
  idx=$(mktemp "${TMPDIR:-/tmp}/fm-teleport-index.XXXXXX") || return 1
  rm -f "$idx"
  if ! GIT_INDEX_FILE=$idx git -C "$wt" read-tree HEAD 2>/dev/null \
    || ! GIT_INDEX_FILE=$idx git -C "$wt" add -A -- . 2>/dev/null \
    || ! tree=$(GIT_INDEX_FILE=$idx git -C "$wt" write-tree 2>/dev/null); then
    rm -f "$idx"
    return 1
  fi
  rm -f "$idx"
  printf '%s\n' "$tree"
}

# Create the WIP commit for <task> without touching the worktree, record it
# under refs/teleport/<task>, and print it.
fm_teleport_snapshot() { # <worktree> <task>
  local wt=$1 task=$2 tree head wip
  head=$(git -C "$wt" rev-parse --verify --quiet 'HEAD^{commit}') || return 1
  tree=$(fm_teleport_worktree_tree "$wt") || return 1
  if [ -n "$(git -C "$wt" config user.email 2>/dev/null)" ]; then
    wip=$(printf 'WIP snapshot\n' | git -C "$wt" commit-tree "$tree" -p "$head") || return 1
  else
    wip=$(printf 'WIP snapshot\n' | git -C "$wt" -c user.name=snapshot -c user.email=snapshot@localhost commit-tree "$tree" -p "$head") || return 1
  fi
  git -C "$wt" update-ref "$(fm_teleport_ref "$task")" "$wip" || return 1
  printf '%s\n' "$wip"
}

# Write a bundle carrying refs/teleport/<task>, minus history that the origin's
# default branch already holds.
fm_teleport_bundle_create() { # <worktree> <task> <bundle-file>
  local wt=$1 ref default
  ref=$(fm_teleport_ref "$2")
  default=$(git -C "$wt" rev-parse --verify --quiet refs/remotes/origin/HEAD 2>/dev/null \
    || git -C "$wt" rev-parse --verify --quiet refs/remotes/origin/main 2>/dev/null \
    || git -C "$wt" rev-parse --verify --quiet refs/remotes/origin/master 2>/dev/null || true)
  if [ -n "$default" ] && [ "$(git -C "$wt" rev-parse "$ref")" != "$default" ]; then
    git -C "$wt" bundle create "$3" "$ref" --not "$default"
  else
    git -C "$wt" bundle create "$3" "$ref"
  fi
}

# Install refs/teleport/<task> from <bundle> into <clone> and prove it names
# <wip>. Fetches origin first when the clone lacks the bundle's prerequisites.
fm_teleport_bundle_import() { # <clone> <task> <bundle-file> <wip>
  local clone=$1 ref bundle=$3 wip=$4
  ref=$(fm_teleport_ref "$2")
  if ! git -C "$clone" bundle verify "$bundle" >/dev/null 2>&1; then
    git -C "$clone" fetch --quiet origin || { echo "error: could not fetch origin into $clone for the snapshot's history" >&2; return 1; }
    git -C "$clone" bundle verify "$bundle" >/dev/null 2>&1 || { echo "error: the snapshot bundle does not apply to $clone" >&2; return 1; }
  fi
  git -C "$clone" fetch --quiet "$bundle" "+$ref:$ref" || { echo "error: could not read the snapshot from its bundle" >&2; return 1; }
  [ "$(git -C "$clone" rev-parse --verify --quiet "$ref^{commit}")" = "$wip" ] || {
    git -C "$clone" update-ref -d "$ref" 2>/dev/null || true
    echo "error: the snapshot bundle does not hold the snapshot named in the manifest" >&2; return 1; }
}

# Check out the teleported work in a clean worktree: branch at the WIP parent,
# WIP tree as uncommitted changes. Refuses an existing local branch of the same
# name that is not an ancestor of the WIP parent, so nothing it holds is moved.
fm_teleport_restore_worktree() { # <worktree> <task> <wip> <branch>
  local wt=$1 task=$2 wip=$3 branch=$4 ref base existing
  ref=$(fm_teleport_ref "$task")
  [ -n "$wip" ] && [ "$(git -C "$wt" rev-parse --verify --quiet "$ref^{commit}")" = "$wip" ] || {
    echo "error: $ref does not hold the teleport snapshot of $task" >&2; return 1; }
  base=$(git -C "$wt" rev-parse --verify --quiet "$wip^1") || { echo "error: teleport snapshot has no parent" >&2; return 1; }
  [ -z "$(git -C "$wt" status --porcelain)" ] || { echo "error: worktree $wt is not clean; refusing to restore over it" >&2; return 1; }
  if [ -n "$branch" ]; then
    git check-ref-format --branch "$branch" >/dev/null 2>&1 || { echo "error: unsafe branch name in snapshot: $branch" >&2; return 1; }
    if existing=$(git -C "$wt" rev-parse --verify --quiet "refs/heads/$branch^{commit}"); then
      git -C "$wt" merge-base --is-ancestor "$existing" "$base" || {
        echo "error: local branch $branch already holds commits that are not in the teleported work; refusing to move it" >&2; return 1; }
    fi
    git -C "$wt" checkout --quiet -B "$branch" "$base" || return 1
  else
    git -C "$wt" checkout --quiet --detach "$base" || return 1
  fi
  git -C "$wt" read-tree -u --reset "$wip" || return 1
  git -C "$wt" reset --quiet
}

# Leave a worktree whose content still equals the WIP snapshot detached at that
# commit, so it reads clean on its snapshot, as teardown --teleported requires.
# Refuses when the content changed after the snapshot.
fm_teleport_settle_on_snapshot() { # <worktree> <task>
  local wt=$1 task=$2 ref wip tree
  ref=$(fm_teleport_ref "$task")
  wip=$(git -C "$wt" rev-parse --verify --quiet "$ref^{commit}") || {
    echo "error: no $ref in $wt" >&2; return 1; }
  tree=$(fm_teleport_worktree_tree "$wt") || { echo "error: could not read $wt" >&2; return 1; }
  [ "$tree" = "$(git -C "$wt" rev-parse "$wip^{tree}")" ] || {
    echo "error: $wt changed after the teleport snapshot; leaving it untouched" >&2; return 1; }
  git -C "$wt" checkout --quiet --detach || return 1
  git -C "$wt" reset --quiet "$wip"
}

# Replace each literal <from> with <to> in <file>, in place.
fm_teleport_map_paths() { # <file> <from> <to> [<from> <to>...]
  local file=$1
  shift
  [ "$#" -ge 2 ] || return 0
  perl -i -e '
    my @pairs;
    while (@ARGV > 1 && $ARGV[0] ne "--") { push @pairs, [shift @ARGV, shift @ARGV]; }
    shift @ARGV;
    @pairs = sort { length($b->[0]) <=> length($a->[0]) } grep { length $_->[0] } @pairs;
    while (my $line = <>) {
      for my $p (@pairs) { $line =~ s/\Q$p->[0]\E/$p->[1]/g; }
      print $line;
    }
  ' "$@" -- "$file"
}

# Finish an adopting worktree for fm-spawn --teleport: restore the work, then,
# when the manifest names a Claude session, install its transcript for this
# worktree and render the arrival note the resumed session receives.
fm_teleport_prepare_worktree() { # <worktree> <task> <data-dir> <home> <state-dir>
  local wt=$1 task=$2 data=$3 home=$4 state=$5 dir manifest session src_wt src_home dest arrival
  dir="$data/$task/teleport"
  manifest="$dir/manifest"
  [ -f "$manifest" ] || { echo "error: no teleport manifest at $manifest" >&2; return 1; }
  fm_teleport_restore_worktree "$wt" "$task" "$(fm_meta_get "$manifest" wip)" "$(fm_meta_get "$manifest" branch)" || return 1
  session=$(fm_meta_get "$manifest" session)
  [ -n "$session" ] || return 0
  fm_teleport_valid_session "$session" || { echo "error: invalid session id in $manifest" >&2; return 1; }
  [ -f "$dir/session.jsonl" ] || { echo "error: manifest names session $session but no transcript arrived" >&2; return 1; }
  src_wt=$(fm_meta_get "$manifest" source_worktree)
  src_home=$(fm_meta_get "$manifest" source_home)
  dest="$(fm_teleport_claude_project_dir "$wt")/$session.jsonl"
  mkdir -p "$(dirname "$dest")" || return 1
  [ ! -e "$dest" ] || { echo "error: a transcript for session $session already exists at $dest" >&2; return 1; }
  cp "$dir/session.jsonl" "$dest.tmp" || return 1
  fm_teleport_map_paths "$dest.tmp" "$src_wt" "$wt" "$src_home" "$home" || { rm -f "$dest.tmp"; return 1; }
  mv "$dest.tmp" "$dest" || return 1
  arrival="$dir/arrival.md"
  [ -f "$arrival" ] || return 0
  fm_teleport_map_paths "$arrival" "__WORKTREE__" "$wt" "__STATUS__" "$state/$task.status"
}
