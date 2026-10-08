# 실행 전 가설·수용 기준

원본 c82c3b0 CSV의 38.765초는 호출 시작→마지막 idle 대기 시작이다. 실제 touch 전달 시간 또는 함수 반환 시간으로 해석하지 않는다.

가설: (A) XCTest 입력 호출이 반환하지 못함, (B) 입력 호출은 반환했지만 native interactive dismissal이 완료되지 않음, (C) presented가 false로 바뀐 뒤 다시 표시됨. B는 영상의 내려갔다 되돌아오는 관측과 같은 요청 ID/표시 전이를 함께 평가한다. C는 기존/새 요청과 state-owner ID로 구분한다. 실제 touch 전달 시각은 XCTest가 제공하지 않으므로 미계측으로 보고한다.

범위: DEBUG Simulator의 명시적 audit 인자와 검증된 synthetic fixture marker를 모두 요구한다. payload, 세션 ID, GPS, 차량 데이터, 파일 URL, 오류 문자열, 인증정보는 기록하지 않는다. 사용자 변경/mobile/·실기기·다른 Simulator는 제외한다.

수용: 원래 normalized CSV drag/hold/default velocity, 닫힘 조건과 5초 한도, 부팅 180초 한도, 31-test CI partition을 보존한다. 기존 AX 조회만 감싸서 start/return/result를 기록하고 입력 호출 start/return을 기록한다. 테스트 trace는 메모리에서 수집하고 JSON attachment는 wait 뒤 기록하며 optional 관측 실패가 기존 실패/종료코드를 덮지 않는다. runner heartbeat는 외부 프로세스·디스크 기록 없이 낮은 빈도로 메모리에 수집한다.

검증: fixture admission 거부/허용, bounded trace·개인정보 whitelist·old/new request 구별, optional 수거 실패 및 원래 실패 보존, 독립 read-only review, Python 회귀·docs 검증·hosted export 회귀·원본 Simulator UI 시험. 통과한 계측만 canonical main에서 commit/push한다. push로 생기는 새 SHA CI attempt1만 끝까지 회수하고 재실행하지 않는다. 재현되지 않거나 boot에서 차단되면 cause 미확정으로 증거를 보존한다.


## 계측 경계와 해석 한계

생산 `App/` 소스와 기존 도움말 캡처의 소스 해시는 유지한다. runner가 생성한 임시 fixture 소스에만 정확히 한 번 일치하는 경계를 변환하고 입력·변환 후 SHA-256을 기록한다. `EXPORT_DISMISSAL_AUDIT_FIXTURE` 조건은 staged Debug Simulator build/test에만 전달한다. canonical hosted spec의 기존 89개 테스트는 계측 심볼 없이 컴파일되고, staged hosted 실행은 계측 admission·stale callback·상한 회귀 3개를 더한 92개를 요구한다.

audit는 launch 인자와 합성 marker가 모두 있어야 켜진다. marker와 trace는 측정 저장소와 별개인 `Library/Application Support/ExportDismissalAudit`에 둔다. UI 시험의 앱 업데이트로 data-container 경로가 바뀔 수 있으므로, 원래 시험 판정 후 collector가 runner-created Simulator UUID에 대해서만 현재 Telemetry data container를 다시 조회한다. 이 조회의 2초 제한은 기존 5초 collector child 실행 예산 안에 포함된다. container/admission/trace-read/validation/copy 단계와 오류 유형만 기록하며 경로·오류 본문은 별도 수거 receipt에 남기지 않는다. 5초는 child completion 예산이며 process-group 정리와 receipt 쓰기를 포함한 전체 경과 시간과 동일하지 않다.

앱은 caller에서 UUID·불변 상태·시계를 포착하고 serial utility queue로 전달한다. trace는 128행/64KiB 상한이고 관측 완료 flush를 시험 흐름에 추가하지 않는다. 누락·I/O 오류·부분 write·종료 시 async tail은 가능하므로 없는 행을 callback 부재나 false 전이 부재의 증거로 사용하지 않는다. XCTest의 호출 start/return은 공개 입력 API 경계이며 실제 touch 전달·native completion 시각은 미계측이다. app/test clock의 관계도 저장된 epoch/uptime 쌍으로 확인해야 한다.

runner heartbeat는 5초 간격의 메모리 clock/load-average 표본이다. CPU 사용률·AX 응답·native sheet 응답을 직접 재지 않는다. 입력 전후 print와 wait 후 JSON attachment, 앱의 queue 제출에는 관측 오버헤드가 있으며 무영향이라고 주장하지 않는다. 원래 drag, OR 단락 조회 순서, 5초 실패 판정과 180초 boot budget은 유지한다. 원래 실패 객체와 shutdown/delete/finalize는 optional collector timeout에서도 보존하는 main 통합 회귀로 확인한다.

초기 로컬 원본 UI 시험은 1/1 통과했으나 trace 수거가 FileNotFoundError로 끝났다. 당시 세부 단계는 없어 marker 삭제·container 이동·trace 미생성 중 무엇인지는 미확정이다. 최종 staged 경계와 수거는 별도 로컬 검증으로 확인하고, 원래 CSV 실패가 재현되지 않으면 세 원인 가설 중 어느 것도 확정하지 않는다.

앱 audit의 비동기 append는 입력·predicate 실행과 병행될 수 있다. 입력 actor의 동기 파일 쓰기를 피한다는 경계이며, 전체 시험 중 디스크 I/O가 없다는 뜻은 아니다.
