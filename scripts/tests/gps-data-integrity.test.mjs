import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const root = new URL('../../', import.meta.url);

// Load the production ES modules unchanged; only OS location APIs are replaced.
async function load(relative, dependencies = {}, globals = {}) {
  const context = vm.createContext({ console, Date, ...globals });
  const cache = new Map();
  function moduleFor(url) {
    if (!cache.has(url.href)) {
      cache.set(url.href, new vm.SourceTextModule(readFileSync(url, 'utf8'), {
        context, identifier: url.href,
      }));
    }
    return cache.get(url.href);
  }
  const entry = moduleFor(new URL(relative, root));
  await entry.link((name, parent) => {
    if (dependencies[name]) {
      const values = dependencies[name];
      return new vm.SyntheticModule(Object.keys(values), function () {
        for (const [key, value] of Object.entries(values)) this.setExport(key, value);
      }, { context });
    }
    return moduleFor(new URL(name.endsWith('.js') ? name : `${name}.js`, parent.identifier));
  });
  await entry.evaluate();
  return entry.namespace;
}

async function mobile({ bridge = false, backgroundRequested = bridge, os = 'ios', authorization = 'granted' } = {}) {
  let onPosition;
  const listeners = new Map();
  let configuredLevel;
  const geo = {
    setRNConfiguration: (config) => { configuredLevel = config.authorizationLevel; },
    requestAuthorization: (success, failure) => {
      assert.equal(typeof success, 'function', 'native API takes a callback, not a string');
      assert.equal(typeof failure, 'function');
      if (authorization === 'granted') success();
      else failure({ code: 1, message: 'Permission denied' });
    },
    watchPosition: (success) => { onPosition = success; return 1; },
    clearWatch: () => { onPosition = null; },
  };
  const nativeBridge = { startBackgroundLocation() {}, stopBackgroundLocation() {} };
  const rn = {
    Platform: { OS: os }, PermissionsAndroid: {},
    NativeModules: bridge ? { RNIosLocationBridge: nativeBridge } : {},
    NativeEventEmitter: class {
      addListener(name, fn) {
        listeners.set(name, fn);
        return { remove: () => listeners.delete(name) };
      }
    },
  };
  const dependencies = {
    'react-native': rn,
    '@react-native-community/geolocation': { default: geo },
  };
  const api = await load('mobile/src/telemetry/gps-client.js', dependencies);
  const protocol = await load('mobile/src/telemetry/protocol.js', dependencies);
  const client = new api.GpsClient();
  const payloads = [];
  const errors = [];
  const started = client.start((fix) => {
    // Assert the serialized uplink contract, not just a normalizer return value.
    payloads.push(JSON.parse(JSON.stringify(protocol.createGpsPayload(fix))));
  }, (error) => errors.push(error), {
    iosBackgroundMode: os === 'ios' && backgroundRequested,
    androidBackgroundMode: os === 'android' && backgroundRequested,
  });
  return {
    api, payloads, client, errors, started, watching: () => !!onPosition,
    configured: () => configuredLevel,
    emit(coords) {
      if (bridge) listeners.get('locationUpdate')(coords);
      else onPosition({ coords, timestamp: 1700000000000 });
    },
  };
}

const valid = { latitude: 37, longitude: 127, speed: 12, heading: 90, accuracy: 5, altitude: 20 };

test('recording health distinguishes queued data from confirmed writes without leaking server errors', async () => {
  const ui = await load('client/ui.js');
  const element = { textContent: '', className: '' };
  ui.updateRecording(element, { v: 1, status: { recording: { state: 'delayed', pending: 3, unconfirmed: 0, rejected: 0 } } });
  assert.equal(element.textContent, 'CSV delayed: 3 pending');
  ui.updateRecording(element, { v: 1, type: 'recording_status', recording: {
    state: 'failed', pending: 2, unconfirmed: 3, rejected: 1, error: 'private-canary',
  } });
  assert.equal(element.textContent, 'CSV failed: 6 unresolved');
  assert.equal(element.className, 'pill stale');
  ui.updateRecording(element, { v: 1, type: 'recording_status', recording: { state: 'ready', pending: -1 } });
  assert.equal(element.textContent, 'CSV status unknown');
});

test('a recording control message never becomes a fresh CAN frame', async () => {
  const handlers = {};
  class Socket {
    static OPEN = 1;
    constructor() { this.readyState = 1; }
    addEventListener(name, fn) { handlers[name] = fn; }
  }
  const ws = await load('client/ws.js', {}, { WebSocket: Socket });
  let frames = 0;
  new ws.TelemetrySocket({ url: 'ws://localhost/ws', onFrame: () => frames++ }).connect();
  handlers.message({ data: JSON.stringify({ v: 1, type: 'recording_status', recording: { state: 'failed' }, sig: { ws_fl: 99 }, status: { seq: 1 } }) });
  assert.equal(frames, 0);
});

