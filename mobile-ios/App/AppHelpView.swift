import SwiftUI
import UIKit

struct LanguagePicker: View {
    private var store: AppLanguageStore { .shared }
    var body: some View {
        Picker(AppLocalization.text("Language"), selection: Binding(
            get: { store.language }, set: { store.select($0) })) {
            ForEach(AppLanguage.allCases) { language in
                Text(verbatim: language.nativeName).tag(language)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("app-language-picker")
    }
}

@MainActor struct HelpCopy {
    let en: String
    let ko: String
    var text: String { AppLanguageStore.shared.language == .korean ? ko : en }
}

struct HelpStep: Identifiable {
    let id: String
    let number: Int
    let action: HelpCopy
    let result: HelpCopy
    let recovery: HelpCopy
}

@MainActor struct HelpGuide: Identifiable {
    let id: String
    let title: HelpCopy
    let overview: HelpCopy
    let steps: [HelpStep]
    static let all: [HelpGuide] = [
        .init(id: "setup", title: .init(en: "1. Connect a verified adapter", ko: "1. 검증된 어댑터 연결"),
              overview: .init(en: "Use CAN/manufacturer diagnostics and GPS on your iPhone. No server, account or internet is needed for recording and Replay.", ko: "iPhone에서 CAN·제조사 진단과 GPS를 사용합니다. 기록과 Replay에는 서버·계정·인터넷이 필요하지 않습니다."), steps: [
            .init(id:"import-adapter-profile", number:1, action:.init(en:"Open Setup → Import JSON. Choose your verified adapter profile.",ko:"설정 → JSON 가져오기를 누르고 검증된 어댑터 프로필을 선택하세요."), result:.init(en:"The adapter profile shows LOADED. Check its name and transport.",ko:"어댑터 프로필에 불러옴이 표시됩니다. 이름과 연결 방식을 확인하세요."), recovery:.init(en:"If the profile is missing or rejected, keep the previous profile. Do not guess BLE UUIDs, CAN IDs or commands.",ko:"프로필이 없거나 거부되면 이전 프로필을 보존하세요. BLE UUID·CAN ID·명령을 추측하지 마세요.")),
            .init(id:"start-live-adapter", number:2, action:.init(en:"When safely parked in P, confirm the intended adapter has power and another OBD app is disconnected. Open Setup → Developer / diagnostics, then tap Start live adapter.",ko:"안전하게 정차/P 상태에서 사용할 어댑터의 급전과 다른 OBD 앱의 연결 해제를 확인한 뒤 설정 → 개발자 / 진단을 열고 실차 어댑터 시작을 누르세요."), result:.init(en:"Status changes to diagnostic or live adapter monitoring. This screenshot is synthetic and proves no vehicle connection.",ko:"상태가 진단 또는 실차 어댑터 수집 중으로 바뀝니다. 이 예시 화면은 합성이며 실차 연결 증거가 아닙니다."), recovery:.init(en:"If Bluetooth is off or permission is denied, check the reported condition. Do not reinstall, reset stored data or scan new ECU queries as a workaround.",ko:"Bluetooth 꺼짐이나 권한 거부가 표시되면 해당 상태를 확인하세요. 재설치·데이터 초기화·새 ECU 질의 탐색으로 우회하지 마세요."))]),
        .init(id:"live",title:.init(en:"2. Record, mark and stop",ko:"2. 기록·MARK·정상 중지"),overview:.init(en:"Live shows the selected Dashboard. Recording and GPS have separate controls; connection alone does not save a session.",ko:"실시간 탭에 선택한 Dashboard가 표시됩니다. 기록과 GPS는 별도 버튼이며 연결만으로 기록이 저장되지는 않습니다."),steps:[
            .init(id:"toggle-recording",number:1,action:.init(en:"Tap Start recording in the bottom controls. Use a new local session.",ko:"화면 아래 기록 시작을 눌러 기기에 새 기록을 만드세요."),result:.init(en:"The recording control shows Recording on and elapsed time advances. Keep recording on for steps 2 and 3.",ko:"기록 켜짐과 경과 시간이 표시됩니다. 기록을 계속 켜둔 채 2·3단계를 진행하세요."),recovery:.init(en:"If storage is unavailable or recording fails, stop the test and preserve retained measurements. Replay must be stopped before recording.",ko:"저장소 사용 불가 또는 기록 실패 시 시험을 멈추고 보존된 측정값을 유지하세요. 기록 전 Replay를 종료해야 합니다.")),
            .init(id:"toggle-gps",number:2,action:.init(en:"Tap Start GPS separately if location recording is needed. Allow precise location.",ko:"위치 기록이 필요하면 GPS 시작을 별도로 누르고 정확한 위치를 허용하세요."),result:.init(en:"GPS collecting is separate from recording. No fix means no usable position, not zero coordinates. App switching is supported; screen-lock testing is outside this guide.",ko:"GPS 수집은 기록과 별개입니다. 위치 없음은 유효 위치가 없다는 뜻이며 0 좌표가 아닙니다. 앱 전환은 지원하지만 화면 잠금 시험은 이 안내 범위 밖입니다."),recovery:.init(en:"If no fix is received, check location permission and reception. A cached map is not proof of offline map tiles.",ko:"위치가 없으면 위치 권한과 수신 환경을 확인하세요. 캐시된 지도는 오프라인 지도 타일 지원의 증거가 아닙니다.")),
            .init(id:"mark-event",number:3,action:.init(en:"Tap the flag (Mark) once during recording to mark a moment for later review.",ko:"기록 중 깃발(MARK 표시)을 한 번 눌러 나중에 살펴볼 시점을 표시하세요."),result:.init(en:"Last MARK updates and the original event is saved. When finished, turn GPS off with the step 2 button, then tap Stop recording in the bottom controls.",ko:"마지막 MARK가 갱신되고 원본 이벤트가 저장됩니다. 끝나면 2단계의 GPS 버튼으로 GPS를 끄고 마지막으로 화면 아래 기록 중지를 누르세요."),recovery:.init(en:"If recording is off, MARK does not create a measurement recording. Do not force-close the app to finish a session.",ko:"기록이 꺼져 있으면 MARK로 측정 기록을 만들 수 없습니다. 앱 강제 종료로 기록을 마치지 마세요."))]),
        .init(id:"signals",title:.init(en:"3. Read signal quality and source",ko:"3. 신호 품질과 출처 읽기"),overview:.init(en:"Signals keeps diagnostic responses separate from passive raw CAN. Supported queries vary by vehicle and verified profile.",ko:"신호 탭은 진단 응답과 수동 raw CAN을 구분합니다. 지원 질의는 차량과 검증된 프로필에 따라 달라집니다."),steps:[
            .init(id:"raw-can-content",number:1,action:.init(en:"Check the RAW CAN or DIAGNOSTIC RESPONSE heading and the receive time.",ko:"RAW CAN 또는 진단 응답 제목과 수신 시각을 확인하세요."),result:.init(en:"Diagnostic payloads are query responses, not passive CAN frames. Passive CAN bit view is unavailable for diagnostic responses.",ko:"진단 payload는 질의 응답이며 수동 CAN 프레임이 아닙니다. 진단 응답에서는 수동 CAN 비트 보기를 사용할 수 없습니다."),recovery:.init(en:"NO SAMPLE, INVALID, STALE and valid zero mean different things. A failed or unsupported query must not be interpreted as zero or as a new valid sample.",ko:"표본 없음·잘못된 값·오래된 값·유효한 0은 서로 다릅니다. 실패하거나 미지원인 질의를 0 또는 새 유효 표본으로 해석하지 마세요.")),
            .init(id:"signals-stale-filter",number:2,action:.init(en:"In Signals, tap STALE to show confirmed stale signals. The button changes to ALL; tap ALL to see every signal.",ko:"신호 탭의 오래된 값을 눌러 오래됨이 확인된 신호만 보세요. 버튼이 전체로 바뀌며 전체를 누르면 모든 신호를 봅니다."),result:.init(en:"Replay shows recorded quality and historical freshness separately. Unknown freshness is not proof that a signal was stale.",ko:"Replay는 기록 당시 품질과 당시 신선도를 따로 표시합니다. 신선도 미상은 오래된 값이었다는 증거가 아닙니다."),recovery:.init(en:"If values are missing, check the selected time and profile. Keep raw records; do not invent decoding rules.",ko:"값이 없으면 선택 시간과 프로필을 확인하세요. 원본 기록을 보존하고 해석 규칙을 임의로 만들지 마세요."))]),
        .init(id:"sessions",title:.init(en:"4. Choose and export a recording",ko:"4. 기록 선택과 파일 저장"),overview:.init(en:"Sessions contains local recordings. CSV and JSON preserve original rows and timestamps. Saving is local, with no external upload.",ko:"기록 탭에는 기기 내 기록이 있습니다. CSV와 JSON은 원본 행과 시각을 보존합니다. 외부 업로드 없이 기기에 저장합니다."),steps:[
            .init(id:"saved-session-picker",number:1,action:.init(en:"Tap the saved-session chooser and select a closed session. Refresh if needed.",ko:"저장 기록 선택 버튼을 눌러 종료된 기록을 선택하세요. 필요하면 새로고침하세요."),result:.init(en:"The selected session is shown. A running session must be stopped before loading Replay.",ko:"선택한 기록이 표시됩니다. 진행 중인 기록은 Replay를 열기 전에 중지해야 합니다."),recovery:.init(en:"If the session is unavailable, open or too large, keep it unchanged. Do not delete or overwrite it.",ko:"기록을 사용할 수 없거나 진행 중·너무 큰 상태라면 그대로 보존하세요. 삭제하거나 덮어쓰지 마세요.")),
            .init(id:"sessions-export-json",number:2,action:.init(en:"Tap JSON to open the system Save to Files flow. Choose a new filename; CSV works the same way.",ko:"JSON을 눌러 시스템 파일 저장 화면을 여세요. 새 파일명을 선택하세요. CSV도 같은 방식으로 저장합니다."),result:.init(en:"Wait for save completion. Compare session ID, row count, source, timestamps, units, GPS and MARK. Canceling does not delete the recording.",ko:"저장 완료를 기다리세요. 기록 ID·행 수·출처·시각·단위·GPS·MARK를 비교하세요. 취소해도 원본 기록은 삭제되지 않습니다."),recovery:.init(en:"If saving fails, return to the app and retry after checking local storage. Do not substitute cloud upload for local saving.",ko:"저장에 실패하면 앱으로 돌아와 기기 저장소를 확인한 뒤 다시 시도하세요. 기기 저장을 클라우드 업로드로 대신하지 마세요.")),
            .init(id:"replay-saved-session",number:3,action:.init(en:"After selecting a closed recording, tap Open Replay in Sessions.",ko:"종료된 기록을 선택한 뒤 기록 탭의 Replay 열기를 누르세요."),result:.init(en:"Replay controls appear for the selected recording. Acquisition and new recording remain off.",ko:"선택한 기록의 Replay 제어가 나타납니다. 수집과 새 기록은 꺼진 상태로 유지됩니다."),recovery:.init(en:"If unavailable, finish the running recording normally and select a closed session. Keep the original files.",ko:"사용할 수 없으면 진행 중 기록을 정상 종료하고 종료된 기록을 선택하세요. 원본 파일을 보존하세요."))]),
        .init(id:"replay",title:.init(en:"5. Replay recorded time",ko:"5. 기록 시간 Replay"),overview:.init(en:"Open Replay for the selected recording. Vehicle and GPS acquisition and new recording remain off. The displayed location is recorded, not your current position.",ko:"선택한 기록의 Replay를 여세요. 차량·GPS 수집과 새 기록은 꺼진 상태로 유지됩니다. 표시된 위치는 기록된 위치이며 현재 위치가 아닙니다."),steps:[
            .init(id:"session-replay-play",number:1,action:.init(en:"Tap Play or Pause. Use the speed control to change only replay speed.",ko:"재생 또는 일시정지를 누르세요. 속도 버튼은 Replay 속도만 바꿉니다."),result:.init(en:"Recorded time advances and stops at the end. Pause keeps the selected instant when switching tabs.",ko:"기록 시간이 진행하고 끝에 도달하면 멈춥니다. 일시정지는 탭을 바꿔도 선택 시점을 유지합니다."),recovery:.init(en:"A single recorded instant has no time range. It cannot be played as a long recording.",ko:"한 시점만 기록된 경우 시간 범위가 없습니다. 긴 기록처럼 재생할 수 없습니다.")),
            .init(id:"replay-time-slider",number:2,action:.init(en:"Move the Recorded time slider, or enter Seconds and tap Go. Seek pauses playback.",ko:"기록 시간 슬라이더를 움직이거나 초 값을 입력하고 이동을 누르세요. 시간 탐색은 재생을 일시정지합니다."),result:.init(en:"Signals, graph, route and MARK reflect only the selected recorded prefix. Original values and files do not change.",ko:"신호·그래프·경로·MARK는 선택한 시점까지의 기록만 반영합니다. 원본 값과 파일은 바뀌지 않습니다."),recovery:.init(en:"If freshness is unknown, keep it unknown. Stop Replay to return to Live; acquisition does not automatically restart.",ko:"신선도가 미상이면 미상으로 유지하세요. 실시간으로 돌아가려면 Replay 종료를 누르세요. 수집은 자동 재시작되지 않습니다."))]),
        .init(id:"editor",title:.init(en:"6. Arrange your Dashboard",ko:"6. Dashboard 배치 바꾸기"),overview:.init(en:"Live → Edit opens the Dashboard editor. Changes affect the layout, not recorded measurement rows.",ko:"실시간 → 편집으로 Dashboard 편집기를 여세요. 배치를 바꿔도 기록된 측정 행은 바뀌지 않습니다."),steps:[
            .init(id:"resize-dashboard-widget-fixture-0",number:1,action:.init(en:"Tap a card to select it, then drag the card or the cyan corner. At large text sizes, use the card’s Move or resize actions.",ko:"카드를 눌러 선택한 뒤 카드나 파란 모서리를 드래그하세요. 큰 글자에서는 카드의 이동 또는 크기 변경 동작을 사용하세요."),result:.init(en:"Release to save. The other cards keep their layout. Use Undo if needed.",ko:"손을 떼면 저장합니다. 다른 카드의 배치는 유지됩니다. 필요하면 실행 취소를 누르세요."),recovery:.init(en:"If save fails, keep the profile and use Retry save. Do not reset settings to recover a layout.",ko:"저장에 실패하면 프로필을 보존하고 저장 다시 시도를 누르세요. 배치 복구를 위해 설정을 초기화하지 마세요.")),
            .init(id:"undo-dashboard-layout",number:2,action:.init(en:"Tap Undo or Redo to review an edit. Tap Done to return.",ko:"실행 취소·다시 실행으로 변경을 확인하고 완료를 눌러 돌아가세요."),result:.init(en:"Reopening Edit keeps the saved layout. Large text and landscape have their own measured viewports.",ko:"편집을 다시 열면 저장된 배치가 유지됩니다. 큰 글자와 가로 화면은 실제 표시 영역에 맞춰 동작합니다."),recovery:.init(en:"Do not operate the editor while driving. Stop if a control is unreachable; preserve the layout and report the screen.",ko:"운전 중 편집기를 조작하지 마세요. 버튼에 접근할 수 없으면 멈추고 배치를 보존한 채 화면을 알려주세요."))])
    ]
}

struct AppHelpView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading, spacing:20) {
                    LanguagePicker()
                    Text(HelpCopy(en:"Follow the real app screens",ko:"실제 앱 화면으로 따라하기").text).font(.title2.bold())
                    Text(HelpCopy(en:"These screenshots use synthetic examples, not vehicle measurements or personal GPS. Read the numbered steps before starting acquisition.",ko:"아래 화면은 합성 예시이며 차량 측정값이나 개인 GPS가 아닙니다. 수집을 시작하기 전에 번호별 안내를 읽어보세요.").text)
                        .foregroundStyle(TelemetryTheme.mutedText)
                    ForEach(HelpGuide.all) { guide in
                        NavigationLink {
                            HelpGuideView(guide:guide)
                        } label: {
                            VStack(alignment:.leading,spacing:6) {
                                Text(guide.title.text).font(.headline)
                                Text(guide.overview.text).font(.subheadline).foregroundStyle(TelemetryTheme.mutedText)
                            }.frame(maxWidth:.infinity,alignment:.leading).padding().telemetrySurface(.standard)
                        }.accessibilityIdentifier("help-guide-"+guide.id)
                    }
                    Text(HelpCopy(en:"Help works offline. System Save to Files and permission dialogs follow iOS settings. App language changes only presentation; original records, profile names and units stay unchanged.",ko:"도움말은 오프라인에서 열립니다. 시스템 파일 저장·권한 화면은 iOS 설정을 따릅니다. 앱 언어는 표시만 바꾸며 원본 기록·프로필 이름·단위는 그대로 유지합니다.").text)
                        .font(.footnote).foregroundStyle(TelemetryTheme.mutedText)
                }.padding()
            }
            .background(TelemetryTheme.background.ignoresSafeArea())
            .navigationTitle(AppLocalization.text("Help"))
            .accessibilityIdentifier("app-help-screen")
        }
    }
}

