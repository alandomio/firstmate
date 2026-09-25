#!/usr/bin/env bash
# Behavior tests for bin/fm-pal-council.sh: tier resolution from stubbed model
# catalogs, quota exclusion and the single-provider stop, the euro estimate and
# its budget refusal, the pseudonymisation send gate, the round barrier and delta
# packets, budget closure, the synthesis and knowledge payloads, the cleanup
# gate, and the sensitive-council purge. Every firstmate script the council
# calls (spawn, send, captain-hold, teardown, condition watch) and the
# pseudonymiser model are replaced by logging fakes; fm-brief.sh is the real one.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || fail "python3 is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"

TMP=$(fm_test_tmproot fm-pal-council)
PAL="$ROOT/bin/fm-pal-council.sh"
FIX="$TMP/fixtures"
LOGS="$TMP/logs"
mkdir -p "$FIX/catalog" "$LOGS" "$TMP/bin"

new_home() {
  local home=$1
  mkdir -p "$home/data" "$home/state" "$home/config"
}

# --- fixtures -------------------------------------------------------------------

cat > "$FIX/catalog/claude" <<'EOF'
Usage: claude [options]
  --mcp-config <configs...>             Load MCP servers
  --model <model>                       Model for the current session. Provide
                                        an alias for the latest model (e.g.
                                        'fable', 'opus', or 'sonnet') or a
                                        model's full name (e.g.
                                        'claude-fable-5').
  --name <name>                         Session name
EOF
cat > "$FIX/catalog/codex" <<'EOF'
{"models": [
  {"slug": "model-b", "visibility": "list", "priority": 2, "display_name": "B", "description": "Balanced model."},
  {"slug": "hidden-x", "visibility": "hide", "priority": 0, "display_name": "X", "description": "Internal."},
  {"slug": "model-a", "visibility": "list", "priority": 1, "display_name": "A", "description": "Frontier model for complex work."},
  {"slug": "model-c", "visibility": "list", "priority": 3, "display_name": "C", "description": "Fast and efficient model."}
]}
EOF
printf 'Fetching available models...\ngemini-9.9-flash-high\tGemini 9.9 Flash (High)\nclaude-sonnet-9\tClaude Sonnet 9 (Thinking)\ngemini-9.1-pro-high\tGemini 9.1 Pro (High)\ngemini-9.1-pro-low\tGemini 9.1 Pro (Low)\n' > "$FIX/catalog/agy"

cat > "$FIX/quota.json" <<'EOF'
{"providers": [
  {"provider": "claude", "quotaSemantics": {"effectiveAvailability": [{"scope": "all_models", "status": "known", "effectivePercentRemaining": 60}]}},
  {"provider": "codex", "quotaSemantics": {"effectiveAvailability": [{"scope": "all_models", "status": "known", "effectivePercentRemaining": 40}]}}
]}
EOF
cat > "$FIX/quota-codex-empty.json" <<'EOF'
{"providers": [
  {"provider": "codex", "quotaSemantics": {"effectiveAvailability": [{"scope": "all_models", "status": "known", "effectivePercentRemaining": 0}]}}
]}
EOF

# The fake pseudonymiser finds the two private names this test uses, and only
# in the TEXT section of its prompt, like the real model.
cat > "$TMP/bin/fake-haiku.py" <<'EOF'
import json, sys
prompt = sys.stdin.read()
text = prompt.split("TEXT:\n<<<", 1)[-1]
entities = [{"type": t, "forms": [f]} for t, f in (("PERSON", "Mario Rossi"), ("ORG", "Sologas")) if f in text]
print(json.dumps({"is_error": False, "total_cost_usd": 0.002, "result": json.dumps({"entities": entities})}))
EOF

