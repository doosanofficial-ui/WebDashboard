import { ScrollingChart } from "./charts.js";
import { GpsTracker } from "./gps.js";
import { NaverMap } from "./naver-map.js";
import { NaverRoadview } from "./naver-roadview.js";
import { updateConnection, updateGauges, updateGps } from "./ui.js";
import { JsonCodec, TelemetrySocket } from "./ws.js";

const els = {
  serverUrl: document.getElementById("serverUrl"),
  connectBtn: document.getElementById("connectBtn"),
  disconnectBtn: document.getElementById("disconnectBtn"),
  startGpsBtn: document.getElementById("startGpsBtn"),
  themeBtn: document.getElementById("themeBtn"),
  gpsMode: document.getElementById("gpsMode"),
  markBtn: document.getElementById("markBtn"),
  markNote: document.getElementById("markNote"),
  connState: document.getElementById("connState"),
  frameAge: document.getElementById("frameAge"),
  seqValue: document.getElementById("seqValue"),
  dropValue: document.getElementById("dropValue"),
  rttValue: document.getElementById("rttValue"),
  gpsState: document.getElementById("gpsState"),
  gpsLat: document.getElementById("gpsLat"),
  gpsLon: document.getElementById("gpsLon"),
  gpsSpd: document.getElementById("gpsSpd"),
  gpsHdg: document.getElementById("gpsHdg"),
  gpsAcc: document.getElementById("gpsAcc"),
  gpsAge: document.getElementById("gpsAge"),
  headingArrow: document.getElementById("headingArrow"),
  gpsMap: document.getElementById("gpsMap"),
  mapHint: document.getElementById("mapHint"),
  bottomLayout: document.getElementById("bottomLayout"),
  splitterMain: document.getElementById("splitterMain"),
  gpsViews: document.getElementById("gpsViews"),
  splitterMapRoadview: document.getElementById("splitterMapRoadview"),
  naverRoadview: document.getElementById("naverRoadview"),
  naverRoadviewStatus: document.getElementById("naverRoadviewStatus"),
  naverRoadviewAddress: document.getElementById("naverRoadviewAddress"),
  gauge: {
    ws_fl: document.getElementById("g_ws_fl"),
    ws_fr: document.getElementById("g_ws_fr"),
    ws_rl: document.getElementById("g_ws_rl"),
    ws_rr: document.getElementById("g_ws_rr"),
    yaw: document.getElementById("g_yaw"),
    ay: document.getElementById("g_ay"),
  },
};

const speedChart = new ScrollingChart(document.getElementById("speedChart"), {
  windowSec: 60,
  yMin: 0,
  yMax: 180,
  series: [
    { key: "ws_fl", label: "WS FL", color: "#4dd4ac" },
    { key: "ws_fr", label: "WS FR", color: "#ffbc42" },
  ],
});

const dynChart = new ScrollingChart(document.getElementById("dynChart"), {
  windowSec: 60,
  yMin: -25,
  yMax: 25,
  series: [
    { key: "yaw", label: "Yaw", color: "#76c6ff" },
    { key: "ay", label: "Ay", color: "#ff7c7c" },
  ],
});

const gpsTracker = new GpsTracker({
  mode: "hold",
  emaAlpha: 0.25,
  staleMs: 4000,
});

const naverMap = new NaverMap({
  container: els.gpsMap,
  hintEl: els.mapHint,
  defaultCenter: [37.5665, 126.978],
  defaultZoom: 16,
  trailLimit: 1200,
});

const roadview = new NaverRoadview({
  container: els.naverRoadview,
  statusEl: els.naverRoadviewStatus,
  addressEl: els.naverRoadviewAddress,
});

let socket = null;
let pingTimer = null;
let socketState = "disconnected";
let lastCanFrame = null;
let lastFrameRecvMs = null;
let lastSeq = null;
let lastServerDrop = 0;
let localDropCount = 0;
let rttMs = null;
let lastGpsView = null;
let gpsStateOverride = null;
let gpsNoFixTimer = null;
const layoutState = {
  mainSplitPct: 58,
  mapSplitPct: 50,
};
const MOBILE_BREAKPOINT = 860;
const FRAME_STALENESS_THRESHOLD_MS = 1500;
const THEME_STORAGE_KEY = "telemetry-theme";

els.serverUrl.value = `${window.location.protocol}//${window.location.host}`;

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value));
}

