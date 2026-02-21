import AsyncStorage from "@react-native-async-storage/async-storage";

const DEFAULT_MAX_ITEMS = 1000;

export class StoreForwardQueue {
  constructor({ storageKey = "telemetry:gps:queue:v1", maxItems = DEFAULT_MAX_ITEMS, storage = AsyncStorage } = {}) {
    this.storageKey = storageKey;
    this.maxItems = maxItems;
    this.storage = storage;
    this.items = [];
    this.loaded = false;
    this._flushing = false;
    this.overflowCount = 0;
  }

  async init() {
    if (this.loaded) {
      return this.items.length;
    }

    try {
      const raw = await this.storage.getItem(this.storageKey);
      if (raw) {
        const parsed = JSON.parse(raw);
        if (Array.isArray(parsed)) {
          this.items = parsed;
        }
      }
    } catch {
      this.items = [];
    }

    this.loaded = true;
    return this.items.length;
  }

  depth() {
    return this.items.length;
  }

  async enqueue(payload) {
    if (!this.loaded) {
      await this.init();
    }

    this.items.push(payload);
    if (this.items.length > this.maxItems) {
      const dropped = this.items.length - this.maxItems;
      this.overflowCount += dropped;
      this.items = this.items.slice(dropped);
    }
    await this._persist();
    return this.items.length;
  }

  async flush(sendFn, limit = 200) {
    if (this._flushing) {
      return { sent: 0, remaining: this.items.length };
    }
    if (!this.loaded) {
      await this.init();
    }

    this._flushing = true;
    let sent = 0;
    try {
      while (this.items.length > 0 && sent < limit) {
        const next = this.items[0];
        const ok = !!sendFn(next);
        if (!ok) {
          break;
        }
        this.items.shift();
        sent += 1;
      }
    } finally {
      this._flushing = false;
    }

    await this._persist();
    return { sent, remaining: this.items.length };
  }

  async _persist() {
    try {
      await this.storage.setItem(this.storageKey, JSON.stringify(this.items));
    } catch {
      // Keep memory queue even if persistence fails.
    }
  }
}
