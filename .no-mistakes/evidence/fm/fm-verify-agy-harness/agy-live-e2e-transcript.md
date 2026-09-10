# agy (Antigravity CLI) adapter — live end-to-end verification

Host: Linux, tmux 3.4, **agy 1.2.0** (`agy --version`), sqlite3 from Android platform-tools.
Workspace: a throwaway git repo at `/tmp/agy-e2e-*/ws` (NOT the firstmate worktree).
Everything below drove firstmate's real code paths on the target commit against a
real, token-spending agy session in a real tmux pane.

## 1. Launch shape

`bin/fm-spawn.sh` emits (captured in `agy-spawn-launch-command.txt`):

    env -u CURSOR_AGENT -u CURSOR_INVOKED_AS env -u CLAUDECODE -u AI_AGENT -u PI_CODING_AGENT \
      -u GROK_AGENT -u FM_PI_HARNESS agy --dangerously-skip-permissions \
      --model 'gemini-3.7-flash' --effort 'high' -i "$(.../fm-operational-input.sh encode launch-brief < .../brief.md)"

The live pane was launched with exactly that shape. agy started, showed a
first-launch workspace trust prompt ("Do you trust the contents of this project?"),
and after confirmation ran the brief.

## 2. Harness detection, end to end

The steer asked agy to run `bin/fm-harness.sh` with its own shell tool. agy's own
tool subprocess printed (see `agy-live-pane-harness-detect.txt`):

    ● Bash(/…/bin/fm-harness.sh)
      Exact stdout:
        agy

## 3. Semantic busy state (agy's own SQLite conversation database)

Binding resolved from the `state/<id>.agy-session` sidecar seeded exactly as
fm-spawn seeds it:

    bound conversation: ~/.gemini/antigravity-cli/conversations/34ad7f00-…-e0696a97b16b.db

`fm_busy_classify tmux <pane> agy <id> <state>` polled at 1 Hz through two real
turns (`agy-live-busy-poll.txt`) — the source name and the pane identity agree
throughout, and `busy agy-conversation` is reported for the whole working window,
including the FIRST turn (the round-1 `.db-wal` blind spot):

    05:10:57  busy=idle agy-conversation  identity=agy/working
    05:10:58  busy=busy agy-conversation  identity=agy/working
    …
    05:11:57  busy=busy agy-conversation  identity=agy/working
    05:11:59  busy=idle agy-conversation  identity=agy/idle

## 4. Interrupt = a single Escape, no clear key

`fm_control_interrupt_key/repeat/clear_key/exit_command` returned
`Escape / 1 / <none> / /exit`. Those exact values were replayed against a live
generation turn (`agy-live-interrupt-poll.txt`):

    05:12:42  busy=busy agy-conversation  identity=agy/working  footer=esc to cancel
    05:12:43  busy=busy agy-conversation  identity=agy/working  footer=esc to cancel   <- Escape x1 sent 05:12:43
    05:12:44  busy=idle agy-conversation  identity=agy/idle     footer=? for shortcuts

Pane after the interrupt (`agy-live-pane-after-interrupt.txt`):

    ⎿  Interrupted · What should Antigravity CLI do instead?

Composer read `empty` immediately afterwards — no clear key needed, as the
control table claims.

## 5. Exit

`fm_control_exit_command agy` -> `/exit`; typing it ended the agy process and the
tmux pane (`tmux has-session` -> gone, no agy process left).

## 6. Composer classification, including the background-task strip regression

Live screen with agy's running-background-task strip below the composer
(`agy-live-pane-taskstrip.txt`, footer `1 task(s) · /tasks`):

    ────────────────────────────────  <- composer open rule
    >
    ────────────────────────────────  <- composer close rule
      ● [05:10:05] sleep 45 && echo LATE_TASK_DONE running
    ────────────────────────────────  <- task-strip close rule

`fm_tmux_composer_state` against that live pane:

| screen                          | pre-fix lib (69e61e3) | target commit |
|---------------------------------|-----------------------|---------------|
| empty composer + task strip     | `unknown`             | `empty`       |
| typed composer + task strip     | `unknown`             | `pending`     |

`fm_tmux_composer_identity` reported the real `agy/idle` tuple in both cases.
The pre-fix `unknown` is what made `bin/fm-send.sh` report
"text not submitted … delivery unconfirmed" for a steer that had landed.

## 7. Real steer delivery through the submit path, with the strip on screen

    fm_tmux_submit_core <pane> "Run this shell command and report its exact stdout: …/bin/fm-harness.sh …" 3 0.4 0.3
    -> empty

`empty` is the delivered verdict fm-send maps to success; agy then answered the
steer (section 2 above).
