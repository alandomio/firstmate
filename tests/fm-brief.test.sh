#!/usr/bin/env bash
# Behavior tests for bin/fm-brief.sh.
#
# Regression coverage for the heredoc-in-command-substitution parse bug (issues
# #166, #958, #1069). Building a variable with `VAR=$(cat <<EOF ... EOF)` is
# unsafe on Bash 3.2 (macOS /bin/bash): the lexer scans for the matching `)` of
# the command substitution textually and tracks quote state through the heredoc
# body, so a single apostrophe, unbalanced quote, or unbalanced paren anywhere
# in that body breaks parsing of the *entire rest of the script* - `bash -n`
# fails, not just the generated brief. The DOD and Herdr-section builders now
# use `IFS= read -r -d '' VAR <<EOF || true` instead, which removes the `$(...)`
# wrapper and eliminates the whole defect class regardless of future prose.
# test_no_heredoc_in_command_substitution guards that structure directly.
# Ambient `bash -n` here is Bash 5 and cannot see the bug, so the real
# cross-version enforcement lives in the macos-stock-bash CI job.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief)
BRIEF_HOME="$TMP_ROOT/home"
mkdir -p "$BRIEF_HOME/data"

# The script itself must always parse under the ambient bash. That is Bash 5 in
# CI and locally, where the issue #958/#1069 parser bug does not fire, so this
# is a weak guard on its own; test_no_heredoc_in_command_substitution and the
# macos-stock-bash CI job carry the real cross-version enforcement.
test_script_parses() {
  local out rc
  out=$(bash -n "$ROOT/bin/fm-brief.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-brief.sh must parse cleanly (got: $out)"
  [ -z "$out" ] || fail "bash -n bin/fm-brief.sh emitted unexpected output: $out"
  pass "fm-brief.sh: bash -n succeeds"
}

# Structural class guard (issues #166, #958, #1069): never build a variable by
# wrapping a heredoc in a command substitution (`VAR=$(cat <<EOF ... EOF)`).
# That construct is what breaks Bash 3.2 parsing, and pinning one historical
# apostrophe phrase (as the old test did) missed the #945 reintroduction. This
# guards the *shape* directly against the whole file, so any future DOD or
# section builder that reintroduces the class fails here regardless of prose.
test_no_heredoc_in_command_substitution() {
  local unsafe safe
  unsafe="$TMP_ROOT/heredoc-in-substitution.sh"
  safe="$TMP_ROOT/plain-heredoc.sh"
  # shellcheck disable=SC2016 # Literal shell fixtures must remain unexpanded.
  printf '%s\n' 'value=$(' '  cat <<EOF' 'body' 'EOF' ')' > "$unsafe"
  # shellcheck disable=SC2016 # Literal shell fixtures must remain unexpanded.
  printf '%s\n' 'cat <<EOF' '$(' '  cat <<INNER' 'INNER' ')' 'EOF' > "$safe"
  if no_heredoc_in_command_substitution "$unsafe"; then
    fail "structural guard accepted a multiline heredoc nested in a command substitution"
  fi
  no_heredoc_in_command_substitution "$safe" \
    || fail "structural guard treated heredoc body prose as shell structure"
  no_heredoc_in_command_substitution "$ROOT/bin/fm-brief.sh" \
    || fail "fm-brief.sh wraps a heredoc in a command substitution (breaks Bash 3.2 parsing)"
  pass "fm-brief.sh: no heredoc is nested inside a command substitution (Bash 3.2 parse-safe)"
}

no_heredoc_in_command_substitution() {
  perl - "$1" <<'PERL'
use strict;
use warnings;

my $path = shift;
open my $source, '<', $path or die "$path: $!\n";
my @frames;
my @heredocs;
my $quote = '';
my $line_number = 0;

while (my $line = <$source>) {
  $line_number++;
  if (@heredocs) {
    my $candidate = $line;
    $candidate =~ s/\r?\n\z//;
    $candidate =~ s/^\t+// if $heredocs[0]{strip_tabs};
    shift @heredocs if $candidate eq $heredocs[0]{delimiter};
    next;
  }

  my $length = length $line;
  for (my $i = 0; $i < $length; $i++) {
    my $char = substr($line, $i, 1);
    if ($quote eq "'") {
      $quote = '' if $char eq "'";
      next;
    }
    if ($char eq '\\') {
      $i++;
      next;
    }
    if ($quote eq '"' && $char eq '"') {
      $quote = '';
      next;
    }
    if ($char eq "'" && $quote eq '') {
      $quote = "'";
      next;
    }
    if ($char eq '"' && $quote eq '') {
      $quote = '"';
      next;
    }
    if ($char eq '#' && $quote eq '' && ($i == 0 || substr($line, $i - 1, 1) =~ /[\s;|&()]/)) {
      last;
    }
    if ($char eq '$' && substr($line, $i + 1, 1) eq '(') {
      push @frames, { depth => 1, quote => $quote };
      $quote = '';
      $i++;
      next;
    }
    if (@frames && $quote eq '' && $char eq '(') {
      $frames[-1]{depth}++;
      next;
    }
    if (@frames && $quote eq '' && $char eq ')') {
      $frames[-1]{depth}--;
      if ($frames[-1]{depth} == 0) {
        my $frame = pop @frames;
        $quote = $frame->{quote};
      }
      next;
    }
    next unless $quote eq '' && $char eq '<' && substr($line, $i + 1, 1) eq '<';
    if (@frames) {
      print STDERR "$path:$line_number\n";
      exit 1;
    }

    my $j = $i + 2;
    my $strip_tabs = substr($line, $j, 1) eq '-';
    $j++ if $strip_tabs;
    $j++ while substr($line, $j, 1) =~ /[ \t]/;
    my $delimiter = '';
    my $delimiter_quote = '';
    for (; $j < $length; $j++) {
      my $token = substr($line, $j, 1);
      if ($delimiter_quote) {
        if ($token eq $delimiter_quote) {
          $delimiter_quote = '';
        } elsif ($token eq '\\' && $delimiter_quote eq '"') {
          $j++;
          $delimiter .= substr($line, $j, 1);
        } else {
          $delimiter .= $token;
        }
        next;
      }
      if ($token eq "'" || $token eq '"') {
        $delimiter_quote = $token;
        next;
      }
      if ($token eq '\\') {
        $j++;
        $delimiter .= substr($line, $j, 1);
        next;
      }
      last if $token =~ /[\s;|&()<>]/;
      $delimiter .= $token;
    }
    push @heredocs, { delimiter => $delimiter, strip_tabs => $strip_tabs };
    $i = $j - 1;
  }
}

exit 0;
PERL
}

test_help_includes_entire_header() {
  local help
  help=$("$ROOT/bin/fm-brief.sh" --help)
  assert_contains "$help" "Refuses to overwrite an existing brief." "fm-brief.sh --help omitted its header terminator"
  pass "fm-brief.sh: --help renders the complete header"
}

# Registry with one project per delivery mode. fm-brief.sh no longer reads it -
# the ship mode arrives as an explicit flag - so this fixture exists to prove the
# scaffold ignores the registered posture (test_ship_mode_is_explicit_not_registry).
write_registry() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- direct-proj [direct-PR] - fixture for direct-PR mode (added 2026-07-01)
- local-proj [local-only] - fixture for local-only mode (added 2026-07-01)
EOF
}

