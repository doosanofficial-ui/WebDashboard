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

세션 ID는 `YYYYMMDD_HHMMSS_<UUID>`입니다. CSV는 exclusive create로 열어
빠른 재시작이나 명시적 ID 충돌 시 기존 파일을 덮어쓰지 않습니다.
뷰어별 CAN 전송은 최신 대기 프레임 1개만 유지하고, 전송이 1초 이상 막히면
그 연결을 종료합니다. 느린 뷰어는 CAN 수집과 다른 뷰어를 막지 않습니다.
`status.client_drop`은 해당 연결의 대기 프레임 병합 횟수이며,
기존 `status.drop`(서버 누락 시뮬레이션)과 별도입니다. 클라이언트 seq gap과
중복 합산하지 마세요. CSV는 실시간 뷰어 큐와 별도로 기록합니다.
송출 누락 시뮬레이션을 켜도 원본 CAN CSV는 매 수집 샘플을 기록합니다.
시작/종료 수명주기마다 새 세션과 seq=0을 사용하며 이전 CSV를 재사용하지 않습니다.

`GET /api/ping`은 단순 HTTP 생존이 아니라 CAN 수집/기록 상태를 확인합니다.
정상은 200, 수집/기록 작업 실패나 stale은 503이며 `error.code`로
`source_failed`, `recording_failed`, `stream_unavailable`, `stream_stale`을 구분합니다.
원본 예외 문자열이나 내부 경로는 반환하지 않습니다. 실패 후 자동으로 기록을
건너뛰며 정상 표시하지 않고, 원인을 해결한 뒤 서버를 재시작해야 합니다.
`stream.last_frame_age_ms`는 마지막 기록 성공 후 경과 시간입니다.
현재 동기식 디스크 I/O의 장기 block까지 격리하는 기능은 아직 출시 과제입니다.

## 환경 변수
- `HOST` (기본 `127.0.0.1`)
- `PORT` (기본 `8080`)
- `CAN_HZ` (기본 `10`, 유한한 양수만 허용)
- `SIM_DROP_EVERY` (기본 `0`, 예: `25`면 25프레임마다 1회 누락 시뮬레이션)
- `CAN_SOURCE` (기본 `dummy`)
- `SIGNALS_CONFIG` (기본 `./signals.json`, 신호 enable/scale/offset/clamp 설정)
- `SSL_CERTFILE`, `SSL_KEYFILE` (선택, HTTPS 실행)
- `NAVER_MAPS_CLIENT_ID` (선택, NAVER 로드뷰/지도 JS 로드)
- `NAVER_MAPS_CLIENT_SECRET` (선택, 서버 reverse-geocode 호출용)

예시:
```powershell
$env:SIM_DROP_EVERY = "20"
python app.py
```

신호 매핑 파일 경로 변경 예시:
```powershell
$env:SIGNALS_CONFIG = "C:\telemetry\signals.json"
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
참고: reverse-geocode 실패 시 서버가 401/403/429/5xx를 구분하여 반환하므로, 클라이언트는 인증 실패를 영구 비활성화하고 나머지는 자동 backoff로 재시도합니다.
참고: NAVER Maps JS 스크립트는 최신 문서 기준 `ncpKeyId=<Client ID>` 파라미터를 사용해야 합니다.
지도에 `Open API 설정 실패` 문구가 뜨면 아래를 확인하세요.
- NCP 콘솔 `웹 서비스 URL` 허용 목록에 정확히 등록:
- `http://127.0.0.1:8080`
- `http://localhost:8080`
- `http://<LAN_IP>:8080`
- `https://127.0.0.1:18443` (HTTPS 사용 시)
- `https://<LAN_IP>:18443` (HTTPS 사용 시)
- URL 등록 후 브라우저 강력 새로고침
- VS Code 내장 브라우저에서만 실패하면 Chrome/Safari에서 먼저 확인(웹뷰 리퍼러 차이로 인증 실패 가능)

## HTTPS 개발 인증서 (선택)
Geolocation 권한이 HTTP에서 실패하면 HTTPS로 전환하세요.

```powershell
cd security
.\make_dev_cert.ps1 -LanIp "<LAN_IP>"
cd ..
$env:SSL_CERTFILE = "./security/certs/dev-cert.pem"
$env:SSL_KEYFILE  = "./security/certs/dev-key.pem"
$env:HOST = "0.0.0.0"
$env:PORT = "18443"
python app.py
```

macOS (zsh/bash):
```bash
cd security
./make_dev_cert_mac.sh ./certs 192.168.x.x
cd ..
export SSL_CERTFILE="./security/certs/dev-cert.pem"
export SSL_KEYFILE="./security/certs/dev-key.pem"
export HOST="0.0.0.0"
export PORT="18443"
python app.py
```

iPhone/iPad에서 HTTPS 위치 권한이 필요하면, `make_dev_cert_mac.sh`가 생성한
`dev-local-ca-cert.cer`를 기기에 설치하고 신뢰 설정까지 켜야 합니다.

## API
- `POST /api/v2/ingest`: 원본 측정시각을 보존하는 영속 GPS/MARK/STATE batch 수신.
  `INGEST_TOKEN` 환경변수가 없으면 비활성(503)이며, 원격 요청은 HTTPS와
  Bearer 인증이 필요합니다. 토큰을 소스/로그에 기록하지 마세요.
  SQLite commit 후 ACK하며 같은 event ID의 동일 재전송은 중복 기록하지 않습니다.
  다른 내용으로 ID를 재사용하면 batch 전체를 409로 거부합니다.
  상세 계약: `docs/adr/0003-native-ios-reliable-ingest.md`.
  저장 파일: `server/logs/telemetry.sqlite3`; CSV는 `TelemetryJournal.export_csv`로 추출합니다.
  기존 v1 경로 전체의 페어링/인증 강화는 아직 별도 출시 과제입니다.
- `GET /api/ping`
- `GET /api/public-config`
- `GET /api/naver/reverse-geocode?lat=<lat>&lon=<lon>`
- `POST /api/gps`
- `POST /api/event`
- `WS /ws`

`POST /api/gps` / `WS /ws` GPS uplink 예시(선택 메타 포함):
```json
{
  "v": 1,
  "t": 1730000001.456,
  "gps": { "lat": 37.123, "lon": 127.123, "spd": 8.2, "hdg": 92.4, "acc": 7.1, "alt": 35.5 },
  "meta": {
    "source": "web|mobile",
    "bg_state": "foreground|background",
    "os": "iOS|Android|...",
    "app_ver": "string",
    "device": "string"
  }
}
```
메타 필드는 선택이며, 전달 시 `gps_<session>.csv`에 함께 기록됩니다.

## 핫스팟 운영
권장: iPad가 AP(핫스팟) 역할, 노트북이 해당 SSID에 접속
1. iPad 핫스팟 ON
2. 노트북을 iPad SSID에 연결
3. 노트북 IP 확인 (`ipconfig`)
4. iPad Safari에서 `http://<노트북IP>:8080` 접속

HTTPS 운영 시:
4. iPad Safari에서 `https://<노트북IP>:18443` 접속

일부 핫스팟은 기기 간 통신을 제한(AP isolation)할 수 있습니다. 연결 안 되면 다음을 확인:
- 노트북 방화벽에서 8080 허용
- iPad와 노트북이 같은 서브넷인지 확인
- 가능하면 iPad AP 모드로 재구성
