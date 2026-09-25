### 1. Tier resolution from (stubbed) harness catalogs + quota check
$ fm-pal-council.sh new "Which log format?" --tier best --language it --slug logs --attach allegato.md
council: logs-9083
folder: /tmp/tmp.BZLu2PUAcP/home/data/pal-logs-9083
state: draft; tier best; language it; rounds up to 6; project /home/alan/.no-mistakes/worktrees/34c874d3722d/01M3CDJ56SEFB14RSBQ3B2H8XB
seat claude: claude fable effort=high provider=Anthropic trusted=yes status=planned
seat codex: codex model-a effort=high provider=OpenAI trusted=no status=planned
seat agy: agy gemini-9.1-pro-high effort=high provider=Google trusted=no status=planned
seat researcher: agy gemini-9.1-pro-high effort=high provider=Google trusted=no status=planned
budget: 10.50 EUR (default)
note: agy: no quota evidence for agy; kept, quota uncertain
note: researcher: no quota evidence for agy; kept, quota uncertain
next: search the RAG for earlier councils and record them with `prior`, write brief.md and persone/claude.md, persone/codex.md, persone/agy.md, then run pseudo, estimate, launch

### 2. Quota exclusion leaving one provider stops for the captain

$ fm-pal-council.sh new Quota --slug quota1
ERROR: every remaining voice is from one provider (Anthropic); a single-provider council gives weaker reviews - ask the captain, and pass --single-provider-ok only on their word
[exit 5]

### 3. Euro estimate vs budget

$ fm-pal-council.sh estimate logs-9083
estimate for council logs-9083: 3 expected round(s), limit 6; prices from /home/alan/.no-mistakes/worktrees/34c874d3722d/01M3CDJ56SEFB14RSBQ3B2H8XB/docs/examples/pal-council.json (checked 2026-09-25)
| seat | model | price class | per round EUR | expected EUR | at the limit EUR |
|---|---|---|---|---|---|
| claude | claude/fable | opus | 0.97 | 3.37 | 8.12 |
| codex | codex/model-a | fallback | 0.49 | 1.69 | 4.06 |
| agy | agy/gemini-9.1-pro-high | standard | 0.22 | 0.75 | 1.77 |
| researcher | agy/gemini-9.1-pro-high | standard | 0.20 | 0.43 | 1.25 |
| moderator | firstmate | fixed | - | 0.50 | 0.50 |
| pseudonymiser | spent so far | - | - | 0.00 | 0.00 |
total expected: 6.73 EUR; at the round limit: 15.70 EUR; budget: 10.50 EUR
verdict: within budget
[exit 0]

$ fm-pal-council.sh estimate tiny-3b69
ERROR: REFUSED: the estimate (6.73 EUR) exceeds the budget (0.50 EUR); lower the tier or the rounds, drop a seat, or ask the captain for a higher --budget (at most 50 EUR)
estimate for council tiny-3b69: 3 expected round(s), limit 6; prices from /home/alan/.no-mistakes/worktrees/34c874d3722d/01M3CDJ56SEFB14RSBQ3B2H8XB/docs/examples/pal-council.json (checked 2026-09-25)
| seat | model | price class | per round EUR | expected EUR | at the limit EUR |
|---|---|---|---|---|---|
| claude | claude/fable | opus | 0.97 | 3.37 | 8.12 |
| codex | codex/model-a | fallback | 0.49 | 1.69 | 4.06 |
| agy | agy/gemini-9.1-pro-high | standard | 0.22 | 0.75 | 1.77 |
| researcher | agy/gemini-9.1-pro-high | standard | 0.20 | 0.43 | 1.25 |
| moderator | firstmate | fixed | - | 0.50 | 0.50 |
| pseudonymiser | spent so far | - | - | 0.00 | 0.00 |
total expected: 6.73 EUR; at the round limit: 15.70 EUR; budget: 0.50 EUR
[exit 3]

### 4. Pseudonymisation gate

$ fm-pal-council.sh pseudo logs-9083
pseudonymised 6 file(s) into psevdo/; entity map: 2 forms, 2 new
placeholders: [ENTE_1] [PERSONA_1]
literal recheck: PASSED
sensitive: yes
[exit 0]
--- psevdo/brief.md:
# Domanda
Il cliente [ENTE_1] di [PERSONA_1] vuole log leggibili: JSON Lines o logfmt?

$ fm-pal-council.sh check logs-9083 /tmp/tmp.BZLu2PUAcP/home/data/pal-logs-9083/brief.md
ERROR: REFUSED: /tmp/tmp.BZLu2PUAcP/home/data/pal-logs-9083/brief.md still contains data that must not be sent: [PERSONA_1] (PERSON) x1, [ENTE_1] (ORG) x1. Pseudonymise it (pseudo --add TYPE=FORM for a missed form) or remove the secret, then retry.
[exit 3]

