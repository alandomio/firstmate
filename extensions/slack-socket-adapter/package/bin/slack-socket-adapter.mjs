#!/usr/bin/env node
// Firstmate process-event-adapter/1 package: Slack Socket Mode listener.
//
// Verbs (argv[2]):
//   handshake   firstmate host handshake (JSON on stdin and stdout)
//   invoke      firstmate host invocation (JSON on stdin and stdout)
//   listen      direct one-shot listen for operators and smoke tests:
//               listen [--config-ref <ref>] [--wait <seconds>] [--connect-only]
//               Prints one JSON document on stdout. Exit 0 on a message,
//               a no-result, or (with --connect-only) a confirmed connection;
//               exit 2 when the token or Slack app needs operator action;
//               exit 64 on bad arguments.
//
// Logs go to stderr. The app-level token is read from the credential backend
// the config_ref selects (macOS keychain, libsecret secret-tool, or a 0600
// file) and is never written to stdout, stderr, or state.

import { ConfigError, MAX_WAIT_SECONDS, parseConfigRef } from "../lib/config.mjs";
import { RESULT_SCHEMA, resultFor } from "../lib/filter.mjs";
import { readToken } from "../lib/credentials.mjs";
import { AuthError, apiBase, listen } from "../lib/slack.mjs";
import { MAX_PENDING, loadState, saveState } from "../lib/state.mjs";

const EXTENSION_ID = "de.peter-park.devops.slack-socket-adapter";
const EXTENSION_VERSION = "1.1.0";
const ADAPTER = "slack-socket";
const MAX_INPUT_BYTES = 65536;
const AUTH_REPORT_COOLDOWN_MS = 60 * 60 * 1000;

function log(message) {
  process.stderr.write(`slack-socket-adapter: ${message}\n`);
}

function finish(document, code = 0) {
  process.stdout.write(`${JSON.stringify(document)}\n`, () => process.exit(code));
}

