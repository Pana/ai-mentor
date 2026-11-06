import XCTest

/// Full round trip through the real gateway and a mock model. Run via `scripts/ipad-e2e.sh`;
/// skipped in normal test runs because no gateway is configured.
final class GatewayE2EUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func openSidebar(_ app: XCUIApplication, _ title: String) {
        let cell = app.cells.containing(.staticText, identifier: title).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 5), "sidebar item \(title)")
        cell.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
    }

    func testHelpCheckAndGeneratedPractice() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["E2E_GATEWAY_URL"], let token = env["E2E_TOKEN"] else {
            throw XCTSkip("Run scripts/ipad-e2e.sh to provide a local gateway.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-reset", "-e2e-service", url, token]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        app.buttons["先体验示例家庭"].tap()

        // Homework: ask for a hint, then a provisional check.
        openSidebar(app, "我的作业")
        app.staticTexts["小熊的橡果问题"].firstMatch.tap()
        let answer = app.textFields["记录你的答案或想法（可选）"]
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        answer.tap(); answer.typeText("42")
        let question = app.textFields["说说你卡在哪里，或写下你的思路"]
        question.tap(); question.typeText("个位怎么算")
        app.buttons["发送问题"].tap()
        XCTAssertTrue(app.staticTexts["小熊：先看看个位：4 加 8 等于多少？满十要怎么办？"].waitForExistence(timeout: 15))
        app.buttons["帮我检查"].tap()
        XCTAssertTrue(app.staticTexts["AI 检查建议：目前看起来正确。最终完成状态由家长确认。"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["进行中"].exists, "an AI check never completes homework")

        // Practice: generate an AI exercise and answer it.
        openSidebar(app, "练一练")
        app.buttons["生成新题"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["算一算：35 + 27 = ？请填写一个整数。"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["这是 AI 生成题，参考答案可能有误；结果不计入独立掌握证据。"].exists)
        let field = app.textFields["写下你的答案"]
        field.tap(); field.typeText("62")
        app.buttons["我写好了，检查一下"].tap()
        XCTAssertTrue(app.staticTexts["已完成"].waitForExistence(timeout: 5))

        // Progress: the generated exercise is recorded but not counted as mastery.
        openSidebar(app, "我的进步")
        XCTAssertTrue(app.staticTexts["待核验"].waitForExistence(timeout: 5))
    }
}
