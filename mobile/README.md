# Telemetry Mobile (Bare React Native Scaffold)

현재 리포의 서버(`server/app.py`)와 동일 데이터 계약을 사용하는 모바일 앱 스캐폴딩입니다.

## 범위
- WebSocket 수신: CAN frame(`seq/drop/sig`) 표시
- GPS watch + uplink: `meta(source/bg_state/os/app_ver/device)` 포함 송신
- WS 단절 시 GPS payload store-and-forward 큐 적재 + 재연결 시 flush
- MARK 이벤트 송신
- 재연결(backoff) + ping/pong RTT 표시

## 빠른 시작
```bash
cd mobile
npm install
npm run init-native   # 최초 1회: ios/android 네이티브 프로젝트 생성
npm run ios:setup-bg  # iOS Info.plist 위치 권한/백그라운드 키 자동 반영 + 브리지 파일 복사
npm run android:setup-bg  # Android 브리지/서비스 소스 복사 + 매니페스트 체크리스트 출력
npm run validate
npm run start
```

다른 터미널에서:
```bash
# iOS
npm run ios

# Android
npm run android
```

## 서버 연결
- 기본 입력값: `http://127.0.0.1:8080`
- 실기기 테스트 시 서버를 LAN으로 바인딩:
```bash
cd server
HOST=0.0.0.0 python app.py
```
- 앱 입력창에 `http://<server-ip>:8080` 지정 후 Connect

## 권한 설정 (필수)

### iOS (`ios/<App>/Info.plist`)
- `NSLocationWhenInUseUsageDescription`
- `NSLocationAlwaysAndWhenInUseUsageDescription`
- `UIBackgroundModes`에 `location`
- 위 3개는 `npm run ios:setup-bg`로 자동 반영 가능
- Xcode에서 `Signing & Capabilities > Background Modes > Location updates` 체크 필요

### Android (`android/app/src/main/AndroidManifest.xml`)
- `ACCESS_FINE_LOCATION`
- Background 수집 단계에서 추가:
  - `ACCESS_BACKGROUND_LOCATION` (Android 10+)
  - Foreground Service 권한/알림 채널
- 최소 스캐폴드: [`scripts/android-manifest-fgs-scaffold.xml`](scripts/android-manifest-fgs-scaffold.xml)
- 상세 가이드: [`docs/android-fgs-bg-location.md`](../docs/android-fgs-bg-location.md)

## Android 네이티브 백그라운드 위치 FGS (P3-3 Android 트랙)

Android 백그라운드 GPS 수집은 Foreground Service(FGS)를 통해 구현한다.  
권한 선언, 서비스 선언, `meta.bg_state` 흐름 전체 가이드:  
→ **[`docs/android-fgs-bg-location.md`](../docs/android-fgs-bg-location.md)**

### JS 계층 흐름
```
GpsClient.start({ androidBackgroundMode: true })
  └─ Android + RNAndroidLocationBridge 사용 가능?
       ├─ YES → LocationForegroundService 시작 → GPS 수집
       │         └─ "locationUpdate" 이벤트 → onFix → meta.bg_state 포함 uplink
       └─ NO  → Geolocation.watchPosition() (기존 동작, 폴백)
```

현재 baseline에서는 Android 네이티브 소스 파일(`native-android-bridge`)과 복사 스크립트만 제공한다.
실제 동작을 위해서는 생성된 `android/` 프로젝트에 파일 반영 + ReactPackage 등록이 필요하다.
앱 UI의 `Android BG Pilot` 토글은 `ACCESS_BACKGROUND_LOCATION` 권한 요청 분기를 활성화한다.

`meta.bg_state`는 React Native `AppState`("active" → `"foreground"`, 그 외 → `"background"`)  
기준으로 설정되어 서버 수신 GPS 페이로드의 `meta.bg_state` 필드에 기록됩니다.  
→ 흐름 상세: [`docs/android-fgs-bg-location.md#4-metabg_state-흐름`](../docs/android-fgs-bg-location.md)

## iOS 네이티브 백그라운드 위치 브리지 (P3-3)

`mobile/native-ios-bridge/RNIosLocationBridge.{h,m}`은 백그라운드 위치 수명 주기를 안정적으로
관리하는 전용 네이티브 모듈입니다.

### 동작 원리
| 항목 | 설명 |
|------|------|
| **모듈 이름** | `RNIosLocationBridge` |
| **JS 진입** | `NativeModules.RNIosLocationBridge` |
| **이벤트** | `locationUpdate`, `bgStateChange`, `locationError` |
| **연속 모드** | `allowsBackgroundLocationUpdates = YES`, `pausesLocationUpdatesAutomatically = NO` |
| **절전 모드** | `startMonitoringSignificantLocationChanges` (약 500 m 해상도) |

### JS 계층 흐름
```
GpsClient.start({ iosBackgroundMode: true })
  └─ iOS + RNIosLocationBridge 사용 가능?
       ├─ YES → _startViaIosBridge() → RNIosLocationBridge.startBackgroundLocation()
       │         └─ "locationUpdate" 이벤트 → onFix callback → meta.bg_state 포함 uplink
       └─ NO  → Geolocation.watchPosition() (기존 동작, 폴백)
```

