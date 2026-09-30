import XCTest

@MainActor
final class funcDictionaryUITests: XCTestCase {
    func testEmptyProjectShellLaunches() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        XCTAssertTrue(app.staticTexts["No Projects Yet"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["open-dictionary-button"].exists)
        XCTAssertTrue(app.buttons["open-search-button"].exists)
    }

    func testSettingsCanBeOpened() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        app.buttons["settings-button"].tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.tables["settings-table"].exists)
    }

    func testCreateProjectOpensProjectScopedDictionary() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        app.buttons["create-project-button"].tap()
        let nameField = app.textFields["project-name-field"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 2))
        nameField.tap()
        nameField.typeText("UI Test Project")
        app.alerts.buttons["Create"].tap()

        XCTAssertTrue(app.staticTexts["UI Test Project"].waitForExistence(timeout: 2))
        app.staticTexts["UI Test Project"].tap()
        XCTAssertTrue(app.staticTexts["No Definitions Yet"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["dictionary-import-button"].exists)
        XCTAssertTrue(app.buttons["dictionary-export-button"].exists)
    }

    func testDemoDefinitionExpandsAndExposesAgentActions() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--demo-data"]
        app.launch()

        let projectCell = app.cells["project-cell-project_demo"]
        XCTAssertTrue(projectCell.waitForExistence(timeout: 2))
        projectCell.tap()
        let card = app.cells["definition-card-def_dictionary_card"]
        XCTAssertTrue(card.waitForExistence(timeout: 2))
        card.tap()
        XCTAssertTrue(app.buttons["copy-button-def_dictionary_card"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["send-to-agent-button-def_dictionary_card"].exists)
    }

    func testDemoDefinitionCopyMenuOffersBothContextFormats() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--demo-data"]
        app.launch()

        let projectCell = app.cells["project-cell-project_demo"]
        XCTAssertTrue(projectCell.waitForExistence(timeout: 2))
        projectCell.tap()
        let card = app.cells["definition-card-def_dictionary_card"]
        XCTAssertTrue(card.waitForExistence(timeout: 2))
        card.tap()

        app.buttons["copy-button-def_dictionary_card"].tap()
        let readable = app.sheets.buttons["Readable Context"]
        let structured = app.sheets.buttons["Structured JSON"]
        XCTAssertTrue(readable.waitForExistence(timeout: 2))
        XCTAssertTrue(structured.exists)
        readable.tap()
    }
}
