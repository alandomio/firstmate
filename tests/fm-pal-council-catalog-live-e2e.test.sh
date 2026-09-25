#!/usr/bin/env bash
# Live guard for pal-council tier resolution: bin/fm-pal-council.sh reads each
# harness's own model catalog (claude --help aliases, codex debug models, agy
# models, grok models, cursor-agent --list-models), which is vendor output that a
# release can change. For every INSTALLED harness this runs `catalog` against the
# real CLI and fails naming the harness and its version when the catalog no
# longer parses or the configured top pattern picks nothing. An absent harness is
# reported, and a run that checked no harness at all fails rather than passing.
# Opt-in because standard CI has neither the CLIs nor their credentials; run it
# after a harness upgrade.
set -u

if [ "${FM_PAL_COUNCIL_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_PAL_COUNCIL_LIVE_E2E=1 to check pal-council tier resolution against the installed harness catalogs"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset FM_PAL_CATALOG_DIR
PAL="$ROOT/bin/fm-pal-council.sh"
checked=0
for harness in claude codex agy grok cursor; do
  bin=$harness
  [ "$harness" = cursor ] && bin=cursor-agent
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "absent: $harness ($bin not on PATH)"
    continue
  fi
  version=$("$bin" --version 2>/dev/null | head -n 1)
  out=$("$PAL" catalog "$harness" 2>&1) || fail "$harness ${version:-unknown version}: catalog did not parse: $out"
  top=$(printf '%s\n' "$out" | sed -n 's/^top: //p')
  [ -n "$top" ] && [ "$top" != - ] || fail "$harness ${version:-unknown version}: the configured top pattern picks no model: $out"
  pass "$harness ${version:-unknown version}: top model $top"
  checked=$((checked + 1))
done
[ "$checked" -gt 0 ] || fail "no harness was installed, so nothing was checked"
echo "checked $checked installed harness catalog(s)"
