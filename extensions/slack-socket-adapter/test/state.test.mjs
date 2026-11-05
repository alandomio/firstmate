import assert from "node:assert/strict";
import { mkdtemp, readdir } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { loadState, saveState } from "../package/lib/state.mjs";

test("concurrent saves both succeed and the last state wins", async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), "slack-state-"));
  const state = await loadState(dir);
  const first = saveState(dir, state);
  state.recent.push("C1:1.0");
  const second = saveState(dir, state);
  await Promise.all([first, second]);
  assert.deepEqual((await loadState(dir)).recent, ["C1:1.0"]);
  assert.deepEqual((await readdir(dir)).filter((f) => f.endsWith(".tmp")), []);
});
