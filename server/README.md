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
CSV의 파일 열기/쓰기/닫기는 별도 프로세스가 수행합니다. 서버는 최대 128개의
미확인 작업만 유지하며 CAN 수집은 저장 완료를 기다리지 않습니다. 대기가 500ms를
넘으면 `recording_delayed`, 큐 포화/기록 프로세스 실패는 `recording_failed`로
상태를 내립니다. 큐 포화 시 신규 수집을 중단하며 기존 작업을 조용히 버리지 않습니다.
`recording` 상태의 pending/written/unconfirmed/rejected와 last_can_seq를 구분하세요.
CAN 프레임의 `status.recording` 및 `recording_status` 제어 메시지에도 같은 상태를 보냅니다.
웹과 네이티브 iOS는 연결 상태와 별도로 서버 CSV 상태를 표시합니다.

HTTP GPS/MARK 성공은 실제 CSV write/flush 확인 후에만 반환합니다. 1초 안에 확인하지
못하면 503이며 이미 수락한 쓰기는 이후 완료될 수 있습니다. v1 재전송은 중복될 수
있으므로 정확한 영속 ACK/중복 제거에는 v2 경로를 사용하세요. CSV의 written은
전원 장애에도 안전한 영속 저장을 보증하는 표현이 아닙니다.

종료는 기본 2초 동안 큐를 비우고, 멈춘 자식은 종료/강제 종료 후 회수합니다.
닫힘 응답과 정상 종료 코드가 모두 있어야 정상 종료로 판정합니다. 미확인 건수는
오류와 함께 보고하며, 부모 입력 연결을 잃은 작업 프로세스도 무한히 남지 않도록 감시합니다.
실행 중인 Windows는 subprocess를 지원하는 Proactor 이벤트 루프가 필요합니다.
권장 실행인 `python app.py`의 단일 프로세스 설정을 사용하세요. frozen EXE 포장은
아직 C09 검증 대상이며, 현재 작업 프로세스는 실제 Python 인터프리터를 사용합니다.

이 격리는 CSV 경로에 적용됩니다. v2 SQLite 호출은 기존 스레드 경로이며,
OS/커널 전체 고착이나 실제 저장장치 장애의 모든 복구를 검증한 것은 아닙니다.

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

### v1 업링크 입력 규칙

`POST /api/gps`, `POST /api/event`는 `Content-Type: application/json`과 UTF-8
JSON을 요구합니다. WebSocket은 text JSON 프레임을 사용합니다.
메시지는 최대 16 KiB이며 중복 JSON 키, NaN/Infinity, 알 수 없는 필드는 거부합니다.
GPS/MARK의 `v`는 정수 1, `t`는 유한한 양수 epoch seconds여야 합니다.
기존 웹 호환을 위해 ping만 `v` 생략을 허용합니다.

- GPS: lat [-90,90], lon [-180,180]. spd/acc는 0 이상 또는 null,
  hdg는 [0,360) 또는 null, alt는 유한한 수 또는 null입니다.
- 선택 metadata는 source/bg_state/os/app_ver/device만 허용하며 문자열 각각 128자 이내입니다.
  bg_state는 foreground/background입니다. MARK note는 500자 이내이며 NUL/잘못된 Unicode는 거부합니다.
- 이전 모바일의 선택 `queued_at`은 양수 시각으로 검증하되 원래 `t`를 바꾸지 않습니다.
  기존 v1 CSV에는 queued_at 열을 새로 추가하지 않습니다.
- HTTP 거부: 400 invalid_json, 413 payload_too_large, 415 unsupported_media_type,
  422 invalid_payload/unsupported_version. CSV 실패는 503 storage_unavailable입니다.
- WS의 앱 계층 거부는 `{"v":1,"type":"error","error":{"code":"invalid_payload","message":"..."}}`
  형태입니다. 사용자 데이터나 원본 예외 문자열은 반환하지 않습니다.
- wire 한도 초과는 JSON 처리 전에 해당 WS를 **1009**로 닫을 수 있습니다.
  웹은 payload_too_large 경고를 표시하고 backoff 재연결합니다. 다른 구독자는 영향을 받지 않습니다.
  정상 크기의 손상 메시지는 오류를 반환하고 같은 연결의 CAN/ping 처리를 계속합니다.

`python app.py`는 WS 최대 메시지 16 KiB/수신 큐 8개를 설정합니다.
다른 실행기를 쓰면 같은 한도를 별도로 적용하세요. 예:
`uvicorn app:app --host 127.0.0.1 --port 8080 --ws websockets --ws-max-size 16384 --ws-max-queue 8`.

CSV의 note/metadata 등 텍스트가 수식 시작 문자로 해석되지 않도록 앞에 `'`를 붙입니다.
수치 좌표의 음수는 변경하지 않고, v2 journal 원문도 변경하지 않습니다.
웹의 업링크 거부 경고는 정상 CAN 수신이나 자동 재연결로 지우지 않으며,
사용자가 Connect를 다시 누를 때 초기화합니다. 이는 저장 성공 확인을 뜻하지 않습니다.
**v1 WS에는 영속 ACK/중복 제거가 없습니다.** 신뢰성 있는 기록은 `/api/v2/ingest` 경로를 사용합니다.
이 검증은 인증/Origin 제한/요청 빈도 제한을 대체하지 않습니다.

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
