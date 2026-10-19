#!/usr/bin/env bash
# fm-bearings-board.sh - build, arm, and live-refresh the /bearings lavish fleet board.
#
# The board is the captain-facing interactive surface of /bearings lavish: the
# shipped template (.agents/skills/bearings/assets/board-template.html) plus one
# injected fm-bearings-board.v1 JSON payload. This script owns the mechanics so
# the invoking agent's per-run work stays "compose the JSON, run build" - the
# agent never authors board UI at invocation time.
#
# Usage:
#   fm-bearings-board.sh build <data.json>
#   fm-bearings-board.sh refresh
#   fm-bearings-board.sh loop [--interval <seconds>]
#   fm-bearings-board.sh systemd-units [--interval <seconds>] [--dir <path>]
#   fm-bearings-board.sh path
#
# build      Validate the payload, drop the Captain's Call cards whose subject
#            already landed, give every surviving decision card the standard
#            reconcile choice, and inject the result into a fresh copy of the
#            shipped template at the stable board path. Establish the Lavish
#            session on that board and PROVE it is live BEFORE binding and
#            arming its answer source, so a registered poll can never race a
#            session that does not exist or attach to one that has ended.
#            Bind to the keyed-answer intake (bin/fm-captain-hold.sh) ALWAYS
#            precedes arm, so the board can never produce an answer that has
#            nowhere to go (captain-hold-lifecycle's ordering rule, enforced
#            here rather than left to agent memory). Before serving, build also
#            writes the live data file beside the board (the same payload) and
#            replaces the private composed-card store with this payload's
#            Captain's Call cards, so a later refresh reuses firstmate's
#            composed text. Output starts with `board: <path>`, then includes
#            lavish-axi's session output and the remaining status:
#              session: live | reopened
#              served: <path>
#              bound: <source-id>
#              armed: <source-id>            (first registration)
#              already-armed: <source-id>    (registration already present)
#              listening: <owner>            (only when a replacement was needed)
#            Every dropped card is named on stderr as a `dropped-landed-card:`
#            line, so a rebuild states what it removed instead of quietly
#            shrinking Captain's Call.
# refresh    The live board's deterministic regeneration; it never calls a
#            model, never rewrites the board page, never touches the Lavish
#            session, and never binds or arms anything. It does nothing unless
#            config/live-board's first non-blank line is exactly `on` and the
#            board has been published by a build; each of those prints one
#            `skipped: <why>` line and exits 0. It keeps running during away
#            mode and its return catch-up, when the captain watches the board
#            from elsewhere: it reads bin/fm-bearings-snapshot.sh --unattended
#            --json --all-decisions --all-in-flight
#            --all-recorded-prs (local-only; open holds, in-flight tasks, and
#            recorded PRs are complete, gates stay capped) and
#            bin/fm-bearings-quota.sh, composes a fresh payload with source
#            "live-refresh", validates it exactly as build does, and atomically
#            replaces the live data file, printing `refreshed: <path>`. The
#            page loads that file on its own timer, so a refresh never reloads
#            the page and never disturbs an answer being typed or queued.
#            Composition rules: a Captain's Call card is the stored composed
#            card while its key is still an open captain hold (or, for a
#            `merge.<task-id>` card, while that task is in flight with a
#            recorded PR); an open hold with no composed card becomes a raw
#            card (raw: true) carrying the hold's own reason, answered in free
#            text, with close "release" because a raw card cannot know
#            whether the held task is a question or gated work. The result
#            then gets build's Captain's Call hygiene and reconcile choice.
#            Underway rows are the snapshot's in-flight rows (secondmate
#            children included) with its name, and `since` from the task's
#            status-log mtime; the `prs` section is every locally recorded PR
#            with the task's last reported state; landed, charted, and
#            charted_more come straight from the snapshot, with a charted row
#            dispatchable only when it names no blocker and no gate reason;
#            the main-inventory and return-catchup gates and an unavailable
#            secondmate home are warning rows, and an externally held
#            secondmate home is a non-dispatchable charted row.
# loop       Run refresh every <seconds> (default 90, minimum 30) forever, for a
#            supervisor that is not systemd (launchd, a tmux pane). A failed
#            refresh is reported on stderr and the loop continues.
# systemd-units
#            Print (or, with --dir, write) a user-level systemd service and
#            timer that run refresh every <seconds> (default 90, minimum 30)
#            for this FM_HOME, capturing the current PATH so the timer finds
#            the same tools. The unit name is fm-live-board-<cksum of FM_HOME>
#            so several homes on one machine never collide.
# path       Print the stable board path for this home.
#
# A LIVE SESSION IS PROVED, NEVER ASSUMED. `lavish-axi <file>` exits 0 even
# when it refuses to reopen a session the captain ended from the browser,
# reporting `status: user-ended` with the same session id, so exit status alone
# cannot tell a live board from a dead one. build requires the server's fresh
# session listing to show the canonical board open and refuses rather than
# arming an ended session. After a reopen it retires the pre-reopen source
# generation through the guarded adapter path, arms a fresh registration, and
# accepts only the replacement listener as live. A registered board with no
# live owner also gets a replacement before build returns, because
# `already-armed` is not the same fact as `listening`.
#
# CAPTAIN'S CALL HYGIENE. A decision card is dropped when its work item, PR, or
# structured artifact/version subject appears among the payload's own landed
# rows, or when `bin/fm-captain-hold.sh open` reports the task is no longer an
# open captain call. A newer published version also supersedes a version card.
# A task whose state cannot be established is kept, because a call wrongly
# hidden is worse than a card wrongly shown. Cleanup is therefore a normal
# rebuild effect rather than a committed migration or direct state mutation.
#
# THE RECONCILE CHOICE. Every decision card carries the standard `reconcile`
# option, injected here so the guarantee does not depend on the composer's
# memory, and the payload validator reserves that value across every card type.
# The validator's reservation scope must equal the adapter's reconcile
# classification scope, which is all card types because the captured payload
# carries no card type. Its meaning, and the reason it can never reach the
# keyed-answer intake as a blind close, are owned by
# docs/captain-hold-lifecycle.md.
#
# Validation is fail-closed: the payload must be valid JSON with
# schema=fm-bearings-board.v1 and every renderer-consumed field must satisfy
# the fm-bearings-board.v1 types and item invariants below. Every fleet row and
# Captain's Call item explicitly carries `repo`; the composer fills it from the
# snapshot and task records wherever known, and uses null or an empty string
# only as the deliberate genuinely-no-repo marker. In that exceptional case
# the template may display the routing id. Every Captain's Call item also
# carries `allow_freeform: true`; there is no card the composer may render
# without an open response textbox. The optional `quota` section is exactly
# what bin/fm-bearings-quota.sh prints (that script's header owns its shape);
# a payload without it still validates, and one carrying it must satisfy that
# shape. Optional live fields: top-level `source` (string), an underway row's
# `since` (string or null), a Captain's Call item's `raw` (boolean), and a
# `prs` array of {id, repo, url (https), state, doing}. Anything else refuses
# before the existing board is touched.
#
# Every Underway row likewise carries a non-empty `name`: the durable task name
# when known, otherwise its durable identifier.
# A Charted Next row MAY carry `filed`, the durable filed date (YYYY-MM-DD, or
# that date with a UTC timestamp) the template orders the section by, newest
# first; a row with no comparable date keeps its payload order after every dated
# row. Anything else in that field refuses rather than sorting on garbage.
#
# The board path is stable - $FM_HOME/.lavish/bearings-board.html - so a
# re-invocation rebuilds the same file in place, which keeps the same Lavish
# session URL and the same canonical process-event source id. Injection escapes
# every `<` in the compact JSON as the \u003c string escape, so a payload string
# containing "</script>" can never terminate the data block early. The live
# data file sits beside it as bearings-board.data.js, a script that hands the
# payload to the page; Lavish hot-reloads only on a change to the page file
# itself, so replacing the data file never reloads the page. The composed-card
# store is data/bearings-board-cards.json (fm-bearings-board-cards.v1), private
# and mode 0600.
#
# FM_BEARINGS_BOARD_TEMPLATE overrides the shipped template path (tests only).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

