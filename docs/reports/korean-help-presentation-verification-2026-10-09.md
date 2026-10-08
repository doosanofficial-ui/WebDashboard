# Korean 표시와 Help 전체 삽화 검증

Source는 canonical `main`의 `8ddb12e1b80dd4831911f50a3d4e75517c0a2529`에 아래 관련 변경을 적용한 candidate다. 각 실행의 실제 App/UITest/LifecycleTest SHA-256은 `*-source-inputs.json`에 보존했으며 실행 전후 동일했다. 검증 날짜는 2026-10-08 UTC / 2026-10-09 KST다. 이전 24c 및 8ddb 원격 실패 원인과 이번 표시 수정을 구분한다.

## 문제와 변경

- Sessions GPS 표시가 번역 전에 uppercase돼 한국어 key를 놓쳤다. 표시 경계에서 번역한 뒤 uppercase하며 원래 model 상태를 유지한다.
- Replay `End` key를 EN/KO에 추가했다. 빈 기록의 `no unit`과 `multiple units` 표시 fallback을 번역하되 실제 저장 단위는 그대로 쓴다.
- Specific recorded-seconds template이 generic seconds보다 먼저 매칭되도록 순서만 바꿨다. `기록 시간 2.5 / 5.0초`와 일반 `2.5 / 5.0초`를 구분하며 원본 값·이름·단위·CSV/JSON을 바꾸지 않는다.
- 기존 최대 글자 UI 검사는 삽화의 끝을 Next button의 시작과만 비교했다. Previous와 padding을 포함한 footer 시작보다 아래에서도 조기 완료할 수 있었다. 완전한 footer의 accessibility container를 식별하고 내용 영역 안의 짧은 양방향 drag 뒤 전체 image bounds를 엄격히 확인한다. 기존32회 한계와 boot60/180·build600·UI1200초 예산 및 testcase 선택을 유지한다. 제품 scroll/layout 변경은 없다.
- 실제 candidate App에서 EN/KO 제품 삽화28개를 다시 촬영해 원본 PNG, target marker 및 manifest를 갱신했다. 바이트·소스·marker·출처 검사를 통과했다. 기존 asset 원본은 로컬에 보존했다.

## 실제 검증

| 검사 | 실제 결과 | 환경과 한계 |
| --- | --- | --- |
| 실제 AppLocalization 컴파일 fixture | 6항목, RED2 → GREEN0실패 | End와 recorded-seconds가 원래 소스에서 실패. 최초 sandbox compiler 접근 오류는 제품 RED로 계산하지 않았다 |
| EN/KO 제품 삽화 capture | 2PASS/0FAIL/0skip | 새 소유 iPhone17, iOS27.0/24A434, Xcode27.0/27A266a, 합성 기록 |
| 최대 글자 EN | 1PASS/0FAIL/0skip | 520.750초 testcase, 번호 삽화14 및 가로 확대12 촬영 |
| 최대 글자 KO | 원래 XCTest1PASS/0FAIL/0skip | 461.909초 testcase. 원래 실행 연결 종료 뒤 official xcresult summary·첨부 내보내기·소유 정리만 복구했다. 재시험하지 않았다. 원래 runner 최종 exit 및 collector final receipt는 미수집이며 성공으로 만들어 쓰지 않았다 |
| Help 언어 선택·Replay 상태 보존 및 KO 확대/회전 | 2PASS/0FAIL/0skip | 기존2개 testcase. 선택·재실행 persistence와 Help 후 Replay 시간을 확인 |
| 실제 App/SQLite Hosted XCTest | 92PASS/0FAIL/0skip | 새 소유 iPhone11, iOS27.0/24A434. 기존900초 제한, source불변 및 소유 shutdown/delete 확인 |
| script 회귀 | 169PASS | synthetic script contracts; 실제 UI31개 통과 증거로 계산하지 않는다 |
| 문서 parity·Help28 출처·scoped diff | PASS | 사용자45파일 hash와 기존 mobile/ 수정 보존; 관련 파일만 통합 |

각 UI/Hosted 실행은 소유 UUID만 정상 shutdown/delete했다. 기존 Simulator와 실제 iPhone을 조작하지 않았다. KO 복구 시 원래 로그 subscriber는 없었으며 과거 collector 정리 시각·신호·exit를 소급해서 추정하지 않는다.

## 직접 원본 픽셀 검토

