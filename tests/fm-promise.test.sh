#!/usr/bin/env bash
# Behavior tests for durable dated promises and their enforcement:
# bin/fm-promise.sh (records, deadline alert stages, blocking decisions, digest,
# legacy record readability), bin/fm-promise-turnend.sh (Italian time
# expressions, the Stop block and its bounded give-up, the prompt context), and
# bin/fm-sentinel.sh (down episode, recovery request, alerts, recovery notice,
# digest, systemd units). Telegram and pane typing are replaced by the scripts'
# own seams (FM_PROMISE_SEND, FM_SENTINEL_SUBMIT), so nothing leaves the host.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-promise-tests)
trap fm_test_cleanup EXIT
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_SUPERVISION_MODEL

P="$ROOT/bin/fm-promise.sh"
T="$ROOT/bin/fm-promise-turnend.sh"
S="$ROOT/bin/fm-sentinel.sh"
export FM_PROMISE_NO_CHECK=1

new_home() {  # <name>
  local h="$TMP_ROOT/$1"
  mkdir -p "$h/state" "$h/data" "$h/config"
  printf '%s' "$h"
}

at() { date -d "2026-11-25 $1" +%s; }

# --- fm-promise.sh -----------------------------------------------------------

H=$(new_home promise)
export FM_HOME=$H
SENT="$TMP_ROOT/sent.txt"
export FM_PROMISE_SEND="cat >> '$SENT'; printf '%s\n' '----' >> '$SENT'"

out=$(FM_PROMISE_NOW=$(at 13:00) "$P" add rilascio --due 16:00 --text 'rilascio app al cliente' --ref chat)
[ "$out" = 'Registrato: rilascio app al cliente entro oggi 16:00 (promessa rilascio)' ] \
  || fail "add must echo the Registrato line, got: $out"
grep -q 'due=' "$H/data/promesse/rilascio.meta" || fail "add must record the due epoch"
pass "add records a dated promise and echoes it back"

FM_PROMISE_NOW=$(at 13:00) "$P" add rilascio --due 17:00 --text x >/dev/null 2>&1 \
  && fail "a duplicate id must be refused"
FM_PROMISE_NOW=$(at 13:00) "$P" add 'Bad Id' --due 17:00 --text x >/dev/null 2>&1 \
  && fail "an invalid id must be refused"
FM_PROMISE_NOW=$(at 13:00) "$P" add nodue --text x >/dev/null 2>&1 \
  && fail "a promise without a due time or condition must be refused"
FM_PROMISE_NOW=$(at 13:00) "$P" add badtime --due 'presto' --text x >/dev/null 2>&1 \
  && fail "an unreadable due time must be refused"
pass "add refuses duplicates, bad ids, and missing or unreadable due times"

out=$(FM_PROMISE_NOW=$(at 13:00) "$P" block rilascio --decision 'MR 99: A o B' --task gop-99)
[ "$out" = 'BLOCCA SCADENZA 16:00 - MR 99: A o B (impegno: rilascio app al cliente; gop-99)' ] \
  || fail "block must print the banner line, got: $out"
pass "block ties a captain decision to the promise and prints the banner"

: > "$SENT"
FM_PROMISE_NOW=$(at 13:30) "$P" alerts >/dev/null
[ ! -s "$SENT" ] || fail "no alert is due 2h30 before the deadline"
FM_PROMISE_NOW=$(at 14:05) "$P" alerts >/dev/null
grep -q '^Scade tra 1h55 (16:00): rilascio app al cliente$' "$SENT" || fail "the 2h alert must fire: $(cat "$SENT")"
grep -q '^BLOCCA SCADENZA 16:00: serve la tua decisione - MR 99: A o B$' "$SENT" || fail "the alert must carry the blocking decision"
grep -q 'informazione, non' "$SENT" || fail "the alert must say a reply is not authorization"
: > "$SENT"
FM_PROMISE_NOW=$(at 14:10) "$P" alerts >/dev/null
[ ! -s "$SENT" ] || fail "the 2h alert must fire once"
FM_PROMISE_NOW=$(at 15:40) "$P" alerts >/dev/null
grep -q '^Scade tra 20 min (16:00)' "$SENT" || fail "the 30m alert must fire"
: > "$SENT"
FM_PROMISE_NOW=$(at 16:01) "$P" alerts >/dev/null
grep -q '^SCADUTO alle 16:00: rilascio app al cliente$' "$SENT" || fail "the overdue alert must fire"
pass "alerts fire once each at 2h, 30m, and overdue"

