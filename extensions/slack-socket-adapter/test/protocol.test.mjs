import assert from "node:assert/strict";
import { test } from "node:test";
import { ConfigError, parseConfigRef } from "../package/lib/config.mjs";
import { matchEvent } from "../package/lib/filter.mjs";
import { REQUEST_ID, TOKEN, fakeSecurity, pollRequest, resultRequest, run, tempDir } from "./helpers.mjs";

test("handshake echoes identity and only its own adapter name", async () => {
  const request = {
    schema: "firstmate.extension-handshake-request.v1",
    request_id: REQUEST_ID,
    host_protocols: [1],
    extension_id: "de.peter-park.devops.slack-socket-adapter",
    extension_version: "1.1.0",
    package_digest: `sha256:${"b".repeat(64)}`,
    capability: { name: "process-event-adapter", versions: [1], adapter_names: ["slack-socket", "other"] },
  };
  const { code, stdout } = await run(["handshake"], { stdin: JSON.stringify(request) });
  assert.equal(code, 0);
  assert.deepEqual(JSON.parse(stdout), {
    schema: "firstmate.extension-handshake-response.v1",
    request_id: REQUEST_ID,
    extension_id: "de.peter-park.devops.slack-socket-adapter",
    extension_version: "1.1.0",
    host_protocol: 1,
    capability: "process-event-adapter",
    capability_version: 1,
    adapter_names: ["slack-socket"],
  });
});

test("classify, terminal, and silent verdicts", async () => {
  const message = JSON.stringify({ schema: "slack-socket-adapter.message.v1", channel: "C08D5AM39F0", ts: "1.1", user: "U1", text: "x" });
  const hostError = JSON.stringify({ code: "extension-unavailable", extension_id: "x", operation: "source.poll", schema: "firstmate.process-event-extension-error.v1" });
  const cases = [
    ["result.classify", message, { classification: "message" }],
    ["result.classify", hostError, { classification: "error" }],
    ["result.classify", "not json", { classification: "error" }],
    ["result.terminal", message, { value: false }],
    ["result.terminal", hostError, { value: false }],
    ["result.silent", message, { value: false }],
  ];
  for (const [operation, content, expected] of cases) {
    const { code, stdout } = await run(["invoke"], { stdin: resultRequest(operation, content) });
    assert.equal(code, 0);
    const response = JSON.parse(stdout);
    assert.deepEqual(response, { schema: "firstmate.extension-response.v1", request_id: REQUEST_ID, ok: true, result: expected, error: null }, operation);
  }
});

test("unknown operation and bad config_ref are invalid-request", async () => {
  const unknown = JSON.parse((await run(["invoke"], { stdin: resultRequest("result.mutate", "") })).stdout);
  assert.equal(unknown.ok, false);
  assert.equal(unknown.error.code, "invalid-request");
  const bad = JSON.parse((await run(["invoke"], { stdin: pollRequest("slack-socket:v1;channels=nope") })).stdout);
  assert.equal(bad.ok, false);
  assert.equal(bad.error.code, "invalid-request");
});

test("missing keychain item or a non-xapp value fails without printing the value", async () => {
  const directory = await tempDir();
  const missing = await fakeSecurity(directory, { exitCode: 44 });
  const env = { SLACK_SOCKET_ADAPTER_SECURITY: missing, SLACK_SOCKET_ADAPTER_API_BASE: "http://127.0.0.1:9/api" };
  const listen = await run(["listen", "--wait", "1"], { env });
  assert.equal(listen.code, 2);
  assert.match(listen.stderr, /fm-slack-ask-devops-socket.*missing/);
  assert.equal(JSON.parse(listen.stdout).status, "error");

  const otherDir = await tempDir();
  const wrong = await fakeSecurity(otherDir, { value: "xoxb-not-an-app-token-123456" });
  const invoke = await run(["invoke"], { stdin: pollRequest("default"), env: { ...env, SLACK_SOCKET_ADAPTER_SECURITY: wrong } });
  const response = JSON.parse(invoke.stdout);
  assert.equal(response.ok, false);
  assert.equal(response.error.code, "unavailable");
  assert.match(response.error.diagnostic, /xapp-/);
  assert.ok(!invoke.stdout.includes("xoxb-not") && !invoke.stderr.includes("xoxb-not"));
});

