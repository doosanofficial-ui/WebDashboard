# iOS Preflight Smoke Report (2026-02-22)

목적: iPhone 실기기 30분 검증 전에 서버/로그 파이프라인이 정상인지 로컬에서 선확인한다.

## 실행 환경

- Date (UTC): 2026-02-22
- Host: macOS local
- Server URL: `http://127.0.0.1:8090`
- Session ID: `20260222_002008`

## 실행 명령

```bash
# server start (separate terminal)
cd server
HOST=127.0.0.1 PORT=8090 ./.venv/bin/python app.py

# preflight checks
curl -s http://127.0.0.1:8090/api/ping

# websocket ping + sample GPS uplink(meta 포함) + MARK
./server/.venv/bin/python - <<'PY'
import asyncio, json, time
import websockets

URL='ws://127.0.0.1:8090/ws'

async def main():
    async with websockets.connect(URL) as ws:
        for _ in range(3):
            _ = await ws.recv()
        await ws.send(json.dumps({'v':1,'type':'ping','t':time.time()}))
        _ = await ws.recv()
        await ws.send(json.dumps({
            'v':1,
            't':time.time(),
            'gps':{'lat':37.5665,'lon':126.9780,'spd':3.2,'hdg':181.0,'acc':6.0,'alt':35.0},
            'meta':{'source':'ios-rn','bg_state':'background','os':'iOS','app_ver':'rn-bare-v0.1','device':'iPhone'}
        }))
        await ws.send(json.dumps({'v':1,'t':time.time(),'type':'MARK','note':'ios-preflight-local'}))

asyncio.run(main())
PY
```

## 결과

- [x] `GET /api/ping` 응답 정상 (`ok=true`, `session=20260222_002008`)
- [x] `WS /ws` 연결/수신/ping-pong 정상
- [x] 샘플 GPS uplink 수신 및 CSV 기록 확인
- [x] MARK 이벤트 수신 및 CSV 기록 확인

로그 파일:
- `server/logs/can_20260222_002008.csv`
- `server/logs/gps_20260222_002008.csv`
- `server/logs/events_20260222_002008.csv`

CSV 샘플 확인:
- `gps_20260222_002008.csv` header에 메타 컬럼 존재
  - `source,bg_state,os,app_ver,device`
- `events_20260222_002008.csv`
  - `type=MARK`, `note=ios-preflight-local`

분석 스크립트 결과:
- record count: 1
- bg_state distribution: `background=1`
- gaps > 30s: 0

## 판정

- Preflight pipeline status: **PASS**
- 의미:
  - iOS 실기기 검증 전 서버 수신/저장 경로는 정상.
  - 남은 검증은 실기기에서의 실제 위치 이벤트 지속성(30분) 및 배터리/발열.

## 다음 단계 (실기기 필요)

1. iPhone에서 HTTPS 접속 + GPS always 권한 확인
2. 30분 백그라운드 시나리오 실행 (`docs/e2e-platform-checklist.md` iOS 섹션)
3. 결과를 `docs/reports/ios-bg-30min-template.md`에 실측값으로 기입