# Logging fakes for the firstmate scripts the council calls; each appends its
# arguments to a log under $PAL_TEST_LOGS so the test can assert the calls.
export PAL_TEST_LOGS="$LOGS"
fake() {
  { printf '#!/usr/bin/env bash\n'; cat; } > "$TMP/bin/$1"
  chmod +x "$TMP/bin/$1"
}
fake spawn <<'EOF2'
echo "$*" >> "$PAL_TEST_LOGS/spawn.log"
case "$1" in *"${FAKE_SPAWN_FAIL:-none}"*) exit 1 ;; esac
EOF2
fake send <<'EOF2'
echo "$1 $2" >> "$PAL_TEST_LOGS/send.log"
exit "${FAKE_SEND_EXIT:-0}"
EOF2
fake teardown <<'EOF2'
echo "$*" >> "$PAL_TEST_LOGS/teardown.log"
EOF2
fake when <<'EOF2'
echo "$*" >> "$PAL_TEST_LOGS/when.log"
EOF2
fake hold <<'EOF2'
case "$1" in
  complete) echo "$*" >> "$PAL_TEST_LOGS/hold.log"; touch "$PAL_TEST_LOGS/completed-$2" ;;
  verify) [ -e "$PAL_TEST_LOGS/completed-$2" ] ;;
esac
EOF2

export FM_PAL_CATALOG_DIR="$FIX/catalog"
export FM_PAL_QUOTA_JSON="$FIX/quota.json"
export FM_PAL_PSEUDONYMISER_CMD="python3 $TMP/bin/fake-haiku.py"
export FM_PAL_SPAWN_BIN="$TMP/bin/spawn" FM_PAL_SEND_BIN="$TMP/bin/send" FM_PAL_TEARDOWN_BIN="$TMP/bin/teardown"
export FM_PAL_HOLD_BIN="$TMP/bin/hold" FM_PAL_WHEN_BIN="$TMP/bin/when"
unset FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE

H="$TMP/home"
new_home "$H"
export FM_HOME="$H"
T0=1790000000
export FM_PAL_NOW=$T0

field() { jq -r "$2" "$H/data/pal-$1/consiglio.json"; }
new_id() { printf '%s\n' "$1" | sed -n 's/^council: //p'; }

# --- tier resolution from the tools' catalogs -------------------------------------

printf 'Allegato: contratto con Sologas.\n' > "$TMP/allegato.md"
out=$("$PAL" new "Which log format?" --tier best --language it --slug logs --attach "$TMP/allegato.md" 2>&1) || fail "new --tier best failed: $out"
C=$(new_id "$out")
[ -n "$C" ] || fail "new printed no council id: $out"
[ "$(field "$C" '[.seats[] | "\(.seat)=\(.harness)/\(.model)/\(.effort)"] | join(" ")')" = "claude=claude/fable/high codex=codex/model-a/high agy=agy/gemini-9.1-pro-high/high" ] \
  || fail "best tier resolved the wrong seats: $(field "$C" '.seats')"
[ "$(field "$C" '.researcher.model')" = "gemini-9.1-pro-high" ] || fail "researcher should take agy's top Gemini Pro model"
[ "$(field "$C" '[.seats[] | .trusted] | join(",")')" = "true,false,false" ] || fail "only the claude seat is inside the Anthropic boundary"
assert_contains "$out" "no quota evidence for agy; kept, quota uncertain" "missing quota evidence is uncertainty, not exclusion"
pass "best tier takes each tool's top catalog model by its own ranking and skips non-Google models on agy"

out=$("$PAL" new "Pro question" --tier pro --slug pro 2>&1) || fail "new --tier pro failed: $out"
P=$(new_id "$out")
[ "$(field "$P" '[.seats[] | "\(.seat)=\(.model)/\(.effort)"] | join(" ")')" = "claude=fable/max codex=model-a/xhigh agy=gemini-9.1-pro-high/high codex-eco=model-c/low" ] \
  || fail "pro tier resolved the wrong seats: $(field "$P" '.seats')"
assert_contains "$out" "grok: model catalog unavailable; optional seat skipped" "an optional seat without a catalog is skipped"
pass "pro tier adds the economy seat from the catalog description and skips an unavailable optional tool"

out=$(FM_PAL_CATALOG_DIR="$TMP/empty" "$PAL" new "No catalogs" 2>&1); code=$?
expect_code 4 "$code" "a required tool without a catalog"
assert_contains "$out" "claude: model catalog unavailable" "the missing catalog is named"
pass "a required seat whose catalog cannot be read stops creation"

# --- quota and provider diversity ---------------------------------------------------

