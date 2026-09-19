#!/usr/bin/env bash
# fm-handoff.sh - move ONE firstmate home between machines through an S3 bucket,
# never active in two places at once.
#
# OPT-IN. Nothing here does anything unless the local, gitignored
# config/handoff-s3 exists; docs/configuration.md "Machine handoff" owns that
# file's schema and the operator-facing contract. Without it `gate`, `check`,
# and `idle` succeed silently, and every other action refuses as not enabled.
#
# What moves: ONLY data/. state/, projects/, and config/ never leave the machine.
# The bucket holds three things under s3://<bucket>/<prefix>/:
#   lease         "active here": which machine holds the helm (absent = nobody)
#   last-upload   which machine uploaded data/ last, when, and why
#   data/         the synced copy of data/ (aws s3 sync --delete; the bucket is
#                 versioned, so a deletion or an overwrite is recoverable there)
#
# Usage:
#   fm-handoff.sh status                 lease, last upload, local unuploaded changes
#   fm-handoff.sh gate                   session-start lease verdict (see below)
#   fm-handoff.sh prendi [--force] [--replace-local]
#                                        take the helm: take the lease, download data/
#   fm-handoff.sh consegna [--leave]     hand over: upload data/, release the lease
#   fm-handoff.sh backup                 upload data/ now, keeping the lease
#   fm-handoff.sh check                  watcher entry: backup when due, silent otherwise
#   fm-handoff.sh arm | disarm           register or remove the watcher backup check
#   fm-handoff.sh diff                   local unuploaded changes, then local vs bucket
#   fm-handoff.sh inflight               list this home's in-flight tasks
#   fm-handoff.sh idle [--minutes N]     exit 0 when idle for N minutes (default 120)
#   fm-handoff.sh riprendi [--leave] [--replace-local]
#                                        return flow: consegna on EC2 via SSM,
#                                        prendi here, stop the EC2 instance
#
# THE LEASE AND THE SESSION LOCK. `gate` runs inside bin/fm-session-start.sh's
# lock stage, before bin/fm-lock.sh. It reads the lease and records its verdict
# in state/.handoff-refused: present means "this machine does not hold the helm"
# and carries the explanation. bin/fm-lock.sh refuses to acquire while that file
# exists and config/handoff-s3 is present, so the session lands in the EXISTING
# lock-refused read-only mode - there is no second read-only mode - and every
# other lock claimant (the Stop auto-arm's stale-lock recovery included) is
# refused the same way without a network call.
# Verdicts:
#   this machine holds the lease (machine and nonce match state/.handoff-held)
#       -> allowed; the marker is cleared.
#   another machine holds it, nobody holds it, or it names this machine with a
#   nonce this home never took
#       -> refused, with the holder, the last upload, this machine's unuploaded
#          data/ changes, and the exact commands that end the refusal.
#   the bucket cannot be read
#       -> allowed only when this home's own record says it took the lease and
#          never released it (the laptop working offline); refused otherwise.
#
# prendi takes the lease BEFORE downloading, so a crash in between leaves this
# home refused rather than working on stale data; rerunning prendi finishes.
# Before replacing data/ it compares data/ with the manifest recorded at this
# machine's last sync, and refuses when there are unuploaded local changes
# unless --replace-local is given. Every download first copies the current
# data/ to state/handoff-backups/<stamp>/, so --replace-local sets the local
# copy aside for merging rather than discarding it. A bucket that has never
# received an upload seeds from this machine instead of downloading.
# --force takes the lease from another machine and appends the forced takeover
# and the upload it started from to data/handoff-log.md.
#
# consegna refuses while tasks are in flight (a state/<id>.meta other than a
# secondmate) unless --leave, which records on each in-flight backlog item that
# it stays on this machine (through tasks-axi when available) and in
# data/handoff-log.md. It then uploads, deletes the lease if it is still this
# machine's, writes the refusal marker, and disarms the backup check. The session
# that ran it keeps its lock file but must stop mutating.
#
# BACKUP. `arm` writes state/handoff-backup.check.sh and binds it with
# bin/fm-check-register.sh, the same trusted-check path bin/fm-tool-update-check.sh
# uses, so the watcher runs `check` every FM_CHECK_INTERVAL while supervision is
# live. `check` uploads when data/ differs from the last sync AND either
# data/backlog.md changed or FM_HANDOFF_BACKUP_INTERVAL (default 900) seconds have
# passed since the last upload. It never releases the lease, and it verifies the
# lease is still this machine's before uploading: a lost lease writes the refusal
# marker and prints one line so the watcher wakes firstmate. It prints only when
# something needs attention, and repeats the same problem at most once.
# prendi arms the check and consegna disarms it.
#
# idle is the EC2 idle-shutdown probe: busy while any in-flight task (a
# state/<id>.meta other than a secondmate), registered process-event source, queued wake, pending captain inbox note, or pending Relay
# mention exists, or while anything under data/, a state/<id>.status log, the wake
# queue, or a configured idle_activity path changed in the last N minutes.
# Exit 0 prints "idle: ...", exit 1 prints "busy: <reason>".
#
# riprendi is captain-authorized per occasion: firstmate runs it only on the
# captain's explicit word. It needs ec2_instance_id, ec2_machine, ec2_home, and
# ec2_user in config. It lists the EC2 home's in-flight tasks first (through SSM
# `inflight`) and stops when there are any unless --leave, then runs `consegna`
# there through SSM, `prendi` here, and `aws ec2 stop-instances`.
#
# Exit codes: 0 success/allowed/idle, 1 refused/failed/busy, 2 usage or not enabled.
#
# Environment:
#   FM_HANDOFF_AWS              aws CLI command (default aws; tests stub it)
#   FM_HANDOFF_TIMEOUT          seconds per small S3 call (default 15)
#   FM_HANDOFF_SYNC_TIMEOUT     seconds per data/ sync (default 120; `check` caps
#                               it to fit FM_CHECK_TIMEOUT)
#   FM_HANDOFF_BACKUP_INTERVAL  seconds between periodic backups (default 900)
#   FM_HANDOFF_SSM_TIMEOUT      seconds to wait for one SSM command (default 600)
#   FM_HANDOFF_BACKUPS_KEEP     local pre-download copies kept (default 5)
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CONFIG_FILE="$CONFIG_DIR/handoff-s3"