FM_PROMISE_NOW=$(at 15:20) "$P" add tardi --due 15:45 --text 'consegna tardiva' >/dev/null
: > "$SENT"
FM_PROMISE_NOW=$(at 15:21) "$P" alerts >/dev/null
[ "$(grep -c '^Scade' "$SENT")" = 1 ] || fail "a promise registered inside 30m gets one alert, got: $(cat "$SENT")"
grep -q '^Scade tra 24 min' "$SENT" || fail "that alert is the 30m one"
pass "a late registration gets only the most urgent stage"

FM_PROMISE_SEND=false FM_PROMISE_NOW=$(at 13:00) "$P" add retry --due 14:00 --text retry >/dev/null
FM_PROMISE_SEND=false FM_PROMISE_NOW=$(at 13:10) "$P" alerts >/dev/null 2>&1
[ ! -e "$H/data/promesse/retry.alerted-2h" ] || fail "a failed send must not be marked delivered"
: > "$SENT"
FM_PROMISE_NOW=$(at 13:15) "$P" alerts >/dev/null
grep -q 'retry' "$SENT" || fail "a failed alert must retry on the next run"
pass "a failed delivery retries on the next run"

out=$(FM_PROMISE_NOW=$(at 8:30) "$P" digest)
case "$out" in
  'BLOCCA SCADENZA 16:00 - MR 99: A o B'*'impegni di oggi:'*'rilascio [open] entro oggi 16:00'*) ;;
  *) fail "digest must lead with blocking decisions and list today's promises, got: $out" ;;
esac
pass "digest leads with blocking decisions and lists today's promises"

FM_PROMISE_NOW=$(at 13:00) "$P" unblock rilascio >/dev/null
[ -z "$(FM_PROMISE_NOW=$(at 13:00) "$P" blocking)" ] || fail "unblock must clear the banner"
"$P" "done" rilascio >/dev/null
[ -e "$H/data/promesse/archivio/rilascio.msg" ] || fail "done must archive the record"
[ ! -e "$H/data/promesse/rilascio.msg" ] || fail "done must remove the open record"
pass "unblock clears the banner and done archives the promise"

# A record written by the 07/11 local tool stays readable and closable.
printf 'created=2026-11-08T10:14:21+01:00 every=15\n' > "$H/data/promesse/vecchia.meta"
printf 'compattazione WKS stasera\n' > "$H/data/promesse/vecchia.msg"
printf 'true\n' > "$H/data/promesse/vecchia.cond"
FM_PROMISE_NOW=$(at 13:00) "$P" list | grep -q '^vecchia \[open\] compattazione WKS stasera$' \
  || fail "a legacy record must list: $("$P" list)"
FM_PROMISE_NOW=$(at 13:00) "$P" tick vecchia >/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -e "$H/data/promesse/vecchia.kept" ] && break; sleep 0.2; done
[ -e "$H/data/promesse/vecchia.kept" ] || fail "tick must run a legacy condition"
out=$(FM_PROMISE_NOW=$(at 13:20) "$P" tick vecchia)
case "$out" in 'promessa vecchia mantenibile: compattazione WKS stasera'*) ;; *) fail "tick must announce a kept condition once, got: $out" ;; esac
[ -z "$(FM_PROMISE_NOW=$(at 13:40) "$P" tick vecchia)" ] || fail "the kept announcement must be printed once"
pass "legacy condition promises stay readable and keep working"

out=$("$P" none 'parlava della spesa')
[ "$out" = 'Registrato: nessuna scadenza (parlava della spesa)' ] || fail "none must echo the override"
awk -F '\t' '$2 == "none" && $4 == "parlava della spesa"' "$H/data/promesse/registro.log" | grep -q . \
  || fail "none must be logged"
