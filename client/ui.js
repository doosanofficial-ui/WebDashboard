function fmt(value, digits = 1, fallback = "-") {
  return Number.isFinite(value) ? value.toFixed(digits) : fallback;
}

export function updateConnection(elements, { connected, frameAgeMs, seq, drop, rttMs, stale }) {
  const { connState, frameAge, seqValue, dropValue, rttValue } = elements;

  connState.textContent = connected ? (stale ? "stale" : "connected") : "disconnected";
  connState.className = "pill " + (connected ? (stale ? "stale" : "connected") : "disconnected");

  frameAge.textContent = Number.isFinite(frameAgeMs) ? Math.round(frameAgeMs).toString() : "-";
  seqValue.textContent = Number.isFinite(seq) ? String(seq) : "-";
  dropValue.textContent = Number.isFinite(drop) ? String(drop) : "0";
  rttValue.textContent = Number.isFinite(rttMs) ? Math.round(rttMs).toString() : "-";
}

export function updateGauges(gaugeEls, sig = {}) {
  const keys = ["ws_fl", "ws_fr", "ws_rl", "ws_rr", "yaw", "ay"];
  for (const key of keys) {
    const el = gaugeEls[key];
    if (!el) {
      continue;
    }
    el.textContent = fmt(sig[key]);
  }
}

export function updateGps(elements, { fix, stale, ageMs }) {
  const { gpsState, gpsLat, gpsLon, gpsSpd, gpsHdg, gpsAcc, gpsAge, headingArrow } = elements;

  if (!fix) {
    gpsState.textContent = "idle";
    gpsState.className = "pill neutral";
    gpsLat.textContent = "-";
    gpsLon.textContent = "-";
    gpsSpd.textContent = "-";
    gpsHdg.textContent = "-";
    gpsAcc.textContent = "-";
    gpsAge.textContent = "-";
    headingArrow.style.transform = "rotate(0deg)";
    return;
  }

  gpsState.textContent = stale ? "stale" : "tracking";
  gpsState.className = "pill " + (stale ? "stale" : "connected");

  gpsLat.textContent = fmt(fix.lat, 6);
  gpsLon.textContent = fmt(fix.lon, 6);
  gpsSpd.textContent = Number.isFinite(fix.spd) ? `${(fix.spd * 3.6).toFixed(1)} km/h` : "-";
  gpsHdg.textContent = Number.isFinite(fix.hdg) ? `${fix.hdg.toFixed(1)} deg` : "-";
  gpsAcc.textContent = Number.isFinite(fix.acc) ? `${fix.acc.toFixed(1)} m` : "-";
  gpsAge.textContent = Number.isFinite(ageMs) ? `${Math.round(ageMs)} ms` : "-";

  if (Number.isFinite(fix.hdg)) {
    headingArrow.style.transform = `rotate(${fix.hdg}deg)`;
  }
}