# Build a local clone at an explicit path with the given origin, so
# fm_brief_detect_forge (bin/fm-brief.sh) has something to read. An empty
# origin leaves the clone remote-less, and a third "ci-marker" argument drops
# a .gitlab-ci.yml so self-hosted-host detection can be exercised.
write_clone_at() {
  local dir=$1 origin=$2 ci_marker=${3:-}
  mkdir -p "$dir"
  git -C "$dir" init -q
  [ -z "$origin" ] || git -C "$dir" remote add origin "$origin"
  [ -z "$ci_marker" ] || printf 'stages: []\n' > "$dir/.gitlab-ci.yml"
}

# The same, for a project name under a home's default projects/ directory.
write_project_clone() {
  local home=$1 name=$2 origin=$3 ci_marker=${4:-}
  write_clone_at "$home/projects/$name" "$origin" "$ci_marker"
}

# fm-brief.sh must exit 0 and produce a brief with no unreplaced shell
# metacharacter corruption for every ship delivery mode. This also guards
# against any *new* unescaped apostrophe or unbalanced quote later added to
# one of these DOD blocks, since a broken heredoc corrupts or empties the
# generated brief content, not just the script's own syntax.
test_ship_modes_generate_clean_briefs() {
  local home id mode brief status
  home="$TMP_ROOT/ship-home"
  write_registry "$home"

  for id_mode in "brief-nomistakes-a1:no-mistakes" "brief-directpr-a2:direct-PR" "brief-localonly-a3:local-only"; do
    id=${id_mode%%:*}
    mode=${id_mode##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode "$mode" >/dev/null 2>&1; status=$?
    expect_code 0 "$status" "fm-brief.sh $id --mode $mode should exit 0"
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "# Definition of done" "$brief" "$id: brief missing Definition of done section"
    grep -qx "Delivery contract: mode=$mode" "$brief" \
      || fail "$id: brief did not record its machine-readable delivery contract line"
    assert_grep "{TASK}" "$brief" "$id: brief missing the {TASK} placeholder"
    assert_grep "mid-task \`working:\` or \`note:\` line (including setup complete) is nonterminal" "$brief" \
      "$id: brief missing nonterminal working:/note:/setup-complete gate protection"
    assert_no_grep "EOF" "$brief" "$id: brief leaked a heredoc EOF marker (unterminated heredoc)"
  done
  pass "fm-brief.sh: no-mistakes/direct-PR/local-only briefs generate cleanly"
}

# A ship task's delivery mode is firstmate's per-task decision, so a missing or
# unusable value must stop the scaffold instead of silently defaulting. The
# no-mistakes-prod-only row is the conditional registry policy: it is never a task
# mode, and its refusal must say to classify the task's surface first.
test_ship_mode_is_required_and_closed_set() {
  local home id out status label flag expect
  home="$TMP_ROOT/mode-required-home"
  mkdir -p "$home/data"
  id=0
  while IFS='|' read -r label flag expect; do
    [ -n "$label" ] || continue
    id=$((id + 1))
    # shellcheck disable=SC2086  # flag is an intentional word-split arg list (may be empty)
    out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "brief-required-$id" some-proj $flag 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain the contract"
    assert_absent "$home/data/brief-required-$id/brief.md" "$label: refused scaffold still wrote a brief"
  done <<'ROWS'
missing --mode||ship briefs require --mode
empty --mode value|--mode|requires a value
unknown mode value|--mode nope|must be one of no-mistakes, direct-PR, local-only
conditional policy is not a task mode|--mode no-mistakes-prod-only|classify this task's surface
ROWS
  pass "fm-brief.sh: ship --mode is required and closed-set validated"
}

# The registry is the captain's standing posture, not this task's answer: the
# scaffold must follow the explicit flag even when the project is registered
# with a different mode, and must not consult the registry at all.
test_ship_mode_is_explicit_not_registry() {
  local home brief
  home="$TMP_ROOT/explicit-over-registry-home"
  write_registry "$home"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-explicit-a5 direct-proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "explicit no-mistakes brief on a direct-PR project should scaffold"
  brief="$home/data/brief-explicit-a5/brief.md"
  grep -qx "Delivery contract: mode=no-mistakes" "$brief" \
    || fail "registered direct-PR posture overrode the explicit --mode"
  assert_grep "Firstmate will then instruct you to run /no-mistakes" "$brief" \
    "explicit no-mistakes brief did not render the pipeline definition of done"

  # An unregistered project is not a blocker either, because nothing is looked up.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-explicit-a6 never-registered --mode local-only >/dev/null 2>&1 \
    || fail "unregistered project should still scaffold from the explicit mode"
  grep -qx "Delivery contract: mode=local-only" "$home/data/brief-explicit-a6/brief.md" \
    || fail "unregistered project did not honour the explicit --mode"
  pass "fm-brief.sh: the explicit ship mode wins over the registered posture"
}

# yolo is firstmate's merge authority and never reaches the worker, and a scout
# or charter carries no delivery contract. Each must refuse rather than accept and
# discard the flag, which would look recorded but change nothing.
test_delivery_flags_are_refused_where_they_do_not_apply() {
  local home out status label args expect
  home="$TMP_ROOT/refused-flags-home"
  mkdir -p "$home/data"
  while IFS='|' read -r label args expect; do
    [ -n "$label" ] || continue
    # shellcheck disable=SC2086  # args is an intentional word-split arg list
    out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" $args 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain why"
  done <<'ROWS'
yolo on a ship brief|brief-refused-b1 some-proj --mode direct-PR --yolo on|--yolo is not a brief input
yolo=value form on a ship brief|brief-refused-b2 some-proj --mode direct-PR --yolo=off|--yolo is not a brief input
mode on a scout brief|brief-refused-b3 some-proj --scout --mode direct-PR|--mode applies only to ship briefs
mode on a secondmate charter|brief-refused-b4 --secondmate --no-projects --mode no-mistakes|--mode applies only to ship briefs
ROWS
  pass "fm-brief.sh: --yolo and scout/secondmate --mode are refused, never silently dropped"
}

test_faster_paths_use_configured_authority_without_stacked_review() {
  local home id brief
  home="$TMP_ROOT/configured-authority-home"
  write_registry "$home"
  write_project_clone "$home" direct-proj https://github.com/acme/direct-proj.git
  write_project_clone "$home" local-proj https://github.com/acme/local-proj.git
  id="brief-direct-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj --mode direct-PR >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority decides whether to merge the pull request; firstmate relays the outcome." "$brief" \
    "direct-PR brief lost configured merge authority"
  assert_no_grep "The captain reviews and merges the pull request" "$brief" \
    "direct-PR brief hard-coded captain-only authority"
  id="brief-local-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" local-proj --mode local-only >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path." "$brief" \
    "local-only brief lost configured merge authority and guarded landing"
  assert_no_grep "The captain approves the ready branch" "$brief" \
    "local-only brief hard-coded captain-only authority"
  assert_no_grep "Firstmate then reviews your branch diff" "$brief" \
    "local-only brief retained a personal review stacked on the selected delivery path"
  assert_no_grep "make \`--intent\` preserve all relevant content from this brief" "$home/data/$id/brief.md" \
    "local-only brief must not include the no-mistakes --intent contract"
  id="brief-direct-intent-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj --mode direct-PR >/dev/null 2>&1
  assert_no_grep "make \`--intent\` preserve all relevant content from this brief" "$home/data/$id/brief.md" \
    "direct-PR brief must not include the no-mistakes --intent contract"
  pass "fm-brief.sh: faster paths use configured authority without stacked review"
}

# The captain's standing instruction (2026-08-28) requires every generated MR/PR
# description, including a review-fix revision, to go through the mr-description
# skill. That only applies to the two modes that actually open one.
test_mr_description_skill_required_for_pr_modes() {
  local home id brief
  home="$TMP_ROOT/mrdesc-skill-home"
  mkdir -p "$home/data"

  id="brief-mr-desc-directpr"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode direct-PR >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  # shellcheck disable=SC2016 # single quotes are deliberate: the backticks must stay literal
  assert_grep '`mr-description` skill' "$brief" \
    "direct-PR brief did not require the mr-description skill"
  assert_grep 'any later revision to it' "$brief" \
    "direct-PR brief did not cover revising an existing PR description"

  id="brief-mr-desc-nomistakes"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  # shellcheck disable=SC2016 # single quotes are deliberate: the backticks must stay literal
  assert_grep '`mr-description` skill' "$brief" \
    "no-mistakes brief did not require the mr-description skill"
  assert_grep 'any later revision to it (including a review-fix revision)' "$brief" \
    "no-mistakes brief did not cover a review-fix revision to the PR description"

  # The requirement's wording must follow the project's actual forge, never a
  # hardcoded "PR description": a GitLab project says "MR description" (the
  # captain's standing GitLab vocabulary rule), a GitHub project says "PR
  # description". The skill name itself (`mr-description`) stays fixed either
  # way - only the surrounding prose is forge-aware.
  write_project_clone "$home" gh-mrdesc-proj https://github.com/acme/gh-mrdesc-proj.git
  write_project_clone "$home" gl-mrdesc-proj https://gitlab.com/peterpark/gl-mrdesc-proj.git

  id="brief-mr-desc-directpr-gh"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" gh-mrdesc-proj --mode direct-PR >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  # shellcheck disable=SC2016 # single quotes are deliberate: the backticks must stay literal
  assert_grep 'Write the PR description, and any later revision to it, with the `mr-description` skill.' "$brief" \
    "direct-PR brief for a GitHub project did not require the PR-worded mr-description skill"

  id="brief-mr-desc-directpr-gl"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" gl-mrdesc-proj --mode direct-PR >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  # shellcheck disable=SC2016 # single quotes are deliberate: the backticks must stay literal
  assert_grep 'Write the MR description, and any later revision to it, with the `mr-description` skill.' "$brief" \
    "direct-PR brief for a GitLab project did not require the MR-worded mr-description skill"
  assert_no_grep 'Write the PR description' "$brief" \
    "direct-PR brief for a GitLab project hardcoded PR description wording"

  id="brief-mr-desc-nomistakes-gh"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" gh-mrdesc-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  # shellcheck disable=SC2016 # single quotes are deliberate: the backticks must stay literal
  assert_grep 'Write the PR description, and any later revision to it (including a review-fix revision), with the `mr-description` skill.' "$brief" \
    "no-mistakes brief for a GitHub project did not require the PR-worded mr-description skill"

  id="brief-mr-desc-nomistakes-gl"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" gl-mrdesc-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  # shellcheck disable=SC2016 # single quotes are deliberate: the backticks must stay literal
  assert_grep 'Write the MR description, and any later revision to it (including a review-fix revision), with the `mr-description` skill.' "$brief" \
    "no-mistakes brief for a GitLab project did not require the MR-worded mr-description skill"
  assert_no_grep 'Write the PR description' "$brief" \
    "no-mistakes brief for a GitLab project hardcoded PR description wording"

  id="brief-mr-desc-localonly"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode local-only >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_no_grep 'mr-description' "$brief" \
    "local-only brief must not require the mr-description skill (it never opens a PR)"

  id="brief-mr-desc-scout"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --scout >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_no_grep 'mr-description' "$brief" \
    "scout brief must not require the mr-description skill (it never opens a PR)"

  pass "fm-brief.sh: direct-PR and no-mistakes briefs require the mr-description skill; local-only and scout do not"
}

# Pin the specific line the bug lived on: the no-mistakes DOD's no-mistakes
# reference must render as plain prose with no dangling apostrophe artifact.
test_no_mistakes_dod_wording() {
  local home id brief
  home="$TMP_ROOT/wording-home"
  mkdir -p "$home/data"
  id="brief-wording-b1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "no-mistakes itself provides for the mechanics" "$brief" \
    "no-mistakes DOD lost its guidance-reference sentence"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`no-mistakes axi run --help`' "$brief" \
    "no-mistakes DOD must render literal backticks around the help command"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`help`' "$brief" \
    "no-mistakes DOD must render literal backticks around help"
  assert_grep "make \`--intent\` preserve all relevant content from this brief" "$brief" \
    "no-mistakes DOD must require --intent to retain the accepted task contract"
  assert_grep "carrying only each requirement's current accepted form" "$brief" \
    "no-mistakes DOD must replace superseded requirements with their current accepted form"
  assert_grep "retain direct requirements instead of substituting a diff summary" "$brief" \
    "no-mistakes DOD must keep direct requirements and exclude generic scaffold boilerplate from --intent"
  assert_grep "exclude generic operational, status, delivery, and other scaffold boilerplate unless it is task-specific" "$brief" \
    "no-mistakes DOD must exclude non-task-specific scaffold boilerplate from --intent"
  # The apostrophe in "firstmate's authority check" is now structurally safe
  # (no `$(...)` wrapper around the heredoc), so it renders verbatim instead of
  # being reworded or escaped away. test_no_heredoc_in_command_substitution
  # guards the structure that makes it safe.
  assert_grep "firstmate's authority check" "$brief" \
    "no-mistakes DOD lost the apostrophe prose that the structural fix makes parse-safe"
  pass "fm-brief.sh: no-mistakes DOD keeps its apostrophe prose, now parse-safe"
}

test_ship_project_memory_wording() {
  local home id brief
  home="$TMP_ROOT/project-memory-home"
  mkdir -p "$home/data"
  id="brief-memory-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "Record only project knowledge useful to almost every future session." "$brief" \
    "project-memory contract lost the durable-knowledge bar"
  assert_grep "prefer a pointer to the authoritative file, command, or doc over copying the detail" "$brief" \
    "project-memory contract lost pointer-over-copy guidance"
  assert_grep "lacks \`## Maintaining this file\`, add that short self-governance section" "$brief" \
    "project-memory contract lost the self-governance add-in-same-pass rule"
  pass "fm-brief.sh: ship project-memory wording carries the AGENTS.md authoring bar"
}

test_herdr_lab_contract_is_explicit_and_complete() {
  local home id brief
  home="$TMP_ROOT/herdr-lab-home"
  mkdir -p "$home/data"
  id="brief-herdr-lab-d1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode no-mistakes --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "Herdr lab brief was not scaffolded"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "Herdr lab brief missing its hard safety contract"
  assert_grep "HERDR_LAB_HELPER='$ROOT/bin/fm-herdr-lab.sh'" "$brief" \
    "Herdr lab brief must bind the absolute Firstmate helper path"
  assert_grep "HERDR_LAB_SESSION=\$(\"\$HERDR_LAB_HELPER\" name $id)" "$brief" \
    "Herdr lab brief missing helper-owned session naming"
  assert_grep "\"\$HERDR_LAB_HELPER\" provision \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned provisioning"
  assert_grep "\"\$HERDR_LAB_HELPER\" teardown \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned teardown"
  assert_grep "required trailing \`--session \"\$HERDR_LAB_SESSION\"\`" "$brief" \
    "Herdr lab brief missing the per-call trailing session contract"
  assert_grep "direct \`herdr server stop\`" "$brief" \
    "Herdr lab brief missing the forbidden server-global command list"
  assert_grep "records the live default session before provisioning" "$brief" \
    "Herdr lab brief missing the before tripwire"
  assert_grep "verifies the identical fleet state after teardown" "$brief" \
    "Herdr lab brief missing the after tripwire"
  assert_no_grep "Herdr lifecycle declaration - NOT ENABLED" "$brief" \
    "Herdr lab brief retained the unguarded declaration"
  pass "fm-brief.sh: --herdr-lab emits the complete hard safety contract"
}

test_herdr_lab_contract_quotes_foreign_firstmate_path() {
  local home id brief foreign_root helper
  home="$TMP_ROOT/herdr-lab-foreign-home"
  foreign_root="$TMP_ROOT/firstmate helper's root"
  mkdir -p "$home/data"
  id="brief-herdr-lab-foreign-d2"
  helper=$(printf '%s' "$foreign_root/bin/fm-herdr-lab.sh" | sed "s/'/'\\\\''/g")
  helper="'$helper'"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$foreign_root" "$ROOT/bin/fm-brief.sh" "$id" foreign --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "HERDR_LAB_HELPER=$helper" "$brief" \
    "Herdr lab brief must shell-quote an absolute Firstmate helper path"
  assert_no_grep "bin/fm-herdr-lab.sh name $id" "$brief" \
    "Herdr lab brief must not invoke a worktree-relative helper"
  pass "fm-brief.sh: --herdr-lab uses its quoted Firstmate-owned helper path"
}

test_herdr_lab_omission_is_loud_for_ship_and_scout() {
  local home id brief
  home="$TMP_ROOT/herdr-gate-home"
  mkdir -p "$home/data"
  for kind in ship scout; do
    id="brief-herdr-gate-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode no-mistakes >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_grep "# Herdr lifecycle declaration - NOT ENABLED" "$brief" \
      "$kind brief silently omitted the Herdr declaration"
    assert_grep "regenerate the brief with \`--herdr-lab\` before dispatch" "$brief" \
      "$kind brief missing the fail-visible regeneration instruction"
  done
  pass "fm-brief.sh: ship and scout scaffolds make omitted Herdr intent fail-visible"
}

test_secondmate_no_projects_charter() {
  local home brief status
  home="$TMP_ROOT/no-projects-home"
  mkdir -p "$home/data"

  # The deliberate --no-projects signal scaffolds a valid project-less charter for
  # a domain whose subject is the firstmate repo itself (no clones needed).
  FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-brief.sh" fdev --secondmate --no-projects >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "--no-projects secondmate brief should exit 0"
  brief="$home/data/fdev/brief.md"
  assert_present "$brief" "project-less charter was not scaffolded"
  assert_grep "# Project clones" "$brief" "project-less charter dropped the Project clones heading"
  assert_grep "None. This is a project-less domain" "$brief" \
    "project-less charter did not render a sensible no-clones note"
  assert_grep "its crews take pooled worktrees of that repo" "$brief" \
    "project-less charter operating model lost the pooled-worktree note"
  assert_no_grep "The projects above are local clones" "$brief" \
    "project-less charter kept the with-projects operating-model line"
  assert_grep 'working [key=<work-slug>]' "$brief" \
    "secondmate charter did not key material routed-work phases"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter did not close a quietly ended routed-work phase"
  assert_grep 'use the same key on its later' "$brief" \
    "secondmate charter did not supersede working phases with later states"
  if grep -nE '^-[[:space:]]*$' "$brief" >/dev/null; then
    fail "project-less charter left a stray empty project bullet"
  fi

  # Accidental omission (no projects, no signal) still fails loudly, writing nothing.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops --secondmate >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "secondmate brief with no projects and no --no-projects must fail"
  assert_absent "$home/data/oops/brief.md" "loud-failure secondmate brief still wrote a file"

  # --no-projects is mutually exclusive with a project list.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops2 --secondmate --no-projects alpha >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects combined with a project list must fail"

  # --no-projects applies only to secondmate charters, never a ship/scout brief.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" oops3 somerepo --no-projects >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects on a ship brief must fail"

  pass "fm-brief.sh: --no-projects scaffolds a project-less charter and guards misuse"
}

test_secondmate_marked_request_reporting_contract() {
  local home brief
  home="$TMP_ROOT/marked-request-reporting-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=paused \
    FM_SECONDMATE_CHARTER='Handle routed domain work.' \
    "$ROOT/bin/fm-brief.sh" marked-request-reporting --secondmate --no-projects >/dev/null 2>&1
  brief="$home/data/marked-request-reporting/brief.md"

  assert_grep 'A marked request requires one correlated answer after the work' "$brief" \
    "secondmate charter did not require the correlated answer after the work"
  assert_grep 'does not require a separate receipt or start acknowledgement' "$brief" \
    "secondmate charter did not reject a separate receipt/start acknowledgement"
  assert_grep "Never append \`working:\` merely to acknowledge receipt or announce that a marked request has started." "$brief" \
    "secondmate charter did not forbid a generic working acknowledgement"
  assert_no_grep "Give every routed-work phase a stable key: open it with \`working" "$brief" \
    "secondmate charter retained the unconditional working opener"
  assert_grep 'When a routed-work phase has a supervisor-actionable material change worth reporting under the rule above' "$brief" \
    "secondmate charter did not limit keyed phases to reportable material changes"
  assert_grep "If its first reportable event is \`working [key=<work-slug>]: {material phase}\`" "$brief" \
    "secondmate charter lost keyed working syntax for a reportable material phase"
  assert_grep "use the same key on its later \`paused\`, \`done\`, \`failed\`, \`needs-decision\`, or \`blocked\` event" "$brief" \
    "secondmate charter lost same-key closure for a reportable material phase"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter lost resolved closure for a keyed material phase"

  assert_grep 'include that exact token in your parent status reply' "$brief" \
    "secondmate charter lost correlated parent results"
  assert_grep 'For a terse result, a status line is the whole answer.' "$brief" \
    "secondmate charter lost terse result reporting"
  assert_grep 'append a status line that points to that doc' "$brief" \
    "secondmate charter lost detailed document pointers"
  assert_grep 'Report only true captain-relevant outcomes or a declared external wait' "$brief" \
    "secondmate charter lost declared external waits"
  assert_grep 'a captain decision, a real blocker, a failure, or work ready for review' "$brief" \
    "secondmate charter lost decisions, blockers, failures, or ready outcomes"
  assert_grep 'States: working, needs-decision, blocked, paused, done, failed.' "$brief" \
    "secondmate charter changed the preserved status vocabulary"
  pass "fm-brief.sh: marked requests avoid generic acknowledgements and preserve material reporting"
}

test_secondmate_directory_paths_are_absolute_and_output_is_stable() {
  local root home data_override state_override brief baseline err status
  root="$TMP_ROOT/relative-directory-inputs"
  mkdir -p "$root"
  root=$(cd "$root" && pwd -P)
  home="$root/home"
  data_override="$root/data-override"
  state_override="$root/state-override"
  mkdir -p "$home/data" "$home/state" "$data_override" "$state_override" \
    "$root/cdpath/home/data" "$root/cdpath/home/state" \
    "$root/cdpath/data-override" "$root/cdpath/state-override"

  brief="$home/data/relative-home/brief.md"
  FM_HOME="$home" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-home --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-home-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME=home FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-home --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_HOME changed charter bytes compared with the same absolute home"
  assert_grep ">> '$home/state/relative-home.status'" "$brief" \
    "relative FM_HOME did not render an absolute secondmate status path"

  brief="$home/data/relative-state/brief.md"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state_override" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-state --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-state-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME="$home" FM_STATE_OVERRIDE=state-override FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-state --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_STATE_OVERRIDE changed charter bytes compared with the same absolute state directory"
  assert_grep ">> '$state_override/relative-state.status'" "$brief" \
    "relative FM_STATE_OVERRIDE did not render an absolute secondmate status path"

  brief="$data_override/relative-data/brief.md"
  FM_HOME="$home" FM_DATA_OVERRIDE="$data_override" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-data --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-data-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME="$home" FM_DATA_OVERRIDE=data-override FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-data --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_DATA_OVERRIDE changed charter bytes compared with the same absolute data directory"
  assert_grep ">> '$home/state/relative-data.status'" "$brief" \
    "relative FM_DATA_OVERRIDE changed the absolute default status path"

  err="$root/unresolved.err"
  (
    cd "$root" || exit 1
    FM_HOME=missing-home FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-home --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_HOME must fail"
  assert_grep "FM_HOME directory cannot be resolved: missing-home" "$err" \
    "unresolved relative FM_HOME did not fail loudly"

  (
    cd "$root" || exit 1
    FM_HOME="$home" FM_STATE_OVERRIDE=missing-state FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-state --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_STATE_OVERRIDE must fail"
  assert_grep "FM_STATE_OVERRIDE directory cannot be resolved: missing-state" "$err" \
    "unresolved relative FM_STATE_OVERRIDE did not fail loudly"

  (
    cd "$root" || exit 1
    FM_HOME="$home" FM_DATA_OVERRIDE=missing-data FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-data --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_DATA_OVERRIDE must fail"
  assert_grep "FM_DATA_OVERRIDE directory cannot be resolved: missing-data" "$err" \
    "unresolved relative FM_DATA_OVERRIDE did not fail loudly"

  pass "fm-brief.sh: relative directory inputs ignore CDPATH, render stable absolute charter paths, or fail loudly"
}

test_herdr_lab_contract_applies_to_scouts_but_not_secondmates() {
  local home brief status=0
  home="$TMP_ROOT/herdr-kind-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" herdr-scout firstmate --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/herdr-scout/brief.md"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "scout --herdr-lab brief missing the contract"

  FM_HOME="$home" FM_SECONDMATE_CHARTER=ops "$ROOT/bin/fm-brief.sh" herdr-secondmate --secondmate firstmate --herdr-lab >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "secondmate --herdr-lab must be rejected"
  assert_absent "$home/data/herdr-secondmate/brief.md" \
    "rejected secondmate --herdr-lab still wrote a brief"
  pass "fm-brief.sh: Herdr lab contract covers scouts and rejects secondmate misuse"
}

test_pause_verb_override_renders_all_brief_scaffolds() {
  local home kind id brief states
  home="$TMP_ROOT/pause-verb-home"
  mkdir -p "$home/data"

  for kind in ship scout secondmate; do
    id="brief-pause-verb-$kind"
    case "$kind" in
      ship)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode no-mistakes >/dev/null 2>&1
        ;;
      scout)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
        ;;
      secondmate)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null 2>&1
        ;;
    esac
    brief="$home/data/$id/brief.md"
    case "$kind" in
      ship) states="States: working, note, needs-decision, blocked, awaiting, done, failed." ;;
      *)    states="States: working, needs-decision, blocked, awaiting, done, failed." ;;
    esac
    assert_grep "$states" "$brief" \
      "$kind brief did not render the configured pause verb in its states list"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_grep 'Use `awaiting: {why}`' "$brief" \
      "$kind brief did not instruct the configured pause status"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_no_grep '`paused: {why}`' "$brief" \
      "$kind brief still instructs the default paused status"
    assert_grep 'a blocker or wait clears' "$brief" \
      "$kind brief did not require durable resolution when a blocker clears"
    assert_grep 'even when the answer is what started that work' "$brief" \
      "$kind brief did not warn that an answer-started done/working never closes a decision"
  done
  pass "fm-brief.sh: custom pause verb renders in every scaffold"
}