pass "the nessuna scadenza override is recorded in the log"

# --- fm-promise-turnend.sh ---------------------------------------------------

match() { printf '%s' "$1" | "$T" match; }
for s in 'dobbiamo rilasciare entro il pomeriggio' 'rilasciamo domani' 'ci vediamo alle 15' \
  'consegna il 26/11' 'fammi sapere tra 2 ore' 'per lunedì il report' 'oggi dobbiamo chiudere la MR'; do
  match "$s" >/dev/null || fail "must match a time expression: $s"
done
for s in 'stamattina compro il robot da cucina. cosa devo comprare per il pranzo?' \
  'come va oggi?' 'lunedì ne parliamo' 'Merge PR 108' 'ok procedi'; do
  match "$s" >/dev/null && fail "must not match: $s"
done
pass "time expressions match deadlines and skip everyday mentions"

H2=$(new_home turnend)
export FM_HOME=$H2
TR="$TMP_ROOT/transcript.jsonl"
write_transcript() {  # <iso-ts> <captain text>
  {
    jq -cn '{type:"user",timestamp:"2026-11-25T08:00:00Z",message:{content:"ciao"}}'
    jq -cn --arg ts "$1" --arg t "$2" '{type:"user",timestamp:$ts,message:{content:$t}}'
    jq -cn '{type:"user",timestamp:"2026-11-25T23:59:00Z",message:{content:[{type:"tool_result",content:"x"}]}}'
    jq -cn '{type:"user",timestamp:"2026-11-25T23:59:01Z",message:{content:"⁣FIRSTMATE_OP: v1 watcher: entro domani"}}'
    printf 'not json\n'
  } > "$TR"
}
stop() { jq -cn --arg p "$TR" '{session_id:"s",transcript_path:$p,stop_hook_active:false}' \
  | FM_PROMISE_TURNEND_FORCE_SCOPE=1 "$T" stop; }

write_transcript 2026-11-25T12:00:00Z 'ok procedi con la MR'
stop 2>/dev/null || fail "a message without a time expression must not block"
write_transcript 2026-11-25T12:00:00Z 'dobbiamo rilasciare entro il pomeriggio'
err=$(stop 2>&1) && fail "an unregistered deadline must block the turn end"
case "$err" in *'Turno non chiuso'*'"entro"'*'bin/fm-promise.sh add'*'bin/fm-promise.sh none'*) ;; *) fail "the block must name both commands, got: $err" ;; esac
FM_PROMISE_NOW=$(date -d 2026-11-25T12:01:00Z +%s) "$P" add rilascio --due 16:00 --text r >/dev/null
stop 2>/dev/null || fail "a promise registered after the message must let the turn end"
pass "Stop blocks an unregistered captain deadline until a promise is added"

write_transcript 2026-11-25T13:00:00Z 'per domani il report'
FM_PROMISE_NOW=$(date -d 2026-11-25T12:59:00Z +%s) "$P" none early >/dev/null
stop 2>/dev/null && fail "an override older than the message must not count"
FM_PROMISE_NOW=$(date -d 2026-11-25T13:00:30Z +%s) "$P" none 'era un esempio' >/dev/null
stop 2>/dev/null || fail "a later none override must let the turn end"
pass "the none override counts only after the message"

write_transcript 2026-11-25T14:00:00Z 'consegna entro venerdì'
stop 2>/dev/null && fail "first block"
stop 2>/dev/null && fail "second block"
stop 2>/dev/null || fail "the third Stop must give up"
stop 2>/dev/null || fail "later Stops for the same message must not block again"
[ "$(awk -F '\t' '$2 == "unregistered"' "$H2/data/promesse/registro.log" | wc -l | tr -d ' ')" = 1 ] \
  || fail "the give-up must be logged once"
pass "Stop blocks at most twice per message and logs the give-up once"

jq -cn --arg p "$TR" '{session_id:"s",transcript_path:$p}' | "$T" stop 2>/dev/null \
  || fail "outside a primary home the hook must stay inert"
