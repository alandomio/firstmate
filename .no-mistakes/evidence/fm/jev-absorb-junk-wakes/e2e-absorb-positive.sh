#!/usr/bin/env bash
# Positive path: a loopback stub speaking Rizzo Flow's /v1/decisions shape answers
# "absorbable" at 0.95; absorb-try absorbs, the masked digest is written, the next
# drain surfaces it exactly once. Also times the hung-server fall-through precisely.
set -u
WT=/Users/a.domio/.no-mistakes/worktrees/38493c8a7325/01M3JJ086XBMN4XV9A8FMEMZSY
JEV="$WT/bin/fm-jev.sh"; DRAIN="$WT/bin/fm-wake-drain.sh"
H=$(mktemp -d /tmp/fm-jev-absorb-pos.XXXXXX); mkdir -p "$H/state" "$H/config"
export FM_HOME="$H" FM_STATE_OVERRIDE="$H/state"
run() { printf '\n$ %s\n' "${*/#$WT\//}"; "$@"; printf '[exit %s]\n' "$?"; }
python3 - <<'PY' &
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n=int(self.headers.get('Content-Length',0)); req=json.loads(self.rfile.read(n))
        open('/tmp/fm-jev-absorb-stub-last-request.json','w').write(json.dumps(req))
        b=json.dumps({"answers":{"handling":{"type":"choice","status":"ok","choice":"absorbable","uncertainty":{"top_probability":0.95}}}}).encode()
        self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self,*a): pass
http.server.HTTPServer(("127.0.0.1",18918),H).serve_forever()
PY
SPID=$!; sleep 0.7
printf 'http://127.0.0.1:18918\n' > "$H/config/jev-endpoint"
printf 'on\noverride\n' > "$H/config/jev-absorb"
printf 'working: compiling step 2 https://internal.example/ci/42 /Users/me/wt/secret\n' > "$H/state/alpha.status"
printf 'paused: waiting on upstream release\n' > "$H/state/beta.status"
run "$JEV" status
run "$JEV" absorb-try --kind signal --task alpha --reason "signal: $H/state/alpha.status"
run "$JEV" absorb-try --kind stale --task beta --reason "stale: test:beta (paused, awaiting external)"
echo; echo "--- request the classifier received (masked, local only):"; cat /tmp/fm-jev-absorb-stub-last-request.json | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["state"]))'
echo; echo "--- durable digest state/jev/absorbed.jsonl:"; cat "$H/state/jev/absorbed.jsonl"
echo; echo "=== away mode active (.afk): drain holds the digest"
: > "$H/state/.afk"; run "$DRAIN"; rm -f "$H/state/.afk"
echo; echo "=== next real drain (wake or heartbeat) surfaces it"
run "$DRAIN"
echo; echo "=== a later drain never repeats it"
run "$DRAIN"
kill $SPID 2>/dev/null; wait $SPID 2>/dev/null

echo; echo "=== hung classifier: accepts, never answers, config/jev-timeout=2"
python3 - <<'PY' &
import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(("127.0.0.1",18919)); s.listen(5)
c,_=s.accept(); time.sleep(30)
PY
HPID=$!; sleep 0.5
printf 'http://127.0.0.1:18919\n' > "$H/config/jev-endpoint"; printf '2\n' > "$H/config/jev-timeout"
t0=$(python3 -c 'import time;print(time.time())')
run "$JEV" absorb-try --kind signal --task alpha --reason "signal: x"
python3 -c "import time;print('elapsed: %.2fs (per-request classify timeout 2s)'%(time.time()-$t0))"
kill $HPID 2>/dev/null; wait $HPID 2>/dev/null
echo "digest lines still: $(wc -l < "$H/state/jev/absorbed.jsonl" | tr -d ' ')"
rm -rf "$H" /tmp/fm-jev-absorb-stub-last-request.json