out=$(FM_PAL_QUOTA_JSON="$FIX/quota-codex-empty.json" "$PAL" new "Quota" --slug quota 2>&1) || fail "new with an exhausted provider failed: $out"
Q=$(new_id "$out")
[ "$(field "$Q" '.seats[] | select(.seat=="codex") | .status')" = "excluded" ] || fail "an exhausted provider's seat must be excluded"
assert_contains "$out" "codex: EXCLUDED - no quota left on codex (0% remaining)" "the exclusion is reported"
pass "quota-axi exhaustion excludes a seat and reports it"

printf '[{"harness":"claude","model":"opus","persona":"A"},{"harness":"claude","model":"sonnet","persona":"B"}]' > "$FIX/one-provider.json"
out=$("$PAL" new "One provider" --participants "$FIX/one-provider.json" 2>&1); code=$?
expect_code 5 "$code" "a two-voice single-provider council"
assert_contains "$out" "ask the captain" "the single-provider stop routes to the captain"
out=$("$PAL" new "One provider" --participants "$FIX/one-provider.json" --single-provider-ok --slug solo 2>&1) || fail "--single-provider-ok should allow it: $out"
S=$(new_id "$out")
[ "$(field "$S" '[.seats[].seat] | join(",")')" = "claude,claude-2" ] || fail "duplicate participant seats get distinct names"
[ -s "$H/data/pal-$S/persone/claude-2.md" ] || fail "an explicit participant's persona is written"
pass "a single-provider council needs the captain's word, and explicit participants keep their personas"

# --- budget -------------------------------------------------------------------------------

[ "$(field "$C" '.budget_eur')" = "10.5" ] || fail "default budget should be 4 (opus-class) + 2 + 2 + 2 (researcher) + 0.5, got $(field "$C" '.budget_eur')"
out=$("$PAL" new "Too rich" --budget 60 2>&1); code=$?
expect_code 3 "$code" "a budget above the configured maximum"
out=$("$PAL" new "Tiny budget" --budget 0.5 --slug tiny 2>&1) || fail "new --budget 0.5 failed: $out"
TINY=$(new_id "$out")
out=$("$PAL" estimate "$TINY" 2>&1); code=$?
expect_code 3 "$code" "an estimate above the budget"
assert_contains "$out" "REFUSED: the estimate" "the refusal names the estimate"
out=$("$PAL" estimate "$C" 2>&1) || fail "estimate within budget failed: $out"
assert_contains "$out" "verdict: within budget" "the default council fits its default budget"
assert_contains "$out" "| claude | claude/fable | opus |" "a Fable seat is priced as opus class"
[ "$(jq -r '.estimate.expected_eur > 0' "$H/data/pal-$C/costi.json")" = "true" ] || fail "the estimate is recorded in costi.json"
pass "default budget, budget bounds, and the estimate refusal"

# --- pseudonymisation gate --------------------------------------------------------------

CD="$H/data/pal-$C"
printf '# Domanda\nIl cliente Sologas di Mario Rossi vuole log leggibili: JSON Lines o logfmt?\n' > "$CD/brief.md"
for s in claude codex agy; do printf '# Persona: %s\n\n## Mandate\nJudge from the %s angle.\n' "$s" "$s" > "$CD/persone/$s.md"; done

out=$("$PAL" launch "$C" 2>&1); code=$?
expect_code 2 "$code" "launch before the RAG search is recorded"
assert_contains "$out" "search the RAG for earlier councils first" "launch requires the prior search"
"$PAL" prior "$C" --none >/dev/null

out=$("$PAL" launch "$C" 2>&1); code=$?
expect_code 3 "$code" "launch with no pseudonymised copies"
assert_contains "$out" "no current pseudonymised copy of brief.md" "launch names the stale copy"
assert_absent "$LOGS/spawn.log" "nothing is spawned while the gate refuses"

out=$("$PAL" pseudo "$C" 2>&1) || fail "pseudo failed: $out"
assert_contains "$out" "placeholders: [ENTE_1] [PERSONA_1]" "Italian placeholders for both names"
assert_no_grep "Mario Rossi" "$CD/psevdo/brief.md" "the pseudonymised brief keeps no clear name"
assert_grep "[PERSONA_1]" "$CD/psevdo/brief.md" "the name becomes a stable placeholder"
[ "$(field "$C" '.sensitive')" = "true" ] || fail "a non-empty map marks the council sensitive"

