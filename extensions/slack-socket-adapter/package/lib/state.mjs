// Small private state file in the host-provided FIRSTMATE_EXTENSION_STATE
// directory: recently delivered messages (so a Slack retry of an event that
// already woke firstmate is skipped), the last result per request id (so a
// pre-capture retry with the same request id replays it), and when an auth
// failure was last reported (so a broken token wakes firstmate about once an
// hour instead of on every watcher cycle), and matches acked from Slack but
// not yet returned (delivered oldest first on the next polls).

import { readFileSync, rmSync, writeFileSync } from "node:fs";
import { readFile, rename, writeFile } from "node:fs/promises";
import path from "node:path";

const FILE = "state.json";
const SLEEP_STOP_FILE = "sleep-stop.json";
const SLEEP_STOP_WINDOW_MS = 15 * 60 * 1000;
const MAX_RECENT = 500;
export const MAX_PENDING = 100;

function empty() {
  return { recent: [], pending: [], last: null, auth_failure_reported_at: 0 };
}

export async function loadState(directory) {
  if (!directory) return empty();
  try {
    const parsed = JSON.parse(await readFile(path.join(directory, FILE), "utf8"));
    const state = empty();
    if (Array.isArray(parsed.recent)) state.recent = parsed.recent.filter((key) => typeof key === "string").slice(-MAX_RECENT);
    if (Array.isArray(parsed.pending)) {
      state.pending = parsed.pending
        .filter((entry) => entry && typeof entry.key === "string" && typeof entry.output === "string")
        .map((entry) => ({ key: entry.key, output: entry.output }))
        .slice(-MAX_PENDING);
    }
    if (parsed.last && typeof parsed.last.request_id === "string" && typeof parsed.last.output === "string") {
      state.last = { request_id: parsed.last.request_id, output: parsed.last.output };
    }
    if (Number.isFinite(parsed.auth_failure_reported_at)) state.auth_failure_reported_at = parsed.auth_failure_reported_at;
    return state;
  } catch {
    return empty();
  }
}

const writes = new Map();

export function saveState(directory, state) {
  if (!directory) return Promise.resolve();
  const target = path.join(directory, FILE);
  const previous = writes.get(target) ?? Promise.resolve();
  const next = previous.catch(() => {}).then(() => writeState(target, state));
  writes.set(target, next);
  return next;
}

async function writeState(target, state) {
  const temporary = `${target}.${process.pid}.tmp`;
  const body = {
    recent: state.recent.slice(-MAX_RECENT),
    pending: state.pending.slice(-MAX_PENDING),
    last: state.last,
    auth_failure_reported_at: state.auth_failure_reported_at,
  };
  await writeFile(temporary, `${JSON.stringify(body)}\n`, { mode: 0o600 });
  await rename(temporary, target);
}

// Synchronous: the host allows 250 ms between its SIGTERM and SIGKILL.
export function markSleepStop(directory, now = Date.now()) {
  if (!directory) return;
  writeFileSync(path.join(directory, SLEEP_STOP_FILE), `${JSON.stringify({ at: now })}\n`, { mode: 0o600 });
}

// True once for a stop marked in the last 15 minutes; the mark is consumed.
export function takeSleepStop(directory, now = Date.now()) {
  if (!directory) return false;
  const file = path.join(directory, SLEEP_STOP_FILE);
  let at;
  try {
    at = JSON.parse(readFileSync(file, "utf8")).at;
  } catch {
    return false;
  }
  rmSync(file, { force: true });
  return Number.isFinite(at) && now - at >= 0 && now - at <= SLEEP_STOP_WINDOW_MS;
}