test_scout_and_secondmate_load_decision_hold_policy() {
  local home scout charter
  home="$TMP_ROOT/decision-policy-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-brief.sh" sample-investigation sample --scout >/dev/null 2>&1
  scout="$home/data/sample-investigation/brief.md"
  assert_grep "$ROOT/.agents/skills/captain-hold-lifecycle/SKILL.md" "$scout" \
    "scout brief did not load the captain-call policy before done"
  assert_grep "pass its shared completion gate for the report and any visual review" "$scout" \
    "scout brief did not cross-reference visual-review completion"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SECONDMATE_CHARTER='sample reviews' \
    "$ROOT/bin/fm-brief.sh" sample-mate --secondmate --no-projects >/dev/null 2>&1
  charter="$home/data/sample-mate/brief.md"
  assert_grep "load \`captain-hold-lifecycle\`" "$charter" \
    "secondmate charter did not load the shared captain-call policy for detailed investigations"
  pass "fm-brief.sh: investigation and visual-review completions load the shared decision policy"
}

# The captain's instruction (2026-09-01) requires workers to ground themselves
# in PP Brain and the local memory store before acting, not just when a skill
# they happen to invoke requires it. This section belongs in ship and scout
# briefs, whose worker performs the task's first substantive action directly;
# a secondmate charter routes work to its own crewmates, who each get their
# own generated ship/scout brief carrying this same contract, so the charter
# itself does not need a duplicate copy.
test_grounding_section_requires_search_and_reporting() {
  local home id brief
  home="$TMP_ROOT/grounding-home"
  mkdir -p "$home/data"

  id="brief-grounding-ship"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "# Grounding" "$brief" "ship brief missing the Grounding section"
  # shellcheck disable=SC2016 # single quotes are deliberate: the backticks must stay literal
  assert_grep 'both `query` and `prompt` populated' "$brief" \
    "ship brief Grounding section did not require both PP Brain retrieval fields"
  assert_grep "the local memory store" "$brief" \
    "ship brief Grounding section did not mention the local memory store"
  assert_grep "Report what you found and what it changed" "$brief" \
    "ship brief Grounding section did not require reporting outcome, not just the search"
  assert_grep "starting point rather than a substitute" "$brief" \
    "ship brief Grounding section did not frame the Task section as a starting point"

  id="brief-grounding-scout"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --scout >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "# Grounding" "$brief" "scout brief missing the Grounding section"
  assert_grep "Report what you found and what it changed" "$brief" \
    "scout brief Grounding section did not require reporting outcome, not just the search"

  id="brief-grounding-secondmate"
  FM_HOME="$home" FM_SECONDMATE_CHARTER='sample domain' \
    "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_no_grep "# Grounding" "$brief" \
    "secondmate charter should not duplicate the Grounding section its own crewmates already carry"

  pass "fm-brief.sh: ship and scout briefs require Brain/memory grounding with reported outcome; secondmate charter does not duplicate it"
}

