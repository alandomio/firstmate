#!/usr/bin/env bash
# Manual E2E: drive bin/fm-wake-drain.sh (FM_JEV_FOREGROUND=1) against a real
# `rizzo serve` on 127.0.0.1:8017, a hung loopback server, a refused loopback
# port, a high load reading, and a non-loopback endpoint.
set -u
ROOT=${ROOT:?}
DRAIN="$ROOT/bin/fm-wake-drain.sh"; JEV="$ROOT/bin/fm-jev.sh"
T=$(mktemp -d /tmp/fm-jev-e2e.XXXXXX)
REALCURL=$(command -v curl)
mkdir -p "$T/shim" "$T/cap"
cat > "$T/shim/curl" <<SH
#!/usr/bin/env bash
# records each request's URL + body, then runs the real curl
n=\$(ls "$T/cap" | wc -l | tr -d ' ')
prev=; for a in "\$@"; do
  [ "\$prev" = --data-binary ] && cp "\${a#@}" "$T/cap/body.\$n.json"
  case "\$a" in http*) echo "\$a" > "$T/cap/url.\$n";; esac; prev=\$a; done
exec "$REALCURL" "\$@"
SH
chmod +x "$T/shim/curl"

mkhome() { local h="$T/$1"; mkdir -p "$h/state" "$h/config"; printf '%s\n' "$2" > "$h/config/jev-endpoint"; printf '1000\n' > "$h/config/jev-max-load"; echo "$h"; }
q() { printf '1790000000\t%s\tsignal\t%s.status\tsignal: %s.status: %s\n' "$2" "$3" "$3" "$4" >> "$1/state/.wake-queue"; printf '%s\n' "$4" > "$1/state/$3.status"; }
drain() { local h=$1; shift; env PATH="$T/shim:$PATH" FM_HOME="$h" FM_STATE_OVERRIDE="$h/state" FM_JEV_FOREGROUND=1 "$@" "$DRAIN" >/dev/null 2>"$h/drain.err" || echo "DRAIN FAILED: $(cat "$h/drain.err")"; }
show() { jq -c 'select(.ev=="jev" or .ev=="disabled") | {id,outcome,choice,confidence,model,why,reason:(.reason//null|tostring|.[0:60])} | with_entries(select(.value!=null))' "$1/state/jev/shadow.jsonl"; echo "state/jev/disabled: $( [ -f "$1/state/jev/disabled" ] && cat "$1/state/jev/disabled" || echo '(absent - no day pause)')"; }

