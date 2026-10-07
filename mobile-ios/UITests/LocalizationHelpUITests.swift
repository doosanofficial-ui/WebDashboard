import XCTest

/// New, pre-seeded Simulator only. No vehicle acquisition or recording control is tapped.
final class LocalizationHelpUITests: XCTestCase {
    private func tab(_ app:XCUIApplication,_ en:String,_ ko:String,_ language:String) {
        let button=app.tabBars.buttons[language=="ko" ? ko:en]
        XCTAssertTrue(button.waitForExistence(timeout:8),app.debugDescription);button.tap()
    }
    private func reveal(_ element:XCUIElement,in app:XCUIApplication) {
        for _ in 0..<12 {
            if element.exists && element.isHittable {return}
            app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable,app.debugDescription)
    }
    private func top(_ app:XCUIApplication) {for _ in 0..<5 {app.swipeDown()}}
    private func capture(_ app:XCUIApplication,_ guide:String,_ language:String,_ number:Int,_ element:XCUIElement) {
        reveal(element,in:app)
        let window=app.windows.firstMatch
        let frame=element.frame
        XCTAssertTrue(window.frame.contains(frame),"Numbered target must be wholly inside the actual screenshot: \(frame)")
        let name="Help-\(guide)-\(language)-\(number)"
        let screenshot=XCTAttachment(screenshot:window.screenshot());screenshot.name=name;screenshot.lifetime = .keepAlways;add(screenshot)
        let marker:[[String:Any]]=[["number":number,"x":(frame.midX-window.frame.minX)/window.frame.width,"y":(frame.midY-window.frame.minY)/window.frame.height]]
        let data=try! JSONSerialization.data(withJSONObject:marker,options:[.sortedKeys])
        let metadata=XCTAttachment(data:data,uniformTypeIdentifier:"public.json");metadata.name=name+"-markers";metadata.lifetime = .keepAlways;add(metadata)
        let tree=XCTAttachment(string:app.debugDescription);tree.name=name+"-AX";tree.lifetime = .keepAlways;add(tree)
    }
    private func captureScreens(_ language:String) {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--app-language",language,"--audit-ui-layout"]
        app.launch();XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["toggle-recording"].waitForExistence(timeout:10))
        XCTAssertEqual(app.buttons["toggle-recording"].value as? String,language=="ko" ? "기록 꺼짐":"Recording off")
        XCTAssertEqual(app.buttons["toggle-gps"].value as? String,language=="ko" ? "GPS 꺼짐":"GPS off")
        capture(app,"live",language,1,app.buttons["toggle-recording"])
        capture(app,"live",language,2,app.buttons["toggle-gps"])
        capture(app,"live",language,3,app.buttons["mark-event"])
        app.buttons["edit-dashboard"].tap()
        let card=app.otherElements["editor-widget-fixture-0"];reveal(card,in:app);card.tap()
        XCTAssertTrue(app.buttons["resize-dashboard-widget-fixture-0"].waitForExistence(timeout:5))
        capture(app,"editor",language,1,app.buttons["resize-dashboard-widget-fixture-0"])
        capture(app,"editor",language,2,app.buttons["undo-dashboard-layout"])
        app.buttons[language=="ko" ? "완료":"Done"].tap()
        tab(app,"Setup","설정",language)
        capture(app,"setup",language,1,app.buttons["import-adapter-profile"])
        let developer=app.buttons.matching(NSPredicate(format:"label == %@",language=="ko" ? "개발자 / 진단":"Developer / diagnostics")).firstMatch
        reveal(developer,in:app);developer.tap()
        capture(app,"setup",language,2,app.buttons["start-live-adapter"])
        tab(app,"Sessions","기록",language)
        let picker=app.buttons["saved-session-picker"];reveal(picker,in:app);picker.tap()
        let fixture=app.buttons["saved-session-offline-seek-fixture"]
        XCTAssertTrue(fixture.waitForExistence(timeout:5));fixture.tap()
        capture(app,"sessions",language,1,picker)
        capture(app,"sessions",language,2,app.buttons["sessions-export-json"])
        top(app)
        capture(app,"sessions",language,3,app.buttons["replay-saved-session"])
        let open=app.buttons["replay-saved-session"];reveal(open,in:app);open.tap()
        XCTAssertTrue(app.buttons["session-replay-play"].waitForExistence(timeout:8))
        let start=app.buttons["replay-seek-start"];reveal(start,in:app);start.tap()
        top(app);capture(app,"replay",language,1,app.buttons["session-replay-play"])
        capture(app,"replay",language,2,app.sliders["replay-time-slider"])
        let end=app.buttons["replay-seek-end"];reveal(end,in:app);end.tap()
        tab(app,"Signals","신호",language)
        capture(app,"signals",language,2,app.buttons["signals-stale-filter"])
        capture(app,"signals",language,1,app.staticTexts["raw-can-content"])
        tab(app,"Sessions","기록",language);app.buttons["stop-replay-header"].tap()
        tab(app,"Live","실시간",language)
        XCTAssertEqual(app.buttons["toggle-recording"].value as? String,language=="ko" ? "기록 꺼짐":"Recording off")
        XCTAssertEqual(app.buttons["toggle-gps"].value as? String,language=="ko" ? "GPS 꺼짐":"GPS off")
        app.terminate()
    }
    func testCaptureEnglishGuideScreens() {captureScreens("en")}
    func testCaptureKoreanGuideScreens() {captureScreens("ko")}

    func testLanguageSwitchPersistsAndHelpPreservesReplay() {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--app-language","en","--audit-ui-layout"]
        app.launch();tab(app,"Sessions","기록","en")
        let picker=app.buttons["saved-session-picker"];reveal(picker,in:app);picker.tap()
        app.buttons["saved-session-offline-seek-fixture"].tap();app.buttons["replay-saved-session"].tap()
        XCTAssertTrue(app.staticTexts["session-replay-position"].waitForExistence(timeout:8))
        XCTAssertEqual(app.staticTexts["session-replay-position"].value as? String,"5.0 of 5.0 seconds")
        tab(app,"Help","도움말","en")
        let language=app.segmentedControls["app-language-picker"]
        XCTAssertTrue(language.waitForExistence(timeout:5));language.buttons["한국어"].tap()
        XCTAssertTrue(app.navigationBars["도움말"].waitForExistence(timeout:5))
        let guide=app.buttons["help-guide-live"];XCTAssertTrue(guide.waitForExistence(timeout:5));guide.tap()
        XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"help-image-live").firstMatch.waitForExistence(timeout:5),"Actual Korean screenshot must be bundled")
        XCTAssertTrue(app.staticTexts["help-step-progress"].isHittable)
        let readyKorean=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in app.buttons["help-next"].isHittable && !app.navigationBars.buttons.firstMatch.identifier.isEmpty },object:app)
        XCTAssertEqual(XCTWaiter.wait(for:[readyKorean],timeout:5),.completed)
        // Screenshot only after SwiftUI navigation has settled through an explicit UI query.
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format:"label CONTAINS %@","정상 결과:")).firstMatch.isHittable)
        let shot=XCTAttachment(screenshot:app.windows.firstMatch.screenshot());shot.name="App-help-Korean-live";shot.lifetime = .keepAlways;add(shot)
        let next=app.buttons["help-next"];reveal(next,in:app);next.tap()
        XCTAssertEqual(app.staticTexts["help-step-progress"].label,"3단계 중 2단계")
        app.navigationBars.buttons.firstMatch.tap()
        tab(app,"Sessions","기록","ko")
        XCTAssertEqual(app.staticTexts["session-replay-position"].value as? String,"전체 5.0초 중 5.0초")
        XCTAssertFalse(app.buttons["session-replay-play"].isEnabled)
        app.terminate();app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_US"];app.launch()
        XCTAssertTrue(app.tabBars.buttons["도움말"].waitForExistence(timeout:8),"Saved choice must win over system English after relaunch")
        tab(app,"Help","도움말","ko");app.segmentedControls["app-language-picker"].buttons["English"].tap()
        XCTAssertTrue(app.navigationBars["Help"].waitForExistence(timeout:5))
        app.buttons["help-guide-live"].tap();XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"help-image-live").firstMatch.exists)
        XCTAssertTrue(app.staticTexts["help-step-progress"].isHittable)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format:"label CONTAINS %@","Expected:")).firstMatch.isHittable)
        app.buttons["help-next"].tap();app.buttons["help-previous"].tap()
        XCTAssertEqual(app.staticTexts["help-step-progress"].label,"Step 1 of 3")
        let english=XCTAttachment(screenshot:app.windows.firstMatch.screenshot());english.name="App-help-English-live";english.lifetime = .keepAlways;add(english)
        app.terminate();app.launch()
        XCTAssertTrue(app.tabBars.buttons["Help"].waitForExistence(timeout:8),"English choice persists too")
        app.terminate()
    }

    func testKoreanHelpAtMaximumTextAndLandscape() {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--app-language","ko","-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryAccessibilityXXXL"]
        XCUIDevice.shared.orientation = .portrait;defer {XCUIDevice.shared.orientation = .portrait}
        app.launch();tab(app,"Help","도움말","ko")
        let guide=app.buttons["help-guide-live"];reveal(guide,in:app);guide.tap()
        XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"help-image-live").firstMatch.waitForExistence(timeout:5))
        let zoom=app.buttons["help-enlarge-screenshot"];reveal(zoom,in:app);zoom.tap()
        let slider=app.sliders.firstMatch;XCTAssertTrue(slider.waitForExistence(timeout:5));slider.adjust(toNormalizedSliderPosition:0.5)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["완료"].waitForExistence(timeout:5));XCTAssertTrue(app.buttons["완료"].isHittable)
        let shot=XCTAttachment(screenshot:app.windows.firstMatch.screenshot());shot.name="App-help-Korean-AX5-landscape-zoom";shot.lifetime = .keepAlways;add(shot)
        app.buttons["완료"].tap();let next=app.buttons["help-next"];reveal(next,in:app);next.tap()
        XCTAssertEqual(app.staticTexts["help-step-progress"].label,"3단계 중 2단계")
        app.terminate()
    }
    func testEveryGuideAtMaximumTextShowsWholeNumberedImageAndClosesZoomInBothLanguages() {
        continueAfterFailure=false
        XCUIDevice.shared.orientation = .portrait
        defer {XCUIDevice.shared.orientation = .portrait}
        let guides:[(String,Int)]=[("setup",2),("live",3),("signals",2),("sessions",3),("replay",2),("editor",2)]
        for language in ["en","ko"] {
            let app=XCUIApplication()
            app.launchArguments=["--app-language",language,"-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryAccessibilityXXXL"]
            app.launch();tab(app,"Help","도움말",language)
            for (guide,count) in guides {
                let card=app.buttons["help-guide-"+guide];reveal(card,in:app);card.tap()
                for step in 1...count {
                    let progress=app.staticTexts["help-step-progress"]
                    XCTAssertTrue(progress.waitForExistence(timeout:5))
                    XCTAssertEqual(progress.label,language=="ko" ? "\(count)단계 중 \(step)단계":"Step \(step) of \(count)")
                    let image=app.descendants(matching:.any).matching(identifier:"help-image-"+guide).firstMatch
                    let enlarge=app.buttons["help-enlarge-screenshot"]
                    for _ in 0..<32 {
                        if image.exists {
                            let imageFrame=image.frame
                            if imageFrame.minY>app.navigationBars.firstMatch.frame.maxY && imageFrame.maxY<app.buttons["help-next"].frame.minY {break}
                        }
                        app.swipeUp()
                    }
                    XCTAssertTrue(image.exists,"Actual screenshot must be bundled for every step")
                    let imageFrame=image.frame
                    XCTAssertGreaterThan(imageFrame.minY,app.navigationBars.firstMatch.frame.maxY)
                    XCTAssertLessThan(imageFrame.maxY,app.buttons["help-next"].frame.minY,"Full numbered image must be above the fixed navigation controls")
                    XCTAssertTrue(app.windows.firstMatch.frame.contains(imageFrame))
                    let shot=XCTAttachment(screenshot:app.windows.firstMatch.screenshot())
                    shot.name="App-help-\(language)-\(guide)-step\(step)-AX5-numbered";shot.lifetime = .keepAlways;add(shot)
                    if step==1 || step==count {
                        XCTAssertTrue(enlarge.isHittable);enlarge.tap()
                        let zoom=app.sliders.firstMatch;XCTAssertTrue(zoom.waitForExistence(timeout:5));XCTAssertTrue(zoom.isHittable)
                        zoom.adjust(toNormalizedSliderPosition:0.5)
                        XCUIDevice.shared.orientation = .landscapeLeft
                        let done=app.buttons[language=="ko" ? "완료":"Done"]
                        XCTAssertTrue(done.waitForExistence(timeout:5));XCTAssertTrue(done.isHittable)
                        let zoomShot=XCTAttachment(screenshot:app.windows.firstMatch.screenshot())
                        zoomShot.name="App-help-\(language)-\(guide)-step\(step)-AX5-landscape-zoom";zoomShot.lifetime = .keepAlways;add(zoomShot)
                        done.tap();XCUIDevice.shared.orientation = .portrait
                    }
                    if step<count {app.buttons["help-next"].tap()}
                }
                app.navigationBars.buttons.firstMatch.tap()
            }
            app.terminate()
        }
    }

}
