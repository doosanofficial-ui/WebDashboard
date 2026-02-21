import AsyncStorage from "@react-native-async-storage/async-storage";

const DEFAULT_MAX_ITEMS = 1000;

export class StoreForwardQueue {
  constructor({ storageKey = "telemetry:gps:queue:v1", maxItems = DEFAULT_MAX_ITEMS } = {}) {
    this.storageKey = storageKey;
    this.maxItems = maxItems;
    this.items = [];
    this.loaded = false;
  }

  async init() {
    if (this.loaded) {
      return this.items.length;
    }

    try {
      const raw = await AsyncStorage.getItem(this.storageKey);
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
      this.items = this.items.slice(this.items.length - this.maxItems);
    }
    await this._persist();
    return this.items.length;
  }

  async flush(sendFn, limit = 200) {
    if (!this.loaded) {
      await this.init();
    }

    let sent = 0;
    while (this.items.length > 0 && sent < limit) {
      const next = this.items[0];
      const ok = !!sendFn(next);
      if (!ok) {
        break;
      }
      this.items.shift();
      sent += 1;
    }

    await this._persist();
    return { sent, remaining: this.items.length };
  }

  async _persist() {
    try {
      await AsyncStorage.setItem(this.storageKey, JSON.stringify(this.items));
    } catch {
      // Keep memory queue even if persistence fails.
    }
  }
}
