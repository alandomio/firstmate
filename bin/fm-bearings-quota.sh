#!/usr/bin/env bash
# fm-bearings-quota.sh - the /bearings lavish board's provider-quota reader.
#
# Runs quota-axi once, bounded, for the three providers the fleet dispatches
# on, and prints the board payload's optional `quota` section as JSON on
# stdout. The composer copies that output verbatim into the
# fm-bearings-board.v1 payload; bin/fm-bearings-board.sh validates it and the
# board template renders it. Composer judgment never touches these numbers.
#
# Usage:
#   fm-bearings-quota.sh
#
# Providers, in board order: claude (Anthropic), codex (OpenAI), agy (Google).
#
# This reader never fails the board: a missing quota-axi, a timeout, a
# non-zero exit without readable output, or unreadable output all still print
# a valid section with available=false and a status code saying why, and the
# script exits 0. It never invents a value: a percentage quota-axi did not
# report stays null, and a provider quota-axi did not report is marked
# not_reported. It reads with --no-credential-refresh, so it never renews a
# vendor session, and it is kept separate from bin/fm-bearings-snapshot.sh so
# that snapshot's local-only default stays intact.
#
# Output shape (every key always present unless marked optional):
#   {
#     "source": "quota-axi",
#     "generated": <quota-axi generatedAt string, or null>,
#     "available": <bool>,
#     "status": "ok" | "tool_missing" | "timeout" | "failed" | "unreadable",
#     "detail": <string, optional: why the read failed>,
#     "providers": [
#       {
#         "provider": "claude" | "codex" | "agy",
#         "label": "Anthropic" | "OpenAI" | "Google",
#         "available": <bool: false when no window can be shown>,
#         "status": <quota-axi state.status such as fresh, stale,
#                    auth_required; or not_reported, no_windows, or the
#                    section status when the whole read failed>,
#         "detail": <string, optional: quota-axi's own error text>,
#         "plan": <string or null>,
#         "windows": [
#           { "id", "label", "kind",
#             "percent_used": <0-100 or null>,
#             "percent_remaining": <0-100 or null>,
#             "resets_at": <ISO string or null> }
#         ],
#         "attention": [
#           { "kind": "stale" | "auth_required" | "headroom_unknown" | <other
#                     non-fresh state>,
#             "detail": <string, optional> }
#         ]
#       }
#     ]
#   }
#
# FM_BEARINGS_QUOTA_TIMEOUT bounds the quota-axi call in seconds (default 20).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"

FM_BEARINGS_QUOTA_TIMEOUT=${FM_BEARINGS_QUOTA_TIMEOUT:-20}
case "$FM_BEARINGS_QUOTA_TIMEOUT" in ''|*[!0-9]*|0) FM_BEARINGS_QUOTA_TIMEOUT=20 ;; esac
PROVIDERS=claude,codex,agy

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1-}" in
  -h|--help|help) usage; exit 0 ;;
  '') ;;
  *) usage >&2; exit 2 ;;
esac
command -v jq >/dev/null 2>&1 || { echo "fm-bearings-quota: jq is required" >&2; exit 1; }

# Emit the degraded section: every provider unavailable for the same reason.
degraded() {  # <status> <detail>
  jq -n --arg status "$1" --arg detail "$2" '
    def provider($id; $label):
      { provider: $id, label: $label, available: false, status: $status,
        detail: $detail, plan: null, windows: [], attention: [] };
    { source: "quota-axi", generated: null, available: false,
      status: $status, detail: $detail,
      providers: [provider("claude"; "Anthropic"), provider("codex"; "OpenAI"),
                  provider("agy"; "Google")] }'
}

if ! command -v quota-axi >/dev/null 2>&1; then
  degraded tool_missing "quota-axi is not installed"
  exit 0
fi

out=$(fm_run_timed "$FM_BEARINGS_QUOTA_TIMEOUT" \
  quota-axi --provider "$PROVIDERS" --json --no-credential-refresh 2>/dev/null)
rc=$?
if [ "$rc" -eq 124 ]; then
  degraded timeout "quota-axi did not answer within ${FM_BEARINGS_QUOTA_TIMEOUT}s"
  exit 0
fi
# quota-axi may exit non-zero while still reporting per-provider errors in
# readable JSON, so a readable providers array wins over the exit code.
if ! printf '%s' "$out" | jq -e 'type == "object" and (.providers | type == "array")' >/dev/null 2>&1; then
  if [ "$rc" -ne 0 ]; then
    degraded failed "quota-axi exited with status $rc"
  else
    degraded unreadable "quota-axi output is not the expected JSON"
  fi
  exit 0
fi

printf '%s' "$out" | jq '
  def pct: if type == "number" and . >= 0 and . <= 100 then . else null end;
  def str_or_null: if type == "string" and length > 0 then . else null end;
  def window:
    ((.percentRemaining | pct) // (if (.percentUsed | pct) != null then 100 - .percentUsed else null end)) as $rem
    | { id: ((.id | str_or_null) // ""),
        label: ((.label | str_or_null) // (.id | str_or_null) // "window"),
        kind: ((.kind | str_or_null) // ""),
        percent_used: (if $rem == null then null else 100 - $rem end),
        percent_remaining: $rem,
        resets_at: (.resetsAt | str_or_null) };
  def project($id; $label):
    (first(.providers[] | select(type == "object" and .provider == $id)) // null) as $p
    | if $p == null then
        { provider: $id, label: $label, available: false, status: "not_reported",
          plan: null, windows: [], attention: [] }
      else
        (($p.state.status | str_or_null) // "unknown") as $state
        | ([($p.windows // [])[] | select(type == "object") | window]) as $windows
        | ([($p.quotaSemantics.effectiveAvailability // [])[]
            | select(type == "object" and .status == "unknown") | .scope | str_or_null]) as $unknown
        | { provider: $id, label: $label,
            available: ($state != "auth_required" and ($windows | length) > 0),
            status: (if $state != "auth_required" and ($windows | length) == 0 then "no_windows" else $state end),
            plan: ($p.plan | str_or_null),
            windows: $windows,
            attention: (
              (if $state == "fresh" then [] else
                [{ kind: $state } + (if ($p.state.error | str_or_null) then { detail: $p.state.error } else {} end)]
              end)
              + (if ($unknown | length) > 0 and $state != "auth_required" then
                  [{ kind: "headroom_unknown", detail: ($unknown | join(", ")) }]
                else [] end)) }
          + (if ($p.state.error | str_or_null) then { detail: $p.state.error } else {} end)
      end;
  { source: "quota-axi", generated: (.generatedAt | str_or_null), available: true, status: "ok",
    providers: [project("claude"; "Anthropic"), project("codex"; "OpenAI"), project("agy"; "Google")] }'
