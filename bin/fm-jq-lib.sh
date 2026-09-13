#!/usr/bin/env bash
# fm-jq-lib.sh - the single owner of passing fleet-sized values to jq.
#
# Sourced, never executed. The kernel caps one argv string at MAX_ARG_STRLEN
# (128KB on Linux), so `jq --argjson name "$big"` dies with "Argument list too
# long" once a backlog, task list, or secondmate summary grows past it.
#
#   fm_jq -n [jq options...] <filter>
#       Runs jq with the same arguments, except that every `--argjson NAME VALUE`
#       and `--arg NAME VALUE` whose value exceeds FM_JQ_INLINE_MAX characters
#       (default 8192) travels on jq's stdin instead of argv: the values are
#       written as a JSON text stream (an --arg string is JSON-encoded first by
#       `jq -Rs .`) and the filter is prefixed with one `input as $NAME |` binding
#       per value, in order. Small values stay inline, so the common case costs
#       nothing extra.
#       Spilling requires `-n` (stdin is otherwise the caller's input) and the
#       filter as the LAST argument; without `-n` every value stays inline.
#       No temp files are created, so there is nothing to clean up and no tool
#       beyond bash and jq is needed.
#       Output and exit status are jq's own: jq parses a stdin text with the same
#       parser as --argjson and applies the same UTF-8 handling as --arg, so the
#       result is byte-identical to the plain argv form for any value that fit.
set -u

fm_jq() {
  local limit=${FM_JQ_INLINE_MAX:-8192}
  local -a fm_jq_argv=()
  local prefix='' stream='' null_input=0 arg
  for arg in "$@"; do
    case "$arg" in -n|--null-input) null_input=1; break ;; esac
  done
  while [ "$#" -gt 1 ]; do
    case "$1" in
      --arg|--argjson|--slurpfile|--rawfile)
        if [ "$#" -lt 4 ]; then
          fm_jq_argv+=("$@"); set --; break
        fi
        if [ "$null_input" = 1 ] && { [ "$1" = --arg ] || [ "$1" = --argjson ]; } \
          && [ "${#3}" -gt "$limit" ]; then
          if [ "$1" = --arg ]; then
            stream="$stream$(printf '%s' "$3" | jq -Rs .)"$'\n'
          else
            stream="$stream$3"$'\n'
          fi
          prefix="${prefix}input as \$$2 | "
        else
          fm_jq_argv+=("$1" "$2" "$3")
        fi
        shift 3
        ;;
      --indent)
        fm_jq_argv+=("$1" "$2"); shift 2
        ;;
      *)
        fm_jq_argv+=("$1"); shift
        ;;
    esac
  done
  if [ -z "$prefix" ]; then
    jq "${fm_jq_argv[@]}" "$@"
    return $?
  fi
  printf '%s' "$stream" | jq "${fm_jq_argv[@]}" "$prefix${1-}"
}
