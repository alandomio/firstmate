#!/usr/bin/env bash
# fm-claude-context-lib.sh - the lighter start-up context for claude ship and
# scout workers, sourced by bin/fm-spawn.sh.
#
# docs/configuration.md "Claude worker context" owns the file formats and the
# operator contract; bin/fm-spawn.sh's header owns the launch-flag mechanics.
#
# The light profile (the default) changes two things on the launch line and
# nothing else: `--tools=<built-in tools>` hides every built-in tool the worker
# does not use, and a `deniedMcpServers` key in the inline --settings JSON hides
# the MCP servers and claude.ai connectors the worker does not use. MCP servers
# not named stay reachable, so Portolano, Diario di bordo, Jira and the
# project's own servers are untouched. User settings, skills, plugins and hooks
# are deliberately not restricted: --setting-sources would also drop
# ~/.claude/skills and the user-scope agentmemory server.

# shellcheck disable=SC2034  # the three results below are read by bin/fm-spawn.sh
FM_CLAUDE_CTX_DEFAULT_TOOLS='Bash,Read,Edit,Write,Grep,Glob,Skill,ToolSearch,Agent,Monitor,TodoWrite,WebFetch,WebSearch,BashOutput,KillShell,TaskOutput,TaskStop,NotebookEdit,TaskCreate,TaskGet,TaskList,TaskUpdate'
FM_CLAUDE_CTX_DEFAULT_DENY='claude.ai Gmail
claude.ai Google Drive
claude.ai Google Calendar
claude.ai Google Sheets
claude.ai Notion
claude.ai Trello
claude.ai Claude Docs
claude.ai Context7
homeassistant'

# Set by fm_claude_ctx_resolve and read by bin/fm-spawn.sh; both empty for the
# full profile.
FM_CLAUDE_CTX_TOOLS_FLAG=
FM_CLAUDE_CTX_DENY_JSON=

# _fm_claude_ctx_read <file> <name-charset-description> <allowed-pattern>:
# print the trimmed entries one per line (comments and blanks skipped);
# non-zero with the reason on stderr for an unreadable file or bad entry.
_fm_claude_ctx_read() {
  local file=$1 label=$2 pattern=$3 line
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "error: $label must be a readable regular file" >&2
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in
    '' | '#'*) continue ;;
    esac
    if [ -n "$(printf '%s' "$line" | LC_ALL=C tr -d "$pattern")" ]; then
      echo "error: $label has a malformed entry '$line'; expected one name per line using only the characters $pattern (blank lines and # comment lines are allowed)" >&2
      return 1
    fi
    printf '%s\n' "$line"
  done <"$file" || {
    echo "error: cannot read $label" >&2
    return 1
  }
}

# fm_claude_ctx_resolve <config-dir>: read config/claude-worker-context (and the
# optional list files) and set FM_CLAUDE_CTX_TOOLS_FLAG / FM_CLAUDE_CTX_DENY_JSON.
# Non-zero with the reason on stderr when a file is invalid, so the spawn
# refuses before any endpoint or worktree exists.
fm_claude_ctx_resolve() {
  local config=$1 mode=light present tools deny entry names='' json
  FM_CLAUDE_CTX_TOOLS_FLAG=
  FM_CLAUDE_CTX_DENY_JSON=
  present=$(fm_config_source_present "$config/claude-worker-context") || return 1
  if [ "$present" = 1 ]; then
    if [ ! -f "$config/claude-worker-context" ] || [ ! -r "$config/claude-worker-context" ]; then
      echo "error: config/claude-worker-context must be a readable regular file holding one of: light, full" >&2
      return 1
    fi
    mode=$(tr -d '[:space:]' <"$config/claude-worker-context") || return 1
  fi
  case "$mode" in
  full) return 0 ;;
  light) ;;
  *)
    echo "error: config/claude-worker-context holds '$mode'; accepted values are: light (the default when the file is absent), full (the unrestricted launch)" >&2
    return 1
    ;;
  esac

  present=$(fm_config_source_present "$config/claude-worker-tools") || return 1
  if [ "$present" = 1 ]; then
    tools=$(_fm_claude_ctx_read "$config/claude-worker-tools" "config/claude-worker-tools" 'A-Za-z0-9_.-') || return 1
    [ -n "$tools" ] || {
      echo "error: config/claude-worker-tools lists no tools; list at least ToolSearch and Bash, or set config/claude-worker-context to full" >&2
      return 1
    }
    tools=$(printf '%s' "$tools" | tr '\n' ',')
  else
    tools=$FM_CLAUDE_CTX_DEFAULT_TOOLS
  fi
  FM_CLAUDE_CTX_TOOLS_FLAG="--tools=$tools "

  present=$(fm_config_source_present "$config/claude-worker-mcp-deny") || return 1
  if [ "$present" = 1 ]; then
    deny=$(_fm_claude_ctx_read "$config/claude-worker-mcp-deny" "config/claude-worker-mcp-deny" 'A-Za-z0-9_. -') || return 1
  else
    deny=$FM_CLAUDE_CTX_DEFAULT_DENY
  fi
  [ -n "$deny" ] || return 0
  while IFS= read -r entry; do
    names="${names:+$names
}$entry"
  done <<EOF
$deny
EOF
  json=$(printf '%s\n' "$names" | jq -Rcs 'split("\n") | map(select(. != "") | {serverName: .})') || return 1
  FM_CLAUDE_CTX_DENY_JSON=",\"deniedMcpServers\":$json"
}