pass "the hook is inert outside a primary home"

FM_PROMISE_NOW=$(at 13:00) "$P" block rilascio --decision 'scegli A o B' >/dev/null
out=$(jq -cn '{prompt:"rilascia entro le 18"}' | FM_PROMISE_TURNEND_FORCE_SCOPE=1 "$T" prompt)
case "$out" in *'BLOCCA SCADENZA 16:00 - scegli A o B'*'contiene un tempo ("entro")'*) ;; *) fail "prompt context must carry the banner and the hint, got: $out" ;; esac
pass "the prompt hook surfaces blocking decisions and the registration hint"

# --- fm-sentinel.sh ----------------------------------------------------------

H3=$(new_home sentinel)
export FM_HOME=$H3
touch "$H3/state/task-a.meta"
touch -d '-20 minutes' "$H3/state/.last-watcher-beat"
SUB="$TMP_ROOT/submitted.txt"
: > "$SENT"
export FM_SENTINEL_HARNESS=claude FM_SENTINEL_TARGET='tmux %1'
export FM_SENTINEL_SUBMIT="printf '%s\n' \"\$1\" >> '$SUB'"
"$S" tick || fail "tick must succeed"
grep -q "^: Firstmate operational input waiting: read '$H3/state/operational-inbox/" "$SUB" \
  || fail "recovery must type a record-backed doorbell, got: $(cat "$SUB" 2>/dev/null)"
rec=$(sed -n "s/^: Firstmate operational input waiting: read '\\([^']*\\)'.*/\\1/p" "$SUB" | head -n 1)
grep -q 'Run bin/fm-wake-drain.sh' "$rec" || fail "the record must tell the session to drain and end the turn"
grep -q '^Sorveglianza firstmate ferma da 20 min (stale-beacon). Azione: recovery requested in the session.$' "$SENT" \
  || fail "the captain must be alerted, got: $(cat "$SENT")"
pass "a dead watcher opens an episode, requests recovery, and alerts the captain"

: > "$SENT"; : > "$SUB"
"$S" tick
[ ! -s "$SENT" ] || fail "the alert must not repeat within the realert window"
[ ! -s "$SUB" ] || fail "recovery must not be retyped within the retry window"
pass "repeat ticks stay quiet inside the retry and realert windows"

touch "$H3/state/.last-watcher-beat"
"$S" tick
grep -q '^Sorveglianza firstmate ripristinata dopo' "$SENT" || fail "recovery must be announced"
[ ! -e "$H3/state/.sentinel-episode" ] || fail "recovery must close the episode"
pass "a fresh beacon closes the episode with one recovery message"

H4=$(new_home nosession)
export FM_HOME=$H4
touch "$H4/state/task-a.meta"
: > "$SENT"
FM_SENTINEL_HARNESS='' FM_SUPERVISION_MODEL=persistent "$S" tick
grep -q 'no live firstmate session holds this home: it must be reopened' "$SENT" \
  || fail "with no session the alert must say so, got: $(cat "$SENT")"
pass "with no live session the sentinel alerts instead of typing anywhere"

rm -f "$H4/state/task-a.meta"
: > "$SENT"
FM_PROMISE_NOW=$(at 8:30) FM_HOME=$H4 "$P" add oggi --due 18:00 --text 'report Sologas' >/dev/null
FM_PROMISE_NOW=$(at 8:30) "$S" digest
grep -q '^Sorveglianza attiva (nessun lavoro in corso), impegni di oggi:$' "$SENT" || fail "digest header, got: $(cat "$SENT")"
grep -q 'report Sologas' "$SENT" || fail "digest must list today's promises"
pass "the morning digest reports supervision and today's promises"

units=$("$S" systemd-units)
case "$units" in *' tick'*'OnUnitActiveSec=5min'*' digest'*'OnCalendar=*-*-* 08:30:00'*) ;; *) fail "systemd units must carry both timers" ;; esac
pass "systemd units run tick every 5 minutes and the digest at 08:30"
