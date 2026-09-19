#!/usr/bin/env bash
# Tests for fm-handoff.sh, the opt-in machine handoff through an S3 bucket.
#
# No case reaches AWS. A stub `aws` on PATH maps s3://<bucket>/<key> onto a local
# directory and implements only the calls the script makes (s3 cp, s3 rm, s3 sync,
# ssm send-command, ssm get-command-invocation, ec2 stop-instances). Its ssm
# send-command really runs the requested command against a second local home, so
# the return flow is exercised end to end between two homes: "laptop" and "ec2".
# A stub `ps` names every ancestor a harness so bin/fm-lock.sh can acquire.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HANDOFF="$ROOT/bin/fm-handoff.sh"
TMP_ROOT=$(fm_test_tmproot fm-handoff)
FAKEBIN="$TMP_ROOT/fakebin"
S3ROOT="$TMP_ROOT/s3"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
mkdir -p "$FAKEBIN" "$S3ROOT"
fm_git_identity fmtest fmtest@example.invalid

cat > "$FAKEBIN/aws" <<'SH'
#!/usr/bin/env bash
# Local-directory stand-in for the aws CLI; see the test header.
set -u
root=${FAKE_S3_ROOT:?}
printf '%s\n' "$*" >> "$root/.calls"
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --region|--profile) shift 2 ;;
    --only-show-errors|--delete) args+=("$1"); shift ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]}"
if [ -e "$root/.offline" ]; then
  echo 'Could not connect to the endpoint URL: "https://example.invalid/"' >&2
  exit 255
fi
local_of() { printf '%s/%s\n' "$root" "${1#s3://}"; }
service=$1 op=$2
shift 2
case "$service $op" in
  "s3 cp")
    src=$1 dst=$2
    case "$src" in
      s3://*)
        f=$(local_of "$src")
        if [ ! -f "$f" ]; then
          echo "fatal error: An error occurred (404) when calling the HeadObject operation: Key \"${src#s3://*/}\" does not exist" >&2
          exit 1
        fi
        if [ "$dst" = - ]; then cat "$f"; else cp "$f" "$dst"; fi
        ;;
      *)
        f=$(local_of "$dst")
        mkdir -p "$(dirname "$f")"
        [ ! -e "$root/.fail-lease-write" ] || [ "$(basename "$f")" != lease ] || { echo 'AccessDenied' >&2; exit 1; }
        cp "$src" "$f"
        ;;
    esac
    ;;
  "s3 rm") rm -f "$(local_of "$1")" ;;
  "s3 sync")
    src=$1 dst=$2 delete=0
    shift 2
    for a in "$@"; do [ "$a" = --delete ] && delete=1; done
    [ ! -e "$root/.fail-sync" ] || { echo 'upload failed' >&2; exit 1; }
    case "$src" in s3://*) src=$(local_of "$src") ;; esac
    case "$dst" in s3://*) dst=$(local_of "$dst") ;; esac
    mkdir -p "$src" "$dst"
    if [ "$delete" -eq 1 ]; then
      ( cd "$dst" && find . -type f ) | while IFS= read -r f; do
        [ -e "$src/$f" ] || rm -f "$dst/$f"
      done
    fi
    ( cd "$src" && find . -type f ) | while IFS= read -r f; do
      mkdir -p "$(dirname "$dst/$f")"
      cp -p "$src/$f" "$dst/$f"
    done
    ;;
  "ssm send-command")
    params=
    while [ "$#" -gt 0 ]; do
      case "$1" in --parameters) params=$2; shift 2 ;; *) shift ;; esac
    done
    cmd=$(printf '%s' "$params" | jq -r '.commands[0]')
    cid="cmd-$RANDOM$RANDOM"
    mkdir -p "$root/.ssm"
    printf '%s\n' "$cmd" > "$root/.ssm/$cid.cmd"
    out=$(bash -c "$cmd" 2>"$root/.ssm/$cid.err")
    rc=$?
    status=Success
    [ "$rc" -eq 0 ] || status=Failed
    jq -n --arg s "$status" --arg o "$out" --rawfile e "$root/.ssm/$cid.err" \
      '{Status: $s, StandardOutputContent: $o, StandardErrorContent: $e}' > "$root/.ssm/$cid.json"
    printf '%s\n' "$cid"
    ;;
  "ssm get-command-invocation")
    cid=
    while [ "$#" -gt 0 ]; do
      case "$1" in --command-id) cid=$2; shift 2 ;; *) shift ;; esac
    done
    cat "$root/.ssm/$cid.json"
    ;;
  "ec2 stop-instances") printf '%s\n' "$*" >> "$root/.ec2-stopped" ;;
  *) echo "fake aws: unsupported $service $op" >&2; exit 2 ;;