function readStoredTheme() {
  try {
    const stored = window.localStorage.getItem(THEME_STORAGE_KEY);
    return stored === "day" ? "day" : "night";
  } catch {
    return "night";
  }
}

function writeStoredTheme(theme) {
  try {
    window.localStorage.setItem(THEME_STORAGE_KEY, theme);
  } catch {
    // ignore private mode/storage policy failures
  }
}

function applyTheme(theme) {
  const normalized = theme === "day" ? "day" : "night";
  document.documentElement.setAttribute("data-theme", normalized);
  writeStoredTheme(normalized);

  if (els.themeBtn) {
    els.themeBtn.textContent = normalized === "day" ? "Theme: Day" : "Theme: Night";
  }

  const themeColor = normalized === "day" ? "#e8eef5" : "#0f1720";
  const meta = document.querySelector("meta[name='theme-color']");
  if (meta) {
    meta.setAttribute("content", themeColor);
  }
}

function applySplitLayout() {
  if (window.innerWidth <= MOBILE_BREAKPOINT) {
    if (els.bottomLayout) {
      els.bottomLayout.style.gridTemplateColumns = "";
    }
    if (els.gpsViews) {
      els.gpsViews.style.gridTemplateColumns = "";
    }
    return;
  }

  if (els.bottomLayout) {
    const main = clamp(layoutState.mainSplitPct, 38, 72);
    els.bottomLayout.style.gridTemplateColumns = `${main}% var(--splitter-size, 8px) ${100 - main}%`;
  }

  if (els.gpsViews) {
    const inner = clamp(layoutState.mapSplitPct, 30, 70);
    els.gpsViews.style.gridTemplateColumns = `${inner}% var(--splitter-size, 8px) ${100 - inner}%`;
  }
}

function installVerticalSplitter({ splitterEl, containerEl, minPct, maxPct, onRatio }) {
  if (!splitterEl || !containerEl) {
    return;
  }

  const onPointerMove = (event) => {
    const rect = containerEl.getBoundingClientRect();
    if (!rect.width) {
      return;
    }
    const ratio = ((event.clientX - rect.left) / rect.width) * 100;
    onRatio(clamp(ratio, minPct, maxPct));
  };

  const onPointerUp = () => {
    window.removeEventListener("pointermove", onPointerMove);
    window.removeEventListener("pointerup", onPointerUp);
    window.removeEventListener("pointercancel", onPointerUp);
    document.body.classList.remove("resizing");
  };

  splitterEl.addEventListener("pointerdown", (event) => {
    if (window.innerWidth <= MOBILE_BREAKPOINT) {
      return;
    }
    event.preventDefault();
    splitterEl.setPointerCapture?.(event.pointerId);
    document.body.classList.add("resizing");
    window.addEventListener("pointermove", onPointerMove);
    window.addEventListener("pointerup", onPointerUp);
    window.addEventListener("pointercancel", onPointerUp);
  });
}

function fitViewportLayout() {
  const topbar = document.querySelector(".topbar");
  const main = document.querySelector("main");
  if (!topbar || !main) {
    return;
  }

  if (window.innerWidth <= MOBILE_BREAKPOINT) {
    main.style.height = "auto";
    applySplitLayout();
    naverMap.resize();
    roadview.resize();
    return;
  }

  const viewportH = window.innerHeight;
  const topbarH = Math.ceil(topbar.getBoundingClientRect().height);
  const mainHeight = Math.max(320, viewportH - topbarH);
  main.style.height = `${mainHeight}px`;

  applySplitLayout();
  naverMap.resize();
  roadview.resize();
}

let currentTheme = readStoredTheme();
applyTheme(currentTheme);

if (els.themeBtn) {
  els.themeBtn.addEventListener("click", () => {
    currentTheme = currentTheme === "day" ? "night" : "day";
    applyTheme(currentTheme);
  });
}

async function initPublicConfig() {
  try {
    const res = await fetch("/api/public-config");
    if (!res.ok) {
      throw new Error(`HTTP ${res.status}`);
    }

    const payload = await res.json();
    const naverClientId = payload?.naver?.clientId;
    await naverMap.init(naverClientId);
    await roadview.init(naverClientId);
    fitViewportLayout();
  } catch (err) {
    els.naverRoadviewStatus.textContent = `로드뷰 설정 조회 실패: ${err.message}`;
    els.naverRoadviewStatus.classList.add("error");
  }
}