TEMPLATE="${FM_BEARINGS_BOARD_TEMPLATE:-$SCRIPT_DIR/../.agents/skills/bearings/assets/board-template.html}"
PLACEHOLDER='__FM_BEARINGS_BOARD_DATA__'
BOARD_SCHEMA=fm-bearings-board.v1
CARDS_SCHEMA=fm-bearings-board-cards.v1
DEFAULT_INTERVAL=90
MIN_INTERVAL=30

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-bearings-board: %s\n' "$*" >&2
  exit 1
}

board_path() { printf '%s/.lavish/bearings-board.html\n' "$FM_HOME"; }
data_file_path() { printf '%s/.lavish/bearings-board.data.js\n' "$FM_HOME"; }
cards_path() { printf '%s/bearings-board-cards.json\n' "$DATA"; }

# The fm-bearings-board.v1 item and payload invariants, shared by build's
# validation and refresh's per-card filtering so the two can never disagree.
# shellcheck disable=SC2016 # jq program text, not shell expansion
BOARD_JQ_DEFS='
    def nonempty_string: type == "string" and length > 0;
    def slug($max): type == "string" and test("^[A-Za-z0-9._-]{1," + ($max | tostring) + "}$");
    def repo_marker: has("repo") and (.repo == null or (.repo | type == "string"));
    def name_marker: has("name") and (.name | nonempty_string);
    def valid_filed:
      . as $filed
      | type == "string"
      and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)?$")
      and (if test("T")
        then try ((fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) == $filed) catch false
        else try (((. + "T00:00:00Z") | fromdateiso8601 | strftime("%Y-%m-%d")) == $filed) catch false
        end);
    def optional_filed:
      (has("filed") | not) or (.filed == null) or (.filed | valid_filed);
    def optional_string($name): (has($name) | not) or (.[$name] | type == "string");
    def is_https_url:
      type == "string"
      and test("^https://[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::[0-9]{1,5})?(?:[/?#][^[:space:]]*)?$");
    def optional_https_url($name): (has($name) | not) or (.[$name] | is_https_url);
    def version: type == "string" and test("^(0|[1-9][0-9]{0,8})\\.(0|[1-9][0-9]{0,8})\\.(0|[1-9][0-9]{0,8})$");
    def optional_subject:
      (has("subject") | not)
      or (.subject
        | type == "object"
          and (keys | sort) == ["artifact", "version"]
          and (.artifact | slug(128))
          and (.version | version));
    def call_item:
      type == "object"
      and (.key | slug(128))
      and (.type == "decision" or .type == "merge" or .type == "credential")
      and repo_marker
      and (.title | nonempty_string)
      and (.options | type == "array")
      and ([.options[]
        | type == "object"
          and (.value | slug(128))
          and (.label | nonempty_string)
          and optional_string("hint")] | all)
      and (optional_string("about"))
      and (optional_string("decide"))
      and (optional_string("detail"))
      and (optional_string("recommend_reason"))
      and (optional_https_url("pr_url"))
      and optional_subject
      and (if has("subject") then .type == "decision" else true end)
      and (optional_string("freeform_hint"))
      and ((has("close") | not) or (.close == "done" or .close == "release"))
      and ((has("raw") | not) or (.raw | type == "boolean"))
      and (.allow_freeform == true)
      and ((has("recommend_value") | not)
        or ((.recommend_value | slug(128))
          and (.recommend_value as $recommend
            | ([.options[].value] | index($recommend) != null))))
      and ([.options[].value] | index("reconcile") == null)
      and (if .type == "merge" then (.risk | nonempty_string) else true end);
    def underway_item:
      type == "object" and repo_marker and name_marker and (.id | nonempty_string)
      and (.state | nonempty_string) and (.doing | nonempty_string) and (.kind | nonempty_string)
      and ((has("since") | not) or .since == null or (.since | type == "string"));
    def landed_item:
      type == "object" and repo_marker and (.id | nonempty_string)
      and (.what | nonempty_string) and (.owner | nonempty_string)
      and optional_https_url("pr_url")
      and optional_subject;
    def charted_item:
      type == "object" and repo_marker and (.id | slug(128))
      and (.title | nonempty_string) and (.reason | type == "string")
      and (.dispatchable | type == "boolean")
      and ((has("kind") | not) or (.kind == "queued" or .kind == "warning"))
      and optional_filed
      and (if .kind == "warning" then .dispatchable == false else true end);
    def pr_item:
      type == "object" and repo_marker and (.id | nonempty_string)
      and (.url | is_https_url) and (.state | type == "string") and (.doing | type == "string");
    def percent: . == null or (type == "number" and . >= 0 and . <= 100);
    def nullable_string($name): (.[$name] == null) or (.[$name] | type == "string");
    def quota_window:
      type == "object" and (.label | nonempty_string) and (.kind | type == "string")
      and (.percent_used | percent) and (.percent_remaining | percent)
      and nullable_string("resets_at");
    def quota_attention: type == "object" and (.kind | slug(64)) and optional_string("detail");
    def quota_provider:
      type == "object" and (.provider | slug(64)) and (.label | nonempty_string)
      and (.available | type == "boolean") and (.status | slug(64))
      and optional_string("detail") and nullable_string("plan")
      and (.windows | type == "array") and ([.windows[] | quota_window] | all)
      and (.attention | type == "array") and ([.attention[] | quota_attention] | all);
    def quota_section:
      type == "object" and (.available | type == "boolean") and (.status | slug(64))
      and optional_string("detail") and nullable_string("generated")
      and (.providers | type == "array") and ([.providers[] | quota_provider] | all);
    def board_payload($schema):
      type == "object"
      and (.schema == $schema)
      and (.home | nonempty_string)
      and (.generated | nonempty_string)
      and (.prs_live | type == "boolean")
      and optional_string("source")
      and (.captains_call | type == "array")
      and (.underway | type == "array")
      and (.landed | type == "array")
      and (.charted | type == "array")
      and ((has("charted_more") | not)
        or ((.charted_more | type == "number") and (.charted_more >= 0) and (.charted_more | floor == .)))
      and ((has("charted_warning_more") | not)
        or ((.charted_warning_more | type == "number") and (.charted_warning_more >= 0) and (.charted_warning_more | floor == .)))
      and ([.captains_call[] | call_item] | all)
      and ([.underway[] | underway_item] | all)
      and ([.landed[] | landed_item] | all)
      and ([.charted[] | charted_item] | all)
      and ((has("prs") | not) or ((.prs | type == "array") and ([.prs[] | pr_item] | all)))
      and ((has("quota") | not) or (.quota | quota_section));
