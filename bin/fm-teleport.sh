#!/usr/bin/env bash
# fm-teleport.sh - move a running ship or scout task from this home to a remote
# secondmate home and back, keeping its work and, for Claude, its conversation.
#
# Usage:
#   fm-teleport.sh <task-id> [--to <secondmate>] [--session <claude-session-id>]
#   fm-teleport.sh <task-id> --back [--to <secondmate>]
#   fm-teleport.sh remind [--lid]
#
#   --to       the remote secondmate route in data/secondmates.md (default
#              alwayson). With --back it names where the task lives now.
#   --session  the Claude session to carry, when the newest transcript for the
#              worker's directory is not the right one.
#   --back     bring a task this home previously teleported out back here.
#   remind     raise one notification "N tasks running, teleport out?" through
#              the config/wedge-alarm channels when this home has live local
#              workers. Never moves anything. --lid fires only while the lid
#              reads closed. Rate-limited to once per FM_TELEPORT_REMIND_SECS
#              (default 600). Wire it to a sleep hook; docs/remote-secondmates.md
#              "Teleporting a task" shows how.
#
# Protocol verbs. Each runs in the home that owns that side of the move, either
# directly or through bin/fm-on.sh; operators use the two forms above.
#   fm-teleport.sh describe <task-id>
#   fm-teleport.sh check <task-id> <project-key> <origin-url>
#   fm-teleport.sh pack <task-id> [--session <id>]
#   fm-teleport.sh chunk-get <task-id> <index>
#   fm-teleport.sh chunk-put <task-id> <index> <sha256>
#   fm-teleport.sh adopt <task-id>                  (manifest on stdin)
#   fm-teleport.sh abort <task-id>
#   fm-teleport.sh release <task-id> [--drop-backlog]
#   fm-teleport.sh backlog-export <task-id>
#   fm-teleport.sh backlog-start <task-id>
#
# The move, in order. The sending home is this one for an outbound move and the
# secondmate for --back; the adopting home is the other.
#   1. describe and check: the adopting home refuses when it already records the
#      task, holds a half-finished receipt, or its clone of the project is
#      missing, dirty, or points at another origin.
#   2. pack (sending home): refuses during an active validation run, interrupts
#      the worker through bin/fm-control.sh, waits until it reads idle, commits
#      the whole worktree as a WIP snapshot on fm/teleport/<task> without moving
#      the worker's HEAD (bin/fm-teleport-lib.sh owns the git mechanics), pushes
#      it, and packs the task's data/<task>/ directory plus the Claude transcript
#      into a payload split into chunks under the 1 MiB fm-on input bound.
#   3. chunk-put/chunk-get carry the payload, each chunk checked by sha256.
#   4. adopt (adopting home): unpacks data/<task>/ with the sending home's paths
#      rewritten to its own, then launches the worker through bin/fm-spawn.sh
#      --teleport, which restores the work into a fresh pooled worktree. A Claude
#      task resumes its transcript with an arrival note; any other harness, or a
#      Claude task whose transcript is missing, starts from its instructions plus
#      a generated progress note. adopt waits until the agent reads alive and
#      rolls itself back on any failure.
#   5. The backlog item follows: bin/fm-backlog-handoff.sh outbound, and
#      backlog-export plus a local tasks-axi move for --back. The adopting home
#      already owns the task here, so an outbound handoff failure only warns
#      (run bin/fm-backlog-handoff.sh --resume-pending when an outbox was
#      staged; otherwise the local item gets a parked dispatch hold and the
#      warning names bin/fm-backlog-handoff.sh <secondmate> <task>) and the
#      teleport still completes.
#   6. release (sending home): only after the adopting home confirmed, stops the
#      worker, proves the worktree still equals the snapshot, tears it down
#      through bin/fm-teardown.sh, and deletes the sending copy of the transcript.
#   7. The WIP ref is deleted from origin.
# Any failure before step 6 aborts the adopting side and leaves the sending task
# in place with its worker alive and idle, its worktree and transcript untouched.
#
# Environment: FM_HOME is required. FM_TELEPORT_CHUNK_BYTES (786432),
# FM_TELEPORT_IDLE_WAIT (30), FM_TELEPORT_LAUNCH_WAIT (90). FM_TELEPORT_BIN and
# FM_TELEPORT_PROBE are test seams for the helper scripts and the backend probes.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/fm-teleport.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
warn() { printf 'warning: %s\n' "$1" >&2; }
log() { printf 'fm-teleport: %s\n' "$*" >&2; }
usage() { sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; }

case "${1:-}" in -h|--help|'') usage; exit 0 ;; esac
[ -n "${FM_HOME:-}" ] && [ -d "$FM_HOME" ] || die "FM_HOME must name this firstmate home"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
HELPERS="${FM_TELEPORT_BIN:-$SCRIPT_DIR}"
BACKLOG="$DATA/backlog.md"
CHUNK_BYTES=${FM_TELEPORT_CHUNK_BYTES:-786432}
IDLE_WAIT=${FM_TELEPORT_IDLE_WAIT:-30}
LAUNCH_WAIT=${FM_TELEPORT_LAUNCH_WAIT:-90}
DEFAULT_SECONDMATE=alwayson

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-teleport-lib.sh
. "$SCRIPT_DIR/fm-teleport-lib.sh"

