#!/usr/bin/env bash
# fm-telegram.sh - operator commands for a home's opt-in Telegram channel.
#
# Usage:
#   fm-telegram.sh status
#   fm-telegram.sh arm
#   fm-telegram.sh retire
#   fm-telegram.sh send --chat <chat-id> [--reply-to <message-id>]
#                       [--parse-mode MarkdownV2|HTML|Markdown] --file <path|->
#   fm-telegram.sh list
#   fm-telegram.sh discover
#
# status   Report whether this home opted in, why not, and whether the inbound
#          source is armed. Makes no network call and never prints the token.
# arm      Register the inbound long-poll source with the process-event runner
#          (bin/fm-procevent.sh); the watcher's ordinary cycle starts and
#          restarts it. Refuses unless the home opted in.
# retire   Retire every Telegram source this home registered. Works even after
#          the token was removed.
# send     Send text from a file (or stdin with -) to one allowlisted chat.
#          Plain text unless --parse-mode asks otherwise, so Markdown or HTML
#          in the text is never interpreted by surprise. Text longer than one
#          Telegram message is split on line or word boundaries; only the first
#          part replies to --reply-to. Every send, including a partial failure,
#          is recorded under state/telegram/sent/.
# list     Show recorded inbound messages, newest first, with their trust and
#          whether they already reached the inbox.
# discover Setup aid: print the chat ids, chat types, and sender user ids of
#          the updates Telegram is holding for the bot, without confirming
#          them, so the allowlist and owner id can be written before the
#          channel is armed. Needs only the .env token, and refuses while the
#          inbound source is armed, because that poller consumes the same
#          updates and Telegram allows one reader at a time.
#
# Inbound handling is owned by bin/fm-procevent-telegram.sh; each accepted
# message reaches firstmate as a captain-inbox channel note
# (bin/fm-inbox.sh channel-note) and is acknowledged with
# `bin/fm-inbox.sh drain --ack <note-id>`. docs/telegram.md owns setup and
# docs/configuration.md owns config/telegram.json.
#
# AUTHORITY. This channel is a data plane only. A Telegram message is never
# captain authority for merges, releases, production writes, credentials, or
# destructive actions - not even one from the configured owner.
#
# Environment:
#   FM_HOME                         operational home (default: this checkout)
#   FM_TELEGRAM_API_BASE            Bot API base URL (tests point it elsewhere)
#   FM_TELEGRAM_MAX_MESSAGE_UNITS   split size in UTF-16 units (default 4096)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_HOME=$(cd "$FM_HOME" 2>/dev/null && pwd) || { printf 'fm-telegram: FM_HOME does not exist\n' >&2; exit 1; }
export FM_HOME

# shellcheck source=bin/fm-telegram-lib.sh
. "$SCRIPT_DIR/fm-telegram-lib.sh"

die() { printf 'fm-telegram: %s\n' "$1" >&2; exit 1; }
usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
  exit 2
}

fm_tg_init

require_optin() {
  fm_tg_optin || die "$TG_OPTIN_REASON (see docs/telegram.md)"
}

registered_sources() {
  local f id
  for f in "$FM_HOME/state/procevent"/telegram-*.source; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    grep -qx 'adapter=telegram' "$f" 2>/dev/null || continue
    id=${f##*/}; id=${id%.source}
    printf '%s\n' "$id"
  done
}

cmd_status() {
  local sid armed pending=0 rec key
  if fm_tg_optin; then
    sid=$(fm_tg_source_id)
    armed="not armed (run: bin/fm-telegram.sh arm)"
    [ -f "$FM_HOME/state/procevent/$sid.source" ] && armed="armed as $sid"
    for rec in "$TG_MESSAGES"/*.json; do
      [ -f "$rec" ] || continue
      key=${rec##*/}; key=${key%.json}
      [ -e "$TG_MESSAGES/$key.surfaced" ] || pending=$((pending + 1))
    done
    printf 'telegram: %s\n' "$TG_OPTIN_REASON"
    printf 'allowed chats: %s\n' "$(jq -r '.allowed_chats | length' "$TG_CONFIG_FILE")"
    printf 'inbound: %s\n' "$armed"
    printf 'records not yet in the inbox: %s\n' "$pending"
    if [ -s "$TG_STATE/bot.json" ]; then
      printf 'bot username: @%s\n' "$(jq -r '.username // "?"' "$TG_STATE/bot.json")"
    fi
  else
    printf 'telegram: %s\n' "$TG_OPTIN_REASON"
    sid=$(registered_sources | head -1)
    [ -z "$sid" ] || printf 'inbound: %s is still registered (run: bin/fm-telegram.sh retire)\n' "$sid"
  fi
}

cmd_arm() {
  [ "$#" -eq 0 ] || usage
  require_optin
  local tool
  for tool in curl jq perl; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed"
  done
  "$SCRIPT_DIR/fm-procevent.sh" register telegram "$(fm_tg_source_id)" \
    -- "$SCRIPT_DIR/fm-procevent-telegram.sh" poll --home "$FM_HOME" || exit 1
  printf 'armed: %s\n' "$(fm_tg_source_id)"
}