HELD="$STATE/.handoff-held"
REFUSED="$STATE/.handoff-refused"
MANIFEST="$STATE/.handoff-manifest"
LAST_UPLOAD_EPOCH="$STATE/.handoff-last-upload"
REPORTED="$STATE/.handoff-backup-report"
OP_LOCK="$STATE/.handoff.lock"
BACKUPS="$STATE/handoff-backups"
CHECK_ID=handoff-backup
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
HANDOFF_LOG="$DATA/handoff-log.md"

AWS_CMD=${FM_HANDOFF_AWS:-aws}
SMALL_TIMEOUT=${FM_HANDOFF_TIMEOUT:-15}
SYNC_TIMEOUT=${FM_HANDOFF_SYNC_TIMEOUT:-120}
BACKUP_INTERVAL=${FM_HANDOFF_BACKUP_INTERVAL:-900}
SSM_TIMEOUT=${FM_HANDOFF_SSM_TIMEOUT:-600}
BACKUPS_KEEP=${FM_HANDOFF_BACKUPS_KEEP:-5}

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  sed -n '2,/^set -u$/p' "$SCRIPT_DIR/fm-handoff.sh" | sed 's/^# \{0,1\}//; $d'
}

die() { printf 'fm-handoff: %s\n' "$*" >&2; exit 1; }
die_usage() { printf 'fm-handoff: %s\n' "$*" >&2; exit 2; }

positive_int() {  # <name> <value>
  case "$2" in ''|*[!0-9]*|0) die_usage "$1 must be a positive whole number, got '$2'" ;; esac
}
positive_int FM_HANDOFF_TIMEOUT "$SMALL_TIMEOUT"
positive_int FM_HANDOFF_SYNC_TIMEOUT "$SYNC_TIMEOUT"
positive_int FM_HANDOFF_BACKUP_INTERVAL "$BACKUP_INTERVAL"
positive_int FM_HANDOFF_SSM_TIMEOUT "$SSM_TIMEOUT"
positive_int FM_HANDOFF_BACKUPS_KEEP "$BACKUPS_KEEP"

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_epoch() { date +%s; }

random_token() {
  local t
  t=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  [ -n "$t" ] || t="$$$(now_epoch)$RANDOM"
  printf '%s\n' "$t"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# --- config -----------------------------------------------------------------

CFG_BUCKET='' CFG_MACHINE='' CFG_PREFIX=firstmate CFG_REGION='' CFG_PROFILE=''
CFG_EC2_INSTANCE='' CFG_EC2_MACHINE='' CFG_EC2_HOME='' CFG_EC2_USER=''
CFG_IDLE_ACTIVITY=()

enabled() { [ -f "$CONFIG_FILE" ]; }

load_config() {
  local line key value n=0
  [ -f "$CONFIG_FILE" ] || die_usage "machine handoff is not enabled (no $CONFIG_FILE; see docs/configuration.md \"Machine handoff\")"
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line%$'\r'}
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) die "config/handoff-s3 line $n is not key=value: $line" ;; esac
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      bucket) CFG_BUCKET=$value ;;
      machine) CFG_MACHINE=$value ;;
      prefix) CFG_PREFIX=$value ;;
      region) CFG_REGION=$value ;;
      profile) CFG_PROFILE=$value ;;
      ec2_instance_id) CFG_EC2_INSTANCE=$value ;;
      ec2_machine) CFG_EC2_MACHINE=$value ;;
      ec2_home) CFG_EC2_HOME=$value ;;
      ec2_user) CFG_EC2_USER=$value ;;
      idle_activity) CFG_IDLE_ACTIVITY+=("$value") ;;
      *) die "config/handoff-s3 line $n has unknown key '$key'" ;;
    esac
  done < "$CONFIG_FILE"
  [[ "$CFG_BUCKET" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || die "config/handoff-s3 needs a valid bucket= (got '$CFG_BUCKET')"
  [[ "$CFG_MACHINE" =~ ^[A-Za-z0-9._-]+$ ]] || die "config/handoff-s3 needs machine= made of letters, digits, dot, dash, underscore (got '$CFG_MACHINE')"
  [[ "$CFG_PREFIX" =~ ^[A-Za-z0-9._/-]+$ ]] || die "config/handoff-s3 prefix= is invalid (got '$CFG_PREFIX')"
  CFG_PREFIX=${CFG_PREFIX%/}
  [ -z "$CFG_EC2_MACHINE" ] || [[ "$CFG_EC2_MACHINE" =~ ^[A-Za-z0-9._-]+$ ]] || die "config/handoff-s3 ec2_machine= is invalid"
  S3_BASE="s3://$CFG_BUCKET/$CFG_PREFIX"
}

aws_run() {  # <timeout> <aws args...>
  local t=$1
  shift
  local extra=()
  [ -z "$CFG_REGION" ] || extra+=(--region "$CFG_REGION")
  [ -z "$CFG_PROFILE" ] || extra+=(--profile "$CFG_PROFILE")
  fm_run_timed "$t" "$AWS_CMD" ${extra[@]+"${extra[@]}"} "$@"
}

# --- small S3 objects ---------------------------------------------------------

S3_OBJ_BODY=
S3_OBJ_ERR=
# s3_read <name>: 0 read into S3_OBJ_BODY, 3 absent, 1 unreachable (S3_OBJ_ERR).
s3_read() {
  local errf rc
  errf=$(mktemp "${TMPDIR:-/tmp}/fm-handoff-err.XXXXXX") || return 1
  S3_OBJ_BODY=$(aws_run "$SMALL_TIMEOUT" s3 cp "$S3_BASE/$1" - 2>"$errf")
  rc=$?
  S3_OBJ_ERR=$(tr '\n' ' ' < "$errf" | cut -c1-300)
  rm -f "$errf"
  [ "$rc" -eq 0 ] && return 0
  [ "$rc" -eq 124 ] && { S3_OBJ_ERR="timed out after ${SMALL_TIMEOUT}s"; return 1; }
  case "$S3_OBJ_ERR" in
    *'(404)'*|*NoSuchKey*|*'Not Found'*|*'does not exist'*) return 3 ;;
  esac
  [ -n "$S3_OBJ_ERR" ] || S3_OBJ_ERR="aws exited $rc"
  return 1
}

s3_write() {  # <name> <content>
  local tmp rc
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-handoff-obj.XXXXXX") || return 1
  printf '%s\n' "$2" > "$tmp"
  aws_run "$SMALL_TIMEOUT" s3 cp "$tmp" "$S3_BASE/$1" --only-show-errors >/dev/null
  rc=$?
  rm -f "$tmp"
  return "$rc"
}

s3_delete() { aws_run "$SMALL_TIMEOUT" s3 rm "$S3_BASE/$1" --only-show-errors >/dev/null; }