# The worker-operating contracts added on 2026-09-02 are ship-only: they govern
# the crewmate that performs the task itself. A scout produces a written report
# and a secondmate charter routes work to its own crewmates, whose generated
# ship briefs already carry these contracts, so neither may duplicate them.
test_ship_worker_operating_contracts() {
  local home brief dod
  home="$TMP_ROOT/worker-contracts-home"
  mkdir -p "$home/data"
  dod="$TMP_ROOT/worker-contracts-dod.txt"

  write_project_clone "$home" gh-proj https://github.com/acme/gh-proj.git
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-contracts-gh gh-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/brief-contracts-gh/brief.md"
  assert_present "$brief" "ship no-mistakes brief was not scaffolded"

  # A pp-brain auth warning in the session-start banner is a known false
  # positive, so only one real live call counts as evidence either way.
  # shellcheck disable=SC2016 # single quotes are deliberate: the backticks must stay literal
  assert_grep 'If the session-start banner reports `pp-brain: auth_missing`' "$brief" \
    "ship brief did not name the pp-brain auth banner as the warning to verify"
  # shellcheck disable=SC2016 # single quotes are deliberate: the backticks must stay literal
  assert_grep 'known false positive: make ONE real `search_knowledge` call before acting on it' "$brief" \
    "ship brief did not require one live search_knowledge call before believing the banner"
  assert_grep 'Only a failing live call is evidence - never stop, and never proceed without org context, on the banner alone.' "$brief" \
    "ship brief did not forbid both stopping and proceeding on the banner alone"

  # Degraded mode reuses an existing classifier verb with a fixed template, so
  # the supervisor classifies the outage instead of parsing invented prose.
  # shellcheck disable=SC2016 # single quotes are deliberate: the backticks must stay literal
  assert_grep 'append `blocked: <server> unreachable (confirmed by a live call, not the startup banner)` to the status file and stop' "$brief" \
    "ship brief did not carry the typed degraded-mode blocked: template"

  # Durable findings travel as supervisor-promoted candidates on the existing
  # status channel, never as worker writes into a shared store.
  # shellcheck disable=SC2016 # single quotes are deliberate: the backticks must stay literal
  assert_grep '`note: CANDIDATE - {finding}` rather than acting on it yourself' "$brief" \
    "ship brief did not route durable findings through the note: unread-surface channel"
  assert_grep "States: working, note, needs-decision, blocked, paused, done, failed." "$brief" \
    "ship brief instructs a note: line but omits note from its own states enumeration"
  # Delivery of a note: line does not depend on its wording, but the wedge
  # guards do not yet cover note:, so the brief discloses that gap honestly
  # instead of coaching the worker around word choices.
  # shellcheck disable=SC2016 # single quotes are deliberate: the backticks must stay literal
  assert_grep 'Every `note:` line reaches firstmate: the next status drain presents it whatever its wording.' "$brief" \
    "ship brief did not state that a note: line reaches firstmate regardless of its wording"
  # shellcheck disable=SC2016 # single quotes are deliberate: the backticks must stay literal
  assert_grep 'But `note:` is not yet covered by the supervision wedge guards that protect `working:`,' "$brief" \
    "ship brief did not disclose that note: lacks the wedge-guard coverage working:/resolved:/captain-held: have"
  assert_grep 'suppressed. That gap lives in those guards, not in note wording, and is tracked separately.' "$brief" \
    "ship brief did not place the wedge-guard gap outside the worker's note wording"
  # Word-substitution coaching cannot be complete, so it must not return.
  assert_no_grep 'Say it another way' "$brief" \
    "ship brief again coaches the worker to swap specific words, which no list can make complete"
  # shellcheck disable=SC2016 # single quotes are deliberate: the backticks must stay literal
  assert_grep 'A mid-task `working:` or `note:` line (including setup complete) is nonterminal' "$brief" \
    "ship brief did not declare a note: line nonterminal, so a worker may stop on one and look wedged"
  assert_grep 'you record candidates, only' "$brief" \
    "ship brief did not reserve promotion of candidates to firstmate"
  assert_grep 'never write to PP Brain or any shared memory system' "$brief" \
    "ship brief did not forbid direct writes to a memory system shared beyond this workstation"
  assert_no_grep 'narrow exception' "$brief" \
    "ship brief still carves an exception out of the shared-memory ban"

  # A terminal line with nothing before it tells the supervisor nothing, and
  # in no-mistakes mode the handoff done: line is the one firstmate acts on.
  # shellcheck disable=SC2016 # single quotes are deliberate: the backticks must stay literal
  assert_grep 'Before the FIRST `done:` or `failed:` line you write, send at least one `working:` status' "$brief" \
    "ship brief did not bind the substantive working: requirement to the first terminal line"
  assert_grep 'that carries real substance (a finding, a decision, a completed stage) - never end a task on' "$brief" \
    "ship brief did not require that working: line to carry real substance"

  # The wait on an open PR/MR is a colleague's approval; the captain cannot
  # approve their own, so the reminder must use the project's forge vocabulary.
  assert_grep 'If a declared wait concerns an open PR under review, describe it as awaiting a' "$brief" \
    "github ship brief did not carry the colleague-approval pause reminder in PR vocabulary"
  assert_grep "colleague's approval, never the captain's merge decision - the captain cannot approve their" "$brief" \
    "ship brief did not name the captain's merge decision as the wrong way to describe the wait"
  assert_no_grep "awaiting the captain's merge decision" "$brief" \
    "ship brief still describes the wait as the captain's merge decision"

  # Nothing in the ship brief mandates a write outside the disposable
  # worktree, so Rule 2's isolation guarantee carries no carve-out.
  assert_grep "2. Stay inside this worktree; modify nothing outside it." "$brief" \
    "ship Rule 2 lost its unqualified worktree-isolation guarantee"
  assert_no_grep "# Retrospective" "$brief" \
    "ship brief still mandates a retrospective whose writes escape the disposable worktree"
  assert_no_grep "retrospective" "$brief" \
    "ship brief still references the retrospective skill"

  # Every supervisor consumer classifies a task from the LAST status line, so
  # the Definition of done must end on its terminal done: line: a trailing
  # pause would supersede the completion and hide the PR/MR url.
  sed -n '/^# Definition of done$/,$p' "$brief" > "$dod"
  # shellcheck disable=SC2016 # single quotes are deliberate: the backticks must stay literal
  assert_grep 'append `done: PR {url} checks green` and stop. You are finished.' "$dod" \
    "no-mistakes DOD lost its terminal done: line"
  assert_no_grep "paused:" "$dod" \
    "no-mistakes DOD appends a pause after the terminal done: line, which supersedes the completion"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-contracts-gh-direct gh-proj --mode direct-PR >/dev/null 2>&1
  brief="$home/data/brief-contracts-gh-direct/brief.md"
  assert_present "$brief" "direct-PR ship brief was not scaffolded"
  assert_grep 'If a declared wait concerns an open PR under review, describe it as awaiting a' "$brief" \
    "direct-PR brief lost the colleague-approval pause reminder, which its own mode can reach"
  assert_grep "2. Stay inside this worktree; modify nothing outside it." "$brief" \
    "direct-PR Rule 2 lost its unqualified worktree-isolation guarantee"
  assert_no_grep "retrospective" "$brief" \
    "direct-PR brief still references the retrospective skill"
  sed -n '/^# Definition of done$/,$p' "$brief" > "$dod"
  # shellcheck disable=SC2016 # single quotes are deliberate: the backticks must stay literal
  assert_grep 'then append `done: PR {url}` to the status file and stop.' "$dod" \
    "direct-PR DOD lost its terminal done: line"
  assert_no_grep "paused:" "$dod" \
    "direct-PR DOD appends a pause after the terminal done: line, which supersedes the completion"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-contracts-gh-local gh-proj --mode local-only >/dev/null 2>&1
  brief="$home/data/brief-contracts-gh-local/brief.md"
  assert_present "$brief" "local-only ship brief was not scaffolded"
  assert_no_grep "If a declared wait concerns an open" "$brief" \
    "local-only brief carries a pause reminder about a PR its Rule 1 forbids it from opening"
  assert_grep "2. Stay inside this worktree; modify nothing outside it." "$brief" \
    "local-only Rule 2 lost its unqualified worktree-isolation guarantee"
  assert_no_grep "retrospective" "$brief" \
    "local-only brief still references the retrospective skill"

  write_project_clone "$home" gl-proj https://gitlab.com/acme/gl-proj.git
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-contracts-gl gl-proj --mode direct-PR >/dev/null 2>&1
  brief="$home/data/brief-contracts-gl/brief.md"
  assert_grep 'If a declared wait concerns an open MR under review, describe it as awaiting a' "$brief" \
    "gitlab ship brief did not carry the colleague-approval pause reminder in MR vocabulary"
  assert_grep "own merge request." "$brief" \
    "gitlab ship brief did not use the GitLab forge noun in the self-approval reminder"
  assert_no_grep "own pull request." "$brief" \
    "gitlab ship brief mixed GitHub vocabulary into the self-approval reminder"
  sed -n '/^# Definition of done$/,$p' "$brief" > "$dod"
  # shellcheck disable=SC2016 # single quotes are deliberate: the backticks must stay literal
  assert_grep 'then append `done: MR {url}` to the status file and stop.' "$dod" \
    "gitlab direct-PR DOD lost its terminal done: line"
  assert_no_grep "paused:" "$dod" \
    "gitlab direct-PR DOD appends a pause after the terminal done: line"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-contracts-scout gh-proj --scout >/dev/null 2>&1
  brief="$home/data/brief-contracts-scout/brief.md"
  assert_present "$brief" "scout brief was not scaffolded"
  assert_no_grep "note: CANDIDATE" "$brief" \
    "scout brief duplicated the ship-only CANDIDATE findings contract"
  assert_no_grep "unreachable (confirmed by a live call" "$brief" \
    "scout brief duplicated the ship-only degraded-mode template"
  assert_no_grep "colleague's approval" "$brief" \
    "scout brief duplicated the ship-only colleague-approval pause reminder"

  FM_HOME="$home" FM_SECONDMATE_CHARTER='sample domain' \
    "$ROOT/bin/fm-brief.sh" brief-contracts-sm --secondmate --no-projects >/dev/null 2>&1
  brief="$home/data/brief-contracts-sm/brief.md"
  assert_present "$brief" "secondmate charter was not scaffolded"
  assert_no_grep "note: CANDIDATE" "$brief" \
    "secondmate charter duplicated the ship-only CANDIDATE findings contract"
  assert_no_grep "unreachable (confirmed by a live call" "$brief" \
    "secondmate charter duplicated the ship-only degraded-mode template"

  pass "fm-brief.sh: ship briefs carry the worker-operating contracts and keep a terminal done: line; scout/secondmate do not duplicate them"
}

