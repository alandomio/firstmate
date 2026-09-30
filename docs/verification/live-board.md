# Live fleet board verification

Audience: maintainer verification.

This record holds the version-scoped Lavish facts the live fleet board depends on.
`docs/configuration.md` ("Live fleet board") owns the operating contract, `bin/fm-bearings-board.sh`'s header owns the refresh mechanics, and `tests/fm-bearings-board.test.sh` pins the composition and page behavior.
Refresh this record after a `lavish-axi` upgrade by repeating the probe below.

Verified on 2026-09-30 on Linux 6.14.0-37-generic with `lavish-axi` 0.1.53 and headless Google Chrome 144.0.7559.59, against an isolated Lavish server (`LAVISH_AXI_STATE_DIR` and `LAVISH_AXI_PORT` pointed at scratch values, `LAVISH_AXI_NO_OPEN=1`).

## A sibling data file refreshes the page without reloading it

The live board relies on three facts: the sandboxed artifact frame can load a sibling script by relative URL, a replaced sibling file is served fresh, and only a change to the page file itself makes Lavish reload the frame.

Probe: a page that sets `window.__mark` once, then every 2 seconds appends a script element loading the sibling file `probe.data.js` with a cache-busting query; that file calls `window.fmProbe("<version>")` to write the version into a heading.
A Chrome DevTools Protocol driver opened the Lavish session URL, attached to the artifact frame's target, and read the heading and the mark:

```text
t0: loaded v1 | original-document
after atomic sidecar replace: loaded v3 | mark: original-document
control, after page file edit: loaded v3 | mark: undefined
```

Replacing `probe.data.js` by rename updated the heading while the mark survived, so the frame was not reloaded; appending a comment to the page file cleared the mark, so the frame was reloaded.
Lavish 0.1.53 watches only the session's page file unless the page opts in to directory watching with `data-lavish-live-reload-root` or `<meta name="lavish-live-reload" content="root">`, which the board template does not carry.

## Queued answers live in the Lavish chrome, not the page

Lavish 0.1.53 keeps queued prompts in the chrome's `sessionStorage` (`persistQueuedPrompts` in `dist/chrome-client.js`), outside the sandboxed artifact frame, so a page re-render or reload does not drop an answer the captain queued but has not sent.
It also replays `[data-lavish-question]` field values into the new document after a page-file reload (`lavish:restoreReviewState`), which covers the full reload a `build` causes.

End-to-end check through `bin/fm-bearings-board.sh build` and `refresh` in a scratch home with a fixture snapshot: the captain types into the active card, a refresh runs, and 33 seconds later the page shows the new data while keeping the draft and focus, then a submit reaches the chrome queue.

```text
before: {"mark":"first-load","titles":["Composed title","Merge: widget fix","Already answered","Merge: gone","A raw card copied back"],"visible":["Composed title"],"drafts":["","","","",""],"notes":["","","","",""],"focused":"","fresh":"updated 2 h ago","prs":[],"underwayAges":[],"stack":"card 1 of 5"}
refresh: refreshed: $H/.lavish/bearings-board.data.js
after refresh: {"mark":"first-load","titles":["Composed title","Merge: widget fix","Pick the export window"],"visible":["Composed title"],"drafts":["ship it after the demo","",""],"notes":["","",""],"focused":"bb-freeform","fresh":"live · updated just now","prs":["widget #9","api #3"],"underwayAges":["2 min"],"stack":"card 1 of 3"}
chrome queue: ["Captain's Call answer - Composed title: ship it after the demo\n\nContext data:\n{\n  \"question\": \"composed-call\",\n  \"answer\": \"ship it after the demo\",\n  \"close\": \"release\"\n}"]
```

## Allowed hosts behind a proxy

Lavish 0.1.53 answers a request whose `Host` and `X-Forwarded-Host` name a host listed in `LAVISH_AXI_ALLOWED_HOSTS` and refuses any other name, which is what the documented Tailscale Serve exposure relies on:

```text
$ LAVISH_AXI_ALLOWED_HOSTS=board-host.example.ts.net lavish-axi .lavish/probe.html
$ curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: board-host.example.ts.net' -H 'X-Forwarded-Host: board-host.example.ts.net' -H 'X-Forwarded-Proto: https' http://127.0.0.1:<port>/session/<key>
200
$ curl ... -H 'Host: other.example.ts.net' -H 'X-Forwarded-Host: other.example.ts.net' ...
403
```

Tailscale Serve itself was not exercised in this record.
