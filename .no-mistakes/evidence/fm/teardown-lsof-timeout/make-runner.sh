#!/usr/bin/env bash
# Build a runner that executes only selected cases of tests/fm-teardown.test.sh
# from <tree-root>, and copies every case's stdout/stderr into <transcript-dir>
# before the fixture tmp root is cleaned up.
# Usage: make-runner.sh <tree-root> <runner-out> <transcript-dir> <test_fn>...
set -eu
tree=$1 out=$2 tdir=$3
shift 3
src="$tree/tests/fm-teardown.test.sh"
last=$(grep -n '^test_local_only_fork_remote_allows$' "$src" | cut -d: -f1)
{
  sed -n "1,$((last - 1))p" "$src" |
    sed "s#^\. \"\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh\"#. '$tree/tests/lib.sh'#"
  cat <<EOF
save_transcripts() {
  local d
  mkdir -p '$tdir'
  for d in "\$TMP_ROOT"/*/; do
    for f in "\$d"*stdout "\$d"*stderr; do
      [ -f "\$f" ] && cp "\$f" '$tdir'/"\$(basename "\$d")__\$(basename "\$f").txt"
    done
  done
  return 0
}
trap 'save_transcripts; fm_test_cleanup' EXIT
EOF
  printf '%s\n' "$@"
} > "$out"
chmod +x "$out"
