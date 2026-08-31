#!/usr/bin/env bash
# Behavior tests for bin/fm-remote-skill-sync.sh, the remote-secondmate-launch
# step that rsyncs the engineer's ~/.claude/skills/ into a remote route.
#
# Exercised entirely through the script's executable interface against a fake
# rsync binary, never against real ssh/rsync or by asserting source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-remote-skill-sync)
SCRIPT="$ROOT/bin/fm-remote-skill-sync.sh"

# --- world builder -----------------------------------------------------------

# new_home <name>: an FM_HOME with data/secondmates.md carrying one remote
# route "rsm" (host fake-host) and one local route "loc", plus a config/ dir
# and a fake local skills source with a couple of ordinary skills and every
# directory the documented default exclusion list names.
new_home() {
  local name=$1 home skills
  home="$TMP_ROOT/$name/home"
  skills="$TMP_ROOT/$name/skills"
  mkdir -p "$home/data" "$home/config" \
    "$skills/alpha-skill" "$skills/beta-skill" \
    "$skills/notebooklm" "$skills/skill-creator" "$skills/no-mistakes" \
    "$skills/__pycache__"
  printf '%s\n' "alpha" > "$skills/alpha-skill/SKILL.md"
  printf '%s\n' "beta" > "$skills/beta-skill/SKILL.md"
  cat > "$home/data/secondmates.md" <<'EOF'
- rsm - remote test domain (host: fake-host; root: /remote/root; home: /remote/home; scope: remote testing; projects: alpha; added 2026-08-02)
- loc - local test domain (home: /local/home; scope: local testing; projects: alpha; added 2026-08-02)
EOF
  printf '%s|%s\n' "$home" "$skills"
}

# fake_rsync <dir> <mode>: install a fake rsync at <dir>/rsync that appends its
# full argv to <dir>/argv.log (one invocation per line, tab-separated) and
# behaves per <mode>:
#   ok        prints a genuine --stats block reporting real transferred files
#   noop      prints a genuine --stats block reporting zero transferred files
#   badflags  mimics an old rsync rejecting an unsupported flag: prints only a
#             usage banner (no stats keys at all) and STILL exits 0, exactly
#             the trap this script must not trust
#   fail      prints an error and exits 1, as a real transfer failure would
fake_rsync() {
  local dir=$1 mode=$2
  mkdir -p "$dir"
  cat > "$dir/rsync" <<SH
#!/usr/bin/env bash
{ IFS=\$'\t'; printf '%s\n' "\$*" >> "$dir/argv.log"; }
case "$mode" in
  ok)
    cat <<'EOT'
Number of files: 5
Number of files transferred: 2
Total file size: 40 B
Total transferred file size: 12 B
Total sent: 210 B
Total received: 60 B
EOT
    exit 0
    ;;
  noop)
    cat <<'EOT'
Number of files: 5
Number of files transferred: 0
Total file size: 40 B
Total transferred file size: 0 B
Total sent: 135 B
Total received: 20 B
EOT
    exit 0
    ;;
  badflags)
    echo "rsync: unrecognized option '--bogus'" >&2
    echo "usage: rsync [-0468BCDEFHIKLOPRSTWVabcdghiklnopqrtuvxyz] [-e program]" >&2
    exit 0
    ;;
  fail)
    echo "rsync: connection unexpectedly closed" >&2
    exit 12
    ;;
esac
SH
  chmod +x "$dir/rsync"
}

run_sync() { # <home> <skills> <id> <fakebin>
  local home=$1 skills=$2 id=$3 fakebin=$4
  FM_HOME="$home" FM_SKILLS_SOURCE_OVERRIDE="$skills" FM_RSYNC_BIN="$fakebin/rsync" \
    "$SCRIPT" "$id"
}

