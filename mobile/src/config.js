import { Platform } from "react-native";

export const APP_VERSION = "rn-bare-v0.1";
export const DEFAULT_SERVER_BASE_URL = "http://127.0.0.1:8080";
export const GPS_OPTIONS = {
  enableHighAccuracy: true,
  timeout: 10000,
  maximumAge: 0,
  distanceFilter: 0,
};

export function inferOsName() {
  if (Platform.OS === "ios") {
    return "iOS";
  }
  if (Platform.OS === "android") {
    return "Android";
  }
  return Platform.OS ?? "Unknown";
}

export function normalizeBaseUrl(raw) {
  if (!raw) {
    return DEFAULT_SERVER_BASE_URL;
  }
  let value = raw.trim();
  if (!value) {
    return DEFAULT_SERVER_BASE_URL;
  }

  if (!/^[a-z]+:\/\//i.test(value)) {
    value = `http://${value}`;
  }

  return value.replace(/\/+$/, "");
}

export function toWsUrl(baseUrl) {
  const normalized = normalizeBaseUrl(baseUrl);
  if (normalized.startsWith("ws://") || normalized.startsWith("wss://")) {
    return normalized.endsWith("/ws") ? normalized : `${normalized}/ws`;
  }
  if (normalized.startsWith("https://")) {
    return `wss://${normalized.slice("https://".length)}/ws`;
  }
  return `ws://${normalized.slice("http://".length)}/ws`;
}
