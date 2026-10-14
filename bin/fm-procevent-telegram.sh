#!/usr/bin/env bash
# Telegram adapter for the generic process-to-event runner.
#
# Usage:
#   fm-procevent-telegram.sh poll [--home <dir>]
#   fm-procevent-telegram.sh classify <result-file>
#   fm-procevent-telegram.sh terminal <result-file>
#   fm-procevent-telegram.sh self-announcing
#   fm-procevent-telegram.sh autohandle <source-id> <sequence> <result-file>
#   fm-procevent-telegram.sh handle <source-id> <sequence> <result-file>
#
# poll        The registered listener command `bin/fm-telegram.sh arm`
#             publishes, not a command to run in a conversational turn. It
#             long-polls the Bot API getUpdates call, filters every update,
#             durably records each accepted message under
#             state/telegram/messages/, persists the next update offset, and
#             returns only once it has accepted at least one message or hit a
#             fatal error. Filtered rounds and transient failures loop inside
#             the poll, so they never reach the runner as results.
# classify    Print `messages`, `error`, or `unknown` for a captured result.
# terminal    Exit 0 only for an `error` result: a revoked token, a webhook or
#             another poller holding the bot, or a home that stopped opting in
#             will not heal on a restart, so the runner retires the source and
#             the one captured error wakes firstmate instead of a restart loop.
# self-announcing
#             Exit 0: every message autohandle surfaces becomes a captain-inbox
#             channel note, and that note appends its own durable `check` wake,
#             so a fully surfaced capture needs no second announcement.
# autohandle  The runner's entry after capture. For a `messages` result it
#             surfaces each listed record as an inbox note through
#             `bin/fm-inbox.sh channel-note` and then records the runner's
#             handled acknowledgement. Exit 0 only when every record surfaced.
# handle      The same idempotent step for a firstmate handler acting on a
#             `procevent telegram ...` wake the runner left unacknowledged.
#
# Durability, stated exactly. A message is recorded before the offset that
# confirms it to Telegram is persisted, and a record whose file already exists
# is never rewritten, so a crash anywhere in a round re-fetches rather than
# loses or doubles a record. A record carries a surfaced marker only after its
# inbox note exists, and the next poll re-offers any unsurfaced record before
# polling again (unless a captured result is still waiting to be handled, which
# the runner re-announces anyway), so a crash between recording and surfacing
# delays a note rather than dropping it. The inbox note id is derived from the
# chat and message ids, so surfacing twice never creates two notes.
# Telegram itself keeps unconfirmed updates for about 24 hours; a home that
# stays down longer than that can lose messages at the source.
#
# Filtering. Updates from a chat that is not in config/telegram.json's
# allowed_chats are dropped without any record, and the bot leaves any such
# group, supergroup, or channel. In a group only a message that mentions the
# bot, replies to the bot, or is a /command reaches the home. Messages from
# other bots, service messages, and unsupported update kinds are dropped.
# Every record marks whether its sender is the configured owner.
#
# AUTHORITY. A Telegram message is data, never captain authority: every record
# and note carries authority=data-only, and trust=untrusted unless the sender
# is the configured owner. Even the owner's messages carry no authority for
# merges, releases, production writes, credentials, or destructive actions.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"
# shellcheck source=bin/fm-telegram-lib.sh
. "$SCRIPT_DIR/fm-telegram-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
  exit 2
}

ALLOWED_UPDATES='["message","channel_post","my_chat_member"]'
CONFLICT_LIMIT=3
RETRY_DELAY_MAX=60

# ------------------------------------------------------------------ results

emit_messages() {  # <key>...
  printf 'telegram: messages\n'
  local key
  for key in "$@"; do printf 'record: %s\n' "$key"; done
}

# A fatal error result. The detail is one sanitized line and never the token.
emit_error() {  # <reason> <detail>
  local detail
  detail=$(printf '%s' "$2" | tr -d '\000-\037\177' | cut -c1-300)
  [ -z "$TG_TOKEN" ] || detail=${detail//"$TG_TOKEN"/[token]}
  printf 'telegram: error\nreason: %s\ndetail: %s\n' "$1" "$detail"
}

result_kind() {  # <result-file>
  local first
  first=$(head -n1 -- "$1" 2>/dev/null)
  case "$first" in
    'telegram: messages') printf 'messages\n' ;;
    'telegram: error') printf 'error\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

cmd_classify() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  result_kind "$file"
}

cmd_terminal() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  [ "$(result_kind "$file")" = error ]
}

# ------------------------------------------------------------------ poll