out=$("$PAL" check "$C" "$CD/brief.md" 2>&1); code=$?
expect_code 3 "$code" "the clear brief bound outside Anthropic"
assert_contains "$out" "[PERSONA_1] (PERSON)" "the gate names the placeholder, never the clear form"
assert_not_contains "$out" "Mario Rossi" "the refusal never prints the clear form"
"$PAL" check "$C" "$CD/brief.md" --trusted >/dev/null || fail "the clear brief may go to an Anthropic voice"
printf 'key = "sk-ant-api03-%s"\n' "abcdefghijklmnopqrstuvwxyz0123456789" > "$TMP/secret.md"
"$PAL" check "$C" "$TMP/secret.md" --trusted >/dev/null 2>&1; code=$?
expect_code 3 "$code" "a credential bound for any voice"

# A tampered pseudonymised copy that still carries the clear name is caught when
# the outside-Anthropic brief is generated, before any worker starts.
cp "$CD/psevdo/brief.md" "$TMP/good-psevdo.md"
printf 'Mario Rossi\n' >> "$CD/psevdo/brief.md"
out=$("$PAL" launch "$C" 2>&1); code=$?
expect_code 3 "$code" "launch whose generated brief still names a person"
assert_contains "$out" "REFUSED: the codex brief still contains data that must not be sent" "the gate refuses the codex brief"
assert_absent "$LOGS/spawn.log" "no worker starts when any brief fails the gate"
cp "$TMP/good-psevdo.md" "$CD/psevdo/brief.md"
pass "the send gate refuses a clear name or a credential, and launch refuses before any spawn"

# --- launch and round 1 ------------------------------------------------------------------

out=$("$PAL" launch "$C" 2>&1) || fail "launch failed: $out"
[ "$(wc -l < "$LOGS/spawn.log")" -eq 4 ] || fail "three voices and the researcher are spawned"
assert_grep "pal-$C-codex $ROOT --scout --harness codex --model model-a --effort high" "$LOGS/spawn.log" "a voice spawns as a scout with explicit harness, model, and effort"
for s in claude codex agy researcher; do
  b="$H/data/pal-$C-$s/brief.md"
  assert_present "$b" "brief for $s"
  assert_no_grep "{RECALL_" "$b" "brief for $s has its recall filled"
  assert_no_grep "{{" "$b" "brief for $s has no template placeholder left"
done
assert_no_grep "Mario Rossi" "$H/data/pal-$C-codex/brief.md" "the OpenAI voice never sees the clear name"
assert_no_grep "Mario Rossi" "$H/data/pal-$C-researcher/brief.md" "the researcher never sees the clear name"
assert_grep "Mario Rossi" "$H/data/pal-$C-claude/brief.md" "the Anthropic voice reads the clear brief"
assert_grep "You are a voice in a pal-council" "$H/data/pal-$C-codex/brief.md" "the voice task fills the scaffold"
assert_grep "You are the researcher of a pal-council" "$H/data/pal-$C-researcher/brief.md" "the researcher task fills the scaffold"
assert_grep "psevdo/allegati/allegato.md" "$H/data/pal-$C-codex/brief.md" "outside-Anthropic voices are pointed at pseudonymised attachments"
assert_grep "turni/1-codex.md" "$H/data/pal-$C-codex/brief.md" "the brief names the round-1 turn file"
assert_grep "[STATUS] CONTINUE new=" "$H/data/pal-$C-codex/brief.md" "the turn contract is inlined"
[ "$(field "$C" '.state')" = "running" ] || fail "launch leaves the council running"
[ "$(field "$C" '.rounds[0].n')" = "1" ] || fail "round 1 is open"
pass "launch builds gated scout briefs and spawns every worker"

