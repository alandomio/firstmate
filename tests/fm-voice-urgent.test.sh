#!/usr/bin/env bash
# tests/fm-voice-urgent.test.sh - the urgent voice path: bin/fm-voice-note.sh
# never transcribes the same clip twice at once, can return before transcribing
# (--detach), and launches bin/fm-voice-urgent.sh only for an owner transcript
# starting with "urgente"; the executor makes only allowlisted Home Assistant
# calls and forwards everything else.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-voice-urgent-tests.XXXXXX")
trap 'rm -rf -- "$TMP_ROOT"' EXIT
FAILED=0
fail() { printf 'not ok - %s\n' "$1"; FAILED=1; }
pass() { printf 'ok - %s\n' "$1"; }

FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
# ssh: logs one line per call, sleeps FAKE_SSH_SLEEP, prints FAKE_TEXT.
cat > "$FAKEBIN/ssh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'call\n' >> "$FAKE_DIR/ssh.log"
sleep "${FAKE_SSH_SLEEP:-0}"
printf '%s\n' "${FAKE_TEXT:-ciao}"
SH
# curl: answers /api/states from FAKE_DIR/states.json and logs service calls.
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
data= url=
while [ $# -gt 0 ]; do
  case "$1" in --data) data=$2; shift 2 ;; -K|-X) shift 2 ;; -*) shift ;; *) url=$1; shift ;; esac
done
case "$url" in
  */api/states) cat "$FAKE_DIR/states.json" ;;
  */api/services/*) printf '%s %s\n' "${url##*/api/services/}" "$data" >> "$FAKE_DIR/ha.log"; printf '[]' ;;
  *) exit 22 ;;
esac
SH
# tmux: a server with no panes, so delivery never reaches a real one.
printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN/tmux"
chmod +x "$FAKEBIN/ssh" "$FAKEBIN/curl" "$FAKEBIN/tmux"
export PATH="$FAKEBIN:$PATH"
export FM_VOICE_URGENT_NO_DELIVER=1

new_home() {  # <name>
  local h="$TMP_ROOT/$1"
  mkdir -p "$h/state" "$h/config" "$h/fake"
  printf '{"ssh_host":"nostromo","timeout_seconds":20}\n' > "$h/config/voice-transcribe.json"
  printf '[{"entity_id":"light.comodino","attributes":{"friendly_name":"Comodino"}},{"entity_id":"lock.porta","attributes":{}},{"entity_id":"scene.notte","attributes":{}}]' > "$h/fake/states.json"
  printf 'tok\n' > "$h/config/ha.token"
  printf '%s' "$h"
}

wait_for() {  # <file> [secs]
  local i=0
  while [ ! -s "$1" ] && [ "$i" -lt "${2:-20}" ]; do sleep 0.5; i=$((i + 1)); done
  [ -s "$1" ]
}

ha_config() {  # <home> <model-answer>
  printf '%s\n' "$2" > "$1/fake/answer.json"
  jq -n --arg tok "$1/config/ha.token" --arg cmd "cat >/dev/null; cat '$1/fake/answer.json'" \
    '{ha_url:"https://ha.example", ha_token_file:$tok, model_command:$cmd}' > "$1/config/voice-urgent.json"
}

test_urgent_note_launches_executor_and_plain_note_does_not() {
  local h id
  h=$(new_home launch)
  printf 'clip-urgent' > "$h/u.ogg"; printf 'clip-plain' > "$h/p.ogg"
  FAKE_DIR="$h/fake" FAKE_TEXT='Urgente, accendi il comodino' FM_HOME="$h" \
    "$ROOT/bin/fm-voice-note.sh" --source watch --trust owner "$h/u.ogg" >/dev/null || fail "urgent note not queued"
  id=$(basename "$(ls "$h"/state/inbox/voice-watch-*.note)" .note)
  wait_for "$h/state/voice/$id.urgent" || { fail "the executor did not record an outcome"; return; }
  grep -q '^forwarded	no urgent executor configured' "$h/state/voice/$id.urgent" \
    || fail "an unconfigured executor must forward: $(cat "$h/state/voice/$id.urgent")"
  FAKE_DIR="$h/fake" FAKE_TEXT='accendi il comodino urgente' FM_HOME="$h" \
    "$ROOT/bin/fm-voice-note.sh" --source watch --trust owner "$h/p.ogg" >/dev/null
  sleep 1
  [ "$(find "$h/state/voice" -name '*.urgent' | wc -l | tr -d ' ')" = 1 ] || fail "a note not starting with urgente launched the executor"
  pass "only a transcript starting with urgente launches the executor"
}

test_untrusted_source_never_launches() {
  local h
  h=$(new_home untrusted)
  printf 'clip' > "$h/u.ogg"
  FAKE_DIR="$h/fake" FAKE_TEXT='urgente accendi' FM_HOME="$h" \
    "$ROOT/bin/fm-voice-note.sh" --source watch "$h/u.ogg" >/dev/null
  sleep 1
  [ -z "$(find "$h/state/voice" -name '*.urgent')" ] || fail "an untrusted source launched the executor"
  pass "an untrusted source never launches the executor"
}

