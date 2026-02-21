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