turn() {  # turn <round> <seat> <status> <new> <changed> [body]
  printf '%s\n\n## Blocchi\nnessuno\n## Domande\nnessuna\n## Richieste di ricerca\n%s\n[STATUS] %s new=%s changed=%s\n' \
    "${6:-Parere di $2.}" "${7:-[RESEARCH] nessuna}" "$3" "$4" "$5" > "$CD/turni/$1-$2.md"
}
turn 1 claude CONTINUE 2 0 "Mario Rossi preferisce logfmt, dice claude. Giulia Verdi concorda." "[RESEARCH] Quali strumenti leggono logfmt per il cliente di Mario Rossi?"
turn 1 codex CONTINUE 1 0 "JSON Lines e' lo standard, dice codex."
printf 'bozza senza chiusura\n' > "$CD/turni/1-agy.md"

out=$("$PAL" barrier "$C" 2>&1)
assert_contains "$out" "answered: claude codex" "delivered turns are seen"
assert_contains "$out" "pending: agy" "a turn without its [STATUS] line is not delivered"
assert_contains "$out" "complete: no" "the round is not complete"
out=$("$PAL" close-round "$C" 2>&1); code=$?
expect_code 2 "$code" "closing a pending round before its time"
assert_contains "$out" "still waiting for agy" "the refusal names the missing voice"

out=$(FM_PAL_NOW=$((T0 + 46 * 60)) "$PAL" close-round "$C" 2>&1) || fail "close-round after the deadline failed: $out"
assert_contains "$out" "agy: TIMEOUT" "a late voice is recorded as such"
assert_contains "$out" "research requests: 1" "the research request is collected"
V="$CD/verbale.md"
assert_grep "Mario Rossi preferisce logfmt, dice claude." "$V" "a delivered turn is in the record verbatim"
assert_grep "**INTERVENTO MANCANTE** (tempo scaduto; file incompleto conservato in" "$V" "the missing turn is recorded honestly"
pass "the round barrier waits for [STATUS] lines and records a late voice as late"

printf 'Claude e codex divergono sul formato.\n' > "$CD/riassunti/1.md"
"$PAL" summary "$C" "$CD/riassunti/1.md" >/dev/null || fail "summary failed"
assert_grep "### Riassunto del moderatore - turno 1" "$V" "the summary is appended under its heading"
"$PAL" summary "$C" "$CD/riassunti/1.md" >/dev/null 2>&1; code=$?
"$PAL" next "$C" >/dev/null 2>&1; next_code=$?
expect_code 2 "$code" "a second summary of the same round"
expect_code 2 "$next_code" "next before the research is served"

out=$("$PAL" research "$C" 2>&1) || fail "research failed: $out"
assert_grep "pal-$C-researcher Council $C research round 1:" "$LOGS/send.log" "the researcher gets one line"
assert_no_grep "Mario Rossi" "$CD/ricerca/pacchetto-1.md" "the research packet is pseudonymised"
assert_grep "[PERSONA_1]" "$CD/ricerca/pacchetto-1.md" "the research packet keeps the placeholder"
"$PAL" dossier "$C" >/dev/null 2>&1; code=$?
expect_code 2 "$code" "a dossier that is not delivered"
printf '# Dossier\n\n### R1.1\nlogfmt: https://example.org/logfmt (consultato 2026-09-25)\n\n[DOSSIER] complete\n' > "$CD/ricerca/1.md"
"$PAL" dossier "$C" >/dev/null || fail "dossier failed"
assert_grep "https://example.org/logfmt" "$CD/dossier-ricerca.md" "the dossier is collected"

