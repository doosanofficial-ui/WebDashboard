# Telemetry Mobile (Bare React Native Scaffold)

현재 리포의 서버(`server/app.py`)와 동일 데이터 계약을 사용하는 모바일 앱 스캐폴딩입니다.

## 범위
- WebSocket 수신: CAN frame(`seq/drop/sig`) 표시
- GPS watch + uplink: `meta(source/bg_state/os/app_ver/device)` 포함 송신
- MARK 이벤트 송신
- 재연결(backoff) + ping/pong RTT 표시

## 빠른 시작
```bash
cd mobile
npm install
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
- Background 수집 단계에서 추가:
  - `NSLocationAlwaysAndWhenInUseUsageDescription`
  - `UIBackgroundModes`에 `location`

### Android (`android/app/src/main/AndroidManifest.xml`)
- `ACCESS_FINE_LOCATION`
- Background 수집 단계에서 추가:
  - `ACCESS_BACKGROUND_LOCATION` (Android 10+)
  - Foreground Service 권한/알림 채널

## 현재 한계
- 본 스캐폴딩은 foreground GPS uplink 기준.
- Background 30분 안정성 목표(P3-3)는 네이티브 서비스/브리지 구현이 추가로 필요.
- CarPlay/Android Auto는 P4 단계에서 네이티브 템플릿 구현이 필요.
