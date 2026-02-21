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
npm run ios:setup-bg  # iOS Info.plist 위치 권한/백그라운드 키 자동 반영
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

## 현재 한계
- 기본 스캐폴딩은 경량 커밋을 위해 `ios/`, `android/`를 저장소에 포함하지 않는다.
- `npm run init-native`로 로컬에서 네이티브 폴더를 생성한 뒤 실행한다.
- iOS significant-change 모드는 배터리 최적화를 위한 파일럿 옵션이며 정확한 주기 보장은 없다.
- Background 30분 안정성 목표(P3-3)는 iOS 네이티브 브리지(위치 서비스 생명주기/재시작) 구현이 추가로 필요.
- CarPlay/Android Auto는 P4 단계에서 네이티브 템플릿 구현이 필요.