cmd_retire() {
  [ "$#" -eq 0 ] || usage
  local sid any=0
  while IFS= read -r sid; do
    [ -n "$sid" ] || continue
    any=1
    "$SCRIPT_DIR/fm-procevent.sh" retire "$sid" || exit 1
  done < <(registered_sources)
  [ "$any" -eq 1 ] || printf 'no telegram source is registered\n'
}

# Split stdin text into part files under <dir> (part.1, part.2, ...), each at
# most <units> UTF-16 code units, which is how Telegram counts message length.
# Prefers the last newline, then the last space, inside each window.
split_text() {  # <dir> <units>
  perl -CS -e '
    use strict; use warnings;
    my ($dir, $max) = @ARGV;
    local $/; my $text = <STDIN>; $text = "" unless defined $text;
    $text =~ s/\s+\z//;
    my @parts;
    while (length $text) {
      my ($units, $cut) = (0, 0);
      for my $i (0 .. length($text) - 1) {
        my $u = ord(substr($text, $i, 1)) > 0xFFFF ? 2 : 1;
        last if $units + $u > $max;
        $units += $u; $cut = $i + 1;
      }
      if ($cut < length $text) {
        my $window = substr($text, 0, $cut);
        my $nl = rindex($window, "\n");
        my $sp = rindex($window, " ");
        if ($nl > 0) { $cut = $nl + 1 } elsif ($sp > 0) { $cut = $sp + 1 }
      }
      my $part = substr($text, 0, $cut, "");
      $part =~ s/\s+\z//;
      $text =~ s/\A\s+//;
      push @parts, $part if length $part;
    }
    my $n = 0;
    for my $p (@parts) {
      $n++;
      open my $fh, ">", "$dir/part.$n" or exit 2;
      print $fh $p; close $fh or exit 2;
    }
    print "$n\n";
  ' "$1" "$2"
}

record_send() {  # <chat> <reply-to> <parse-mode> <parts> <ok> <text-file> <ids...>
  local chat=$1 reply=$2 mode=$3 parts=$4 ok=$5 textf=$6 dir="$TG_STATE/sent" dest
  shift 6
  fm_tg_private_dir "$dir" || return 1
  dest="$dir/$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM.json"
  jq -cn --argjson chat "$chat" --arg reply "$reply" --arg mode "$mode" \
    --argjson parts "$parts" --argjson ok "$ok" --rawfile text "$textf" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --args \
    '{at: $at, chat_id: $chat,
      reply_to: (if $reply == "" then null else ($reply | tonumber) end),
      parse_mode: (if $mode == "" then null else $mode end),
      parts: $parts, delivered: ($ARGS.positional | length),
      message_ids: ($ARGS.positional | map(tonumber)), ok: $ok, text: $text}' \
    "$@" | fm_tg_write_atomic "$dest"
}

cmd_send() {
  local chat='' reply='' mode='' file=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --chat) chat=${2-}; shift 2 || usage ;;
      --reply-to) reply=${2-}; shift 2 || usage ;;
      --parse-mode) mode=${2-}; shift 2 || usage ;;
      --file) file=${2-}; shift 2 || usage ;;
      *) usage ;;
    esac
  done
  [ -n "$chat" ] && [ -n "$file" ] || usage
  require_optin
  fm_tg_is_int "$chat" || die "--chat must be a numeric chat id: $chat"
  fm_tg_chat_allowed "$chat" || die "chat $chat is not in allowed_chats in $TG_CONFIG_FILE; refusing to send"
  if [ -n "$reply" ]; then
    case "$reply" in *[!0-9]*|0) die "--reply-to must be a positive message id: $reply" ;; esac
  fi
  case "$mode" in ''|MarkdownV2|HTML|Markdown) ;; *) die "--parse-mode must be MarkdownV2, HTML, or Markdown" ;; esac
  command -v curl >/dev/null 2>&1 || die "curl is not installed"

  local work units n textf i code out body ok=true attempt retry_after desc
  local -a ids=()
  work=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-telegram-send.XXXXXX") || die "cannot create a work directory"
  # shellcheck disable=SC2064 # expand now, while work is set
  trap "rm -rf -- '$work'" EXIT
  textf="$work/text"
  if [ "$file" = - ]; then
    cat > "$textf"
  else
    [ -f "$file" ] && [ -r "$file" ] || die "cannot read $file"
    cat -- "$file" > "$textf"
  fi
  grep -q '[^[:space:]]' "$textf" || die "refusing to send empty text"
  units=${FM_TELEGRAM_MAX_MESSAGE_UNITS:-4096}
  case "$units" in ''|*[!0-9]*) die "FM_TELEGRAM_MAX_MESSAGE_UNITS must be a positive integer" ;; esac
  [ "$units" -ge 1 ] && [ "$units" -le 4096 ] || die "FM_TELEGRAM_MAX_MESSAGE_UNITS must be from 1 to 4096"
  n=$(split_text "$work" "$units" < "$textf") || die "cannot split the text"
  [ "$n" -ge 1 ] || die "refusing to send empty text"

  for i in $(seq 1 "$n"); do
    body="$work/body.$i"; out="$work/out.$i"
    jq -cn --argjson chat "$chat" --rawfile text "$work/part.$i" \
      --arg reply "$( [ "$i" -eq 1 ] && printf '%s' "$reply" )" --arg mode "$mode" \
      '{chat_id: $chat, text: $text}
       + (if $reply == "" then {} else {reply_parameters: {message_id: ($reply | tonumber), allow_sending_without_reply: true}} end)
       + (if $mode == "" then {} else {parse_mode: $mode} end)' > "$body"
    attempt=0
    while :; do
      attempt=$((attempt + 1))
      code=$(fm_tg_api sendMessage "$body" "$out" 30) || code=
      if [ "$code" = 429 ] && [ "$attempt" -lt 3 ]; then
        retry_after=$(jq -r '.parameters.retry_after // 5' "$out" 2>/dev/null)
        case "$retry_after" in ''|*[!0-9]*) retry_after=5 ;; esac
        [ "$retry_after" -le 60 ] || retry_after=60
        sleep "$retry_after"
        continue
      fi
      break
    done
    if [ "$code" = 200 ] && jq -e '.ok == true' "$out" >/dev/null 2>&1; then
      ids+=("$(jq -r '.result.message_id' "$out")")
    else
      ok=false
      desc=$(jq -r '.description // empty' "$out" 2>/dev/null | tr -d '\000-\037\177' | cut -c1-200)
      break
    fi
  done
  record_send "$chat" "$reply" "$mode" "$n" "$ok" "$textf" ${ids[@]+"${ids[@]}"} \
    || printf 'fm-telegram: warning: could not record the send under %s/sent\n' "$TG_STATE" >&2
  if [ "$ok" = true ]; then
    printf 'sent: chat %s, %s part(s), message ids %s\n' "$chat" "$n" "${ids[*]}"
    return 0
  fi
  die "send failed after ${#ids[@]} of $n part(s) (HTTP ${code:-none}${desc:+: $desc})"
}

