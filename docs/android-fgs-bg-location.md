# Android Background Location — FGS 최소 스캐폴드

> **상태**: 스캐폴드 문서 (구현 진행 중, P3-3 Android 트랙)  
> **관련 파일**:  
> - 권한/서비스 선언 스캐폴드: [`mobile/scripts/android-manifest-fgs-scaffold.xml`](../mobile/scripts/android-manifest-fgs-scaffold.xml)  
> - iOS 네이티브 브리지: `mobile/native-ios-bridge/RNIosLocationBridge.{h,m}`  
> - GPS payload 계약: `mobile/src/telemetry/protocol.js`  
> - 검증 보고서 양식: [`docs/reports/android-bg-30min-template.md`](reports/android-bg-30min-template.md)

---

## 1. 개요

Android에서 앱이 **백그라운드**에 있을 때 GPS를 지속 수집하려면 Foreground Service(FGS)가 필요하다.  
FGS는 사용자에게 지속 알림(Notification)을 표시하며, OS의 앱 종료 정책에서 보호되어 GPS uplink를 안정적으로 유지한다.

### iOS와 Android 백그라운드 위치 비교

| 항목 | iOS | Android |
|---|---|---|
| 권한 단계 | `whenInUse` → `always` | `FINE` → `BACKGROUND_LOCATION` (API 29+) |
| 백그라운드 메커니즘 | `UIBackgroundModes: location` + Significant-Change | FGS + `foregroundServiceType="location"` |
| 알림 필수 여부 | 상단 파란 바(자동) | 개발자가 Notification 채널 생성 필수 |
| JS 브리지 | `RNIosLocationBridge.{h,m}` | `RNAndroidLocationBridge.{java,kt}` (예정) |
| 최소 API 레벨 | iOS 14+ | API 26+(FGS), API 29+(Background 권한), API 34+(serviceType) |

---

## 2. AndroidManifest.xml 선언

스캐폴드 파일: [`mobile/scripts/android-manifest-fgs-scaffold.xml`](../mobile/scripts/android-manifest-fgs-scaffold.xml)

### 필수 권한 목록

| 권한 | 최소 API | 용도 |
|---|---|---|
| `ACCESS_FINE_LOCATION` | 모든 버전 | Foreground GPS watchPosition |
| `ACCESS_COARSE_LOCATION` | 모든 버전 | 거친 위치(선택적 대체) |
| `ACCESS_BACKGROUND_LOCATION` | API 29 (Android 10) | 백그라운드 수집 런타임 권한 |
| `FOREGROUND_SERVICE` | API 28 (Android 9) | FGS 실행 |
| `FOREGROUND_SERVICE_LOCATION` | API 34 (Android 14) | serviceType=location 선언 시 필수 |
| `POST_NOTIFICATIONS` | API 33 (Android 13) | FGS 알림 채널 표시 |

### 서비스 선언

```xml
<service
    android:name=".LocationForegroundService"
    android:exported="false"
    android:foregroundServiceType="location" />
```

- `android:exported="false"`: 외부 앱 바인딩 차단.  
- `android:foregroundServiceType="location"`: API 29+ 필수. 누락 시 API 34+에서 런타임 예외 발생.

---

## 3. 런타임 권한 요청 흐름

```
앱 최초 실행
  └─ requestLocationPermission() (gps-client.js)
       ├─ PermissionsAndroid.request(ACCESS_FINE_LOCATION)
       │    └─ granted? → GPS watchPosition 시작 (foreground)
       └─ [백그라운드 모드 활성화 시]
            PermissionsAndroid.request(ACCESS_BACKGROUND_LOCATION)
              └─ granted? → FGS 시작 (RNAndroidLocationBridge, 예정)
                            └─ LocationForegroundService.startForeground()
                                 └─ GPS 수집 지속 (화면 OFF 포함)
```

> **주의**: `ACCESS_BACKGROUND_LOCATION`은 별도 런타임 요청이 필요하며, Google Play 정책상  
> 사용 목적을 명시한 심사 승인이 필요하다 (Play Console > 앱 콘텐츠 > 위치 권한 정책).