# A captain message travels with the next packets; a name the model missed is
# added by hand mid-council and reaches outside-Anthropic voices as a placeholder.
printf 'Il capitano chiede di considerare anche Mario Rossi.\n' > "$TMP/msg1.md"
"$PAL" message "$C" --all --file "$TMP/msg1.md" >/dev/null || fail "message failed"
assert_grep "### Messaggio del capitano (a tutte le voci)" "$V" "the captain's message is in the record"
out=$("$PAL" pseudo "$C" --skip-model --add "PERSON=Giulia Verdi" 2>&1) || fail "pseudo --add while running failed: $out"
: > "$LOGS/send.log"
out=$("$PAL" next "$C" 2>&1) || fail "next failed: $out"
assert_grep "Il capitano chiede di considerare anche [PERSONA_1]." "$CD/pacchetti/2-codex.md" "the message reaches an outside-Anthropic voice pseudonymised"
assert_grep "Il capitano chiede di considerare anche Mario Rossi." "$CD/pacchetti/2-claude.md" "the message reaches the Anthropic voice as written"
assert_grep "[PERSONA_2] concorda." "$CD/pacchetti/2-codex.md" "a form added mid-council gets its own placeholder"
assert_no_grep "Giulia Verdi" "$CD/pacchetti/2-codex.md" "the hand-added form never reaches the OpenAI voice"
[ "$(field "$C" '.messages[0].delivered')" = "round 2" ] || fail "the message is marked delivered with round 2"
[ "$(wc -l < "$LOGS/send.log")" -eq 3 ] || fail "every active voice gets its round-2 line"
assert_no_grep "Mario Rossi" "$CD/pacchetti/2-codex.md" "the OpenAI packet must not carry the clear name"
assert_grep "[PERSONA_1] preferisce logfmt, dice claude." "$CD/pacchetti/2-codex.md" "the OpenAI packet carries claude's turn pseudonymised"
assert_grep "JSON Lines e' lo standard, dice codex." "$CD/pacchetti/2-claude.md" "claude's packet carries codex's turn"
assert_no_grep "JSON Lines e' lo standard, dice codex." "$CD/pacchetti/2-codex.md" "a voice is not sent its own turn"
assert_grep "Claude e codex divergono sul formato." "$CD/pacchetti/2-agy.md" "the packet carries the moderator summary"
assert_grep "https://example.org/logfmt" "$CD/pacchetti/2-agy.md" "the packet carries the dossier"
assert_grep "INTERVENTO MANCANTE" "$CD/pacchetti/2-claude.md" "the packet says which voice was missing"
assert_no_grep "Mario Rossi" "$CD/psevdo/verbale.md" "the record for outside-Anthropic voices is pseudonymised"
[ "$(field "$C" '.rounds[1].n')" = "2" ] || fail "round 2 is open"
pass "delta packets carry only the others' new turns, the summary, and the dossier, pseudonymised per recipient"

# --- budget closure during the rounds ------------------------------------------------------

big=$(python3 -c 'print("x" * 1500000)')
turn 2 claude DONE 0 0 "$big"
turn 2 codex DONE 0 0
turn 2 agy DONE 0 0
out=$("$PAL" close-round "$C" 2>&1) || fail "close-round 2 failed: $out"
assert_contains "$out" "all-done yes" "every voice reported DONE"
assert_contains "$out" "no-news yes" "nothing new and no changed position"
assert_contains "$out" "budget EXCEEDED" "an oversized round takes the spend past the budget"
printf 'Nessuna novita.\n' > "$CD/riassunti/2.md"
"$PAL" summary "$C" "$CD/riassunti/2.md" >/dev/null
"$PAL" research "$C" >/dev/null
out=$("$PAL" next "$C" 2>&1); code=$?
expect_code 3 "$code" "another round past the budget"
assert_contains "$out" "the budget is exceeded" "the refusal says why"
pass "a council whose spend passes its budget cannot open another round"

# --- close, synthesis, knowledge -------------------------------------------------------------

