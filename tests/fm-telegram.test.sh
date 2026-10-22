#!/usr/bin/env bash
# Behavior tests for the opt-in Telegram channel: bin/fm-telegram.sh (operator
# commands), bin/fm-procevent-telegram.sh (the process-event adapter that
# long-polls), and the channel-note entry it uses in bin/fm-inbox.sh.
#
# The Bot API is stubbed with a fakebin `curl` that reads its URL from the
# `-K -` config on stdin exactly as the real client is fed, serves queued or
# default responses per Bot API method, and logs every call, so nothing here
# touches the network. jq and perl stay the real tools. The inbound path is
# driven both directly and through the real process-event runner, so capture,
# self-announcement, and terminal retirement are exercised end to end.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-telegram-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
export FM_TELEGRAM_RETRY_DELAY=0
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE TELEGRAM_BOT_TOKEN FM_TELEGRAM_API_BASE FM_TELEGRAM_POLL_ROUNDS FM_TELEGRAM_MAX_MESSAGE_UNITS

TOKEN='123456789:AAEexampleSECRETtokenValue_-xyz'
BOT=123456789
SID="telegram-$BOT"
GROUP=-1001111
OWNER=42

HOMES=()
telegram_teardown() {
  local home
  for home in ${HOMES[@]+"${HOMES[@]}"}; do
    FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  done
  fm_test_cleanup
}
trap telegram_teardown EXIT

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
out="" body="" cfg=0 argv="$*"
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -w|-m|-H) shift 2 ;;
    --data-binary) body=${2#@}; shift 2 ;;
    -K) [ "$2" = - ] && cfg=1; shift 2 ;;
    *) shift ;;
  esac
done
url=""
[ "$cfg" = 1 ] && url=$(sed -n 's/^url = "\(.*\)"$/\1/p')
method=${url##*/}
dir=$FAKE_TG_DIR
printf '%s\n' "$argv" >> "$dir/argv.log"
printf '%s\n' "$url" >> "$dir/urls.log"
printf '%s\t%s\n' "$method" "$(tr -d '\n' < "$body" 2>/dev/null)" >> "$dir/calls.log"
q=$(ls "$dir/queue/$method".* 2>/dev/null | sort | head -1)
if [ -n "$q" ]; then
  code=$(head -n1 "$q")
  tail -n +2 "$q" > "$out"
  rm -f "$q"
else
  code=200
  case "$method" in
    getMe) printf '{"ok":true,"result":{"id":123456789,"is_bot":true,"username":"test_bot"}}' > "$out" ;;
    getUpdates) printf '{"ok":true,"result":[]}' > "$out" ;;
    sendMessage)
      n=$(cat "$dir/msgid" 2>/dev/null || echo 500); n=$((n + 1)); echo "$n" > "$dir/msgid"
      printf '{"ok":true,"result":{"message_id":%s}}' "$n" > "$out" ;;
    leaveChat) printf '{"ok":true,"result":true}' > "$out" ;;
    getFile) printf '{"ok":true,"result":{"file_id":"x","file_path":"voice/file_1.oga"}}' > "$out" ;;
    file_1.oga) printf 'OGGDATA' > "$out" ;;
    *) code=404; printf '{"ok":false,"description":"Not Found"}' > "$out" ;;
  esac
fi
printf '%s' "$code"
SH
chmod +x "$FAKEBIN/curl"
# A fake ssh: logs the host and remote command, counts the audio bytes piped to
# it, and behaves per FAKE_SSH_MODE (ok, fail, hang, empty).
cat > "$FAKEBIN/ssh" <<'SH'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) break ;; esac
done
bytes=$(wc -c | tr -d ' ')
printf '%s\t%s\t%s\n' "$1" "$2" "$bytes" >> "$FAKE_TG_DIR/ssh.log"
case "${FAKE_SSH_MODE:-ok}" in
  ok) printf 'ciao  capitano\nprova di trascrizione\n' ;;
  urgent) printf 'Urgente, accendi il comodino\n' ;;
  empty) : ;;
  hang) sleep 30 ;;
  *) echo "ssh: connect to host $1 port 22: Connection refused" >&2; exit 255 ;;
esac
SH
chmod +x "$FAKEBIN/ssh"
export PATH="$FAKEBIN:$PATH"

