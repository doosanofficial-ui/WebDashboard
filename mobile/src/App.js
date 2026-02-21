import React, { useEffect, useMemo, useRef, useState } from "react";
import {
  AppState,
  Platform,
  Pressable,
  SafeAreaView,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from "react-native";
import { APP_VERSION, inferOsName, normalizeBaseUrl, toWsUrl } from "./config";
import { createGpsPayload, createMarkPayload, stampQueued } from "./telemetry/protocol";
import { requestLocationPermission, GpsClient } from "./telemetry/gps-client";
import { StoreForwardQueue } from "./telemetry/store-forward-queue";
import { TelemetryWsClient } from "./telemetry/ws-client";

function formatNumber(value, digits = 2) {
  if (!Number.isFinite(value)) {
    return "-";
  }
  return value.toFixed(digits);
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

export default function App() {
  const [serverBaseUrl, setServerBaseUrl] = useState("http://127.0.0.1:8080");
  const [connectionState, setConnectionState] = useState("disconnected");
  const [frameAgeMs, setFrameAgeMs] = useState(null);
  const [rttMs, setRttMs] = useState(null);
  const [seq, setSeq] = useState(null);
  const [drop, setDrop] = useState(0);
  const [sig, setSig] = useState(null);
  const [gpsState, setGpsState] = useState("gps-idle");
  const [gpsFix, setGpsFix] = useState(null);
  const [gpsRunning, setGpsRunning] = useState(false);
  const [queueDepth, setQueueDepth] = useState(0);
  const [bgState, setBgState] = useState(AppState.currentState || "active");
  const [iosBgPilot, setIosBgPilot] = useState(Platform.OS === "ios");
  const [androidBgPilot, setAndroidBgPilot] = useState(Platform.OS === "android");
  const [markNote, setMarkNote] = useState("");

  const lastFrameAtRef = useRef(null);
  const appStateRef = useRef(AppState.currentState || "active");
  const gpsClientRef = useRef(new GpsClient());
  const queueRef = useRef(new StoreForwardQueue());
  const flushingRef = useRef(false);

  const wsClientRef = useRef(
    new TelemetryWsClient({
      onState: (state) => setConnectionState(state),
      onFrame: (frame) => {
        setSig(frame.sig);
        setSeq(frame.status?.seq ?? null);
        setDrop(frame.status?.drop ?? 0);
        lastFrameAtRef.current = Date.now();
      },
      onRtt: (ms) => setRttMs(ms),
    })
  );

  const staleCan = useMemo(() => {
    if (!Number.isFinite(frameAgeMs)) {
      return true;
    }
    return frameAgeMs > 1500;
  }, [frameAgeMs]);

  const flushQueuedGps = async () => {
    if (flushingRef.current || !wsClientRef.current.isOpen()) {
      return;
    }
    flushingRef.current = true;
    try {
      const { remaining } = await queueRef.current.flush((payload) =>
        wsClientRef.current.sendJson(payload)
      );
      setQueueDepth(remaining);
    } finally {
      flushingRef.current = false;
    }
  };

  const buildMeta = () => ({
    bgState: appStateRef.current === "active" ? "foreground" : "background",
    os: inferOsName(),
    appVersion: APP_VERSION,
    device: Platform.constants?.Model || Platform.constants?.Brand || "unknown",
  });

  const sendGpsUplinkWithQueue = async (fix) => {
    const payload = createGpsPayload(fix, buildMeta());
    const sent = wsClientRef.current.sendJson(payload);
    if (!sent) {
      const depth = await queueRef.current.enqueue(stampQueued(payload));
      setQueueDepth(depth);
      return;
    }
    await flushQueuedGps();
  };

  const startGpsWatch = (useIosBackgroundMode, useAndroidBackgroundMode) => {
    gpsClientRef.current.start(
      (fix) => {
        setGpsFix(fix);
        setGpsState("gps-ok");
        void sendGpsUplinkWithQueue(fix);
      },
      (err) => {
        setGpsState(describeGpsError(err));
      },
      {
        iosBackgroundMode: useIosBackgroundMode,
        androidBackgroundMode: useAndroidBackgroundMode,
      }
    );
    setGpsRunning(true);
  };

  useEffect(() => {
    let mounted = true;
    void queueRef.current.init().then((depth) => {
      if (mounted) {
        setQueueDepth(depth);
      }
    });

    return () => {
      mounted = false;
    };
  }, []);

  useEffect(() => {
    const appStateSub = AppState.addEventListener("change", (nextState) => {
      appStateRef.current = nextState;
      setBgState(nextState);
    });

    const timer = setInterval(() => {
      const last = lastFrameAtRef.current;
      if (!last) {
        setFrameAgeMs(null);
        return;
      }
      setFrameAgeMs(Date.now() - last);
    }, 100);

    return () => {
      clearInterval(timer);
      appStateSub.remove();
      wsClientRef.current.disconnect();
      gpsClientRef.current.stop();
    };
  }, []);

  useEffect(() => {
    if (connectionState === "connected") {
      void flushQueuedGps();
    }
  }, [connectionState]);

  const connect = () => {
    const wsUrl = toWsUrl(serverBaseUrl);
    wsClientRef.current.connect(wsUrl);
  };

  const disconnect = () => {
    wsClientRef.current.disconnect();
  };

  const startGps = async () => {
    const granted = await requestLocationPermission({
      androidBackgroundMode: androidBgPilot,
    });
    if (!granted) {
      setGpsState("gps-denied");
      return;
    }
    startGpsWatch(iosBgPilot, androidBgPilot);
  };

  const stopGps = () => {
    gpsClientRef.current.stop();
    setGpsRunning(false);
    setGpsState("gps-stopped");
  };

  const toggleIosBgPilot = () => {
    const next = !iosBgPilot;
    setIosBgPilot(next);
    if (gpsRunning) {
      gpsClientRef.current.stop();
      startGpsWatch(next, androidBgPilot);
    }
  };

  const toggleAndroidBgPilot = () => {
    const next = !androidBgPilot;
    setAndroidBgPilot(next);
    if (gpsRunning) {
      gpsClientRef.current.stop();
      startGpsWatch(iosBgPilot, next);
    }
  };

  const sendMark = () => {
    wsClientRef.current.sendJson(createMarkPayload(markNote));
  };

  return (
    <SafeAreaView style={styles.safe}>
      <ScrollView contentContainerStyle={styles.container}>
        <Text style={styles.title}>Telemetry Mobile (Bare RN)</Text>
        <Text style={styles.caption}>iOS-first background telemetry pilot</Text>

        <View style={styles.card}>
          <Text style={styles.cardTitle}>Connection</Text>
          <TextInput
            autoCapitalize="none"
            autoCorrect={false}
            style={styles.input}
            value={serverBaseUrl}
            onChangeText={(text) => setServerBaseUrl(normalizeBaseUrl(text))}
            placeholder="http://192.168.x.x:8080"
            placeholderTextColor="#6c7a89"
          />
          <View style={styles.row}>
            <Pressable style={styles.button} onPress={connect}>
              <Text style={styles.buttonText}>Connect</Text>
            </Pressable>
            <Pressable style={styles.buttonMuted} onPress={disconnect}>
              <Text style={styles.buttonText}>Disconnect</Text>
            </Pressable>
          </View>
          <Text style={styles.kv}>state: {connectionState}</Text>
          <Text style={styles.kv}>seq: {seq ?? "-"}</Text>
          <Text style={styles.kv}>drop: {drop}</Text>
          <Text style={styles.kv}>
            frameAge: {Number.isFinite(frameAgeMs) ? `${Math.round(frameAgeMs)}ms` : "-"}
          </Text>
          <Text style={styles.kv}>rtt: {Number.isFinite(rttMs) ? `${Math.round(rttMs)}ms` : "-"}</Text>
          <Text style={styles.kv}>queuedGps: {queueDepth}</Text>
          <Text style={[styles.kv, staleCan ? styles.warn : null]}>
            can: {staleCan ? "stale" : "fresh"}
          </Text>
        </View>

        <View style={styles.card}>
          <Text style={styles.cardTitle}>GPS Uplink</Text>
          <View style={styles.row}>
            <Pressable style={styles.button} onPress={startGps}>
              <Text style={styles.buttonText}>Start GPS</Text>
            </Pressable>
            <Pressable style={styles.buttonMuted} onPress={stopGps}>
              <Text style={styles.buttonText}>Stop GPS</Text>
            </Pressable>
          </View>
          {Platform.OS === "ios" ? (
            <View style={styles.row}>
              <Pressable style={styles.buttonMuted} onPress={toggleIosBgPilot}>
                <Text style={styles.buttonText}>
                  iOS BG Pilot: {iosBgPilot ? "ON(significant)" : "OFF(continuous)"}
                </Text>
              </Pressable>
            </View>
          ) : null}
          {Platform.OS === "android" ? (
            <View style={styles.row}>
              <Pressable style={styles.buttonMuted} onPress={toggleAndroidBgPilot}>
                <Text style={styles.buttonText}>
                  Android BG Pilot: {androidBgPilot ? "ON(request bg permission)" : "OFF"}
                </Text>
              </Pressable>
            </View>
          ) : null}
          <Text style={styles.kv}>gpsState: {gpsState}</Text>
          <Text style={styles.kv}>gpsRunning: {gpsRunning ? "yes" : "no"}</Text>
          <Text style={styles.kv}>lat: {formatNumber(gpsFix?.lat, 6)}</Text>
          <Text style={styles.kv}>lon: {formatNumber(gpsFix?.lon, 6)}</Text>
          <Text style={styles.kv}>spd(m/s): {formatNumber(gpsFix?.spd, 2)}</Text>
          <Text style={styles.kv}>hdg: {formatNumber(gpsFix?.hdg, 1)}</Text>
          <Text style={styles.kv}>acc(m): {formatNumber(gpsFix?.acc, 1)}</Text>
          <Text style={styles.kv}>bgState: {bgState === "active" ? "foreground" : "background"}</Text>
        </View>

        <View style={styles.card}>
          <Text style={styles.cardTitle}>MARK</Text>
          <TextInput
            autoCapitalize="none"
            autoCorrect={false}
            style={styles.input}
            value={markNote}
            onChangeText={setMarkNote}
            placeholder="optional note"
            placeholderTextColor="#6c7a89"
          />
          <Pressable style={styles.button} onPress={sendMark}>
            <Text style={styles.buttonText}>Send MARK</Text>
          </Pressable>
        </View>

        <View style={styles.card}>
          <Text style={styles.cardTitle}>CAN Snapshot</Text>
          <Text style={styles.kv}>ws_fl: {formatNumber(sig?.ws_fl, 2)}</Text>
          <Text style={styles.kv}>ws_fr: {formatNumber(sig?.ws_fr, 2)}</Text>
          <Text style={styles.kv}>ws_rl: {formatNumber(sig?.ws_rl, 2)}</Text>
          <Text style={styles.kv}>ws_rr: {formatNumber(sig?.ws_rr, 2)}</Text>
          <Text style={styles.kv}>yaw: {formatNumber(sig?.yaw, 2)}</Text>
          <Text style={styles.kv}>ay: {formatNumber(sig?.ay, 2)}</Text>
        </View>
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  safe: {
    flex: 1,
    backgroundColor: "#0b1016",
  },
  container: {
    padding: 16,
    gap: 12,
  },
  title: {
    color: "#f6fbff",
    fontSize: 24,
    fontWeight: "700",
  },
  caption: {
    color: "#9bb0c5",
    marginBottom: 4,
  },
  card: {
    backgroundColor: "#141d27",
    borderRadius: 12,
    borderWidth: 1,
    borderColor: "#243346",
    padding: 12,
    gap: 6,
  },
  cardTitle: {
    color: "#f6fbff",
    fontSize: 17,
    fontWeight: "600",
    marginBottom: 4,
  },
  kv: {
    color: "#d8e3ee",
    fontSize: 14,
  },
  warn: {
    color: "#ffb86b",
    fontWeight: "600",
  },
  input: {
    borderWidth: 1,
    borderColor: "#33495f",
    borderRadius: 8,
    color: "#f6fbff",
    paddingHorizontal: 10,
    paddingVertical: 8,
    fontSize: 14,
  },
  row: {
    flexDirection: "row",
    gap: 8,
    marginTop: 4,
    marginBottom: 4,
  },
  button: {
    backgroundColor: "#2f81f7",
    paddingHorizontal: 12,
    paddingVertical: 10,
    borderRadius: 8,
  },
  buttonMuted: {
    backgroundColor: "#314354",
    paddingHorizontal: 12,
    paddingVertical: 10,
    borderRadius: 8,
  },
  buttonText: {
    color: "#ffffff",
    fontWeight: "600",
    fontSize: 14,
  },
});
