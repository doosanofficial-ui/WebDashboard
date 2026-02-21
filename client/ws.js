export class JsonCodec {
  encode(payload) {
    return JSON.stringify(payload);
  }

  decode(raw) {
    return JSON.parse(raw);
  }
}

export class TelemetrySocket {
  constructor({
    url,
    codec = new JsonCodec(),
    onStatus = () => {},
    onMessage = () => {},
    onFrame = () => {},
    baseBackoffMs = 500,
    maxBackoffMs = 8000,
  }) {
    this.url = url;
    this.codec = codec;
    this.onStatus = onStatus;
    this.onMessage = onMessage;
    this.onFrame = onFrame;
    this.baseBackoffMs = baseBackoffMs;
    this.maxBackoffMs = maxBackoffMs;

    this.ws = null;
    this.manualClose = false;
    this.reconnectAttempt = 0;
    this.reconnectTimer = null;
  }

  connect() {
    this.manualClose = false;
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    this.reconnectAttempt = 0;
    this._open();
  }

  disconnect() {
    this.manualClose = true;
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    if (this.ws) {
      this.ws.close(1000, "manual close");
    }
    this._emitStatus("disconnected");
  }

  isOpen() {
    return this.ws && this.ws.readyState === WebSocket.OPEN;
  }

  send(payload) {
    if (!this.isOpen()) {
      return false;
    }
    this.ws.send(this.codec.encode(payload));
    return true;
  }

  _open() {
    if (this.ws && this.ws.readyState <= WebSocket.OPEN) {
      return;
    }

    this._emitStatus("connecting");
    const ws = new WebSocket(this.url);
    this.ws = ws;

    ws.addEventListener("open", () => {
      if (this.ws !== ws) {
        return;
      }
      this.reconnectAttempt = 0;
      this._emitStatus("connected");
    });

    ws.addEventListener("message", (event) => {
      if (this.ws !== ws) {
        return;
      }
      try {
        const payload = this.codec.decode(event.data);
        this.onMessage(payload);
        if (payload && payload.sig && payload.status) {
          this.onFrame(payload);
        }
      } catch {
        // ignore malformed payloads
      }
    });

    ws.addEventListener("close", () => {
      if (this.ws !== ws) {
        return;
      }
      this._emitStatus("disconnected");
      this.ws = null;
      if (!this.manualClose) {
        this._scheduleReconnect();
      }
    });

    ws.addEventListener("error", () => {
      // close handler triggers reconnect
    });
  }

  _scheduleReconnect() {
    const delay = Math.min(this.maxBackoffMs, this.baseBackoffMs * 2 ** this.reconnectAttempt);
    this.reconnectAttempt += 1;

    const jitter = Math.floor(Math.random() * 200);
    const waitMs = delay + jitter;

    this._emitStatus("reconnecting", { waitMs, attempt: this.reconnectAttempt });

    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this._open();
    }, waitMs);
  }

  _emitStatus(state, extra = {}) {
    this.onStatus({ state, ...extra });
  }
}
