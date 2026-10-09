# 후속 최소 관측 변경과 a6 Route 실행 — 2026-10-09

이번 변경은 원인 수정이 아니라 관측 추가다. 부팅 원인은 여전히 미상이다.

원래 a6 CI Route에는 두 개의 다른 시간축이 있다.

- 원래 `bootstatus180` 실패 → 정리 요청: **0.164082792초**.
- 그 실패 뒤 시작된 `failure-diagnostic-worker`의 별도20초 예산에서 Timeout 관측 → 정리 요청: **7.702809250초**. 이 중 main caller 진입 전7.702741416초, caller → stop0.000067834초다. worker stop 뒤 최종 phase receipt까지11.199957916초는 또 다른 구간이다.

7.70초를 부팅 시간이나 bootstatus 종료 시간으로 표현하지 않는다. 기존 증거로 Event 통지·스케줄링·main 동기 progress/save 구간을 분리할 수 없었다.

## 좁은 변경과 의미

`scripts/verify_offline_replay.py`의 `run_owned_phase` 한 함수에34줄을 추가했다. 기존 completion Event의 set 호출 전후, main이 Event wait에서 돌아온 시각과 기존 progress/save 호출의 시작·반환을 monotonic으로 기록한다. main이 Event를 관측한 순간의 progress/save 구간은 고정 슬롯에 보존하여 정리 후 마지막 관측이 덮어쓰지 않는다.

`completionBoundaries`는 schema1·고정15필드다. 숫자·null 및 고정 clock 설명만 추가한다. 호출수는65535에 포화된다. 새 probe/thread/process/I/O/환경 덤프를 추가하지 않았고 기존 deadline·판정·Event·signal·reap 순서와 원래 오류를 유지한다. 관측 시계가 실패하면 해당 필드는null로 남고 비밀/오류 문자열을 기록하지 않는다.

관측의 한계:

- 숫자는 호출 경계 관측이다. 실제 kernel exec/exit, Event 전달, readiness 시각을 증명하지 않는다.
- Event.set 직후 main이 깨어나면 main 관측이 set 반환 시각보다 앞설 수 있다. 둘의 순서를 강제하지 않는다.
- 고정 키의 값만 갱신하지만 여러 필드 전체의 원자적 snapshot을 보장하지는 않는다.
- 최종 save는 쓰기 전에 latest return을null로 만든다. 자기 자신의 반환을 같은 파일에 추가 쓰지 않으므로 최종 디스크 receipt의 `saveLatestReturnedMonotonic`은null이다. 지연 비교에는 앞선 완료값을 보존한 `saveAtCompletion*`을 사용한다.
- 최초 Timestamp·Event·main 사이 또는 stop 뒤 남는 스케줄링/기록 시간은 계속 독립적인 공백이다. 부팅 원인 해결이나 전체 정리 지연 제거를 주장하지 않는다.

## device-free 검증

새6개 경계 시험은 변경 전 missing `completionBoundaries`로RED, 변경 후GREEN이다. 실제 새 Python child와 합성 짧은 deadline/gate로 progress 지연·save 지연·Event.set 지연을 각각 구분한다. clock 실패는null·원래 Timeout·정리를 유지하며, 느린 main에도 timely exit0는 성공을 유지한다. 반복40회 관측에서도 고정숫자 필드·2048바이트 이하를 확인한다.

canonical 전체192개 device-free 시험은16.371초에PASS. 기존 Timeout/late-exit/CalledProcessError/원본 snapshot/descendant cleanup/비밀 allowlist/boot payload 시험을 포함했다. boot payload 측정peak1993084바이트로기존2MiB이내다. platform docs parity·git diff check도PASS. 원래20초/180초 CI와 합성0.1초 fixture를 혼동하지 않는다.

별도 보존한3개 fixture의 신규 summary는687/686/689바이트다. progress/save 지연은 Event.set 약25µs·main 관측 약151/162ms 후, notification 지연은 Event.set 약160ms로 분리됐다. 모두 원래Timeout0.1초·exit−15·group gone·waiter stopped를 유지했다. CI의7.70초 자체를 재현했다는 주장은 아니다.

## 07:41 UTC 준비 시점의 기록

기존 완료CI run37877316123/artifact11592896474의 exact a6 Seed를 재사용한다. ZIP digest `51976634dc810988afb81eabd8df51be8e3afa6156b843dcdd80075b35ec8542`, manifest digest `b3f731adaf7f583325ea10b233b15623e214ce3d51fc2c109b854e5aeced3310`을 기존 Route 잡의 별도 producer-output 환경값과 대조했다. CRC 및 manifest/core/fixture source hashes·Mach-O arm64·binary hash·toolchain·producer/fixture receipts·240초 예산의 검증은 실행 없이PASS.

새 Seed 빌드는 필요 없다. 기존 producer50.461807750초, consumer 잔여189.538192250초다. 07:41 UTC 준비 시점에는 Seed 바이너리를 실행하지 않았다.

첫 selector는 `TelemetryUITests/OfflineReplayUITests/testRecordedGPSRouteContainsOnlySelectedTimePrefix` 한 개다. expected actual UI1, zero failures/skips. a6 app 추적 파일206개를freeze했고 app/Core는HEAD와동일하다. canonical runner에는 이번 미커밋 관측 변경이 있어 **a6 app/Seed + candidate observation runner hash**로 구별한다. 변경 전 a6 runner와 완전히 같은 실행이라고 주장하지 않는다. HEAD가 바뀌면 기존 Seed admission이 실패하므로 실행 전 commit/app/runner 해시를 재확인한다.

