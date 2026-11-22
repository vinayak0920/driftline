// Driftline Friends relay: one Durable Object per room code.
// Each Mac holds one WebSocket. The relay forwards profiles and gestures
// between the people in the room and nothing else. No messages are stored.
import { DurableObject } from "cloudflare:workers";

const CHARACTERS = new Set(["mochi", "pebble", "ghosty", "bean"]);
const GESTURES = new Set(["wave", "heart", "thumbs", "laugh", "highfive", "dance", "sleepy", "coffee", "poke"]);
const MAX_PEOPLE = 8;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/") return new Response("Driftline relay is running.");

    const match = url.pathname.match(/^\/room\/([A-Z0-9]{6})$/);
    if (!match) return new Response("Not found", { status: 404 });
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("Expected a WebSocket", { status: 426 });
    }
    const stub = env.ROOMS.get(env.ROOMS.idFromName(match[1]));
    return stub.fetch(request);
  },
};

function sanitize(input) {
  const id = String(input.id ?? "").slice(0, 64);
  const name = String(input.name ?? "Friend").replace(/[\u0000-\u001f]/g, "").trim().slice(0, 20) || "Friend";
  const character = CHARACTERS.has(input.character) ? input.character : "mochi";
  const color = Math.max(0, Math.min(5, parseInt(input.color, 10) || 0));
  return { id, name, character, color };
}

export class Room extends DurableObject {
  async fetch(request) {
    const url = new URL(request.url);
    const profile = sanitize(Object.fromEntries(url.searchParams));
    if (!profile.id) return new Response("Missing id", { status: 400 });

    // A reconnecting Mac replaces its own old socket.
    for (const ws of this.ctx.getWebSockets()) {
      if (ws.deserializeAttachment()?.id === profile.id) {
        ws.serializeAttachment({ ...profile, replaced: true });
        try { ws.close(4000, "replaced"); } catch {}
      }
    }
    if (this.people(profile.id).length >= MAX_PEOPLE) {
      return new Response("Room is full", { status: 403 });
    }

    const [client, server] = Object.values(new WebSocketPair());
    this.ctx.acceptWebSocket(server); // hibernation API: idle rooms cost nothing
    server.serializeAttachment(profile);

    server.send(JSON.stringify({ type: "roster", peers: this.people(profile.id) }));
    this.broadcast({ type: "join", peer: profile }, server);
    return new Response(null, { status: 101, webSocket: client });
  }

  people(exceptId) {
    const seen = new Map();
    for (const ws of this.ctx.getWebSockets()) {
      const p = ws.deserializeAttachment();
      if (p && !p.replaced && p.id !== exceptId) seen.set(p.id, sanitize(p));
    }
    return [...seen.values()];
  }

  broadcast(message, except) {
    const text = JSON.stringify(message);
    for (const ws of this.ctx.getWebSockets()) {
      if (ws === except || ws.deserializeAttachment()?.replaced) continue;
      try { ws.send(text); } catch {}
    }
  }

  async webSocketMessage(ws, data) {
    if (typeof data !== "string" || data.length > 2000) return;
    let msg;
    try { msg = JSON.parse(data); } catch { return; }
    const me = ws.deserializeAttachment();
    if (!me || me.replaced) return;

    if (msg.type === "gesture" && GESTURES.has(msg.gesture)) {
      const to = typeof msg.to === "string" ? msg.to.slice(0, 64) : null;
      this.broadcast({ type: "gesture", from: me.id, gesture: msg.gesture, to }, ws);
    } else if (msg.type === "profile") {
      const updated = sanitize({ ...msg, id: me.id });
      ws.serializeAttachment(updated);
      this.broadcast({ type: "join", peer: updated }, ws);
    }
  }

  async webSocketClose(ws, code, reason) {
    this.left(ws);
    try { ws.close(code, reason); } catch {}
  }

  async webSocketError(ws) {
    this.left(ws);
  }

  left(ws) {
    const me = ws.deserializeAttachment();
    if (!me || me.replaced) return;
    ws.serializeAttachment({ ...me, replaced: true });
    // Only announce "leave" if this person has no other live connection.
    const stillHere = this.ctx.getWebSockets().some(
      (o) => o !== ws && o.deserializeAttachment()?.id === me.id && !o.deserializeAttachment()?.replaced
    );
    if (!stillHere) this.broadcast({ type: "leave", id: me.id }, ws);
  }
}