ROOT가 제품 삽화28, 최대 글자52, 상태 보존 본문/확대3의 원본83개 **파일**을 모두 image-viewing 도구로 직접 열었다. 동일 화면 bytes가 있는 별도 marker 파일들을 독립 사건 관측으로 계산하지 않는다. 전체 row별 원본·SHA·시각·환경·관찰은 로컬 `product-direct-visual-review.json`, `help-direct-visual-review.md/json`, `help-preservation-direct-review.json`에 보존했다.

- EN/KO 각14단계의 번호 삽화는 상단 navigation chrome과 완전한 padded footer 사이에 온전히 보인다. 이전 EN Live1 하단과 Signals2 삽화의 tab bar도 보인다. Next/Previous는 EN에서 각 한 줄로 세로 배치, KO에서는 한 줄씩 가로 배치다. 첫/끝 단계의 disabled 상태는 위치와 맞는다.
- KO 제품 Sessions의 `수집 안 함`, Replay의 `끝`, `기록 시간 …초`, `단위 없음`이 보인다. raw signal 이름·`percent`·진단 bytes·의도된 debug `large`도 유지된다.
- EN Sessions 세로 title과 EN 확대 label의 ellipsis는 남는다. 본문은 스크롤된 위치이므로 모든 설명을 동시에 보여 준다는 검증이 아니다. 제품 삽화 내부의 원래 페이지 일부는 자체 chrome 아래나 viewport 밖에 이어진다.
- 가로 확대24장의 Done/완료·slider는 보이나 확대된 그림은 상단 clock viewport만 보여 준다. 전체 확대 그림 pan·행동 문구 가독성으로 통과 범위를 확대하지 않는다. 별도 EN/KO Live 첫 단계 본문의 지시·정상 결과·실패 안내는 읽힌다.

원본 core와 검토 기록을 부모에게 제공하며, 부모의 직접 core 열람은 별도 대기 항목이다. 부모가 원본을 열기 전 전체 UI 검증 완료로 보고하지 않는다. 실제 폰 UI·CAN/GPS/BLE·실차 시험은 미검증이다.

## 원격 CI와 실기기 범위

2026-10-08 23:01 UTC에 확인한 8ddb 첫 Native Reliability run37851409267/attempt1에서는 Replay·Route·Help·최대 글자 EN·KO가 앱 빌드 전 bootstatus180초 제한으로 실패했다. Layout은 원본 official summary에서 실제14PASS/0FAIL/0skip이며 소유 정리도 성공했다. EN은 실패 후 shutdown60초 Timeout이나 delete는 성공해 전체 cleanup success=false다. KO는 shutdown/delete 모두 성공했다. Aggregate는 failure이며 SE 별도 첫 job은 진행 중이다. 같은 SHA의 Recording Lifecycle와 smoke는 success다. SE와 최종 workflow는 해당 첫 실행 결과를 계속 확인하며 이 시각의 미완료 상태를 성공으로 소급하지 않는다. 모든 그룹 성공이나 부팅 원인 해결을 주장하지 않는다. 그룹 partition unit fixture의 `31-PASS` 문구는 실제 UI 결과가 아니다. 동일 조건 재시험·timeout 확대·skip·취소를 하지 않았다.

승인한 실제 iPhone 동일 앱 업데이트의 source는 `47148ad8a9896110802ddc7af9eebac074d22dce`, `local.webdashboard.Telemetry` 0.22.4(20)이며 2026-10-08 17:12:35 UTC에 설치 영수증·동일 bundle 목록을 확인했다. 설치 전후 기존27세션·9,321측정행·세션 메타·outbox5,507행과 지속 파일9개의 bytes가 동일했고 두DB quick_check가 ok였다. 이번 candidate 변경을 폰에 설치하지 않았다. 폰 사용·차량 계측 상태는 현재 미확인이다. 실기기 후속 검증에는 사용자가 기존 시험·폰 사용을 마치고 Telemetry를 수동으로 열어 시험 가능한 상태를 알려주는 확인 한 가지가 필요하다. 이미 이행한 설치 승인을 다시 요구하지 않는다.

설치 실행파일을 독립 다운로드해 hash한 것은 아니며 검증된 prepared package와 실제 install receipt가 identity 근거다. 앱 삭제·초기화·실행/강제종료·새 인증·프로비저닝 갱신은 수행하지 않았다. 백업·원시 시스템 로그·실기기 자료는 로컬에 보존하고 외부 업로드하지 않는다.