# Scout and secondmate paths still scaffold well-formed briefs.
test_scout_and_secondmate_scaffold() {
  local brief
  FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-scout-q6 alpha --scout >/dev/null 2>&1 \
    || fail "fm-brief.sh scout scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-scout-q6/brief.md"
  assert_present "$brief" "scout brief was not scaffolded"
  assert_grep "SCOUT task" "$brief" "scout brief must declare itself a scout task"
  assert_grep "report.md" "$brief" "scout brief must point at the report deliverable"
  assert_grep "you may host the Lavish review loop yourself" "$brief" \
    "scout brief must mention the option to host a Lavish review loop"

  FM_SECONDMATE_CHARTER='Supervise the alpha domain.' \
    FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-sm-q6 --secondmate alpha >/dev/null 2>&1 \
    || fail "fm-brief.sh secondmate scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-sm-q6/brief.md"
  assert_present "$brief" "secondmate charter was not scaffolded"
  assert_grep "persistent second mate" "$brief" \
    "secondmate charter must declare its role"
  pass "fm-brief: scout and secondmate code paths still scaffold well-formed briefs"
}

# The generated brief must name the forge the project actually uses (derived
# from its local clone's origin remote) instead of assuming GitHub: GitHub
# gets gh-axi/"pull request"/PR, GitLab gets glab/"merge request"/MR (both a
# gitlab.com host and a self-hosted host carrying .gitlab-ci.yml), and a
# project with no resolvable forge gets an explicit unresolved marker rather
# than a confident wrong answer.
test_forge_detection_shapes_vocabulary() {
  local home brief
  home="$TMP_ROOT/forge-home"
  mkdir -p "$home/data"

  write_project_clone "$home" gh-proj https://github.com/acme/gh-proj.git
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-forge-gh gh-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/brief-forge-gh/brief.md"
  assert_grep "Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations." "$brief" \
    "github clone: rule 3 must name gh-axi and GitHub"
  assert_grep "Never merge a pull request." "$brief" "github clone: rule 1 must say pull request"
  assert_grep "append \`done: PR {url} checks green\`" "$brief" "github clone: done line must use PR"
  assert_no_grep "glab" "$brief" "github clone: brief must not mention glab"

  write_project_clone "$home" gl-proj https://gitlab.com/peterpark/gl-proj.git
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-forge-gl gl-proj --mode direct-PR >/dev/null 2>&1
  brief="$home/data/brief-forge-gl/brief.md"
  assert_grep "Use glab for GitLab operations and chrome-devtools-axi for browser operations." "$brief" \
    "gitlab.com clone: rule 3 must name glab and GitLab"
  assert_grep "open a merge request with glab, then append \`done: MR {url}\`" "$brief" \
    "gitlab.com clone: DOD must use merge request/glab/MR"
  assert_no_grep "gh-axi" "$brief" "gitlab.com clone: brief must not mention gh-axi"

  write_project_clone "$home" gl-self self.example.internal:group/gl-self.git gitlab-ci
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-forge-glself gl-self --scout >/dev/null 2>&1
  brief="$home/data/brief-forge-glself/brief.md"
  assert_grep "Use glab for GitLab operations and chrome-devtools-axi for browser operations." "$brief" \
    "self-hosted GitLab clone (.gitlab-ci.yml, non-matching host): rule 3 must still resolve to glab"
  assert_grep "the deliverable is a written report, not a merge request." "$brief" \
    "GitLab scout: the Setup line must name the project's forge noun"
  assert_no_grep "not a PR." "$brief" \
    "GitLab scout: the Setup line must not mix GitHub vocabulary into a GitLab brief"

  write_project_clone "$home" unk-proj https://code.example.org/team/unk-proj.git
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-forge-unk unk-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/brief-forge-unk/brief.md"
  assert_grep "This project's forge could not be determined from its git remote" "$brief" \
    "unresolvable forge: brief must carry a loud unresolved marker, not a confident guess"
  assert_grep "run \`git remote -v\` to check, then use gh-axi for GitHub or glab for GitLab" "$brief" \
    "unresolvable forge: brief must tell the worker how to check"
  assert_grep "append \`done: PR/MR {url} checks green\`" "$brief" \
    "unresolvable forge: done-line convention must not silently default to PR"

  write_project_clone "$home" no-origin-proj ""
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-forge-noorigin no-origin-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/brief-forge-noorigin/brief.md"
  assert_grep "This project's forge could not be determined from its git remote" "$brief" \
    "clone with no origin remote: brief must carry the same unresolved marker"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-forge-noclone never-cloned --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/brief-forge-noclone/brief.md"
  assert_grep "This project's forge could not be determined from its git remote" "$brief" \
    "project with no local clone: brief must carry the same unresolved marker"

  pass "fm-brief.sh: brief vocabulary matches the project's actual forge"
}

