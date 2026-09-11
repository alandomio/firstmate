# /bearings board: mandatory response box + honest bridge refusal

All screenshots are the **real shipped board** (`bin/fm-bearings-board.sh build` output, or the
same template with the same payload injected) rendered in headless Google Chrome 152 from
`file://`. In a plain browser there is no Lavish host runtime, so `window.lavish` is genuinely
absent - which is exactly the lost-bridge condition the new guards exist for.

| file | what it shows |
| --- | --- |
| `01-board-card1-response-box.png` | the built board as the captain sees it; the first Captain's Call card carries the open response box under its preset options |
| `02-card3-option-less-freeform-only.png` | card 3 has `options: []` - answerable only through the box (`your orders, captain`), the shape the new rule unlocks |
| `03-answer-refused-no-bridge.png` | **post-fix**: answering with the bridge gone shows `Answer not sent - the board's connection is unavailable. Reload the board and try again.` in the card's own alert; no queued mark, deck stays on card 1, header still says 3 items wait |
| `04-answer-queued-healthy-bridge.png` | the healthy path is untouched: with a working `queuePrompt` the answer queues, the deck deals card 2, header reads `card 2 of 3 · 1 answered` - and card 2 carries its own box (`name a condition, captain`) |
| `05-dispatch-refused-no-bridge.png` | the dispatch bar refuses in its own new `role="alert"` element beside the unchanged `1 picked for dispatch` count; no queued badge |
| `06-PREFIX-answer-falsely-marked-queued.png` | **pre-fix (base commit) template, identical payload and identical click**: no error at all, the deck advanced and the header claims `· 1 answered` - the silent swallow this change removes (compare with 03) |
| `07-PREFIX-merge-card-without-a-response-box.png` | **pre-fix**: a card whose payload omits `allow_freeform` renders with preset options only - the captain cannot answer anything the composer did not think of |
| `08-POSTFIX-same-card-still-gets-the-response-box.png` | **post-fix**, same flag-less payload: the renderer gives the box anyway (and `fm-bearings-board.sh build` refuses that payload outright - see the CLI transcript) |
| `validator-cli-transcript.txt` | `build` accepts a payload where every card carries `allow_freeform: true`, and refuses (exit 1) both a card missing the flag and a card with `allow_freeform: false`, without touching the board already on disk |
| `regression-prefix-vs-postfix.txt` | the DOM harness run against the base-commit runtime vs the fixed one: missing bridge, throwing bridge, and flag-less option-less card |