$ fm-pal-council.sh launch logs-9083
claude: spawned pal-logs-9083-claude
codex: spawned pal-logs-9083-codex
agy: spawned pal-logs-9083-agy
researcher: spawned pal-logs-9083-researcher
round 1 is open until 2026-09-21T14:58:20Z (blind)
next: check each new worker for a trust dialog, then wait for turn wakes and run `barrier`
[exit 0]

### 5. Round 1 barrier, late voice, verbale

$ fm-pal-council.sh barrier logs-9083
round: 1 (open; deadline 2026-09-21T14:58:20Z; expired no)
answered: claude codex
pending: agy
complete: no
[exit 0]

$ fm-pal-council.sh close-round logs-9083
round 1 closed: 2 delivered, 1 missing
  claude: CONTINUE new=1 changed=0 - /tmp/tmp.BZLu2PUAcP/home/data/pal-logs-9083/turni/1-claude.md
  codex: CONTINUE new=1 changed=0 - /tmp/tmp.BZLu2PUAcP/home/data/pal-logs-9083/turni/1-codex.md
  agy: TIMEOUT - /tmp/tmp.BZLu2PUAcP/home/data/pal-logs-9083/turni/1-agy.md
research requests: 0
closing conditions: all-done no; no-news no; round-limit not reached; budget within (2.01 of 10.50 EUR)
next: read every turn in full, write riassunti/<n>.md, run summary
[exit 0]

$ fm-pal-council.sh next logs-9083
claude: round 2 packet sent
codex: round 2 packet sent
agy: round 2 packet sent
round 2 is open until 2026-09-21T14:58:20Z
[exit 0]
--- pacchetti/2-codex.md (delta packet to OpenAI voice):
# Pacchetto del turno 2 - logs-9083 - codex

## Riassunto del moderatore - turno 1

Claude e codex divergono.

## Dossier del ricercatore - turno 1

Nessuna ricerca in questo turno

## Nuovi interventi delle altre voci - turno 1

### claude - fable (Anthropic, claude)

[PERSONA_1] preferisce logfmt, dice claude.

## Richieste di ricerca
[RESEARCH] nessuna
[STATUS] CONTINUE new=1 changed=0

### agy - gemini-9.1-pro-high (Google, agy)

**INTERVENTO MANCANTE**

## Compito di questo turno

Round 2: take a position on the other voices' findings by number, keep, modify, or withdraw your own, and add only findings that are genuinely new. Write `/tmp/tmp.BZLu2PUAcP/home/data/pal-logs-9083/turni/2-codex.md` with the closing block of the turn contract, then append `done: turn 2 <CONTINUE or DONE>` to your status file.
--- verbale.md:
# Verbale del consiglio logs-9083

- Tema: Which log format?
- Convocato: 2026-09-21T14:13:20Z
- Livello: best
- Lingua: it
- Budget: 10.50 EUR

| Seggio | Modello | Fornitore | Strumento | Effort |
|---|---|---|---|---|
| claude | fable | Anthropic | claude | high |
| codex | model-a | OpenAI | codex | high |
| agy | gemini-9.1-pro-high | Google | agy | high |
| Ricercatore | gemini-9.1-pro-high | Google | agy | high |

## Turno 1

### claude - fable (Anthropic, claude)

Mario Rossi preferisce logfmt, dice claude.

## Richieste di ricerca
[RESEARCH] nessuna
[STATUS] CONTINUE new=1 changed=0

### codex - model-a (OpenAI, codex)

JSON Lines e lo standard, dice codex.

## Richieste di ricerca
[RESEARCH] nessuna
[STATUS] CONTINUE new=1 changed=0

### agy - gemini-9.1-pro-high (Google, agy)

**INTERVENTO MANCANTE** (tempo scaduto)

### Riassunto del moderatore - turno 1

Claude e codex divergono.

### 6. Cancel with open round, then cleanup gate

$ fm-pal-council.sh cancel logs-9083 --reason prova
round 2 closed into the record: 1 delivered, 2 missing
council logs-9083 cancelled; run complete and cleanup to stop its workers
[exit 0]
--- verbale.md tail:
Claude e codex divergono.

## Turno 2

### claude - fable (Anthropic, claude)

Parere di claude.
[STATUS] DONE new=0 changed=0

### codex - model-a (OpenAI, codex)

**INTERVENTO MANCANTE** (turno chiuso dal moderatore prima della consegna)

### agy - gemini-9.1-pro-high (Google, agy)

**INTERVENTO MANCANTE** (turno chiuso dal moderatore prima della consegna)

## Chiusura

Consiglio annullato: prova

$ fm-pal-council.sh cleanup logs-9083
ERROR: the completion gate has not passed for claude, codex, agy, researcher; run complete first
[exit 3]

$ fm-pal-council.sh cleanup logs-9083
claude: cleaned up
codex: cleaned up
agy: cleaned up
researcher: cleaned up
every worker of council logs-9083 is cleaned up
[exit 0]
