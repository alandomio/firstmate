# shellcheck shell=bash
# Shared rules for the opt-in Telegram channel: opt-in detection, the private
# token read, the config read, the one Bot API call path, and record naming.
# Usage: . bin/fm-telegram-lib.sh   (callers set FM_HOME first)
#
# Callers: bin/fm-telegram.sh (operator commands) and
# bin/fm-procevent-telegram.sh (the process-event adapter that long-polls).
# docs/telegram.md owns setup; docs/configuration.md owns the config schema.
#
# OPT-IN. The channel is inert unless BOTH hold:
#   - the home's gitignored .env carries a non-empty TELEGRAM_BOT_TOKEN, and
#   - the home's gitignored config/telegram.json is valid.
# The token is read only from that .env file, never from the ambient
# environment, so a variable exported in some shell cannot switch on a home
# that never opted in.
#
# TOKEN SECRECY. The token is never printed, logged, or written anywhere by
# this code. It reaches curl only through a config read on curl's stdin
# (`curl -K -`, fed by the printf builtin), so it is not in any process argv
# that `ps` can show, and it is not in the long-lived poller's argv either.
#
# Every function here returns non-zero rather than exiting, so the caller owns
# its own refusal wording.

FM_TELEGRAM_API_BASE_DEFAULT='https://api.telegram.org'

# The TG_* globals are this library's interface to its callers.
# shellcheck disable=SC2034
fm_tg_init() {
  TG_HOME=${FM_HOME:?FM_HOME must be set}
  TG_ENV_FILE="$TG_HOME/.env"
  TG_CONFIG_FILE="$TG_HOME/config/telegram.json"
  TG_STATE="$TG_HOME/state/telegram"
  TG_MESSAGES="$TG_STATE/messages"
  TG_API_BASE=${FM_TELEGRAM_API_BASE:-$FM_TELEGRAM_API_BASE_DEFAULT}
  TG_TOKEN=
  TG_BOT_ID=
  TG_CONFIG_ERROR=
}

# Read TELEGRAM_BOT_TOKEN from .env into TG_TOKEN: last assignment wins, an
# optional leading "export ", surrounding whitespace, and one layer of matching
# quotes are tolerated (the same reading Relay gives its own .env key).
# Returns 1 when absent or empty, 2 when present but not token-shaped. The shape
# check also guarantees the value cannot break out of the curl config line.
fm_tg_load_token() {
  local line val
  TG_TOKEN=
  TG_BOT_ID=
  [ -f "$TG_ENV_FILE" ] || return 1
  line=$(grep -E '^[[:space:]]*(export[[:space:]]+)?TELEGRAM_BOT_TOKEN=' "$TG_ENV_FILE" 2>/dev/null | tail -n1) || return 1
  [ -n "$line" ] || return 1
  val=${line#*=}
  val=${val#"${val%%[![:space:]]*}"}
  val=${val%"${val##*[![:space:]]}"}
  case "$val" in
    \"*\") val=${val#\"}; val=${val%\"} ;;
    \'*\') val=${val#\'}; val=${val%\'} ;;
  esac
  [ -n "$val" ] || return 1
  printf '%s' "$val" | grep -Eq '^[0-9]{1,20}:[A-Za-z0-9_-]{1,128}$' || return 2
  TG_TOKEN=$val
  TG_BOT_ID=${val%%:*}
}

# Validate config/telegram.json. On failure TG_CONFIG_ERROR names the problem.
fm_tg_load_config() {
  TG_CONFIG_ERROR=
  if [ ! -f "$TG_CONFIG_FILE" ]; then
    TG_CONFIG_ERROR="missing $TG_CONFIG_FILE"
    return 1
  fi
  command -v jq >/dev/null 2>&1 || { TG_CONFIG_ERROR="jq is not installed"; return 1; }
  local err
  err=$(jq -r '
    def int: type == "number" and . == floor;
    if type != "object" then "the file must hold one JSON object"
    elif (.allowed_chats | type) != "array" or (.allowed_chats | length) == 0 then "allowed_chats must be a non-empty array of chat ids"
    elif any(.allowed_chats[]; (int | not)) then "every allowed_chats entry must be an integer chat id"
    elif (.owner_user_id | int | not) or .owner_user_id <= 0 then "owner_user_id must be a positive integer Telegram user id"
    elif has("poll_timeout_seconds") and ((.poll_timeout_seconds | int | not) or .poll_timeout_seconds < 1 or .poll_timeout_seconds > 50) then "poll_timeout_seconds must be an integer from 1 to 50"
    else "" end' "$TG_CONFIG_FILE" 2>/dev/null) || { TG_CONFIG_ERROR="$TG_CONFIG_FILE is not valid JSON"; return 1; }
  if [ -n "$err" ]; then
    TG_CONFIG_ERROR="$TG_CONFIG_FILE: $err"
    return 1
  fi
}

# 0 when the home has opted in and both halves are usable; TG_OPTIN_REASON
# carries a token-free explanation either way.
# shellcheck disable=SC2034
fm_tg_optin() {
  local rc=0
  fm_tg_load_token || rc=$?
  case "$rc" in
    0) ;;
    1) TG_OPTIN_REASON="off: no TELEGRAM_BOT_TOKEN in $TG_ENV_FILE"; return 1 ;;
    *) TG_OPTIN_REASON="invalid: TELEGRAM_BOT_TOKEN in $TG_ENV_FILE is not shaped like a bot token"; return 1 ;;
  esac
  if ! fm_tg_load_config; then
    case "$TG_CONFIG_ERROR" in
      missing*) TG_OPTIN_REASON="off: $TG_CONFIG_ERROR" ;;
      *) TG_OPTIN_REASON="invalid: $TG_CONFIG_ERROR" ;;
    esac
    return 1
  fi
  TG_OPTIN_REASON="on: bot $TG_BOT_ID"
}