`meta.bg_state`는 React Native `AppState`("active" → "foreground", 그 외 → "background")를
기준으로 설정되어 서버 수신 GPS 페이로드에 `meta.bg_state=background`로 기록됩니다.

### Xcode 프로젝트 연결 (수동)
`npm run ios:setup-bg` 실행 후 Xcode에서 아래를 수행합니다:
1. `ios/*.xcworkspace` 열기
2. Project Navigator에서 앱 타겟 폴더 우클릭
3. `Add Files to <project>` → `RNIosLocationBridge.h` / `RNIosLocationBridge.m` 선택
4. `Add to target` 체크 확인 후 추가
5. `Signing & Capabilities > Background Modes > Location updates` 체크 확인

### 브리지 메서드
```objc
// 백그라운드 위치 수집 시작 (JS: RNIosLocationBridge.startBackgroundLocation(options))
// options: { useSignificantChanges: boolean }
startBackgroundLocation:(NSDictionary *)options

// 위치 수집 중단 (JS: RNIosLocationBridge.stopBackgroundLocation())
stopBackgroundLocation

// 동기 상태 확인 (JS: RNIosLocationBridge.isBackgroundActive() → bool)
isBackgroundActive
```

## 30분 백그라운드 검증 실행 절차 (P3-3 Runbook)

> 보고서 양식(지표 기재): [`docs/reports/ios-bg-30min-template.md`](../docs/reports/ios-bg-30min-template.md)
> E2E 점검표: [`docs/e2e-platform-checklist.md`](../docs/e2e-platform-checklist.md)

### 사전 준비
1. 서버 LAN 바인딩 시작:
   ```bash
   cd server
   HOST=0.0.0.0 python app.py
   ```
2. 앱 빌드 및 실기기 설치:
   ```bash
   cd mobile
   npm run ios:setup-bg  # Info.plist 위치 권한/백그라운드 키 반영
   npm run ios           # 실기기에 배포
   ```
3. iOS 설정 → 개인 정보 보호 → 위치 서비스 → 앱 → **항상** 선택 확인
4. 배터리 잔량 기록.

### 실행
1. 앱 실행 → 서버 URL 입력 → **Connect** 탭.
2. WS 상태 표시등이 녹색(연결됨)이고 GPS 값이 갱신되는지 확인 (최소 30초).
3. 기기 화면 잠금(전원 버튼 또는 홈 버튼).
4. 30분 타이머 시작.
5. (선택) 15분 경과 시 서버를 재시작하거나 기기를 비행기 모드로 전환하여 단절 시뮬레이션 실시.
6. 30분 후 화면 잠금 해제 → 앱 foreground 복귀 → 재연결 및 GPS 재수신 확인.

### 로그 수집
```bash
# 서버 실행 디렉터리에서 세션 파일 확인
ls server/logs/gps_*.csv server/logs/events_*.csv

# 타임스탬프 갭 분석 (Python)
python - <<'PY'
import glob
import pandas as pd
import sys

files = sorted(glob.glob("server/logs/gps_*.csv"))
if not files:
    print("No GPS CSV found")
    sys.exit(1)

# 필수 컬럼: client_t(epoch seconds), bg_state, source, lat, lon, app_ver, device
# client_t를 UTC datetime으로 변환해 갭을 계산한다.
df = pd.read_csv(files[-1])
df = df.sort_values("client_t").reset_index(drop=True)
ts = pd.to_datetime(df["client_t"], unit="s", utc=True)
gaps_seconds = ts.diff().dt.total_seconds()
print("총 레코드:", len(df))
print("bg_state 분포:")
print(df["bg_state"].value_counts(dropna=False))
large_gaps_seconds = gaps_seconds[gaps_seconds > 30]
print(f"30초 초과 갭 {len(large_gaps_seconds)}건:")
print(large_gaps_seconds)
PY
```

### 판정 기준 요약

| 지표 | 합격 기준 |
|---|---|
| GPS 누락률 | ≤ 20% |
| WS 재연결 성공률 | 100% |
| 큐 flush 완료 | Y |
| GPS 신선도 지연 | ≤ 300초 |

결과를 `docs/reports/ios-bg-30min-template.md`에 기재하여 팀과 공유.

## 현재 한계
- 기본 스캐폴딩은 경량 커밋을 위해 `ios/`, `android/`를 저장소에 포함하지 않는다.
- `npm run init-native`로 로컬에서 네이티브 폴더를 생성한 뒤 실행한다.
- iOS significant-change 모드는 배터리 최적화를 위한 파일럿 옵션이며 정확한 주기 보장은 없다.
- RNIosLocationBridge는 수동 Xcode 프로젝트 연결이 필요하다(pbxproj 자동화는 P4 범위).
- CarPlay/Android Auto는 P4 단계에서 네이티브 템플릿 구현이 필요.