'

validate_payload() {  # <data.json>
  jq -e --arg schema "$BOARD_SCHEMA" "$BOARD_JQ_DEFS"' board_payload($schema)' "$1" >/dev/null
}

# Atomically replace <dest> with <src> (same directory), mode 0600.
publish_file() {  # <src> <dest>
  if ! { chmod 0600 "$1" && mv -f -- "$1" "$2"; }; then
    rm -f -- "$1"
    return 1
  fi
}

# Write the live data file the page loads on its own timer. `<` is escaped for
# the same reason as the inline slot, so no payload string can close a tag.
write_data_file() {  # <data.json>
  local dest json tmp
  dest=$(data_file_path)
  json=$(jq -c . "$1") || return 1
  json=${json//</\\u003c}
  (umask 077; mkdir -p "${dest%/*}") || return 1
  tmp=$(umask 077; mktemp "${dest%/*}/.board-data.XXXXXX") || return 1
  if ! printf '(function (d) { if (typeof window.fmBearingsBoardData === "function") window.fmBearingsBoardData(d); })(%s);\n' \
      "$json" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  publish_file "$tmp" "$dest"
}

# Replace the private composed-card store with this payload's composed
# Captain's Call cards. A raw card is never stored, so it cannot come back
# looking like firstmate's composed text.
write_card_store() {  # <data.json>
  local dest tmp
  dest=$(cards_path)
  (umask 077; mkdir -p "${dest%/*}") || return 1
  tmp=$(umask 077; mktemp "${dest%/*}/.bearings-board-cards.XXXXXX") || return 1
  if ! jq --arg schema "$CARDS_SCHEMA" \
      '{schema: $schema, generated: .generated, cards: [.captains_call[] | select(.raw != true)]}' \
      "$1" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  publish_file "$tmp" "$dest"
}

# --- Lavish session liveness -------------------------------------------------
# Verified against lavish-axi 0.1.61. `lavish-axi <file>` EXITS 0 even when it
# refuses to reopen a session the captain ended from the browser, reporting
# `status: user-ended` and the same session id, so an exit-code check alone
# cannot tell a live board from a dead one. The establish status is an initial
# signal only; the server's fresh session listing must also show the canonical
# board open before the build may bind or arm its source.

board_realpath() {  # <board>
  perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$1" 2>/dev/null
}

lavish_status_field() {  # <lavish-axi output>
  printf '%s\n' "$1" | sed -n 's/^[[:space:]]*status:[[:space:]]*//p' | head -1 | tr -d '"'
}

# The server's own listing, keyed on the canonical artifact path. Rows are
# `<file>,<status>,"<url>",<pending>`, and only a live session is listed `open`.
lavish_session_listed_open() {  # <canonical-board-path>
  local listing
  listing=$(lavish-axi 2>/dev/null) || return 1
  printf '%s\n' "$listing" | awk -v path="$1" '
    { line = $0; sub(/^[[:space:]]+/, "", line) }
    index(line, path ",") == 1 {
      rest = substr(line, length(path) + 2)
      split(rest, field, ",")
      if (field[1] == "open") { found = 1 }
    }
    END { exit found ? 0 : 1 }
  '
}

lavish_board_live() {  # <establish output> <canonical-board-path>
  lavish_session_listed_open "$2"
}

# Establish the board session and PROVE it is live before anything arms a poll
# on it. A session the captain ended is reopened once - the captain asked for
# this board, which is exactly the attention `--reopen` exists for - and a
# session that is still not live after that refuses the build rather than
# arming a poll that can never attach.
establish_board_session() {  # <board>
  local board=$1 real out status version
  BOARD_SESSION_REOPENED=0
  real=$(board_realpath "$board") || fail "cannot resolve the board path: $board"
  out=$(lavish-axi "$board") || fail "cannot establish the board Lavish session"
  printf '%s\n' "$out"
  if lavish_board_live "$out" "$real"; then
    printf 'session: live\n'
    return 0
  fi
  out=$(lavish-axi "$board" --reopen) || fail "cannot reopen the ended board Lavish session"
  printf '%s\n' "$out"
  if lavish_board_live "$out" "$real"; then
    BOARD_SESSION_REOPENED=1
    printf 'session: reopened\n'
    return 0
  fi
  status=$(lavish_status_field "$out")
  version=$(lavish-axi --version 2>/dev/null | tr -d '[:space:]')
  fail "the board Lavish session is not live after reopening it (lavish-axi ${version:-version-unknown} reported status ${status:-none}); refusing to arm a poll on an ended session"
}

# --- Captain's Call hygiene ---------------------------------------------------
# A held decision whose subject already shipped is not a live call, so it is
# dropped here instead of being carded again. All checks use exact structured
# identities; unknown subject state keeps the card.

decision_card_is_stale() {  # <task-id> <landed-0-or-1>
  local task=$1 landed=$2 rc=0
  if [ "$landed" = 1 ]; then
    printf 'structured subject already landed\n'
    return 0
  fi
  "$SCRIPT_DIR/fm-captain-hold.sh" open "$task" --distinguish-absent >/dev/null 2>&1 || rc=$?
  # 1 is a definite "no longer an open captain call". 2 is "cannot tell", 3 is
  # absent from this backlog, and a call wrongly hidden is worse than a card
  # wrongly shown, so both uncertain and absent cards stay.
  if [ "$rc" -eq 1 ]; then
    printf 'no longer an open captain call\n'
    return 0
  fi
  return 1
}

# Drop every stale decision card, then give every surviving decision card the
# standard reconcile choice. Injecting it here is what makes "every decision
# card offers reconcile" a property of the board rather than of the composer's
# memory; the validator prevents duplicate decision options.
effective_payload() {  # <data.json> <dest.json>
  local data=$1 dest=$2 landed_keys key reason drop='' tmp landed=0
  landed_keys=$(jq -c '
    def version_parts: split(".") | map(tonumber);
    . as $payload
    | [$payload.captains_call[]
      | select(.type == "decision")
      | . as $card
      | select(
          ($payload.landed | any(.id == $card.key))
          or (($card.pr_url? != null) and ($payload.landed | any(.pr_url? == $card.pr_url)))
          or (($card.subject? != null) and ($payload.landed | any(
            (.subject? != null)
            and (.subject.artifact == $card.subject.artifact)
            and ((.subject.version | version_parts) >= ($card.subject.version | version_parts)))))
        )
      | .key]
  ' "$data") || return 1
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    landed=0
    if jq -e --arg key "$key" 'index($key) != null' <<< "$landed_keys" >/dev/null; then
      landed=1
    fi
    reason=$(decision_card_is_stale "$key" "$landed") || continue
    printf 'dropped-landed-card: %s (%s)\n' "$key" "$reason" >&2
    drop=$drop$key$'\n'
  done < <(jq -r '.captains_call[]? | select(.type == "decision") | .key' "$data")
  tmp=$(printf '%s' "$drop" | jq -R -s 'split("\n") | map(select(length > 0))') || return 1
  jq --argjson dropped "$tmp" '
    .captains_call = [
      .captains_call[]
      | . as $card
      | select($card.type != "decision" or (($dropped | index($card.key)) == null))
      | if .type == "decision"
        then .options += [{
          value: "reconcile",
          label: "Reconcile",
          hint: "Re-check the latest state, then close this with evidence or keep it open with a note"
        }]
        else . end
    ]' "$data" > "$dest" || return 1
}

# The OWNER column bin/fm-procevent.sh already publishes: live, none,
# orphaned, or uncertain. Empty means the source is not registered at all.
source_owner() {  # <source-id>
  "$SCRIPT_DIR/fm-procevent.sh" list 2>/dev/null \
    | awk -v id="$1" 'NR > 1 && $1 == id { print $3 }'
}

# A replacement listener is started detached, so it claims the source shortly
# after reconcile returns. Wait for that claim rather than reporting the race.
await_source_owner() {  # <source-id>
  local owner i=0
  while [ "$i" -lt 50 ]; do
    owner=$(source_owner "$1")
    [ "$owner" != live ] || { printf '%s\n' "$owner"; return 0; }
    sleep 0.1
    i=$((i + 1))
  done
  printf '%s\n' "${owner:-none}"
}

command_build() {
  local data=${1-} board json tmp sid extracted effective owner version pre_reopen_owner
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -f "$data" ] || fail "board data does not exist: $data"
  jq empty "$data" 2>/dev/null || fail "board data is not valid JSON: $data"
  validate_payload "$data" || fail "board data does not satisfy $BOARD_SCHEMA: $data"
  [ -f "$TEMPLATE" ] && [ ! -L "$TEMPLATE" ] || fail "board template is missing: $TEMPLATE"
  [ "$(grep -cxF "$PLACEHOLDER" "$TEMPLATE")" -eq 1 ] \
    || fail "board template does not carry exactly one data slot: $TEMPLATE"

  effective=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-bearings-payload.XXXXXX") \
    || fail "cannot stage the board payload"
  if ! effective_payload "$data" "$effective"; then
    rm -f -- "$effective"
    fail "cannot reconcile the board payload against landed work"
  fi
  json=$(jq -c . "$effective") || { rm -f -- "$effective"; fail "cannot compact the board data"; }
  # `<` never appears in JSON syntax outside strings, so escaping every
  # occurrence keeps the payload valid JSON while making </script> inert.
  json=${json//</\\u003c}

  board=$(board_path)
  (umask 077; mkdir -p "${board%/*}") || fail "cannot create ${board%/*}"
  tmp=$(umask 077; mktemp "${board%/*}/.board.XXXXXX") || fail "cannot stage the board"
  if ! BOARD_JSON="$json" perl -pe "s/^\\Q$PLACEHOLDER\\E\$/\$ENV{BOARD_JSON}/" "$TEMPLATE" > "$tmp"; then
    rm -f -- "$tmp" "$effective"
    fail "cannot inject the board data"
  fi
  if grep -qxF "$PLACEHOLDER" "$tmp"; then
    rm -f -- "$tmp" "$effective"
    fail "the board data slot survived injection"
  fi
  # Round-trip the injected payload back out of the built page, so a board that
  # would fail to parse in the browser fails here instead.
  extracted=$(sed -n '/<script id="bearings-data" type="application\/json">/,/<\/script>/p' "$tmp" \
    | sed '1d;$d')
  if ! printf '%s\n' "$extracted" | jq -e --arg schema "$BOARD_SCHEMA" '.schema == $schema' >/dev/null 2>&1; then
    rm -f -- "$tmp" "$effective"
    fail "the built board does not carry a readable $BOARD_SCHEMA payload"
  fi
  # The data file and card store land before the page, so a page that reloads
  # on this publish never loads an older live data file than its own payload.
  # The store keeps the composed cards without the injected reconcile choice.
  write_data_file "$effective" || { rm -f -- "$tmp" "$effective"; fail "cannot write the live board data"; }
  rm -f -- "$effective"
  write_card_store "$data" || { rm -f -- "$tmp"; fail "cannot write the composed-card store"; }
  publish_file "$tmp" "$board" || fail "cannot publish the board"
  printf 'board: %s\n' "$board"

  command -v lavish-axi >/dev/null 2>&1 || fail "lavish-axi is not installed"
  sid=$("$SCRIPT_DIR/fm-procevent-lavish.sh" source-id "$board") \
    || fail "cannot derive the board source id"
  pre_reopen_owner=$(source_owner "$sid")
  establish_board_session "$board"
  if [ "$BOARD_SESSION_REOPENED" = 1 ]; then
    "$SCRIPT_DIR/fm-procevent-lavish.sh" retire "$board" >/dev/null \
      || fail "cannot retire the pre-reopen source generation (observed owner: ${pre_reopen_owner:-none})"
  fi
  if ! lavish_session_listed_open "$(board_realpath "$board")"; then
    version=$(lavish-axi --version 2>/dev/null | tr -d '[:space:]')
    fail "the board Lavish session is not listed open immediately before arming (lavish-axi ${version:-version-unknown}); refusing to arm a poll on observed state not-open"
  fi
  printf 'served: %s\n' "$board"

  "$SCRIPT_DIR/fm-captain-hold.sh" bind "$sid" >/dev/null \
    || fail "cannot bind the board source to the keyed-answer intake"
  printf 'bound: %s\n' "$sid"

  owner=$(source_owner "$sid")
  if [ "$BOARD_SESSION_REOPENED" = 1 ]; then
    "$SCRIPT_DIR/fm-procevent-lavish.sh" arm "$board" >/dev/null \
      || fail "cannot arm a fresh board source after reopening"
    printf 'armed: %s\n' "$sid"
    owner=$(source_owner "$sid")
  elif [ -n "$owner" ]; then
    printf 'already-armed: %s\n' "$sid"
  else
    "$SCRIPT_DIR/fm-procevent-lavish.sh" arm "$board" >/dev/null \
      || fail "cannot arm the board as a process-event source"
    printf 'armed: %s\n' "$sid"
    owner=$(source_owner "$sid")
  fi
  # Registered is not listening. A board whose source has no live owner gets a
  # replacement started now rather than at the next supervision cycle, which is
  # what keeps a rebuilt board from sitting silent behind `already-armed`.
  if [ "$owner" != live ]; then
    "$SCRIPT_DIR/fm-procevent.sh" reconcile >/dev/null 2>&1 || true
    owner=$(await_source_owner "$sid")
    if [ "$owner" != live ]; then
      fail "source $sid is not listening after reconcile (observed owner: ${owner:-none})"
    fi
    printf 'listening: live\n'
  fi
}

# 0 when config/live-board's first non-blank line is exactly "on".
live_board_enabled() {
  local line
  line=$(grep -v '^[[:space:]]*$' "$CONFIG/live-board" 2>/dev/null | head -n1) || return 1
  [ "$line" = on ]
}

file_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# One JSON object per task id with the facts the snapshot does not project:
# the project's name from task metadata and the status log's mtime (epoch).
task_facts() {  # <snapshot.json>
  local id meta project since
  jq -r '[.in_flight[].id, .recorded_prs[].id] | unique | .[]' "$1" | while IFS= read -r id; do
    case "$id" in ''|*/*|.*) continue ;; esac
    meta="$STATE/$id.meta"
    project=$(grep '^project=' "$meta" 2>/dev/null | tail -n1 | cut -d= -f2-) || project=
    since=$(file_mtime "$STATE/$id.status") || since=
    [ -n "$since" ] || since=$(file_mtime "$meta") || since=
    jq -cn --arg id "$id" --arg project "${project%/}" --arg since "$since" \
      '{id: $id, repo: (if $project == "" then null else ($project | split("/") | last) end),
        since: (if $since == "" then null else ($since | tonumber) end)}'
  done
}

# shellcheck disable=SC2016 # jq program text, not shell expansion
COMPOSE_JQ='
  def repo_from_url:
    if type != "string" then null
    elif test("github\\.com/[^/]+/[^/]+/pull/") then capture("github\\.com/[^/]+/(?<r>[^/]+)/pull/").r
    elif test("/-/merge_requests/") then capture("/(?<r>[^/]+)/-/merge_requests/").r
    else null end;
  def iso: if . == null then null else (floor | todate) end;
  def or_dash: if type == "string" and length > 0 then . else "-" end;
  def title_from($id):
    (split(": ")[0] | gsub("^\\s+|\\s+$"; "")) as $head
    | if $head == "" then $id
      elif ($head | length) <= 110 then $head
      else ($head[0:107] + "...") end;
  $snap[0] as $s
  | ($cards[0].cards // []) as $stored
  | (INDEX($facts[]; .id)) as $f
  | ($s | .in_flight //= [] | .decisions_open //= [] | .landed //= [] | .gates //= [] | .recorded_prs //= []) as $s
  | ($s.in_flight | map(.id)) as $inflight
  | ($s.decisions_open | map(.id)) as $open
  | ($s.recorded_prs | map(.id) | map(select(. as $i | $inflight | index($i) != null))) as $pr_tasks
  | [ $stored[]
      | select(call_item)
      | select(
          if (.key | startswith("merge.")) then ((.key | ltrimstr("merge.")) as $t | $pr_tasks | index($t) != null)
          else (.key as $k | $open | index($k) != null) end) ] as $composed
  | ($composed | map(.key)) as $composed_keys
  | [ $s.decisions_open[]
      | select(.id | test("^[A-Za-z0-9._-]{1,128}$"))
      | select(.id as $k | $composed_keys | index($k) | not)
      | { key: .id, type: "decision", repo: ($f[.id].repo // null),
          title: (.id as $i | (.summary // "") | title_from($i)),
          about: (.summary // ""),
          detail: "Firstmate has not written this call up yet: this is the raw reason recorded with the hold. Answer in your own words; firstmate reads it and finishes the call.",
          options: [], allow_freeform: true, close: "release", raw: true,
          freeform_hint: "your answer, captain" } ] as $raw
  | {
      schema: $schema,
      home: $s.home,
      generated: $now,
      source: "live-refresh",
      prs_live: false,
      captains_call: ($composed + $raw),
      underway: [ $s.in_flight[]
        | { id: .id, name: ((.name | select(type == "string" and length > 0)) // .id),
            repo: ($f[.id].repo // (.repo | if type == "string" and length > 0 then split("/") | last else null end)),
            state: (.state | or_dash), doing: (.doing | or_dash),
            kind: (.kind | or_dash), since: ($f[.id].since | iso) } ],
      landed: [ $s.landed[]
        | { id: .id, repo: (.artifact | repo_from_url), what: (.what | if . == null or . == "" then "-" else . end),
            owner: (.owner | or_dash) }
          + (if (.artifact | is_https_url) then {pr_url: .artifact} else {} end) ],
      charted: (
        [ $s.gates[]
          | select(.id | test("^[A-Za-z0-9._-]{1,128}$"))
          | ((.blocked_by // "-") as $b | (.reason // "-") as $r
             | { id: .id, repo: null, title: (.title | if . == null or . == "" then "-" else . end),
                 reason: (if $b != "-" then "waiting on " + $b elif $r != "-" then $r else "" end),
                 dispatchable: ($b == "-" and $r == "-"),
                 filed: (.filed | if valid_filed then . else null end) }) ]
        + [ $s.gates[] | select(.id == "(main-inventory)" or .id == "(return-catchup)")
          | { id: (.id | ltrimstr("(") | rtrimstr(")")), repo: null, kind: "warning",
              title: (.title // "fleet records need attention"),
              reason: (if .id == "(main-inventory)" then "fleet records integrity warning" else "away-return catch-up" end),
              dispatchable: false, filed: null } ]
        + [ ($s.secondmates // [])[] | select(.state == "unknown" or .state == "externally_held")
          | select(.id | test("^[A-Za-z0-9._-]{1,128}$"))
          | { id: .id, repo: null, title: ("Second mate " + .id),
              reason: (.reason // .doing // .state // "state unavailable"), dispatchable: false }
            + (if .state == "unknown" then {kind: "warning"} else {} end) ]),
      charted_more: ([ $s.omitted[]?.surface | strings
        | capture("^gates showing (?<a>[0-9]+) of (?<b>[0-9]+)$")? | ((.b | tonumber) - (.a | tonumber)) ]
        | add // 0),
      prs: [ $s.recorded_prs[] | select(.url | is_https_url)
        | .id as $i | ($s.in_flight | map(select(.id == $i)) | first) as $t
        | { id: .id, repo: ((.url | repo_from_url) // ($f[.id].repo // null)), url: .url,
            state: ($t.state // "not in flight"), doing: ($t.doing // "") } ]
    }
    + (if $quota[0] == null then {} else {quota: $quota[0]} end)
'

command_refresh() {
  local board work snap_err now
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  live_board_enabled || { printf 'skipped: the live board is off (config/live-board)\n'; return 0; }
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  board=$(board_path)
  [ -f "$board" ] || { printf 'skipped: no board has been published yet; build it once with /bearings lavish\n'; return 0; }
  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-board.XXXXXX") || fail "cannot create a work directory"
  # shellcheck disable=SC2064 # expand now: the path is fixed for this run
  trap "rm -rf -- '$work'" EXIT

  snap_err="$work/snapshot.err"
  "$SCRIPT_DIR/fm-bearings-snapshot.sh" --unattended --json --all-decisions --all-in-flight --all-recorded-prs > "$work/snapshot.json" 2> "$snap_err" \
    || fail "the fleet snapshot failed: $(tail -n1 "$snap_err")"
  jq -e '.schema == "fm-bearings.v1"' "$work/snapshot.json" >/dev/null 2>&1 \
    || fail "the fleet snapshot is not readable"
  task_facts "$work/snapshot.json" > "$work/facts.jsonl" || fail "cannot read task facts"
  if ! "$SCRIPT_DIR/fm-bearings-quota.sh" > "$work/quota.json" 2>/dev/null \
      || ! jq -e "$BOARD_JQ_DEFS"' quota_section' "$work/quota.json" >/dev/null 2>&1; then
    printf 'null\n' > "$work/quota.json"
  fi
  if [ -f "$(cards_path)" ] && jq -e --arg schema "$CARDS_SCHEMA" '.schema == $schema and (.cards | type == "array")' \
      "$(cards_path)" >/dev/null 2>&1; then
    cp -- "$(cards_path)" "$work/cards.json"
  else
    printf '{"cards":[]}\n' > "$work/cards.json"
  fi

  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -n --arg schema "$BOARD_SCHEMA" --arg now "$now" \
    --slurpfile snap "$work/snapshot.json" --slurpfile cards "$work/cards.json" \
    --slurpfile facts "$work/facts.jsonl" --slurpfile quota "$work/quota.json" \
    "$BOARD_JQ_DEFS$COMPOSE_JQ" > "$work/payload.json" \
    || fail "cannot compose the live board payload"
  validate_payload "$work/payload.json" || fail "the composed live payload does not satisfy $BOARD_SCHEMA"
  effective_payload "$work/payload.json" "$work/effective.json" \
    || fail "cannot reconcile the live board payload against landed work"
  write_data_file "$work/effective.json" || fail "cannot write the live board data"
  printf 'refreshed: %s\n' "$(data_file_path)"
}

parse_interval() {  # <value>
  case "$1" in ''|*[!0-9]*) fail "--interval must be a whole number of seconds" ;; esac
  [ "$1" -ge "$MIN_INTERVAL" ] || fail "--interval must be at least $MIN_INTERVAL seconds"
  printf '%s\n' "$1"
}

command_loop() {
  local interval=$DEFAULT_INTERVAL
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --interval) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; interval=$(parse_interval "$2"); shift ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  while :; do
    ( command_refresh ) || printf 'fm-bearings-board: refresh failed; retrying in %ss\n' "$interval" >&2
    sleep "$interval"
  done
}

systemd_quoted() {  # <value>
  local v=$1
  v=${v//\\/\\\\}
  v=${v//\"/\\\"}
  v=${v//%/%%}
  printf '%s' "$v"
}

command_systemd_units() {
  local interval=$DEFAULT_INTERVAL dir="" name home script service timer home_unit path_unit script_unit
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --interval) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; interval=$(parse_interval "$2"); shift ;;
      --dir) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; dir=$2; shift ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  home=$(cd "$FM_HOME" && pwd -P) || fail "FM_HOME is not a directory: $FM_HOME"
  script="$SCRIPT_DIR/fm-bearings-board.sh"
  # These values sit inside systemd double quotes, where `\` and `"` are escapes
  # and `%` starts a specifier, so each is escaped.
  home_unit=$(systemd_quoted "$home")
  path_unit=$(systemd_quoted "$PATH")
  script_unit=$(systemd_quoted "$script")
  name="fm-live-board-$(printf '%s' "$home" | cksum | cut -d' ' -f1)"
  service=$(printf '[Unit]\nDescription=Firstmate live fleet board refresh for %s\n\n[Service]\nType=oneshot\nEnvironment="FM_HOME=%s"\nEnvironment="PATH=%s"\nExecStart="%s" refresh\nNice=10' \
    "$home_unit" "$home_unit" "$path_unit" "$script_unit")
  timer="[Unit]
Description=Refresh the Firstmate live fleet board for $home_unit every ${interval}s

[Timer]
OnActiveSec=15s
OnUnitInactiveSec=${interval}s
AccuracySec=5s

[Install]
WantedBy=timers.target"
  if [ -z "$dir" ]; then
    printf '# %s.service\n%s\n\n# %s.timer\n%s\n' "$name" "$service" "$name" "$timer"
    return 0
  fi
  mkdir -p "$dir" || fail "cannot create $dir"
  printf '%s\n' "$service" > "$dir/$name.service" || fail "cannot write $dir/$name.service"
  printf '%s\n' "$timer" > "$dir/$name.timer" || fail "cannot write $dir/$name.timer"
  printf 'wrote: %s\nwrote: %s\nunit: %s.timer\n' "$dir/$name.service" "$dir/$name.timer" "$name"
}

case "${1-}" in
  build) shift; command_build "$@" ;;
  refresh) shift; command_refresh "$@" ;;
  loop) shift; command_loop "$@" ;;
  systemd-units) shift; command_systemd_units "$@" ;;
  path) board_path ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
