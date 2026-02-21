import { ScrollingChart } from "./charts.js";
import { GpsTracker } from "./gps.js";
import { GpsMap } from "./map.js";
import { NaverRoadview } from "./naver-roadview.js";
import { updateConnection, updateGauges, updateGps } from "./ui.js";
import { JsonCodec, TelemetrySocket } from "./ws.js";

const els = {
  serverUrl: document.getElementById("serverUrl"),
  connectBtn: document.getElementById("connectBtn"),
  disconnectBtn: document.getElementById("disconnectBtn"),
  startGpsBtn: document.getElementById("startGpsBtn"),
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

const gpsMap = new GpsMap({
  container: els.gpsMap,
  hintEl: els.mapHint,
  defaultCenter: [37.5665, 126.978],
  defaultZoom: 16,
  trailLimit: 1200,
});
gpsMap.init();

const roadview = new NaverRoadview({
  container: els.naverRoadview,
  statusEl: els.naverRoadviewStatus,
  addressEl: els.naverRoadviewAddress,
});

let socket = null;
let pingTimer = null;
let lastCanFrame = null;
let lastFrameRecvMs = null;
let lastSeq = null;
let lastServerDrop = 0;
let localDropCount = 0;
let rttMs = null;
let lastGpsView = null;

els.serverUrl.value = `${window.location.protocol}//${window.location.host}`;

function fitViewportLayout() {
  const topbar = document.querySelector(".topbar");
  const main = document.querySelector("main");
  if (!topbar || !main) {
    return;
  }

  if (window.innerWidth <= 860) {
    main.style.height = "auto";
    gpsMap.resize();
    roadview.resize();
    return;
  }

  const viewportH = window.innerHeight;
  const topbarH = Math.ceil(topbar.getBoundingClientRect().height);
  const mainHeight = Math.max(320, viewportH - topbarH);
  main.style.height = `${mainHeight}px`;

  gpsMap.resize();
  roadview.resize();
}

async function initPublicConfig() {
  try {
    const res = await fetch("/api/public-config");
    if (!res.ok) {
      throw new Error(`HTTP ${res.status}`);
    }

    const payload = await res.json();
    const naverClientId = payload?.naver?.clientId;
    await roadview.init(naverClientId);
    fitViewportLayout();
  } catch (err) {
    els.naverRoadviewStatus.textContent = `로드뷰 설정 조회 실패: ${err.message}`;
    els.naverRoadviewStatus.classList.add("error");
  }
}

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
    gpsMap.addMark(lastGpsView.fix, note);
  }
}

els.connectBtn.addEventListener("click", connectSocket);
els.disconnectBtn.addEventListener("click", disconnectSocket);
els.markBtn.addEventListener("click", sendMark);
els.gpsMode.addEventListener("change", () => gpsTracker.setMode(els.gpsMode.value));

els.startGpsBtn.addEventListener("click", () => {
  try {
    gpsTracker.start(
      (fix) => {
        sendGpsUplink(fix);
      },
      (err) => {
        console.error("GPS error", err);
        els.gpsState.textContent = `error(${err.code})`;
      }
    );
    els.startGpsBtn.disabled = true;
  } catch (err) {
    console.error(err);
    els.gpsState.textContent = "not-supported";
  }
});

setInterval(() => {
  const nowMs = performance.now();
  const nowSec = Date.now() / 1000;

  const connected = Boolean(socket && socket.isOpen());
  const frameAgeMs = Number.isFinite(lastFrameRecvMs) ? nowMs - lastFrameRecvMs : null;
  const stale = !connected || !Number.isFinite(frameAgeMs) || frameAgeMs > 1500;

  if (lastCanFrame?.sig) {
    updateGauges(els.gauge, lastCanFrame.sig);
    speedChart.addSample(nowSec, lastCanFrame.sig);
    dynChart.addSample(nowSec, lastCanFrame.sig);
  }

  const serverDrop = Number.isFinite(lastCanFrame?.status?.drop) ? lastCanFrame.status.drop : 0;
  updateConnection(els, {
    connected,
    frameAgeMs,
    seq: lastCanFrame?.status?.seq,
    drop: serverDrop + localDropCount,
    rttMs,
    stale,
  });

  const gpsView = gpsTracker.tick(nowMs);
  lastGpsView = gpsView;
  updateGps(els, gpsView);
  gpsMap.updateFromFix(gpsView.fix, gpsView.stale);
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
