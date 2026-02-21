#import "RNIosLocationBridge.h"

@implementation RNIosLocationBridge {
  CLLocationManager *_locationManager;
  BOOL _bgActive;
}

RCT_EXPORT_MODULE(RNIosLocationBridge);

// --------------------------------------------------------------------------
// RCTEventEmitter

- (NSArray<NSString *> *)supportedEvents {
  return @[@"locationUpdate", @"bgStateChange", @"locationError"];
}

// Return YES so the emitter starts with zero listeners without warning.
+ (BOOL)requiresMainQueueSetup {
  return YES;
}

// --------------------------------------------------------------------------
// JS-callable methods

/**
 * startBackgroundLocation
 *
 * Starts CLLocationManager in the mode specified by the options dict:
 *   useSignificantChanges (bool, default NO) – use significant-change service
 *                                               instead of standard continuous updates.
 *
 * Requires Info.plist keys:
 *   NSLocationAlwaysAndWhenInUseUsageDescription
 *   UIBackgroundModes containing "location"
 */
RCT_EXPORT_METHOD(startBackgroundLocation:(NSDictionary *)options) {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!self->_locationManager) {
      self->_locationManager = [[CLLocationManager alloc] init];
      self->_locationManager.delegate = self;
    }

    BOOL useSignificant = [options[@"useSignificantChanges"] boolValue];

    if (useSignificant) {
      // Significant-change service – battery-friendly, ~500 m resolution.
      [self->_locationManager stopUpdatingLocation];
      [self->_locationManager startMonitoringSignificantLocationChanges];
    } else {
      // Continuous updates with background entitlement.
      self->_locationManager.desiredAccuracy = kCLLocationAccuracyBest;
      self->_locationManager.distanceFilter = kCLDistanceFilterNone;
      self->_locationManager.allowsBackgroundLocationUpdates = YES;
      self->_locationManager.pausesLocationUpdatesAutomatically = NO;
      [self->_locationManager stopMonitoringSignificantLocationChanges];
      [self->_locationManager startUpdatingLocation];
    }

    self->_bgActive = YES;
    [self sendEventWithName:@"bgStateChange" body:@{@"active": @YES}];
  });
}

/**
 * stopBackgroundLocation
 *
 * Stops both continuous and significant-change location updates and
 * emits a bgStateChange event with active=false.
 */
RCT_EXPORT_METHOD(stopBackgroundLocation) {
  dispatch_async(dispatch_get_main_queue(), ^{
    [self->_locationManager stopUpdatingLocation];
    [self->_locationManager stopMonitoringSignificantLocationChanges];
    self->_bgActive = NO;
    [self sendEventWithName:@"bgStateChange" body:@{@"active": @NO}];
  });
}

/**
 * isBackgroundActive (synchronous accessor used in tests / diagnostics).
 */
RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(isBackgroundActive) {
  return @(_bgActive);
}

// --------------------------------------------------------------------------
// CLLocationManagerDelegate

- (void)locationManager:(CLLocationManager *)manager
     didUpdateLocations:(NSArray<CLLocation *> *)locations {
  CLLocation *loc = locations.lastObject;
  if (!loc) {
    return;
  }

  [self sendEventWithName:@"locationUpdate" body:@{
    @"latitude":  @(loc.coordinate.latitude),
    @"longitude": @(loc.coordinate.longitude),
    @"speed":     @(loc.speed >= 0 ? loc.speed : -1),
    @"heading":   @(loc.course >= 0 ? loc.course : -1),
    @"accuracy":  @(loc.horizontalAccuracy),
    @"altitude":  @(loc.altitude),
  }];
}

- (void)locationManager:(CLLocationManager *)manager
       didFailWithError:(NSError *)error {
  [self sendEventWithName:@"locationError" body:@{
    @"code":    @(error.code),
    @"message": error.localizedDescription ?: @"Unknown location error",
  }];
}

// Called when iOS grants or denies authorization at runtime.
- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
  CLAuthorizationStatus status;
  if (@available(iOS 14.0, *)) {
    status = manager.authorizationStatus;
  } else {
    status = [CLLocationManager authorizationStatus];
  }

  if (status == kCLAuthorizationStatusDenied ||
      status == kCLAuthorizationStatusRestricted) {
    [self sendEventWithName:@"locationError" body:@{
      @"code":    @(1),
      @"message": @"Location permission denied",
    }];
  }
}

@end
