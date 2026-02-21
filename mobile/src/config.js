import { Platform } from "react-native";

export const APP_VERSION = "rn-bare-v0.1";
export const IOS_BG_BRIDGE_MODULE = "RNIosLocationBridge";
export const ANDROID_BG_BRIDGE_MODULE = "RNAndroidLocationBridge";
export const DEFAULT_SERVER_BASE_URL = "http://127.0.0.1:8080";
export const GPS_OPTIONS_BASE = {
  enableHighAccuracy: true,
  timeout: 10000,
  maximumAge: 0,
  distanceFilter: 0,
};
export const GPS_OPTIONS_IOS_SIGNIFICANT = {
  enableHighAccuracy: false,
  timeout: 120000,
  maximumAge: 15000,
  distanceFilter: 50,
  useSignificantChanges: true,
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

export function buildGpsOptions({ iosBackgroundMode = false } = {}) {
  if (Platform.OS === "ios" && iosBackgroundMode) {
    return { ...GPS_OPTIONS_IOS_SIGNIFICANT };
  }
  return { ...GPS_OPTIONS_BASE };
}
