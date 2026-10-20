# shellcheck shell=bash
# Shared local voice transcription: the one place that knows how audio reaches
# the transcription host and how its text comes back. Used by
# bin/fm-voice-note.sh (any audio file, e.g. the watch relay) and by the Telegram
# channel (bin/fm-telegram-lib.sh, bin/fm-procevent-telegram.sh).
# Usage: . bin/fm-voice-lib.sh   (callers set FM_HOME first when they want fm_voice_cfg_load)
# docs/telegram.md "Voice notes" owns setup; docs/configuration.md owns the schema.
#
# CONFIG. One JSON object, read from config/voice-transcribe.json, or when that
# file is absent from the `voice_transcribe` object of config/telegram.json.
# Absent means voice transcription is off. Fields: ssh_host (required),
# model, language, timeout_seconds, max_duration_seconds, command.
#
# PRIVACY. Audio goes only to ssh_host, over ssh, on stdin. Nothing is sent to
# any other service. Every failure returns non-zero with a one-line VOICE_ERROR
# and callers keep the message; nothing here ever deletes the caller's audio.

SCRIPT_DIR_VOICE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR_VOICE_LIB/fm-timeout-lib.sh"

VOICE_CFG=
VOICE_ERROR=
VOICE_SCRUB=

fm_voice_set_error() {
  VOICE_ERROR=$(printf '%s' "$1" | tr -d '\000-\037\177' | cut -c1-200)
  [ -z "$VOICE_SCRUB" ] || VOICE_ERROR=${VOICE_ERROR//"$VOICE_SCRUB"/[token]}
}

# Validate one config object on stdin; prints the problem, or nothing when valid.
fm_voice_cfg_error() {
  jq -r '
    def int: type == "number" and . == floor;
    if type != "object" then "voice transcription config must be an object"
    elif ((.ssh_host // "") | type != "string" or test("^[A-Za-z0-9_][A-Za-z0-9._@-]{0,200}$") | not) then "ssh_host must be a host name or ssh alias"
    elif any(["model","language"][] as $k | .[$k]; . != null and (type != "string" or test("^[A-Za-z0-9._-]{1,64}$") | not)) then "model and language must be plain names"
    elif any(["timeout_seconds","max_duration_seconds"][] as $k | .[$k]; . != null and (int | not)) then "timeout_seconds and max_duration_seconds must be integers"
    elif (.timeout_seconds // 120) < 5 or (.timeout_seconds // 120) > 600 then "timeout_seconds must be from 5 to 600"
    elif (.command != null) and ((.command | type) != "string" or (.command | length) == 0 or (.command | test("[[:cntrl:]]"))) then "command must be a single-line string"
    else "" end' 2>/dev/null || printf 'voice transcription config is not valid JSON\n'
}

# Load the voice config for $FM_HOME into VOICE_CFG. Returns 1 when voice
# transcription is not configured, 2 when configured but invalid
# (VOICE_ERROR names the problem).
fm_voice_cfg_load() {
  local own="${FM_HOME:?FM_HOME must be set}/config/voice-transcribe.json" tg="$FM_HOME/config/telegram.json" err
  VOICE_CFG=
  if [ -f "$own" ]; then
    VOICE_CFG=$(jq -c . "$own" 2>/dev/null) || { fm_voice_set_error "$own is not valid JSON"; VOICE_CFG=; return 2; }
  elif [ -f "$tg" ] && jq -e '(.voice_transcribe | type) == "object"' "$tg" >/dev/null 2>&1; then
    VOICE_CFG=$(jq -c '.voice_transcribe' "$tg")
  else
    return 1
  fi
  err=$(printf '%s' "$VOICE_CFG" | fm_voice_cfg_error)
  if [ -n "$err" ]; then fm_voice_set_error "$err"; VOICE_CFG=; return 2; fi
}

fm_voice_cfg_get() {  # <jq-expr>
  printf '%s' "$VOICE_CFG" | jq -r "$1"
}

# Transcribe <audio-file> on the configured host into <out-file>. The result
# travels by file, not stdout, so VOICE_ERROR survives in the caller's shell.
fm_voice_transcribe_file() {  # <audio-file> <out-file>
  local audio=$1 dest=$2 host cmd model lang secs out errf rc=0
  [ -n "$VOICE_CFG" ] || { fm_voice_set_error "voice transcription is not configured"; return 1; }
  host=$(fm_voice_cfg_get '.ssh_host')
  model=$(fm_voice_cfg_get '.model // "small"')
  lang=$(fm_voice_cfg_get '.language // "it"')
  secs=$(fm_voice_cfg_get '.timeout_seconds // 120')
  cmd=$(printf '%s' "$VOICE_CFG" | jq -r --arg m "$model" --arg l "$lang" '.command // ("$HOME/.local/share/fm-whisper/venv/bin/python $HOME/.local/share/fm-whisper/transcribe.py --model " + $m + " --language " + $l)')
  command -v ssh >/dev/null 2>&1 || { fm_voice_set_error "ssh is not installed"; return 1; }
  errf=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-voice-ssherr.XXXXXX") || { fm_voice_set_error "no work file"; return 1; }
  # The audio is opened inside the bounded child: fm_run_timed runs its command
  # in the background, where a redirect on the call itself would be replaced by
  # /dev/null.
  # shellcheck disable=SC2016 # expanded by the child shell
  out=$(fm_run_timed "$secs" bash -c 'f=$1; shift; exec "$@" < "$f"' _ "$audio" \
    ssh -o BatchMode=yes -o ConnectTimeout=10 -- "$host" "$cmd" 2>"$errf") || rc=$?
  if [ "$rc" -eq 124 ]; then
    rm -f -- "$errf"; fm_voice_set_error "timed out after ${secs}s"; return 1
  elif [ "$rc" -ne 0 ]; then
    fm_voice_set_error "host $host failed (exit $rc): $(tail -n1 "$errf" 2>/dev/null)"; rm -f -- "$errf"; return 1
  fi
  rm -f -- "$errf"
  out=$(printf '%s' "$out" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  if [ -z "$out" ]; then fm_voice_set_error "no speech recognized"; return 1; fi
  printf '%s\n' "$out" > "$dest"
}
