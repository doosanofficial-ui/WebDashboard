import { createPingPayload } from "./protocol";

const MAX_BACKOFF_MS = 15000;

function parseJson(raw) {
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

export class TelemetryWsClient {
  constructor({ onState, onFrame, onRtt } = {}) {
    this.onState = onState;
    this.onFrame = onFrame;
    this.onRtt = onRtt;

    this.url = null;
    this.ws = null;
    this.reconnectTimer = null;
    this.pingTimer = null;
    this.backoffMs = 1000;
    this.manualClose = false;
    this.lastPingAtMs = null;
  }

  connect(url) {
    this.url = url;
    this.manualClose = false;
    this.backoffMs = 1000;
    this._open();
  }

  disconnect() {
    this.manualClose = true;
    this._clearReconnect();
    this._stopPing();
    if (this.ws) {
      this.ws.close();
      this.ws = null;
    }
    this._emitState("disconnected");
  }

  isOpen() {
    return !!this.ws && this.ws.readyState === WebSocket.OPEN;
  }

  sendJson(payload) {
    if (!this.isOpen()) {
      return false;
    }
    this.ws.send(JSON.stringify(payload));
    return true;
  }

  _open() {
    if (!this.url) {
      return;
    }
    this._emitState("connecting");
    this.ws = new WebSocket(this.url);

    this.ws.onopen = () => {
      this.backoffMs = 1000;
      this._emitState("connected");
      this._startPing();
    };

    this.ws.onmessage = (event) => {
      const payload = parseJson(event.data);
      if (!payload) {
        return;
      }

      if (payload.type === "pong" && this.lastPingAtMs) {
        const rttMs = Date.now() - this.lastPingAtMs;
        this.lastPingAtMs = null;
        if (this.onRtt) {
          this.onRtt(rttMs);
        }
        return;
      }

      if (payload.sig && payload.status && this.onFrame) {
        this.onFrame(payload);
      }
    };

    this.ws.onerror = () => {
      // onclose handles reconnect.
    };

    this.ws.onclose = () => {
      this._stopPing();
      this.ws = null;
      if (this.manualClose) {
        return;
      }
      this._emitState("reconnecting");
      this._scheduleReconnect();
    };
  }

  _emitState(state) {
    if (this.onState) {
      this.onState(state);
    }
  }

  _scheduleReconnect() {
    this._clearReconnect();
    const delay = this.backoffMs;
    this.reconnectTimer = setTimeout(() => {
      this._open();
    }, delay);
    this.backoffMs = Math.min(this.backoffMs * 2, MAX_BACKOFF_MS);
  }

  _clearReconnect() {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
  }

  _startPing() {
    this._stopPing();
    this.pingTimer = setInterval(() => {
      if (!this.isOpen()) {
        return;
      }
      this.lastPingAtMs = Date.now();
      this.sendJson(createPingPayload());
    }, 5000);
  }

  _stopPing() {
    if (this.pingTimer) {
      clearInterval(this.pingTimer);
      this.pingTimer = null;
    }
  }
}
