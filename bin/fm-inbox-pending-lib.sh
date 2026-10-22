# shellcheck shell=bash
# fm-inbox-pending-lib.sh - pending captain inbox notes: the one owner of what
# "pending" means and of the re-announce ladder that keeps a pending note in
# front of firstmate until it is handled.
#
# A note is pending while <state>/inbox/<id>.note exists; `fm-inbox.sh drain
# --ack <id>` moves it to handled/, which is the only way to stop it surfacing.
# Acknowledging the wake row that announced a note does NOT handle the note, so
# a wake acknowledged unseen would otherwise lose the note for good.
#
# Two consumers:
#   bin/fm-wake-drain.sh prints fm_inbox_pending_section on every drain, so every
#     presentation lists every pending note (id, age, first words).
#   bin/fm-watch.sh calls fm_inbox_pending_due each poll and appends one
#     `check: inbox note <id> still unhandled - <words>` wake per due note, then
#     fm_inbox_pending_record_announce.
#
# Ladder: a note is due once its age reaches FM_INBOX_PENDING_GRACE_SECS
# (default 240) and again every grace period after the last re-announce, for as
# long as it stays pending. State lives in <state>/inbox/.reannounce/<id>
# (epoch of the last re-announce) and is pruned once the note is handled.
# Age is read from the note's mtime, which fm-inbox.sh writes once at creation.
#
# Usage: . bin/fm-inbox-pending-lib.sh

fm_inbox_pending_grace() {
  local g=${FM_INBOX_PENDING_GRACE_SECS:-240}
  case "$g" in ''|*[!0-9]*|0) g=240 ;; esac
  printf '%s\n' "$g"
}

_fm_inbox_pending_mtime() {  # <file>
  stat -c %Y -- "$1" 2>/dev/null || stat -f %m -- "$1" 2>/dev/null
}

# First words of a note body, one line, at most 100 characters.
fm_inbox_pending_words() {  # <note-file>
  awk 'found { print; next } /^--$/ { found=1 }' "$1" \
    | tr '\n\t' '  ' | tr -d '\000-\037\177' | sed 's/ *$//' | cut -c1-100
}

# One "<id>\t<age-seconds>\t<words>" line per pending note, oldest first.
fm_inbox_pending_list() {  # <state-dir> [<now>]
  local inbox="$1/inbox" now=${2:-$(date +%s)} f m
  [ -d "$inbox" ] || return 0
  for f in "$inbox"/*.note; do
    [ -f "$f" ] || continue
    m=$(_fm_inbox_pending_mtime "$f") || continue
    printf '%s\t%s\t%s\n' "$m" "$(basename "$f" .note)" "$(fm_inbox_pending_words "$f")"
  done | sort -n | while IFS=$(printf '\t') read -r m id words; do
    printf '%s\t%s\t%s\n' "$id" $((now - m)) "$words"
  done
}

_fm_inbox_pending_age_label() {  # <seconds>
  if [ "$1" -lt 60 ]; then printf '%ss' "$1"
  elif [ "$1" -lt 3600 ]; then printf '%sm' $(($1 / 60))
  else printf '%sh%sm' $(($1 / 3600)) $(($1 % 3600 / 60))
  fi
}

# The drain's PENDING INBOX NOTES section; prints nothing when none is pending.
fm_inbox_pending_section() {  # <state-dir>
  local list id age words
  list=$(fm_inbox_pending_list "$1") || return 1
  [ -n "$list" ] || return 0
  printf 'PENDING INBOX NOTES (not yet handled; each stays listed until bin/fm-inbox.sh drain --ack <id>):\n' || return 1
  while IFS=$(printf '\t') read -r id age words; do
    [ -n "$id" ] || continue
    printf '%s age=%s: %s\n' "$id" "$(_fm_inbox_pending_age_label "$age")" "$words" || return 1
  done <<EOF
$list
EOF
  printf 'PENDING INBOX NOTES: read one in full with bin/fm-inbox.sh list, act on it, then ack it.\n'
}

# One "<id>\t<words>" line per pending note due a re-announce now. Prunes ladder
# state for notes no longer pending.
fm_inbox_pending_due() {  # <state-dir> [<now>]
  local state=$1 now=${2:-$(date +%s)} grace dir id age words last r
  grace=$(fm_inbox_pending_grace)
  dir="$state/inbox/.reannounce"
  if [ -d "$dir" ]; then
    for r in "$dir"/*; do
      [ -f "$r" ] || continue
      [ -f "$state/inbox/${r##*/}.note" ] || rm -f -- "$r"
    done
  fi
  fm_inbox_pending_list "$state" "$now" | while IFS=$(printf '\t') read -r id age words; do
    [ -n "$id" ] || continue
    [ "$age" -ge "$grace" ] || continue
    last=
    [ ! -f "$dir/$id" ] || last=$(head -n1 "$dir/$id" 2>/dev/null)
    case "$last" in ''|*[!0-9]*) ;; *) [ $((now - last)) -ge "$grace" ] || continue ;; esac
    printf '%s\t%s\n' "$id" "$words"
  done
}

fm_inbox_pending_record_announce() {  # <state-dir> <id> [<now>]
  local dir="$1/inbox/.reannounce"
  mkdir -p "$dir" && printf '%s\n' "${3:-$(date +%s)}" > "$dir/$2"
}