struct HelpGuideView: View {
    let guide: HelpGuide
    @State private var showingFullScreen = false
    @State private var stepIndex = 0
    private var imageName: String { "Help-" + guide.id + "-" + AppLanguageStore.shared.language.rawValue + "-" + String(stepIndex+1) }
    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                Text(guide.overview.text).id("help-guide-top")
                Text(HelpCopy(en:"Step \(stepIndex+1) of \(guide.steps.count)",ko:"\(guide.steps.count)단계 중 \(stepIndex+1)단계").text)
                    .font(.subheadline).accessibilityIdentifier("help-step-progress")
                if let step = guide.steps[safe: stepIndex] {
                    VStack(alignment:.leading,spacing:8) {
                        Text("\(step.number). " + step.action.text).font(.headline)
                        Text(HelpCopy(en:"Expected: ",ko:"정상 결과: ").text + step.result.text)
                        Text(HelpCopy(en:"If it fails: ",ko:"안 되면: ").text + step.recovery.text)
                            .foregroundStyle(TelemetryTheme.mutedText)
                    }.padding().telemetrySurface(.standard).accessibilityElement(children:.combine)
                }
                Button { showingFullScreen=true } label: {
                    VStack(spacing:8) {
                        HelpScreenshot(name:imageName,guide:guide).frame(width:140)
                        Text(HelpCopy(en:"Tap the numbered screen to enlarge",ko:"번호가 있는 화면을 눌러 확대하세요").text).font(.caption)
                    }.frame(maxWidth:.infinity)
                }.buttonStyle(.plain)
                    .accessibilityLabel(HelpCopy(en:"Enlarge real example screenshot",ko:"실제 예시 화면 확대").text)
                    .accessibilityIdentifier("help-enlarge-screenshot")
            }.padding()
        }.background(TelemetryTheme.background.ignoresSafeArea())
            .navigationTitle(guide.title.text).navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge:.bottom) {
                HStack {
                    Button(HelpCopy(en:"Previous",ko:"이전").text) {stepIndex-=1}
                        .disabled(stepIndex==0).accessibilityIdentifier("help-previous")
                    Spacer()
                    Button(HelpCopy(en:"Next",ko:"다음").text) {stepIndex+=1}
                        .disabled(stepIndex==guide.steps.count-1).accessibilityIdentifier("help-next")
                }.buttonStyle(.bordered).frame(minHeight:44)
                .padding().background(TelemetryTheme.surfaceRaised)
            }
            .onChange(of:stepIndex) { _,_ in proxy.scrollTo("help-guide-top",anchor:.top) }
            .sheet(isPresented:$showingFullScreen) {
                HelpScreenshotZoom(name:imageName,guide:guide)
            }
        }
    }
}

