#!/usr/bin/env bash
# Behavioral coverage for bin/fm-knowledge-store.sh: the one resolver of the
# optional config/knowledge-store that /retrospective uses to pick the RAG or
# PP Brain, including the absent default, backend derivation, and refusals; its
# `reach` probe against a real local HTTP server; and the fm-spawn warning on it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-knowledge-store)
KS="$ROOT/bin/fm-knowledge-store.sh"

new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config"
  printf '%s\n' "$home"
}

test_absent_file_resolves_the_rag() {
  local home out rc
  home=$(new_home absent)
  out=$(FM_HOME="$home" "$KS" read 2>&1); rc=$?
  expect_code 0 "$rc" "an absent config/knowledge-store must resolve, not fail"
  assert_contains "$out" "name=the RAG" "absent file did not name the RAG"
  assert_contains "$out" "backend=rag" "absent file did not resolve the rag backend"
  assert_contains "$out" "search=\`query_rag_hybrid\` or \`query_rag\` on the \`rag_qdrant_server\` MCP server" \
    "absent file did not print the RAG search instructions"
  pass "fm-knowledge-store.sh: an absent file resolves the upstream RAG default"
}

test_pp_brain_file_derives_pp_brain_backend() {
  local home out rc
  home=$(new_home pp-brain)
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  printf 'PP Brain\n`search_knowledge` on the `pp-brain` MCP server, with both `query` and `prompt` set\n' \
    > "$home/config/knowledge-store"
  out=$(FM_HOME="$home" "$KS" read 2>&1); rc=$?
  expect_code 0 "$rc" "a two-line PP Brain config must resolve"
  assert_contains "$out" "name=PP Brain" "PP Brain config did not print its name"
  assert_contains "$out" "backend=pp-brain" "PP Brain config did not derive the pp-brain backend"
  assert_contains "$out" "search=\`search_knowledge\` on the \`pp-brain\` MCP server" \
    "PP Brain config did not print its search instructions"
  pass "fm-knowledge-store.sh: a PP Brain config derives the pp-brain backend"
}

test_backend_derivation_and_explicit_override() {
  local home out
  home=$(new_home rag-renamed)
  printf 'the company RAG\nquery_rag_hybrid on rag_qdrant_server\n' > "$home/config/knowledge-store"
  out=$(FM_HOME="$home" "$KS" read 2>&1)
  assert_contains "$out" "backend=rag" "a config naming rag_qdrant_server did not derive rag"

  home=$(new_home unknown)
  printf 'Wiki\nsearch the wiki tool\n' > "$home/config/knowledge-store"
  out=$(FM_HOME="$home" "$KS" read 2>&1)
  assert_contains "$out" "backend=other" "a config naming no known server did not resolve other"

  home=$(new_home explicit)
  printf 'Brain\nsearch the brain tool\npp-brain\n' > "$home/config/knowledge-store"
  out=$(FM_HOME="$home" "$KS" read 2>&1)
  assert_contains "$out" "backend=pp-brain" "an explicit line-3 backend key was not honored"
  pass "fm-knowledge-store.sh: backend derives from the named server, and line 3 overrides it"
}

test_malformed_files_are_refused() {
  local home out rc
  home=$(new_home empty)
  : > "$home/config/knowledge-store"
  out=$(FM_HOME="$home" "$KS" read 2>&1); rc=$?
  expect_code 1 "$rc" "a 0-byte config/knowledge-store must be refused, not defaulted"
  assert_contains "$out" "config/knowledge-store" "the empty-file refusal must name the file"

  home=$(new_home name-only)
  printf 'PP Brain\n' > "$home/config/knowledge-store"
  out=$(FM_HOME="$home" "$KS" read 2>&1); rc=$?
  expect_code 1 "$rc" "a config missing its search-instructions line must be refused"

  home=$(new_home bad-backend)
  printf 'Brain\nsearch it\nnotion\n' > "$home/config/knowledge-store"
  out=$(FM_HOME="$home" "$KS" read 2>&1); rc=$?
  expect_code 1 "$rc" "an unknown line-3 backend key must be refused"
  assert_contains "$out" "line 3" "the backend-key refusal must name line 3"
  pass "fm-knowledge-store.sh: malformed configs are refused, not silently defaulted"
}