07:41 UTC에 준비한, 자원 조율 뒤 실행할 명령:

```sh
python3 -B /Users/doosansmacbookpro/Documents/Codex/2026-10-02/task-3/owned-phase-boundaries-20261009/run_prepared_route.py
```

이 wrapper는 main·HEADa6·app추적206개·미추적 파일을 포함한 실제stage 입력 전체·검증 helper 소스·runner·Seed 입력·selector·새 result directory를 다시 대조한 후 준비 JSON의 실제 `verify_offline_replay.py --group replay-route --seed-artifact ... --seed-manifest-sha256 ... --result-directory ...` 명령을 실행한다. canonical runner가 새로 읽은 toolchain으로 Seed admission을 다시 검증한 뒤에만 Simulator를 생성한다. `--boot-only` 같은 미지원 옵션은 사용하지 않는다.

예상 산출물은 seed-consumer/run/fixture/admission, environment/toolchain, boot/bootstatus/stream, build-process, test-process, selection/summary, xcresult와 screenshots, Simulator cleanup이다. bootstrap 실패 시 앱 build/UI로 진행하지 않고 첫 오류·diagnostic 기록과 소유 UUID 정리를 보존한다. 화면 검증이 필요한 경우 실제 screenshot pixels를 별도로 직접 검사하고 부모가 core evidence를 직접 열어야 한다.

07:41 UTC 준비 시점에는 wrapper/UI/Simulator/Xcode/Seed build/실기기 설치와 커밋·push를 실행하지 않았다. 사용자45파일·원래237증거는 최종 보존 검증 대상으로 유지했다. 실기기 앱 실행·종료·인증·프로비저닝 변경 없음.

## 자원 배정 뒤 실제 Route 1회 결과

**실제 XCTest 1개 PASS, 실패·skip 0개, 종료 코드 0.** 원본 xcresult를 다시 읽어 선택자와 실제 case를 확인했다. 한 case가 일반/최대 접근성 글자 크기를 순회하며 원본 PNG 10개를 남겼다.

앱·Seed `a6e07517d9c2a15727c02a325cb5b7176ea48c73`, 미커밋 관측 실행기 `6ff0323a738e79917fdb54a7686a7ad7222d5dc6f944164980d4f03550b00e95` 조합이다. Xcode 27.0/27A266a·SDK 27.0·iOS 27.0/24A434 및 입력/소유권을 실행 직전에 재확인했다. Seed admission·fixture PASS가 Simulator 생성보다 먼저 완료됐다. Producer 50.46180775초를 총 실행 예산 240초에서 차감해 남은 189.53819225초 중 실제 Seed는 0.805840167초를 사용했다. 이는 산출물의 벽시계 나이가 아닌 실행 예산이다.

bootstatus 36.010초, build 45.001초, test phase 206.065초, XCTest case 184.252초. 원본 XCTest 시각은 07:51:12.239–07:54:33.795 UTC이다. 실패/Timeout 없이 새 완료 경계 관측이 저장됐다. 따라서 첫 CI의 7.70초 실패 진단 간극이나 부팅 원인이 해결됐다는 근거는 아니다.

원본 화면 10개를 직접 열어 두 글자 크기의 2→1→0 경로 점/시점과 끝 시점의 필수 품질 안내를 확인했다. 최대 글자 크기 중간·시작의 부가 설명은 Replay 패널 아래로 이어져 전체 가독성/스크롤 도달성은 이 캡처로 미검증이다. 부모 직접 핵심 화면 검수는 아직 NOT REVIEWED이다.

07:55:45 UTC에 소유 Simulator 삭제·collector cleanup·기록 PID 및 PGID 8개 소멸을 확인하여 자원을 반환했다. 이후 추가 Simulator/build/test/실기기 제어 없음. main/HEAD a6와 앱 206개, 사용자 45개, 기존 산출물 237개 해시가 보존됐으며 index는 비어 있다. 기존 관측 패치 3개만 미커밋 상태로 유지했다.

범위는 이 로컬 Route 1개와 직접 본 화면이다. 나머지 Help/SE/한국어 UI, 전체 CI, 원래 boot 실패 원인/안정성, 실기기 UI와 현재 차량 계측은 미완료 또는 미확인으로 남긴다. 기존 `47148ad` 동일 앱 설치 완료 기록은 과거 사실이며 이번 새 설치 결과가 아니다.

근거: `route-ui-result.json`, `route-original-xcresult-tests.json`, `route-original-provenance.json`, `route-ui-visual-review.md`, `route-first-result-resource-release.json`, `route-final-preservation.json`; 원본은 `route-ui-a6e0751-after-resource-coordination/ReplayUI.xcresult`와 `screenshots/`에 보존됐다.

Library 전달: DNS 제한 후 외부 저장 시도에 대한 자동 승인 심사가 거부됐다. 저장소 경로·커밋·시험 정보가 포함된 자료와 ChatGPT Library 목적지에 대한 직접 승인이 없다는 이유이다. 우회나 재시도 없음. 자료 12개 저장 승인 요청 중이며 로컬 검수·원본·자원 반환 확인은 완료됐다.
