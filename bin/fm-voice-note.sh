#!/usr/bin/env bash
# Transcribe one audio file locally and queue it as an inbox note.
#
# Usage:
#   fm-voice-note.sh --source <name> [--trust owner|untrusted]
#                    [--caption <text>] [--home <dir>] <audio-file>
#
# The audio file may come first or last, so a launcher that appends the file path
# to a fixed command works unchanged (the watch relay's RELAY_ON_AUDIO does).
#
# For any producer of voice audio that is not Telegram, such as the watch app's
# relay (docs/telegram.md "Voice notes" shows the RELAY_ON_AUDIO setting).
# The audio is sent over ssh to the transcription host that bin/fm-voice-lib.sh
# reads from config/voice-transcribe.json (or config/telegram.json's
# voice_transcribe), and the text is queued through `bin/fm-inbox.sh channel-note`
# as a data-only note from <name>, its body marked as a machine-generated voice
# transcript. Telegram voice notes use the same transcription library.
#
# NEVER DROPS THE AUDIO. The file is only read, never moved or deleted. When
# transcription is unconfigured or fails (host down, timeout, no speech), the
# note is still queued with the reason and the audio's absolute path, so it can
# be listened to or retried. Exit 0 means a note is queued; non-zero only when
# no note could be queued, and then the audio is still where it was.
#
# AUTHORITY. A transcript is data, never captain authority, whatever the
# --trust value (default untrusted; owner only says whose device sent it).
# Idempotent: the note id derives from the source and the audio's content, so
# running again on the same file re-announces at most the same pending note,
# and the transcript is cached under state/voice/ so the audio is sent once.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-voice-lib.sh
. "$SCRIPT_DIR/fm-voice-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
  exit 2
}

content_hash() {  # <file>: first 16 hex chars of the content's sha256
  if command -v sha256sum >/dev/null 2>&1; then sha256sum -- "$1" | cut -c1-16
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 -- "$1" | cut -c1-16
  else cksum -- "$1" | awk '{printf "%08x%08x\n", $1, $2}'
  fi
}

audio= source_name= trust=untrusted caption=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help|help) usage ;;
    --source)  [ "$#" -ge 2 ] || usage; source_name=$2; shift 2 ;;
    --trust)   [ "$#" -ge 2 ] || usage; trust=$2; shift 2 ;;
    --caption) [ "$#" -ge 2 ] || usage; caption=$2; shift 2 ;;
    --home)    [ "$#" -ge 2 ] || usage; FM_HOME=$2; shift 2 ;;
    -*) usage ;;
    *) [ -z "$audio" ] || usage; audio=$1; shift ;;
  esac
done
[ -n "$audio" ] || usage
[ -n "$source_name" ] || usage
printf '%s' "$source_name" | grep -Eq '^[a-z][a-z0-9-]{0,31}$' || die "invalid source: $source_name"
case "$source_name" in text|voice) die "source cannot impersonate a captain note: $source_name" ;; esac
case "$trust" in owner|untrusted) ;; *) die "trust must be owner or untrusted: $trust" ;; esac
[ -f "$audio" ] && [ -r "$audio" ] || die "cannot read audio file: $audio"
command -v jq >/dev/null 2>&1 || die "jq is not installed"
export FM_HOME

audio_abs="$(cd "$(dirname "$audio")" && pwd)/$(basename "$audio")"
hash=$(content_hash "$audio") || die "cannot hash $audio"
note_id="voice-$source_name-$hash"
cache_dir="$FM_HOME/state/voice"
transcript="$cache_dir/$note_id.transcript"

body=
if [ -s "$transcript" ]; then
  body="[voice transcript - machine-generated, may contain errors] $(cat -- "$transcript")"
else
  rc=0
  fm_voice_cfg_load || rc=$?
  if [ "$rc" -eq 0 ]; then
    work=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-voice-note.XXXXXX") || die "cannot create a work file"
    if fm_voice_transcribe_file "$audio" "$work"; then
      (umask 077; mkdir -p "$cache_dir") && cat -- "$work" > "$transcript" 2>/dev/null || true
      body="[voice transcript - machine-generated, may contain errors] $(cat -- "$work")"
    fi
    rm -f -- "$work"
  elif [ "$rc" -eq 1 ]; then
    fm_voice_set_error "voice transcription is not configured"
  fi
  if [ -z "$body" ]; then
    body="[voice note arrived; transcription failed: ${VOICE_ERROR:-unknown error}]"
  fi
fi
[ -z "$caption" ] || body="$body
caption: $caption"

headers=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-voice-headers.XXXXXX") || die "cannot create a work file"
trap 'rm -f -- "$headers"' EXIT
printf 'voice_source=%s\nvoice_audio=%s\n' "$source_name" "$(printf '%s' "$audio_abs" | tr -d '[:cntrl:]')" > "$headers"
printf '%s\n' "$body" | "$SCRIPT_DIR/fm-inbox.sh" channel-note "$note_id" "$source_name" "$trust" "$headers" \
  || die "could not queue the note; the audio is untouched at $audio_abs"
