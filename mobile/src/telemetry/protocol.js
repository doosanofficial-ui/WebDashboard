import { APP_VERSION } from "../config";

export function createPingPayload() {
  return {
    v: 1,
    type: "ping",
    t: Date.now() / 1000,
  };
}

export function createGpsPayload(fix, meta) {
  return {
    v: 1,
    t: Date.now() / 1000,
    gps: {
      lat: fix.lat,
      lon: fix.lon,
      spd: fix.spd,
      hdg: fix.hdg,
      acc: fix.acc,
      alt: fix.alt,
    },
    meta: {
      source: "mobile",
      bg_state: meta?.bgState || "foreground",
      os: meta?.os || "Unknown",
      app_ver: meta?.appVersion || APP_VERSION,
      device: meta?.device || "unknown",
    },
  };
}

export function createMarkPayload(note = "") {
  return {
    v: 1,
    t: Date.now() / 1000,
    type: "MARK",
    note,
  };
}

/**
 * Stamps a payload as queued for store-and-forward replay.
 * The `queued_at` field allows the server to distinguish live from replayed
 * payloads and to measure queuing latency.
 *
 * @param {object} payload  - Any telemetry payload (e.g. from createGpsPayload).
 * @param {number} [nowSec] - Current time as a float (seconds since Unix epoch,
 *   matching the `t` field convention used by other payload builders).
 * @returns A new payload object with the `queued_at` field set.
 */
export function stampQueued(payload, nowSec = Date.now() / 1000) {
  return { ...payload, queued_at: nowSec };
}
