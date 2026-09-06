#!/usr/bin/env bash
# Claude Stop-hook advisor for CREWMATE/SCOUT worktrees only: reviews the last
# completed turn with a second, stronger model and exits 2 with terse advice
# (Claude continues the turn with that text as feedback), or exits 0 when the
# reviewer says OK or the turn is skipped. Installed only by bin/fm-spawn.sh,
# only for the claude harness, only when a dispatch profile's "advisor" field
# is resolved (docs/configuration.md "Crew dispatch profiles" owns the
# schema); never installed for --secondmate launches or the primary session.
#
# Env knobs (all set by fm-spawn.sh at install time):
#   FM_ADVISOR_MODEL     model for the review call (default: sonnet)
#   FM_ADVISOR_EFFORT     --effort for the review call (default: low)
#   FM_ADVISOR_MAX_CALLS  hard cap on advisor invocations for this worktree (default: 20)
#   FM_ADVISOR_COUNTER    counter file path (default: ./.advisor-count)
#   FM_ADVISOR_LOG        jsonl measurement log path (default: ./.advisor-log.jsonl)
#   FM_ADVISOR_BRIEF      path to the task brief to include if it exists (default: ./BRIEF.md)
#   FM_ADVISOR_TIMEOUT    seconds before the review call is killed (default: 60)
#
# Exit contract (a Claude Stop hook's only two meaningful outcomes):
#   0  no advice - turn was skipped, capped, malformed, or the reviewer said OK
#   2  advice on stderr - Claude Code continues the turn with that text as feedback
# Every failure mode (missing jq, unreadable transcript, a failed or
# unparseable reviewer call) exits 0: this hook must never block a
# crewmate's turn, only advise on top of one that already completed.
set -u

ADVISOR_MODEL="${FM_ADVISOR_MODEL:-sonnet}"
ADVISOR_EFFORT="${FM_ADVISOR_EFFORT:-low}"
MAX_CALLS="${FM_ADVISOR_MAX_CALLS:-20}"
COUNTER_FILE="${FM_ADVISOR_COUNTER:-./.advisor-count}"
LOG_FILE="${FM_ADVISOR_LOG:-./.advisor-log.jsonl}"
BRIEF_FILE="${FM_ADVISOR_BRIEF:-./BRIEF.md}"
TIMEOUT_SECS="${FM_ADVISOR_TIMEOUT:-60}"

log_event() {
  # $1=verdict $2=cost $3=duration_ms $4=note
  jq -cn --arg ts "$(date -u +%FT%TZ)" --arg verdict "$1" \
    --argjson cost "${2:-0}" --argjson dur "${3:-0}" --arg note "${4:-}" \
    '{ts:$ts,verdict:$verdict,cost_usd:$cost,duration_ms:$dur,note:$note}' >> "$LOG_FILE" 2>/dev/null
}

payload=$(cat)
[ -n "$payload" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

stop_hook_active=$(printf '%s' "$payload" | jq -r '.stop_hook_active // false' 2>/dev/null)
transcript_path=$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)

# Never re-advise on the continuation our own exit-2 caused; a per-worktree
# counter below is the second, independent loop guard in case a harness
# quirk ever fails to set this flag.
[ "$stop_hook_active" = "true" ] && { log_event skip 0 0 stop_hook_active; exit 0; }
[ -n "$transcript_path" ] && [ -f "$transcript_path" ] || exit 0

count=0
[ -f "$COUNTER_FILE" ] && count=$(cat "$COUNTER_FILE" 2>/dev/null || printf 0)
case "$count" in ''|*[!0-9]*) count=0 ;; esac
count=$((count + 1))
printf '%s' "$count" > "$COUNTER_FILE" 2>/dev/null
if [ "$count" -gt "$MAX_CALLS" ]; then
  log_event skip 0 0 "max-calls-exhausted:$MAX_CALLS"
  exit 0
fi