field() {  # <text> <key>
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1
}

# LEASE_STATE: ours | foreign | free | unknown ; plus LEASE_* fields.
LEASE_STATE='' LEASE_MACHINE='' LEASE_NONCE='' LEASE_TAKEN='' LEASE_FORCED='' LEASE_ERR=''
read_lease() {
  local rc
  LEASE_MACHINE='' LEASE_NONCE='' LEASE_TAKEN='' LEASE_FORCED='' LEASE_ERR=''
  s3_read lease
  rc=$?
  case "$rc" in
    0)
      if [ "$(printf '%s\n' "$S3_OBJ_BODY" | head -1)" != fm-handoff-lease-v1 ]; then
        LEASE_STATE=unknown
        LEASE_ERR="the lease object is not a fm-handoff-lease-v1 record"
        return 0
      fi
      LEASE_MACHINE=$(field "$S3_OBJ_BODY" machine)
      LEASE_NONCE=$(field "$S3_OBJ_BODY" nonce)
      LEASE_TAKEN=$(field "$S3_OBJ_BODY" taken_at)
      LEASE_FORCED=$(field "$S3_OBJ_BODY" forced_from)
      if [ "$LEASE_MACHINE" = "$CFG_MACHINE" ] && [ -n "$LEASE_NONCE" ] \
        && [ "$LEASE_NONCE" = "$(held_field nonce)" ]; then
        LEASE_STATE=ours
      else
        LEASE_STATE=foreign
      fi
      ;;
    3) LEASE_STATE=free ;;
    *) LEASE_STATE=unknown; LEASE_ERR=$S3_OBJ_ERR ;;
  esac
}

UPLOAD_ID='' UPLOAD_MACHINE='' UPLOAD_AT='' UPLOAD_KIND='' UPLOAD_STATE=''
read_last_upload() {
  local rc
  UPLOAD_ID='' UPLOAD_MACHINE='' UPLOAD_AT='' UPLOAD_KIND=''
  s3_read last-upload
  rc=$?
  case "$rc" in
    0)
      UPLOAD_STATE=present
      UPLOAD_ID=$(field "$S3_OBJ_BODY" id)
      UPLOAD_MACHINE=$(field "$S3_OBJ_BODY" machine)
      UPLOAD_AT=$(field "$S3_OBJ_BODY" at)
      UPLOAD_KIND=$(field "$S3_OBJ_BODY" kind)
      ;;
    3) UPLOAD_STATE=absent ;;
    *) UPLOAD_STATE=unknown ;;
  esac
}

upload_desc() {
  case "$UPLOAD_STATE" in
    present) printf '%s by %s (%s, upload %s)' "$UPLOAD_AT" "$UPLOAD_MACHINE" "$UPLOAD_KIND" "$UPLOAD_ID" ;;
    absent) printf 'never (the bucket has no upload yet)' ;;
    *) printf 'unknown (the upload record could not be read)' ;;
  esac
}

# --- local records ---------------------------------------------------------------

held_field() { [ -f "$HELD" ] && sed -n "s/^$1=//p" "$HELD" | head -1; }

write_held() {  # <status> <nonce>
  local tmp
  tmp=$(mktemp "$STATE/.handoff-held.XXXXXX") || return 1
  printf 'machine=%s\nnonce=%s\nstatus=%s\nat=%s\n' "$CFG_MACHINE" "$2" "$1" "$(now_iso)" > "$tmp" \
    && mv -f "$tmp" "$HELD"
}

write_refused() {  # <text>
  local tmp
  tmp=$(mktemp "$STATE/.handoff-refused.XXXXXX") || return 1
  printf '%s\n' "$1" > "$tmp" && mv -f "$tmp" "$REFUSED"
}

clear_refused() { rm -f "$REFUSED"; }

# require_held: the lease reads as ours AND this home's prendi finished, so its
# data/ is the bucket's latest and may be uploaded over it.
require_held() {  # <what>
  case "$LEASE_STATE" in
    ours) ;;
    unknown) die "cannot read the lease ($LEASE_ERR); nothing $1" ;;
    *) die "refused: this machine does not hold the lease (${LEASE_MACHINE:-$LEASE_STATE}); nothing $1" ;;
  esac
  [ "$(held_field status)" = held ] \
    || die "refused: this machine took the lease but prendi never finished bringing data/ up to date; nothing $1 - rerun bin/fm-handoff.sh prendi"
}

# manifest_of <dir>: "<sha256>  <relative path>" for every regular file, sorted.
manifest_of() {
  local dir=$1 f
  [ -d "$dir" ] || return 0
  (
    cd "$dir" || exit 1
    find . -type f -print | sed 's|^\./||' | sort | while IFS= read -r f; do
      printf '%s  %s\n' "$(sha256_file "$f")" "$f"
    done
  )
}

record_manifest() {  # <upload-id>
  local tmp
  tmp=$(mktemp "$STATE/.handoff-manifest.XXXXXX") || return 1
  { printf 'upload_id=%s\n' "$1"; manifest_of "$DATA"; } > "$tmp" && mv -f "$tmp" "$MANIFEST"
}

# local_changes: lines "added|modified|deleted: <path>" for data/ against the
# manifest of this machine's last sync. With no manifest, every file is added.
local_changes() {
  local current recorded
  current=$(manifest_of "$DATA")
  recorded=
  [ -f "$MANIFEST" ] && recorded=$(sed '1{/^upload_id=/d;}' "$MANIFEST")
  awk -v rec="$recorded" '
    BEGIN {
      n = split(rec, lines, "\n")
      for (i = 1; i <= n; i++) {
        if (lines[i] == "") continue
        h = substr(lines[i], 1, 64); p = substr(lines[i], 67)
        old[p] = h
      }
    }
    $0 != "" {
      h = substr($0, 1, 64); p = substr($0, 67)
      seen[p] = 1
      if (!(p in old)) print "added: " p
      else if (old[p] != h) print "modified: " p
    }
    END { for (p in old) if (!(p in seen)) print "deleted: " p }
  ' <<< "$current" | sort -t: -k2
}

append_log() {  # <line>
  mkdir -p "$DATA" || return 1
  if [ ! -f "$HANDOFF_LOG" ]; then
    printf '# Machine handoff log\n\nWritten by bin/fm-handoff.sh; one line per handoff event.\n\n' > "$HANDOFF_LOG" || return 1
  fi
  printf -- '- %s\n' "$1" >> "$HANDOFF_LOG"
}

