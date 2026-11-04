// Slack Socket Mode client: open a connection with the app-level token and
// wait for the first matching message event. Uses only Node built-ins
// (fetch and the global WebSocket of Node 22+). credentials.mjs reads the token.

import { AuthError } from "./errors.mjs";
import { matchEvent } from "./filter.mjs";

export { AuthError };

const DEFAULT_API_BASE = "https://slack.com/api";
const HTTP_TIMEOUT_MS = 10000;
const HELLO_TIMEOUT_MS = 10000;
const MAX_BACKOFF_MS = 30000;
// apps.connections.open errors that no retry can fix: the operator must act.
const AUTH_ERRORS = new Set([
  "invalid_auth",
  "not_authed",
  "account_inactive",
  "token_revoked",
  "token_expired",
  "not_allowed_token_type",
  "missing_scope",
  "no_permission",
  "team_access_not_granted",
  "ekm_access_denied",
]);

class TransientError extends Error {
  constructor(message, retryAfterMs = 0) {
    super(message);
    this.retryAfterMs = retryAfterMs;
  }
}

export function apiBase(env = process.env) {
  const base = env.SLACK_SOCKET_ADAPTER_API_BASE || DEFAULT_API_BASE;
  let url;
  try {
    url = new URL(base);
  } catch {
    throw new AuthError("SLACK_SOCKET_ADAPTER_API_BASE is not a URL");
  }
  const local = url.protocol === "http:" && (url.hostname === "127.0.0.1" || url.hostname === "localhost");
  if (url.protocol !== "https:" && !local) {
    throw new AuthError("Slack API base must be https (plain http only for 127.0.0.1 or localhost)");
  }
  return base.replace(/\/+$/, "");
}

export async function openConnection(base, token) {
  let response;
  try {
    response = await fetch(`${base}/apps.connections.open`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: "",
      signal: AbortSignal.timeout(HTTP_TIMEOUT_MS),
    });
  } catch {
    throw new TransientError("apps.connections.open request failed");
  }
  if (response.status === 429) {
    const seconds = Number(response.headers.get("retry-after"));
    throw new TransientError("apps.connections.open rate limited", Number.isFinite(seconds) && seconds > 0 ? seconds * 1000 : 60000);
  }
  let body;
  try {
    body = await response.json();
  } catch {
    throw new TransientError(`apps.connections.open returned HTTP ${response.status} without JSON`);
  }
  if (!body || body.ok !== true) {
    const code = body && typeof body.error === "string" ? body.error : `http_${response.status}`;
    if (AUTH_ERRORS.has(code)) throw new AuthError(`Slack rejected the app-level token: ${code}`);
    if (code === "ratelimited") throw new TransientError("apps.connections.open rate limited", 60000);
    throw new TransientError(`apps.connections.open failed: ${code}`);
  }
  if (typeof body.url !== "string" || !/^wss?:\/\//.test(body.url)) {
    throw new TransientError("apps.connections.open returned no WebSocket URL");
  }
  if (body.url.startsWith("ws://") && !base.startsWith("http://")) {
    throw new TransientError("apps.connections.open returned an unencrypted WebSocket URL");
  }
  return body.url;
}

function sleepUntil(deadline, ms) {
  const delay = Math.max(0, Math.min(ms, deadline - Date.now()));
  return new Promise((resolve) => setTimeout(resolve, delay));
}

function decode(data) {
  if (typeof data === "string") return data;
  if (data instanceof ArrayBuffer) return Buffer.from(data).toString("utf8");
  return null;
}

// One WebSocket session. Resolves with an outcome object, never rejects.
function runSocket(url, { config, deadline, log, isSeen, onConnected }) {
  return new Promise((resolve) => {
    let finished = false;
    let socket;
    const finish = (outcome) => {
      if (finished) return;
      finished = true;
      clearInterval(clock);
      clearTimeout(helloTimer);
      try {
        socket.close();
      } catch {
        // already closed
      }
      resolve(outcome);
    };
    // Poll the wall clock so a laptop sleep cannot stretch the wait.
    const clock = setInterval(() => {
      if (Date.now() >= deadline) finish({ kind: "deadline" });
    }, 250);
    const helloTimer = setTimeout(() => finish({ kind: "retry", reason: "no hello within 10 s" }), HELLO_TIMEOUT_MS);
    try {
      socket = new WebSocket(url);
    } catch {
      finish({ kind: "retry", reason: "WebSocket could not be created" });
      return;
    }
    socket.onmessage = (message) => {
      const text = decode(message.data);
      if (text === null) return;
      let envelope;
      try {
        envelope = JSON.parse(text);
      } catch {
        return;
      }
      if (!envelope || typeof envelope !== "object") return;
      // Ack first: Slack retries anything not acked within 3 s.
      if (typeof envelope.envelope_id === "string") {
        socket.send(JSON.stringify({ envelope_id: envelope.envelope_id }));
      }
      if (envelope.type === "hello") {
        clearTimeout(helloTimer);
        const count = envelope.num_connections;
        log(`connected to Slack Socket Mode${Number.isInteger(count) ? ` (num_connections=${count})` : ""}`);
        if (onConnected) onConnected(envelope);
        return;
      }
      if (envelope.type === "disconnect") {
        if (envelope.reason === "link_disabled") {
          finish({ kind: "fatal", message: "Slack disabled Socket Mode for this app (disconnect reason link_disabled)" });
        } else {
          log(`Slack asked to reconnect (reason ${String(envelope.reason).slice(0, 40)})`);
          finish({ kind: "refresh" });
        }
        return;
      }
      if (envelope.type === "events_api") {
        const event = envelope.payload && envelope.payload.event;
        const reason = matchEvent(event, config);
        if (reason && !isSeen(`${event.channel}:${event.ts}`)) finish({ kind: "match", event, reason });
      }
    };
    socket.onclose = () => finish({ kind: "retry", reason: "socket closed" });
    socket.onerror = () => finish({ kind: "retry", reason: "socket error" });
  });
}

// Waits until the deadline for the first matching message.
// Returns { event, reason } or null; throws AuthError when the operator must act.
export async function listen({ config, token, base, deadline, log = () => {}, isSeen = () => false, onConnected }) {
  let backoff = 1000;
  while (Date.now() < deadline) {
    let url;
    try {
      url = await openConnection(base, token);
    } catch (error) {
      if (error instanceof AuthError) throw error;
      log(`${error.message}; retrying`);
      await sleepUntil(deadline, error.retryAfterMs || backoff);
      backoff = Math.min(backoff * 2, MAX_BACKOFF_MS);
      continue;
    }
    const outcome = await runSocket(url, {
      config,
      deadline,
      log,
      isSeen,
      onConnected: (hello) => {
        backoff = 1000;
        if (onConnected) onConnected(hello);
      },
    });
    if (outcome.kind === "match") return { event: outcome.event, reason: outcome.reason };
    if (outcome.kind === "fatal") throw new AuthError(outcome.message);
    if (outcome.kind === "deadline") break;
    if (outcome.kind === "refresh") {
      backoff = 1000;
      continue;
    }
    log(`${outcome.reason}; reconnecting`);
    await sleepUntil(deadline, backoff);
    backoff = Math.min(backoff * 2, MAX_BACKOFF_MS);
  }
  return null;
}
