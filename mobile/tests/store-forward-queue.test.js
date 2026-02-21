import { StoreForwardQueue } from "../src/telemetry/store-forward-queue";

/**
 * Minimal synchronous in-memory storage stub that satisfies the
 * AsyncStorage interface used by StoreForwardQueue.
 */
function makeStorage() {
  const store = {};
  return {
    getItem: jest.fn(async (key) => store[key] ?? null),
    setItem: jest.fn(async (key, value) => { store[key] = value; }),
  };
}

describe("StoreForwardQueue", () => {
  describe("enqueue", () => {
    it("persists a single item and returns depth 1", async () => {
      const q = new StoreForwardQueue({ storage: makeStorage() });
      const depth = await q.enqueue({ id: 1 });
      expect(depth).toBe(1);
      expect(q.depth()).toBe(1);
    });

    it("preserves insertion order (FIFO)", async () => {
      const q = new StoreForwardQueue({ storage: makeStorage() });
      await q.enqueue({ id: 1 });
      await q.enqueue({ id: 2 });
      await q.enqueue({ id: 3 });
      expect(q.items.map((x) => x.id)).toEqual([1, 2, 3]);
    });

    it("enforces maxItems by dropping oldest items on overflow", async () => {
      const q = new StoreForwardQueue({ maxItems: 3, storage: makeStorage() });
      for (let i = 1; i <= 5; i++) {
        await q.enqueue({ id: i });
      }
      expect(q.depth()).toBe(3);
      expect(q.items.map((x) => x.id)).toEqual([3, 4, 5]);
    });

    it("increments overflowCount for each dropped item", async () => {
      const q = new StoreForwardQueue({ maxItems: 2, storage: makeStorage() });
      await q.enqueue({ id: 1 });
      await q.enqueue({ id: 2 });
      await q.enqueue({ id: 3 }); // drops id:1 → overflowCount = 1
      await q.enqueue({ id: 4 }); // drops id:2 → overflowCount = 2
      expect(q.overflowCount).toBe(2);
    });
  });

  describe("flush", () => {
    it("delivers queued items to sendFn in order and returns sent count", async () => {
      const q = new StoreForwardQueue({ storage: makeStorage() });
      await q.enqueue({ id: 1 });
      await q.enqueue({ id: 2 });
      await q.enqueue({ id: 3 });

      const received = [];
      const { sent, remaining } = await q.flush((payload) => {
        received.push(payload.id);
        return true;
      });

      expect(sent).toBe(3);
      expect(remaining).toBe(0);
      expect(received).toEqual([1, 2, 3]);
    });

    it("stops flushing when sendFn returns falsy", async () => {
      const q = new StoreForwardQueue({ storage: makeStorage() });
      await q.enqueue({ id: 1 });
      await q.enqueue({ id: 2 });
      await q.enqueue({ id: 3 });

      const received = [];
      const { sent, remaining } = await q.flush((payload) => {
        received.push(payload.id);
        // Fail after the first delivery
        return payload.id < 2;
      });

      expect(sent).toBe(1);
      expect(remaining).toBe(2);
      expect(received).toEqual([1, 2]);
    });

    it("respects the per-flush limit parameter", async () => {
      const q = new StoreForwardQueue({ storage: makeStorage() });
      for (let i = 1; i <= 5; i++) {
        await q.enqueue({ id: i });
      }

      const { sent, remaining } = await q.flush(() => true, 2);
      expect(sent).toBe(2);
      expect(remaining).toBe(3);
    });

    it("returns immediately without sending when a flush is already in progress", async () => {
      const q = new StoreForwardQueue({ storage: makeStorage() });
      await q.enqueue({ id: 1 });

      // Manually set the internal guard to simulate a concurrent flush
      q._flushing = true;
      const { sent, remaining } = await q.flush(() => true);

      expect(sent).toBe(0);
      expect(remaining).toBe(1);
      // Reset so the queue isn't left in a broken state
      q._flushing = false;
    });
  });

  describe("init", () => {
    it("loads persisted items from storage on first init", async () => {
      const stored = [{ id: 10 }, { id: 20 }];
      const storage = makeStorage();
      storage.getItem.mockResolvedValueOnce(JSON.stringify(stored));

      const q = new StoreForwardQueue({ storage });
      const depth = await q.init();

      expect(depth).toBe(2);
      expect(q.items).toEqual(stored);
    });

    it("starts empty when storage contains invalid JSON", async () => {
      const storage = makeStorage();
      storage.getItem.mockResolvedValueOnce("not-valid-json{{");

      const q = new StoreForwardQueue({ storage });
      const depth = await q.init();

      expect(depth).toBe(0);
      expect(q.items).toEqual([]);
    });

    it("does not re-read storage on subsequent init calls", async () => {
      const storage = makeStorage();
      const q = new StoreForwardQueue({ storage });
      await q.init();
      await q.init();

      expect(storage.getItem).toHaveBeenCalledTimes(1);
    });
  });
});
