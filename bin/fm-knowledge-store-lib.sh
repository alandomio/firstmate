# shellcheck shell=bash
# shellcheck disable=SC2034 # FM_KS_* fields are output globals for sourcing callers.
# Knowledge-store resolution primitives.
# Usage: . bin/fm-knowledge-store-lib.sh
#
# The optional local config/knowledge-store setting names the org-wide
# knowledge store this home's installed MCP servers actually provide
# (docs/configuration.md "Knowledge store naming").  This library is the one
# owner of reading it; bin/fm-brief.sh sources it for generated Grounding
# wording and bin/fm-knowledge-store.sh prints it for skills such as
# /retrospective.
#
# Line 1 is the store's name as it reads in agent-facing text, line 2 the
# search-instructions clause, and optional line 3 the backend key: `rag`
# (rag_qdrant_server) or `pp-brain`.  Without line 3 the backend is derived
# from the MCP server line 2 names - `rag_qdrant_server` is `rag`,
# `pp-brain` or `search_knowledge` is `pp-brain` - and anything else is
# `other`, a store whose write contract is not known here.
# A NONEXISTENT file resolves to the historical upstream default, the RAG.
# A PRESENT file (including a 0-byte one) lacking line 1 or line 2, or carrying
# an unknown line-3 key, is refused rather than silently defaulted, since a
# silent default there is exactly the unfollowable-instruction failure the
# setting exists to prevent.  The existence check must not be a non-empty
# check (`-s`): a 0-byte file must hit the same refusal as a one-line file.

FM_KS_FILE_NAME="knowledge-store"
FM_KS_NAME=""
FM_KS_INSTRUCTIONS=""
FM_KS_BACKEND=""
FM_KS_ERROR=""

# fm_knowledge_store_read <config-dir>
# Sets FM_KS_NAME, FM_KS_INSTRUCTIONS, and FM_KS_BACKEND; on refusal returns 1
# with FM_KS_ERROR set.
fm_knowledge_store_read() {
  local file="$1/$FM_KS_FILE_NAME" name instructions backend
  FM_KS_ERROR=""
  FM_KS_NAME="the RAG"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  FM_KS_INSTRUCTIONS='`query_rag_hybrid` or `query_rag` on the `rag_qdrant_server` MCP server, with `query_text` set and `user_roles` passed, empty if you have none'
  FM_KS_BACKEND="rag"
  [ -f "$file" ] || return 0
  name=$(sed -n '1p' "$file")
  instructions=$(sed -n '2p' "$file")
  backend=$(sed -n '3p' "$file")
  if [ -z "$name" ] || [ -z "$instructions" ]; then
    FM_KS_ERROR="$file must have the store name on line 1 and search instructions on line 2"
    return 1
  fi
  case "$backend" in
    rag|pp-brain) ;;
    "")
      case "$instructions" in
        *rag_qdrant_server*) backend=rag ;;
        *pp-brain*|*search_knowledge*) backend=pp-brain ;;
        *) backend=other ;;
      esac
      ;;
    *)
      FM_KS_ERROR="$file line 3 must be a backend key, rag or pp-brain, or be absent"
      return 1
      ;;
  esac
  FM_KS_NAME=$name
  FM_KS_INSTRUCTIONS=$instructions
  FM_KS_BACKEND=$backend
}

# fm_knowledge_store_reach <harness>
# Prints the store's MCP server state as the harness's USER-level configuration
# defines it, which is the only registration a worker in a disposable worktree
# inherits (a project-scoped entry matches only the project's own path):
#   reachable    a bounded HTTP probe of the configured server got a 2xx
#   unavailable  the probe got no answer, a 5xx, or a refusal of the configured
#                credentials
#   missing      the configuration has no enabled entry for the server
#   unknown      nothing can be concluded: a backend other than `rag`, a harness
#                other than claude, codex, or agy, an unreadable configuration,
#                or an entry with no probeable server (stdio, a codex entry, a
#                value left for the harness to expand, or an answer that neither
#                confirms nor rules out the server)
# Never prints a value from the configuration, and passes the URL and headers to
# curl on stdin so they stay out of the process table.  The probe is one attempt
# bounded by --max-time, so an open SSE stream costs that long on a healthy server.
# Test seams: FM_KS_CLAUDE_JSON, FM_KS_CODEX_TOML, FM_KS_AGY_MCP.
fm_knowledge_store_reach() {
  local harness="$1" server=rag_qdrant_server
  [ "$FM_KS_BACKEND" = rag ] || { echo unknown; return 0; }
  case "$harness" in
    claude) fm_ks_reach_json "${FM_KS_CLAUDE_JSON:-${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json}" "$server" ;;
    codex) fm_ks_reach_codex "${FM_KS_CODEX_TOML:-${CODEX_HOME:-$HOME/.codex}/config.toml}" "$server" ;;
    agy) fm_ks_reach_json "${FM_KS_AGY_MCP:-$HOME/.gemini/config/mcp_config.json}" "$server" ;;
    *) echo unknown ;;
  esac
}

fm_ks_reach_codex() { # <toml-file> <server>
  [ -f "$1" ] || { echo unknown; return 0; }
  awk -v header="[mcp_servers.$2]" '
    index($0, header) == 1 { found = 1; inside = 1; next }
    /^\[/ { inside = 0 }
    inside && /^enabled[ \t]*=[ \t]*false/ { disabled = 1 }
    END { print (found && !disabled) ? "unknown" : "missing" }
  ' "$1"
}

fm_ks_reach_json() { # <json-file> <server>
  local entry rc=0
  { [ -f "$1" ] && command -v jq >/dev/null 2>&1; } || { echo unknown; return 0; }
  entry=$(jq -ce --arg s "$2" '.mcpServers[$s] | if . == null or .disabled == true then null else . end' "$1" 2>/dev/null) || rc=$?
  case "$rc" in
    0) fm_ks_probe "$entry" ;;
    1) echo missing ;;
    *) echo unknown ;;
  esac
}

fm_ks_probe() { # <mcp-server-entry-json>
  local config code
  command -v curl >/dev/null 2>&1 || { echo unknown; return 0; }
  config=$(printf '%s' "$1" | jq -r '
    (.url // .serverUrl // .httpUrl) as $url
    | if ($url | type) != "string" or ($url | test("^https?://") | not) or any(.. | strings; contains("${")) then empty
      else "url = \($url | tojson)", (.headers // {} | to_entries[] | "header = \("\(.key): \(.value)" | tojson)")
      end
  ' 2>/dev/null) || config=
  [ -n "$config" ] || { echo unknown; return 0; }
  code=$(printf '%s\n' "$config" | curl -s -o /dev/null -w '%{http_code}' --max-time 3 -H 'Accept: text/event-stream' -K - 2>/dev/null) || true
  case "$code" in
    2??) echo reachable ;;
    000|5??) echo unavailable ;;
    401|403) case "$config" in *'header = '*) echo unavailable ;; *) echo unknown ;; esac ;;
    *) echo unknown ;;
  esac
}
