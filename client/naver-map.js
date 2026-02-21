function toRad(deg) {
  return (deg * Math.PI) / 180;
}

function toDeg(rad) {
  return (rad * 180) / Math.PI;
}

function destinationPoint(lat, lon, headingDeg, distanceM) {
  const earthRadius = 6378137;
  const heading = toRad(headingDeg);
  const lat1 = toRad(lat);
  const lon1 = toRad(lon);
  const dByR = distanceM / earthRadius;

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

  return { lat: toDeg(lat2), lon: toDeg(lon2) };
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

function loadNaverScript(clientId) {
  return new Promise((resolve, reject) => {
    if (window.naver?.maps) {
      resolve();
      return;
    }

    const existing = document.querySelector("script[data-naver-maps='1']");
    if (existing) {
      existing.addEventListener("load", () => resolve(), { once: true });
      existing.addEventListener("error", () => reject(new Error("Naver Maps script load failed")), {
        once: true,
      });
      return;
    }

    const script = document.createElement("script");
    script.dataset.naverMaps = "1";
    script.src = `https://oapi.map.naver.com/openapi/v3/maps.js?ncpClientId=${encodeURIComponent(
      clientId
    )}&submodules=panorama`;
    script.async = true;
    script.defer = true;
    script.onload = () => resolve();
    script.onerror = () => reject(new Error("Naver Maps script load failed"));
    document.head.appendChild(script);
  });
}

export class NaverMap {
  constructor({ container, hintEl, defaultCenter = [37.5665, 126.978], defaultZoom = 16, trailLimit = 1200 }) {
    this.container = container;
    this.hintEl = hintEl;
    this.defaultCenter = defaultCenter;
    this.defaultZoom = defaultZoom;
    this.trailLimit = trailLimit;

    this.map = null;
    this.positionMarker = null;
    this.accuracyCircle = null;
    this.headingLine = null;
    this.trailLine = null;

    this.trail = [];
    this.lastTrailPoint = null;
  }

  async init(clientId) {
    if (!clientId) {
      this._setHint("NAVER Client ID 미설정. 지도 비활성화.", true);
      return;
    }

    if (!this.container) {
      return;
    }

    try {
      await loadNaverScript(clientId);

      const naver = window.naver;
      if (!naver?.maps) {
        throw new Error("NAVER Maps 객체를 찾을 수 없음");
      }

      const center = new naver.maps.LatLng(this.defaultCenter[0], this.defaultCenter[1]);
      this.map = new naver.maps.Map(this.container, {
        center,
        zoom: this.defaultZoom,
        mapTypeControl: false,
        scaleControl: false,
      });

      this.positionMarker = new naver.maps.Marker({
        map: this.map,
        position: center,
      });

      this.accuracyCircle = new naver.maps.Circle({
        map: this.map,
        center,
        radius: 8,
        strokeColor: "#2ec4ff",
        strokeWeight: 2,
        strokeOpacity: 0.65,
        fillColor: "#2ec4ff",
        fillOpacity: 0.12,
      });

      this.headingLine = new naver.maps.Polyline({
        map: this.map,
        path: [center, center],
        strokeColor: "#ffb347",
        strokeOpacity: 0.9,
        strokeWeight: 3,
      });

      this.trailLine = new naver.maps.Polyline({
        map: this.map,
        path: [],
        strokeColor: "#7cb8ff",
        strokeOpacity: 0.85,
        strokeWeight: 3,
      });

      this._setHint("NAVER 지도 준비 완료", false);
      setTimeout(() => this.resize(), 120);
    } catch (err) {
      this._setHint(`지도 초기화 실패: ${err.message}`, true);
    }
  }

  updateFromFix(fix, stale) {
    if (!this.map || !hasValidLatLon(fix)) {
      return;
    }

    const naver = window.naver;
    const center = new naver.maps.LatLng(fix.lat, fix.lon);

    this.positionMarker.setPosition(center);

    const accuracy = Number.isFinite(fix.acc) ? Math.max(3, fix.acc) : 5;
    this.accuracyCircle.setCenter(center);
    this.accuracyCircle.setRadius(accuracy);

    if (Number.isFinite(fix.hdg)) {
      const head = destinationPoint(fix.lat, fix.lon, fix.hdg, 22);
      const headLatLng = new naver.maps.LatLng(head.lat, head.lon);
      this.headingLine.setPath([center, headLatLng]);
      this.headingLine.setOptions({ strokeOpacity: stale ? 0.35 : 0.9 });
    } else {
      this.headingLine.setPath([center, center]);
      this.headingLine.setOptions({ strokeOpacity: 0.2 });
    }

    this._pushTrail(fix);
    const trailPath = this.trail.map((p) => new naver.maps.LatLng(p.lat, p.lon));
    this.trailLine.setPath(trailPath);

    if (this.trail.length < 3) {
      this.map.setCenter(center);
      this.map.setZoom(this.defaultZoom);
    } else {
      this.map.panTo(center);
    }

    this._setHint(stale ? "GPS 신호 지연(stale)" : "GPS 추적 중", false);
  }

  addMark(fix, note = "") {
    if (!this.map || !hasValidLatLon(fix) || !window.naver?.maps) {
      return;
    }

    const marker = new window.naver.maps.Marker({
      map: this.map,
      position: new window.naver.maps.LatLng(fix.lat, fix.lon),
      title: note ? `MARK: ${note}` : "MARK",
    });

    if (note) {
      const info = new window.naver.maps.InfoWindow({
        content: `<div style=\"padding:6px 8px;font-size:12px;\">MARK: ${note}</div>`,
        borderWidth: 0,
        disableAnchor: true,
      });
      info.open(this.map, marker);
      setTimeout(() => info.close(), 2500);
    }
  }

  resize() {
    if (!this.map || !window.naver?.maps?.Event) {
      return;
    }
    window.naver.maps.Event.trigger(this.map, "resize");
  }

  _pushTrail(fix) {
    if (this.lastTrailPoint) {
      const dLat = Math.abs(fix.lat - this.lastTrailPoint.lat);
      const dLon = Math.abs(fix.lon - this.lastTrailPoint.lon);
      if (dLat < 0.000002 && dLon < 0.000002) {
        return;
      }
    }

    this.trail.push({ lat: fix.lat, lon: fix.lon });
    this.lastTrailPoint = { lat: fix.lat, lon: fix.lon };

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