"$PAL" close "$C" --reason "tutte le voci DONE" >/dev/null
"$PAL" finalize "$C" >/dev/null 2>&1; code=$?
expect_code 2 "$code" "finalize without a synthesis"
printf '## Raccomandazione\nlogfmt per Mario Rossi.\n\n## Disaccordi\ncodex contro claude.\n' > "$CD/sintesi.md"
out=$("$PAL" finalize "$C" 2>&1); code=$?
expect_code 2 "$code" "a synthesis missing required headings"
assert_contains "$out" "Punti d'accordo" "the missing heading is named"
printf "## Raccomandazione\nlogfmt per Mario Rossi.\n\n## Punti d'accordo\nNessuno.\n\n## Disaccordi\ncodex contro claude.\n\n## Domande per il capitano\nNessuna.\n" > "$CD/sintesi.md"
out=$("$PAL" finalize "$C" 2>&1) || fail "finalize failed: $out"
[ "$(field "$C" '.state')" = "closed" ] || fail "finalize closes the council"
R="$CD/rag/synthesis-1.json"
assert_present "$R" "the synthesis payload"
[ "$(jq -r '.user_roles' "$R")" = "admin,dev" ] || fail "knowledge is internal (admin,dev)"
[ "$(jq -r '.metadata_json | fromjson | .rbac_roles | join(",")' "$R")" = "admin,dev" ] || fail "metadata carries the internal roles"
jq -e '.metadata_json | fromjson | .tags | index("pal-council")' "$R" >/dev/null || fail "payload is tagged pal-council"
jq -e '.metadata_json | fromjson | .tags | index("sensitivity:sensitive")' "$R" >/dev/null || fail "payload carries the sensitivity tag"
assert_contains "$(jq -r '.chunk_text' "$R")" "Tags: pal-council;" "the tags are also searchable text"
assert_no_grep "Mario Rossi" "$R" "a sensitive council's synthesis payload is pseudonymised"
for f in "$CD"/rag/record-*.json; do assert_no_grep "Mario Rossi" "$f" "a sensitive council's record payload is pseudonymised"; done
out=$("$PAL" rag-query "$C")
assert_contains "$out" "query_text: pal-council Which log format?" "the prior-council query uses the tag and topic"
"$PAL" rag-done "$C" synthesis-1.json point-1 >/dev/null
[ "$(field "$C" '.rag[0].point_id')" = "point-1" ] || fail "an ingested payload is recorded"
pass "the synthesis gate, internal tagged knowledge payloads, and their pseudonymisation"

# --- cleanup gate -----------------------------------------------------------------------------

out=$("$PAL" cleanup "$C" 2>&1); code=$?
expect_code 3 "$code" "cleanup before the completion gate"
assert_contains "$out" "run complete first" "the refusal points at complete"
assert_absent "$LOGS/teardown.log" "no worker is torn down before the gate"
"$PAL" complete "$C" --none >/dev/null || fail "complete failed"
out=$("$PAL" cleanup "$C" 2>&1) || fail "cleanup failed: $out"
[ "$(wc -l < "$LOGS/teardown.log")" -eq 4 ] || fail "every worker is cleaned up"
assert_present "$H/data/pal-$C-codex/report.md" "each worker gets its pointer report"
pass "cleanup waits for the completion gate, then cleans up every worker"

# --- a later council finds this one -----------------------------------------------------------------

out=$("$PAL" new "Which log format, again?" --like "$C" --slug again 2>&1) || fail "new --like failed: $out"
A=$(new_id "$out")
assert_present "$H/data/pal-$A/precedenti/$C.md" "the inherited synthesis is attached"
[ "$(field "$A" '[.seats[].model] | join(",")')" = "fable,model-a,gemini-9.1-pro-high" ] || fail "--like keeps the composition"
assert_present "$H/data/pal-$A/persone/codex.md" "--like keeps the personas"
pass "a follow-up council inherits the earlier synthesis and composition"

# --- sensitive purge -----------------------------------------------------------------------------

expect_code 1 "$("$PAL" purge-due "$C"; echo $?)" "purge is not due before 12 hours"
"$PAL" arm-purge "$C" >/dev/null || fail "arm-purge failed"
assert_grep "arm pal-purge-$C" "$LOGS/when.log" "the watch is named after the council"
assert_grep "--condition $ROOT/bin/fm-pal-council.sh purge-due $C --action $ROOT/bin/fm-pal-council.sh status $C" "$LOGS/when.log" "the watch polls purge-due and only prints status"
LATE=$((T0 + 13 * 3600))
expect_code 0 "$(FM_PAL_NOW=$LATE "$PAL" purge-due "$C"; echo $?)" "purge is due after 12 hours"
[ "$(FM_PAL_NOW=$LATE "$PAL" purge-due --all)" = "$C" ] || fail "purge-due --all lists the due council"
out=$(FM_PAL_NOW=$LATE "$PAL" purge "$C" 2>&1) || fail "purge failed: $out"
assert_absent "$CD/entita.md" "the placeholder table is deleted"
assert_absent "$CD/allegati" "the original attachments are deleted"
if grep -rF "Mario Rossi" "$CD" "$H/data/pal-$C-claude" >/dev/null; then
  fail "no clear name survives the purge: $(grep -rlF "Mario Rossi" "$CD" "$H/data/pal-$C-claude")"