require_task_id() { fm_teleport_valid_task_id "$1" || die "invalid task id: $1"; }
staging() { printf '%s/teleport/%s\n' "$STATE" "$1"; }

# --- probes -----------------------------------------------------------------

probe() { # busy|agent <task>
  local meta="$STATE/$2.meta" verdict
  if [ -n "${FM_TELEPORT_PROBE:-}" ]; then "$FM_TELEPORT_PROBE" "$1" "$2"; return; fi
  case "$1" in
    busy) verdict=$(fm_busy_classify_meta "$meta" "$2" "$STATE"); printf '%s\n' "${verdict%% *}" ;;
    agent) fm_backend_agent_state "$(fm_backend_of_meta "$meta")" "$(fm_backend_target_of_meta "$meta")" ;;
  esac
}

wait_probe() { # <kind> <task> <want> <timeout>
  local seen elapsed=0
  while :; do
    seen=$(probe "$1" "$2" 2>/dev/null || true)
    [ "$seen" != "$3" ] || return 0
    [ "$elapsed" -lt "$4" ] || { printf '%s\n' "${seen:-unreadable}"; return 1; }
    sleep 1
    elapsed=$((elapsed + 1))
  done
}

# --- project identity --------------------------------------------------------

normalize_url() { # <url>
  printf '%s\n' "$1" | sed -E 's#/+$##; s#\.git$##; s#^[a-z+]+://([^@/]*@)?##; s#^[^@/]*@([^:/]+):#\1/#'
}

project_key_of() { # <project-path>
  local real home
  real=$(CDPATH='' cd -- "$1" 2>/dev/null && pwd -P) || real=$1
  home=$(CDPATH='' cd -- "$FM_HOME" && pwd -P)
  if [ "$real" = "$home" ]; then printf '@home\n'; else basename "$real"; fi
}

