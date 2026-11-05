import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { after, before, test } from "node:test";
import { hello, messageEnvelope, startFakeSlack } from "./fake-slack.mjs";
import { REQUEST_ID, TOKEN, fakeSecurity, pollRequest, run, tempDir } from "./helpers.mjs";

const ASK = "C08D5AM39F0";
const INTERNAL = "C088ESUUM2N";
const ENGINEER = "U0EXAMPLE01";
const BOT = "U0CEL4F2X4K";
const BOTH = `slack-socket:v1;channels=${ASK}:all,${INTERNAL}:asks;mentions=${ENGINEER},${BOT};wait=5`;

let security;
let securityDir;

before(async () => {
  securityDir = await tempDir();
  security = await fakeSecurity(securityDir);
});

async function poll(fake, configRef, { state, requestId } = {}) {
  const env = {
    SLACK_SOCKET_ADAPTER_API_BASE: fake.apiBase,
    SLACK_SOCKET_ADAPTER_SECURITY: security,
  };
  if (state) env.FIRSTMATE_EXTENSION_STATE = state;
  const outcome = await run(["invoke"], { stdin: pollRequest(configRef, requestId), env });
  return { ...outcome, response: outcome.stdout ? JSON.parse(outcome.stdout) : null };
}

function output(response) {
  assert.equal(response.ok, true, JSON.stringify(response));
  assert.equal(response.result.status, "result");
  return JSON.parse(response.result.output);
}

test("returns the first top-level human message and acks every envelope", async () => {
  const fake = await startFakeSlack({
    token: TOKEN,
    scenario: (connection, { sendEnvelope }) => {
      connection.send(hello());
      setTimeout(() => {
        sendEnvelope({ envelope_id: "slash-1", type: "slash_commands", payload: {} });
        sendEnvelope(messageEnvelope({ channel: ASK, user: "U01HUMAN", ts: "1.000001", text: "edit", subtype: "message_changed" }));
        sendEnvelope(messageEnvelope({ channel: ASK, user: "U01HUMAN", ts: "1.000002", thread_ts: "1.000000", text: "a reply" }));
        sendEnvelope(messageEnvelope({ channel: ASK, user: "U01BOTUSR", ts: "1.000003", bot_id: "B01", text: "bot says" }));
        sendEnvelope(messageEnvelope({ channel: "C0OTHER01", user: "U01HUMAN", ts: "1.000004", text: "other channel" }));
        sendEnvelope(messageEnvelope({ channel: ASK, user: "U01HUMAN", ts: "1.000005", text: "prod is down, help" }));
      }, 50);
    },
  });
  try {
    const { response, code, stdout, stderr } = await poll(fake, "default");
    assert.equal(code, 0, stderr);
    assert.equal(response.request_id, REQUEST_ID);
    assert.deepEqual(output(response), {
      schema: "slack-socket-adapter.message.v1",
      channel: ASK,
      ts: "1.000005",
      user: "U01HUMAN",
      text: "prod is down, help",
      text_truncated: false,
      matched: "all",
    });
    await new Promise((resolve) => setTimeout(resolve, 100));
    assert.equal(fake.state.acks.length, 6, "every envelope acked");
    for (const ack of fake.state.acks) assert.ok(ack.delayMs !== null && ack.delayMs < 3000, `ack within 3 s: ${JSON.stringify(ack)}`);
    assert.equal(fake.state.authHeaders[0], `Bearer ${TOKEN}`);
    assert.ok(!stdout.includes(TOKEN) && !stderr.includes(TOKEN), "token never printed");
  } finally {
    await fake.close();
  }
});