---

## 4. meta.bg_state 흐름

`meta.bg_state`는 GPS payload(`protocol.js`)의 `meta` 필드로 서버에 전송되어  
**백그라운드 수집 여부를 서버/분석 레이어에서 식별**하는 데 사용된다.

### React Native AppState → bg_state 매핑

```
AppState.currentState
  ├─ "active"     → meta.bg_state = "foreground"
  └─ "background" │
     "inactive"   → meta.bg_state = "background"
```

### 코드 흐름 (`App.js` → `protocol.js`)

```
AppState 이벤트 수신 (App.js)
  └─ appStateRef.current = nextState
       └─ GPS fix 수신 시 createGpsPayload(fix, { bgState: ... }) 호출
            └─ protocol.js: meta.bg_state = bgState || "foreground"
                 └─ WebSocket uplink → 서버 수신 스키마(bg_state 컬럼)
```

### 서버 수신 스키마 (`bg_state` 컬럼)

```jsonc
{
  "v": 1,
  "t": 1740000000.0,        // epoch seconds (client clock)
  "gps": { "lat": 37.5, "lon": 127.0, "spd": 0, ... },
  "meta": {
    "source": "mobile",
    "bg_state": "background",   // "foreground" | "background"
    "os": "Android",
    "app_ver": "rn-bare-v0.1",
    "device": "Pixel 8"
  }
}
```

> `bg_state` 분포 분석은 서버 로그 CSV의 `bg_state` 컬럼을 기준으로  
> [android-bg-30min-template.md](reports/android-bg-30min-template.md) 판정 기준을 사용한다.

---

## 5. Android FGS 구현 단계 (예정, P3-3 Android 트랙)

| 단계 | 내용 | 상태 |
|---|---|---|
| 1 | `AndroidManifest.xml` 권한/서비스 선언 | ✅ 스캐폴드 완료 |
| 2 | `LocationForegroundService.kt` — Notification 채널 + `startForeground()` | 🔲 예정 |
| 3 | `RNAndroidLocationBridge.kt` — JS NativeModule, `startBackgroundLocation` / `stopBackgroundLocation` | 🔲 예정 |
| 4 | `gps-client.js` Android 분기 — `Platform.OS === "android" && androidBackgroundMode` | 🔲 예정 |
| 5 | `ACCESS_BACKGROUND_LOCATION` 런타임 요청 추가 (`requestLocationPermission`) | 🔲 예정 |
| 6 | Android 30분 백그라운드 검증 실행 (보고서 양식: android-bg-30min-template.md) | 🔲 예정 |

---

## 6. 배터리 최적화 예외 안내

Android 기기는 백그라운드 앱을 절전 모드(Doze/App Standby)로 전환하여 FGS도 영향을 받을 수 있다.

- **배터리 최적화 예외 요청** (선택, 주행 중 연속 수집에 권장):
  ```xml
  <uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS" />
  ```
  앱 설정 → 배터리 → 배터리 사용 최적화 → 앱 선택 → 최적화 안 함.  
  > Google Play 정책상 필수가 아닌 경우 이 권한 사용 자제 권고. 목적을 명시한 예외 사유 필요.

- **Doze 모드 참고**: FGS는 Doze 윈도우 밖에서도 실행되나 네트워크 접근은 제한될 수 있다.  
  → `store-forward-queue.js` 의 오프라인 큐잉으로 단절 구간 커버.

---

## 7. 관련 문서 링크

- [플랫폼 매트릭스](platform-matrix.md) — Background Telemetry 체크리스트 (Gate B)  
- [E2E 플랫폼 점검표](e2e-platform-checklist.md) — GPS 점검 항목  
- [ADR-0001: 모바일 런타임 선택](adr/0001-mobile-runtime-selection.md)  
- [Android 30분 검증 보고서 양식](reports/android-bg-30min-template.md)  
- [Mobile README](../mobile/README.md) — 빠른 시작 및 iOS 브리지 참조