# One real HTTP server answers every probe outcome; /sse holds its 200 open the
# way the real SSE MCP server does.
start_mcp_stub() {
  python3 - "$TMP_ROOT/stub-port" "$TMP_ROOT/stub-auth.log" <<'PY' &
import http.server, os, socketserver, sys, time
port_file, auth_log = sys.argv[1:3]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        with open(auth_log, "a") as f: f.write(str(self.headers.get("Authorization")) + "\n")
        code = {"/ok": 200, "/sse": 200, "/deny": 401, "/err": 503, "/odd": 404}[self.path]
        self.send_response(code); self.send_header("Content-Length", "100" if self.path == "/sse" else "0"); self.end_headers()
        if self.path == "/sse": self.wfile.flush(); time.sleep(10)
class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
s = S(("127.0.0.1", 0), H)
with open(port_file + ".tmp", "w") as f: f.write(str(s.server_address[1]))
os.rename(port_file + ".tmp", port_file)
s.serve_forever()
PY
  STUB_PID=$!
  local i=0
  while [ ! -s "$TMP_ROOT/stub-port" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$TMP_ROOT/stub-port" ] || fail "the MCP stub server never came up"
  STUB="http://127.0.0.1:$(cat "$TMP_ROOT/stub-port")"
}

stop_mcp_stub() {
  [ -z "${STUB_PID:-}" ] || kill "$STUB_PID" 2>/dev/null
  fm_test_cleanup
}
trap stop_mcp_stub EXIT

# A port that was just free refuses the connection.
closed_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

server_entry() { # <url>; a Claude-shaped entry carrying the token
  printf '{"mcpServers":{"rag_qdrant_server":{"type":"sse","url":"%s","headers":{"Authorization":"Bearer SECRET-TOKEN"}}},"projects":{}}\n' "$1"
}

expect_reach() { # <expected> <harness> <message>; config seams come from the caller's env
  local out
  out=$(FM_HOME="$REACH_HOME" "$KS" reach "$2" 2>&1)
  [ "$out" = "$1" ] || fail "$3: expected $1, got: $out"
  assert_not_contains "$out" "SECRET" "reach must never print configuration values"
  assert_not_contains "$out" "127.0.0.1" "reach must never print the server URL"
}

test_reach_probes_the_configured_server() {
  local d="$TMP_ROOT/reach-probe" c
  REACH_HOME=$(new_home reach-probe); mkdir -p "$d"; c="$d/claude.json"
  server_entry "$STUB/ok" > "$c"
  FM_KS_CLAUDE_JSON="$c" expect_reach reachable claude "a 200 from the server"
  assert_grep "Bearer SECRET-TOKEN" "$TMP_ROOT/stub-auth.log" "the probe did not send the configured Authorization header"
  server_entry "$STUB/sse" > "$c"
  FM_KS_CLAUDE_JSON="$c" expect_reach reachable claude "an SSE stream held open past the probe bound"
  server_entry "$STUB/deny" > "$c"
  FM_KS_CLAUDE_JSON="$c" expect_reach unavailable claude "a refused configured token"
  server_entry "$STUB/err" > "$c"
  FM_KS_CLAUDE_JSON="$c" expect_reach unavailable claude "a server error"
  server_entry "http://127.0.0.1:$(closed_port)/sse" > "$c"
  FM_KS_CLAUDE_JSON="$c" expect_reach unavailable claude "a connection refused"
  server_entry "$STUB/odd" > "$c"
  FM_KS_CLAUDE_JSON="$c" expect_reach unknown claude "an answer that neither confirms nor rules out the server"
  printf '{"mcpServers":{"rag_qdrant_server":{"url":"%s"}}}\n' "$STUB/deny" > "$c"
  FM_KS_CLAUDE_JSON="$c" expect_reach unknown claude "a 401 with no configured credential, as for an OAuth entry"
  # shellcheck disable=SC2016  # the literal ${...} is the case under test
  printf '{"mcpServers":{"rag_qdrant_server":{"url":"%s","headers":{"Authorization":"Bearer ${RAG_TOKEN}"}}}}\n' "$STUB/deny" > "$c"
  FM_KS_CLAUDE_JSON="$c" expect_reach unknown claude "a credential left for the harness to expand"
  printf '{"mcpServers":{"rag_qdrant_server":{"url":"%s"}}}\n' "$STUB/ok" > "$d/agy.json"
  FM_KS_AGY_MCP="$d/agy.json" expect_reach reachable agy "an agy entry naming a live URL"
  pass "fm-knowledge-store.sh: reach reports what a bounded probe of the server found"
}

test_reach_keeps_url_and_token_out_of_curl_argv() {
  local d="$TMP_ROOT/reach-argv" real_curl
  REACH_HOME=$(new_home reach-argv); mkdir -p "$d/bin"
  real_curl=$(command -v curl)
  cat > "$d/bin/curl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$d/argv.log"
exec "$real_curl" "\$@"
SH
  chmod +x "$d/bin/curl"
  server_entry "$STUB/ok" > "$d/claude.json"
  FM_KS_CLAUDE_JSON="$d/claude.json" PATH="$d/bin:$PATH" expect_reach reachable claude "a probe through the argv recorder"
  assert_present "$d/argv.log" "the probe did not run curl"
  assert_not_contains "$(cat "$d/argv.log")" "SECRET" "the token reached curl's process arguments"
  assert_not_contains "$(cat "$d/argv.log")" "127.0.0.1" "the server URL reached curl's process arguments"
  pass "fm-knowledge-store.sh: the probe keeps the URL and token out of curl's process arguments"
}

test_reach_reads_the_harness_configuration() {
  local d="$TMP_ROOT/reach-cfg" c
  REACH_HOME=$(new_home reach-cfg); mkdir -p "$d"; c="$d/claude.json"
  printf '{"mcpServers":{"agentmemory":{}},"projects":{"/p":{"mcpServers":{"rag_qdrant_server":{}}}}}\n' > "$c"
  FM_KS_CLAUDE_JSON="$c" expect_reach missing claude "a project-scoped-only claude entry"
  printf '{"mcpServers":{"rag_qdrant_server":{"command":"x","env":{"K":"SECRET-TOKEN"}}}}\n' > "$c"
  FM_KS_CLAUDE_JSON="$c" expect_reach unknown claude "a stdio entry has no server to probe"
  printf '{"mcpServers":{"rag_qdrant_server":' > "$c"
  FM_KS_CLAUDE_JSON="$c" expect_reach unknown claude "a truncated configuration"
  FM_KS_CLAUDE_JSON="$d/absent.json" expect_reach unknown claude "an absent configuration"
  printf '[mcp_servers.other]\ncommand = "x"\n' > "$d/codex.toml"
  FM_KS_CODEX_TOML="$d/codex.toml" expect_reach missing codex "a codex config without the server"
  printf '[mcp_servers.rag_qdrant_server]\ncommand = "x"\n[mcp_servers.after]\nenabled = false\n' >> "$d/codex.toml"
  FM_KS_CODEX_TOML="$d/codex.toml" expect_reach unknown codex "a registered codex entry cannot be probed"
  printf '[mcp_servers.rag_qdrant_server]\nenabled = false\ncommand = "x"\n' > "$d/codex.toml"
  FM_KS_CODEX_TOML="$d/codex.toml" expect_reach missing codex "a disabled codex entry"
  printf '{"mcpServers":{}}\n' > "$d/agy.json"
  FM_KS_AGY_MCP="$d/agy.json" expect_reach missing agy "an agy config without the server"
  printf '{"mcpServers":{"rag_qdrant_server":{"command":"x","disabled":true}}}\n' > "$d/agy.json"
  FM_KS_AGY_MCP="$d/agy.json" expect_reach missing agy "a disabled agy entry"
  printf 'not json\n' > "$d/agy.json"
  FM_KS_AGY_MCP="$d/agy.json" expect_reach unknown agy "an unparseable agy config"
  expect_reach unknown opencode "an unchecked harness"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  printf 'PP Brain\n`search_knowledge` on the `pp-brain` MCP server\n' > "$REACH_HOME/config/knowledge-store"
  FM_KS_CLAUDE_JSON="$c" expect_reach unknown claude "a non-rag backend"
  pass "fm-knowledge-store.sh: reach separates missing, disabled, unprobeable, and unreadable configuration"
}

test_reach_follows_the_claude_config_dir() {
  local d="$TMP_ROOT/reach-dir"
  REACH_HOME=$(new_home reach-dir); mkdir -p "$d/user" "$d/pinned"
  server_entry "$STUB/ok" > "$d/user/.claude.json"
  printf '{"mcpServers":{}}\n' > "$d/pinned/.claude.json"
  HOME="$d/user" CLAUDE_CONFIG_DIR="$d/pinned" expect_reach missing claude "a pinned account whose store lacks the server"
  HOME="$d/pinned" CLAUDE_CONFIG_DIR="$d/user" expect_reach reachable claude "a pinned account whose store has the server"
  HOME="$d/user" CLAUDE_CONFIG_DIR='' expect_reach reachable claude "no pin reads the user home"
  pass "fm-knowledge-store.sh: reach reads the Claude store the worker will read"
}

spawn_warning_case() { # <name> <spawn-kind: ship|secondmate> [claude-json-content]; sets SPAWN_OUT and SPAWN_RC
  local name=$1 kind=$2 case_dir="$TMP_ROOT/spawn-$1" id="ks-$1-z1" home proj wt fakebin sm
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake" codex)
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "${SPAWN_HARNESS:-claude}" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  fm_test_spawn_brief "$home" "$id"
  printf '%s' "${3:-}" > "$case_dir/claude.json"
  if [ "$kind" = secondmate ]; then
    sm="$case_dir/secondmate-home"
    mkdir -p "$sm/bin" "$sm/data"
    printf '# Firstmate\n' > "$sm/AGENTS.md"
    printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
    printf 'charter for %s\n' "$id" > "$sm/data/charter.md"
    printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$sm/.gitignore"
    git -C "$sm" init -q -b main
    SPAWN_OUT=$(FM_KS_CLAUDE_JSON="$case_dir/claude.json" fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$sm" --secondmate); SPAWN_RC=$?
  else
    SPAWN_OUT=$(FM_KS_CLAUDE_JSON="$case_dir/claude.json" fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off); SPAWN_RC=$?
  fi
}

test_spawn_warns_without_blocking() {
  local no_server='{"mcpServers":{}}'
  spawn_warning_case missing ship "$no_server"
  expect_code 0 "$SPAWN_RC" "a spawn with no registered server must still succeed"$'\n'"$SPAWN_OUT"
  assert_contains "$SPAWN_OUT" "warning: ks-missing-z1: the claude harness has no enabled user-level registration" "no warning for an unregistered server"
  assert_contains "$SPAWN_OUT" "spawned ks-missing-z1" "the spawn did not finish after the warning"

  spawn_warning_case down ship "$(server_entry "http://127.0.0.1:$(closed_port)/sse")"
  expect_code 0 "$SPAWN_RC" "a spawn with the server down must still succeed"$'\n'"$SPAWN_OUT"
  assert_contains "$SPAWN_OUT" "warning: ks-down-z1: the knowledge store's MCP server registered for claude is unavailable" "no warning for a server that is down"
  assert_not_contains "$SPAWN_OUT" "SECRET" "the spawn warning leaked the token"
  assert_not_contains "$SPAWN_OUT" "127.0.0.1" "the spawn warning leaked the server URL"
  assert_contains "$SPAWN_OUT" "spawned ks-down-z1" "the spawn did not finish after the warning"

  spawn_warning_case stdio ship '{"mcpServers":{"rag_qdrant_server":{"command":"x","env":{"K":"SECRET-TOKEN"}}}}'
  expect_code 0 "$SPAWN_RC" "a spawn on an unprobeable entry must still succeed"$'\n'"$SPAWN_OUT"
  assert_contains "$SPAWN_OUT" "warning: ks-stdio-z1: the knowledge store could not be verified for the claude harness" "no warning for an entry that cannot be probed"
  assert_contains "$SPAWN_OUT" "must state it in its next status line" "the warning did not say what the worker must do"
  assert_not_contains "$SPAWN_OUT" "SECRET" "the unverified warning leaked configuration"
  assert_contains "$SPAWN_OUT" "spawned ks-stdio-z1" "the spawn did not finish after the warning"

  printf '[mcp_servers.rag_qdrant_server]\ncommand = "x"\n' > "$TMP_ROOT/spawn-codex.toml"
  FM_KS_CODEX_TOML="$TMP_ROOT/spawn-codex.toml" SPAWN_HARNESS=codex spawn_warning_case codex ship
  expect_code 0 "$SPAWN_RC" "a codex spawn on a registered entry must still succeed"$'\n'"$SPAWN_OUT"
  assert_contains "$SPAWN_OUT" "warning: ks-codex-z1: the knowledge store could not be verified for the codex harness" "no warning for a registered codex entry"

  spawn_warning_case live ship "$(server_entry "$STUB/ok")"
  expect_code 0 "$SPAWN_RC" "a spawn with a live server must succeed"$'\n'"$SPAWN_OUT"
  assert_not_contains "$SPAWN_OUT" "knowledge store" "a live server drew a warning"

  spawn_warning_case mate secondmate "$no_server"
  expect_code 0 "$SPAWN_RC" "a secondmate spawn must succeed"$'\n'"$SPAWN_OUT"
  assert_not_contains "$SPAWN_OUT" "knowledge store" "a secondmate spawn drew the worker warning"
  pass "fm-spawn.sh: warns a ship worker on a missing, unavailable, or unverifiable server, never blocks, spares secondmates"
}

start_mcp_stub
test_absent_file_resolves_the_rag
test_reach_probes_the_configured_server
test_reach_keeps_url_and_token_out_of_curl_argv
test_reach_reads_the_harness_configuration
test_reach_follows_the_claude_config_dir
test_spawn_warns_without_blocking
test_pp_brain_file_derives_pp_brain_backend
test_backend_derivation_and_explicit_override
test_malformed_files_are_refused

echo '# all fm-knowledge-store tests passed'