retry_delay() {
  local d=${FM_TELEGRAM_RETRY_DELAY:-5}
  case "$d" in ''|*[!0-9]*) d=5 ;; esac
  printf '%s\n' "$d"
}

read_offset() {
  local v
  v=$(cat -- "$TG_STATE/offset" 2>/dev/null) || v=0
  case "$v" in ''|*[!0-9]*) v=0 ;; esac
  printf '%s\n' "$v"
}

poll_timeout() {
  local t
  t=$(jq -r '.poll_timeout_seconds // 50' "$TG_CONFIG_FILE" 2>/dev/null)
  case "$t" in ''|*[!0-9]*) t=50 ;; esac
  printf '%s\n' "$t"
}

# Whether this source still has a captured result nobody acknowledged. The
# runner re-announces those itself, so re-offering their records would only
# produce a second capture of the same records.
source_has_unhandled_result() {  # <source-id>
  local result
  while IFS= read -r result; do
    [ -n "$result" ] || continue
    [ "$(fm_procevent_result_source_id "$result")" = "$1" ] && return 0
  done < <(fm_procevent_pending "$FM_HOME/state")
  return 1
}

unsurfaced_records() {
  local rec key
  for rec in "$TG_MESSAGES"/*.json; do
    [ -f "$rec" ] && [ ! -L "$rec" ] || continue
    key=${rec##*/}; key=${key%.json}
    fm_tg_record_key_valid "$key" || continue
    [ -e "$TG_MESSAGES/$key.surfaced" ] || printf '%s\n' "$key"
  done
}

# Cache getMe in state/telegram/bot.json. Returns 0 when the identity is
# known, 1 on a transient failure, 3 on an authorization failure (TG_FAIL_DETAIL).
ensure_bot_identity() {
  local cache="$TG_STATE/bot.json" body out code
  if [ -f "$cache" ] && jq -e --argjson id "$TG_BOT_ID" '.id == $id' "$cache" >/dev/null 2>&1; then
    BOT_USERNAME=$(jq -r '.username // ""' "$cache")
    return 0
  fi
  body="$WORK/getme.json"; out="$WORK/getme.out"
  printf '{}' > "$body"
  code=$(fm_tg_api getMe "$body" "$out" 20) || return 1
  case "$code" in
    200) ;;
    401|403|404) TG_FAIL_DETAIL=$(jq -r '.description // "unauthorized"' "$out" 2>/dev/null); return 3 ;;
    *) return 1 ;;
  esac
  jq -e --argjson id "$TG_BOT_ID" '.ok == true and .result.id == $id' "$out" >/dev/null 2>&1 || return 1
  jq -c '{id: .result.id, username: (.result.username // "" | if test("^[A-Za-z0-9_]{1,64}$") then . else "" end)}' "$out" \
    | fm_tg_write_atomic "$cache" || return 1
  BOT_USERNAME=$(jq -r '.username' "$cache")
}