project_dir_for() { # <project-key>
  case "$1" in
    @home) printf '%s\n' "$FM_HOME" ;;
    ''|.|..|*/*|-*) return 1 ;;
    *) printf '%s/%s\n' "$PROJECTS" "$1" ;;
  esac
}

task_meta() { # <task>; validates a movable local task and sets META WT KIND HARNESS PROJECT
  META="$STATE/$1.meta"
  [ -f "$META" ] || die "task $1 has no record in this home"
  [ -z "$(fm_meta_get "$META" remote_host)" ] || die "task $1 is a remotely placed secondmate; only ship and scout workers teleport"
  KIND=$(fm_meta_get "$META" kind)
  case "${KIND:-ship}" in ship|scout) KIND=${KIND:-ship} ;; *) die "task $1 is a $KIND; only ship and scout workers teleport" ;; esac
  WT=$(fm_meta_get "$META" worktree)
  [ -n "$WT" ] && [ -d "$WT" ] || die "task $1 has no worktree on this host"
  HARNESS=$(fm_meta_get "$META" harness)
  [ -n "$HARNESS" ] || die "task $1 records no harness"
  PROJECT=$(fm_meta_get "$META" project)
  [ -n "$PROJECT" ] || die "task $1 records no project"
}

# --- backlog helpers -----------------------------------------------------------

backlog_section() { # <file> <task>; prints the section holding the task, or fails
  [ -f "$1" ] || return 1
  awk -v key="$2" '
    /^## / { section = $0 }
    $0 ~ "^- \\[[ x]\\] " key "([[:space:]]|$)" { print section; found = 1; exit }
    END { exit !found }
  ' "$1"
}

seed_backlog() { [ -f "$1" ] || printf '## In flight\n\n## Queued\n\n## Done\n' > "$1"; }

# --- protocol verbs -------------------------------------------------------------

cmd_describe() { # <task>
  local origin
  task_meta "$1"
  origin=$(git -C "$WT" remote get-url origin 2>/dev/null) || die "task $1's worktree has no origin remote"
  printf 'project=%s\norigin=%s\nharness=%s\nkind=%s\n' "$(project_key_of "$PROJECT")" "$origin" "$HARNESS" "$KIND"
}

check_receivable() { # <task> <project-key> <origin-url> [adopting]
  local task=$1 dir origin
  [ ! -f "$STATE/$task.meta" ] || die "this home already records task $task; refusing to adopt a second copy"
  [ "${4:-}" = adopting ] || [ ! -d "$(staging "$task")/in" ] || die "this home holds an unfinished teleport receipt for $task at $(staging "$task")/in; remove it once nothing depends on it"
  dir=$(project_dir_for "$2") || die "unsafe project key: $2"
  git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || die "this home has no clone of $2 at $dir"
  origin=$(git -C "$dir" remote get-url origin 2>/dev/null) || die "the clone at $dir has no origin remote"
  [ "$(normalize_url "$origin")" = "$(normalize_url "$3")" ] || die "the clone at $dir points at $origin, not $3"
  [ -z "$(git -C "$dir" status --porcelain 2>/dev/null)" ] || die "the clone at $dir has uncommitted changes; refusing to adopt into a dirty clone"
  PROJECT_DIR=$dir
}

cmd_check() { # <task> <project-key> <origin-url>
  check_receivable "$1" "$2" "$3"
  printf 'ok\n'
}

cmd_pack() { # <task> [--session <id>]
  local task=$1 session='' crew transcript='' out wip ref origin branch base i sha bytes chunks src_host
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --session) [ "$#" -ge 2 ] || die "--session requires a value"; session=$2; shift 2 ;;
      *) die "unknown pack option: $1" ;;
    esac
  done
  task_meta "$task"
  crew=$("$HELPERS/fm-crew-state.sh" "$task" 2>/dev/null || true)
  case "$crew" in
    *"source: run-step"*)
      case "$crew" in "state: working"*|"state: parked"*) die "task $task is inside an active validation run ($crew); teleport it before or after validation" ;; esac ;;
  esac
  if [ "$HARNESS" = claude ]; then
    if [ -n "$session" ]; then
      fm_teleport_valid_session "$session" || die "invalid session id: $session"
      transcript="$(fm_teleport_claude_project_dir "$WT")/$session.jsonl"
      [ -f "$transcript" ] || transcript="$(fm_teleport_claude_project_dir "$(cd "$WT" && pwd -P)")/$session.jsonl"
      [ -f "$transcript" ] || die "no transcript for session $session of $WT"
    else
      transcript=$(fm_teleport_claude_latest_transcript "$WT")
      [ -n "$transcript" ] || warn "no Claude transcript found for $WT; the adopting worker will start from its instructions and a progress note"
      [ -z "$transcript" ] || session=$(basename "$transcript" .jsonl)
    fi
  elif [ -n "$session" ]; then
    die "--session applies only to a claude worker; $task runs $HARNESS"
  fi
  "$HELPERS/fm-control.sh" "$task" interrupt >/dev/null || die "could not interrupt task $task's worker"
  wait_probe busy "$task" idle "$IDLE_WAIT" >/dev/null || die "task $task's worker did not read idle within ${IDLE_WAIT}s after the interrupt"

  ref=$(fm_teleport_ref "$task")
  wip=$(fm_teleport_snapshot "$WT" "$task") || die "could not snapshot $WT"
  git -C "$WT" push --quiet origin "+$wip:refs/heads/$ref" || die "could not push the snapshot to origin $ref"
  git -C "$WT" fetch --quiet origin "+refs/heads/$ref:refs/remotes/origin/$ref" || die "could not confirm the pushed snapshot on origin"
  [ "$(git -C "$WT" rev-parse "refs/remotes/origin/$ref")" = "$wip" ] || die "origin $ref does not hold the snapshot just pushed"
  origin=$(git -C "$WT" remote get-url origin)
  branch=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  base=$(git -C "$WT" rev-parse "$wip^1")

  out="$(staging "$task")/out"
  rm -rf -- "$out"
  mkdir -p "$out/payload/data"
  if [ -d "$DATA/$task" ]; then
    (cd "$DATA/$task" && tar cf - --exclude ./teleport .) | (cd "$out/payload/data" && tar xf -) || die "could not stage $DATA/$task"
  fi
  [ -z "$transcript" ] || cp "$transcript" "$out/payload/session.jsonl" || die "could not stage the transcript"
  [ ! -f "$STATE/$task.status" ] || tail -n 20 "$STATE/$task.status" > "$out/payload/status.tail"
  (cd "$out/payload" && tar czf ../payload.tgz .) || die "could not build the payload"
  bytes=$(LC_ALL=C wc -c < "$out/payload.tgz" | tr -d ' ')
  perl -e '
    my ($file, $size, $dir) = @ARGV; my $i = 0;
    open(my $in, "<:raw", $file) or die;
    while (read($in, my $buf, $size)) { open(my $o, ">:raw", "$dir/part.$i") or die; print $o $buf; close $o; $i++; }
    print "$i\n";
  ' "$out/payload.tgz" "$CHUNK_BYTES" "$out" > "$out/chunks" || die "could not split the payload"
  chunks=$(cat "$out/chunks")
  src_host=$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'unknown')
  {
    printf 'schema=fm-teleport.v1\ntask=%s\nkind=%s\nmode=%s\nyolo=%s\n' "$task" "$KIND" "$(fm_meta_get "$META" mode)" "$(fm_meta_get "$META" yolo)"
    printf 'harness=%s\nmodel=%s\neffort=%s\nadvisor=%s\n' "$HARNESS" "$(fm_meta_get "$META" model)" "$(fm_meta_get "$META" effort)" "$(fm_meta_get "$META" advisor)"
    printf 'project=%s\norigin=%s\nbranch=%s\nbase=%s\nwip=%s\n' "$(project_key_of "$PROJECT")" "$origin" "$branch" "$base" "$wip"
    printf 'session=%s\nsource_host=%s\nsource_home=%s\nsource_worktree=%s\nsource_transcript=%s\n' "$session" "$src_host" "$FM_HOME" "$WT" "$transcript"
    printf 'payload_bytes=%s\npayload_sha256=%s\nchunks=%s\n' "$bytes" "$(fm_teleport_sha256 "$out/payload.tgz")" "$chunks"
    i=0
    while [ "$i" -lt "$chunks" ]; do
      sha=$(fm_teleport_sha256 "$out/part.$i")
      printf 'chunk_%s=%s\n' "$i" "$sha"
      i=$((i + 1))
    done
  } > "$out/manifest"
  cat "$out/manifest"
}

valid_index() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }

cmd_chunk_get() { # <task> <index>
  valid_index "$2" || die "invalid chunk index: $2"
  local part
  part="$(staging "$1")/out/part.$2"
  [ -f "$part" ] || die "no staged chunk $2 for $1"
  cat "$part"
}

cmd_chunk_put() { # <task> <index> <sha256>
  local dir
  valid_index "$2" || die "invalid chunk index: $2"
  case "$3" in *[!0-9a-f]*|'') die "invalid sha256: $3" ;; esac
  dir="$(staging "$1")/in"
  mkdir -p "$dir"
  cat > "$dir/part.$2.tmp"
  [ "$(fm_teleport_sha256 "$dir/part.$2.tmp")" = "$3" ] || { rm -f "$dir/part.$2.tmp"; die "chunk $2 of $1 arrived damaged"; }
  mv -f "$dir/part.$2.tmp" "$dir/part.$2"
  printf 'ok\n'
}

progress_note() { # <manifest> <payload-dir> <project-dir>
  local manifest=$1 payload=$2 proj=$3 base wip
  base=$(fm_meta_get "$manifest" base)
  wip=$(fm_meta_get "$manifest" wip)
  printf '\n## Teleport note (%s)\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'This task was teleported from %s (%s) to this home. Continue from here.\n' "$(fm_meta_get "$manifest" source_host)" "$(fm_meta_get "$manifest" source_home)"
  printf 'Your working copy holds every change the previous worker made, committed and uncommitted.\n'
  printf 'Skip setup steps that already happened: the branch %s already exists and is checked out.\n' "$(fm_meta_get "$manifest" branch)"
  printf 'Paths of the previous home in these instructions were rewritten to this home.\n\n'
  printf 'Recent commits:\n\n'
  git -C "$proj" log --oneline -5 "$base" 2>/dev/null | sed 's/^/    /' || true
  printf '\nUncommitted changes carried over:\n\n'
  git -C "$proj" diff --stat "$base" "$wip" 2>/dev/null | sed 's/^/    /' || true
  if [ -s "$payload/status.tail" ]; then
    printf '\nLast status lines the previous worker reported:\n\n'
    sed 's/^/    /' "$payload/status.tail"
  fi
}

arrival_note() { # <manifest>
  local manifest=$1
  printf 'This conversation was teleported from %s to a new machine and resumes here.\n' "$(fm_meta_get "$manifest" source_host)"
  printf 'Your working copy is now __WORKTREE__ and holds every change you made, committed and uncommitted.\n'
  printf 'Report status by appending to __STATUS__ from now on.\n'
  printf 'Paths of the previous machine earlier in this conversation were rewritten to this one; trust the paths above.\n'
  printf 'Continue the task from where you stopped.\n'
}

adopt_rollback_data() { # <task> <prior-dir>
  rm -rf -- "${DATA:?}/$1"
  [ ! -d "$2" ] || mv "$2" "$DATA/$1"
}

cmd_adopt() { # <task>; manifest on stdin
  local task=$1 dir manifest chunks i want payload ref wip proj session harness out note_file prior state
  local -a spawn_args
  dir="$(staging "$task")/in"
  mkdir -p "$dir"
  manifest="$dir/manifest"
  cat > "$manifest"
  [ "$(fm_meta_get "$manifest" schema)" = fm-teleport.v1 ] || die "unrecognized teleport manifest"
  [ "$(fm_meta_get "$manifest" task)" = "$task" ] || die "manifest is for another task"
  # The receipt directory is this adopt's own; check everything else.
  check_receivable "$task" "$(fm_meta_get "$manifest" project)" "$(fm_meta_get "$manifest" origin)" adopting
  proj=$PROJECT_DIR

  chunks=$(fm_meta_get "$manifest" chunks)
  valid_index "$chunks" || die "invalid chunk count in manifest"
  : > "$dir/payload.tgz"
  i=0
  while [ "$i" -lt "$chunks" ]; do
    [ -f "$dir/part.$i" ] || die "chunk $i of $task never arrived"
    want=$(fm_meta_get "$manifest" "chunk_$i")
    [ "$(fm_teleport_sha256 "$dir/part.$i")" = "$want" ] || die "chunk $i of $task is damaged"
    cat "$dir/part.$i" >> "$dir/payload.tgz"
    i=$((i + 1))
  done
  [ "$(fm_teleport_sha256 "$dir/payload.tgz")" = "$(fm_meta_get "$manifest" payload_sha256)" ] || die "the payload for $task is damaged"
  payload="$dir/payload"
  rm -rf -- "$payload"
  mkdir -p "$payload"
  tar xzf "$dir/payload.tgz" -C "$payload" || die "could not unpack the payload"

  ref=$(fm_teleport_ref "$task")
  wip=$(fm_meta_get "$manifest" wip)
  git -C "$proj" fetch --quiet origin "+refs/heads/$ref:refs/remotes/origin/$ref" || die "could not fetch $ref into $proj"
  [ "$(git -C "$proj" rev-parse "refs/remotes/origin/$ref")" = "$wip" ] || die "origin $ref does not hold the snapshot named in the manifest"

  prior="$dir/prior-data"
  rm -rf -- "$prior"
  [ ! -d "$DATA/$task" ] || mv "$DATA/$task" "$prior"
  mkdir -p "$DATA/$task"
  : > "$dir/installed-data"
  (cd "$payload/data" && tar cf - .) | (cd "$DATA/$task" && tar xf -) || { adopt_rollback_data "$task" "$prior"; die "could not install $task's records"; }
  while IFS= read -r -d '' f; do
    grep -Iq . "$f" 2>/dev/null || continue
    fm_teleport_map_paths "$f" "$(fm_meta_get "$manifest" source_home)" "$FM_HOME" || true
  done < <(find "$DATA/$task" -type f -print0)
  mkdir -p "$DATA/$task/teleport"
  : > "$DATA/$task/teleport/adopted"
  cp "$manifest" "$DATA/$task/teleport/manifest"
  session=$(fm_meta_get "$manifest" session)
  harness=$(fm_meta_get "$manifest" harness)
  if [ -n "$session" ] && [ "$harness" = claude ] && [ -f "$payload/session.jsonl" ]; then
    cp "$payload/session.jsonl" "$DATA/$task/teleport/session.jsonl"
    arrival_note "$manifest" > "$DATA/$task/teleport/arrival.md"
  else
    # Without a transcript the manifest must not promise one.
    awk -F= '$1 != "session"' "$manifest" > "$DATA/$task/teleport/manifest"
    [ -f "$DATA/$task/brief.md" ] || { adopt_rollback_data "$task" "$prior"; die "task $task arrived without instructions"; }
    note_file="$DATA/$task/teleport/progress-note.md"
    progress_note "$manifest" "$payload" "$proj" > "$note_file"
    awk '/^## Teleport note/ { skip = 1; next } skip && /^## / { skip = 0 } !skip' "$DATA/$task/brief.md" > "$DATA/$task/brief.md.tmp"
    cat "$note_file" >> "$DATA/$task/brief.md.tmp"
    mv -f "$DATA/$task/brief.md.tmp" "$DATA/$task/brief.md"
  fi

  spawn_args=("$task" "$proj")
  if [ "$(fm_meta_get "$manifest" kind)" = scout ]; then
    spawn_args+=(--scout)
  else
    spawn_args+=(--mode "$(fm_meta_get "$manifest" mode)" --yolo "$(fm_meta_get "$manifest" yolo)")
  fi
  spawn_args+=(--harness "$harness")
  case "$(fm_meta_get "$manifest" model)" in ''|default) ;; *) spawn_args+=(--model "$(fm_meta_get "$manifest" model)") ;; esac
  case "$(fm_meta_get "$manifest" effort)" in ''|default) ;; *) spawn_args+=(--effort "$(fm_meta_get "$manifest" effort)") ;; esac
  [ -z "$(fm_meta_get "$manifest" advisor)" ] || spawn_args+=(--advisor "$(fm_meta_get "$manifest" advisor)")
  spawn_args+=(--teleport)
  if ! out=$("$HELPERS/fm-spawn.sh" "${spawn_args[@]}" 2>&1); then
    printf '%s\n' "$out" >&2
    if [ -f "$STATE/$task.meta" ]; then
      "$SELF" abort "$task" >&2 || die "the adopting worker for $task failed to launch and could not be rolled back; inspect it here"
    else
      adopt_rollback_data "$task" "$prior"
      rm -rf -- "$dir"
    fi
    die "the adopting worker for $task could not be launched"
  fi
  if ! state=$(wait_probe agent "$task" alive "$LAUNCH_WAIT"); then
    "$SELF" abort "$task" >&2 || die "the adopting worker for $task never came up (it reads '$state') and could not be rolled back; inspect it here"
    die "the adopting worker for $task never came up (it reads '$state'); rolled back"
  fi
  rm -rf -- "$prior" "$dir"
  printf 'adopted %s worktree=%s\n' "$task" "$(fm_meta_get "$STATE/$task.meta" worktree)"
}

installed_transcript() { # <task> <worktree>; the transcript adopt installed, if any
  local manifest="$DATA/$1/teleport/manifest" session
  session=$(fm_meta_get "$manifest" session)
  [ -n "$session" ] || return 0
  fm_teleport_valid_session "$session" || return 0
  printf '%s/%s.jsonl\n' "$(fm_teleport_claude_project_dir "$2")" "$session"
}

shared_worktree_owner() { # <task> <worktree>; prints another task recording the same worktree
  local meta other
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    other=$(basename "$meta" .meta)
    [ "$other" != "$1" ] || continue
    [ "$(fm_meta_get "$meta" worktree)" != "$2" ] || { printf '%s\n' "$other"; return 0; }
  done
  return 1
}

# Stop this home's copy of <task>, prove its worktree still equals the snapshot,
# and clean it up. Shared by release (sending side) and abort (adopting side).
retire_copy() { # <task>
  local task=$1 other
  task_meta "$task"
  if other=$(shared_worktree_owner "$task" "$WT"); then
    die "task $other also records $WT; refusing to clean up a worktree another task uses"
  fi
  "$HELPERS/fm-control.sh" "$task" exit >/dev/null || die "could not stop task $task's worker"
  fm_teleport_settle_on_snapshot "$WT" "$task" || die "task $task's worktree no longer matches the teleport snapshot; it was left in place"
  "$HELPERS/fm-teardown.sh" "$task" >&2 || die "cleanup of task $task's worktree failed; its worker is stopped and its worktree still holds the snapshot"
}

# Roll back a copy this home adopted (or half-adopted) and has not yet confirmed
# to the sending home. Refuses a task this home did not adopt.
cmd_abort() { # <task>
  local task=$1 transcript prior in
  in="$(staging "$task")/in"
  prior="$in/prior-data"
  if [ ! -f "$STATE/$task.meta" ]; then
    [ ! -f "$in/installed-data" ] || adopt_rollback_data "$task" "$prior"
    rm -rf -- "$in"
    printf 'nothing running to abort for %s\n' "$task"
    return 0
  fi
  [ -f "$DATA/$task/teleport/adopted" ] || die "task $task was not adopted by a teleport into this home; refusing to abort it"
  task_meta "$task"
  transcript=$(installed_transcript "$task" "$WT")
  retire_copy "$task"
  [ -z "$transcript" ] || rm -f -- "$transcript"
  adopt_rollback_data "$task" "$prior"
  rm -f -- "$STATE/$task.meta"
  rm -rf -- "$in"
  printf 'aborted %s\n' "$task"
}

cmd_release() { # <task> [--drop-backlog]
  local task=$1 drop=0 transcript
  [ "${2:-}" != --drop-backlog ] || drop=1
  transcript=$(fm_meta_get "$(staging "$task")/out/manifest" source_transcript)
  retire_copy "$task"
  [ -z "$transcript" ] || rm -f -- "$transcript"
  if [ "$drop" = 1 ] && backlog_section "$BACKLOG" "$task" >/dev/null; then
    tasks-axi rm "$task" --file "$BACKLOG" >/dev/null || warn "could not remove $task from this home's backlog; remove it by hand"
  fi
  rm -rf -- "$(staging "$task")" "${DATA:?}/$task/teleport"
  printf 'released %s\n' "$task"
}

cmd_backlog_export() { # <task>; prints the task's backlog item as a backlog file, or nothing
  local task=$1 tmp
  backlog_section "$BACKLOG" "$task" >/dev/null || return 0
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-teleport-backlog.XXXXXX")
  cp "$BACKLOG" "$tmp/copy.md"
  seed_backlog "$tmp/out.md"
  tasks-axi reopen "$task" --file "$tmp/copy.md" >/dev/null 2>&1 || true
  tasks-axi mv "$task" --file "$tmp/copy.md" --to "$tmp/out.md" >/dev/null || { rm -rf -- "$tmp"; die "could not export $task's backlog item"; }
  cat "$tmp/out.md"
  rm -rf -- "$tmp"
}

cmd_backlog_start() { # <task>
  backlog_section "$BACKLOG" "$1" >/dev/null || return 0
  tasks-axi start "$1" --file "$BACKLOG" >/dev/null
}

# --- operator flows ----------------------------------------------------------------

on() { # <secondmate> <fm-command> [args...]
  "$HELPERS/fm-on.sh" "$@"
}

delete_wip_ref() { # <task> <git-dir>
  git -C "$2" push --quiet origin --delete "refs/heads/$(fm_teleport_ref "$1")" 2>/dev/null \
    || warn "could not delete $(fm_teleport_ref "$1") from origin; delete it by hand"
}

teleport_out() { # <task> <secondmate> <session>
  local task=$1 sm=$2 session=$3 desc key origin manifest dir chunks i sha adopted section=''
  local -a pack_args
  desc=$("$SELF" describe "$task") || exit 1
  key=$(printf '%s\n' "$desc" | sed -n 's/^project=//p')
  origin=$(printf '%s\n' "$desc" | sed -n 's/^origin=//p')
  on "$sm" fm-teleport.sh check "$task" "$key" "$origin" >/dev/null || die "$sm cannot take task $task; it stays here untouched"
  pack_args=(pack "$task")
  [ -z "$session" ] || pack_args+=(--session "$session")
  manifest=$("$SELF" "${pack_args[@]}") || die "could not pack task $task; it stays here (its worker may have been interrupted and now waits idle)"
  dir="$(staging "$task")/out"
  chunks=$(printf '%s\n' "$manifest" | sed -n 's/^chunks=//p')
  i=0
  while [ "$i" -lt "$chunks" ]; do
    sha=$(printf '%s\n' "$manifest" | sed -n "s/^chunk_$i=//p")
    on "$sm" fm-teleport.sh chunk-put "$task" "$i" "$sha" < "$dir/part.$i" >/dev/null \
      || { on "$sm" fm-teleport.sh abort "$task" >/dev/null 2>&1 || true; die "could not send task $task to $sm; it stays here with its worker idle"; }
    i=$((i + 1))
  done
  if ! adopted=$(printf '%s\n' "$manifest" | on "$sm" fm-teleport.sh adopt "$task"); then
    on "$sm" fm-teleport.sh abort "$task" >/dev/null 2>&1 || warn "$sm may hold a partial copy of $task; run fm-on.sh $sm fm-teleport.sh abort $task"
    die "$sm could not take over task $task; it stays here with its worker idle"
  fi
  if section=$(backlog_section "$BACKLOG" "$task"); then
    [ "$section" != "## In flight" ] || tasks-axi reopen "$task" --file "$BACKLOG" >/dev/null
    if ! "$HELPERS/fm-backlog-handoff.sh" "$sm" "$task" >&2; then
      if [ -f "$DATA/handoff/$sm.outbox.md" ] && backlog_section "$DATA/handoff/$sm.outbox.md" "$task" >/dev/null; then
        warn "$sm took over task $task, but its backlog item did not arrive; run bin/fm-backlog-handoff.sh --resume-pending to deliver it"
      elif backlog_section "$BACKLOG" "$task" >/dev/null; then
        tasks-axi hold "$task" --file "$BACKLOG" --kind parked --reason "teleported to $sm; backlog move pending - run fm-backlog-handoff.sh $sm $task" >/dev/null \
          || warn "could not place a dispatch hold on $task here; do not dispatch it"
        warn "$sm took over task $task, but its backlog item did not move and is held here; run bin/fm-backlog-handoff.sh $sm $task"
      else
        warn "$sm took over task $task, but its backlog item did not move; run bin/fm-backlog-handoff.sh $sm $task"
      fi
    else
      on "$sm" fm-teleport.sh backlog-start "$task" >/dev/null 2>&1 || warn "$sm received $task's backlog item but could not mark it in flight"
    fi
  fi
  "$SELF" release "$task" >/dev/null || die "$sm took over task $task, but cleaning up the copy here failed; the worker here is stopped or idle and its worktree is kept"
  delete_wip_ref "$task" "$(project_dir_for "$key")"
  printf 'teleported %s to %s: %s\n' "$task" "$sm" "$adopted"
}

teleport_back() { # <task> <secondmate>
  local task=$1 sm=$2 desc key origin manifest dir chunks i sha adopted exported tmp
  [ ! -f "$STATE/$task.meta" ] || die "this home already records task $task"
  desc=$(on "$sm" fm-teleport.sh describe "$task") || die "$sm does not hold a movable task $task"
  key=$(printf '%s\n' "$desc" | sed -n 's/^project=//p')
  origin=$(printf '%s\n' "$desc" | sed -n 's/^origin=//p')
  "$SELF" check "$task" "$key" "$origin" >/dev/null || die "this home cannot take task $task back; it stays on $sm untouched"
  manifest=$(on "$sm" fm-teleport.sh pack "$task") || die "$sm could not pack task $task; it stays there (its worker may have been interrupted and now waits idle)"
  dir="$(staging "$task")/fetch"
  rm -rf -- "$dir"
  mkdir -p "$dir"
  chunks=$(printf '%s\n' "$manifest" | sed -n 's/^chunks=//p')
  i=0
  while [ "$i" -lt "$chunks" ]; do
    sha=$(printf '%s\n' "$manifest" | sed -n "s/^chunk_$i=//p")
    { on "$sm" fm-teleport.sh chunk-get "$task" "$i" > "$dir/part.$i" \
      && "$SELF" chunk-put "$task" "$i" "$sha" < "$dir/part.$i" >/dev/null; } \
      || { "$SELF" abort "$task" >/dev/null 2>&1 || true; rm -rf -- "$dir"; die "could not fetch task $task from $sm; it stays there with its worker idle"; }
    i=$((i + 1))
  done
  rm -rf -- "$dir"
  adopted=$(printf '%s\n' "$manifest" | "$SELF" adopt "$task") || die "this home could not take over task $task; it stays on $sm with its worker idle"
  exported=$(on "$sm" fm-teleport.sh backlog-export "$task") || { "$SELF" abort "$task" >&2 || true; die "could not read task $task's backlog item on $sm; the move was rolled back"; }
  if [ -n "$exported" ]; then
    tmp=$(mktemp "${TMPDIR:-/tmp}/fm-teleport-import.XXXXXX")
    printf '%s\n' "$exported" > "$tmp"
    seed_backlog "$BACKLOG"
    if ! backlog_section "$BACKLOG" "$task" >/dev/null && ! tasks-axi mv "$task" --file "$tmp" --to "$BACKLOG" >/dev/null; then
      rm -f "$tmp"
      "$SELF" abort "$task" >&2 || true
      die "could not take task $task's backlog item into this home; the move was rolled back"
    fi
    rm -f "$tmp"
    tasks-axi start "$task" --file "$BACKLOG" >/dev/null || warn "could not mark $task in flight in this home's backlog"
  fi
  on "$sm" fm-teleport.sh release "$task" --drop-backlog >/dev/null || die "this home took task $task back, but cleaning up its copy on $sm failed; inspect it there"
  delete_wip_ref "$task" "$(project_dir_for "$key")"
  printf 'teleported %s back from %s: %s\n' "$task" "$sm" "$adopted"
}

# --- sleep reminder ---------------------------------------------------------------

lid_closed() {
  case "$(uname)" in
    Darwin) ioreg -r -k AppleClamshellState -d 4 2>/dev/null | grep -q '"AppleClamshellState" = Yes' ;;
    *) grep -qs closed /proc/acpi/button/lid/*/state ;;
  esac
}

