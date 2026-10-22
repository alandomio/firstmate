#!/usr/bin/env bash
# tests/fm-inbox-pending.test.sh - a pending captain inbox note stays in front
# of firstmate until it is handled: every drain lists it, and the re-announce
# ladder makes it due after the grace period and again every period after.
# The incident this pins: a watch voice note whose announcing wake was
# acknowledged unseen was never surfaced again.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=bin/fm-inbox-pending-lib.sh
. "$ROOT/bin/fm-inbox-pending-lib.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-inbox-pending-tests)
mkdir -p "$TMP_ROOT/config"
: > "$TMP_ROOT/config/supervision-host-off"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/config"

write_note() {  # <state> <id> <epoch> <body>
  mkdir -p "$1/inbox"
  printf 'id=%s\nat=x\nsource=watch\n--\n%s\n' "$2" "$4" > "$1/inbox/$2.note"
  touch -d "@$3" "$1/inbox/$2.note"
}

test_drain_lists_pending_notes_and_drops_handled_ones() {
  local dir state out
  dir=$(make_case drain-lists)
  state="$dir/state"
  out="$dir/drain.out"
  write_note "$state" voice-watch-aaaa "$(( $(date +%s) - 400 ))" '[voice transcript] accendi la luce del comodino'
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2>/dev/null || fail "drain failed with a pending note"
  grep -F 'PENDING INBOX NOTES' "$out" >/dev/null || fail "no PENDING INBOX NOTES section: $(cat "$out")"
  grep -F 'voice-watch-aaaa age=6m: [voice transcript] accendi la luce del comodino' "$out" >/dev/null \
    || fail "the pending note line is missing: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2>/dev/null || fail "second drain failed"
  grep -F 'voice-watch-aaaa' "$out" >/dev/null || fail "a still-pending note was not re-listed on the next drain"
  mkdir -p "$state/inbox/handled"
  mv "$state/inbox/voice-watch-aaaa.note" "$state/inbox/handled/"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2>/dev/null || fail "drain failed after the ack"
  if grep -F 'PENDING INBOX NOTES' "$out" >/dev/null; then fail "a handled note is still listed: $(cat "$out")"; fi
  pass "every drain lists each pending note until it is handled"
}

test_reannounce_ladder() {
  local dir state now due
  dir=$(make_case ladder)
  state="$dir/state"
  now=$(date +%s)
  write_note "$state" voice-watch-bbbb "$((now - 100))" 'mandami la foto'
  due=$(fm_inbox_pending_due "$state" "$now")
  [ -z "$due" ] || fail "a note younger than the grace period was due: $due"
  due=$(fm_inbox_pending_due "$state" "$((now + 140))")
  [ "$due" = "voice-watch-bbbb	mandami la foto" ] || fail "the note was not due at the grace period: '$due'"
  fm_inbox_pending_record_announce "$state" voice-watch-bbbb "$((now + 140))" || fail "record failed"
  due=$(fm_inbox_pending_due "$state" "$((now + 300))")
  [ -z "$due" ] || fail "the note was due again before a full period passed: $due"
  due=$(fm_inbox_pending_due "$state" "$((now + 380))")
  [ -n "$due" ] || fail "the note was not due again after a full period"
  mkdir -p "$state/inbox/handled"
  mv "$state/inbox/voice-watch-bbbb.note" "$state/inbox/handled/"
  due=$(fm_inbox_pending_due "$state" "$((now + 1000))")
  [ -z "$due" ] || fail "a handled note was still due: $due"
  [ ! -e "$state/inbox/.reannounce/voice-watch-bbbb" ] || fail "ladder state was not pruned for a handled note"
  pass "the re-announce ladder fires after the grace period, repeats per period, and stops once handled"
}

test_grace_override() {
  local dir state now
  dir=$(make_case grace)
  state="$dir/state"
  now=$(date +%s)
  write_note "$state" voice-watch-cccc "$((now - 30))" 'x'
  [ -n "$(FM_INBOX_PENDING_GRACE_SECS=20 fm_inbox_pending_due "$state" "$now")" ] \
    || fail "FM_INBOX_PENDING_GRACE_SECS was not honored"
  pass "the grace period is configurable"
}

test_drain_lists_pending_notes_and_drops_handled_ones
test_reannounce_ladder
test_grace_override