# in-flight tasks: every state/<id>.meta except persistent secondmates.
inflight_ids() {
  local meta id
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    grep -qx 'kind=secondmate' "$meta" 2>/dev/null && continue
    id=$(basename "$meta" .meta)
    printf '%s\n' "$id"
  done
}

describe_task() {  # <id>
  local meta="$STATE/$1.meta" kind project
  kind=$(sed -n 's/^kind=//p' "$meta" | head -1)
  project=$(sed -n 's/^project=//p' "$meta" | head -1)
  printf '%s (%s%s)' "$1" "${kind:-ship}" "${project:+, $(basename "$project")}"
}

# --- op lock -------------------------------------------------------------------

OP_LOCK_HELD=0
op_lock() {
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  if [ "${1:-}" = try ]; then
    fm_lock_try_acquire "$OP_LOCK" || return 1
  else
    fm_lock_acquire_wait "$OP_LOCK" || die "cannot take the handoff operation lock"
  fi
  OP_LOCK_HELD=1
}
op_unlock() {
  if [ "$OP_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$OP_LOCK" || true
    OP_LOCK_HELD=0
  fi
}
trap op_unlock EXIT
trap 'exit 1' HUP INT TERM

# --- upload / download ----------------------------------------------------------

# upload <kind> [sync-timeout]: sync data/ up, then publish the last-upload record.
UPLOADED_ID=
upload() {
  local kind=$1 t=${2:-$SYNC_TIMEOUT} id at
  mkdir -p "$DATA" || return 1
  id="$(date -u +%Y%m%dT%H%M%SZ)-$CFG_MACHINE-$(random_token | cut -c1-6)"
  at=$(now_iso)
  aws_run "$t" s3 sync "$DATA/" "$S3_BASE/data/" --delete --only-show-errors >/dev/null || return 1
  s3_write last-upload "$(printf 'fm-handoff-upload-v1\nid=%s\nmachine=%s\nat=%s\nkind=%s' "$id" "$CFG_MACHINE" "$at" "$kind")" || return 1
  record_manifest "$id" || return 1
  now_epoch > "$LAST_UPLOAD_EPOCH"
  rm -f "$REPORTED"
  UPLOADED_ID=$id
}

prune_backups() {
  local n
  [ -d "$BACKUPS" ] || return 0
  n=$(find "$BACKUPS" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  [ "$n" -gt "$BACKUPS_KEEP" ] || return 0
  find "$BACKUPS" -mindepth 1 -maxdepth 1 -type d | sort | head -n $((n - BACKUPS_KEEP)) | while IFS= read -r d; do
    rm -rf -- "$d"
  done
}

# download: sync the bucket's data/ into a fresh staging dir, copy the current
# data/ aside, then swap. Prints the saved copy's path in SAVED_COPY.
SAVED_COPY=
download() {
  local staging stamp
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  if [ -L "$DATA" ]; then
    printf 'fm-handoff: data/ is a symlink; refusing to replace it\n' >&2
    return 1
  fi
  staging="$STATE/.handoff-staging.$$"
  rm -rf -- "$staging"
  mkdir -p "$staging" "$BACKUPS" || return 1
  if ! aws_run "$SYNC_TIMEOUT" s3 sync "$S3_BASE/data/" "$staging/" --delete --only-show-errors >/dev/null; then
    rm -rf -- "$staging"
    return 1
  fi
  SAVED_COPY=
  if [ -d "$DATA" ]; then
    SAVED_COPY="$BACKUPS/$stamp"
    rm -rf -- "$SAVED_COPY"
    cp -Rp "$DATA" "$SAVED_COPY" || { rm -rf -- "$staging"; return 1; }
    rm -rf -- "$DATA" || { rm -rf -- "$staging"; return 1; }
  fi
  if ! mv "$staging" "$DATA"; then
    [ -z "$SAVED_COPY" ] || cp -Rp "$SAVED_COPY" "$DATA"
    return 1
  fi
  prune_backups
}

# --- check shim -------------------------------------------------------------------

shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-handoff.sh - periodic data/ backup to the handoff bucket.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-handoff.sh") check"
}

action_arm() {
  local home tmp
  home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || die "cannot resolve FM_HOME $FM_HOME"
  mkdir -p "$STATE" || return 1
  [ ! -L "$CHECK_SHIM" ] || die "refusing to write through a symlink at $CHECK_SHIM"
  tmp=$(umask 077; mktemp "$STATE/.fm-handoff-check.XXXXXX") || return 1
  if ! shim_content "$home" > "$tmp" || ! chmod 0700 "$tmp" || ! mv -f "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    die "could not write $CHECK_SHIM"
  fi
  if ! FM_HOME="$home" "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" >/dev/null; then
    rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
    die "could not register $CHECK_SHIM, so the periodic backup is not armed"
  fi
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

action_disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$REPORTED"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

# --- actions -------------------------------------------------------------------------

refusal_text() {  # uses LEASE_* and UPLOAD_*
  local changes count
  changes=$(local_changes)
  count=0
  [ -z "$changes" ] || count=$(printf '%s\n' "$changes" | wc -l | tr -d ' ')
  case "$LEASE_STATE" in
    foreign)
      if [ "$LEASE_MACHINE" = "$CFG_MACHINE" ]; then
        printf 'HANDOFF: the lease names this machine (%s) but not a lease this home took - operate read-only.\n' "$CFG_MACHINE"
      else
        printf 'HANDOFF: the helm is on machine %s (lease taken %s%s) - operate read-only.\n' \
          "$LEASE_MACHINE" "${LEASE_TAKEN:-at an unknown time}" "${LEASE_FORCED:+, forced from $LEASE_FORCED}"
      fi
      ;;
    free) printf 'HANDOFF: no machine holds the helm - operate read-only until this machine takes it.\n' ;;
    ours) printf 'HANDOFF: this machine took the lease but prendi never finished bringing data/ up to date - operate read-only.\n' ;;
    *) printf 'HANDOFF: the lease could not be read (%s) and this home never took it - operate read-only.\n' "$LEASE_ERR" ;;
  esac
  printf 'HANDOFF: last upload of data/: %s.\n' "$(upload_desc)"
  if [ "$count" -gt 0 ]; then
    printf 'HANDOFF: this machine has %s local data/ change(s) not uploaded - nothing overwrites them silently; bin/fm-handoff.sh diff lists them.\n' "$count"
  fi
  case "$LEASE_STATE" in
    free) printf 'HANDOFF: to take the helm here: bin/fm-handoff.sh prendi\n' ;;
    ours) printf 'HANDOFF: to finish taking the helm: bin/fm-handoff.sh prendi\n' ;;
    foreign)
      if [ -n "$CFG_EC2_INSTANCE" ] && [ "$LEASE_MACHINE" = "$CFG_EC2_MACHINE" ]; then
        printf 'HANDOFF: to take the helm back cleanly (captain'"'"'s explicit word only): bin/fm-handoff.sh riprendi\n'
      fi
      printf 'HANDOFF: to force the takeover without a handover (captain'"'"'s explicit word only): bin/fm-handoff.sh prendi --force\n'
      ;;
    *) printf 'HANDOFF: once the bucket is reachable, rerun bin/fm-session-start.sh; to force the takeover (captain'"'"'s explicit word only): bin/fm-handoff.sh prendi --force\n' ;;
  esac
  [ "$count" -eq 0 ] || printf 'HANDOFF: prendi refuses over those local changes unless --replace-local, which first saves this copy under state/handoff-backups/ for merging.\n'
  printf 'HANDOFF: after taking the helm, rerun bin/fm-session-start.sh.\n'
}

