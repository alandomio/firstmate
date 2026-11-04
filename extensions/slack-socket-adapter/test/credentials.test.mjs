import assert from "node:assert/strict";
import { chmod, mkdir, readFile, symlink, writeFile } from "node:fs/promises";
import { createServer } from "node:net";
import path from "node:path";
import { test } from "node:test";
import { ConfigError, parseConfigRef } from "../package/lib/config.mjs";
import { TOKEN, pollRequest, run, tempDir } from "./helpers.mjs";

const UNREACHABLE_API = "http://127.0.0.1:9/api";

// A stand-in for a credential CLI. It records its argv and the D-Bus address
// it saw, then prints the value or fails.
async function fakeTool(directory, name, { value = TOKEN, exitCode = 0, requireBus = "" } = {}) {
  const file = path.join(directory, name);
  const log = path.join(directory, `${name}.args`);
  const busCheck = requireBus
    ? `[ "$DBUS_SESSION_BUS_ADDRESS" = '${requireBus}' ] || exit 1\n`
    : "";
  const body = `#!/bin/sh\nprintf '%s\\n' "$*" > '${log}'\n${busCheck}${exitCode === 0 ? `printf '%s\\n' '${value}'\n` : `exit ${exitCode}\n`}`;
  await writeFile(file, body);
  await chmod(file, 0o755);
  return { file, log };
}

async function tokenFile(directory, { mode = 0o600, value = TOKEN } = {}) {
  const file = path.join(directory, "slack-app-token");
  await writeFile(file, `${value}\n`, { mode });
  await chmod(file, mode);
  return file;
}

// listen --connect-only reads the token first. With a valid token it goes on
// to the unreachable API and ends with no-result (exit 0) after the wait;
// with a credential problem it exits 2 before any network call.
function listen(configRef, env) {
  return run(["listen", "--config-ref", configRef, "--wait", "1"], {
    env: { SLACK_SOCKET_ADAPTER_API_BASE: UNREACHABLE_API, ...env },
  });
}

function assertNoToken(outcome) {
  assert.ok(!outcome.stdout.includes("xapp-1-A0TEST"), "token leaked to stdout");
  assert.ok(!outcome.stderr.includes("xapp-1-A0TEST"), "token leaked to stderr");
}

test("cred defaults to keychain on macOS and secret-tool elsewhere", () => {
  assert.equal(parseConfigRef("default", "darwin").credentialBackend, "keychain");
  assert.equal(parseConfigRef("default", "linux").credentialBackend, "secret-tool");
  assert.equal(parseConfigRef("slack-socket:v1;cred=keychain", "linux").credentialBackend, "keychain");
  const file = parseConfigRef("slack-socket:v1;cred=file;credfile=/home/me/.config/slack/app-token", "darwin");
  assert.equal(file.credentialBackend, "file");
  assert.equal(file.credentialFile, "/home/me/.config/slack/app-token");
  for (const bad of [
    "slack-socket:v1;cred=vault",
    "slack-socket:v1;cred=file",
    "slack-socket:v1;cred=file;credfile=relative/token",
    "slack-socket:v1;cred=file;credfile=/home/me/../other/token",
    "slack-socket:v1;cred=file;credfile=/x;keychain=item",
    "slack-socket:v1;cred=secret-tool;credfile=/x",
    "slack-socket:v1;credfile=/x",
    "slack-socket:v1;cred=file;cred=file;credfile=/x",
  ]) {
    assert.throws(() => parseConfigRef(bad, "linux"), ConfigError, bad);
  }
});

test("keychain backend calls security find-generic-password with the service", async () => {
  const directory = await tempDir();
  const security = await fakeTool(directory, "security");
  const outcome = await listen("slack-socket:v1;cred=keychain;keychain=my-item", { SLACK_SOCKET_ADAPTER_SECURITY: security.file });
  assert.equal(outcome.code, 0, outcome.stderr);
  assert.equal(JSON.parse(outcome.stdout).status, "no-result");
  assert.equal((await readFile(security.log, "utf8")).trim(), "find-generic-password -s my-item -w");
  assertNoToken(outcome);
});

test("secret-tool backend looks up attribute service with the same name", async () => {
  const directory = await tempDir();
  const tool = await fakeTool(directory, "secret-tool");
  const outcome = await listen("slack-socket:v1;cred=secret-tool", { SLACK_SOCKET_ADAPTER_SECRET_TOOL: tool.file });
  assert.equal(outcome.code, 0, outcome.stderr);
  assert.equal((await readFile(tool.log, "utf8")).trim(), "lookup service fm-slack-ask-devops-socket");
  assertNoToken(outcome);
});

