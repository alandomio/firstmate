---
name: worker-steering
description: Agent-only procedure for talking to and controlling a live worker or secondmate. Load before steering or answering a worker, before interrupting, exiting, or relaunching one, when the captain adds or changes an ask mid-task, and when reconciling a marked secondmate request.
user-invocable: false
metadata:
  internal: true
---

# Worker steering

This skill owns how firstmate sends text to a live worker and drives its lifecycle.
`bin/fm-send.sh`, `bin/fm-control.sh`, and `bin/fm-task-inbox-lib.sh` own the exact mechanics in their headers and help.

## Steer with text

Steer a worker with ordinary text through fail-closed `fm-send`: the message becomes a durable record in the task's steering inbox (multi-line text is legal, local and remote alike) and the worker's terminal receives only a constant doorbell line, with the watcher re-ringing an unacknowledged local message and escalating a stuck one (`bin/fm-task-inbox-lib.sh`; `bin/fm-send.sh` owns the typed-plane carve-outs).
A remote secondmate steer rides the same durable-inbox model through the remote transport; after an unconfirmed delivery, only the exact `FM_PENDING_REPLY_EXISTING_CORR=<id>` resend command printed by `fm-send` is safe because it preserves the request body for remote enqueue deduplication (`bin/fm-send.sh` header).
When a steer answers an open keyed decision or blocker, pass `fm-send`'s `--resolve-key` so the answer itself closes that decision record at answer time, identically for local and remote workers (contract: `bin/fm-send.sh` header).

## Drive the lifecycle

`fm-send` is the data plane for text the worker should read; never use its key or text paths for interrupt, exit, or other lifecycle control, because routing-marked lifecycle text becomes chat the worker reasons about instead of executing.
Drive a worker's lifecycle through `bin/fm-control.sh <task-id> interrupt|exit|relaunch`, which owns the per-runtime mechanics, verifies each action, and never tears down or discards anything ([`docs/agent-control.md`](../../../docs/agent-control.md)).

## Secondmate replies

A secondmate's routed reply returns through status or a document pointer, not by firstmate peeking into its chat.
For the parent-owned correlation, recovery, and escalation contract on marked secondmate requests, see `bin/fm-pending-reply-lib.sh`.

## Captain changes mid-task

When the captain adds or changes an ask mid-task, append the captain's words without added speaker labels or direct address to that brief's `## Captain's intent` and relay those words to the worker; Firstmate build constraints stay in `## Firstmate spec` or the steer.
