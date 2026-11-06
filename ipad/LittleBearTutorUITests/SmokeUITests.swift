import XCTest

/// Walks the main child flows on a fresh install using the demo family. No network is used.
final class SmokeUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openSidebar(_ app: XCUIApplication, _ title: String) {
        let cell = app.cells.containing(.staticText, identifier: title).firstMatch
        if !cell.waitForExistence(timeout: 2) {
            app.navigationBars.buttons.element(boundBy: 0).tap()   // reveal the sidebar in portrait
        }
        XCTAssertTrue(cell.waitForExistence(timeout: 5), "sidebar item \(title)")
        cell.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), "page \(title) opened")
    }

    func testDemoPracticeAndHomeworkFlow() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-reset"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft

        let demo = app.buttons["先体验示例家庭"]
        if demo.waitForExistence(timeout: 5) { demo.tap() }
        XCTAssertTrue(app.staticTexts["林林，准备好一起探索了吗？"].waitForExistence(timeout: 5))
        shot(app, "1-home")

        openSidebar(app, "练一练")
        XCTAssertTrue(app.buttons["本地基础练习"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["本地基础练习"].firstMatch.tap()
        let field = app.textFields["写下你的答案"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        app.buttons["给我一点提示"].tap()
        XCTAssertTrue(app.staticTexts["已用提示 1/3"].waitForExistence(timeout: 3))
        field.tap(); field.typeText("41")
        app.buttons["我写好了，检查一下"].tap()
        XCTAssertTrue(app.staticTexts["待订正"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["草稿白板"].exists)
        shot(app, "2-exercise")

        openSidebar(app, "我的进步")
        XCTAssertTrue(app.staticTexts["复习安排"].waitForExistence(timeout: 5))
        shot(app, "3-progress")

        openSidebar(app, "我的作业")
        app.staticTexts["小熊的橡果问题"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["问问小熊"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["请家长先在家长设置中开启辅导服务。你仍然可以记录想法并交给家长检查。"].exists)
        app.buttons["我写好了，请家长检查"].tap()
        XCTAssertTrue(app.staticTexts["已经记下啦，等待家长检查。"].waitForExistence(timeout: 3))
        shot(app, "4-homework")
    }
}
