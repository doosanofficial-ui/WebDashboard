#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * RNIosLocationBridge
 *
 * Native bridge module that manages a dedicated CLLocationManager for
 * continuous background location updates on iOS.  The JS layer uses this
 * module instead of the generic Geolocation watcher when iosBackgroundMode
 * is enabled so that `allowsBackgroundLocationUpdates` and
 * `pausesLocationUpdatesAutomatically` are set correctly.
 *
 * Emitted events (NativeEventEmitter):
 *   "locationUpdate"  – { latitude, longitude, speed, heading, accuracy, altitude }
 *   "bgStateChange"   – { active: bool }
 *   "locationError"   – { code: number, message: string }
 */
@interface RNIosLocationBridge : RCTEventEmitter <RCTBridgeModule, CLLocationManagerDelegate>

@end

NS_ASSUME_NONNULL_END