echo "=== 1. Real rizzo serve: native /v1/decisions, three wakes ==="
h=$(mkhome real http://127.0.0.1:8017)
q "$h" 1 w1 "working: implementing the fix"
q "$h" 2 w2 "blocked: need the captain to approve force-pushing main and rotating the prod API key"
q "$h" 3 w3 "done: PR ready for review, all CI green"
drain "$h"
show "$h"
echo "--- request URL(s) the local backend dialed:"; sort -u "$T"/cap/url.* ; rm -f "$T"/cap/url.*
echo "--- request body sent (first row):"; jq -c '{top_level_keys:keys, options:(.questions.handling.options|map(.id)), policy:.questions.handling.policy, state}' "$T/cap/body.0.json"
echo "--- raw rizzo /v1/decisions answer to that same body:"
"$REALCURL" -sS --max-time 10 -H 'Content-Type: application/json' --data-binary "@$T/cap/body.0.json" http://127.0.0.1:8017/v1/decisions | jq -c '{model, handling:(.answers.handling|{type,status,choice,top:.uncertainty.top_probability})}'
rm -f "$T"/cap/*

echo; echo "=== 2. Hung loopback server (accepts, never answers), jev-timeout=2 ==="
python3 -c 'import socket,time;s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(("127.0.0.1",18917));s.listen(50);c=[]
while True: c.append(s.accept())' & HUNG=$!
sleep 0.5
h=$(mkhome hung http://127.0.0.1:18917); printf '2\n' > "$h/config/jev-timeout"
q "$h" 1 w1 "working: step 1"; q "$h" 2 w2 "working: step 2"; q "$h" 3 w3 "working: step 3"
start=$(date +%s); drain "$h"; echo "drain+classify wall time: $(( $(date +%s)-start ))s (one timeout for the whole drain, not one per row)"
echo "requests dialed: $(ls "$T"/cap/url.* 2>/dev/null | wc -l | tr -d ' ')"; rm -f "$T"/cap/*
show "$h"
kill $HUNG 2>/dev/null; wait $HUNG 2>/dev/null
echo "--- very next drain, endpoint now pointed at the real server (same home):"
printf 'http://127.0.0.1:8017\n' > "$h/config/jev-endpoint"
q "$h" 4 w4 "working: step 4"; drain "$h"
show "$h" | tail -2; rm -f "$T"/cap/*

echo; echo "=== 3. Refused loopback port (nothing listening) ==="
h=$(mkhome refused http://127.0.0.1:18918)
q "$h" 1 w1 "working: a"; q "$h" 2 w2 "working: b"
drain "$h"; echo "requests dialed: $(ls "$T"/cap/url.* 2>/dev/null | wc -l | tr -d ' ') (each row tried)"; rm -f "$T"/cap/*
show "$h"
echo "--- very next drain against the real server:"
printf 'http://127.0.0.1:8017\n' > "$h/config/jev-endpoint"; q "$h" 3 w3 "working: c"; drain "$h"; show "$h" | tail -2; rm -f "$T"/cap/*

echo; echo "=== 4. HTTP 500 from a stub loopback server ==="
python3 -c 'import http.server as H
class R(H.BaseHTTPRequestHandler):
  def do_POST(s): s.send_response(500); s.end_headers(); s.wfile.write(b"boom")
  def log_message(s,*a): pass
H.HTTPServer(("127.0.0.1",18919),R).serve_forever()' & E500=$!
sleep 0.5
h=$(mkhome http500 http://127.0.0.1:18919)
q "$h" 1 w1 "working: a"; q "$h" 2 w2 "working: b"; drain "$h"
echo "requests dialed: $(ls "$T"/cap/url.* 2>/dev/null | wc -l | tr -d ' ')"; rm -f "$T"/cap/*
show "$h"; kill $E500; wait $E500 2>/dev/null

echo; echo "=== 5. Load at/above ceiling (config/jev-max-load=0.01, real load reading) ==="
h=$(mkhome load http://127.0.0.1:8017); printf '0.01\n' > "$h/config/jev-max-load"
q "$h" 1 w1 "working: a"; drain "$h"; echo "requests dialed: $(ls "$T"/cap/url.* 2>/dev/null | wc -l | tr -d ' ')"; rm -f "$T"/cap/*
show "$h"
echo "--- very next drain with the ceiling back at 1000:"
printf '1000\n' > "$h/config/jev-max-load"; q "$h" 2 w2 "working: b"; drain "$h"; show "$h" | tail -2; rm -f "$T"/cap/*

echo; echo "=== 6. Invalid endpoint (non-loopback / path-carrying) - the sole day pause ==="
for ep in http://10.0.0.5:8017 http://127.0.0.1:8017/v1; do
  h=$(mkhome "inv$RANDOM" "$ep"); q "$h" 1 w1 "working: a"; q "$h" 2 w2 "working: b"; drain "$h"
  echo "endpoint $ep -> requests dialed: $(ls "$T"/cap/url.* 2>/dev/null | wc -l | tr -d ' ')"; rm -f "$T"/cap/*
  show "$h"
done
echo; echo "=== status (local backend) ==="
env FM_HOME="$T/real" FM_STATE_OVERRIDE="$T/real/state" "$JEV" status
rm -rf "$T"
