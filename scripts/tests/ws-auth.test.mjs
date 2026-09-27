import test from "node:test";
import assert from "node:assert/strict";
import { TelemetrySocket } from "../../client/ws.js";

class FakeWebSocket {
  static OPEN = 1;
  constructor() {
    this.readyState = FakeWebSocket.OPEN;
    this.handlers = {};
    this.sent = [];
  }
  addEventListener(name, handler) { this.handlers[name] = handler; }
  send(value) { this.sent.push(JSON.parse(value)); }
  close() { this.readyState = 3; this.handlers.close?.({ code: 1000 }); }
  emit(name, value) { this.handlers[name]?.(value); }
}

test("WebSocket auth token is sent only after opening and gates uplink", () => {
  const statuses = [];
  globalThis.WebSocket = FakeWebSocket;
  const socket = new TelemetrySocket({
    url: "wss://example.test/ws",
    authToken: "secret",
    onStatus: status => statuses.push(status.state),
  });
  socket.connect();
  const raw = socket.ws;
  raw.emit("open", {});
  assert.deepEqual(raw.sent, [{ v: 1, type: "auth", token: "secret" }]);
  assert.equal(socket.send({ v: 1, type: "MARK" }), false);
  raw.emit("message", { data: JSON.stringify({ v: 1, type: "auth_ok" }) });
  assert.equal(socket.send({ v: 1, type: "MARK" }), true);
  assert.deepEqual(statuses, ["connecting", "connected", "authenticated"]);
});