# A leftover `.github` directory is not evidence of the forge a project ships
# to: a repo migrated to a self-hosted GitLab whose host carries no gitlab
# token keeps its old `.github/workflows`. Detection must stay unresolved.
test_forge_detection_rejects_bare_github_dir() {
  local home brief
  home="$TMP_ROOT/forge-ghdir-home"
  mkdir -p "$home/data"
  write_project_clone "$home" ghdir-proj https://code.example.org/team/ghdir-proj.git
  mkdir -p "$home/projects/ghdir-proj/.github/workflows"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-forge-ghdir ghdir-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/brief-forge-ghdir/brief.md"
  assert_grep "This project's forge could not be determined from its git remote" "$brief" \
    "unrecognized host with a .github directory: brief must stay unresolved"
  assert_no_grep "Use gh-axi for GitHub operations" "$brief" \
    "unrecognized host with a .github directory: brief must not declare GitHub"
  assert_grep "append \`done: PR/MR {url} checks green\`" "$brief" \
    "unrecognized host with a .github directory: done line must not default to PR"
  pass "fm-brief.sh: a bare .github directory alone never declares GitHub"
}

# The repo argument accepts three spellings that must all name one clone: a
# projects/<name> path and an absolute path, both shared with bin/fm-spawn.sh's
# resolve_project_dir_arg, plus a bare name that deliberately diverges from
# fm-spawn's cwd-relative handling to keep fm-brief's own $PROJECTS/<name>
# convention. The same clone must yield identical forge vocabulary through all.
test_forge_detection_accepts_repo_arg_spellings() {
  local home brief spelling id n
  home="$TMP_ROOT/forge-spelling-home"
  mkdir -p "$home/data"
  write_project_clone "$home" spell-proj https://gitlab.com/peterpark/spell-proj.git

  n=0
  for spelling in spell-proj projects/spell-proj "$home/projects/spell-proj"; do
    n=$((n + 1))
    id="brief-forge-spelling-$n"
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "$spelling" --mode no-mistakes >/dev/null 2>&1
    brief="$home/data/$id/brief.md"
    assert_grep "Use glab for GitLab operations and chrome-devtools-axi for browser operations." "$brief" \
      "repo spelling '$spelling': rule 3 must name glab and GitLab"
    assert_grep "Never merge a merge request." "$brief" \
      "repo spelling '$spelling': rule 1 must say merge request"
    assert_grep "append \`done: MR {url} checks green\`" "$brief" \
      "repo spelling '$spelling': done line must use MR"
    assert_no_grep "This project's forge could not be determined from its git remote" "$brief" \
      "repo spelling '$spelling': a resolvable clone must not render the unresolved marker"
  done
  pass "fm-brief.sh: all three repo-argument spellings resolve the same clone's forge"
}