action_gate() {
  local err
  enabled || { rm -f "$REFUSED"; return 0; }
  mkdir -p "$STATE" || return 1
  # An unusable config refuses the lock rather than silently disabling the lease.
  if ! err=$( (load_config) 2>&1 ); then
    write_refused "HANDOFF: config/handoff-s3 is unusable - operate read-only until it is fixed: ${err#fm-handoff: }" || true
    cat "$REFUSED"
    return 1
  fi
  load_config
  read_lease
  if [ "$LEASE_STATE" = ours ] && [ "$(held_field status)" = held ]; then
    clear_refused
    printf 'HANDOFF: this machine (%s) holds the helm since %s.\n' "$CFG_MACHINE" "${LEASE_TAKEN:-an unknown time}"
    return 0
  fi
  if [ "$LEASE_STATE" = unknown ] && [ "$(held_field status)" = held ] \
    && [ "$(held_field machine)" = "$CFG_MACHINE" ] && [ -z "$LEASE_MACHINE" ]; then
    clear_refused
    printf 'HANDOFF: WARNING - the lease could not be verified (%s); proceeding because this machine took it at %s and never released it. Another machine may have forced a takeover meanwhile.\n' \
      "$LEASE_ERR" "$(held_field at)"
    return 0
  fi
  read_last_upload
  local text
  text=$(refusal_text)
  write_refused "$text" || return 1
  printf '%s\n' "$text"
  return 1
}

action_status() {
  load_config
  read_lease
  read_last_upload
  printf 'machine: %s\nbucket: %s\n' "$CFG_MACHINE" "$S3_BASE"
  case "$LEASE_STATE" in
    ours) printf 'lease: held by this machine since %s\n' "$LEASE_TAKEN" ;;
    foreign) printf 'lease: held by %s since %s%s\n' "$LEASE_MACHINE" "$LEASE_TAKEN" "${LEASE_FORCED:+ (forced from $LEASE_FORCED)}" ;;
    free) printf 'lease: free\n' ;;
    *) printf 'lease: unreadable (%s)\n' "$LEASE_ERR" ;;
  esac
  printf 'last upload: %s\n' "$(upload_desc)"
  printf 'local record: %s\n' "$( [ -f "$HELD" ] && tr '\n' ' ' < "$HELD" || printf 'none')"
  printf 'session lock refusal: %s\n' "$( [ -f "$REFUSED" ] && printf present || printf absent)"
  printf 'periodic backup: %s\n' "$( [ -f "$CHECK_SHIM" ] && printf armed || printf 'not armed')"
  local changes
  changes=$(local_changes)
  if [ -n "$changes" ]; then
    printf 'local data/ changes not uploaded:\n'
    printf '%s\n' "$changes" | sed 's/^/  /'
  else
    printf 'local data/ changes not uploaded: none\n'
  fi
}

action_diff() {
  load_config
  local changes tmp
  changes=$(local_changes)
  printf 'local data/ changes since this machine last synced:\n'
  if [ -n "$changes" ]; then printf '%s\n' "$changes" | sed 's/^/  /'; else printf '  none\n'; fi
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-handoff-diff.XXXXXX") || return 1
  if ! aws_run "$SYNC_TIMEOUT" s3 sync "$S3_BASE/data/" "$tmp/" --only-show-errors >/dev/null; then
    rm -rf -- "$tmp"
    die "could not download the bucket copy for comparison"
  fi
  printf 'local data/ against the bucket copy:\n'
  if diff -rq "$DATA" "$tmp" >/dev/null 2>&1; then
    printf '  identical\n'
  else
    diff -rq "$DATA" "$tmp" 2>&1 | sed "s|$tmp|<bucket>|g; s|$DATA|data|g; s/^/  /"
  fi
  rm -rf -- "$tmp"
}