esac
SH
chmod +x "$FAKEBIN/aws"

# runuser on the fake EC2 side: drop the user switch and the login shell, and the
# caller's home selection, so the command runs in the EC2 home it cds into.
cat > "$FAKEBIN/runuser" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do shift; done
shift
[ "$1" = bash ] && [ "$2" = -lc ] && { shift 2; exec env -u FM_HOME bash -c "$1"; }
exec "$@"
SH
chmod +x "$FAKEBIN/runuser"

# Every process is a harness, so fm-lock.sh finds one in its ancestry.
cat > "$FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
pid=
prev=
for a in "$@"; do [ "$prev" = -p ] && pid=$a; prev=$a; done
case "$*" in
  *comm=*) printf '/usr/local/bin/claude\n' ;;
  *args=*) printf 'claude\n' ;;
  *ppid=*) /bin/ps -o ppid= -p "$pid" ;;
  *) exec /bin/ps "$@" ;;
esac
SH
chmod +x "$FAKEBIN/ps"

export FAKE_S3_ROOT="$S3ROOT"
export PATH="$FAKEBIN:$PATH"
export FM_HANDOFF_SSM_POLL=0

# new_home <name> <machine> [extra config lines...]: a home whose bin/ is this
# repo's bin/, so it can also stand in for the EC2 checkout the SSM command cds to.
new_home() {
  local name=$1 machine=$2 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  ln -s "$ROOT/bin" "$home/bin"
  shift 2
  {
    printf 'bucket=fm-test-bucket\nmachine=%s\n' "$machine"
    for l in "$@"; do printf '%s\n' "$l"; done
  } > "$home/config/handoff-s3"
  printf '%s\n' "$home"
}

hf() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" "$home/bin/fm-handoff.sh" "$@"
}

lock() {  # <home>
  FM_HOME="$1" "$ROOT/bin/fm-lock.sh"
}

reset_bucket() { rm -rf "$S3ROOT"; mkdir -p "$S3ROOT"; }

test_disabled_changes_nothing() {
  local home out
  home="$TMP_ROOT/plain"
  mkdir -p "$home/state" "$home/data" "$home/config"
  out=$(FM_HOME="$home" "$HANDOFF" gate 2>&1) || fail "gate without config should succeed"
  [ -z "$out" ] || fail "gate without config should print nothing, got: $out"
  : > "$home/state/.handoff-refused"
  out=$(lock "$home" 2>&1) || fail "lock without handoff config should ignore a stray refusal record: $out"
  assert_contains "$out" "lock acquired" "lock should be acquired when handoff is disabled"
  FM_HOME="$home" "$HANDOFF" check >/dev/null || fail "check without config should succeed"
  out=$(FM_HOME="$home" "$HANDOFF" prendi 2>&1)
  expect_code 2 "$?" "prendi without config should refuse as not enabled"
  assert_contains "$out" "not enabled" "prendi should say the handoff is not enabled"
  [ ! -e "$S3ROOT/.calls" ] || fail "disabled handoff must never call aws"
  pass "without config/handoff-s3 nothing changes and aws is never called"
}