# A firstmate home is itself a git checkout with projects/ gitignored inside it,
# so a projects/<repo> directory that is not its own clone root - a worktree
# container, a placeholder, a half-finished clone - makes git discovery walk UP
# to the enclosing firstmate repo (a GitHub remote). The brief must report the
# forge as unresolved rather than confidently emitting GitHub vocabulary for a
# project whose real forge is something else.
test_forge_detection_ignores_enclosing_repo() {
  local home brief
  home="$TMP_ROOT/forge-nested-home"
  mkdir -p "$home/data"
  git -C "$home" init -q
  git -C "$home" remote add origin https://github.com/alandomio/firstmate.git
  mkdir -p "$home/projects/nested-proj"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-forge-nested nested-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/brief-forge-nested/brief.md"
  assert_grep "This project's forge could not be determined from its git remote" "$brief" \
    "non-root project dir: brief must not inherit the enclosing firstmate repo's forge"
  assert_no_grep "Use gh-axi for GitHub operations" "$brief" \
    "non-root project dir: brief must not claim GitHub from the enclosing repo's remote"
  pass "fm-brief.sh: a project dir that is not its own clone root resolves unknown"
}

# Forge detection must resolve the clone through the same projects-dir override
# every other resolver honors. A home invoked with FM_PROJECTS_OVERRIDE has no
# $FM_HOME/projects, so hardcoding that path made every brief in such a home
# fall back to the unresolved marker even for a known GitLab project.
test_forge_detection_honors_projects_override() {
  local home projects brief
  home="$TMP_ROOT/forge-override-home"
  projects="$TMP_ROOT/forge-override-projects"
  mkdir -p "$home/data"
  write_clone_at "$projects/gl-proj" https://gitlab.com/peterpark/gl-proj.git

  FM_HOME="$home" FM_PROJECTS_OVERRIDE="$projects" \
    "$ROOT/bin/fm-brief.sh" brief-forge-override gl-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/brief-forge-override/brief.md"
  assert_grep "Use glab for GitLab operations and chrome-devtools-axi for browser operations." "$brief" \
    "FM_PROJECTS_OVERRIDE home: rule 3 must resolve the overridden clone's forge"
  assert_grep "append \`done: MR {url} checks green\`" "$brief" \
    "FM_PROJECTS_OVERRIDE home: done line must use the overridden clone's forge"
  assert_no_grep "This project's forge could not be determined from its git remote" "$brief" \
    "FM_PROJECTS_OVERRIDE home: a resolvable clone must not render the unresolved marker"
  pass "fm-brief.sh: forge detection honors FM_PROJECTS_OVERRIDE"
}

