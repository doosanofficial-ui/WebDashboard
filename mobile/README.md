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
       ├─ YES → _startViaBridge() → RNIosLocationBridge.startBackgroundLocation()
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

## 현재 한계
- 기본 스캐폴딩은 경량 커밋을 위해 `ios/`, `android/`를 저장소에 포함하지 않는다.
- `npm run init-native`로 로컬에서 네이티브 폴더를 생성한 뒤 실행한다.
- iOS significant-change 모드는 배터리 최적화를 위한 파일럿 옵션이며 정확한 주기 보장은 없다.
- RNIosLocationBridge는 수동 Xcode 프로젝트 연결이 필요하다(pbxproj 자동화는 P4 범위).
- CarPlay/Android Auto는 P4 단계에서 네이티브 템플릿 구현이 필요.
