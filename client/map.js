function destinationPoint(lat, lon, headingDeg, distanceM) {
  const R = 6378137;
  const heading = (headingDeg * Math.PI) / 180;
  const lat1 = (lat * Math.PI) / 180;
  const lon1 = (lon * Math.PI) / 180;
  const dByR = distanceM / R;

  const lat2 = Math.asin(
    Math.sin(lat1) * Math.cos(dByR) +
      Math.cos(lat1) * Math.sin(dByR) * Math.cos(heading)
  );

  const lon2 =
    lon1 +
    Math.atan2(
      Math.sin(heading) * Math.sin(dByR) * Math.cos(lat1),
      Math.cos(dByR) - Math.sin(lat1) * Math.sin(lat2)
    );

  return [(lat2 * 180) / Math.PI, (lon2 * 180) / Math.PI];
}

function hasValidLatLon(fix) {
  return (
    fix &&
    Number.isFinite(fix.lat) &&
    Number.isFinite(fix.lon) &&
    Math.abs(fix.lat) <= 90 &&
    Math.abs(fix.lon) <= 180
  );
}

export class GpsMap {
  constructor({
    container,
    hintEl,
    defaultCenter = [37.5665, 126.978],
    defaultZoom = 16,
    trailLimit = 1200,
  }) {
    this.container = container;
    this.hintEl = hintEl;
    this.defaultCenter = defaultCenter;
    this.defaultZoom = defaultZoom;
    this.trailLimit = trailLimit;

    this.map = null;
    this.trail = [];
    this.positionMarker = null;
    this.accuracyCircle = null;
    this.headingLine = null;
    this.trailLine = null;
    this.lastTrailPoint = null;
  }

  init() {
    const L = window.L;

    if (!this.container || !L) {
      this._setHint("지도 라이브러리를 불러오지 못했습니다. 네트워크를 확인하세요.", true);
      return;
    }

    this.map = L.map(this.container, {
      zoomControl: true,
      attributionControl: true,
    }).setView(this.defaultCenter, this.defaultZoom);

    L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
      maxZoom: 19,
      attribution: "&copy; OpenStreetMap contributors",
    }).addTo(this.map);

    this.positionMarker = L.circleMarker(this.defaultCenter, {
      radius: 7,
      color: "#00d4a8",
      fillColor: "#00d4a8",
      fillOpacity: 0.85,
      weight: 2,
    }).addTo(this.map);

    this.accuracyCircle = L.circle(this.defaultCenter, {
      radius: 5,
      color: "#2ec4ff",
      fillColor: "#2ec4ff",
      fillOpacity: 0.12,
      weight: 1,
    }).addTo(this.map);

    this.headingLine = L.polyline([this.defaultCenter, this.defaultCenter], {
      color: "#ffb347",
      weight: 3,
      opacity: 0.9,
    }).addTo(this.map);

    this.trailLine = L.polyline([], {
      color: "#7cb8ff",
      weight: 3,
      opacity: 0.8,
    }).addTo(this.map);

    this._setHint("GPS 수신을 시작하면 지도에 위치가 표시됩니다.", false);

    setTimeout(() => {
      if (this.map) {
        this.map.invalidateSize();
      }
    }, 120);
  }

  updateFromFix(fix, stale) {
    if (!this.map || !hasValidLatLon(fix)) {
      return;
    }

    const latlng = [fix.lat, fix.lon];
    this.positionMarker.setLatLng(latlng);

    const accuracy = Number.isFinite(fix.acc) ? Math.max(3, fix.acc) : 5;
    this.accuracyCircle.setLatLng(latlng).setRadius(accuracy);

    if (Number.isFinite(fix.hdg)) {
      const headingLenM = 20;
      const end = destinationPoint(fix.lat, fix.lon, fix.hdg, headingLenM);
      this.headingLine.setLatLngs([latlng, end]);
      this.headingLine.setStyle({ opacity: stale ? 0.4 : 0.9 });
    } else {
      this.headingLine.setLatLngs([latlng, latlng]);
      this.headingLine.setStyle({ opacity: 0.2 });
    }

    this._pushTrail(latlng);
    this.trailLine.setLatLngs(this.trail);

    this.positionMarker.setStyle({
      color: stale ? "#ffb347" : "#00d4a8",
      fillColor: stale ? "#ffb347" : "#00d4a8",
    });

    if (this.trail.length < 3) {
      this.map.setView(latlng, this.defaultZoom, { animate: false });
    } else {
      this.map.panTo(latlng, { animate: false });
    }

    this._setHint(stale ? "GPS 신호 지연(stale)" : "GPS 추적 중", false);
  }

  addMark(fix, note = "") {
    if (!this.map || !hasValidLatLon(fix) || !window.L) {
      return;
    }

    const label = note.trim() ? `MARK: ${note}` : "MARK";
    window.L.marker([fix.lat, fix.lon]).addTo(this.map).bindPopup(label);
  }

  resize() {
    if (!this.map) {
      return;
    }
    this.map.invalidateSize();
  }

  _pushTrail(latlng) {
    const [lat, lon] = latlng;
    if (this.lastTrailPoint) {
      const dLat = Math.abs(lat - this.lastTrailPoint[0]);
      const dLon = Math.abs(lon - this.lastTrailPoint[1]);
      if (dLat < 0.000002 && dLon < 0.000002) {
        return;
      }
    }

    this.trail.push(latlng);
    this.lastTrailPoint = latlng;

    if (this.trail.length > this.trailLimit) {
      this.trail.shift();
    }
  }

  _setHint(text, isError) {
    if (!this.hintEl) {
      return;
    }

    this.hintEl.textContent = text;
    this.hintEl.classList.toggle("error", Boolean(isError));
  }
}
