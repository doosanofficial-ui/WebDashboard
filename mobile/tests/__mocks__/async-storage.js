// Minimal in-memory AsyncStorage mock used only when resolving the module
// import from store-forward-queue.js during tests. The tests themselves
// pass a storage stub via the constructor, so this mock is never called.
const store = {};

module.exports = {
  getItem: async (key) => store[key] ?? null,
  setItem: async (key, value) => { store[key] = value; },
  removeItem: async (key) => { delete store[key]; },
};
