# Promises and the sentinel

This document explains how a home keeps the deadlines the captain gives in chat and how it notices when its own supervision has stopped.
Read it when installing the sentinel on a host, when a deadline alert or the morning digest is missing, or when changing any of the three scripts below.

| Piece | Owner | What it does |
| --- | --- | --- |
| Promises | `bin/fm-promise.sh` | Dated commitments, deadline alerts, decisions that block a deadline, the morning digest text |
| Turn-end check | `bin/fm-promise-turnend.sh` | Blocks a Claude primary's turn end while a captain deadline is unregistered, and surfaces blocking decisions every turn |
| Sentinel | `bin/fm-sentinel.sh` | Runs every five minutes outside any agent session: deadline alerts, supervision liveness, recovery, captain alerts, the 08:30 digest, the shutdown and suspend notice |

Each script's header owns its exact commands, flags, file formats, and environment knobs.

## Promises

A promise is a commitment with a due date and time, registered in the same turn the captain states it and echoed back as `Registrato: ... entro ...`.
Records live in `data/promesse/`, the directory the earlier local promise tool used, so its records stay readable and its condition checks keep running.
Each open promise also registers a watcher check, so the home keeps needing supervision while a promise is open and firstmate is woken at the same thresholds the captain is.

The captain gets one Telegram message at each stage: two hours before the deadline, thirty minutes before, and once overdue.
A promise registered inside a later window gets only that window's message.
A failed send is retried on the next sentinel run.
Messages go to the configured owner's private chat when it is listed in `allowed_chats` of `config/telegram.json`; [`docs/telegram.md`](telegram.md) owns that setup.
A reply on Telegram is information, never authorization.

When a captain decision blocks a deadlined promise, `fm-promise.sh block` ties the decision to it.
Until `unblock`, every captain turn receives the `BLOCCA SCADENZA hh:mm` lines as context, every alert repeats the decision, and the morning digest leads with it.
Firstmate never decides in the captain's place.

Deadlines found in client mail, meeting notes, or Jira due dates are proposed to the captain first and registered only after the captain agrees.

## Turn-end check

On a Claude primary, the tracked `.claude/settings.json` runs `bin/fm-promise-turnend.sh` on UserPromptSubmit and on Stop.
When the captain's last message contains an Italian time expression and nothing was registered after it, the Stop hook blocks the turn end and names the two ways out: register the promise, or record `fm-promise.sh none '<why>'` when the phrase is not a deadline.
The override is logged in `data/promesse/registro.log`.
The hook blocks at most twice per message and then logs an `unregistered` event, so a broken registry cannot wedge the session.
Crew and scout worktrees are out of scope, exactly as for the supervision turn-end guard.
Other primary harnesses do not run this check yet.

## Sentinel

The sentinel is a systemd user timer, so it keeps running when the agent session, its hooks, and its watcher have all stopped.
Each run sends due deadline alerts, records a heartbeat, and checks supervision with the same model-aware verdict `bin/fm-guard.sh` uses, evaluated for the harness of the session that holds the home's lock.

When supervision is needed and that verdict fails, the sentinel opens a down episode and does two things:

- It asks the session to recover by typing one Firstmate operational input into the lock holder's pane, only into an empty input box and never during a running turn.
  The input tells the session to drain its wakes and end the turn, which re-arms the watcher through the harness's own path; the sentinel never starts or kills a watcher itself.
- It alerts the captain on Telegram, once per episode and again every hour while it lasts, saying what it tried.
  When no live session holds the home, the alert says the session must be reopened.

A fresh beacon closes the episode with one "ripristinata" message.
The sentinel counts 240 seconds of beacon silence as down, so with the timer every five minutes recovery is requested at most nine minutes after the last sign of life, leaving a minute for the session's turn to re-arm.

Every morning at 08:30 the sentinel sends `Sorveglianza attiva, impegni di oggi: ...`, or a warning when supervision is down.
A missing morning message means the sentinel, the timer, the laptop, or the Telegram channel is broken.
The timer is persistent, so a laptop asleep at 08:30 sends the message when it wakes.

When the laptop shuts down or suspends normally while a dated promise is open, the captain gets one immediate message, `Portatile spento con N impegni aperti: ...`, listing each commitment with its deadline.
A reboot sends nothing.
A sudden power or network loss cannot send it; that is the cloud check's job.

### Install

```sh
bin/fm-sentinel.sh install               # writes and enables the two user timers for this home
sudo bin/fm-sentinel.sh install-power    # the shutdown and suspend notice units, run as you
bin/fm-sentinel.sh status                # timers, current verdict, last log lines
bin/fm-sentinel.sh uninstall             # and: sudo bin/fm-sentinel.sh uninstall-power
```

The units are named after a checksum of the home path, so several homes on one host do not collide.
The notice units are system units because a user timer cannot run before suspend; they still run the script as the home's owner.
Actions are logged to `state/sentinel.log`.

### Drill

The drill proves the whole chain on a Claude primary:

```sh
bin/fm-sentinel.sh drill start    # kills this home's own supervision process group
bin/fm-sentinel.sh drill report   # after two timer runs: detection, recovery, alerts, timings
```

`drill start` kills only the process group of this home's Claude Stop auto-arm owner, read from its own ledger and checked against its command line, which is what a timed-out or crashed hook leaves behind.
Pass means the report shows a recovery request within ten minutes, a Telegram alert, and a fresh watcher beacon afterwards.

## Cloud dead-man's switch

The laptop cannot report its own power loss, sleep, or network loss, so an outside check must notice the heartbeat stopping.
The sentinel runs the one shell line in the optional, gitignored `config/sentinel-heartbeat` on every run, bounded to 20 seconds; [`docs/configuration.md`](configuration.md#sentinel-heartbeat-and-cloud-arming-configsentinel-heartbeat-configsentinel-arm-configsentinel-disarm) owns the file.
The receiving side is a deployment choice outside this repository; it must alert the captain on Telegram when no heartbeat arrives for about fifteen minutes.

The laptop is often off on purpose, so the outside check should alert only while there is something to miss.
`bin/fm-promise.sh` arms it, by running the one line in the optional, gitignored `config/sentinel-arm`, when the first dated promise opens, and disarms it with `config/sentinel-disarm` when the last one closes.
Every sentinel run re-applies a failed or pending change, and each change is logged in `data/promesse/registro.log`.
The heartbeat keeps running while disarmed, so arming finds a fresh signal.
Neither file may contain a secret; [`docs/configuration.md`](configuration.md#sentinel-heartbeat-and-cloud-arming-configsentinel-heartbeat-configsentinel-arm-configsentinel-disarm) owns them.
