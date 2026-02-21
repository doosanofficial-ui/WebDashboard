import Geolocation from "@react-native-community/geolocation";
import {
  NativeEventEmitter,
  NativeModules,
  PermissionsAndroid,
  Platform,
} from "react-native";
import { buildGpsOptions, IOS_BG_BRIDGE_MODULE } from "../config";

// Native bridge module – present only after `npm run ios:setup-bg` and Xcode
// project linking.  Gracefully absent on Android and in bare JS environments.
const _nativeBridge = NativeModules[IOS_BG_BRIDGE_MODULE] ?? null;

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
    this._bgSubscriptions = [];
  }

  start(onFix, onError, options = {}) {
    if (this.watchId != null || this._usingBridge) {
      return;
    }

    const { iosBackgroundMode = false } = options;

    if (Platform.OS === "ios" && iosBackgroundMode && _nativeBridge) {
      this._startViaBridge(onFix, onError, options);
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
  _startViaBridge(onFix, onError, options = {}) {
    const emitter = new NativeEventEmitter(_nativeBridge);
    const useSignificantChanges =
      options.useSignificantChanges ??
      buildGpsOptions(options).useSignificantChanges ??
      false;

    const locationSub = emitter.addListener("locationUpdate", (data) => {
      onFix?.({
        lat: data.latitude,
        lon: data.longitude,
        spd: data.speed >= 0 ? data.speed : 0,
        hdg: data.heading >= 0 ? data.heading : null,
        acc: Number.isFinite(data.accuracy) ? data.accuracy : null,
        alt: Number.isFinite(data.altitude) ? data.altitude : null,
      });
    });

    const errorSub = emitter.addListener("locationError", (err) => {
      onError?.(err);
    });

    this._bgSubscriptions = [locationSub, errorSub];
    this._usingBridge = true;

    _nativeBridge.startBackgroundLocation({ useSignificantChanges });
  }

  stop() {
    if (this._usingBridge) {
      _nativeBridge?.stopBackgroundLocation();
      this._bgSubscriptions.forEach((s) => s.remove());
      this._bgSubscriptions = [];
      this._usingBridge = false;
      return;
    }

    if (this.watchId != null) {
      Geolocation.clearWatch(this.watchId);
      this.watchId = null;
    }
  }
}
