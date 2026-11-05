// Decide whether one Slack Events API event should wake firstmate.

export const RESULT_SCHEMA = "slack-socket-adapter.message.v1";
export const MAX_TEXT_CHARS = 2000;

// A direct ask: "can/could someone|somebody|anyone", or "anyone" on its own.
const ASK_RE = /\b(?:(?:can|could)\s+(?:someone|somebody|anyone)|anyone)\b/i;
const USER_RE = /^[UW][A-Z0-9]{2,20}$/;

function mentions(text, userIds) {
  return userIds.some((id) => text.includes(`<@${id}>`) || text.includes(`<@${id}|`));
}

// Returns null when the event does not match, otherwise the reason string.
export function matchEvent(event, config) {
  if (!event || typeof event !== "object") return null;
  if (event.type !== "message") return null;
  if (event.subtype !== undefined) return null;
  if (event.bot_id !== undefined || event.bot_profile !== undefined) return null;
  if (typeof event.user !== "string" || !USER_RE.test(event.user)) return null;
  if (typeof event.ts !== "string" || typeof event.channel !== "string") return null;
  if (event.thread_ts !== undefined && event.thread_ts !== event.ts) return null;
  const channel = config.channels.find((entry) => entry.id === event.channel);
  if (!channel) return null;
  if (channel.mode === "all") return "all";
  const text = typeof event.text === "string" ? event.text : "";
  if (mentions(text, config.mentions)) return "mention";
  if (ASK_RE.test(text)) return "ask-phrase";
  return null;
}

export function truncateText(text) {
  const characters = Array.from(typeof text === "string" ? text : "");
  if (characters.length <= MAX_TEXT_CHARS) return { text: characters.join(""), truncated: false };
  return { text: characters.slice(0, MAX_TEXT_CHARS).join(""), truncated: true };
}

export function resultFor(event, reason) {
  const { text, truncated } = truncateText(event.text);
  return {
    schema: RESULT_SCHEMA,
    channel: event.channel,
    ts: event.ts,
    user: event.user,
    text,
    text_truncated: truncated,
    matched: reason,
  };
}