test_local_route_is_skipped() {
  local rec home skills fakebin out rc
  rec=$(new_home local-skip)
  home=${rec%%|*}; skills=${rec#*|}
  fakebin="$TMP_ROOT/local-skip/fakebin"
  # No fake rsync at all: if the script tried to invoke it, this fails loudly
  # with "command not found" rather than silently succeeding.
  mkdir -p "$fakebin"
  out=$(run_sync "$home" "$skills" loc "$fakebin" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "a local route should exit 0, got $rc: $out"
  assert_contains "$out" "not a remote route" "a local route should report why it was skipped"
  assert_absent "$fakebin/argv.log" "a local route must never invoke rsync at all"
  pass "a local secondmate route is skipped without ever invoking rsync"
}

test_never_passes_delete_and_applies_default_exclusions() {
  local rec home skills fakebin out rc argv
  rec=$(new_home defaults)
  home=${rec%%|*}; skills=${rec#*|}
  fakebin="$TMP_ROOT/defaults/fakebin"
  fake_rsync "$fakebin" ok
  out=$(run_sync "$home" "$skills" rsm "$fakebin" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "a remote route with working rsync should succeed, got $rc: $out"
  argv=$(cat "$fakebin/argv.log")
  assert_not_contains "$argv" "--delete" "rsync must never be invoked with --delete"
  assert_contains "$argv" "--exclude=notebooklm/" "default exclusions should exclude notebooklm/"
  assert_contains "$argv" "--exclude=skill-creator/" "default exclusions should exclude skill-creator/"
  assert_contains "$argv" "--exclude=notebooklm-to-skill/" "default exclusions should exclude notebooklm-to-skill/"
  assert_contains "$argv" "--exclude=notebooklm-to-skill-workspace/" "default exclusions should exclude notebooklm-to-skill-workspace/"
  assert_contains "$argv" "--exclude=no-mistakes/" "default exclusions should exclude no-mistakes/ for correctness, not preference"
  assert_contains "$argv" "--exclude=__pycache__" "default exclusions should exclude build residue"
  assert_contains "$argv" "fake-host:.claude/skills/" "rsync should target the registered route's SSH alias"
  pass "a remote route rsyncs with the documented default exclusions and never --delete"
}

test_exclude_file_fully_overrides_default() {
  local rec home skills fakebin out rc argv
  rec=$(new_home override)
  home=${rec%%|*}; skills=${rec#*|}
  fakebin="$TMP_ROOT/override/fakebin"
  fake_rsync "$fakebin" ok
  {
    echo "# a captain-edited exclusion list"
    echo ""
    echo "my-private-skill/"
  } > "$home/config/skill-sync-exclude"
  out=$(run_sync "$home" "$skills" rsm "$fakebin" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "override should still succeed, got $rc: $out"
  argv=$(cat "$fakebin/argv.log")
  assert_contains "$argv" "--exclude=my-private-skill/" "config/skill-sync-exclude should apply the captain's own pattern"
  assert_not_contains "$argv" "--exclude=notebooklm/" "a present config/skill-sync-exclude should fully replace the built-in default, not merge with it"
  pass "config/skill-sync-exclude fully overrides the built-in default exclusion set"
}

test_absent_rsync_fails_without_a_real_transfer() {
  local rec home skills fakebin out rc
  rec=$(new_home absent)
  home=${rec%%|*}; skills=${rec#*|}
  fakebin="$TMP_ROOT/absent/fakebin"
  mkdir -p "$fakebin"
  out=$(run_sync "$home" "$skills" rsm "$fakebin" 2>&1); rc=$?
  [ "$rc" -eq 2 ] || fail "an absent rsync should be a distinct transfer-failure exit, got $rc: $out"
  assert_contains "$out" "rsync is not available" "an absent rsync should say so plainly"
  pass "an absent rsync fails distinctly rather than silently succeeding"
}

test_failing_rsync_reports_failure() {
  local rec home skills fakebin out rc
  rec=$(new_home failing)
  home=${rec%%|*}; skills=${rec#*|}
  fakebin="$TMP_ROOT/failing/fakebin"
  fake_rsync "$fakebin" fail
  out=$(run_sync "$home" "$skills" rsm "$fakebin" 2>&1); rc=$?
  [ "$rc" -eq 2 ] || fail "a failing rsync invocation should exit 2, got $rc: $out"
  assert_contains "$out" "rsync to fake-host failed" "a failing rsync should name the host it failed against"
  pass "a failing rsync invocation is reported as a failure"
}

test_confirmed_noop_is_distinguished_from_a_silent_non_transfer() {
  local rec home skills fakebin out rc
  rec=$(new_home noop)
  home=${rec%%|*}; skills=${rec#*|}
  fakebin="$TMP_ROOT/noop/fakebin"

  fake_rsync "$fakebin" noop
  out=$(run_sync "$home" "$skills" rsm "$fakebin" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "a confirmed zero-file resync is a success, not a failure, got $rc: $out"
  assert_contains "$out" "Number of files transferred: 0" "a confirmed no-op should still surface the real stats block"

  rm -f "$fakebin/argv.log"
  fake_rsync "$fakebin" badflags
  out=$(run_sync "$home" "$skills" rsm "$fakebin" 2>&1); rc=$?
  [ "$rc" -eq 2 ] || fail "an unrecognized-flag usage banner exiting 0 must still be treated as a failure, got $rc: $out"
  assert_contains "$out" "no recognizable transfer summary" "a usage banner with no stats block should be called out as unverified"
  pass "a confirmed no-op transfer is distinguished from an rsync invocation that silently never ran"
}

test_local_route_is_skipped
test_never_passes_delete_and_applies_default_exclusions
test_exclude_file_fully_overrides_default
test_absent_rsync_fails_without_a_real_transfer
test_failing_rsync_reports_failure
test_confirmed_noop_is_distinguished_from_a_silent_non_transfer

echo "ALL TESTS PASSED"