action_prendi() {
  local force=0 replace=0 changes nonce prior_holder prior_taken
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force) force=1 ;;
      --replace-local) replace=1 ;;
      *) die_usage "prendi: unknown argument $1" ;;
    esac
    shift
  done
  load_config
  mkdir -p "$STATE" || return 1
  op_lock
  read_lease
  case "$LEASE_STATE" in
    unknown) die "cannot read the lease ($LEASE_ERR); nothing changed" ;;
    ours)
      if [ "$(held_field status)" = held ]; then
        clear_refused
        printf 'this machine already holds the helm; rerun bin/fm-session-start.sh if this session is read-only.\n'
        return 0
      fi
      ;;
    foreign)
      if [ "$force" -ne 1 ]; then
        read_last_upload
        printf 'refused: the helm is on machine %s (lease taken %s); last upload %s.\n' \
          "$LEASE_MACHINE" "${LEASE_TAKEN:-at an unknown time}" "$(upload_desc)" >&2
        printf 'Take it back through a handover (riprendi, or consegna on that machine), or force it on the captain'"'"'s explicit word: bin/fm-handoff.sh prendi --force\n' >&2
        return 1
      fi
      ;;
  esac
  read_last_upload
  [ "$UPLOAD_STATE" != unknown ] || die "cannot read the last-upload record; nothing changed"

  changes=
  if [ "$UPLOAD_STATE" = present ]; then
    changes=$(local_changes)
    # Local data/ identical to what this machine last synced is only safe to
    # replace when that sync is not already the bucket's latest upload - and when
    # it is, the download is a no-op anyway.
    if [ -n "$changes" ] && [ "$replace" -ne 1 ]; then
      printf 'refused: this machine has local data/ changes that were never uploaded:\n' >&2
      printf '%s\n' "$changes" | sed 's/^/  /' >&2
      printf 'Taking the helm would replace them with the bucket copy (last upload %s).\n' "$(upload_desc)" >&2
      printf 'Decide with the captain: bin/fm-handoff.sh diff compares them; bin/fm-handoff.sh prendi --replace-local%s saves this copy under state/handoff-backups/ and then takes the helm, so the wanted changes can be merged back by hand.\n' \
        "$( [ "$force" -eq 1 ] && printf ' --force')" >&2
      return 1
    fi
  fi

  # 1. Claim the lease first: a crash after this point leaves the home refused.
  prior_holder=
  prior_taken=
  if [ "$LEASE_STATE" = foreign ]; then
    prior_holder=$LEASE_MACHINE
    prior_taken=$LEASE_TAKEN
  fi
  if [ "$LEASE_STATE" = ours ]; then
    nonce=$(held_field nonce)
  else
    nonce=$(random_token)
    write_held claimed "$nonce" || die "cannot write $HELD"
    write_refused "HANDOFF: prendi started at $(now_iso) and has not finished - rerun bin/fm-handoff.sh prendi." || true
    s3_write lease "$(printf 'fm-handoff-lease-v1\nmachine=%s\nnonce=%s\ntaken_at=%s\nforced_from=%s' \
      "$CFG_MACHINE" "$nonce" "$(now_iso)" "$prior_holder")" || die "cannot write the lease; this home stays read-only"
    read_lease
    [ "$LEASE_STATE" = ours ] || die "the lease changed hands while taking it (now: ${LEASE_MACHINE:-$LEASE_STATE}); this home stays read-only"
  fi

  # 2. Bring data/ to the bucket's latest upload, or seed an empty bucket, then
  # upload once more so the bucket records who took the helm and from where.
  if [ "$UPLOAD_STATE" = absent ]; then
    if [ -n "$prior_holder" ]; then
      append_log "$(now_iso) FORCED takeover by $CFG_MACHINE from $prior_holder (its lease taken ${prior_taken:-at an unknown time}), started from no upload: seeding the empty bucket from its data/." \
        || die "cannot record the forced takeover in $HANDOFF_LOG"
      printf 'recorded the forced takeover in data/handoff-log.md.\n'
    else
      append_log "$(now_iso) $CFG_MACHINE took the helm, seeding the empty bucket from its data/." \
        || die "cannot write $HANDOFF_LOG"
    fi
    upload seed || die "the lease is taken but seeding the empty bucket from this machine failed; rerun bin/fm-handoff.sh prendi"
    printf 'seeded the empty bucket from this machine (upload %s).\n' "$UPLOADED_ID"
  else
    download || die "the lease is taken but downloading data/ failed; this home stays read-only - rerun bin/fm-handoff.sh prendi"
    record_manifest "$UPLOAD_ID" || die "cannot record the data/ manifest"
    printf 'downloaded data/ from upload %s.\n' "$(upload_desc)"
    [ -z "$SAVED_COPY" ] || printf 'the previous local data/ is saved at %s.\n' "$SAVED_COPY"
    if [ -n "$prior_holder" ]; then
      append_log "$(now_iso) FORCED takeover by $CFG_MACHINE from $prior_holder (its lease taken ${prior_taken:-at an unknown time}), started from upload $(upload_desc)." \
        || die "cannot record the forced takeover in $HANDOFF_LOG"
      printf 'recorded the forced takeover in data/handoff-log.md.\n'
    else
      append_log "$(now_iso) $CFG_MACHINE took the helm, starting from upload $(upload_desc)." \
        || die "cannot write $HANDOFF_LOG"
    fi
    [ -z "$changes" ] || append_log "$(now_iso) $CFG_MACHINE set aside its unuploaded local data/ changes in $SAVED_COPY for merging." || true
    upload prendi || printf 'warning: recording the takeover in the bucket failed; the periodic backup retries it.\n' >&2
  fi

  write_held held "$nonce" || die "cannot write $HELD"
  clear_refused
  action_arm >/dev/null || printf 'warning: the periodic backup check could not be armed; run bin/fm-handoff.sh arm\n' >&2
  printf 'this machine (%s) now holds the helm. Rerun bin/fm-session-start.sh to take it in this session.\n' "$CFG_MACHINE"
}

annotate_backlog() {  # <id> <line>: append a line to a backlog item body via tasks-axi.
  local id=$1 line=$2 raw body tmp
  command -v tasks-axi >/dev/null 2>&1 || return 1
  [ -f "$DATA/backlog.md" ] || return 1
  raw=$(tasks-axi show "$id" --full --file "$DATA/backlog.md" 2>/dev/null) || return 1
  body=$(printf '%s\n' "$raw" | sed -n 's/^  body: //p' | head -1)
  case "$body" in
    '"'*) body=$(printf '%s' "$body" | jq -r '.' 2>/dev/null) || return 1 ;;
  esac
  [ "$body" != '-' ] || body=
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-handoff-body.XXXXXX") || return 1
  if [ -n "$body" ]; then printf '%s\n%s\n' "$body" "$line" > "$tmp"; else printf '%s\n' "$line" > "$tmp"; fi
  tasks-axi update "$id" --body-file "$tmp" --file "$DATA/backlog.md" >/dev/null 2>&1
  local rc=$?
  rm -f "$tmp"
  return "$rc"
}