# Turn one getUpdates response into decision lines, one compact JSON object per
# update: {update_id, action: accept|leave|drop, ...}. All filtering lives here.
decide_updates() {  # <response-file>
  jq -c \
    --argjson allowed "$(jq -c '.allowed_chats' "$TG_CONFIG_FILE")" \
    --argjson owner "$(jq -c '.owner_user_id' "$TG_CONFIG_FILE")" \
    --argjson bot "$TG_BOT_ID" \
    --arg user "$BOT_USERNAME" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    def allowed($id): any($allowed[]; . == $id);
    def joinable($type): $type == "group" or $type == "supergroup" or $type == "channel";
    def drop($u; $why): {update_id: $u.update_id, action: "drop", reason: $why};
    def leave($u; $chat): {update_id: $u.update_id, action: "leave", chat_id: $chat.id, chat_type: $chat.type};
    def content_kinds($m):
      ["photo","document","voice","audio","video","video_note","animation","sticker",
       "location","venue","contact","poll","dice"] | map(select($m[.] != null));
    def addressed($m; $chat):
      ($m.text // $m.caption // "") as $t
      | ($chat.type == "private")
        or (($user | length) > 0 and ($t | test("(^|[^A-Za-z0-9_])@" + $user + "($|[^A-Za-z0-9_])"; "i")))
        or ($t | test("^/[A-Za-z0-9_]+($|\\s)"))
        or (($user | length) > 0 and ($t | test("^/[A-Za-z0-9_]+@" + $user + "($|\\s)"; "i")))
        or (($m.reply_to_message.from.id // null) == $bot)
        or any(($m.entities // $m.caption_entities // [])[]; .type == "text_mention" and (.user.id // null) == $bot);
    def decide($u):
      if $u.message then
        $u.message as $m | $m.chat as $c
        | if (allowed($c.id) | not) then
            (if joinable($c.type) then leave($u; $c) else drop($u; "chat-not-allowed") end)
          elif $c.type == "channel" then drop($u; "channel")
          elif ($m.from.is_bot // false) then drop($u; "from-bot")
          elif (addressed($m; $c) | not) then drop($u; "not-addressed")
          else
            ($m.text // $m.caption // "") as $text
            | content_kinds($m) as $kinds
            | if $text == "" and ($kinds | length) == 0 then drop($u; "no-content")
              else
                (($m.from.id // null) == $owner) as $is_owner
                | {update_id: $u.update_id, action: "accept",
                   record: {
                     update_id: $u.update_id,
                     chat_id: $c.id,
                     chat_type: $c.type,
                     chat_title: ($c.title // null),
                     message_id: $m.message_id,
                     message_thread_id: ($m.message_thread_id // null),
                     date: ($m.date // null),
                     from_id: ($m.from.id // null),
                     from_username: ($m.from.username // null),
                     from_name: ([$m.from.first_name, $m.from.last_name] | map(select(. != null and . != "")) | join(" ")),
                     is_owner: $is_owner,
                     trust: (if $is_owner then "owner" else "untrusted" end),
                     authority: "data-only",
                     text: (if $text == "" then "(non-text message: " + ($kinds | join(", ")) + ")" else $text end),
                     content: $kinds,
                     reply_to_message_id: ($m.reply_to_message.message_id // null),
                     reply_to_bot: (($m.reply_to_message.from.id // null) == $bot),
                     received_at: $now
                   }}
              end
          end
      elif $u.channel_post then
        $u.channel_post.chat as $c
        | if allowed($c.id) then drop($u; "channel") else leave($u; $c) end
      elif $u.my_chat_member then
        $u.my_chat_member as $mm
        | if (allowed($mm.chat.id) | not) and joinable($mm.chat.type)
             and any(["member","administrator","restricted"][]; . == ($mm.new_chat_member.status // ""))
          then leave($u; $mm.chat) else drop($u; "membership") end
      else drop($u; "unsupported-update") end;
    # One malformed update is dropped on its own, so it can neither stall the
    # offset nor turn the poll into a tight re-fetch loop.
    .result[] as $u
    | try decide($u) catch {update_id: $u.update_id, action: "drop", reason: "unreadable"}
  ' "$1"
}

leave_chat() {  # <chat-id> <chat-type>
  local chat=$1 body="$WORK/leave.json" out="$WORK/leave.out" code outcome
  fm_tg_is_int "$chat" || return 0
  printf '{"chat_id":%s}' "$chat" > "$body"
  code=$(fm_tg_api leaveChat "$body" "$out" 20) || code=failed
  outcome=failed
  [ "$code" = 200 ] && outcome=left
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$chat" "$2" "$outcome" >> "$TG_STATE/left.log"
  chmod 0600 "$TG_STATE/left.log" 2>/dev/null || true
}

# Apply one response: record accepted messages, leave foreign chats, and only
# then persist the next offset. Prints the keys of records still to surface.
apply_updates() {  # <response-file>
  local line action key rec max=-1 id chat type
  local -a fresh=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    id=$(printf '%s' "$line" | jq -r '.update_id')
    case "$id" in ''|*[!0-9]*) continue ;; esac
    [ "$id" -gt "$max" ] && max=$id
    action=$(printf '%s' "$line" | jq -r '.action')
    case "$action" in
      accept)
        chat=$(printf '%s' "$line" | jq -r '.record.chat_id')
        key=$(fm_tg_record_key "$chat" "$(printf '%s' "$line" | jq -r '.record.message_id')")
        fm_tg_record_key_valid "$key" || continue
        rec="$TG_MESSAGES/$key.json"
        if [ ! -e "$rec" ]; then
          printf '%s' "$line" | jq -c '.record' | fm_tg_write_atomic "$rec" || return 1
        fi
        [ -e "$TG_MESSAGES/$key.surfaced" ] || fresh+=("$key")
        ;;
      leave)
        chat=$(printf '%s' "$line" | jq -r '.chat_id')
        type=$(printf '%s' "$line" | jq -r '.chat_type // ""' | tr -cd '[:lower:]')
        leave_chat "$chat" "$type"
        ;;
    esac
  done < <(decide_updates "$1")
  if [ "$max" -ge 0 ]; then
    printf '%s\n' "$((max + 1))" | fm_tg_write_atomic "$TG_STATE/offset" || return 1
  fi
  [ "${#fresh[@]}" -eq 0 ] || printf '%s\n' "${fresh[@]}"
}

cmd_poll() {
  if [ "${1-}" = --home ]; then
    [ -n "${2-}" ] || usage
    FM_HOME=$2
    shift 2
  fi
  [ "$#" -eq 0 ] || usage
  export FM_HOME
  fm_tg_init
  if ! fm_tg_optin; then
    emit_error not-configured "$TG_OPTIN_REASON"
    return 0
  fi
  local tool
  for tool in curl jq perl; do
    command -v "$tool" >/dev/null 2>&1 || { emit_error missing-tool "$tool is not installed"; return 0; }
  done
  fm_tg_private_dir "$TG_MESSAGES" || die "cannot create $TG_MESSAGES"
  WORK=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-telegram-poll.XXXXXX") || die "cannot create a work directory"
  # shellcheck disable=SC2064 # expand now, while WORK is set
  trap "rm -rf -- '$WORK'" EXIT
  local signal
  for signal in INT TERM HUP; do
    # shellcheck disable=SC2064
    trap "rm -rf -- '$WORK'; trap - $signal; kill -$signal \$\$" "$signal"
  done

  local sid pending
  sid=$(fm_tg_source_id)
  if ! source_has_unhandled_result "$sid"; then
    pending=$(unsurfaced_records)
    if [ -n "$pending" ]; then
      # shellcheck disable=SC2086 # keys are validated path-safe tokens
      emit_messages $pending
      return 0
    fi
  fi

  local rounds=0 max_rounds=${FM_TELEGRAM_POLL_ROUNDS:-0} conflicts=0 delay base_delay
  local body out code rc timeout fresh retry_after id_rc
  base_delay=$(retry_delay)
  delay=$base_delay
  case "$max_rounds" in ''|*[!0-9]*) max_rounds=0 ;; esac
  BOT_USERNAME=
  while :; do
    if [ "$max_rounds" -gt 0 ] && [ "$rounds" -ge "$max_rounds" ]; then
      return 1
    fi
    rounds=$((rounds + 1))
    if ! fm_tg_optin; then
      emit_error not-configured "$TG_OPTIN_REASON"
      return 0
    fi
    id_rc=0
    ensure_bot_identity || id_rc=$?
    case "$id_rc" in
      0) ;;
      3) emit_error unauthorized "${TG_FAIL_DETAIL:-unauthorized}"; return 0 ;;
      *) sleep "$delay"; delay=$(( delay * 2 > RETRY_DELAY_MAX ? RETRY_DELAY_MAX : delay * 2 )); continue ;;
    esac
    timeout=$(poll_timeout)
    body="$WORK/updates.json"; out="$WORK/updates.out"
    jq -cn --argjson offset "$(read_offset)" --argjson timeout "$timeout" \
      --argjson allowed "$ALLOWED_UPDATES" \
      '{offset: $offset, timeout: $timeout, allowed_updates: $allowed}' > "$body"
    rc=0
    code=$(fm_tg_api getUpdates "$body" "$out" "$((timeout + 15))") || rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$code" ]; then
      sleep "$delay"; delay=$(( delay * 2 > RETRY_DELAY_MAX ? RETRY_DELAY_MAX : delay * 2 )); continue
    fi
    case "$code" in
      200)
        if ! jq -e '.ok == true and (.result | type) == "array"' "$out" >/dev/null 2>&1; then
          sleep "$delay"; continue
        fi
        conflicts=0
        delay=$base_delay
        fresh=$(apply_updates "$out") || die "cannot persist Telegram updates under $TG_STATE"
        if [ -n "$fresh" ]; then
          # shellcheck disable=SC2086 # keys are validated path-safe tokens
          emit_messages $fresh
          return 0
        fi
        ;;
      401|403|404)
        emit_error unauthorized "$(jq -r '.description // "unauthorized"' "$out" 2>/dev/null)"
        return 0
        ;;
      409)
        conflicts=$((conflicts + 1))
        if [ "$conflicts" -ge "$CONFLICT_LIMIT" ]; then
          emit_error conflict "$(jq -r '.description // "conflict"' "$out" 2>/dev/null)"
          return 0
        fi
        sleep "$delay"
        ;;
      429)
        retry_after=$(jq -r '.parameters.retry_after // 5' "$out" 2>/dev/null)
        case "$retry_after" in ''|*[!0-9]*) retry_after=5 ;; esac
        [ "$retry_after" -le 300 ] || retry_after=300
        [ "$base_delay" -eq 0 ] && retry_after=0
        sleep "$retry_after"
        ;;
      *)
        sleep "$delay"; delay=$(( delay * 2 > RETRY_DELAY_MAX ? RETRY_DELAY_MAX : delay * 2 ))
        ;;
    esac
  done
}

# ------------------------------------------------------------------ surfacing

# Surface one record as an inbox channel note, at most once. The marker is
# written only after the note exists, and the note id is derived from the
# record key, so a retry after any crash lands on the same note.
surface_record() {  # <key>
  local key=$1 rec marker headers bodyf trust note rc=0
  fm_tg_record_key_valid "$key" || return 1
  rec="$TG_MESSAGES/$key.json"
  marker="$TG_MESSAGES/$key.surfaced"
  [ -e "$marker" ] && return 0
  [ -f "$rec" ] && [ ! -L "$rec" ] || return 1
  trust=$(jq -r 'if .trust == "owner" and .is_owner == true then "owner" else "untrusted" end' "$rec" 2>/dev/null) || return 1
  note=$(fm_tg_note_id "$key")
  headers=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-telegram-headers.XXXXXX") || return 1
  bodyf=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-telegram-body.XXXXXX") || { rm -f -- "$headers"; return 1; }
  jq -r --arg key "$key" '
    def clean: tostring | gsub("[[:cntrl:]]"; " ");
    def v: if . == null then "" else clean end;
    "telegram_chat=\(.chat_id | v)",
    "telegram_chat_type=\(.chat_type | v)",
    "telegram_chat_title=\(.chat_title | v)",
    "telegram_message=\(.message_id | v)",
    "telegram_from_id=\(.from_id | v)",
    "telegram_from_username=\(.from_username | v)",
    "telegram_from_name=\(.from_name | v)",
    "telegram_reply_to=\(.reply_to_message_id | v)",
    "telegram_record=state/telegram/messages/\($key).json",
    "reply_command=bin/fm-telegram.sh send --chat \(.chat_id | v) --reply-to \(.message_id | v) --file <path>"
  ' "$rec" > "$headers" 2>/dev/null || rc=1
  [ "$rc" -eq 0 ] && { jq -r '.text // ""' "$rec" > "$bodyf" 2>/dev/null || rc=1; }
  if [ "$rc" -eq 0 ]; then
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-inbox.sh" channel-note "$note" telegram "$trust" "$headers" \
      < "$bodyf" >/dev/null || rc=1
  fi
  rm -f -- "$headers" "$bodyf"
  [ "$rc" -eq 0 ] || return 1
  printf '%s\n' "$note" | fm_tg_write_atomic "$marker"
}

cmd_handle() {
  local sid=${1-} seq=${2-} result=${3-} key fail=0 out
  [ -n "$result" ] || usage
  case "$sid" in telegram-*) ;; *) die "not a telegram source: $sid" ;; esac
  fm_procevent_source_id_valid "$sid" || die "invalid source id: $sid"
  case "$seq" in ''|*[!0-9]*) die "invalid sequence: $seq" ;; esac
  [ -f "$result" ] && [ ! -L "$result" ] || die "result file does not exist: $result"
  [ "$(result_kind "$result")" = messages ] || return 1
  # The capture lives under <home>/state/procevent-inbox/, so the result itself
  # names the home whose records it lists, whatever FM_HOME the caller exported.
  case "$result" in
    */state/procevent-inbox/*) FM_HOME=$(cd "${result%/state/procevent-inbox/*}" && pwd) || return 1 ;;
  esac
  export FM_HOME
  fm_tg_init
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    surface_record "$key" || { printf 'cannot surface record %s\n' "$key" >&2; fail=1; }
  done < <(sed -n 's/^record: //p' "$result")
  [ "$fail" -eq 0 ] || return 1
  out=$("$SCRIPT_DIR/fm-procevent.sh" handled "$sid" "$seq") || return 1
  printf '%s\n' "$out"
  case "$out" in handled:*|already-handled:*) return 0 ;; esac
  return 1
}

case "${1-}" in
  poll)            shift; cmd_poll "$@" ;;
  classify)        shift; cmd_classify "$@" ;;
  terminal)        shift; cmd_terminal "$@" ;;
  self-announcing) exit 0 ;;
  autohandle|handle) shift; cmd_handle "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
