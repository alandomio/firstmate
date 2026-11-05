// Notices that this process was frozen, by a system sleep or SIGSTOP: the wall
// clock then jumps far past the tick interval. A Socket Mode connection seldom
// survives that, and the host's own poll timeout can expire during the sleep.

export const SUSPEND_GAP_MS = 5000;
const TICK_MS = 250;

let lastTick = Date.now();
let suspendedAt = 0;
const listeners = new Set();

setInterval(() => {
  const now = Date.now();
  const gap = now - lastTick;
  lastTick = now;
  if (gap <= SUSPEND_GAP_MS) return;
  suspendedAt = now;
  for (const listener of [...listeners]) listener(gap);
}, TICK_MS).unref();

// Calls listener(gapMs) after every detected suspension; returns an unsubscribe.
export function onSuspend(listener) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

// True when a suspension was seen, or one is in progress but the tick that
// would see it has not run yet (a signal handled first on wake).
export function wasSuspended(now = Date.now()) {
  return suspendedAt > 0 || now - lastTick > SUSPEND_GAP_MS;
}