cmd_remind() { # [--lid]
  local meta task kind count=0 marker age summary
  if [ "${1:-}" = --lid ]; then lid_closed || return 0; fi
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    task=$(basename "$meta" .meta)
    kind=$(fm_meta_get "$meta" kind)
    case "${kind:-ship}" in ship|scout) ;; *) continue ;; esac
    [ -z "$(fm_meta_get "$meta" remote_host)" ] || continue
    [ "$(probe agent "$task" 2>/dev/null || true)" = alive ] || continue
    count=$((count + 1))
  done
  [ "$count" -gt 0 ] || return 0
  marker="$STATE/.teleport-reminded"
  if [ -f "$marker" ]; then
    age=$(( $(date +%s) - $(cat "$marker" 2>/dev/null || echo 0) ))
    [ "$age" -ge "${FM_TELEPORT_REMIND_SECS:-600}" ] || return 0
  fi
  date +%s > "$marker"
  if [ "$count" -eq 1 ]; then summary="1 task running, teleport out?"; else summary="$count tasks running, teleport out?"; fi
  # shellcheck source=bin/fm-alert-lib.sh
  . "$SCRIPT_DIR/fm-alert-lib.sh"
  FM_ALERT_TITLE="firstmate: tasks running" wedge_alarm_notify "$summary" "$marker"
  printf '%s\n' "$summary"
}

