function toRad(deg) {
  return (deg * Math.PI) / 180;
}

function haversineMeters(a, b) {
  const R = 6371000;
  const dLat = toRad(b.lat - a.lat);
  const dLon = toRad(b.lon - a.lon);
  const lat1 = toRad(a.lat);
  const lat2 = toRad(b.lat);

  const h =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) * Math.sin(dLon / 2);
  return 2 * R * Math.asin(Math.sqrt(h));
}

function normalizePan(headingDeg) {
  if (!Number.isFinite(headingDeg)) {
    return 0;
  }
  let pan = headingDeg % 360;
  if (pan > 180) {
    pan -= 360;
  }
  if (pan < -180) {
    pan += 360;
  }
  return pan;
}

function hasLatLon(fix) {
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
    script.src = `https://oapi.map.naver.com/openapi/v3/maps.js?ncpKeyId=${encodeURIComponent(
      clientId
    )}&submodules=panorama`;
    script.async = true;
    script.defer = true;
    script.onload = () => resolve();
    script.onerror = () => reject(new Error("Naver Maps script load failed"));
    document.head.appendChild(script);
  });
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export class NaverRoadview {
  constructor({ container, statusEl, addressEl, reverseGeocodeEndpoint = "/api/naver/reverse-geocode" }) {
    this.container = container;
    this.statusEl = statusEl;
    this.addressEl = addressEl;
    this.reverseGeocodeEndpoint = reverseGeocodeEndpoint;

    this.panorama = null;
    this.ready = false;
    this.lastPanoFix = null;
    this.lastGeocodeFix = null;
    this.lastGeocodeAtMs = 0;
    this.reverseGeocodeDisabled = false;
  }

  async init(clientId) {
    if (!clientId) {
      this._setStatus("NAVER Client ID 미설정. 로드뷰 비활성화.", true);
      return;
    }

    if (!this.container) {
      return;
    }

    try {
      this._setStatus("NAVER 로드뷰 로딩 중...", false);
      await loadNaverScript(clientId);

      const naver = window.naver;
      if (!naver?.maps) {
        throw new Error("NAVER Maps 객체를 찾을 수 없음");
      }

      const defaultPos = new naver.maps.LatLng(37.5665, 126.978);
      const target = this.container.id || this.container;
      let panoError = null;
      for (let i = 0; i < 5; i += 1) {
        try {
          this.panorama = new naver.maps.Panorama(target, {
            position: defaultPos,
            pov: {
              pan: 0,
              tilt: 0,
              fov: 100,
            },
          });
          panoError = null;
          break;
        } catch (err) {
          panoError = err;
          await sleep(200);
        }
      }

      if (!this.panorama) {
        throw panoError || new Error("Panorama 초기화 실패");
      }

      naver.maps.Event.addListener(this.panorama, "pano_status", (status) => {
        if (status === "ERROR") {
          this._setStatus("이 좌표 근처의 로드뷰를 찾지 못했습니다.", true);
          return;
        }
        this._setStatus(`로드뷰 상태: ${status}`, false);
      });

      this.ready = true;
      this._setStatus("로드뷰 준비 완료", false);
    } catch (err) {
      this._setStatus(`로드뷰 초기화 실패: ${err.message}`, true);
    }
  }

  async updateFromFix(fix, stale) {
    if (!this.ready || !this.panorama || !hasLatLon(fix)) {
      return;
    }

    const shouldUpdatePosition =
      (!this.lastPanoFix || haversineMeters(this.lastPanoFix, fix) >= 8) && stale !== true;

    if (shouldUpdatePosition) {
      const latlng = new window.naver.maps.LatLng(fix.lat, fix.lon);
      this.panorama.setPosition(latlng);
      this.lastPanoFix = { lat: fix.lat, lon: fix.lon };
    }

    this.panorama.setPov({
      pan: normalizePan(fix.hdg),
      tilt: -2,
      fov: 100,
    });

    if (!stale) {
      await this._maybeReverseGeocode(fix);
    }
  }

  async _maybeReverseGeocode(fix) {
    if (this.reverseGeocodeDisabled) {
      return;
    }

    const nowMs = performance.now();
    if (nowMs - this.lastGeocodeAtMs < 5000) {
      return;
    }

    if (this.lastGeocodeFix && haversineMeters(this.lastGeocodeFix, fix) < 20) {
      return;
    }

    this.lastGeocodeAtMs = nowMs;
    this.lastGeocodeFix = { lat: fix.lat, lon: fix.lon };

    try {
      const qs = new URLSearchParams({
        lat: String(fix.lat),
        lon: String(fix.lon),
      });
      const res = await fetch(`${this.reverseGeocodeEndpoint}?${qs.toString()}`);
      if (!res.ok) {
        if (res.status === 401 || res.status === 403) {
          this.reverseGeocodeDisabled = true;
          this._setAddress("주소 API 인증 실패(키 설정 확인 필요)");
          return;
        }
        throw new Error(`HTTP ${res.status}`);
      }

      const payload = await res.json();
      const address = payload?.address || "(주소 정보 없음)";
      this._setAddress(address);
    } catch {
      this._setAddress("주소 조회 실패");
    }
  }

  _setStatus(text, isError) {
    if (!this.statusEl) {
      return;
    }

    this.statusEl.textContent = text;
    this.statusEl.classList.toggle("error", Boolean(isError));
  }

  _setAddress(addressText) {
    if (!this.addressEl) {
      return;
    }

    this.addressEl.textContent = `주소: ${addressText}`;
  }

  resize() {
    if (!this.panorama || !window.naver?.maps?.Event) {
      return;
    }
    window.naver.maps.Event.trigger(this.panorama, "resize");
  }
}