# The process-event source id. The bot id is the public half of the token, so
# two homes on one machine using two bots never share an owner, while two homes
# using one bot share one poller - which is also all Telegram allows.
fm_tg_source_id() { printf 'telegram-%s\n' "$TG_BOT_ID"; }

fm_tg_chat_allowed() {  # <chat-id>
  jq -e --argjson chat "$1" 'any(.allowed_chats[]; . == $chat)' "$TG_CONFIG_FILE" >/dev/null 2>&1
}

fm_tg_is_int() {
  case "${1-}" in
    ''|-|*[!0-9-]*|?*-*) return 1 ;;
  esac
  return 0
}

fm_tg_private_dir() {  # <dir>
  (umask 077; mkdir -p "$1") || return 1
  chmod 0700 "$1" 2>/dev/null || true
}

# Atomic private write of stdin to <path>.
fm_tg_write_atomic() {  # <path>
  local dest=$1 tmp
  tmp=$(umask 077; mktemp "${dest%/*}/.tg-write.XXXXXX") || return 1
  if ! cat > "$tmp"; then rm -f -- "$tmp"; return 1; fi
  chmod 0600 "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$dest" || { rm -f -- "$tmp"; return 1; }
}

# One Bot API call. The JSON body is read from <body-file>; the response body
# is written to <out-file>; the HTTP status is printed. Returns curl's own
# failure as non-zero with nothing printed. The URL, which embeds the token,
# reaches curl only on stdin.
fm_tg_api() {  # <method> <body-file> <out-file> <max-seconds>
  local method=$1 body=$2 out=$3 max=$4
  case "$method" in ''|*[!A-Za-z]*) return 2 ;; esac
  [ -n "$TG_TOKEN" ] || return 2
  printf 'url = "%s/bot%s/%s"\n' "$TG_API_BASE" "$TG_TOKEN" "$method" \
    | curl -sS -m "$max" -o "$out" -w '%{http_code}' \
        -H 'Content-Type: application/json' \
        --data-binary "@$body" -K - 2>/dev/null
}

# Telegram chat ids are signed integers; a record key must be path-safe.
fm_tg_record_key() {  # <chat-id> <message-id>
  local chat=$1
  case "$chat" in -*) chat="n${chat#-}" ;; esac
  printf '%s-%s\n' "$chat" "$2"
}

fm_tg_record_key_valid() {
  printf '%s' "${1-}" | grep -Eq '^n?[0-9]{1,20}-[0-9]{1,20}$'
}

fm_tg_note_id() { printf 'tg-%s\n' "$1"; }
