function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value));
}

function normalizeHeading(deg) {
  if (!Number.isFinite(deg)) {
    return null;
  }
  return ((deg % 360) + 360) % 360;
}

function lerp(a, b, alpha) {
  return a + (b - a) * alpha;
}

function lerpHeading(a, b, alpha) {
  if (!Number.isFinite(a) || !Number.isFinite(b)) {
    return Number.isFinite(b) ? b : a;
  }
  const delta = ((b - a + 540) % 360) - 180;
  return normalizeHeading(a + delta * alpha);
}

function smoothFix(current, target, alpha) {
  if (!current) {
    return { ...target };
  }

  return {
    ...target,
    lat: lerp(current.lat, target.lat, alpha),
    lon: lerp(current.lon, target.lon, alpha),
    spd: lerp(current.spd ?? 0, target.spd ?? 0, alpha),
    acc: lerp(current.acc ?? target.acc ?? 0, target.acc ?? 0, alpha),
    alt:
      Number.isFinite(current.alt) && Number.isFinite(target.alt)
        ? lerp(current.alt, target.alt, alpha)
        : target.alt,
    hdg:
      current.hdg == null || target.hdg == null
        ? target.hdg
        : lerpHeading(current.hdg, target.hdg, alpha),
  };
}

function lerpFix(from, to, alpha) {
  return {
    ...to,
    lat: lerp(from.lat, to.lat, alpha),
    lon: lerp(from.lon, to.lon, alpha),
    spd: lerp(from.spd ?? 0, to.spd ?? 0, alpha),
    acc: lerp(from.acc ?? to.acc ?? 0, to.acc ?? 0, alpha),
    alt:
      Number.isFinite(from.alt) && Number.isFinite(to.alt)
        ? lerp(from.alt, to.alt, alpha)
        : to.alt,
    hdg:
      from.hdg == null || to.hdg == null
        ? to.hdg
        : lerpHeading(from.hdg, to.hdg, alpha),
  };
}

function isValidLatLon(lat, lon) {
  return (
    Number.isFinite(lat) &&
    Number.isFinite(lon) &&
    Math.abs(lat) <= 90 &&
    Math.abs(lon) <= 180
  );
}

export class GpsTracker {
  constructor({ mode = "hold", emaAlpha = 0.25, staleMs = 4000 } = {}) {
    this.mode = mode;
    this.emaAlpha = emaAlpha;
    this.staleMs = staleMs;

    this.watchId = null;
    this.prevFix = null;
    this.lastFix = null;
    this.displayFix = null;
    this.transition = null;
  }

  setMode(mode) {
    this.mode = mode;
  }

  start(onFix, onError) {
    if (!navigator.geolocation) {
      throw new Error("Geolocation not supported");
    }
    if (this.watchId != null) {
      return;
    }

    this.watchId = navigator.geolocation.watchPosition(
      (position) => {
        const coords = position.coords;
        if (!isValidLatLon(coords.latitude, coords.longitude)) {
          return;
        }
        const fix = {
          t: (position.timestamp || Date.now()) / 1000,
          recvMs: performance.now(),
          lat: coords.latitude,
          lon: coords.longitude,
          spd: Number.isFinite(coords.speed) ? coords.speed : 0,
          hdg: normalizeHeading(coords.heading),
          acc: Number.isFinite(coords.accuracy) ? coords.accuracy : null,
          alt: Number.isFinite(coords.altitude) ? coords.altitude : null,
        };

        this.prevFix = this.lastFix;
        this.lastFix = fix;

        if (this.prevFix) {
          const rawDuration = (fix.t - this.prevFix.t) * 1000;
          const durationMs = Number.isFinite(rawDuration)
            ? clamp(rawDuration, 250, 2000)
            : 500;

          this.transition = {
            from: this.prevFix,
            to: fix,
            startMs: performance.now(),
            durationMs,
          };
        }

        if (!this.displayFix) {
          this.displayFix = { ...fix };
        }

        if (onFix) {
          onFix(fix);
        }
      },
      (err) => {
        if (onError) {
          onError(err);
        }
      },
      {
        enableHighAccuracy: true,
        maximumAge: 0,
        timeout: 10000,
      }
    );
  }

  stop() {
    if (this.watchId != null && navigator.geolocation) {
      navigator.geolocation.clearWatch(this.watchId);
    }
    this.watchId = null;
  }

  tick(nowMs = performance.now()) {
    if (!this.lastFix) {
      return { fix: null, stale: true, ageMs: null };
    }

    let target = this.lastFix;
    if (this.mode === "lerp" && this.transition) {
      const alpha = clamp((nowMs - this.transition.startMs) / this.transition.durationMs, 0, 1);
      target = lerpFix(this.transition.from, this.transition.to, alpha);
      if (alpha >= 1) {
        this.transition = null;
      }
    }

    this.displayFix = smoothFix(this.displayFix, target, this.emaAlpha);

    const ageMs = nowMs - this.lastFix.recvMs;
    return {
      fix: this.displayFix,
      stale: ageMs > this.staleMs,
      ageMs,
    };
  }
}