private extension Array {
    subscript(safe index:Int) -> Element? {indices.contains(index) ? self[index] : nil}
}

private struct HelpScreenshot: View {
    let name:String
    let guide:HelpGuide
    var body: some View {
        if let image=UIImage(named:name) {
            Image(uiImage:image).resizable().scaledToFit()
                .overlay { HelpMarkers(imageName:name) }
                .accessibilityLabel(guide.title.text + ". " + guide.steps.filter { String($0.number) == name.split(separator:"-").last.map(String.init) }.map { "\($0.number). " + $0.action.text }.joined(separator:" "))
                .accessibilityIdentifier("help-image-"+guide.id)
        } else {
            Text(HelpCopy(en:"Example screenshot unavailable. Follow the text steps.",ko:"예시 화면을 불러올 수 없습니다. 글 안내를 따라주세요.").text)
        }
    }
}

private struct HelpMarker: Decodable { let number:Int; let x:Double; let y:Double }
private struct HelpMarkers: View {
    let imageName:String
    private var markers:[HelpMarker] {
        guard let url=Bundle.main.url(forResource:imageName,withExtension:"json"),let data=try? Data(contentsOf:url) else {return []}
        return (try? JSONDecoder().decode([HelpMarker].self,from:data)) ?? []
    }
    var body:some View {
        GeometryReader { geometry in
            ForEach(markers,id:\.number) { marker in
                Text("\(marker.number)").font(.system(size:15,weight:.bold)).foregroundStyle(.black)
                    .frame(width:26,height:26).background(.yellow,in:Circle())
                    .overlay(Circle().stroke(.black,lineWidth:2))
                    .position(x:geometry.size.width*marker.x,y:geometry.size.height*marker.y)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct HelpScreenshotZoom:View {
    let name:String
    let guide:HelpGuide
    @Environment(\.dismiss) private var dismiss
    @State private var scale=1.0
    var body:some View {
        NavigationStack {
            VStack {
                HStack {
                    Text(HelpCopy(en:"Screenshot zoom",ko:"화면 확대").text)
                    Slider(value:$scale,in:1...3,step:0.25)
                        .accessibilityLabel(HelpCopy(en:"Screenshot zoom",ko:"화면 확대").text)
                }.padding()
                GeometryReader { geometry in
                    ScrollView([.horizontal,.vertical]) {
                        HelpScreenshot(name:name,guide:guide).frame(width:geometry.size.width*scale)
                    }
                }
            }.navigationTitle(guide.title.text).navigationBarTitleDisplayMode(.inline)
                .toolbar {ToolbarItem(placement:.confirmationAction) {Button(AppLocalization.text("Done")) {dismiss()}}}
        }
    }
}
