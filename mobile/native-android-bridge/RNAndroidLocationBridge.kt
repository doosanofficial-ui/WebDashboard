package __APP_PACKAGE__

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.Looper
import androidx.core.content.ContextCompat
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.WritableMap
import com.facebook.react.modules.core.DeviceEventManagerModule

/**
 * Android native bridge skeleton for background location updates.
 *
 * Integration notes:
 * - Register this module in a ReactPackage in your android project.
 * - Ensure manifest permissions + foreground service declaration are applied.
 */
class RNAndroidLocationBridge(
    private val reactContext: ReactApplicationContext
) : ReactContextBaseJavaModule(reactContext) {

    private val locationManager =
        reactContext.getSystemService(LocationManager::class.java)

    private var listener: LocationListener? = null
    private var active = false

    override fun getName(): String = "RNAndroidLocationBridge"

    @ReactMethod
    fun isBackgroundActive(promise: Promise) {
        promise.resolve(active)
    }

    @ReactMethod
    fun startBackgroundLocation(options: ReadableMap?, promise: Promise) {
        if (active) {
            promise.resolve(true)
            return
        }

        if (!hasLocationPermission()) {
            emitError("location permission not granted")
            promise.resolve(false)
            return
        }

        if (locationManager == null) {
            emitError("LocationManager unavailable")
            promise.resolve(false)
            return
        }

        startForegroundService()
        beginLocationUpdates(options)
        active = true
        promise.resolve(true)
    }

    @ReactMethod
    fun stopBackgroundLocation(promise: Promise) {
        stopLocationUpdates()
        stopForegroundService()
        active = false
        promise.resolve(true)
    }

    private fun hasLocationPermission(): Boolean {
        val fine = ContextCompat.checkSelfPermission(
            reactContext,
            Manifest.permission.ACCESS_FINE_LOCATION
        )
        val bg = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ContextCompat.checkSelfPermission(
                reactContext,
                Manifest.permission.ACCESS_BACKGROUND_LOCATION
            )
        } else {
            PackageManager.PERMISSION_GRANTED
        }
        return fine == PackageManager.PERMISSION_GRANTED && bg == PackageManager.PERMISSION_GRANTED
    }

    private fun startForegroundService() {
        val intent = Intent(reactContext, LocationForegroundService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            reactContext.startForegroundService(intent)
        } else {
            reactContext.startService(intent)
        }
    }

    private fun stopForegroundService() {
        val intent = Intent(reactContext, LocationForegroundService::class.java)
        reactContext.stopService(intent)
    }

    private fun beginLocationUpdates(options: ReadableMap?) {
        val intervalMs = options?.let { if (it.hasKey("intervalMs")) it.getDouble("intervalMs").toLong() else 1000L } ?: 1000L
        val distanceMeters = options?.let { if (it.hasKey("distanceMeters")) it.getDouble("distanceMeters").toFloat() else 5f } ?: 5f

        val locationListener = object : LocationListener {
            override fun onLocationChanged(location: Location) {
                emitLocation(location)
            }

            override fun onProviderDisabled(provider: String) {
                emitError("provider disabled: $provider")
            }

            override fun onProviderEnabled(provider: String) {
                // no-op
            }

            @Deprecated("Deprecated in Java")
            override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {
                // no-op (legacy callback)
            }
        }

        listener = locationListener
        try {
            locationManager?.requestLocationUpdates(
                LocationManager.GPS_PROVIDER,
                intervalMs,
                distanceMeters,
                locationListener,
                Looper.getMainLooper()
            )
        } catch (e: Throwable) {
            emitError("failed to request location updates: ${e.message}")
        }
    }

    private fun stopLocationUpdates() {
        val locationListener = listener ?: return
        try {
            locationManager?.removeUpdates(locationListener)
        } catch (_: Throwable) {
            // ignore cleanup failures
        }
        listener = null
    }

    private fun emitLocation(location: Location) {
        val map = Arguments.createMap().apply {
            putDouble("latitude", location.latitude)
            putDouble("longitude", location.longitude)
            putDouble("speed", location.speed.toDouble())
            putDouble("heading", location.bearing.toDouble())
            putDouble("accuracy", location.accuracy.toDouble())
            if (location.hasAltitude()) {
                putDouble("altitude", location.altitude)
            }
        }
        emitEvent("locationUpdate", map)
    }

    private fun emitError(message: String) {
        val map = Arguments.createMap().apply {
            putString("code", "android-location")
            putString("message", message)
        }
        emitEvent("locationError", map)
    }

    private fun emitEvent(eventName: String, payload: WritableMap) {
        reactContext
            .getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
            .emit(eventName, payload)
    }
}