test("asks channel wakes only on mentions or direct-ask phrases", async () => {
  const fake = await startFakeSlack({
    token: TOKEN,
    scenario: (connection, { sendEnvelope }) => {
      connection.send(hello());
      setTimeout(() => {
        sendEnvelope(messageEnvelope({ channel: INTERNAL, user: "U01HUMAN", ts: "2.000001", text: "deploy done, lunch?" }));
        sendEnvelope(messageEnvelope({ channel: INTERNAL, user: "U01HUMAN", ts: "2.000002", text: `hey <@${BOT}> what broke` }));
      }, 50);
    },
  });
  try {
    const { response } = await poll(fake, BOTH);
    const result = output(response);
    assert.equal(result.ts, "2.000002");
    assert.equal(result.matched, "mention");
  } finally {
    await fake.close();
  }
  for (const [text, matched] of [
    ["Could somebody look at the VPN?", "ask-phrase"],
    ["does ANYONE know the jump host", "ask-phrase"],
    [`<@${ENGINEER}|engineer> quick one`, "mention"],
  ]) {
    const again = await startFakeSlack({
      token: TOKEN,
      scenario: (connection, { sendEnvelope }) => {
        connection.send(hello());
        setTimeout(() => sendEnvelope(messageEnvelope({ channel: INTERNAL, user: "U01HUMAN", ts: "3.000001", text })), 50);
      },
    });
    try {
      const { response } = await poll(again, BOTH);
      assert.equal(output(response).matched, matched, text);
    } finally {
      await again.close();
    }
  }
});

test("returns no-result when the wait window ends", async () => {
  const fake = await startFakeSlack({ token: TOKEN, scenario: (connection) => connection.send(hello()) });
  try {
    const started = Date.now();
    const { response, code } = await poll(fake, `slack-socket:v1;wait=2`);
    assert.equal(code, 0);
    assert.deepEqual(response.result, { status: "no-result", output: "" });
    assert.ok(Date.now() - started < 5000);
  } finally {
    await fake.close();
  }
});

test("reconnects on a refresh disconnect and on an abrupt close", async () => {
  const fake = await startFakeSlack({
    token: TOKEN,
    scenario: (connection, { sendEnvelope }) => {
      connection.send(hello());
      if (connection.index === 0) {
        setTimeout(() => connection.send({ type: "disconnect", reason: "refresh_requested" }), 50);
      } else if (connection.index === 1) {
        setTimeout(() => connection.destroy(), 50);
      } else {
        setTimeout(() => sendEnvelope(messageEnvelope({ channel: ASK, user: "U01HUMAN", ts: "4.000001", text: "third time" })), 50);
      }
    },
  });
  try {
    const { response } = await poll(fake, `slack-socket:v1;wait=10`);
    assert.equal(output(response).text, "third time");
    assert.equal(fake.state.opens, 3);
  } finally {
    await fake.close();
  }
});

test("auth failure is a failed response, then quiet within the hour", async () => {
  const fake = await startFakeSlack({
    token: TOKEN,
    openResponses: [{ status: 200, body: { ok: false, error: "invalid_auth" } }],
    scenario: () => {},
  });
  const state = await tempDir();
  try {
    const first = await poll(fake, `slack-socket:v1;wait=1`, { state });
    assert.equal(first.code, 0);
    assert.equal(first.response.ok, false);
    assert.equal(first.response.error.code, "unavailable");
    assert.equal(first.response.error.retryable, false);
    assert.match(first.response.error.diagnostic, /invalid_auth/);
    const second = await poll(fake, `slack-socket:v1;wait=1`, { state });
    assert.deepEqual(second.response.result, { status: "no-result", output: "" });
  } finally {
    await fake.close();
  }
});

test("link_disabled disconnect is an operator error", async () => {
  const fake = await startFakeSlack({
    token: TOKEN,
    scenario: (connection) => {
      connection.send(hello());
      setTimeout(() => connection.send({ type: "disconnect", reason: "link_disabled" }), 50);
    },
  });
  try {
    const { response } = await poll(fake, `slack-socket:v1;wait=5`);
    assert.equal(response.ok, false);
    assert.match(response.error.diagnostic, /link_disabled/);
  } finally {
    await fake.close();
  }
});

