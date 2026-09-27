import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';

const source = readFileSync(new URL('../../client/sw.js', import.meta.url), 'utf8');
function worker({ offline = false, cacheFails = false } = {}) {
  const handlers = {}, removed = [], writes = [];
  const stored = new Map([['/gps.js', new Response('old javascript')], ['/index.html', new Response('offline shell')]]);
  const cache = {
    addAll: async () => { if (cacheFails) throw Error('storage unavailable'); },
    match: async key => stored.get(typeof key === 'string' ? key : new URL(key.url).pathname)?.clone(),
    put: async key => { if (cacheFails) throw Error('storage unavailable'); writes.push(key); },
  };
  const self = { location: { origin: 'https://dashboard.invalid' }, clients: { claim: async () => {} },
    skipWaiting() {}, addEventListener(name, callback) { handlers[name] = callback; } };
  vm.runInNewContext(source, { self, URL, caches: {
    open: async () => cache,
    match: cache.match,
    keys: async () => ['telemetry-dashboard-v5', 'unrelated-app-cache'],
    delete: async key => { removed.push(key); return true; },
  }, fetch: async () => { if (offline) throw Error('offline'); return new Response('fresh javascript'); } });
  return {
    removed, writes,
    fetch(path, mode = 'cors') {
      let response;
      handlers.fetch({ request: { url: new URL(path, self.location.origin).href, method: 'GET', mode },
        respondWith(value) { response = value; }, waitUntil() {} });
      return response;
    },
    async lifecycle(name) { let pending; handlers[name]({ waitUntil(value) { pending = value; } }); await pending; },
  };
}

test('live API responses are never intercepted or served from the PWA cache', () => {
  assert.equal(worker().fetch('/api/public-config'), undefined);
  assert.equal(worker().fetch('/api/ping'), undefined);
});
test('third-party map requests are never cached by this worker', () => {
  assert.equal(worker().fetch('https://maps.example.invalid/gps.js'), undefined);
});
test('online static assets use fresh responses instead of an old cached build', async () => {
  assert.equal(await (await worker().fetch('/gps.js')).text(), 'fresh javascript');
});
test('static cache failure does not discard a successful network response', async () => {
  assert.equal(await (await worker({ cacheFails: true }).fetch('/gps.js')).text(), 'fresh javascript');
});
test('offline missing modules do not receive HTML pretending to be JavaScript', async () => {
  await assert.rejects(worker({ offline: true }).fetch('/ui.js'));
});
test('offline navigation can use the cached app shell', async () => {
  assert.equal(await (await worker({ offline: true }).fetch('/?v=updated', 'navigate')).text(), 'offline shell');
});
test('activation only removes this application\'s old caches', async () => {
  const w = worker(); await w.lifecycle('activate');
  assert.deepEqual(w.removed, ['telemetry-dashboard-v5']);
});

test('a storage failure does not prevent installing the network-first worker', async () => {
  await worker({ cacheFails: true }).lifecycle('install');
});
