#!/usr/bin/env bash
# Behavior tests for the optional Slack Socket Mode extension in
# extensions/slack-socket-adapter (operator guide: docs/slack-socket-adapter.md).
#
# Part 1 runs the package's own node:test suites, which drive the package
# entrypoint as a subprocess against a local fake of Slack's
# apps.connections.open and Socket Mode WebSocket, and fake credential tools.
# They never reach Slack or a real keychain.
# Part 2 binds a copy of the package into a throwaway home with the real host
# and verifies its manifest and handshake through bin/fm-extension.sh.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXT="$ROOT/extensions/slack-socket-adapter"
EXTENSION_ID=de.peter-park.devops.slack-socket-adapter

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
node_major=$(node -p 'process.versions.node.split(".")[0]')
# The package uses the global WebSocket, which Node ships unflagged from 22.
[ "$node_major" -ge 22 ] || { echo "skip: node 22+ not found (have $node_major)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-slack-socket-adapter)

# --- package suites -----------------------------------------------------------
out=$(cd "$EXT" && node --test --test-reporter=spec test/*.test.mjs 2>&1) || {
  printf '%s\n' "$out"
  fail "slack-socket-adapter node:test suites failed"
}
pass "slack-socket-adapter protocol, poll, credential, and sleep suites pass"

# --- bind and verify through the real host -----------------------------------
PKG="$TMP_ROOT/packages/slack-socket-adapter"
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$TMP_ROOT/packages" "$HOME_DIR"
cp -R "$EXT/package" "$PKG"
chmod -R go-w "$PKG"
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-extension.sh" bind "$PKG" --adapter slack-socket \
  --trust-same-user-code --consent network --consent credential-store >/dev/null \
  || fail "the shipped package did not bind"
verify_out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-extension.sh" verify "$EXTENSION_ID" 2>&1) \
  || { printf '%s\n' "$verify_out"; fail "the bound package did not verify"; }
pass "the shipped package binds and passes the host handshake"

printf 'all tests passed\n'