async function readRequest() {
  const chunks = [];
  let size = 0;
  for await (const chunk of process.stdin) {
    size += chunk.length;
    if (size > MAX_INPUT_BYTES) throw new Error("request is oversized");
    chunks.push(chunk);
  }
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

function ok(requestId, result) {
  finish({ schema: "firstmate.extension-response.v1", request_id: requestId, ok: true, result, error: null });
}

function failed(requestId, code, retryable, diagnostic) {
  finish({
    schema: "firstmate.extension-response.v1",
    request_id: requestId,
    ok: false,
    result: null,
    error: { code, retryable, diagnostic: diagnostic.slice(0, 500) },
  });
}

function handshake(request) {
  const requested = request && request.capability && Array.isArray(request.capability.adapter_names)
    ? request.capability.adapter_names
    : [];
  finish({
    schema: "firstmate.extension-handshake-response.v1",
    request_id: request.request_id,
    extension_id: EXTENSION_ID,
    extension_version: EXTENSION_VERSION,
    host_protocol: 1,
    capability: "process-event-adapter",
    capability_version: 1,
    adapter_names: requested.filter((name) => name === ADAPTER),
  });
}

function classify(content) {
  try {
    const parsed = JSON.parse(content);
    if (parsed && parsed.schema === RESULT_SCHEMA) return "message";
  } catch {
    // not one of ours
  }
  return "error";
}

async function poll(request) {
  const requestId = request.request_id;
  let config;
  try {
    config = parseConfigRef(request.input && request.input.config_ref);
  } catch (error) {
    if (error instanceof ConfigError) return failed(requestId, "invalid-request", false, error.message);
    throw error;
  }
  const stateDir = process.env.FIRSTMATE_EXTENSION_STATE || "";
  const state = await loadState(stateDir);
  if (state.last && state.last.request_id === requestId) {
    log("replaying the stored result for a retried request id");
    return ok(requestId, { status: "result", output: state.last.output });
  }
  const seen = new Set(state.recent);
  state.pending = state.pending.filter((entry) => !seen.has(entry.key));
  const buffered = state.pending.shift();
  if (buffered) {
    log("returning a buffered message");
    return deliver(stateDir, state, requestId, buffered);
  }
  const deadline = Date.now() + config.waitSeconds * 1000;
  let found;
  try {
    const base = apiBase();
    const token = await readToken(config);
    found = await listen({
      config,
      token,
      base,
      deadline,
      log,
      isSeen: (key) => seen.has(key) || state.pending.some((entry) => entry.key === key),
      onConnected: () => {
        if (state.auth_failure_reported_at) {
          state.auth_failure_reported_at = 0;
          saveState(stateDir, state).catch(() => {});
        }
      },
    });
  } catch (error) {
    if (!(error instanceof AuthError)) throw error;
    log(error.message);
    if (Date.now() - state.auth_failure_reported_at < AUTH_REPORT_COOLDOWN_MS) {
      // Already reported within the hour: stay quiet for this wait window.
      await new Promise((resolve) => setTimeout(resolve, Math.max(0, deadline - Date.now())));
      return ok(requestId, { status: "no-result", output: "" });
    }
    state.auth_failure_reported_at = Date.now();
    await saveState(stateDir, state);
    return failed(requestId, "unavailable", false, error.message);
  }
  if (!found) return ok(requestId, { status: "no-result", output: "" });
  const [first, ...rest] = found.map(({ event, reason }) => ({
    key: `${event.channel}:${event.ts}`,
    output: JSON.stringify(resultFor(event, reason)),
  }));
  state.pending.push(...rest);
  if (state.pending.length > MAX_PENDING) {
    log(`buffer full: dropping ${state.pending.length - MAX_PENDING} oldest buffered messages`);
    state.pending = state.pending.slice(-MAX_PENDING);
  }
  return deliver(stateDir, state, requestId, first);
}

async function deliver(stateDir, state, requestId, entry) {
  state.recent.push(entry.key);
  state.last = { request_id: requestId, output: entry.output };
  await saveState(stateDir, state);
  return ok(requestId, { status: "result", output: entry.output });
}

async function invoke(request) {
  const requestId = request && typeof request.request_id === "string" ? request.request_id : "";
  if (!request || request.schema !== "firstmate.extension-request.v1" || request.adapter !== ADAPTER) {
    return failed(requestId, "invalid-request", false, "unsupported request");
  }
  const content = request.input && typeof request.input.content === "string" ? request.input.content : "";
  switch (request.operation) {
    case "source.poll":
      return poll(request);
    case "result.classify":
      return ok(requestId, { classification: classify(content) });
    case "result.terminal":
      // Never terminal: the registration stays and the watcher re-arms it.
      return ok(requestId, { value: false });
    case "result.silent":
      return ok(requestId, { value: false });
    default:
      return failed(requestId, "invalid-request", false, `unsupported operation ${String(request.operation).slice(0, 64)}`);
  }
}

function parseListenArgs(args) {
  const options = { configRef: "default", wait: null, connectOnly: false };
  for (let index = 0; index < args.length; index += 1) {
    const name = args[index];
    if (name === "--config-ref" && index + 1 < args.length) {
      options.configRef = args[++index];
    } else if (name === "--wait" && index + 1 < args.length) {
      options.wait = args[++index];
    } else if (name === "--connect-only") {
      options.connectOnly = true;
    } else {
      throw new ConfigError(`unknown listen argument ${name}`);
    }
  }
  return options;
}

async function listenCli(args) {
  let config;
  let options;
  try {
    options = parseListenArgs(args);
    config = parseConfigRef(options.configRef);
    if (options.wait !== null) {
      if (!/^[0-9]{1,4}$/.test(options.wait) || Number(options.wait) < 1 || Number(options.wait) > MAX_WAIT_SECONDS) {
        throw new ConfigError(`--wait must be 1..${MAX_WAIT_SECONDS} seconds`);
      }
      config.waitSeconds = Number(options.wait);
    }
  } catch (error) {
    if (!(error instanceof ConfigError)) throw error;
    log(`error: ${error.message}`);
    return finish({ status: "error", error: error.message }, 64);
  }
  const deadline = Date.now() + config.waitSeconds * 1000;
  let connected = false;
  try {
    const base = apiBase();
    const token = await readToken(config);
    const found = await listen({
      config,
      token,
      base,
      deadline,
      log,
      onConnected: () => {
        connected = true;
        if (options.connectOnly) finish({ status: "connected" });
      },
    });
    if (found) return finish({ status: "result", result: resultFor(found[0].event, found[0].reason) });
    return finish({ status: "no-result", connected });
  } catch (error) {
    if (!(error instanceof AuthError)) throw error;
    log(`error: ${error.message}`);
    return finish({ status: "error", error: error.message, connected }, 2);
  }
}

const verb = process.argv[2] || "";
try {
  if (verb === "handshake") {
    handshake(await readRequest());
  } else if (verb === "invoke") {
    await invoke(await readRequest());
  } else if (verb === "listen") {
    await listenCli(process.argv.slice(3));
  } else {
    log("usage: slack-socket-adapter.mjs handshake|invoke|listen [--config-ref <ref>] [--wait <seconds>] [--connect-only]");
    process.exit(64);
  }
} catch (error) {
  log(`internal error: ${error && error.message ? error.message : String(error)}`);
  process.exit(1);
}