installVerticalSplitter({
  splitterEl: els.splitterMain,
  containerEl: els.bottomLayout,
  minPct: 38,
  maxPct: 72,
  onRatio: (value) => {
    layoutState.mainSplitPct = value;
    applySplitLayout();
    naverMap.resize();
    roadview.resize();
  },
});

installVerticalSplitter({
  splitterEl: els.splitterMapRoadview,
  containerEl: els.gpsViews,
  minPct: 30,
  maxPct: 70,
  onRatio: (value) => {
    layoutState.mapSplitPct = value;
    applySplitLayout();
    naverMap.resize();
    roadview.resize();
  },
});

initPublicConfig();
fitViewportLayout();
window.addEventListener("resize", fitViewportLayout);
window.addEventListener("orientationchange", fitViewportLayout);

function normalizeHttpBase(rawInput) {
  let raw = rawInput.trim();
  if (!raw) {
    return `${window.location.protocol}//${window.location.host}`;
  }

  if (raw.startsWith("ws://") || raw.startsWith("wss://")) {
    raw = raw.replace(/^ws/i, "http");
  }

  if (!/^https?:\/\//i.test(raw)) {
    raw = `${window.location.protocol}//${raw}`;
  }

  return raw.replace(/\/+$/, "");
}

function httpToWs(httpBase) {
  return `${httpBase.replace(/^http/i, "ws")}/ws`;
}

function startPing() {
  stopPing();
  pingTimer = setInterval(() => {
    if (!socket) {
      return;
    }
    socket.send({ type: "ping", t: Date.now() / 1000 });
  }, 2000);
}

function stopPing() {
  if (pingTimer) {
    clearInterval(pingTimer);
    pingTimer = null;
  }
}

function connectSocket() {
  const base = normalizeHttpBase(els.serverUrl.value);
  const wsUrl = httpToWs(base);

  if (socket) {
    socket.disconnect();
  }

  socket = new TelemetrySocket({
    url: wsUrl,
    codec: new JsonCodec(),
    onStatus: (status) => {
      socketState = status.state;
      const connected = status.state === "connected";
      els.connectBtn.disabled = connected;
      els.disconnectBtn.disabled = !connected && status.state !== "reconnecting";

      if (connected) {
        startPing();
      }
      if (status.state === "disconnected") {
        stopPing();
      }
    },
    onMessage: (payload) => {
      if (payload?.type === "pong" && Number.isFinite(payload.t)) {
        rttMs = Math.max(0, Date.now() - payload.t * 1000);
      }
    },
    onFrame: (frame) => {
      const seq = frame?.status?.seq;
      const serverDrop = Number.isFinite(frame?.status?.drop) ? frame.status.drop : 0;

      if (Number.isFinite(seq) && Number.isFinite(lastSeq) && seq > lastSeq + 1) {
        const seqGap = seq - lastSeq - 1;
        const serverDropGap = Math.max(0, serverDrop - lastServerDrop);
        const networkGap = Math.max(0, seqGap - serverDropGap);
        localDropCount += networkGap;
      }

      if (Number.isFinite(seq)) {
        lastSeq = seq;
      }
      lastServerDrop = serverDrop;

      lastCanFrame = frame;
      lastFrameRecvMs = performance.now();
    },
  });

  socket.connect();
}

function disconnectSocket() {
  if (socket) {
    socket.disconnect();
  }
  stopPing();
}

function setGpsOverride(text, className = "stale") {
  gpsStateOverride = { text, className };
}

function clearGpsOverride() {
  gpsStateOverride = null;
}

function applyGpsOverrideIfNeeded(gpsView) {
  if (!gpsStateOverride) {
    return;
  }
  if (gpsView?.fix) {
    clearGpsOverride();
    return;
  }
  els.gpsState.textContent = gpsStateOverride.text;
  els.gpsState.className = `pill ${gpsStateOverride.className}`;
}

function describeGpsError(err) {
  const code = Number(err?.code);
  if (code === 1) {
    return "gps-denied";
  }
  if (code === 2) {
    return "gps-unavailable";
  }
  if (code === 3) {
    return "gps-timeout";
  }
  return "gps-error";
}

function detectClientOs() {
  const ua = navigator.userAgent || "";
  if (/iPad|iPhone|iPod/i.test(ua)) {
    return "iOS";
  }
  if (/Android/i.test(ua)) {
    return "Android";
  }
  if (/Mac OS X|Macintosh/i.test(ua)) {
    return "macOS";
  }
  if (/Windows/i.test(ua)) {
    return "Windows";
  }
  return "Unknown";
}