test_first_prendi_seeds_empty_bucket_and_gate_allows() {
  local home out
  reset_bucket
  home=$(new_home seed laptop)
  printf 'captain notes\n' > "$home/data/captain.md"
  out=$(hf "$home" gate 2>&1)
  expect_code 1 "$?" "gate should refuse when nobody holds the lease"
  assert_contains "$out" "no machine holds the helm" "free lease should be explained"
  assert_contains "$out" "bin/fm-handoff.sh prendi" "free lease should name the command"
  lock "$home" >/dev/null 2>&1 && fail "fm-lock should refuse while the handoff refusal is recorded"
  out=$(hf "$home" prendi 2>&1) || fail "first prendi should seed: $out"
  assert_contains "$out" "seeded the empty bucket" "first prendi should seed from this machine"
  [ -f "$S3ROOT/fm-test-bucket/firstmate/data/captain.md" ] || fail "seed should upload data/"
  assert_grep "machine=laptop" "$S3ROOT/fm-test-bucket/firstmate/lease"
  [ -f "$home/state/handoff-backup.check.sh" ] || fail "prendi should arm the backup check"
  [ -f "$home/state/handoff-backup.check-trust" ] || fail "prendi should register the backup check"
  out=$(hf "$home" gate 2>&1) || fail "gate should allow the lease holder: $out"
  assert_contains "$out" "holds the helm" "gate should say this machine holds the helm"
  out=$(lock "$home" 2>&1) || fail "fm-lock should acquire for the lease holder: $out"
  pass "first prendi seeds an empty bucket, then gate and lock allow this machine"
}

test_consegna_prendi_moves_data_and_foreign_lease_is_read_only() {
  local laptop ec2 out
  reset_bucket
  laptop=$(new_home move-laptop laptop)
  ec2=$(new_home move-ec2 ec2)
  printf 'from laptop\n' > "$laptop/data/backlog.md"
  hf "$laptop" prendi >/dev/null 2>&1 || fail "laptop prendi"
  out=$(hf "$laptop" consegna 2>&1) || fail "consegna with nothing in flight should succeed: $out"
  [ ! -e "$S3ROOT/fm-test-bucket/firstmate/lease" ] || fail "consegna should release the lease"
  [ ! -e "$laptop/state/handoff-backup.check.sh" ] || fail "consegna should disarm the backup"
  lock "$laptop" >/dev/null 2>&1 && fail "after consegna the laptop must not take the session lock"
  assert_grep "handed over the helm" "$S3ROOT/fm-test-bucket/firstmate/data/handoff-log.md"
  out=$(hf "$ec2" prendi 2>&1) || fail "ec2 prendi after consegna should succeed: $out"
  assert_grep "from laptop" "$ec2/data/backlog.md"
  printf 'from ec2\n' >> "$ec2/data/backlog.md"
  hf "$ec2" backup >/dev/null 2>&1 || fail "ec2 backup"
  assert_grep "machine=ec2" "$S3ROOT/fm-test-bucket/firstmate/lease"
  out=$(hf "$laptop" gate 2>&1)
  expect_code 1 "$?" "laptop gate should refuse while ec2 holds the lease"
  assert_contains "$out" "the helm is on machine ec2" "gate should name the holder"
  assert_contains "$out" "last upload of data/:" "gate should give the last upload"
  assert_contains "$out" "by ec2 (backup" "gate should say who uploaded last and why"
  assert_contains "$out" "bin/fm-handoff.sh prendi --force" "gate should give the force command"
  out=$(lock "$laptop" 2>&1)
  expect_code 1 "$?" "fm-lock should refuse on the laptop"
  assert_contains "$out" "operate read-only" "lock refusal should keep the read-only wording"
  assert_contains "$out" "the helm is on machine ec2" "lock refusal should carry the handoff explanation"
  out=$(hf "$laptop" prendi 2>&1)
  expect_code 1 "$?" "prendi should refuse a lease held by another machine"
  assert_contains "$out" "prendi --force" "prendi refusal should name --force"
  pass "consegna and prendi move data/, and a foreign lease keeps the other machine read-only"
}

test_consegna_refuses_in_flight_unless_leave_and_records_backlog() {
  local home out
  reset_bucket
  home=$(new_home inflight laptop)
  printf '# Backlog\n\n## In flight\n\n- [ ] fm-busy - Busy task (repo: firstmate)\n  Original note.\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  hf "$home" prendi >/dev/null 2>&1 || fail "prendi"
  fm_write_meta "$home/state/fm-busy.meta" kind=ship project=/x/firstmate
  fm_write_secondmate_meta "$home/state/sm-one.meta" "$TMP_ROOT/sm"
  out=$(hf "$home" consegna 2>&1)
  expect_code 1 "$?" "consegna should refuse with a task in flight"
  assert_contains "$out" "fm-busy (ship, firstmate)" "consegna should list the in-flight task"
  assert_not_contains "$out" "sm-one" "a persistent secondmate is not an in-flight task"
  [ -e "$S3ROOT/fm-test-bucket/firstmate/lease" ] || fail "a refused consegna must keep the lease"
  out=$(hf "$home" consegna --leave 2>&1) || fail "consegna --leave should hand over: $out"
  [ ! -e "$S3ROOT/fm-test-bucket/firstmate/lease" ] || fail "consegna --leave should release the lease"
  if command -v tasks-axi >/dev/null 2>&1; then
    assert_grep "stays on machine laptop" "$S3ROOT/fm-test-bucket/firstmate/data/backlog.md"
    assert_grep "Original note." "$S3ROOT/fm-test-bucket/firstmate/data/backlog.md"
  fi
  assert_grep "task(s) left in flight on it: fm-busy" "$S3ROOT/fm-test-bucket/firstmate/data/handoff-log.md"
  pass "consegna refuses with tasks in flight, and --leave records where each one stays"
}

