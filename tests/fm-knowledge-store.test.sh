#!/usr/bin/env bash
# Behavioral coverage for bin/fm-knowledge-store.sh: the one resolver of the
# optional config/knowledge-store that /retrospective uses to pick the RAG or
# PP Brain, including the absent default, backend derivation, and refusals.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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

test_absent_file_resolves_the_rag
test_pp_brain_file_derives_pp_brain_backend
test_backend_derivation_and_explicit_override
test_malformed_files_are_refused

echo '# all fm-knowledge-store tests passed'
