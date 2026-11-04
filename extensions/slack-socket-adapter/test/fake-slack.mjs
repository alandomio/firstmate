// Local fake of the two Slack surfaces the adapter uses:
// POST /api/apps.connections.open and the Socket Mode WebSocket.
// Minimal RFC 6455 server framing, no dependencies.

import { createHash } from "node:crypto";
import { createServer } from "node:http";

const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

function frame(text) {
  const payload = Buffer.from(text, "utf8");
  let header;
  if (payload.length < 126) {
    header = Buffer.from([0x81, payload.length]);
  } else if (payload.length < 65536) {
    header = Buffer.alloc(4);
    header[0] = 0x81;
    header[1] = 126;
    header.writeUInt16BE(payload.length, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x81;
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(payload.length), 2);
  }
  return Buffer.concat([header, payload]);
}

class Connection {
  constructor(socket, index) {
    this.socket = socket;
    this.index = index;
    this.closed = false;
    this.buffer = Buffer.alloc(0);
    this.listeners = [];
    socket.on("data", (chunk) => this.receive(chunk));
    socket.on("close", () => {
      this.closed = true;
    });
    socket.on("error", () => {});
  }

  receive(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    while (this.buffer.length >= 2) {
      const opcode = this.buffer[0] & 0x0f;
      const masked = (this.buffer[1] & 0x80) !== 0;
      let length = this.buffer[1] & 0x7f;
      let offset = 2;
      if (length === 126) {
        if (this.buffer.length < 4) return;
        length = this.buffer.readUInt16BE(2);
        offset = 4;
      } else if (length === 127) {
        if (this.buffer.length < 10) return;
        length = Number(this.buffer.readBigUInt64BE(2));
        offset = 10;
      }
      const maskBytes = masked ? 4 : 0;
      if (this.buffer.length < offset + maskBytes + length) return;
      const mask = masked ? this.buffer.subarray(offset, offset + 4) : null;
      const payload = Buffer.from(this.buffer.subarray(offset + maskBytes, offset + maskBytes + length));
      if (mask) for (let i = 0; i < payload.length; i += 1) payload[i] ^= mask[i % 4];
      this.buffer = this.buffer.subarray(offset + maskBytes + length);
      if (opcode === 0x8) {
        if (!this.closed) {
          this.socket.write(Buffer.from([0x88, 0]));
          this.socket.end();
        }
        this.closed = true;
      } else if (opcode === 0x9) {
        this.socket.write(Buffer.concat([Buffer.from([0x8a, payload.length]), payload]));
      } else if (opcode === 0x1) {
        const text = payload.toString("utf8");
        for (const listener of this.listeners) listener(text);
      }
    }
  }

  send(value) {
    if (this.closed) return;
    this.socket.write(frame(typeof value === "string" ? value : JSON.stringify(value)));
  }

  onText(listener) {
    this.listeners.push(listener);
  }

  // Abrupt close without a close frame.
  destroy() {
    this.closed = true;
    this.socket.destroy();
  }
}

// scenario(connection, server) runs for every accepted WebSocket.
// openResponses: optional array of responses for apps.connections.open, used
// in order; the last one repeats. Each entry is { status, body, headers }.
export async function startFakeSlack({ token, scenario, openResponses = null }) {
  const state = {
    opens: 0,
    authHeaders: [],
    acks: [],
    connections: [],
    sent: new Map(),
  };
  const server = createServer((request, response) => {
    if (request.method !== "POST" || request.url !== "/api/apps.connections.open") {
      response.writeHead(404).end();
      return;
    }
    request.resume();
    request.on("end", () => {
      state.opens += 1;
      state.authHeaders.push(request.headers.authorization || "");
      let reply;
      if (openResponses) {
        reply = openResponses[Math.min(state.opens - 1, openResponses.length - 1)];
      } else if (request.headers.authorization !== `Bearer ${token}`) {
        reply = { status: 200, body: { ok: false, error: "invalid_auth" } };
      } else {
        reply = { status: 200, body: { ok: true, url: `ws://127.0.0.1:${server.address().port}/link/?n=${state.opens}` } };
      }
      const body = reply.body && reply.body.url === "AUTO"
        ? { ...reply.body, url: `ws://127.0.0.1:${server.address().port}/link/?n=${state.opens}` }
        : reply.body;
      response.writeHead(reply.status || 200, { "Content-Type": "application/json", ...(reply.headers || {}) });
      response.end(JSON.stringify(body));
    });
  });
  server.on("upgrade", (request, socket) => {
    const key = request.headers["sec-websocket-key"];
    const accept = createHash("sha1").update(key + GUID).digest("base64");
    socket.write([
      "HTTP/1.1 101 Switching Protocols",
      "Upgrade: websocket",
      "Connection: Upgrade",
      `Sec-WebSocket-Accept: ${accept}`,
      "",
      "",
    ].join("\r\n"));
    const connection = new Connection(socket, state.connections.length);
    state.connections.push(connection);
    connection.onText((text) => {
      try {
        const parsed = JSON.parse(text);
        if (parsed && typeof parsed.envelope_id === "string") {
          const sentAt = state.sent.get(parsed.envelope_id);
          state.acks.push({ envelope_id: parsed.envelope_id, delayMs: sentAt === undefined ? null : Date.now() - sentAt });
        }
      } catch {
        // ignore
      }
    });
    scenario(connection, { state, sendEnvelope: (envelope) => {
      state.sent.set(envelope.envelope_id, Date.now());
      connection.send(envelope);
    } });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return {
    state,
    apiBase: `http://127.0.0.1:${server.address().port}/api`,
    close: () => new Promise((resolve) => {
      for (const connection of state.connections) connection.destroy();
      server.close(() => resolve());
    }),
  };
}

let envelopeCounter = 0;

export function hello(numConnections = 1) {
  return { type: "hello", num_connections: numConnections, connection_info: { app_id: "A0TEST" }, debug_info: {} };
}

export function messageEnvelope(event, extra = {}) {
  envelopeCounter += 1;
  return {
    envelope_id: `env-${envelopeCounter}`,
    type: "events_api",
    accepts_response_payload: false,
    retry_attempt: 0,
    retry_reason: "",
    payload: {
      token: "verification-unused",
      team_id: "T0TEST",
      api_app_id: "A0TEST",
      type: "event_callback",
      event_id: `Ev${envelopeCounter}`,
      event: { type: "message", channel_type: "channel", ...event },
    },
    ...extra,
  };
}