test_forced_takeover_records_it_and_returning_machine_keeps_its_changes() {
  local laptop ec2 out saved
  reset_bucket
  laptop=$(new_home force-laptop laptop)
  ec2=$(new_home force-ec2 ec2)
  printf 'base\n' > "$laptop/data/captain.md"
  hf "$laptop" prendi >/dev/null 2>&1 || fail "laptop prendi"
  # The laptop keeps working and never hands over.
  printf 'unuploaded laptop edit\n' >> "$laptop/data/captain.md"
  out=$(hf "$ec2" prendi --force 2>&1) || fail "forced prendi should succeed: $out"
  assert_contains "$out" "recorded the forced takeover" "forced prendi should say it recorded the takeover"
  assert_grep "FORCED takeover by ec2 from laptop" "$ec2/data/handoff-log.md"
  assert_grep "started from upload" "$ec2/data/handoff-log.md"
  hf "$ec2" backup >/dev/null 2>&1 || fail "ec2 backup"
  out=$(hf "$laptop" gate 2>&1)
  expect_code 1 "$?" "the returning laptop should start read-only"
  assert_contains "$out" "forced from laptop" "gate should say the lease was forced"
  assert_contains "$out" "1 local data/ change(s) not uploaded" "gate should count the unuploaded change"
  out=$(hf "$laptop" diff 2>&1) || fail "diff should run: $out"
  assert_contains "$out" "modified: captain.md" "diff should list the unuploaded change"
  hf "$ec2" consegna >/dev/null 2>&1 || fail "ec2 consegna"
  out=$(hf "$laptop" prendi 2>&1)
  expect_code 1 "$?" "prendi must not overwrite unuploaded local changes silently"
  assert_contains "$out" "modified: captain.md" "prendi refusal should list the change"
  assert_grep "unuploaded laptop edit" "$laptop/data/captain.md"
  out=$(hf "$laptop" prendi --replace-local 2>&1) || fail "prendi --replace-local should succeed: $out"
  assert_no_grep "unuploaded laptop edit" "$laptop/data/captain.md"
  saved=$(find "$laptop/state/handoff-backups" -name captain.md | head -1)
  [ -n "$saved" ] || fail "the replaced local copy should be saved"
  assert_grep "unuploaded laptop edit" "$saved"
  pass "a forced takeover is recorded and the returning machine's changes are never overwritten silently"
}