test("listen refuses a non-local plain http API base", async () => {
  const directory = await tempDir();
  const security = await fakeSecurity(directory);
  const outcome = await run(["listen", "--wait", "1"], {
    env: { SLACK_SOCKET_ADAPTER_SECURITY: security, SLACK_SOCKET_ADAPTER_API_BASE: "http://example.com/api" },
  });
  assert.equal(outcome.code, 2);
  assert.ok(!outcome.stderr.includes(TOKEN));
});

test("config_ref parsing", () => {
  assert.deepEqual(parseConfigRef("default", "darwin"), {
    channels: [{ id: "C08D5AM39F0", mode: "all" }],
    mentions: [],
    waitSeconds: 240,
    keychainService: "fm-slack-ask-devops-socket",
    credentialBackend: "keychain",
    credentialFile: null,
  });
  assert.deepEqual(parseConfigRef("slack-socket:v1;channels=C08D5AM39F0:all,C088ESUUM2N:asks;mentions=U0EXAMPLE01,U0CEL4F2X4K;wait=100;keychain=other-item", "darwin"), {
    channels: [{ id: "C08D5AM39F0", mode: "all" }, { id: "C088ESUUM2N", mode: "asks" }],
    mentions: ["U0EXAMPLE01", "U0CEL4F2X4K"],
    waitSeconds: 100,
    keychainService: "other-item",
    credentialBackend: "keychain",
    credentialFile: null,
  });
  assert.deepEqual(parseConfigRef("slack-socket:v1;channels=C088ESUUM2N").channels, [{ id: "C088ESUUM2N", mode: "all" }]);
  for (const bad of [
    "",
    "file:/x",
    "slack-socket:v1;channels=C1:sometimes",
    "slack-socket:v1;channels=C08D5AM39F0,C08D5AM39F0",
    "slack-socket:v1;wait=0",
    "slack-socket:v1;wait=9999",
    "slack-socket:v1;wait=1;wait=2",
    "slack-socket:v1;token=xapp-1",
    "slack-socket:v1;keychain=a b",
    "slack-socket:v1;mentions=engineer",
  ]) {
    assert.throws(() => parseConfigRef(bad), ConfigError, bad);
  }
});

test("event filter edge cases", () => {
  const config = parseConfigRef("slack-socket:v1;channels=C08D5AM39F0:all,C088ESUUM2N:asks;mentions=U0CEL4F2X4K");
  const base = { type: "message", channel: "C08D5AM39F0", user: "U01HUMAN", ts: "1.1", text: "hi" };
  assert.equal(matchEvent(base, config), "all");
  assert.equal(matchEvent({ ...base, thread_ts: "1.1" }, config), "all", "thread parent marker equal to ts is top-level");
  assert.equal(matchEvent({ ...base, subtype: "thread_broadcast" }, config), null);
  assert.equal(matchEvent({ ...base, bot_profile: {} }, config), null);
  assert.equal(matchEvent({ ...base, user: undefined }, config), null);
  assert.equal(matchEvent({ ...base, type: "app_mention" }, config), null);
  const internal = { ...base, channel: "C088ESUUM2N" };
  assert.equal(matchEvent({ ...internal, text: "anyone around?" }, config), "ask-phrase");
  assert.equal(matchEvent({ ...internal, text: "can someone review" }, config), "ask-phrase");
  assert.equal(matchEvent({ ...internal, text: "canyone" }, config), null);
  assert.equal(matchEvent({ ...internal, text: "someone deployed it" }, config), null);
  assert.equal(matchEvent({ ...internal, text: "<@U0EXAMPLE01> fyi" }, config), null, "not in this mentions list");
});