test('a serialized WS upload rejection reaches the UI without reflecting server text', async () => {
  const ui = await load('client/ui.js');
  const handlers = {};
  class Socket {
    static OPEN = 1;
    constructor() { this.readyState = 1; }
    addEventListener(name, handler) { handlers[name] = handler; }
  }
  const ws = await load('client/ws.js', {}, { WebSocket: Socket });
  const element = { hidden: true, textContent: '', className: '' };
  Object.defineProperty(element, 'innerHTML', { set() { assert.fail('Must not inject HTML'); } });
  new ws.TelemetrySocket({ url: 'ws://localhost/ws',
    onMessage: payload => ui.showUplinkError(element, payload),
  }).connect();
  handlers.message({ data: JSON.stringify({ v: 1, type: 'error',
    error: { code: 'storage_unavailable', message: '<img src=x>private-canary' },
  }) });
  assert.equal(element.hidden, false);
  assert.match(element.textContent, /storage_unavailable/);
  assert.ok(!element.textContent.includes('private-canary'));
  assert.equal(element.className, 'pill stale');
});

test('upload error remains visible during CAN traffic and unknown codes are not reflected', async () => {
  const ui = await load('client/ui.js');
  const element = { hidden: true, textContent: '', className: '' };
  ui.showUplinkError(element, { v: 1, type: 'error', error: { code: 'invalid_payload' } });
  const errorText = element.textContent;
  assert.equal(ui.showUplinkError(element, { v: 1, sig: { ws_fl: 10 }, status: { seq: 1 } }), false);
  assert.equal(element.textContent, errorText);
  for (const code of ['constructor', '__proto__', '<script>private-canary</script>']) {
    ui.showUplinkError(element, { v: 1, type: 'error', error: { code } });
    assert.match(element.textContent, /unknown_error/);
    assert.ok(!element.textContent.includes(code));
  }
  ui.clearUplinkError(element);
  assert.equal(element.hidden, true);
  assert.equal(element.textContent, '');
});

test('transport close 1009 shows a safe size error and automatic reconnect still works', async () => {
  const ui = await load('client/ui.js');
  const sockets = [];
  let retry;
  class Socket {
    static OPEN = 1;
    constructor() { this.readyState = 1; this.handlers = {}; sockets.push(this); }
    addEventListener(name, handler) { this.handlers[name] = handler; }
  }
  const ws = await load('client/ws.js', {}, {
    WebSocket: Socket, setTimeout: fn => { retry = fn; return 1; }, clearTimeout() {},
  });
  const element = { hidden: true, textContent: '', className: '' };
  const statuses = [];
  const client = new ws.TelemetrySocket({ url: 'ws://localhost/ws',
    onMessage: payload => ui.showUplinkError(element, payload),
    onStatus: value => statuses.push(value.state),
  });
  client.connect();
  sockets[0].handlers.close({ code: 1009, reason: '<script>private-canary</script>' });
  assert.equal(element.hidden, false);
  assert.match(element.textContent, /payload_too_large/);
  assert.ok(!element.textContent.includes('private-canary'));
  assert.equal(statuses.at(-1), 'reconnecting');
  retry();
  sockets[1].handlers.open();
  assert.equal(statuses.at(-1), 'connected');
  assert.equal(client.isOpen(), true);
  assert.equal(element.hidden, false, 'Reconnection is not proof the rejected upload was stored');
});

for (const os of ['ios', 'android']) {
  test(`${os}: requesting background without a bridge fails explicitly`, async () => {
    const m = await mobile({ os, backgroundRequested: true });
    assert.equal(m.started, false);
    assert.equal(m.watching(), false);
    assert.equal(m.errors[0]?.code, 'background-unavailable');
  });
}
test('foreground watch and available iOS bridge report successful startup', async () => {
  for (const bridge of [false, true]) {
    const m = await mobile({ bridge });
    assert.equal(m.started, true);
    m.emit(valid);
    assert.equal(m.payloads.length, 1);
    m.client.stop();
  }
});

for (const bridge of [false, true]) {
  const label = bridge ? 'native bridge' : 'watchPosition';
  test(`${label}: null coordinates never emit a zero-location uplink`, async () => {
    const m = await mobile({ bridge });
    m.emit({ ...valid, latitude: null, longitude: null });
    assert.equal(m.payloads.length, 0);
  });
  test(`${label}: malformed coordinates are rejected`, async () => {
    const m = await mobile({ bridge });
    for (const latitude of [91, -91, Infinity, NaN, '', '37', false, undefined]) {
      m.emit({ ...valid, latitude });
    }
    m.emit({ ...valid, longitude: 181 });
    assert.equal(m.payloads.length, 0);
  });
  test(`${label}: unknown measurements stay null after a valid fix`, async () => {
    const m = await mobile({ bridge });
    m.emit(valid);
    for (const value of [null, undefined, -1, '', false, NaN, Infinity]) {
      m.emit({ ...valid, speed: value, heading: value, accuracy: value, altitude: null });
      const gps = m.payloads.at(-1).gps;
      assert.equal(gps.spd, null);
      assert.equal(gps.hdg, null);
      assert.equal(gps.acc, null);
      assert.equal(gps.alt, null);
    }
  });
  test(`${label}: real zero speed and north heading remain valid`, async () => {
    const m = await mobile({ bridge });
    m.emit({ latitude: 0, longitude: 0, speed: 0, heading: 0, accuracy: 0, altitude: -10 });
    assert.deepEqual(m.payloads[0].gps, { lat: 0, lon: 0, spd: 0, hdg: 0, acc: 0, alt: -10 });
  });
  test(`${label}: out-of-range heading stays unknown`, async () => {
    const m = await mobile({ bridge });
    m.emit({ ...valid, heading: 360 });
    assert.equal(m.payloads[0].gps.hdg, null);
  });
}

