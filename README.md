# telemetry-dashboard (MVP)

Windows 노트북에서 10Hz CAN 계측값을 송출하고, iPad Safari/PWA에서 실시간 대시보드(게이지 + 그래프 + GPS)를 표시하는 최소 동작 레포입니다.
GPS는 좌표 카드뿐 아니라 NAVER 지도 위에 현재 위치/궤적/MARK를 표시하고, NAVER 로드뷰를 함께 표시합니다.

## 구조

```text
/telemetry-dashboard
  /server
    app.py
    config.py
    can_source/
      __init__.py
      base.py
      dummy.py
      adapters.md
    gps_sink.py
    logger.py
    security/
      make_dev_cert.ps1
      certs/
    requirements.txt
    README.md
  /client
    index.html
    app.js
    gps.js
    ws.js
    charts.js
    ui.js
    styles.css
    manifest.json
    sw.js
  /docs
    PRD.md
    BACKLOG.md
  .gitignore
```

## 빠른 시작 (1분)

### 1) 서버 실행
```powershell
cd server
py -3.11 -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
python app.py
```

기본 보수 모드:
- 서버는 `127.0.0.1:8080`에만 바인딩됩니다(외부 기기 차단).

모바일 접속이 필요할 때만 명시적으로 LAN 공개:
```powershell
$env:HOST = "0.0.0.0"
python app.py
```

### 2) iPad 접속
- iPad Safari에서 `http://<노트북IP>:8080` 접속
- `Connect` 클릭
- `Start GPS` 클릭 후 위치 권한 허용

## 핫스팟 운영 권장
1. iPad 핫스팟 ON (AP 역할)
2. Windows 노트북이 해당 SSID 접속
3. 노트북 IP 확인: `ipconfig`
4. iPad Safari에서 `http://<노트북IP>:8080`

핫스팟 AP isolation으로 통신이 막히면:
- iPad AP 구성으로 재시도
- Windows 방화벽에서 TCP 8080 허용
- iPad와 노트북 IP 대역(서브넷) 확인

## GPS 권한 / HTTPS
- 일부 iPadOS/Safari 환경에서 Geolocation은 HTTPS 보안 컨텍스트를 요구할 수 있습니다.
- HTTP에서 GPS가 동작하지 않으면 `server/security/make_dev_cert.ps1`로 자체서명 인증서를 생성해 HTTPS로 실행하세요.
- NAVER 지도/로드뷰 스크립트 로드를 위해 외부 네트워크 연결이 필요합니다.

## NAVER 로드뷰 연동
서버 실행 전에 환경 변수 설정:
```powershell
$env:NAVER_MAPS_CLIENT_ID = "<your_client_id>"
$env:NAVER_MAPS_CLIENT_SECRET = "<your_client_secret>"
python app.py
```
- `Client ID`: 브라우저에서 NAVER Maps JS 로드에 사용
- `Client Secret`: 서버의 reverse-geocode API 호출에만 사용(브라우저 비노출)
- NAVER Maps JS 로더 파라미터는 최신 문서 기준 `ncpKeyId=<Client ID>`를 사용합니다.
- reverse-geocode가 401이면 NAVER/NCP 콘솔에서 해당 API 권한 또는 상품 활성화 상태를 확인하세요(로드뷰 자체는 동작 가능).
- 지도에 `Open API 설정 실패`가 보이면 대부분 `웹 서비스 URL` 미등록 문제입니다.
  - NCP 콘솔에 아래 URL을 모두 등록:
  - `http://127.0.0.1:8080`
  - `http://localhost:8080`
  - `http://<LAN_IP>:8080` (iPhone/iPad 접속용)
  - 등록 후 서버/브라우저 새로고침
  - VS Code 내장 브라우저(Simple Browser)에서만 실패하면, 먼저 Chrome/Safari에서 같은 URL로 검증

## 트러블슈팅
- `Connect`가 안 됨:
  - `http://<노트북IP>:8080/api/ping`이 iPad에서 열리는지 확인
  - 방화벽/보안SW가 8080 차단하는지 확인
- CAN 값이 안 뜸:
  - 서버 콘솔 에러 확인
  - 브라우저 새로고침 후 재접속
- GPS가 안 뜸:
  - Safari 위치 권한 허용 확인
  - iPad 설정 > 개인정보 보호 > 위치 서비스 ON
  - HTTPS로 전환

## 확장 포인트
- 실차 연동: `server/can_source/base.py` 인터페이스 구현체 교체
- 인코딩 교체(JSON -> msgpack/protobuf): `client/ws.js` codec 레이어 교체
- 상세 연동 후보: `server/can_source/adapters.md`
