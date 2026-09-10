# Regression + guard verification

## 1. Contract phrases in the real emitted briefs
```
emitted-brief contract phrase                              ship@base ship@HEAD scout@base scout@HEAD
--------------------------------------------------------------------------------------------------
searching costs only latency, so search again whenever a n absent    PRESENT   absent     PRESENT   
When you hit an obstacle, surprising behavior, or trap, ch absent    PRESENT   absent     PRESENT   
append `note: CANDIDATE - {finding}` if it is not          absent    PRESENT   absent     PRESENT   
never write to PP Brain or any shared memory directly, onl absent    PRESENT   absent     PRESENT   
States: working, note, needs-decision, blocked, paused, do PRESENT   PRESENT   absent     PRESENT   
pp-brain: auth_missing                                     PRESENT   PRESENT   absent     absent    
Only a failing live call is evidence                       PRESENT   PRESENT   absent     absent    
{TASK}                                                     PRESENT   PRESENT   PRESENT    PRESENT   
Stay inside this worktree                                  PRESENT   PRESENT   PRESENT    PRESENT   
```

## 2. The scout leak guard is non-vacuous

Round-2 concern: the ship-only Rule 4 phrase must exist on ONE physical line of a generated brief, otherwise the line-based `assert_no_grep` can never fire. Counted with `grep -Fc` on the real briefs:
```
ship brief : 1 match(es) for "firstmate promotes them, and you must never write to PP Brain"
scout brief: 0 match(es)

as emitted in the ship brief:
49:   `note: CANDIDATE - {finding}` rather than acting on it yourself: you record candidates, only
50-   firstmate promotes them, and you must never write to PP Brain or any shared memory directly.
```

## 3. tests/fm-brief.test.sh fails against the pre-fix generator

Same test file, `bin/fm-brief.sh` temporarily swapped to its base-commit version (restored afterwards; `git status` clean):
```
$ bash tests/fm-brief.test.sh   # with base-commit bin/fm-brief.sh
ok - fm-brief.sh: Herdr lab contract covers scouts and rejects secondmate misuse
ok - fm-brief.sh: --no-projects scaffolds a project-less charter and guards misuse
ok - fm-brief.sh: marked requests avoid generic acknowledgements and preserve material reporting
ok - fm-brief.sh: relative directory inputs ignore CDPATH, render stable absolute charter paths, or fail loudly
not ok - scout brief did not render the configured pause verb in its states list
exit code: 1
```

## 4. `bin/fm-brief.sh --help` renders the updated header contract
```
Ship and scout briefs include a Grounding section requiring PP Brain and
local-memory-store search before the first substantive action, a repeated
search whenever a later obstacle or subject comes up since latency is the
only cost, a check of PP Brain before working around any gotcha (citing it,
or filing a note: CANDIDATE when it is silent, never writing to PP Brain or
any shared memory itself), and a reported outcome; a secondmate charter omits
it because its own crewmates each get their own generated brief carrying the
same contract.
```
