import XCTest

final class DownloadKeyboardUITests: XCTestCase {
    @MainActor
    func testDismissKeyboardKeepsLinkAndSetupIsActionable() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"]
        app.launch()
        let tab = app.buttons["下載"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()

        let field = app.descendants(matching: .any).matching(identifier: "downloadLink").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let source = "https://youtu.be/keyboard-fixture?x=1&y=2"
        field.typeText(source)
        let close = app.buttons["dismissDownloadKeyboard"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertTrue(close.isHittable)
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "Download-keyboard-visible"
        before.lifetime = .keepAlways
        add(before)
        close.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, source)

        // Reopen and exercise the accessory when available. The inline close
        // remains available even when a keyboard/provider omits the accessory.
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let accessory = app.buttons["dismissDownloadKeyboardAccessory"]
        if accessory.waitForExistence(timeout: 2) { accessory.tap() }
        else { app.buttons["dismissDownloadKeyboard"].tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, source)
        let after = XCTAttachment(screenshot: app.screenshot())
        after.name = "Download-keyboard-dismissed"
        after.lifetime = .keepAlways
        add(after)

        let action = app.buttons["downloadPrimaryAction"]
        XCTAssertTrue(action.isEnabled)
        XCTAssertTrue(action.label.contains("先完成下載設定"))
        action.tap()
        XCTAssertTrue(app.navigationBars["免費下載設定"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["1. 授權下載交接資料夾"].exists)
        XCTAssertTrue(app.buttons["2. 安裝／更新解析元件並檢查 FFmpeg"].exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
    }
}
