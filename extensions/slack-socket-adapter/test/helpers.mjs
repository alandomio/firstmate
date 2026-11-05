import { spawn } from "node:child_process";
import { mkdtemp, writeFile, chmod } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const ENTRYPOINT = path.join(path.dirname(path.dirname(fileURLToPath(import.meta.url))), "package", "bin", "slack-socket-adapter.mjs");
export const TOKEN = "xapp-1-A0TEST-1234567890-abcdefabcdef";
export const REQUEST_ID = `sha256:${"a".repeat(64)}`;

export async function tempDir() {
  return mkdtemp(path.join(tmpdir(), "slack-socket-adapter-test-"));
}

// A stand-in for /usr/bin/security that prints a fixed value or fails.
export async function fakeSecurity(directory, { value = TOKEN, exitCode = 0 } = {}) {
  const file = path.join(directory, "security");
  const body = exitCode === 0
    ? `#!/bin/sh\nprintf '%s\\n' '${value}'\n`
    : `#!/bin/sh\necho 'security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain.' >&2\nexit ${exitCode}\n`;
  await writeFile(file, body);
  await chmod(file, 0o755);
  return file;
}

// The default credential backend depends on the platform (keychain on macOS,
// secret-tool elsewhere). A fake credential tool prints its value whatever its
// arguments, so a test that sets only the security stand-in gets the same
// stand-in for secret-tool and behaves the same on every platform.
export function run(args, { stdin = "", env = {}, onSpawn = null } = {}) {
  const tools = env.SLACK_SOCKET_ADAPTER_SECURITY && !env.SLACK_SOCKET_ADAPTER_SECRET_TOOL
    ? { SLACK_SOCKET_ADAPTER_SECRET_TOOL: env.SLACK_SOCKET_ADAPTER_SECURITY }
    : {};
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [ENTRYPOINT, ...args], {
      env: { PATH: process.env.PATH, HOME: process.env.HOME, ...tools, ...env },
      stdio: ["pipe", "pipe", "pipe"],
    });
    if (onSpawn) onSpawn(child);
    const stdout = [];
    const stderr = [];
    child.stdout.on("data", (chunk) => stdout.push(chunk));
    child.stderr.on("data", (chunk) => stderr.push(chunk));
    child.on("close", (code) => resolve({
      code,
      stdout: Buffer.concat(stdout).toString("utf8"),
      stderr: Buffer.concat(stderr).toString("utf8"),
    }));
    child.stdin.end(stdin);
  });
}

export function pollRequest(configRef, requestId = REQUEST_ID) {
  return JSON.stringify({
    schema: "firstmate.extension-request.v1",
    request_id: requestId,
    host_protocol: 1,
    extension_id: "de.peter-park.devops.slack-socket-adapter",
    extension_version: "1.1.0",
    package_digest: `sha256:${"b".repeat(64)}`,
    capability: "process-event-adapter",
    capability_version: 1,
    adapter: "slack-socket",
    operation: "source.poll",
    input: { source_id: "ask-devops", config_ref: configRef },
  });
}

export function resultRequest(operation, content) {
  return JSON.stringify({
    schema: "firstmate.extension-request.v1",
    request_id: REQUEST_ID,
    host_protocol: 1,
    extension_id: "de.peter-park.devops.slack-socket-adapter",
    extension_version: "1.1.0",
    package_digest: `sha256:${"b".repeat(64)}`,
    capability: "process-event-adapter",
    capability_version: 1,
    adapter: "slack-socket",
    operation,
    input: { source_id: "ask-devops", sequence: 1, content },
  });
}
