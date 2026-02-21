describe("gps-client requestLocationPermission", () => {
  const loadModule = ({
    os = "android",
    version = 34,
    fineResult = "granted",
    backgroundResult = "granted",
    iosAuth = "granted",
    hasBackgroundPermission = true,
  } = {}) => {
    jest.resetModules();

    const requests = [];

    jest.doMock("react-native", () => {
      const PERMISSIONS = {
        ACCESS_FINE_LOCATION: "android.permission.ACCESS_FINE_LOCATION",
      };
      if (hasBackgroundPermission) {
        PERMISSIONS.ACCESS_BACKGROUND_LOCATION =
          "android.permission.ACCESS_BACKGROUND_LOCATION";
      }

      return {
        Platform: { OS: os, Version: version, constants: {} },
        PermissionsAndroid: {
          PERMISSIONS,
          RESULTS: {
            GRANTED: "granted",
            DENIED: "denied",
          },
          request: jest.fn(async (permission) => {
            requests.push(permission);
            if (permission === PERMISSIONS.ACCESS_BACKGROUND_LOCATION) {
              return backgroundResult;
            }
            return fineResult;
          }),
        },
        NativeModules: {},
        NativeEventEmitter: jest.fn(() => ({
          addListener: jest.fn(() => ({ remove: jest.fn() })),
        })),
      };
    });

    jest.doMock("@react-native-community/geolocation", () => ({
      requestAuthorization: jest.fn(async () => iosAuth),
      watchPosition: jest.fn(),
      clearWatch: jest.fn(),
    }));

    const { requestLocationPermission } = require("../src/telemetry/gps-client");
    return { requestLocationPermission, requests };
  };

  test("returns true on Android when fine permission granted and background mode off", async () => {
    const { requestLocationPermission, requests } = loadModule({
      os: "android",
      fineResult: "granted",
    });

    const ok = await requestLocationPermission({ androidBackgroundMode: false });

    expect(ok).toBe(true);
    expect(requests).toEqual(["android.permission.ACCESS_FINE_LOCATION"]);
  });

  test("requests background permission on Android 10+ when background mode on", async () => {
    const { requestLocationPermission, requests } = loadModule({
      os: "android",
      version: 34,
      fineResult: "granted",
      backgroundResult: "granted",
    });

    const ok = await requestLocationPermission({ androidBackgroundMode: true });

    expect(ok).toBe(true);
    expect(requests).toEqual([
      "android.permission.ACCESS_FINE_LOCATION",
      "android.permission.ACCESS_BACKGROUND_LOCATION",
    ]);
  });

  test("returns false when background permission is denied", async () => {
    const { requestLocationPermission } = loadModule({
      os: "android",
      version: 34,
      fineResult: "granted",
      backgroundResult: "denied",
    });

    const ok = await requestLocationPermission({ androidBackgroundMode: true });
    expect(ok).toBe(false);
  });

  test("returns true on iOS when authorization is granted", async () => {
    const { requestLocationPermission } = loadModule({
      os: "ios",
      iosAuth: "granted",
    });

    const ok = await requestLocationPermission();
    expect(ok).toBe(true);
  });
});