run_executor() {  # <home> <transcript> -> note id
  local h=$1 id=voice-watch-test$RANDOM
  mkdir -p "$h/state/inbox"
  printf 'id=%s\nsource=watch\n--\n[voice transcript - machine-generated, may contain errors] %s\n' "$id" "$2" > "$h/state/inbox/$id.note"
  FAKE_DIR="$h/fake" FM_HOME="$h" "$ROOT/bin/fm-voice-urgent.sh" "$id" 2>/dev/null
  printf '%s' "$id"
}

test_executor_runs_allowed_calls() {
  local h id
  h=$(new_home allowed)
  ha_config "$h" '{"action":"ha","calls":[{"service":"light.turn_on","entity_id":"light.comodino","brightness_pct":40},{"service":"scene.turn_on","entity_id":"scene.notte"}],"reply":"fatto"}'
  id=$(run_executor "$h" 'urgente accendi il comodino')
  grep -q '^executed' "$h/state/voice/$id.urgent" || fail "allowed calls were not executed: $(cat "$h/state/voice/$id.urgent")"
  grep -q '^light/turn_on {"entity_id":"light.comodino","brightness_pct":40}$' "$h/fake/ha.log" || fail "light call missing: $(cat "$h/fake/ha.log")"
  grep -q '^scene/turn_on {"entity_id":"scene.notte"}$' "$h/fake/ha.log" || fail "scene call missing"
  [ -f "$h/state/inbox/$id.note" ] || fail "the executor must leave the note pending for the session"
  pass "the executor makes allowlisted light and scene calls and leaves the note pending"
}

test_executor_refuses_outside_the_list() {
  local h id answer
  for answer in \
    '{"action":"ha","calls":[{"service":"lock.unlock","entity_id":"lock.porta"}]}' \
    '{"action":"ha","calls":[{"service":"light.turn_on","entity_id":"lock.porta"}]}' \
    '{"action":"ha","calls":[{"service":"light.turn_on","entity_id":"light.inesistente"}]}' \
    '{"action":"ha","calls":[{"service":"light.turn_on","entity_id":"light.comodino"},{"service":"lock.unlock","entity_id":"lock.porta"}]}' \
    '{"action":"forward"}' \
    'not json'; do
    h=$(new_home "refuse$RANDOM")
    ha_config "$h" "$answer"
    id=$(run_executor "$h" 'urgente apri la porta')
    grep -q '^forwarded' "$h/state/voice/$id.urgent" || fail "answer was not forwarded: $answer -> $(cat "$h/state/voice/$id.urgent")"
    [ ! -s "$h/fake/ha.log" ] || fail "a call was made for: $answer"
  done
  h=$(new_home plainhttp)
  ha_config "$h" '{"action":"forward"}'
  jq '.ha_url = "http://ha.example"' "$h/config/voice-urgent.json" > "$h/c" && mv "$h/c" "$h/config/voice-urgent.json"
  id=$(run_executor "$h" 'urgente')
  grep -q 'not https' "$h/state/voice/$id.urgent" || fail "a plain-http Home Assistant URL was accepted"
  pass "the executor makes no call outside the allowlist and forwards instead"
}

test_concurrent_runs_transcribe_once() {
  local h
  h=$(new_home lock)
  printf 'clip-lock' > "$h/a.ogg"
  FAKE_DIR="$h/fake" FAKE_SSH_SLEEP=2 FM_HOME="$h" "$ROOT/bin/fm-voice-note.sh" --source watch "$h/a.ogg" >/dev/null &
  sleep 0.5
  FAKE_DIR="$h/fake" FAKE_SSH_SLEEP=2 FM_HOME="$h" "$ROOT/bin/fm-voice-note.sh" --source watch "$h/a.ogg" >/dev/null &
  wait
  [ "$(wc -l < "$h/fake/ssh.log" | tr -d ' ')" = 1 ] || fail "a concurrent run transcribed the same clip again"
  [ "$(find "$h/state/inbox" -name '*.note' | wc -l | tr -d ' ')" = 1 ] || fail "concurrent runs queued more than one note"
  pass "concurrent runs on one clip transcribe it once"
}

