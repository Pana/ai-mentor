import XCTest

/// Phase-1 homework round trip on two simulators against a real local server. Run via `scripts/phase1-e2e.sh`,
/// which runs these stages in order (parent iPhone → child iPad → parent → child). Skipped in normal test runs.
final class Phase1E2EUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private var env: [String: String] { ProcessInfo.processInfo.environment }

    private func launch(reset: Bool) throws -> XCUIApplication {
        guard env["E2E_SERVER"] != nil else { throw XCTSkip("Run scripts/phase1-e2e.sh to provide a local server.") }
        let app = XCUIApplication()
        app.launchArguments = (reset ? ["-ui-testing-reset"] : []) + ["-ui-testing-sample-photo"]
        app.launch()
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func replace(_ field: XCUIElement, with text: String) {
        field.waitTap()
        if let current = field.value as? String, !current.isEmpty, current != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(text)
    }

    private func wait(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 15) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), what)
    }

    /// Stage 1 (iPhone): connect as parent, add a child, enter homework.
    func test1ParentConnectsAndEntersHomework() throws {
        let app = try launch(reset: true)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "我是家长")).firstMatch.waitTap()
        replace(app.textFields["服务器地址"], with: env["E2E_SERVER"]!)
        app.secureTextFields["家长密钥"].waitTap()
        app.secureTextFields["家长密钥"].typeText(env["E2E_PARENT_SECRET"]!)
        app.buttons["连接"].waitTap()
        wait(app.navigationBars["作业"], "parent app opened")
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 3) { notNow.tap() }
        shot(app, "p1-empty")

        app.buttons["设置"].waitTap()
        app.buttons["添加孩子"].waitTap()
        app.textFields["昵称"].waitTap()
        app.textFields["昵称"].typeText("林林")
        app.navigationBars["添加孩子"].buttons["保存"].waitTap()
        wait(app.staticTexts["林林"].firstMatch, "child added")
        app.navigationBars["设置"].buttons["完成"].waitTap()

        app.tabBars.buttons["录入"].waitTap()
        let editor = app.textViews.firstMatch
        wait(editor, "paste box")
        editor.waitTap()
        editor.typeText(env["E2E_HOMEWORK_TEXT"] ?? "数学口算本第12页1-20题，明早交。语文背诵《咏柳》，家长签字。")
        app.buttons["完成"].firstMatch.waitTap()
        shot(app, "p2-entry")
        if env["E2E_AI"] == "1" {
            app.buttons["让 AI 整理"].waitTap()
            wait(app.navigationBars["核对作业"], "AI result", timeout: 90)
        } else {
            app.buttons["不用 AI，手动填写"].waitTap()
            wait(app.navigationBars["核对作业"], "manual form")
            let content = app.textFields["作业内容"].firstMatch
            content.waitTap(); content.typeText("口算本第 12 页，第 1–20 题")
            app.buttons["完成"].firstMatch.waitTap()
        }
        shot(app, "p3-result")
        app.navigationBars["核对作业"].buttons["保存"].waitTap()
        wait(app.navigationBars["作业"], "back on the homework list")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '口算'")).firstMatch.waitForExistence(timeout: 10))
        shot(app, "p4-list")
    }

    /// Stage 2 (iPad): pair with the code, find the homework, hand in a photo.
    func test2ChildPairsAndSubmitsPhoto() throws {
        let app = try launch(reset: true)
        XCUIDevice.shared.orientation = .landscapeLeft
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "这是孩子的 iPad")).firstMatch.waitTap()
        replace(app.textFields["服务器地址"], with: env["E2E_SERVER"]!)
        app.textFields["6 位配对码"].waitTap()
        app.textFields["6 位配对码"].typeText(env["E2E_PAIR_CODE"]!)
        app.buttons["连接"].waitTap()
        let me = app.buttons.matching(NSPredicate(format: "label CONTAINS '林林'")).firstMatch
        wait(me, "profile picker", timeout: 30)
        shot(app, "c1-profiles")
        me.waitTap()
        let math = app.buttons.matching(NSPredicate(format: "label CONTAINS '口算'")).firstMatch
        wait(math, "today has the math homework")
        shot(app, "c2-today")
        app.buttons["全部作业"].waitTap()
        shot(app, "c3-all")
        app.buttons["今天"].waitTap()
        math.waitTap()
        app.buttons["写完了，拍照交作业"].waitTap()
        app.buttons["使用示例图片"].waitTap()
        app.buttons["使用整张"].waitTap()
        wait(app.staticTexts["已经拍了 1 页"], "one page")
        shot(app, "c4-submit")
        app.buttons["交给家长批改"].waitTap()
        wait(app.staticTexts["交上了，等家长批改"], "submitted")
        shot(app, "c5-waiting")
    }

    /// Stage 3 (iPhone): grade with a red check, ask for a correction.
    func test3ParentGrades() throws {
        let app = try launch(reset: false)
        let banner = app.buttons.matching(NSPredicate(format: "label CONTAINS '等你批改'")).firstMatch
        wait(banner, "waiting-for-review banner", timeout: 30)
        shot(app, "p5-waiting")
        banner.waitTap()
        app.buttons["开始批改"].waitTap()
        let page = app.images["review-page"]
        wait(page, "submitted photo")
        app.buttons["tool-check"].waitTap()
        XCTAssertTrue(app.buttons["tool-check"].isSelected, "check tool selected")
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        app.buttons["tool-circle"].waitTap()
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.6)).tap()
        shot(app, "p6-annotate")
        app.buttons["下一步：打分"].waitTap()
        app.buttons["良"].waitTap()
        let toggle = app.switches["要求订正后再交"]
        wait(toggle, "correction toggle")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        app.buttons["字很工整"].waitTap()
        XCTAssertTrue(app.staticTexts["已批注"].exists, "annotations were drawn")
        shot(app, "p7-grade")
        app.navigationBars["打分与评语"].buttons["发送"].waitTap()
        wait(app.staticTexts["要求订正后再交"], "review saved")
        shot(app, "p8-reviewed")
    }

    /// Stage 4 (iPad): the correction request and the reward show up.
    func test4ChildSeesFeedback() throws {
        let app = try launch(reset: false)
        XCUIDevice.shared.orientation = .landscapeLeft
        let me = app.buttons.matching(NSPredicate(format: "label CONTAINS '林林'")).firstMatch
        if me.waitForExistence(timeout: 5), app.staticTexts["今天谁来学习？"].exists { me.waitTap() }
        wait(app.staticTexts["要订正"].firstMatch, "correction requested", timeout: 40)
        shot(app, "c6-today-correction")
        app.buttons.matching(NSPredicate(format: "label CONTAINS '口算'")).firstMatch.waitTap()
        wait(app.staticTexts["订正好再交一次"], "feedback view")
        shot(app, "c7-feedback")
        app.buttons["返回"].waitTap()
        app.buttons["奖励时间"].waitTap()
        shot(app, "c8-rewards")
    }
}

extension XCUIElement {
    /// Waits for the element (sheets and pushes animate in) before tapping it.
    func waitTap(timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitForExistence(timeout: timeout), "\(self) did not appear", file: file, line: line)
        tap()
    }
}
