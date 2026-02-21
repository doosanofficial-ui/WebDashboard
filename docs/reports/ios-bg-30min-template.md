# iOS Background Telemetry — 30-Minute Validation Report

이 템플릿은 iOS 앱의 백그라운드 GPS uplink 30분 시나리오를 반복 실행할 때 비교 가능한 보고서를 생성하기 위한 양식이다.

## 1. 실행 메타

| 항목 | 값 |
|---|---|
| 날짜 / 시간 |  |
| 테스터 |  |
| 디바이스 모델 |  |
| iOS 버전 |  |
| 앱 버전(`app_ver`) |  |
| 빌드/커밋 SHA |  |
| 서버 호스트 |  |
| 네트워크 환경 (Wi-Fi / LTE / etc.) |  |
| 배터리 시작 % |  |
| 배터리 종료 % |  |

## 2. 시나리오 요약

- 총 실행 시간: 30분 (± 1분)
- 화면 상태: 잠금(화면 OFF)으로 유지
- GPS 모드: significant-change (항상 권한, `UIBackgroundModes: location`)
- WS 연결: `ws://<server>/ws` 지속 연결, 단절 발생 시 자동 재연결
- 강제 단절: ___분 경과 시 서버 재시작 또는 네트워크 토글 (해당 없음 시 "없음" 기재)

## 3. 핵심 지표

### 3-1. GPS Drop Rate (GPS 누락률)

| 항목 | 값 |
|---|---|
| 예상 수신 이벤트 수 (significant-change 기준 추정) |  |
| 실제 수신 이벤트 수 (`server/logs/gps_<session>.csv` 행 수) |  |
| **누락률 (%)** | `(1 - 실제/예상) × 100` |
| 합격 기준 | ≤ 20% |
| 판정 | PASS / FAIL |

### 3-2. Reconnect Count (WS 재연결 횟수)

| 항목 | 값 |
|---|---|
| WS 재연결 총 횟수 |  |
| 재연결 평균 소요 시간 (초) |  |
| 최대 단절 지속 시간 (초) |  |
| 합격 기준 | 재연결 성공률 100% (무한 재시도) |
| 판정 | PASS / FAIL |

### 3-3. Queue Depth (store-and-forward 큐 최대 깊이)

| 항목 | 값 |
|---|---|
| WS 단절 구간 시작 시각 |  |
| WS 단절 구간 종료 시각 |  |
| 단절 구간 동안 큐에 적재된 최대 GPS 페이로드 수 |  |
| 재연결 후 flush 완료 여부 |  |
| CSV에 flush된 레코드가 타임스탬프 순으로 기록됐는지 여부 |  |
| 합격 기준 | flush 완료 + 타임스탬프 순 정렬 |
| 판정 | PASS / FAIL |

### 3-4. GPS Freshness (GPS 최신성)

| 항목 | 값 |
|---|---|
| 마지막 GPS 이벤트 시각 (UTC) |  |
| 세션 종료 시각 (UTC) |  |
| **GPS 신선도 지연 (초)** | `종료시각 − 마지막GPS시각` |
| `bg_state` 컬럼의 `background` 비율 (%) |  |
| 합격 기준 | 지연 ≤ 300초(5분), `background` 레코드 존재 |
| 판정 | PASS / FAIL |

## 4. 로그 추출 체크리스트

- [ ] `server/logs/gps_<session>.csv` 파일 확보
- [ ] `server/logs/events_<session>.csv` 파일 확보
- [ ] CSV 첫 행/마지막 행 타임스탬프 기록 (세션 시작·종료 확인)
- [ ] `bg_state` 컬럼에 `background` 값이 존재하는지 확인
- [ ] `source` 컬럼이 `ios-rn` (또는 해당 플랫폼 식별자)인지 확인
- [ ] `os`, `app_ver`, `device` 컬럼 값 확인
- [ ] 총 행 수 기록 → 섹션 3-1에 입력
- [ ] 단절 구간 확인 (타임스탬프 갭 > 30초인 구간 목록)

```python
# 샘플: 타임스탬프 갭 분석
# 필수 컬럼: client_t(epoch seconds), bg_state, source, lat, lon, app_ver, device
import pandas as pd

df = pd.read_csv("server/logs/gps_20260221_143022.csv")
df = df.sort_values("client_t").reset_index(drop=True)
ts = pd.to_datetime(df["client_t"], unit="s", utc=True)
gaps_seconds = ts.diff().dt.total_seconds()
print(gaps_seconds[gaps_seconds > 30])
```

## 5. 종합 판정

| 지표 | 기준 | 실제값 | 판정 |
|---|---|---|---|
| GPS 누락률 | ≤ 20% |  |  |
| WS 재연결 성공률 | 100% |  |  |
| 큐 flush 완료 | Y |  |  |
| GPS 신선도 지연 | ≤ 300초 |  |  |

**최종 결과**: PASS / FAIL

## 6. 이슈 및 조치

| # | 현상 | 재현 절차 | 영향 | 담당 / 기한 |
|---|---|---|---|---|
| 1 |  |  |  |  |

## 7. 다음 단계

- [ ] 이슈 수정 후 재실행 예정 여부:
- [ ] Android 동일 시나리오 실행 예정 여부:
- [ ] 배터리/발열 계측(P3-4) 연계 여부:

## 8. 분석 스크립트 실행 예시

`scripts/analyze_ios_bg_session.py` 를 사용하면 GPS CSV를 즉시 분석할 수 있다.

### 기본 실행 (GPS CSV 만)

```bash
python3 scripts/analyze_ios_bg_session.py \
  --gps-csv server/logs/gps_20260221_143022.csv
```

### 이벤트 CSV 포함, 갭 임계값 60초로 지정

```bash
python3 scripts/analyze_ios_bg_session.py \
  --gps-csv server/logs/gps_20260221_143022.csv \
  --events-csv server/logs/events_20260221_143022.csv \
  --gap-threshold-sec 60
```

### 출력 예시

```
=== GPS CSV Analysis: server/logs/gps_20260221_143022.csv ===
Record count : 142
bg_state distribution:
  background: 130 (91.5%)
  foreground: 12 (8.5%)

Gaps > 30s: 2
  1740141900 → 1740141945  (45.0s)
  1740142300 → 1740142350  (50.0s)

Freshness (now − last client_t): 87.3s

=== Events CSV Analysis: server/logs/events_20260221_143022.csv ===
Event record count: 8
event_type distribution:
  ws_reconnect: 5
  app_background: 3
```

### 도움말

```bash
python3 scripts/analyze_ios_bg_session.py --help
```