action_consegna() {
  local leave=0 ids id when note
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --leave) leave=1 ;;
      *) die_usage "consegna: unknown argument $1" ;;
    esac
    shift
  done
  load_config
  op_lock
  read_lease
  case "$LEASE_STATE" in
    ours) require_held "handed over" ;;
    free)
      if [ "$(held_field status)" = released ]; then
        printf 'already handed over: no machine holds the helm.\n'
        return 0
      fi
      die "refused: this machine does not hold the lease (nobody does); nothing to hand over"
      ;;
    foreign) die "refused: the helm is on machine $LEASE_MACHINE, not this one; nothing to hand over" ;;
    *) die "cannot read the lease ($LEASE_ERR); nothing changed" ;;
  esac
  ids=$(inflight_ids)
  when=$(now_iso)
  if [ -n "$ids" ]; then
    printf 'in-flight tasks on this machine (%s):\n' "$CFG_MACHINE"
    while IFS= read -r id; do printf '  %s\n' "$(describe_task "$id")"; done <<< "$ids"
    if [ "$leave" -ne 1 ]; then
      printf 'refused: bring them to a stop point first, or rerun with --leave to hand over while they stay on %s.\n' "$CFG_MACHINE" >&2
      return 1
    fi
    while IFS= read -r id; do
      note="Handoff $when: stays on machine $CFG_MACHINE (in flight when the helm was handed over)."
      if annotate_backlog "$id" "$note"; then
        printf 'recorded in the backlog: %s stays on %s.\n' "$id" "$CFG_MACHINE"
      else
        printf 'note: %s is not a backlog item this script could annotate; recorded in data/handoff-log.md only.\n' "$id"
      fi
    done <<< "$ids"
    append_log "$when $CFG_MACHINE handed over with task(s) left in flight on it: $(printf '%s' "$ids" | tr '\n' ' ')" || die "cannot write $HANDOFF_LOG"
  else
    append_log "$when $CFG_MACHINE handed over the helm (no task in flight)." || die "cannot write $HANDOFF_LOG"
  fi
  upload consegna || die "uploading data/ failed; the lease is kept, so this machine still holds the helm"
  read_lease
  if [ "$LEASE_STATE" = ours ]; then
    s3_delete lease || die "data/ was uploaded (upload $UPLOADED_ID) but releasing the lease failed; rerun bin/fm-handoff.sh consegna"
  else
    printf 'warning: the lease was no longer this machine'"'"'s when releasing it (%s); left as it is.\n' "${LEASE_MACHINE:-$LEASE_STATE}" >&2
  fi
  write_held released "$(held_field nonce)" || true
  write_refused "HANDOFF: this machine ($CFG_MACHINE) handed the helm over at $when (upload $UPLOADED_ID) - operate read-only. To take it again: bin/fm-handoff.sh prendi, then rerun bin/fm-session-start.sh." || true
  action_disarm >/dev/null
  printf 'handed over: data/ uploaded (upload %s) and the lease released. This machine is now read-only; a running firstmate session here must stop mutating.\n' "$UPLOADED_ID"
}

action_backup() {
  load_config
  op_lock
  read_lease
  require_held uploaded
  upload backup || die "uploading data/ failed"
  printf 'uploaded data/ (upload %s); the lease stays with this machine.\n' "$UPLOADED_ID"
}

report_once() {  # <message>: print only when it differs from the last report.
  if [ "$(cat "$REPORTED" 2>/dev/null)" != "$1" ]; then
    printf '%s\n' "$1" > "$REPORTED"
    printf '%s\n' "$1"
  fi
}

action_check() {
  local changes elapsed last t budget start
  start=$(now_epoch)
  enabled || return 0
  (load_config) >/dev/null 2>&1 || { report_once "handoff backup: config/handoff-s3 is invalid - run bin/fm-handoff.sh status"; return 0; }
  load_config
  [ "$(held_field status)" = held ] || return 0
  op_lock try || return 0
  # Fit inside the watcher's per-check bound: the lease read, the sync, and the
  # last-upload write together.
  budget=${FM_CHECK_TIMEOUT:-30}
  case "$budget" in ''|*[!0-9]*) budget=30 ;; esac
  [ "$SMALL_TIMEOUT" -le $((budget / 6)) ] || SMALL_TIMEOUT=$((budget / 6))
  [ "$SMALL_TIMEOUT" -ge 1 ] || SMALL_TIMEOUT=1
  changes=$(local_changes)
  [ -n "$changes" ] || return 0
  last=$(cat "$LAST_UPLOAD_EPOCH" 2>/dev/null || printf 0)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  elapsed=$(( $(now_epoch) - last ))
  if [ "$elapsed" -lt "$BACKUP_INTERVAL" ] && ! printf '%s\n' "$changes" | grep -q ': backlog.md$'; then
    return 0
  fi
  read_lease
  case "$LEASE_STATE" in
    ours) ;;
    unknown) report_once "handoff backup: the bucket is unreachable ($LEASE_ERR); data/ is not backed up"; return 0 ;;
    *)
      write_held lost "$(held_field nonce)" || true
      write_refused "HANDOFF: this machine ($CFG_MACHINE) lost the lease to ${LEASE_MACHINE:-nobody} - operate read-only. See bin/fm-handoff.sh status." || true
      report_once "handoff: this machine lost the helm to ${LEASE_MACHINE:-nobody} - stop mutating fleet state and rerun bin/fm-session-start.sh"
      return 0
      ;;
  esac
  t=$(( budget - ($(now_epoch) - start) - SMALL_TIMEOUT - 3 ))
  [ "$t" -le "$SYNC_TIMEOUT" ] || t=$SYNC_TIMEOUT
  [ "$t" -ge 1 ] || t=1
  upload backup "$t" || report_once "handoff backup: uploading data/ failed; it will be retried"
  return 0
}

action_inflight() {
  local ids id
  ids=$(inflight_ids)
  [ -n "$ids" ] || { printf 'none\n'; return 0; }
  while IFS= read -r id; do printf '%s\n' "$(describe_task "$id")"; done <<< "$ids"
}