test("secret-tool failures name the item and never the value", async () => {
  const directory = await tempDir();
  const missing = await fakeTool(directory, "missing", { exitCode: 1 });
  const absent = await listen("slack-socket:v1;cred=secret-tool", { SLACK_SOCKET_ADAPTER_SECRET_TOOL: missing.file });
  assert.equal(absent.code, 2);
  assert.match(absent.stderr, /secret-tool item "service fm-slack-ask-devops-socket" is missing/);

  const notInstalled = await listen("slack-socket:v1;cred=secret-tool", { SLACK_SOCKET_ADAPTER_SECRET_TOOL: path.join(directory, "no-such-tool") });
  assert.equal(notInstalled.code, 2);
  assert.match(notInstalled.stderr, /secret-tool is not installed/);

  const wrong = await fakeTool(directory, "wrong", { value: "xoxb-not-an-app-token-123456" });
  const wrongType = await run(["invoke"], {
    stdin: pollRequest("slack-socket:v1;cred=secret-tool"),
    env: { SLACK_SOCKET_ADAPTER_SECRET_TOOL: wrong.file, SLACK_SOCKET_ADAPTER_API_BASE: UNREACHABLE_API },
  });
  const response = JSON.parse(wrongType.stdout);
  assert.equal(response.ok, false);
  assert.equal(response.error.code, "unavailable");
  assert.ok(!wrongType.stdout.includes("xoxb-not") && !wrongType.stderr.includes("xoxb-not"));
});

test("secret-tool reaches the per-user D-Bus socket when no bus address is set", async () => {
  const runtime = await tempDir();
  const socketPath = path.join(runtime, "bus");
  const server = createServer();
  await new Promise((resolve) => server.listen(socketPath, resolve));
  try {
    const directory = await tempDir();
    const tool = await fakeTool(directory, "secret-tool", { requireBus: `unix:path=${socketPath}` });
    const env = { SLACK_SOCKET_ADAPTER_SECRET_TOOL: tool.file, XDG_RUNTIME_DIR: runtime };
    const derived = await listen("slack-socket:v1;cred=secret-tool", env);
    assert.equal(derived.code, 0, derived.stderr);

    const explicit = await listen("slack-socket:v1;cred=secret-tool", { ...env, DBUS_SESSION_BUS_ADDRESS: "unix:path=/elsewhere" });
    assert.equal(explicit.code, 2, "an explicit bus address must win over the derived one");
  } finally {
    server.close();
  }
});

test("file backend reads a 0600 file owned by the current user", async () => {
  const directory = await tempDir();
  const file = await tokenFile(directory);
  const outcome = await listen(`slack-socket:v1;cred=file;credfile=${file}`, {});
  assert.equal(outcome.code, 0, outcome.stderr);
  assert.equal(JSON.parse(outcome.stdout).status, "no-result");
  assertNoToken(outcome);
});

test("file backend refuses loose modes, symlinks, non-files, and bad content", async () => {
  const directory = await tempDir();
  const loose = path.join(await tempDir(), "slack-app-token");
  await writeFile(loose, `${TOKEN}\n`);
  await chmod(loose, 0o640);
  const looseOutcome = await listen(`slack-socket:v1;cred=file;credfile=${loose}`, {});
  assert.equal(looseOutcome.code, 2);
  assert.match(looseOutcome.stderr, /must have mode 0600 \(it has 0640\)/);
  assertNoToken(looseOutcome);

  const target = await tokenFile(directory);
  const link = path.join(directory, "link-to-token");
  await symlink(target, link);
  const linkOutcome = await listen(`slack-socket:v1;cred=file;credfile=${link}`, {});
  assert.equal(linkOutcome.code, 2);
  assert.match(linkOutcome.stderr, /is a symlink/);

  const folder = path.join(directory, "folder");
  await mkdir(folder, { mode: 0o700 });
  const folderOutcome = await listen(`slack-socket:v1;cred=file;credfile=${folder}`, {});
  assert.equal(folderOutcome.code, 2);
  assert.match(folderOutcome.stderr, /not a regular file/);

  const missingOutcome = await listen(`slack-socket:v1;cred=file;credfile=${path.join(directory, "absent")}`, {});
  assert.equal(missingOutcome.code, 2);
  assert.match(missingOutcome.stderr, /missing or unreadable/);

  const wrong = await tokenFile(await tempDir(), { value: "xoxb-not-an-app-token-123456" });
  const wrongOutcome = await listen(`slack-socket:v1;cred=file;credfile=${wrong}`, {});
  assert.equal(wrongOutcome.code, 2);
  assert.match(wrongOutcome.stderr, /does not hold an xapp- app-level token/);
  assert.ok(!wrongOutcome.stderr.includes("xoxb-not"));
});