test_script_parses
test_no_heredoc_in_command_substitution
test_help_includes_entire_header
test_ship_modes_generate_clean_briefs
test_ship_mode_is_required_and_closed_set
test_ship_mode_is_explicit_not_registry
test_delivery_flags_are_refused_where_they_do_not_apply
test_faster_paths_use_configured_authority_without_stacked_review
test_mr_description_skill_required_for_pr_modes
test_no_mistakes_dod_wording
test_ship_project_memory_wording
test_herdr_lab_contract_is_explicit_and_complete
test_herdr_lab_contract_quotes_foreign_firstmate_path
test_herdr_lab_omission_is_loud_for_ship_and_scout
test_herdr_lab_contract_applies_to_scouts_but_not_secondmates
test_secondmate_no_projects_charter
test_secondmate_marked_request_reporting_contract
test_secondmate_directory_paths_are_absolute_and_output_is_stable
test_pause_verb_override_renders_all_brief_scaffolds
test_scout_and_secondmate_load_decision_hold_policy
test_grounding_section_requires_search_and_reporting
test_ship_worker_operating_contracts
test_scout_and_secondmate_scaffold
test_forge_detection_shapes_vocabulary
test_forge_detection_rejects_bare_github_dir
test_forge_detection_accepts_repo_arg_spellings
test_forge_detection_ignores_enclosing_repo
test_forge_detection_honors_projects_override
