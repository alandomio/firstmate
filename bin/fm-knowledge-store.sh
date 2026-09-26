#!/usr/bin/env bash
# Print the org-wide knowledge store this home is configured with.
# Usage:
#   fm-knowledge-store.sh read
#
# `read` prints three lines - `name=<store name>`, `backend=<rag|pp-brain|other>`,
# and `search=<search-instructions clause>` - resolved from the optional
# config/knowledge-store under $FM_HOME (default: this code root).  An absent
# file prints the upstream RAG default; a malformed one exits 1 naming the
# problem.  bin/fm-knowledge-store-lib.sh owns the format and derivation.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-knowledge-store-lib.sh
. "$SCRIPT_DIR/fm-knowledge-store-lib.sh"

usage() {
  sed -n '2,10{s/^# \{0,1\}//;p;}' "$0"
}

case "${1:-}" in
  read)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    if ! fm_knowledge_store_read "$CONFIG"; then
      printf 'knowledge-store: %s\n' "$FM_KS_ERROR" >&2
      exit 1
    fi
    printf 'name=%s\nbackend=%s\nsearch=%s\n' "$FM_KS_NAME" "$FM_KS_BACKEND" "$FM_KS_INSTRUCTIONS"
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