test("rate limited open is retried after Retry-After", async () => {
  const fake = await startFakeSlack({
    token: TOKEN,
    openResponses: [
      { status: 429, headers: { "Retry-After": "1" }, body: { ok: false, error: "ratelimited" } },
      { status: 200, body: { ok: true, url: "AUTO" } },
    ],
    scenario: (connection, { sendEnvelope }) => {
      connection.send(hello());
      setTimeout(() => sendEnvelope(messageEnvelope({ channel: ASK, user: "U01HUMAN", ts: "5.000001", text: "after limit" })), 50);
    },
  });
  try {
    const { response } = await poll(fake, `slack-socket:v1;wait=8`);
    assert.equal(output(response).text, "after limit");
    assert.equal(fake.state.opens, 2);
  } finally {
    await fake.close();
  }
});

test("truncates text to 2000 characters", async () => {
  const long = "é".repeat(2500);
  const fake = await startFakeSlack({
    token: TOKEN,
    scenario: (connection, { sendEnvelope }) => {
      connection.send(hello());
      setTimeout(() => sendEnvelope(messageEnvelope({ channel: ASK, user: "U01HUMAN", ts: "6.000001", text: long })), 50);
    },
  });
  try {
    const result = output((await poll(fake, "default")).response);
    assert.equal(Array.from(result.text).length, 2000);
    assert.equal(result.text_truncated, true);
  } finally {
    await fake.close();
  }
});

test("replays a retried request id and skips a redelivered event", async () => {
  const state = await tempDir();
  const event = { channel: ASK, user: "U01HUMAN", ts: "7.000001", text: "once" };
  const fake = await startFakeSlack({
    token: TOKEN,
    scenario: (connection, { sendEnvelope }) => {
      connection.send(hello());
      setTimeout(() => {
        sendEnvelope(messageEnvelope(event, { retry_attempt: connection.index }));
        if (connection.index > 0) {
          sendEnvelope(messageEnvelope({ ...event, ts: "7.000002", text: "twice" }));
        }
      }, 50);
    },
  });
  try {
    const first = output((await poll(fake, "default", { state })).response);
    assert.equal(first.text, "once");
    const replay = output((await poll(fake, "default", { state })).response);
    assert.equal(replay.text, "once");
    assert.equal(fake.state.opens, 1, "replay does not reconnect");
    const next = output((await poll(fake, "default", { state, requestId: `sha256:${"c".repeat(64)}` })).response);
    assert.equal(next.text, "twice", "redelivered 7.000001 skipped");
  } finally {
    await fake.close();
  }
});

after(() => {});

test("buffers extra matches from one session, keeps them across restarts, and never delivers twice", async () => {
  const state = await tempDir();
  const fake = await startFakeSlack({
    token: TOKEN,
    scenario: (connection, { sendEnvelope }) => {
      connection.send(hello());
      if (connection.index !== 0) return;
      setTimeout(() => {
        sendEnvelope(messageEnvelope({ channel: ASK, user: "U01HUMAN", ts: "9.000001", text: "first ask" }));
        sendEnvelope(messageEnvelope({ channel: ASK, user: "U01HUMAN", ts: "9.000002", text: "second ask" }));
        sendEnvelope(messageEnvelope({ channel: ASK, user: "U01HUMAN", ts: "9.000002", text: "second ask" }));
      }, 50);
    },
  });
  try {
    const first = output((await poll(fake, "slack-socket:v1;wait=2", { state })).response);
    assert.equal(first.text, "first ask");
    assert.equal(fake.state.opens, 1);
    const saved = JSON.parse(await readFile(path.join(state, "state.json"), "utf8"));
    assert.deepEqual(saved.pending.map((entry) => entry.key), [`${ASK}:9.000002`], "buffer persisted for the next process");
    const second = output((await poll(fake, "slack-socket:v1;wait=2", { state, requestId: `sha256:${"d".repeat(64)}` })).response);
    assert.equal(second.text, "second ask");
    assert.equal(fake.state.opens, 1, "buffered match returned without reconnecting");
    const third = (await poll(fake, "slack-socket:v1;wait=1", { state, requestId: `sha256:${"e".repeat(64)}` })).response;
    assert.deepEqual(third.result, { status: "no-result", output: "" }, "duplicate not delivered twice");
  } finally {
    await fake.close();
  }
});
