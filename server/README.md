# Telemetry Dashboard Server (MVP)

## 1분 실행 (Windows PowerShell)

```powershell
cd server
py -3.11 -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
python app.py
```

기본 주소(보수 설정):
- HTTP: `http://127.0.0.1:8080`
- WS: `ws://127.0.0.1:8080/ws`
- 기본값은 로컬 루프백만 허용합니다.

## 기능 요약
- FastAPI 정적 호스팅 (`/` -> `../client/index.html`)
- WebSocket 10Hz CAN 브로드캐스트
- 업링크 수신: GPS 프레임, MARK 이벤트 (WS 또는 HTTP)
- CSV 세션 로그: `server/logs/`

## 환경 변수
- `HOST` (기본 `127.0.0.1`)
- `PORT` (기본 `8080`)
- `CAN_HZ` (기본 `10`)
- `SIM_DROP_EVERY` (기본 `0`, 예: `25`면 25프레임마다 1회 누락 시뮬레이션)
- `CAN_SOURCE` (기본 `dummy`)
- `SSL_CERTFILE`, `SSL_KEYFILE` (선택, HTTPS 실행)
- `NAVER_MAPS_CLIENT_ID` (선택, NAVER 로드뷰/지도 JS 로드)
- `NAVER_MAPS_CLIENT_SECRET` (선택, 서버 reverse-geocode 호출용)

예시:
```powershell
$env:SIM_DROP_EVERY = "20"
python app.py
```

모바일(iPad/iPhone) 접속이 필요할 때만 외부 노출:
```powershell
$env:HOST = "0.0.0.0"
python app.py
```
또는 특정 LAN IP만 바인딩:
```powershell
$env:HOST = "192.168.x.x"
python app.py
```

NAVER 로드뷰 사용 예시:
```powershell
$env:NAVER_MAPS_CLIENT_ID = "<your_client_id>"
$env:NAVER_MAPS_CLIENT_SECRET = "<your_client_secret>"
python app.py
```
`Client Secret`은 서버에서만 사용되며 브라우저로 노출되지 않습니다.
참고: 로드뷰 JS는 `Client ID`로 동작하지만, reverse-geocode는 NCP API 권한/상품 활성화가 별도로 필요할 수 있습니다(401 시 주소 조회만 비활성).

## HTTPS 개발 인증서 (선택)
Geolocation 권한이 HTTP에서 실패하면 HTTPS로 전환하세요.

```powershell
cd security
.\make_dev_cert.ps1
cd ..
$env:SSL_CERTFILE = "./security/certs/dev-cert.pem"
$env:SSL_KEYFILE  = "./security/certs/dev-key.pem"
python app.py
```

## API
- `GET /api/ping`
- `GET /api/public-config`
- `GET /api/naver/reverse-geocode?lat=<lat>&lon=<lon>`
- `POST /api/gps`
- `POST /api/event`
- `WS /ws`

## 핫스팟 운영
권장: iPad가 AP(핫스팟) 역할, 노트북이 해당 SSID에 접속
1. iPad 핫스팟 ON
2. 노트북을 iPad SSID에 연결
3. 노트북 IP 확인 (`ipconfig`)
4. iPad Safari에서 `http://<노트북IP>:8080` 접속

일부 핫스팟은 기기 간 통신을 제한(AP isolation)할 수 있습니다. 연결 안 되면 다음을 확인:
- 노트북 방화벽에서 8080 허용
- iPad와 노트북이 같은 서브넷인지 확인
- 가능하면 iPad AP 모드로 재구성
