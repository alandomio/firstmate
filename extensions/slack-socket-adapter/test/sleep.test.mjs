import assert from "node:assert/strict";
import { test } from "node:test";
import { hello, messageEnvelope, startFakeSlack } from "./fake-slack.mjs";
import { TOKEN, fakeSecurity, pollRequest, resultRequest, run, tempDir } from "./helpers.mjs";

const ASK = "C08D5AM39F0";
// Exactly what the host captures when it stops a poll at its timeout.
const HOST_TIMEOUT = JSON.stringify({
  code: "timeout",
  extension_id: "de.peter-park.devops.slack-socket-adapter",
  operation: "source.poll",
  schema: "firstmate.process-event-extension-error.v1",
});

const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function until(condition, what, ms = 5000) {
  const end = Date.now() + ms;
  while (!condition()) {
    if (Date.now() > end) throw new Error(`timed out waiting for ${what}`);
    await pause(20);
  }
}

async function environment(fake, state) {
  return {
    SLACK_SOCKET_ADAPTER_API_BASE: fake.apiBase,
    SLACK_SOCKET_ADAPTER_SECURITY: await fakeSecurity(await tempDir()),
    FIRSTMATE_EXTENSION_STATE: state,
  };
}

async function silent(state, content = HOST_TIMEOUT) {
  const outcome = await run(["invoke"], {
    stdin: resultRequest("result.silent", content),
    env: { FIRSTMATE_EXTENSION_STATE: state },
  });
  assert.equal(outcome.code, 0, outcome.stderr);
  return JSON.parse(outcome.stdout).result.value;
}

// SIGSTOP freezes the adapter while the wall clock runs on, as a laptop sleep does.
async function freeze(child, ms) {
  child.kill("SIGSTOP");
  await pause(ms);
  child.kill("SIGCONT");
}

test("after a sleep the poll drops the stale connection and listens on a new one", async () => {
  const fake = await startFakeSlack({
    token: TOKEN,
    scenario: (connection, { sendEnvelope }) => {
      connection.send(hello());
      if (connection.index === 1) {
        setTimeout(() => sendEnvelope(messageEnvelope({ channel: ASK, user: "U01HUMAN", ts: "7.000001", text: "after the sleep" })), 50);
      }
    },
  });
  try {
    let child;
    const pending = run(["invoke"], {
      stdin: pollRequest("slack-socket:v1;wait=30"),
      env: await environment(fake, await tempDir()),
      onSpawn: (spawned) => { child = spawned; },
    });
    await until(() => fake.state.connections.length === 1, "the first connection");
    await pause(200);
    await freeze(child, 6000);
    const outcome = await pending;
    assert.equal(outcome.code, 0, outcome.stderr);
    const response = JSON.parse(outcome.stdout);
    assert.equal(response.result.status, "result", outcome.stderr);
    assert.equal(JSON.parse(response.result.output).text, "after the sleep");
    assert.equal(fake.state.opens, 2, "reconnected once after the sleep");
    assert.match(outcome.stderr, /the system was suspended for \d+ s; reconnecting/);
  } finally {
    await fake.close();
  }
});

test("a host timeout that lands on wake from sleep is silent once; any other timeout wakes", async () => {
  const fake = await startFakeSlack({ token: TOKEN, scenario: (connection) => connection.send(hello()) });
  try {
    const state = await tempDir();
    const env = await environment(fake, state);

    // The host stops a poll that was frozen by a sleep: SIGTERM right on wake.
    let child;
    const slept = run(["invoke"], { stdin: pollRequest("slack-socket:v1;wait=60"), env, onSpawn: (spawned) => { child = spawned; } });
    await until(() => fake.state.connections.length === 1, "the first connection");
    child.kill("SIGSTOP");
    await pause(6000);
    child.kill("SIGTERM");
    child.kill("SIGCONT");
    assert.equal((await slept).code, 143);
    assert.equal(await silent(state), true, "the sleep stop needs no wake");
    assert.equal(await silent(state), false, "the mark is used once");

    // The host stops a poll that was awake the whole time: that is a real fault.
    let awake;
    const hung = run(["invoke"], { stdin: pollRequest("slack-socket:v1;wait=60"), env, onSpawn: (spawned) => { awake = spawned; } });
    await until(() => fake.state.connections.length === 2, "the second connection");
    awake.kill("SIGTERM");
    assert.equal((await hung).code, 143);
    assert.equal(await silent(state), false, "a timeout without a sleep still wakes");

    assert.equal(await silent(state, JSON.stringify({ schema: "slack-socket-adapter.message.v1", text: "x" })), false);
  } finally {
    await fake.close();
  }
});
