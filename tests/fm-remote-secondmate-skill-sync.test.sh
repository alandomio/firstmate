#!/usr/bin/env bash
# tests/fm-remote-secondmate-skill-sync.test.sh - integration coverage for the
# skill-sync step bin/fm-spawn.sh runs at the remote secondmate launch
# convergence point (bin/fm-remote-skill-sync.sh).
#
# tests/fm-remote-skill-sync.test.sh already covers that script's own behavior
# directly (route guard, exclusions, --delete, failure detection). This suite
# instead drives the real chain - parent fm-spawn -> fm-on -> the real remote
# entrypoint -> fm-remote-secondmate-control -> the remote host's own fm-spawn -
# against the repo's deterministic SSH boundary and Herdr fixture, the same
# shape tests/fm-remote-secondmate-trace-context.test.sh uses, to prove the
# ONE contract that must hold at the integration point: a skill-sync failure
# warns without ever blocking the secondmate launch, exactly like every other
# inherited-material propagation failure.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/remote-herdr-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-herdr-fixture.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-skill-sync-e2e)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
RSYNCBIN="$TMP_ROOT/rsyncbin"
SKILLS_SOURCE="$TMP_ROOT/skills"
HERDR_LOG="$TMP_ROOT/remote-herdr.log"
HERDR_STATE="$TMP_ROOT/remote-herdr.state"
TMUX_LOG="$TMP_ROOT/remote-tmux.log"
TMUX_STATE="$TMP_ROOT/remote-tmux.state"
CLAIMS="$TMP_ROOT/claims"
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects" "$REMOTE_ROOT" "$CLAIMS" \
  "$RSYNCBIN" "$SKILLS_SOURCE/a-skill"
printf 'a\n' > "$SKILLS_SOURCE/a-skill/SKILL.md"
trap 'FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true; if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then kill "$(cat "$TMP_ROOT/remote-jobs/worker.pid")" 2>/dev/null || true; fi; rm -rf -- "$TMP_ROOT"' EXIT

# The remote host's tracked code root, a real git repository, matching every
# other remote-secondmate suite's fixture.
(
  cd "$ROOT" || exit
  tar --exclude=.git --exclude=.no-mistakes --exclude=data --exclude=state --exclude=config -cf - .
) | (cd "$REMOTE_ROOT" && tar -xf -)

cat > "$REMOTE_ROOT/bin/tmux" <<SH
#!/usr/bin/env bash
set -u
log='$TMUX_LOG'
state='$TMUX_STATE'
printf '%s\n' "\$*" >> "\$log"
case "\${1:-}" in
  has-session|new-session|set-window-option) exit 0 ;;
  list-windows)
    [ -f "\$state" ] || exit 0
    name=\$(cut -d'|' -f1 "\$state")
    case "\$*" in *'#{session_name}:#{window_name}'*) printf 'firstmate:%s\n' "\$name" ;; *) printf '%s\n' "\$name" ;; esac
    exit 0
    ;;
  new-window)
    name=; cwd=
    while [ "\$#" -gt 0 ]; do
      case "\$1" in -n) shift; name=\$1 ;; -c) shift; cwd=\$1 ;; esac
      shift
    done
    printf '%s|%s\n' "\$name" "\$cwd" > "\$state"
    printf '@1\n'
    exit 0
    ;;
  display-message)
    case "\$*" in
      *'#{pane_current_path}'*) cut -d'|' -f2- "\$state" ;;
      *'#{pane_current_command}'*) printf 'codex\n' ;;
      *'#{cursor_y}'*) printf '0\n' ;;
      *'#S'*) printf 'firstmate\n' ;;
      *) printf '%%1\n' ;;
    esac
    exit 0
    ;;
  capture-pane) printf '❯\n'; exit 0 ;;
  send-keys) exit 0 ;;
  kill-window) rm -f -- "\$state"; exit 0 ;;
  list-panes) printf 'codex\n'; exit 0 ;;