function sendGpsUplink(fix) {
  if (!socket || !socket.isOpen()) {
    return;
  }

  socket.send({
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
      source: "web",
      bg_state: document.visibilityState === "visible" ? "foreground" : "background",
      os: detectClientOs(),
      app_ver: "web-mvp-v1",
      device: navigator.platform || "unknown",
    },
  });
}

function sendMark() {
  const t = Date.now() / 1000;
  const note = els.markNote.value || "";

  speedChart.addMarker(t, "MARK");
  dynChart.addMarker(t, "MARK");

  if (socket && socket.isOpen()) {
    socket.send({ v: 1, t, type: "MARK", note });
  }

  if (lastGpsView?.fix) {
    naverMap.addMark(lastGpsView.fix, note);
  }
}

els.connectBtn.addEventListener("click", connectSocket);
els.disconnectBtn.addEventListener("click", disconnectSocket);
els.markBtn.addEventListener("click", sendMark);
els.gpsMode.addEventListener("change", () => gpsTracker.setMode(els.gpsMode.value));

els.startGpsBtn.addEventListener("click", () => {
  if (gpsNoFixTimer) {
    clearTimeout(gpsNoFixTimer);
    gpsNoFixTimer = null;
  }

  if (!window.isSecureContext) {
    setGpsOverride("gps-no-fix(http)", "stale");
  } else {
    clearGpsOverride();
  }

  // If no fix is received soon after starting, show an explicit hint.
  gpsNoFixTimer = setTimeout(() => {
    if (!gpsTracker.lastFix) {
      setGpsOverride(
        window.isSecureContext ? "gps-no-fix" : "gps-no-fix(https권장)",
        "stale"
      );
    }
  }, 12000);

  try {
    gpsTracker.start(
      (fix) => {
        clearGpsOverride();
        sendGpsUplink(fix);
      },
      (err) => {
        console.error("GPS error", err);
        setGpsOverride(describeGpsError(err), "disconnected");
      }
    );
    els.startGpsBtn.disabled = true;
  } catch (err) {
    console.error(err);
    setGpsOverride("gps-not-supported", "disconnected");
  }
});

setInterval(() => {
  const nowMs = performance.now();
  const nowSec = Date.now() / 1000;

  const connectionVisible = Boolean(socket && socket.isOpen()) || socketState === "reconnecting";
  const frameAgeMs = Number.isFinite(lastFrameRecvMs) ? nowMs - lastFrameRecvMs : null;
  const stale =
    !socket ||
    !socket.isOpen() ||
    !Number.isFinite(frameAgeMs) ||
    frameAgeMs > FRAME_STALENESS_THRESHOLD_MS;

  if (lastCanFrame?.sig) {
    updateGauges(els.gauge, lastCanFrame.sig);
    speedChart.addSample(nowSec, lastCanFrame.sig);
    dynChart.addSample(nowSec, lastCanFrame.sig);
  }

  const serverDrop = Number.isFinite(lastCanFrame?.status?.drop) ? lastCanFrame.status.drop : 0;
  updateConnection(els, {
    connected: connectionVisible,
    frameAgeMs,
    seq: lastCanFrame?.status?.seq,
    drop: serverDrop + localDropCount,
    rttMs,
    stale,
  });

  const gpsView = gpsTracker.tick(nowMs);
  lastGpsView = gpsView;
  updateGps(els, gpsView);
  applyGpsOverrideIfNeeded(gpsView);
  naverMap.updateFromFix(gpsView.fix, gpsView.stale);
  roadview.updateFromFix(gpsView.fix, gpsView.stale);
}, 100);

function renderLoop() {
  const nowSec = Date.now() / 1000;
  speedChart.render(nowSec);
  dynChart.render(nowSec);
  requestAnimationFrame(renderLoop);
}

renderLoop();

if ("serviceWorker" in navigator) {
  window.addEventListener("load", () => {
    const isLocalDevHost =
      window.location.hostname === "127.0.0.1" || window.location.hostname === "localhost";

    if (isLocalDevHost) {
      navigator.serviceWorker
        .getRegistrations()
        .then((regs) => Promise.all(regs.map((reg) => reg.unregister())))
        .catch(() => {});
      return;
    }

    navigator.serviceWorker.register("/sw.js").catch(() => {});
  });
}
