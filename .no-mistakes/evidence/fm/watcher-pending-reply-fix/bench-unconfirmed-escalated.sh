#!/usr/bin/env bash
# Benchmark: watcher-style polls of try_resolve over N escalated records whose
# delivery was never confirmed, against a long-lived mate status log.
# Usage: bench.sh <bin-dir> <records> <status-lines> <polls>
set -u; export LC_ALL=C
BIN=$1 N=$2 L=$3 P=$4
. "$BIN/fm-marker-lib.sh"; . "$BIN/fm-pending-reply-lib.sh"
export FM_PENDING_REPLY_GRACE_SECS=0
home=$(mktemp -d /tmp/fm-bench-XXXX); state="$home/state"; mkdir -p "$state"
export FM_PENDING_REPLY_NOW=9800
corrs=()
for i in $(seq 1 "$N"); do
  c=$(fm_pending_reply_create "$home" "$state" hibit "req $i")
  fm_pending_reply_prepare_delivery "$state" "$c" >/dev/null
  fm_pending_reply_mark_delivery_unknown "$state" "$c" >/dev/null
  fm_pending_reply_maybe_escalate "$state" "$c" >/dev/null 2>&1
  corrs+=("$c")
done
for i in $(seq 1 "$L"); do printf 'working [corr=%016x]: unrelated chatter line %d\n' "$i" "$i"; done >> "$state/hibit.status"
esc=0; unconf=0
for c in "${corrs[@]}"; do r=$(fm_pending_reply_path "$state" "$c")
  [ "$(fm_pending_reply_get "$r" phase)" = escalated ] && esc=$((esc+1))
  [ -z "$(fm_pending_reply_get "$r" delivered_epoch)" ] && unconf=$((unconf+1)); done
echo "records=$N escalated=$esc unconfirmed=$unconf status_lines=$(wc -l < "$state/hibit.status")"
for p in $(seq 1 "$P"); do
  s=$(date +%s.%N)
  for c in "${corrs[@]}"; do fm_pending_reply_try_resolve "$state" "$c" || true; done
  e=$(date +%s.%N); printf 'poll %d: %.2fs\n' "$p" "$(echo "$e - $s" | bc)"
done
# a real reply for the last record must still resolve
export FM_PENDING_REPLY_NOW=9801
last=${corrs[$((N-1))]}
printf 'done [corr=%s]: routed work picked up\n' "$last" >> "$state/hibit.status"
s=$(date +%s.%N); fm_pending_reply_try_resolve "$state" "$last" && r=resolved || r=NOT-resolved; e=$(date +%s.%N)
printf 'after correlated reply lands: last record %s, phase=%s (%.2fs)\n' "$r" "$(fm_pending_reply_get "$(fm_pending_reply_path "$state" "$last")" phase)" "$(echo "$e - $s" | bc)"
rm -rf "$home"