action_idle() {
  local minutes=120 p recent inflight
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --minutes) minutes=${2:-}; shift ;;
      --minutes=*) minutes=${1#--minutes=} ;;
      *) die_usage "idle: unknown argument $1" ;;
    esac
    shift
  done
  positive_int --minutes "$minutes"
  if enabled; then load_config; fi
  # shellcheck source=bin/fm-supervision-lib.sh
  . "$SCRIPT_DIR/fm-supervision-lib.sh"
  fm_supervision_status "$STATE"
  inflight=$(inflight_ids | wc -l | tr -d ' ')
  [ "$inflight" -eq 0 ] || { printf 'busy: %s task(s) in flight\n' "$inflight"; return 1; }
  [ "$FM_SUP_SOURCES" -eq 0 ] || { printf 'busy: %s process-event source(s) registered\n' "$FM_SUP_SOURCES"; return 1; }
  [ "$FM_SUP_QUEUE_PENDING" = false ] || { printf 'busy: queued wakes are waiting\n'; return 1; }
  if [ -d "$STATE/inbox" ] && [ -n "$(find "$STATE/inbox" -mindepth 1 -maxdepth 1 -type f -print -quit 2>/dev/null)" ]; then
    printf 'busy: captain inbox notes are waiting\n'; return 1
  fi
  if [ -d "$STATE/x-inbox" ] && [ -n "$(find "$STATE/x-inbox" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
    printf 'busy: Relay mentions are waiting\n'; return 1
  fi
  for p in "$DATA" "$STATE"/*.status "$STATE/.wake-queue" ${CFG_IDLE_ACTIVITY[@]+"${CFG_IDLE_ACTIVITY[@]}"}; do
    [ -e "$p" ] || continue
    recent=$(find "$p" -mmin "-$minutes" -print -quit 2>/dev/null)
    if [ -n "$recent" ]; then
      printf 'busy: activity in the last %s minute(s) (%s)\n' "$minutes" "$recent"
      return 1
    fi
  done
  printf 'idle: no task, wake, message, or activity for %s minute(s)\n' "$minutes"
}

# --- return flow over SSM ---------------------------------------------------------------

SSM_OUT=
ssm_run() {  # <fm-handoff args...>: run bin/fm-handoff.sh on the EC2 home.
  local inner cmd params cid deadline st json
  inner="cd $(printf '%q' "$CFG_EC2_HOME") && bin/fm-handoff.sh"
  for a in "$@"; do inner="$inner $(printf '%q' "$a")"; done
  cmd="runuser -u $(printf '%q' "$CFG_EC2_USER") -- bash -lc $(printf '%q' "$inner")"
  params=$(jq -cn --arg c "$cmd" '{commands: [$c]}') || return 1
  cid=$(aws_run "$SMALL_TIMEOUT" ssm send-command --instance-ids "$CFG_EC2_INSTANCE" \
    --document-name AWS-RunShellScript --parameters "$params" \
    --query Command.CommandId --output text) || { SSM_OUT="send-command failed"; return 1; }
  cid=$(printf '%s' "$cid" | tr -d '[:space:]')
  deadline=$(( $(now_epoch) + SSM_TIMEOUT ))
  while :; do
    json=$(aws_run "$SMALL_TIMEOUT" ssm get-command-invocation --command-id "$cid" \
      --instance-id "$CFG_EC2_INSTANCE" --output json 2>/dev/null) || json=
    st=$(printf '%s' "$json" | jq -r '.Status // empty' 2>/dev/null)
    case "$st" in
      Success)
        SSM_OUT=$(printf '%s' "$json" | jq -r '.StandardOutputContent // ""')
        return 0
        ;;
      Failed|Cancelled|TimedOut|Cancelling)
        SSM_OUT=$(printf '%s' "$json" | jq -r '(.StandardOutputContent // "") + (.StandardErrorContent // "")')
        return 1
        ;;
    esac
    [ "$(now_epoch)" -lt "$deadline" ] || { SSM_OUT="no result within ${SSM_TIMEOUT}s (command $cid)"; return 1; }
    sleep "${FM_HANDOFF_SSM_POLL:-3}"
  done
}

action_riprendi() {
  local leave=0 replace=0 prendi_args=() changes
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --leave) leave=1 ;;
      --replace-local) replace=1 ;;
      *) die_usage "riprendi: unknown argument $1" ;;
    esac
    shift
  done
  load_config
  [ -n "$CFG_EC2_INSTANCE" ] && [ -n "$CFG_EC2_MACHINE" ] && [ -n "$CFG_EC2_HOME" ] && [ -n "$CFG_EC2_USER" ] \
    || die "riprendi needs ec2_instance_id, ec2_machine, ec2_home, and ec2_user in config/handoff-s3"
  command -v jq >/dev/null 2>&1 || die "riprendi needs jq"
  [ "$replace" -eq 0 ] || prendi_args+=(--replace-local)
  read_lease
  case "$LEASE_STATE" in
    ours) printf 'this machine already holds the helm.\n'; return 0 ;;
    unknown) die "cannot read the lease ($LEASE_ERR); nothing changed" ;;
    foreign)
      [ "$LEASE_MACHINE" = "$CFG_EC2_MACHINE" ] \
        || die "refused: the helm is on machine $LEASE_MACHINE, not the EC2 machine $CFG_EC2_MACHINE"
      printf 'in-flight tasks on %s:\n' "$CFG_EC2_MACHINE"
      ssm_run inflight || die "could not list the EC2 in-flight tasks: $SSM_OUT"
      printf '%s\n' "$SSM_OUT" | sed '/^$/d; s/^/  /'
      if [ "$(printf '%s' "$SSM_OUT" | tr -d '[:space:]')" != none ] && [ "$leave" -ne 1 ]; then
        printf 'refused: EC2 has tasks in flight. Decide with the captain: wait for them, or rerun with --leave so they stay on %s.\n' "$CFG_EC2_MACHINE" >&2
        return 1
      fi
      if [ "$replace" -ne 1 ]; then
        read_last_upload
        changes=$(local_changes)
        if [ "$UPLOAD_STATE" = present ] && [ -n "$changes" ]; then
          printf 'refused: this machine has local data/ changes that were never uploaded:\n' >&2
          printf '%s\n' "$changes" | sed 's/^/  /' >&2
          printf 'Nothing changed on EC2. Decide with the captain: bin/fm-handoff.sh diff compares them; bin/fm-handoff.sh riprendi --replace-local saves this copy under state/handoff-backups/ before taking the helm.\n' >&2
          return 1
        fi
      fi
      if [ "$leave" -eq 1 ]; then ssm_run consegna --leave; else ssm_run consegna; fi \
        || die "consegna on EC2 failed; nothing changed here: $SSM_OUT"
      printf '%s\n' "$SSM_OUT" | sed '/^$/d; s/^/  EC2: /'
      ;;
    free) printf 'no machine holds the helm; skipping the EC2 handover.\n' ;;
  esac
  action_prendi ${prendi_args[@]+"${prendi_args[@]}"} || return 1
  op_unlock
  if aws_run "$SMALL_TIMEOUT" ec2 stop-instances --instance-ids "$CFG_EC2_INSTANCE" >/dev/null; then
    printf 'stopping the EC2 instance %s.\n' "$CFG_EC2_INSTANCE"
  else
    printf 'warning: the helm is here, but stopping the EC2 instance %s failed; stop it by hand.\n' "$CFG_EC2_INSTANCE" >&2
    return 1
  fi
}

ACTION=${1:-}
[ "$#" -eq 0 ] || shift
case "$ACTION" in
  status) action_status ;;
  gate) action_gate ;;
  prendi) action_prendi "$@" ;;
  consegna) action_consegna "$@" ;;
  backup) action_backup ;;
  check) action_check ;;
  arm) load_config; action_arm ;;
  disarm) action_disarm ;;
  diff) action_diff ;;
  inflight) action_inflight ;;
  idle) action_idle "$@" ;;
  riprendi) action_riprendi "$@" ;;
  -h|--help|help) usage ;;
  '') usage >&2; exit 2 ;;
  *) die_usage "unknown action: $ACTION (see --help)" ;;
esac
