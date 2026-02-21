import Geolocation from "@react-native-community/geolocation";
import {
  NativeEventEmitter,
  NativeModules,
  PermissionsAndroid,
  Platform,
} from "react-native";
import {
  ANDROID_BG_BRIDGE_MODULE,
  buildGpsOptions,
  IOS_BG_BRIDGE_MODULE,
} from "../config";

// Native bridge modules are optional and only present after native setup scripts
// (`ios:setup-bg`, `android:setup-bg`) and project-level registration.
const _iosNativeBridge = NativeModules[IOS_BG_BRIDGE_MODULE] ?? null;
const _androidNativeBridge = NativeModules[ANDROID_BG_BRIDGE_MODULE] ?? null;

export async function requestLocationPermission(options = {}) {
  const { androidBackgroundMode = false } = options;

  if (Platform.OS === "ios") {
    if (typeof Geolocation.requestAuthorization === "function") {
      const result = await Geolocation.requestAuthorization("always");
      return result === "granted";
    }
    return true;
  }

  if (Platform.OS !== "android") {
    return true;
  }

  const fine = await PermissionsAndroid.request(
    PermissionsAndroid.PERMISSIONS.ACCESS_FINE_LOCATION
  );

  if (fine !== PermissionsAndroid.RESULTS.GRANTED) {
    return false;
  }

  const needsBackgroundPermission =
    androidBackgroundMode &&
    Number(Platform.Version) >= 29 &&
    Boolean(PermissionsAndroid.PERMISSIONS.ACCESS_BACKGROUND_LOCATION);

  if (!needsBackgroundPermission) {
    return true;
  }

  const background = await PermissionsAndroid.request(
    PermissionsAndroid.PERMISSIONS.ACCESS_BACKGROUND_LOCATION
  );

  return background === PermissionsAndroid.RESULTS.GRANTED;
}

export class GpsClient {
  constructor() {
    this.watchId = null;
    this._usingBridge = false;
    this._bridgeType = null;
    this._bgSubscriptions = [];
  }

  start(onFix, onError, options = {}) {
    if (this.watchId != null || this._usingBridge) {
      return;
    }

    const { iosBackgroundMode = false, androidBackgroundMode = false } = options;

    if (Platform.OS === "ios" && iosBackgroundMode && _iosNativeBridge) {
      this._startViaIosBridge(onFix, onError, options);
      return;
    }

    if (Platform.OS === "android" && androidBackgroundMode && _androidNativeBridge) {
      this._startViaAndroidBridge(onFix, onError, options);
      return;
    }

    const watchOptions = buildGpsOptions(options);

    this.watchId = Geolocation.watchPosition(
      (position) => {
        const coords = position.coords;
        onFix?.({
          lat: coords.latitude,
          lon: coords.longitude,
          spd: Number.isFinite(coords.speed) ? coords.speed : 0,
          hdg: Number.isFinite(coords.heading) ? coords.heading : null,
          acc: Number.isFinite(coords.accuracy) ? coords.accuracy : null,
          alt: Number.isFinite(coords.altitude) ? coords.altitude : null,
        });
      },
      (err) => {
        onError?.(err);
      },
      watchOptions
    );
  }

  /** @private */
  _startViaIosBridge(onFix, onError, options = {}) {
    const emitter = new NativeEventEmitter(_iosNativeBridge);
    const useSignificantChanges =
      options.useSignificantChanges ??
      buildGpsOptions(options).useSignificantChanges ??
      false;

    const locationSub = emitter.addListener("locationUpdate", (data) => {
      const fix = this._normalizeBridgeFix(data);
      if (fix) {
        onFix?.(fix);
      }
    });

    const errorSub = emitter.addListener("locationError", (err) => {
      onError?.(err);
    });

    this._bgSubscriptions = [locationSub, errorSub];
    this._usingBridge = true;
    this._bridgeType = "ios";

    _iosNativeBridge.startBackgroundLocation({ useSignificantChanges });
  }

  /** @private */
  _startViaAndroidBridge(onFix, onError, options = {}) {
    const emitter = new NativeEventEmitter(_androidNativeBridge);
    const locationSub = emitter.addListener("locationUpdate", (data) => {
      const fix = this._normalizeBridgeFix(data);
      if (fix) {
        onFix?.(fix);
      }
    });
    const errorSub = emitter.addListener("locationError", (err) => {
      onError?.(err);
    });

    this._bgSubscriptions = [locationSub, errorSub];
    this._usingBridge = true;
    this._bridgeType = "android";

    _androidNativeBridge.startBackgroundLocation({
      intervalMs: options.intervalMs ?? 1000,
      distanceMeters: options.distanceMeters ?? 5,
    });
  }

  /** @private */
  _normalizeBridgeFix(data = {}) {
    const latitude = Number(data.latitude);
    const longitude = Number(data.longitude);
    const speed = Number(data.speed);
    const heading = Number(data.heading);
    const accuracy = Number(data.accuracy);
    const altitude = Number(data.altitude);

    if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) {
      return null;
    }

    return {
      lat: latitude,
      lon: longitude,
      spd: Number.isFinite(speed) && speed >= 0 ? speed : 0,
      hdg: Number.isFinite(heading) && heading >= 0 ? heading : null,
      acc: Number.isFinite(accuracy) ? accuracy : null,
      alt: Number.isFinite(altitude) ? altitude : null,
    };
  }

  stop() {
    if (this._usingBridge) {
      if (this._bridgeType === "ios") {
        _iosNativeBridge?.stopBackgroundLocation();
      } else if (this._bridgeType === "android") {
        _androidNativeBridge?.stopBackgroundLocation();
      }
      this._bgSubscriptions.forEach((s) => s.remove());
      this._bgSubscriptions = [];
      this._usingBridge = false;
      this._bridgeType = null;
      return;
    }

    if (this.watchId != null) {
      Geolocation.clearWatch(this.watchId);
      this.watchId = null;
    }
  }
}