fi
assert_grep "[PERSONA_1]" "$CD/sintesi.md" "the synthesis stays readable in pseudonymised form"
assert_grep "retire pal-purge-$C" "$LOGS/when.log" "the purge retires its watch"
expect_code 1 "$(FM_PAL_NOW=$LATE "$PAL" purge-due "$C"; echo $?)" "a purged council is never due again"
"$PAL" purge "$TINY" >/dev/null 2>&1; code=$?
expect_code 0 "$code" "purging a non-sensitive council is a no-op"
pass "a sensitive council keeps only its pseudonymised form after the purge"

# --- honest failure on a lost voice ----------------------------------------------------------------

H2="$TMP/home2"
new_home "$H2"
export FM_HOME="$H2"
out=$("$PAL" new "Lost voice" --slug lost 2>&1) || fail "new failed: $out"
L=$(new_id "$out")
LD="$H2/data/pal-$L"
printf 'Domanda neutra.\n' > "$LD/brief.md"
for s in claude codex agy; do printf 'Persona %s.\n' "$s" > "$LD/persone/$s.md"; done
if ! { "$PAL" prior "$L" --none && "$PAL" pseudo "$L" && "$PAL" launch "$L"; } >/dev/null; then
  fail "setup of the lost-voice council failed"
fi
[ "$(jq -r '.sensitive' "$LD/consiglio.json")" = "false" ] || fail "a council with nothing to hide is not sensitive"
CD=$LD
H=$H2
for s in claude codex agy; do turn 1 "$s" CONTINUE 1 0; done
"$PAL" close-round "$L" >/dev/null
printf 'Riassunto.\n' > "$LD/riassunti/1.md"
"$PAL" summary "$L" "$LD/riassunti/1.md" >/dev/null
"$PAL" research "$L" >/dev/null
out=$(FAKE_SEND_EXIT=1 "$PAL" next "$L" 2>&1) || fail "next with failing sends should still open the round: $out"
assert_contains "$out" "LOST" "a voice that cannot be reached is reported"
[ "$(jq -r '[.seats[].status] | unique | join(",")' "$LD/consiglio.json")" = "lost" ] || fail "unreachable voices are marked lost"
assert_grep "Voice lost" "$LD/verbale.md" "the loss is in the record"
pass "a voice that cannot be reached is recorded as lost, never spoken for"

# --- a failed spawn, status, and cancel --------------------------------------------------------------

out=$("$PAL" new "Failed spawn" --slug fail 2>&1) || fail "new failed: $out"
F=$(new_id "$out")
FD="$H2/data/pal-$F"
printf 'Domanda neutra.\n' > "$FD/brief.md"
for s in claude codex agy; do printf 'Persona %s.\n' "$s" > "$FD/persone/$s.md"; done
if ! { "$PAL" prior "$F" --none && "$PAL" pseudo "$F"; } >/dev/null; then
  fail "setup of the failed-spawn council failed"
fi
out=$(FAKE_SPAWN_FAIL="pal-$F-codex" "$PAL" launch "$F" 2>&1) || fail "launch with one failed spawn should continue: $out"
assert_contains "$out" "codex: FAILED - spawn failed" "the failed spawn is reported"
out=$("$PAL" status "$F")
assert_contains "$out" "seat codex: codex/model-a failed - spawn failed" "status shows the failed seat"
assert_contains "$out" "seat claude: claude/fable active" "the other voices run"
"$PAL" cancel "$F" --reason "prova" >/dev/null || fail "cancel failed"
[ "$(jq -r '.state' "$FD/consiglio.json")" = "cancelled" ] || fail "cancel records the state"
assert_grep "Council cancelled: prova" "$FD/verbale.md" "the cancellation is in the record"
"$PAL" complete "$F" --none >/dev/null || fail "complete after cancel failed"
: > "$LOGS/teardown.log"
"$PAL" cleanup "$F" >/dev/null || fail "cleanup after cancel failed"
[ "$(wc -l < "$LOGS/teardown.log")" -eq 3 ] || fail "only the workers that started are cleaned up"
assert_no_grep "pal-$F-codex" "$LOGS/teardown.log" "a worker that never started is not torn down"
pass "a failed spawn is recorded, the council runs on, and a cancel still cleans up what started"

echo "all fm-pal-council tests passed"
