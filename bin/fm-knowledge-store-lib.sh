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