test_backup_check_uploads_when_due_and_detects_lost_lease() {
  local laptop ec2 out calls
  reset_bucket
  laptop=$(new_home check-laptop laptop)
  ec2=$(new_home check-ec2 ec2)
  printf 'one\n' > "$laptop/data/notes.md"
  hf "$laptop" prendi >/dev/null 2>&1 || fail "prendi"
  out=$(hf "$laptop" check 2>&1)
  [ -z "$out" ] || fail "check with nothing changed should be silent: $out"
  printf 'two\n' >> "$laptop/data/notes.md"
  calls=$(wc -l < "$S3ROOT/.calls")
  out=$(hf "$laptop" check 2>&1)
  [ -z "$out" ] || fail "check before the interval should be silent: $out"
  [ "$(wc -l < "$S3ROOT/.calls")" -eq "$calls" ] || fail "check before the interval should not touch the bucket"
  printf 'task\n' > "$laptop/data/backlog.md"
  out=$(hf "$laptop" check 2>&1)
  [ -z "$out" ] || fail "a successful backup should be silent: $out"
  assert_grep "two" "$S3ROOT/fm-test-bucket/firstmate/data/notes.md"
  assert_grep "machine=laptop" "$S3ROOT/fm-test-bucket/firstmate/lease"
  printf 'three\n' >> "$laptop/data/notes.md"
  out=$(FM_HANDOFF_BACKUP_INTERVAL=1 FM_HOME="$laptop" "$HANDOFF" check 2>&1)
  sleep 1
  out=$(FM_HANDOFF_BACKUP_INTERVAL=1 FM_HOME="$laptop" "$HANDOFF" check 2>&1)
  [ -z "$out" ] || fail "an interval backup should be silent: $out"
  assert_grep "three" "$S3ROOT/fm-test-bucket/firstmate/data/notes.md"
  hf "$ec2" prendi --force >/dev/null 2>&1 || fail "ec2 force"
  printf 'more\n' > "$laptop/data/backlog.md"
  out=$(hf "$laptop" check 2>&1)
  assert_contains "$out" "lost the helm to ec2" "check should report the lost lease"
  out=$(hf "$laptop" check 2>&1)
  [ -z "$out" ] || fail "the same problem should be reported once: $out"
  assert_no_grep "more" "$S3ROOT/fm-test-bucket/firstmate/data/backlog.md"
  lock "$laptop" >/dev/null 2>&1 && fail "after losing the lease fm-lock must refuse"
  pass "the backup check uploads after backlog changes or the interval, and stops on a lost lease"
}

test_unreachable_bucket_allows_only_the_last_holder() {
  local laptop other out
  reset_bucket
  laptop=$(new_home offline-laptop laptop)
  other=$(new_home offline-other ec2)
  hf "$laptop" prendi >/dev/null 2>&1 || fail "prendi"
  : > "$S3ROOT/.offline"
  out=$(hf "$laptop" gate 2>&1) || fail "the last holder should proceed offline: $out"
  assert_contains "$out" "WARNING" "offline gate should warn"
  out=$(hf "$other" gate 2>&1)
  expect_code 1 "$?" "a machine that never took the lease must stay read-only offline"
  assert_contains "$out" "could not be read" "offline refusal should say why"
  rm -f "$S3ROOT/.offline"
  printf 'bucket=Not_A_Bucket\nmachine=laptop\n' > "$laptop/config/handoff-s3"
  out=$(hf "$laptop" gate 2>&1)
  expect_code 1 "$?" "an unusable config should refuse"
  lock "$laptop" >/dev/null 2>&1 && fail "an unusable config must keep fm-lock refusing"
  pass "an unreachable bucket allows only the last holder, and a bad config refuses"
}

test_idle_probe() {
  local home out
  home=$(new_home idle ec2)
  touch -t 202001010000 "$home/data" "$home/data/." 2>/dev/null
  out=$(hf "$home" idle --minutes 1 2>&1) || fail "an empty old home should be idle: $out"
  assert_contains "$out" "idle:" "idle should say idle"
  fm_write_meta "$home/state/t1.meta" kind=ship
  out=$(hf "$home" idle --minutes 1 2>&1)
  expect_code 1 "$?" "a task in flight is busy"
  assert_contains "$out" "task(s) in flight" "busy reason should name tasks"
  rm -f "$home/state/t1.meta"
  printf 'x\n' > "$home/state/.wake-queue"
  out=$(hf "$home" idle --minutes 1 2>&1)
  expect_code 1 "$?" "queued wakes are busy"
  : > "$home/state/.wake-queue"
  touch -t 202001010000 "$home/state/.wake-queue"
  mkdir -p "$home/state/inbox"
  printf 'note\n' > "$home/state/inbox/n1"
  out=$(hf "$home" idle --minutes 1 2>&1)
  expect_code 1 "$?" "a pending inbox note is busy"
  rm -f "$home/state/inbox/n1"
  printf 'fresh\n' > "$home/data/fresh.md"
  out=$(hf "$home" idle --minutes 1 2>&1)
  expect_code 1 "$?" "recent data/ activity is busy"
  assert_contains "$out" "activity in the last 1 minute" "busy reason should name activity"
  touch -t 202001010000 "$home/data/fresh.md" "$home/data"
  mkdir -p "$TMP_ROOT/activity"
  printf 'idle_activity=%s\n' "$TMP_ROOT/activity" >> "$home/config/handoff-s3"
  printf 'x\n' > "$TMP_ROOT/activity/session.jsonl"
  out=$(hf "$home" idle --minutes 1 2>&1)
  expect_code 1 "$?" "a configured idle_activity path is busy"
  pass "the idle probe reports tasks, wakes, inbox notes, and recent activity as busy"
}