new_home() {  # <name> [optin]: print a fresh home; optin writes .env and config
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/fake/queue"
  HOMES+=("$home")
  if [ "${2-}" = optin ]; then
    printf 'OTHER=1\nTELEGRAM_BOT_TOKEN="%s"\n' "$TOKEN" > "$home/.env"
    printf '{"allowed_chats":[%s,%s],"owner_user_id":%s}\n' "$GROUP" "$OWNER" "$OWNER" > "$home/config/telegram.json"
  fi
  printf '%s\n' "$home"
}

enqueue() {  # <home> <method> <code> <body>
  local n
  n=$(find "$1/fake/queue" -type f | wc -l | tr -d ' ')
  printf '%s\n%s' "$3" "$4" > "$1/fake/queue/$2.$(printf '%03d' "$n")"
}

tg()   { FM_HOME="$1" FAKE_TG_DIR="$1/fake" "$ROOT/bin/fm-telegram.sh" "${@:2}"; }
ad()   { FM_HOME="$1" FAKE_TG_DIR="$1/fake" "$ROOT/bin/fm-procevent-telegram.sh" "${@:2}"; }
pe()   { FM_HOME="$1" FAKE_TG_DIR="$1/fake" "$ROOT/bin/fm-procevent.sh" "${@:2}"; }
inbox() { FM_HOME="$1" "$ROOT/bin/fm-inbox.sh" "${@:2}"; }
calls() {  # <home> <method>: number of Bot API calls to <method>
  [ -f "$1/fake/calls.log" ] || { printf '0\n'; return 0; }
  grep -c "^$2"$'\t' "$1/fake/calls.log" || true
}

msg() {  # <update-id> <chat-id> <chat-type> <from-id> <text> [extra-message-json]
  printf '{"update_id":%s,"message":{"message_id":%s,"date":1,"chat":{"id":%s,"type":"%s","title":"t"},"from":{"id":%s,"is_bot":false,"first_name":"F","username":"u%s"},"text":%s%s}}' \
    "$1" "$(( $1 + 1000 ))" "$2" "$3" "$4" "$4" "$(jq -Rn --arg t "$5" '$t')" "${6:+,$6}"
}

# ---------------------------------------------------------------------------

test_inert_without_optin() {
  local home out rc
  home=$(new_home inert)
  out=$(TELEGRAM_BOT_TOKEN=$TOKEN tg "$home" status)
  assert_contains "$out" "off: no TELEGRAM_BOT_TOKEN" "an ambient token must not opt a home in"
  rc=0; out=$(tg "$home" arm 2>&1) || rc=$?
  expect_code 1 "$rc" "arm without opt-in"
  printf 'hi\n' > "$home/msg.txt"
  rc=0; tg "$home" send --chat "$GROUP" --file "$home/msg.txt" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "send without opt-in"
  out=$(ad "$home" poll)
  assert_contains "$out" "telegram: error" "an unconfigured poll reports a terminal error"
  assert_contains "$out" "reason: not-configured" "the error names the missing opt-in"
  printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TOKEN" > "$home/.env"
  out=$(tg "$home" status)
  assert_contains "$out" "off: missing" "a token alone is not an opt-in"
  printf '{"allowed_chats":[],"owner_user_id":1}' > "$home/config/telegram.json"
  out=$(tg "$home" status)
  assert_contains "$out" "invalid:" "an empty allowlist is refused"
  assert_not_contains "$out" "$TOKEN" "status never prints the token"
  assert_absent "$home/state/telegram" "an inert home creates no Telegram state"
  assert_absent "$home/fake/calls.log" "an inert home makes no Bot API call"
  pass "channel is inert without both the .env token and a valid config"
}

