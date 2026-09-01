#!/usr/bin/env bash
# Rsync the engineer's local ~/.claude/skills/ into a remote secondmate's home,
# so that secondmate's own crewmates and skill loads always see the captain's
# current skill set. A skill set loads only at session start, so this only
# matters at launch; it has no effect on an already-running secondmate.
#
# Usage: fm-remote-skill-sync.sh <secondmate-id>
#
# This is adjacent to, and independent of, the FM_INHERITABLE_CONFIG allowlist
# (bin/fm-config-inherit-lib.sh): that contract carries single small files
# inside FM_HOME with sha256 transfer and generation records. Skills are a
# directory tree outside FM_HOME, so this uses plain rsync instead and does not
# read or write anything that contract owns.
#
# Remote routes only: a local secondmate is the same user on the same machine
# already reading this same directory, so a local route is a no-op here.
# Never passes --delete: the remote host may legitimately hold skills the
# local machine does not (no-mistakes, installed there by its own installer,
# is the standing example), and deleting host-only content would break it.
#
# The destination is the plain relative path .claude/skills/, which an
# interactive-less ssh command resolves against the remote login shell's own
# home directory, so no extra remote-home field is required beyond the
# existing SSH alias.
#
# Exclusions come from the gitignored config/skill-sync-exclude (one rsync
# --exclude pattern per non-empty, non-comment line); an absent file uses the
# DEFAULT_EXCLUDES below verbatim (no merge). docs/configuration.md owns this
# schema.
#
# A caller must treat any nonzero exit as warn-only and never let it block a
# secondmate launch. Exit 0 means a route was actually not remote (silent
# no-op) or a confirmed rsync transfer, including one that moved nothing.
# Exit 1 means misuse (bad arguments or registry lookup failure). Exit 2 means
# rsync could not be trusted to have run: missing rsync, a failed SSH/rsync
# invocation, or output that carries no recognizable rsync --stats block. That
# last case matters concretely: a shipped rsync that rejects an unsupported
# flag can print its usage banner and still exit 0, so exit status alone is
# never proof a transfer happened here - only a genuine --stats block is.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

DEFAULT_EXCLUDES='notebooklm/
notebooklm-to-skill/
notebooklm-to-skill-workspace/
skill-creator/
no-mistakes/
__pycache__
.venv
node_modules'

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
fail_transfer() { printf '%s\n' "$1" >&2; exit 2; }

[ "$#" -eq 1 ] || die "usage: fm-remote-skill-sync.sh <secondmate-id>"
ID=$1
case "$ID" in ''|*[!A-Za-z0-9._-]*) die "invalid secondmate id: $ID" ;; esac

REMOTE=$(secondmate_registry_field "$DATA/secondmates.md" "$ID" remote 2>/dev/null || true)
if [ "$REMOTE" != 1 ]; then
  echo "skip: secondmate $ID is not a remote route"
  exit 0
fi
HOST=$(secondmate_registry_field "$DATA/secondmates.md" "$ID" host)
case "$HOST" in ''|-*|*[!A-Za-z0-9._-]*) die "configured SSH alias is unsafe: $HOST" ;; esac

SOURCE="${FM_SKILLS_SOURCE_OVERRIDE:-$HOME/.claude/skills}"
if [ ! -d "$SOURCE" ]; then
  echo "skip: no local skills directory at $SOURCE"
  exit 0
fi

EXCLUDE_FILE="$CONFIG/skill-sync-exclude"
if [ -f "$EXCLUDE_FILE" ]; then
  PATTERNS=$(grep -v '^[[:space:]]*#' "$EXCLUDE_FILE" | grep -v '^[[:space:]]*$' || true)
else
  PATTERNS=$DEFAULT_EXCLUDES
fi

RSYNC_BIN=${FM_RSYNC_BIN:-rsync}
SSH_BIN=${FM_SSH_BIN:-ssh}
command -v "$RSYNC_BIN" >/dev/null 2>&1 || fail_transfer "rsync is not available"

RSYNC_ARGS=(-az --stats)
while IFS= read -r pattern; do
  [ -n "$pattern" ] || continue
  RSYNC_ARGS+=(--exclude="$pattern")
done <<EOF
$PATTERNS
EOF

ALIVE_INTERVAL=${FM_SSH_ALIVE_INTERVAL:-15}
ALIVE_COUNT_MAX=${FM_SSH_ALIVE_COUNT_MAX:-3}
RSYNC_SSH="$SSH_BIN -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=$ALIVE_INTERVAL -o ServerAliveCountMax=$ALIVE_COUNT_MAX"

if OUT=$("$RSYNC_BIN" "${RSYNC_ARGS[@]}" -e "$RSYNC_SSH" "$SOURCE/" "$HOST:.claude/skills/" 2>&1); then
  :
else
  fail_transfer "rsync to $HOST failed: $(printf '%s' "$OUT" | tail -1)"
fi

# openrsync (the shipped macOS rsync) and GNU rsync label their --stats block
# differently ("Total sent:" vs "Total bytes sent:"), so match either. Both
# require this pair to appear together only on a genuine stats block, never on
# a usage/error banner, which is what makes a confirmed zero-file resync
# distinguishable from a transfer that never actually ran.
if ! printf '%s\n' "$OUT" | grep -Eq '^Number of files: [0-9]' \
  || ! printf '%s\n' "$OUT" | grep -Eq '^Total (bytes )?sent: [0-9]'; then
  fail_transfer "rsync to $HOST produced no recognizable transfer summary: $(printf '%s' "$OUT" | tail -1)"
fi

printf '%s\n' "$OUT"
exit 0