cmd_list() {
  [ "$#" -eq 0 ] || usage
  local rec key any=0 state
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    key=${rec##*/}; key=${key%.json}
    fm_tg_record_key_valid "$key" || continue
    any=1
    state=pending
    [ -e "$TG_MESSAGES/$key.surfaced" ] && state="in inbox as $(cat -- "$TG_MESSAGES/$key.surfaced")"
    jq -r --arg key "$key" --arg state "$state" '
      def clean: tostring | gsub("[[:cntrl:]]"; " ");
      "\($key)  chat \(.chat_id)  from \(.from_username // .from_id | clean)  \(.trust)  \($state)\n    \(.text | clean | .[0:160])"
    ' "$rec" 2>/dev/null
  done < <(ls -t "$TG_MESSAGES"/*.json 2>/dev/null)
  [ "$any" -eq 1 ] || printf '(no Telegram messages recorded)\n'
}

cmd_discover() {
  [ "$#" -eq 0 ] || usage
  local rc=0 work code
  fm_tg_load_token || rc=$?
  case "$rc" in
    0) ;;
    1) die "no TELEGRAM_BOT_TOKEN in $TG_ENV_FILE (see docs/telegram.md)" ;;
    *) die "TELEGRAM_BOT_TOKEN in $TG_ENV_FILE is not shaped like a bot token" ;;
  esac
  [ -z "$(registered_sources)" ] || die "the inbound source is armed and consumes these updates; run bin/fm-telegram.sh retire first"
  command -v curl >/dev/null 2>&1 || die "curl is not installed"
  work=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-telegram-discover.XXXXXX") || die "cannot create a work directory"
  # shellcheck disable=SC2064 # expand now, while work is set
  trap "rm -rf -- '$work'" EXIT
  # No offset: Telegram returns the earliest unconfirmed updates and confirms none.
  printf '{"timeout":0,"allowed_updates":["message","channel_post","my_chat_member"]}' > "$work/body"
  code=$(fm_tg_api getUpdates "$work/body" "$work/out" 20) || die "cannot reach the Bot API"
  [ "$code" = 200 ] || die "the Bot API answered HTTP $code: $(jq -r '.description // empty' "$work/out" 2>/dev/null | tr -d '\000-\037\177' | cut -c1-200)"
  jq -r '
    def clean: tostring | gsub("[[:cntrl:]]"; " ");
    .result[] | (.message // .channel_post // .my_chat_member) | select(. != null)
    | "chat \(.chat.id)  \(.chat.type)  \(.chat.title // .chat.username // "-" | clean)  from \(.from.id // "-")  @\(.from.username // "-" | clean)"
  ' "$work/out" | sort -u
  printf 'Write the chat ids into allowed_chats and your own user id into owner_user_id in %s.\n' "$TG_CONFIG_FILE"
}

case "${1-}" in
  status) shift; cmd_status "$@" ;;
  arm)    shift; cmd_arm "$@" ;;
  retire) shift; cmd_retire "$@" ;;
  send)   shift; cmd_send "$@" ;;
  list)   shift; cmd_list "$@" ;;
  discover) shift; cmd_discover "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1 (try --help)" ;;
esac
