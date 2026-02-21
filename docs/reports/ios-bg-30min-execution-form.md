# iOS 30-Min Background Run Form (Operator Sheet)

이 문서는 **실측 실행 중 바로 체크/기록**하기 위한 운영용 폼이다.  
최종 정리본은 `docs/reports/ios-bg-30min-template.md`에 반영한다.

## 0) 기본 정보

- 실행 일시(UTC):
- 테스터:
- 디바이스(iPhone/iPad 모델):
- iOS 버전:
- 앱 버전(`app_ver`):
- Git SHA:
- 서버 호스트/IP:
- 네트워크(Wi-Fi/Hotspot):
- 배터리 시작(%):

## 1) 사전 체크 (실행 전)

- [ ] `docs/reports/ios-preflight-smoke-2026-02-22.md` 확인 (preflight PASS)
- [ ] iOS 위치 권한 `Always` 설정 확인
- [ ] Xcode Capabilities: `Background Modes > Location updates` 확인
- [ ] 서버 실행: `cd server && HOST=0.0.0.0 python app.py`
- [ ] iPhone에서 서버 접속 및 Connect 확인
- [ ] iPhone에서 Start GPS 후 foreground 30초 정상 수신 확인

## 2) 타임라인 기록

- T0 (foreground 시작 시각, UTC):
- T1 (화면 OFF/잠금 시각, UTC):
- T2 (선택: 단절 시뮬레이션 시각, UTC):
- T3 (30분 종료/foreground 복귀 시각, UTC):
- 비고:

## 3) 실행 체크

- [ ] WS 상태가 연결됨으로 표시됨
- [ ] GPS 값(lat/lon/speed/accuracy) 갱신 확인
- [ ] 화면 잠금 후 백그라운드 유지 30분
- [ ] (선택) 15분 경과 시 네트워크/서버 단절 시뮬레이션
- [ ] 복귀 후 WS 재연결 및 데이터 재수신 확인
- [ ] MARK 1회 이상 전송

## 4) 로그 수집 (서버)

```bash
ls -lah server/logs/gps_*.csv server/logs/events_*.csv server/logs/can_*.csv | tail -n 20
```

- 세션 ID(`YYYYMMDD_HHMMSS`):
- GPS CSV:
- Events CSV:
- CAN CSV:

## 5) 자동 분석 결과 붙여넣기

```bash
python3 scripts/analyze_ios_bg_session.py \
  --gps-csv server/logs/gps_<session>.csv \
  --events-csv server/logs/events_<session>.csv
```

분석 출력(원문 붙여넣기):

```text
<paste output>
```

## 6) 핵심 지표 계산

- GPS 누락률(%):
- WS 재연결 성공률(%):
- 큐 flush 완료(Y/N):
- GPS 신선도 지연(초):
- `bg_state=background` 레코드 존재(Y/N):

## 7) 판정

- 최종 판정(PASS/FAIL):
- 주요 이슈:
- 재현 절차:
- 조치 계획(담당/기한):

## 8) 최종 반영 체크

- [ ] `docs/reports/ios-bg-30min-template.md`에 지표/판정 반영
- [ ] `docs/e2e-platform-checklist.md` iOS 30분 항목 체크
- [ ] `docs/reports/p3-3-next-actions-2026-02-21.md` 상태 업데이트
