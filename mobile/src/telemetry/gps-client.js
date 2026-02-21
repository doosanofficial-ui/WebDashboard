import Geolocation from "@react-native-community/geolocation";
import { PermissionsAndroid, Platform } from "react-native";
import { buildGpsOptions } from "../config";

export async function requestLocationPermission() {
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

  return fine === PermissionsAndroid.RESULTS.GRANTED;
}

export class GpsClient {
  constructor() {
    this.watchId = null;
  }

  start(onFix, onError, options = {}) {
    if (this.watchId != null) {
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

  stop() {
    if (this.watchId != null) {
      Geolocation.clearWatch(this.watchId);
      this.watchId = null;
    }
  }
}