test_detach_returns_at_once() {
  local h start
  h=$(new_home detach)
  printf 'clip-detach' > "$h/d.ogg"
  start=$(date +%s)
  FAKE_DIR="$h/fake" FAKE_SSH_SLEEP=3 FM_HOME="$h" "$ROOT/bin/fm-voice-note.sh" --detach --source watch "$h/d.ogg" >/dev/null \
    || fail "--detach failed"
  [ $(( $(date +%s) - start )) -lt 2 ] || fail "--detach waited for the transcription"
  local i=0
  while [ -z "$(find "$h/state/inbox" -name '*.note' 2>/dev/null)" ] && [ "$i" -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
  [ -n "$(find "$h/state/inbox" -name '*.note' 2>/dev/null)" ] || fail "--detach never queued the note"
  pass "--detach returns at once and still queues the note"
}

test_urgente_on_a_later_line_never_launches() {
  local h
  h=$(new_home multiline)
  printf 'clip-multi' > "$h/m.ogg"
  FAKE_DIR="$h/fake" FAKE_TEXT=$'accendi il comodino\nUrgente per favore' FM_HOME="$h" \
    "$ROOT/bin/fm-voice-note.sh" --source watch --trust owner "$h/m.ogg" >/dev/null || fail "multiline note not queued"
  sleep 1
  [ -z "$(find "$h/state/voice" -name '*.urgent')" ] || fail "urgente on a later line launched the executor"
  pass "only the true start of the transcript can trigger the executor"
}

test_concurrent_urgent_runs_launch_once() {
  local h i
  h=$(new_home urgent-race)
  printf 'clip-race' > "$h/r.ogg"
  for i in 1 2 3; do
    FAKE_DIR="$h/fake" FAKE_TEXT='urgente accendi il comodino' FM_HOME="$h" \
      "$ROOT/bin/fm-voice-note.sh" --source watch --trust owner "$h/r.ogg" >/dev/null &
  done
  wait
  sleep 2
  [ "$(grep -c 'forwarded: no urgent executor configured' "$h/state/voice/urgent.log" 2>/dev/null)" = 1 ] \
    || fail "concurrent runs launched the executor $(grep -c forwarded "$h/state/voice/urgent.log" 2>/dev/null) times"
  pass "concurrent runs on one urgent clip launch the executor once"
}

test_default_model_resolves_under_a_bare_path() {
  local h id
  h=$(new_home barepath)
  mkdir -p "$h/home/.local/bin"
  printf '%s\n' '{"action":"ha","calls":[{"service":"light.turn_on","entity_id":"light.comodino"}],"reply":"fatto"}' > "$h/fake/answer.json"
  # The default model command must find a user-local claude that the system PATH lacks.
  printf '#!/bin/sh\ncat >/dev/null\ncat %s\n' "'$h/fake/answer.json'" > "$h/home/.local/bin/claude"
  chmod +x "$h/home/.local/bin/claude"
  jq -n --arg tok "$h/config/ha.token" '{ha_url:"https://ha.example", ha_token_file:$tok}' > "$h/config/voice-urgent.json"
  id=voice-watch-bare$RANDOM
  mkdir -p "$h/state/inbox"
  printf 'id=%s\nsource=watch\n--\n%s\n' "$id" 'urgente accendi il comodino' > "$h/state/inbox/$id.note"
  env -i HOME="$h/home" PATH="$FAKEBIN:/usr/bin:/bin" FAKE_DIR="$h/fake" FM_VOICE_URGENT_NO_DELIVER=1 \
    "$ROOT/bin/fm-voice-urgent.sh" --home "$h" "$id" 2>/dev/null
  grep -q '^executed' "$h/state/voice/$id.urgent" \
    || fail "the default model command did not run under a bare PATH: $(cat "$h/state/voice/$id.urgent")"
  pass "the default model command resolves a user-local claude under a bare PATH"
}

test_delivery_targets_the_lock_holder_pane() {
  local h id pid err
  [ -r /proc/self/environ ] || { pass "lock-holder pane resolution skipped: no /proc"; return; }
  h=$(new_home lockpane)
  ha_config "$h" '{"action":"forward"}'
  # A live verified harness holding the session lock, launched from a pane.
  mkdir -p "$h/harness"
  printf '#!/bin/sh\nsleep 30\n' > "$h/harness/claude"
  chmod +x "$h/harness/claude"
  env -u HERDR_ENV TMUX_PANE=%fm-test-99 "$h/harness/claude" &
  pid=$!
  printf '%s\n' "$pid" > "$h/state/.lock"
  sleep 0.3
  id=voice-watch-lock$RANDOM
  mkdir -p "$h/state/inbox"
  printf 'id=%s\nsource=watch\n--\n%s\n' "$id" 'urgente che ore sono' > "$h/state/inbox/$id.note"
  # Detached from every pane, as the nohup forward path is.
  err=$(env -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID -u FM_SUPERVISOR_TARGET -u FM_VOICE_URGENT_NO_DELIVER \
    FAKE_DIR="$h/fake" "$ROOT/bin/fm-voice-urgent.sh" --home "$h" "$id" 2>&1 >/dev/null)
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  printf '%s' "$err" | grep -q 'delivery skipped: %fm-test-99 not found on tmux' \
    || fail "delivery did not target the lock holder's pane: $err"
  pass "delivery targets the live session-lock holder's pane when detached from every pane"
}

test_urgent_note_launches_executor_and_plain_note_does_not
test_urgente_on_a_later_line_never_launches
test_concurrent_urgent_runs_launch_once
test_untrusted_source_never_launches
test_executor_runs_allowed_calls
test_executor_refuses_outside_the_list
test_concurrent_runs_transcribe_once
test_detach_returns_at_once
test_default_model_resolves_under_a_bare_path
test_delivery_targets_the_lock_holder_pane
exit "$FAILED"