# --- dispatch -------------------------------------------------------------------------

VERB=$1
case "$VERB" in
  remind) shift; cmd_remind "$@"; exit 0 ;;
  describe|check|pack|chunk-get|chunk-put|adopt|abort|release|backlog-export|backlog-start)
    shift
    [ "$#" -ge 1 ] || die "$VERB requires a task id"
    require_task_id "$1"
    case "$VERB" in
      describe) cmd_describe "$1" ;;
      check) [ "$#" -eq 3 ] || die "check takes <task> <project-key> <origin-url>"; cmd_check "$@" ;;
      pack) cmd_pack "$@" ;;
      chunk-get) [ "$#" -eq 2 ] || die "chunk-get takes <task> <index>"; cmd_chunk_get "$@" ;;
      chunk-put) [ "$#" -eq 3 ] || die "chunk-put takes <task> <index> <sha256>"; cmd_chunk_put "$@" ;;
      adopt) cmd_adopt "$1" ;;
      abort) cmd_abort "$1" ;;
      release) cmd_release "$@" ;;
      backlog-export) cmd_backlog_export "$1" ;;
      backlog-start) cmd_backlog_start "$1" ;;
    esac
    exit 0
    ;;
esac

TASK=$VERB
shift
require_task_id "$TASK"
SM=$DEFAULT_SECONDMATE
SESSION=
BACK=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --to|--from) [ "$#" -ge 2 ] || die "$1 requires a value"; SM=$2; shift 2 ;;
    --session) [ "$#" -ge 2 ] || die "--session requires a value"; SESSION=$2; shift 2 ;;
    --back) BACK=1; shift ;;
    *) die "unknown option: $1" ;;
  esac
done
case "$SM" in ''|-*|*[!A-Za-z0-9._-]*) die "invalid secondmate id: $SM" ;; esac
if [ "$BACK" = 1 ]; then
  [ -z "$SESSION" ] || die "--session applies to an outbound teleport; --back carries the session the remote worker has"
  teleport_back "$TASK" "$SM"
else
  teleport_out "$TASK" "$SM" "$SESSION"
fi