test_riprendi_runs_consegna_on_ec2_then_prendi_then_stops() {
  local laptop ec2 out
  reset_bucket
  ec2=$(new_home rip-ec2 ec2)
  laptop=$(new_home rip-laptop laptop ec2_instance_id=i-0123 ec2_machine=ec2 "ec2_home=$TMP_ROOT/rip-ec2" ec2_user=firstmate)
  printf 'ec2 work\n' > "$ec2/data/backlog.md"
  hf "$ec2" prendi >/dev/null 2>&1 || fail "ec2 prendi"
  out=$(hf "$laptop" gate 2>&1)
  assert_contains "$out" "bin/fm-handoff.sh riprendi" "gate should offer riprendi when EC2 holds the lease"
  fm_write_meta "$ec2/state/ec2-task.meta" kind=scout project=/x/aws-goplanner
  out=$(hf "$laptop" riprendi 2>&1)
  expect_code 1 "$?" "riprendi should stop when EC2 has tasks in flight"
  assert_contains "$out" "ec2-task (scout, aws-goplanner)" "riprendi should list the EC2 tasks first"
  assert_grep "machine=ec2" "$S3ROOT/fm-test-bucket/firstmate/lease"
  [ ! -e "$S3ROOT/.ec2-stopped" ] || fail "a refused riprendi must not stop the instance"
  rm -f "$ec2/state/ec2-task.meta"
  out=$(hf "$laptop" riprendi 2>&1) || fail "riprendi should succeed: $out"
  assert_grep "machine=laptop" "$S3ROOT/fm-test-bucket/firstmate/lease"
  assert_grep "ec2 work" "$laptop/data/backlog.md"
  assert_grep "i-0123" "$S3ROOT/.ec2-stopped"
  grep -q 'runuser -u firstmate' "$S3ROOT"/.ssm/*.cmd || fail "the SSM command should run as ec2_user"
  out=$(hf "$laptop" gate 2>&1) || fail "the laptop should hold the helm after riprendi: $out"
  pass "riprendi lists EC2 tasks, hands over on EC2 through SSM, takes the helm here, and stops EC2"
}

test_session_start_lands_in_existing_read_only_mode() {
  local laptop ec2 root out
  reset_bucket
  laptop=$(new_home ss-laptop laptop)
  ec2=$(new_home ss-ec2 ec2)
  hf "$ec2" prendi >/dev/null 2>&1 || fail "ec2 prendi"
  root="$TMP_ROOT/ss-root"
  git init -q -b main "$root"
  git -C "$root" commit -q --allow-empty -m init
  out=$(env -u CLAUDECODE FM_HOME="$laptop" FM_ROOT_OVERRIDE="$root" FM_SESSION_START_TIMEOUT=60 \
    "$ROOT/bin/fm-session-start.sh" 2>&1)
  assert_contains "$out" "READ-ONLY SESSION - FLEET LOCK OWNERSHIP WAS NOT VERIFIED" "session start should use the existing read-only banner"
  assert_contains "$out" "the helm is on machine ec2" "the banner should carry the handoff explanation"
  assert_contains "$out" "prendi --force" "the banner should give the force command"
  [ ! -e "$laptop/state/.lock" ] || fail "a refused session must not write the session lock"
  pass "session start on a machine without the lease lands in the existing read-only mode"
}

test_disabled_changes_nothing
test_first_prendi_seeds_empty_bucket_and_gate_allows
test_consegna_prendi_moves_data_and_foreign_lease_is_read_only
test_consegna_refuses_in_flight_unless_leave_and_records_backlog
test_forced_takeover_records_it_and_returning_machine_keeps_its_changes
test_backup_check_uploads_when_due_and_detects_lost_lease
test_unreachable_bucket_allows_only_the_last_holder
test_idle_probe
test_riprendi_runs_consegna_on_ec2_then_prendi_then_stops
test_session_start_lands_in_existing_read_only_mode