esac
exit 0
SH
chmod +x "$REMOTE_ROOT/bin/tmux"
install_remote_herdr_fixture "$REMOTE_ROOT" "$HERDR_STATE" "$HERDR_LOG" \
  "$TMP_ROOT/herdr-send-fail" "$TMP_ROOT/herdr.sock"
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add .
git -C "$REMOTE_ROOT" commit -qm 'remote fixture root'

# fm-remote-skill-sync.sh talks to the remote host with a raw rsync -e ssh
# invocation, never through fm-on's fm-remote-entrypoint.sh protocol, so it is
# faked at the FM_RSYNC_BIN layer rather than through fake-ssh below.
cat > "$RSYNCBIN/rsync" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP_ROOT/rsync-argv.log"
if [ -f "$TMP_ROOT/rsync-should-fail" ]; then
  echo "rsync: connection unexpectedly closed" >&2
  exit 12
fi
cat <<'EOT'
Number of files: 2
Number of files transferred: 2
Total sent: 100 B
Total received: 20 B
EOT
exit 0
SH
chmod +x "$RSYNCBIN/rsync"

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
cd "$FM_FAKE_REMOTE_CWD" || exit 93
if printf '%s' "$4" | base64 --decode 2>/dev/null | tr '\0' '\n' | head -1 | grep -q '^fm-remote-doctor.sh$'; then
  printf 'ok: remote second-mate readiness confirmed on this host\n'
  exit 0
fi
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

printf 'codex\n' > "$PARENT/config/secondmate-harness"
printf 'tmux\n' > "$PARENT/config/backend"
printf 'codex\n' > "$PARENT/config/crew-harness"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$PARENT/data/backlog.md"

remote_env() {
  FM_HOME="$PARENT" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_RSYNC_BIN="$RSYNCBIN/rsync" \
  FM_SKILLS_SOURCE_OVERRIDE="$SKILLS_SOURCE" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_FAKE_REMOTE_CWD="$TMP_ROOT" \
  FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
  "$@"
}

FM_SECONDMATE_CHARTER='Own iOS delivery on the build Mac.' \
  FM_SECONDMATE_SCOPE='iOS implementation and Xcode validation' \
  remote_env "$ROOT/bin/fm-remote-home-seed.sh" ios remote-mac "$REMOTE_ROOT" "$REMOTE_HOME" --no-projects >/dev/null \
  || fail "remote seed did not provision the route under test"

# --- a failing skill sync warns and does not block the launch ---------------
touch "$TMP_ROOT/rsync-should-fail"
OUT=$(remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate 2>&1)
RC=$?
[ "$RC" -eq 0 ] || fail "a remote secondmate launch must succeed even when its skill sync fails (rc=$RC): $OUT"
assert_contains "$OUT" "spawned ios " "a remote launch must still report success when skill sync fails"
assert_contains "$OUT" "SECONDMATE_SYNC: secondmate ios: skipped: skill sync failed on remote-mac" \
  "a failing skill sync must warn using the existing SECONDMATE_SYNC diagnostic convention"
assert_present "$TMP_ROOT/rsync-argv.log" "the launch must actually have attempted the skill sync"
pass "a remote secondmate launch warns on a failing skill sync but is never blocked by it"

# --- a successful skill sync targets the right host and stays quiet ---------
rm -f "$TMP_ROOT/rsync-should-fail" "$TMP_ROOT/rsync-argv.log"
reset_remote_herdr_fixture "$HERDR_STATE"
: > "$HERDR_LOG"
OUT=$(remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate 2>&1)
RC=$?
[ "$RC" -eq 0 ] || fail "a remote secondmate relaunch with a healthy skill sync must succeed (rc=$RC): $OUT"
assert_contains "$OUT" "spawned ios " "a healthy relaunch must report success"
assert_not_contains "$OUT" "SECONDMATE_SYNC: secondmate ios: skipped: skill sync failed" \
  "a healthy skill sync must never emit the failure warning"
assert_contains "$(cat "$TMP_ROOT/rsync-argv.log")" "remote-mac:.claude/skills/" \
  "the skill sync must target this route's own registered SSH alias"
pass "a healthy skill sync targets the route's registered host and reports no warning"

echo "ALL TESTS PASSED"