test('iOS permission resolves from the native success callback', async () => {
  const m = await mobile();
  assert.equal(await m.api.requestLocationPermission(), true);
  assert.equal(m.configured(), 'always');
});
test('iOS permission denial resolves false', async () => {
  const m = await mobile({ authorization: 'denied' });
  assert.equal(await m.api.requestLocationPermission(), false);
});

async function web(mode) {
  let onPosition;
  const api = await load('client/gps.js', {}, {
    navigator: { geolocation: { watchPosition(success) { onPosition = success; return 1; } } },
    performance: { now: () => 1000 },
  });
  const tracker = new api.GpsTracker({ mode });
  const fixes = [];
  tracker.start((fix) => fixes.push(JSON.parse(JSON.stringify(fix))));
  return { tracker, fixes, emit(coords) { onPosition({ coords, timestamp: 1700000000000 }); } };
}

for (const mode of ['hold', 'lerp']) {
  test(`web ${mode}: a new unknown measurement does not reuse old speed or direction`, async () => {
    const w = await web(mode);
    w.emit(valid);
    w.tracker.tick(1000);
    w.emit({ ...valid, speed: null, heading: -1, accuracy: null, altitude: null });
    assert.equal(w.fixes.at(-1).spd, null);
    assert.equal(w.fixes.at(-1).hdg, null);
    const view = w.tracker.tick(1100);
    assert.equal(view.fix.spd, null);
    assert.equal(view.fix.hdg, null);
    assert.equal(view.fix.acc, null);
    assert.equal(view.fix.alt, null);
  });
  test(`web ${mode}: no new event holds the last fix with stale status`, async () => {
    const w = await web(mode);
    w.emit(valid);
    const view = w.tracker.tick(6100);
    assert.equal(view.fix.spd, 12);
    assert.equal(view.stale, true);
    assert.equal(w.fixes.length, 1);
  });
}

for (const heading of [null, 0]) {
  test(`roadview: ${heading === null ? 'unknown heading does not turn north' : 'measured north remains valid'}`, async () => {
    const { NaverRoadview } = await load('client/naver-roadview.js', {}, {
      window: { naver: { maps: { LatLng: class {} } } },
    });
    const povs = [];
    const view = new NaverRoadview({ container: {} });
    view.ready = true;
    view.reverseGeocodeDisabled = true;
    view.panorama = { setPosition() {}, setPov(value) { povs.push(value); } };
    await view.updateFromFix({ lat: 37, lon: 127, hdg: heading }, false);
    assert.equal(povs.length, heading === null ? 0 : 1);
    if (heading === 0) assert.equal(povs[0].pan, 0);
  });
}

test('web GPS arrow is hidden for unknown heading and shown for measured north', async () => {
  const { updateGps } = await load('client/ui.js');
  const elements = Object.fromEntries(['gpsState', 'gpsLat', 'gpsLon', 'gpsSpd', 'gpsHdg', 'gpsAcc', 'gpsAge', 'headingArrow']
    .map(key => [key, { style: {} }]));
  updateGps(elements, { fix: { lat: 37, lon: 127, spd: null, hdg: null }, stale: false, ageMs: 0 });
  assert.equal(elements.gpsHdg.textContent, '-');
  assert.equal(elements.headingArrow.style.visibility, 'hidden');
  updateGps(elements, { fix: { lat: 37, lon: 127, spd: 0, hdg: 0 }, stale: false, ageMs: 0 });
  assert.equal(elements.headingArrow.style.visibility, 'visible');
  assert.equal(elements.headingArrow.style.transform, 'rotate(0deg)');
});

test('map annotations render operator notes as text instead of HTML', async () => {
  let infoContent;
  const { NaverMap } = await load('client/naver-map.js', {}, {
    window: { naver: { maps: {
      LatLng: class {}, Marker: class {},
      InfoWindow: class { constructor(options) { infoContent = options.content; } open() {} close() {} },
    } } },
    document: { createElement: () => ({ style: {}, textContent: '' }) },
    setTimeout: () => 0,
  });
  const view = new NaverMap({ container: {} });
  view.map = {};
  const note = '<b>operator note</b>';
  view.addMark({ lat: 37, lon: 127 }, note);
  assert.equal(typeof infoContent, 'object');
  assert.equal(infoContent.textContent, 'MARK: <b>operator note</b>');
});