# Bounded transcript window: last 8 user/assistant entries, each block
# truncated so a huge tool result cannot blow up the review prompt.
window_text=$(jq -r -s '
  def clip(n): if (.|length) > n then (.[0:n] + "...[clipped]") else . end;
  def block_text:
    if .type == "text" then (.text // "" | clip(1200))
    elif .type == "tool_use" then ("[tool_use " + (.name // "?") + "] " + ((.input // {} | tostring)) | clip(500))
    elif .type == "tool_result" then ("[tool_result] " + ((.content | if type=="array" then map(.text? // "") | join(" ") else (. // "" | tostring) end)) | clip(500))
    else empty end;
  [ .[] | select(.type=="user" or .type=="assistant") ] as $msgs
  | $msgs[-8:]
  | map(
      (.type|ascii_upcase) as $role
      | (.message.content // []) as $content
      | ($content | if type=="array" then map(block_text) | join("\n") else (.|tostring) end) as $body
      | "== " + $role + " ==\n" + $body
    )
  | join("\n\n")
' "$transcript_path" 2>/dev/null)

# Never advise on a turn that only wrote a status line: no real tool_use
# besides a status-file append, and negligible assistant prose.
last_turn_summary=$(jq -r -s '
  [ .[] | select(.type=="assistant") ] as $a
  | if ($a|length)==0 then "" else
      ($a[-1].message.content // []) as $c
      | ($c | map(select(.type=="tool_use")) ) as $tools
      | ($c | map(select(.type=="text") | .text) | join(" ")) as $text
      | {tool_names: ($tools | map(.name)), tool_inputs: ($tools | map(.input | tostring)), text_len: ($text|length)} | tostring
    end
' "$transcript_path" 2>/dev/null)
only_status_line=false
if printf '%s' "$last_turn_summary" | jq -e '
    (.tool_names | length) > 0
    and (.tool_names | all(. == "Bash"))
    and (.tool_inputs | all(test("status"; "i") and (test("Edit|Write"; "i")|not)))
    and (.text_len // 0) < 200
  ' >/dev/null 2>&1; then
  only_status_line=true
fi
if [ "$only_status_line" = true ]; then
  log_event skip 0 0 status-line-only-turn
  exit 0
fi

brief_text=""
[ -f "$BRIEF_FILE" ] && brief_text=$(head -c 4000 "$BRIEF_FILE" 2>/dev/null)

review_prompt=$(cat <<PROMPT
You are a terse second-opinion reviewer for an autonomous coding agent's just-completed turn.
Flag only a MATERIAL problem: a violated brief constraint, a wrong assumption, or a fragile
design choice whose cost of discovering later clearly exceeds the cost of flagging it now.
Do not flag nitpicks, style preferences, or anything you are not confident is a real defect.
Do not restate what was done, do not praise, do not speculate about things
you cannot see in the transcript below.

Answer with EXACTLY ONE of:
- the single word OK, and nothing else, if there is nothing material worth flagging
- 1 to 3 short bullet points (each starts with "- ", one line, under 150
  characters), total reply under 600 characters, no preamble or sign-off

Task brief (may be empty):
${brief_text:-<none available>}

Recent turns (most recent last, truncated):
${window_text:-<no transcript window available>}
PROMPT
)

response=$(printf '%s' "$review_prompt" | timeout "$TIMEOUT_SECS" claude -p \
  --model "$ADVISOR_MODEL" --effort "$ADVISOR_EFFORT" --bare \
  --output-format json --tools "" --strict-mcp-config --permission-prompts none \
  --no-session-persistence 2>/dev/null)
rc=$?
if [ "$rc" -ne 0 ] || [ -z "$response" ]; then
  log_event fail-open 0 0 "advisor-call-rc:$rc"
  exit 0
fi

# --output-format json wraps stream events in an array in the verified CLI
# version; pull the last "result"-typed entry rather than assume the shape.
result_obj=$(printf '%s' "$response" | jq -c '
  if type=="array" then ([.[] | select(.type=="result")] | last // {}) else . end
' 2>/dev/null)
result_text=$(printf '%s' "$result_obj" | jq -r '.result // empty' 2>/dev/null)
cost=$(printf '%s' "$result_obj" | jq '.total_cost_usd // 0' 2>/dev/null)
dur=$(printf '%s' "$result_obj" | jq '.duration_ms // 0' 2>/dev/null)
if [ -z "$result_text" ]; then
  log_event fail-open "${cost:-0}" "${dur:-0}" no-result-field
  exit 0
fi

trimmed=$(printf '%s' "$result_text" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
if [ "$trimmed" = "ok" ]; then
  log_event ok "${cost:-0}" "${dur:-0}" ""
  exit 0
fi

advice=$(printf '%s' "$result_text" | cut -c1-600)
log_event advise "${cost:-0}" "${dur:-0}" "$(printf '%s' "$advice" | tr '\n' ' ' | cut -c1-200)"
printf '%s\n' "$advice" >&2
exit 2