test_poll_filters_records_and_leaves() {
  local home out batch line
  home=$(new_home filter optin)
  batch=$(printf '%s,' \
    "$(msg 100 "$GROUP" supergroup "$OWNER" '@test_bot ciao')" \
    "$(msg 101 "$GROUP" supergroup 55 'random chatter')" \
    "$(msg 102 "$GROUP" supergroup 55 'thanks' '"reply_to_message":{"message_id":7,"from":{"id":123456789,"is_bot":true}}')" \
    "$(msg 103 "$GROUP" supergroup 55 '/status')" \
    "$(msg 104 "$GROUP" supergroup 55 '/status@otherbot')" \
    "$(msg 105 77 private 77 'hi')" \
    "$(msg 106 -1009999 group 55 '@test_bot hi')" \
    '{"update_id":107,"my_chat_member":{"chat":{"id":-1008888,"type":"supergroup"},"new_chat_member":{"status":"member","user":{"id":123456789}}}}' \
    "$(msg 109 "$OWNER" private "$OWNER" '**bold** please')" \
    '{"update_id":110,"message":{"message_id":9,"chat":"malformed"}}')
  line=$(msg 108 "$GROUP" supergroup 66 '@test_bot spam')
  line=${line/\"is_bot\":false/\"is_bot\":true}
  enqueue "$home" getUpdates 200 "{\"ok\":true,\"result\":[${batch}${line}]}"
  out=$(ad "$home" poll)
  assert_contains "$out" "telegram: messages" "accepted messages end the poll as a result"
  for k in n1001111-1100 n1001111-1102 n1001111-1103 42-1109; do
    assert_contains "$out" "record: $k" "accepted record $k is reported"
    assert_present "$home/state/telegram/messages/$k.json" "record $k is persisted"
  done
  [ "$(printf '%s\n' "$out" | grep -c '^record:')" -eq 4 ] || fail "exactly four messages pass the filter: $out"
  [ "$(cat "$home/state/telegram/offset")" = 111 ] || fail "the next offset passes the whole batch, a malformed update included"
  [ "$(jq -r .trust "$home/state/telegram/messages/n1001111-1100.json")" = owner ] || fail "the owner is marked"
  [ "$(jq -r .trust "$home/state/telegram/messages/n1001111-1102.json")" = untrusted ] || fail "others are untrusted"
  [ "$(jq -r .authority "$home/state/telegram/messages/42-1109.json")" = data-only ] || fail "even the owner's record is data only"
  [ "$(jq -r .reply_to_bot "$home/state/telegram/messages/n1001111-1102.json")" = true ] || fail "a reply to the bot is marked"
  [ "$(jq -r .text "$home/state/telegram/messages/42-1109.json")" = '**bold** please' ] || fail "text is recorded verbatim"
  grep -q 'leaveChat.*-1009999' "$home/fake/calls.log" || fail "the bot leaves a foreign group that messages it"
  grep -q 'leaveChat.*-1008888' "$home/fake/calls.log" || fail "the bot leaves a foreign group it is added to"
  [ "$(calls "$home" leaveChat)" = 2 ] || fail "a foreign private chat is dropped without a leave call"
  ! grep -rq '"chat_id":77' "$home/state/telegram/messages" || fail "a foreign private chat leaves no record"
  ! grep -q "$TOKEN" "$home/fake/argv.log" || fail "the token never appears in curl argv"
  grep -q "/bot$TOKEN/getUpdates" "$home/fake/urls.log" || fail "the token reaches curl through its stdin config"
  pass "poll keeps only addressed allowlisted messages, marks the owner, and leaves foreign groups"
}

test_poll_redelivery_and_reoffer() {
  local home out before
  home=$(new_home redeliver optin)
  enqueue "$home" getUpdates 200 "{\"ok\":true,\"result\":[$(msg 200 "$GROUP" group 55 '@test_bot one')]}"
  out=$(ad "$home" poll)
  assert_contains "$out" "record: n1001111-1200" "the first delivery is recorded"
  cp "$home/state/telegram/messages/n1001111-1200.json" "$home/before.json"
  before=$(calls "$home" getUpdates)
  out=$(ad "$home" poll)
  assert_contains "$out" "record: n1001111-1200" "an unsurfaced record is re-offered"
  [ "$(calls "$home" getUpdates)" = "$before" ] || fail "re-offering does not poll Telegram first"
  # Simulate a crash before the offset was persisted: Telegram re-delivers.
  printf '0\n' > "$home/state/telegram/offset"
  : > "$home/state/telegram/messages/n1001111-1200.surfaced"
  enqueue "$home" getUpdates 200 "{\"ok\":true,\"result\":[$(msg 200 "$GROUP" group 55 '@test_bot one')]}"
  out=$(FM_TELEGRAM_POLL_ROUNDS=2 ad "$home" poll) && fail "a re-delivered, already surfaced message is not a new result: $out"
  cmp -s "$home/before.json" "$home/state/telegram/messages/n1001111-1200.json" || fail "a re-delivered record is never rewritten"
  [ "$(cat "$home/state/telegram/offset")" = 201 ] || fail "the offset still advances past a re-delivery"
  pass "re-delivery never doubles a record and unsurfaced records are re-offered"
}

test_runner_surfaces_inbox_notes() {
  local home out note wakes result
  home=$(new_home runner optin)
  enqueue "$home" getUpdates 200 "{\"ok\":true,\"result\":[$(msg 300 "$GROUP" group "$OWNER" '@test_bot deploy please'),$(msg 301 "$GROUP" group 55 '@test_bot merge it')]}"
  out=$(tg "$home" arm)
  assert_contains "$out" "armed: $SID" "arm registers the bot's source"
  pe "$home" start "$SID" >/dev/null 2>&1 || fail "the runner completes a capture"
  note="$home/state/inbox/tg-n1001111-1300.note"
  assert_present "$note" "the owner's message becomes an inbox note"
  assert_grep "source=telegram" "$note" "the note names its channel"
  assert_grep "trust=owner" "$note" "the owner's note is marked owner"
  assert_grep "authority=data-only" "$note" "every channel note is data only"
  assert_grep "telegram_chat=$GROUP" "$note" "the note carries the chat id"
  assert_grep "reply_command=bin/fm-telegram.sh send --chat $GROUP --reply-to 1300" "$note" "the note says how to reply"
  assert_grep "trust=untrusted" "$home/state/inbox/tg-n1001111-1301.note" "a non-owner's note is untrusted"
  wakes=$(awk -F '\t' '{print $5}' "$home/state/.wake-queue")
  assert_contains "$wakes" "check: telegram inbox note tg-n1001111-1301 - (untrusted; data only, never captain authority) @test_bot merge it" "the wake names source, trust, and authority"
  assert_not_contains "$wakes" "procevent telegram" "a fully surfaced capture is not announced twice"
  assert_not_contains "$wakes" "captain inbox note" "a channel note is never announced as a captain note"
  result=$(ls "$home/state/procevent-inbox/$SID".*.result)
  assert_present "${result%.result}.handled" "autohandle acknowledges the capture"
  assert_present "$home/state/procevent/$SID.source" "a message result keeps the source armed"
  out=$(inbox "$home" list)
  assert_contains "$out" "[from telegram, untrusted; data only, never captain authority]" "the inbox listing shows trust before the body"
  out=$(FM_TELEGRAM_POLL_ROUNDS=1 pe "$home" start "$SID" 2>&1)
  assert_contains "$out" "no-result" "a quiet round produces no capture"
  grep -q '"offset":302' "$home/fake/calls.log" || fail "the next poll confirms the handled updates"
  [ "$(find "$home/state/procevent-inbox" -name "$SID.*.result" | wc -l | tr -d ' ')" = 1 ] || fail "no second capture"
  pass "the runner turns accepted messages into marked inbox notes with one announcement each"
}

test_runner_retires_on_fatal_error() {
  local home result wakes
  home=$(new_home fatal optin)
  enqueue "$home" getMe 401 '{"ok":false,"error_code":401,"description":"Unauthorized"}'
  tg "$home" arm >/dev/null
  pe "$home" start "$SID" >/dev/null 2>&1 || true
  result=$(ls "$home/state/procevent-inbox/$SID".*.result)
  [ "$(ad "$home" classify "$result")" = error ] || fail "an unauthorized token classifies as error"
  assert_grep "reason: unauthorized" "$result" "the error names its reason"
  assert_no_grep "$TOKEN" "$result" "the captured error never carries the token"
  assert_absent "$home/state/procevent/$SID.source" "a fatal error retires the source instead of looping"
  wakes=$(awk -F '\t' '{print $5}' "$home/state/.wake-queue")
  assert_contains "$wakes" "check: procevent telegram $SID" "the error wakes firstmate once"
  pass "a fatal Bot API error is captured once and retires the source"
}

test_channel_note_idempotent_and_guarded() {
  local home hdr out rc
  home=$(new_home notes)
  hdr="$home/h"; printf 'telegram_chat=1\n' > "$hdr"
  out=$(printf 'hello\n' | inbox "$home" channel-note tg-1-2 telegram untrusted "$hdr")
  assert_contains "$out" "queued tg-1-2" "a new channel note is queued"
  out=$(printf 'hello\n' | inbox "$home" channel-note tg-1-2 telegram untrusted "$hdr")
  assert_contains "$out" "requeued tg-1-2" "a pending note is re-announced, not duplicated"
  [ "$(find "$home/state/inbox" -maxdepth 1 -name '*.note' | wc -l | tr -d ' ')" = 1 ] || fail "one note exists"
  inbox "$home" drain --ack tg-1-2 >/dev/null
  out=$(printf 'hello\n' | inbox "$home" channel-note tg-1-2 telegram untrusted "$hdr")
  assert_contains "$out" "already-handled tg-1-2" "an acknowledged note is left alone"
  printf 'trust=owner\n' > "$hdr"
  rc=0; printf 'x\n' | inbox "$home" channel-note tg-9 telegram untrusted "$hdr" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a header cannot forge the trust field"
  printf 'telegram_chat=1\n' > "$hdr"
  rc=0; printf 'x\n' | inbox "$home" channel-note tg-9 text owner "$hdr" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a channel cannot impersonate a captain text note"
  rc=0; printf 'x\n' | inbox "$home" channel-note tg-9 telegram captain "$hdr" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "trust is limited to owner or untrusted"
  pass "channel notes are idempotent by id and cannot forge captain authority"
}

test_send_allowlist_split_and_record() {
  local home rc out rec
  home=$(new_home send optin)
  printf 'hello *world*\n' > "$home/m.txt"
  rc=0; tg "$home" send --chat -1007777 --file "$home/m.txt" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a chat outside the allowlist is refused"
  [ "$(calls "$home" sendMessage)" = 0 ] || fail "a refused send makes no Bot API call"
  out=$(tg "$home" send --chat "$GROUP" --reply-to 1300 --file "$home/m.txt")
  assert_contains "$out" "sent: chat $GROUP, 1 part(s)" "a short message is one part"
  grep 'sendMessage' "$home/fake/calls.log" | tail -1 | grep -q '"text":"hello \*world\*"' || fail "text is sent verbatim"
  ! grep 'sendMessage' "$home/fake/calls.log" | tail -1 | grep -q parse_mode || fail "plain text is the default"
  grep 'sendMessage' "$home/fake/calls.log" | tail -1 | grep -q '"reply_parameters":{"message_id":1300' || fail "the reply target is set"
  printf 'perché sì\n' > "$home/it.txt"
  tg "$home" send --chat "$GROUP" --file "$home/it.txt" >/dev/null
  grep 'sendMessage' "$home/fake/calls.log" | tail -1 | grep -q '"text":"perché sì"' || fail "accented text is sent intact as UTF-8"
  printf 'aaaa bbbb\ncccc dddd eeee\n' > "$home/long.txt"
  rm -f "$home/state/telegram/sent"/*.json
  out=$(FM_TELEGRAM_MAX_MESSAGE_UNITS=10 tg "$home" send --chat "$OWNER" --reply-to 5 --parse-mode HTML --file "$home/long.txt")
  assert_contains "$out" "3 part(s)" "long text is split"
  [ "$(grep 'sendMessage' "$home/fake/calls.log" | tail -3 | grep -c reply_parameters)" = 1 ] || fail "only the first part replies"
  [ "$(grep 'sendMessage' "$home/fake/calls.log" | tail -3 | grep -c '"parse_mode":"HTML"')" = 3 ] || fail "parse mode applies when asked"
  rec=$(find "$home/state/telegram/sent" -name '*.json')
  [ "$(jq -r '.parts, .delivered, .ok' "$rec" | tr '\n' ' ')" = "3 3 true " ] || fail "the send is recorded"
  rm -f "$rec"
  enqueue "$home" sendMessage 400 '{"ok":false,"description":"Bad Request: chat not found"}'
  rc=0; out=$(tg "$home" send --chat "$OWNER" --file "$home/m.txt" 2>&1) || rc=$?
  expect_code 1 "$rc" "a failed send exits non-zero"
  assert_contains "$out" "chat not found" "the failure reason is reported"
  rec=$(find "$home/state/telegram/sent" -name '*.json')
  [ "$(jq -r .ok "$rec")" = false ] || fail "a failed send is recorded as failed"
  ! grep -q "$TOKEN" "$home/fake/argv.log" || fail "send never puts the token in argv"
  pass "send refuses foreign chats, sends plain text by default, splits, and records"
}

test_discover_lists_ids_without_confirming() {
  local home out rc
  home=$(new_home discover)
  printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TOKEN" > "$home/.env"
  enqueue "$home" getUpdates 200 "{\"ok\":true,\"result\":[$(msg 400 -1002222 supergroup 42 '/start@test_bot')]}"
  out=$(tg "$home" discover)
  assert_contains "$out" "chat -1002222  supergroup  t  from 42  @u42" "discover prints chat and sender ids"
  ! grep 'getUpdates' "$home/fake/calls.log" | grep -q offset || fail "discover never confirms updates"
  [ "$(calls "$home" leaveChat)" = 0 ] || fail "discover never leaves a chat"
  printf '{"allowed_chats":[-1002222],"owner_user_id":42}' > "$home/config/telegram.json"
  tg "$home" arm >/dev/null
  rc=0; tg "$home" discover >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "discover refuses while the inbound source is armed"
  tg "$home" retire >/dev/null
  assert_absent "$home/state/procevent/$SID.source" "retire drops the registration"
  pass "discover reads chat and user ids without consuming updates, and retire disarms"
}

voice_update() {  # <update-id> <chat-id> <from-id> [caption]
  printf '{"update_id":%s,"message":{"message_id":%s,"date":1,"chat":{"id":%s,"type":"private"},"from":{"id":%s,"is_bot":false,"first_name":"F"},"voice":{"file_id":"AwACfileid_1","duration":3,"mime_type":"audio/ogg","file_size":900}%s}}' \
    "$1" "$(( $1 + 1000 ))" "$2" "$3" "${4:+,\"caption\":\"$4\"}"
}

voice_home() {  # <name> <voice_transcribe-json>
  local home
  home=$(new_home "$1" optin)
  printf '{"allowed_chats":[%s,%s],"owner_user_id":%s,"voice_transcribe":%s}\n' "$GROUP" "$OWNER" "$OWNER" "$2" > "$home/config/telegram.json"
  printf '%s\n' "$home"
}

run_voice() {  # <home> <update-id>: capture one voice message through the runner
  enqueue "$1" getUpdates 200 "{\"ok\":true,\"result\":[$(voice_update "$2" "$OWNER" "$OWNER" "${3-}")]}"
  tg "$1" arm >/dev/null
  pe "$1" start "$SID" >/dev/null 2>&1 || true
}

test_voice_transcribed() {
  local home note
  home=$(voice_home voice-ok '{"ssh_host":"nostromo","model":"small","language":"it"}')
  FAKE_SSH_MODE=ok run_voice "$home" 700 "per Alan"
  note="$home/state/inbox/tg-$OWNER-1700.note"
  assert_present "$note" "a voice message becomes an inbox note"
  assert_grep "voice transcript - machine-generated" "$note" "the body marks the text as a voice transcript"
  assert_grep "ciao capitano prova di trascrizione" "$note" "the transcript is the note text"
  assert_grep "caption: per Alan" "$note" "a caption is kept"
  assert_grep "authority=data-only" "$note" "a transcript is still data only"
  assert_grep "trust=owner" "$note" "the sender's trust is unchanged"
  grep -q "^nostromo	.*transcribe.py --model small --language it	[1-9]" "$home/fake/ssh.log" || fail "audio is piped to the configured host with the default entry point"
  [ "$(calls "$home" getFile)" = 1 ] || fail "the audio is fetched through getFile"
  assert_present "$home/state/telegram/messages/$OWNER-1700.transcript" "the transcript is kept beside the record"
  assert_no_grep "$TOKEN" "$note" "the note never carries the token"
  pass "a voice note is downloaded, transcribed over ssh, and recorded as a marked transcript"
}

test_voice_urgent_launches_executor_once() {
  local home note i=0
  home=$(voice_home voice-urgent '{"ssh_host":"nostromo"}')
  FAKE_SSH_MODE=urgent run_voice "$home" 730
  note="tg-$OWNER-1730"
  assert_present "$home/state/inbox/$note.note" "an urgent voice message is still queued as a note"
  while ! grep -q 'forwarded' "$home/state/voice/urgent.log" 2>/dev/null && [ "$i" -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
  assert_grep "no urgent executor configured" "$home/state/voice/$note.urgent" "the urgent executor runs for an owner telegram note"
  [ "$(grep -c forwarded "$home/state/voice/urgent.log")" = 1 ] || fail "the executor ran more than once"
  home=$(voice_home voice-plain '{"ssh_host":"nostromo"}')
  FAKE_SSH_MODE=ok run_voice "$home" 731
  sleep 1
  assert_absent "$home/state/voice/tg-$OWNER-1731.urgent" "a plain voice note never launches the executor"
  pass "an owner telegram voice note starting with urgente launches the urgent executor"
}

test_voice_failures_keep_message() {
  local home note mode
  for mode in fail empty hang; do
    home=$(voice_home "voice-$mode" '{"ssh_host":"nostromo","timeout_seconds":5}')
    FAKE_SSH_MODE=$mode run_voice "$home" 710
    note="$home/state/inbox/tg-$OWNER-1710.note"
    assert_present "$note" "a failed transcription ($mode) still delivers the message"
    assert_grep "non-text message: voice" "$note" "the placeholder survives ($mode)"
    assert_grep "voice note arrived; transcription failed" "$note" "the failure is recorded ($mode)"
    assert_no_grep "voice transcript" "$note" "no transcript is invented ($mode)"
  done
  assert_grep "timed out after 5s" "$TMP_ROOT/voice-hang/state/inbox/tg-$OWNER-1710.note" "a hung host is bounded by the timeout"
  assert_grep "Connection refused" "$TMP_ROOT/voice-fail/state/inbox/tg-$OWNER-1710.note" "a down host's error is recorded"
  home=$(voice_home voice-getfile '{"ssh_host":"nostromo"}')
  enqueue "$home" getFile 400 '{"ok":false,"description":"Bad Request: file is too big"}'
  FAKE_SSH_MODE=ok run_voice "$home" 711
  assert_grep "getFile failed" "$home/state/inbox/tg-$OWNER-1711.note" "a getFile failure is recorded"
  [ ! -e "$home/fake/ssh.log" ] || fail "no audio goes to ssh when the download failed"
  pass "any transcription failure keeps the message with a reason, and the timeout bounds a hung host"
}

test_voice_off_unless_configured() {
  local home note
  home=$(new_home voice-off optin)
  FAKE_SSH_MODE=ok run_voice "$home" 720
  note="$home/state/inbox/tg-$OWNER-1720.note"
  assert_grep "(non-text message: voice)" "$note" "without voice_transcribe the note is today's placeholder"
  assert_no_grep "transcription" "$note" "no transcription is mentioned when it is off"
  [ "$(calls "$home" getFile)" = 0 ] || fail "audio is never downloaded when off"
  [ ! -e "$home/fake/ssh.log" ] || fail "audio never leaves the machine when off"
  home=$(new_home voice-bad optin)
  printf '{"allowed_chats":[%s],"owner_user_id":%s,"voice_transcribe":{"ssh_host":"-oProxyCommand=x"}}' "$OWNER" "$OWNER" > "$home/config/telegram.json"
  assert_contains "$(tg "$home" status)" "invalid:" "a host that looks like an ssh option is refused"
  home=$(new_home voice-badfile optin)
  printf '{"ssh_host":"-oProxyCommand=x"}\n' > "$home/config/voice-transcribe.json"
  FAKE_SSH_MODE=ok run_voice "$home" 721
  note="$home/state/inbox/tg-$OWNER-1721.note"
  assert_grep "(non-text message: voice)" "$note" "an invalid voice config keeps the placeholder"
  assert_grep "voice note arrived; transcription failed" "$note" "an invalid voice config is reported in the note"
  [ ! -e "$home/fake/ssh.log" ] || fail "an invalid voice config never sends audio"
  pass "voice transcription is off unless configured, and its host is validated"
}

test_voice_note_command() {
  local home audio out rc note
  home=$(new_home vnote)
  audio="$home/clip.ogg"; printf 'OGGDATA-clip' > "$audio"
  note="$home/state/inbox"
  # Unconfigured: the note still arrives, with the reason, and the audio stays.
  out=$(FAKE_TG_DIR="$home/fake" FM_HOME="$home" "$ROOT/bin/fm-voice-note.sh" "$audio" --source watch --trust owner)
  assert_contains "$out" "queued voice-watch-" "an unconfigured home still queues the note"
  assert_grep "transcription failed: voice transcription is not configured" "$(ls "$note"/voice-watch-*.note)" "the reason is recorded"
  assert_present "$audio" "the audio is never removed"
  rm -f "$note"/voice-watch-*.note
  printf '{"ssh_host":"nostromo","timeout_seconds":5}\n' > "$home/config/voice-transcribe.json"
  out=$(FAKE_SSH_MODE=ok FAKE_TG_DIR="$home/fake" FM_HOME="$home" "$ROOT/bin/fm-voice-note.sh" "$audio" --source watch --trust owner --caption "dal polso")
  note=$(ls "$home"/state/inbox/voice-watch-*.note)
  assert_grep "voice transcript - machine-generated" "$note" "the body is marked as a voice transcript"
  assert_grep "ciao capitano prova di trascrizione" "$note" "the transcript is the note text"
  assert_grep "caption: dal polso" "$note" "the caption is kept"
  assert_grep "source=watch" "$note" "the note names its source"
  assert_grep "authority=data-only" "$note" "a transcript is data only"
  assert_grep "trust=owner" "$note" "the requested trust is recorded"
  assert_grep "voice_audio=$audio" "$note" "the note points at the audio"
  # A second run reuses the cached transcript: the audio is sent to the host once.
  FAKE_SSH_MODE=fail FAKE_TG_DIR="$home/fake" FM_HOME="$home" "$ROOT/bin/fm-voice-note.sh" "$audio" --source watch >/dev/null
  [ "$(wc -l < "$home/fake/ssh.log" | tr -d ' ')" = 1 ] || fail "a cached transcript is not re-sent"
  # A down host keeps the audio and queues a failure note for new audio.
  printf 'OGGDATA-other' > "$home/other.ogg"
  FAKE_SSH_MODE=fail FAKE_TG_DIR="$home/fake" FM_HOME="$home" "$ROOT/bin/fm-voice-note.sh" "$home/other.ogg" --source watch >/dev/null
  assert_grep "Connection refused" "$(grep -l other.ogg "$home"/state/inbox/voice-watch-*.note)" "a failed transcription is recorded with the reason"
  assert_present "$home/other.ogg" "a failed transcription never drops the audio"
  # A retry once the host is back delivers the transcript beside the failure note.
  FAKE_SSH_MODE=ok FAKE_TG_DIR="$home/fake" FM_HOME="$home" "$ROOT/bin/fm-voice-note.sh" "$home/other.ogg" --source watch >/dev/null
  [ "$(grep -l other.ogg "$home"/state/inbox/voice-watch-*.note | wc -l | tr -d ' ')" = 2 ] || fail "a successful retry queues a new note"
  grep -l other.ogg "$home"/state/inbox/voice-watch-*.note | xargs grep -l "ciao capitano" >/dev/null || fail "the retry note carries the transcript"
  FAKE_SSH_MODE=ok FAKE_TG_DIR="$home/fake" FM_HOME="$home" "$ROOT/bin/fm-voice-note.sh" "$home/other.ogg" --source watch >/dev/null
  [ "$(grep -l other.ogg "$home"/state/inbox/voice-watch-*.note | wc -l | tr -d ' ')" = 2 ] || fail "an unchanged outcome adds no note"
  out=$(FAKE_SSH_MODE=ok FAKE_TG_DIR="$home/fake" FM_HOME="$home" "$ROOT/bin/fm-voice-note.sh" --source watch --trust owner "$audio")
  assert_contains "$out" "queued voice-watch-" "the audio path may come last, as a relay launcher appends it"
  rc=0; FM_HOME="$home" "$ROOT/bin/fm-voice-note.sh" "$audio" --source text >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a source cannot impersonate a captain note"
  rc=0; FM_HOME="$home" "$ROOT/bin/fm-voice-note.sh" "$home/missing.ogg" --source watch >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a missing file is refused"
  pass "fm-voice-note.sh transcribes any audio file into a data-only inbox note and never drops the audio"
}

test_inert_without_optin
test_voice_note_command
test_voice_transcribed
test_voice_urgent_launches_executor_once
test_voice_failures_keep_message
test_voice_off_unless_configured
test_discover_lists_ids_without_confirming
test_poll_filters_records_and_leaves
test_poll_redelivery_and_reoffer
test_runner_surfaces_inbox_notes
test_runner_retires_on_fatal_error
test_channel_note_idempotent_and_guarded
test_send_allowlist_split_and_record
