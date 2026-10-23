import XCTest

/// End-to-end acceptance on the simulator: onboarding → pair through a nearclip:// link → catch-up →
/// send with the system Paste button. Needs a running peer; pass its link with TEST_RUNNER_NC_PAIR_LINK.
final class NearclipFlowTests: XCTestCase {
    private let app = XCUIApplication()
    private var shots: String { ProcessInfo.processInfo.environment["NC_SHOTS"] ?? "/tmp/nearclip-ios-shots" }

    override func setUp() {
        continueAfterFailure = false
    }

    private func shot(_ name: String) {
        try? FileManager.default.createDirectory(atPath: shots, withIntermediateDirectories: true)
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: shots + "/" + name + ".png"))
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func language() -> [String] {
        let lang = ProcessInfo.processInfo.environment["NC_LANG"] ?? "en"
        return ["-AppleLanguages", "(\(lang))", "-AppleLocale", lang == "ko" ? "ko_KR" : "en_US"]
    }

    private func tapIfExists(_ e: XCUIElement, timeout: TimeInterval = 2) {
        if e.waitForExistence(timeout: timeout) { e.tap() }
    }

    func testOnboardingPairSyncAndSend() throws {
        let link = try XCTUnwrap(ProcessInfo.processInfo.environment["NC_PAIR_LINK"], "set TEST_RUNNER_NC_PAIR_LINK")
        let text = ProcessInfo.processInfo.environment["NC_SEND_TEXT"] ?? "Hello from the iPhone simulator"
        addUIInterruptionMonitor(withDescription: "system alerts") { alert in
            for label in ["Allow", "허용", "OK", "확인", "Open", "열기"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launchArguments = language()
        app.launch()
        let start = app.buttons["onboarding.next"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        shot("01-welcome")
        start.tap()
        XCTAssertTrue(app.staticTexts["onboarding.network.title"].waitForExistence(timeout: 5))
        shot("02-network")
        start.tap()
        app.tap() // lets the interruption monitor handle a local-network alert, if any
        XCTAssertTrue(app.buttons["onboarding.later"].waitForExistence(timeout: 5))
        shot("03-add-devices")
        app.buttons["onboarding.later"].tap()
        XCTAssertTrue(app.buttons["home.addDevice"].waitForExistence(timeout: 5))
        shot("04-home-empty")

        app.open(URL(string: link)!)
        let connected = app.staticTexts["join.success"]
        XCTAssertTrue(connected.waitForExistence(timeout: 30))
        shot("05-joined")
        app.buttons["join.done"].tap()
        tapIfExists(app.buttons["sheet.done"])
        // Catch-up brings the history of the other devices.
        XCTAssertTrue(app.buttons.matching(identifier: "clip.row").firstMatch.waitForExistence(timeout: 20))
        sleep(2)
        shot("06-home-history")

        UIPasteboard.general.string = text
        app.activate()
        let paste = app.buttons["send.paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        shot("07-pending-clipboard")
        paste.tap()
        XCTAssertTrue(app.staticTexts["toast"].waitForExistence(timeout: 8))
        shot("08-sent")

        app.buttons["home.devices"].tap()
        XCTAssertTrue(app.collectionViews["devices.list"].waitForExistence(timeout: 5))
        sleep(1)
        shot("09-devices")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["home.settings"].tap()
        sleep(1)
        shot("10-settings")
        app.buttons["sheet.done"].tap()
        app.buttons["home.addDevice"].tap()
        sleep(2)
        shot("11-add-device")
    }

    /// Needs an already onboarded app (run after testOnboardingPairSyncAndSend).
    func testSheetsOpenFromHome() throws {
        app.launchArguments = language()
        app.launch()
        XCTAssertTrue(app.buttons["home.devices"].waitForExistence(timeout: 10))
        app.buttons["home.devices"].tap()
        XCTAssertTrue(app.collectionViews["devices.list"].waitForExistence(timeout: 5), "Devices page did not open")
        shot("20-devices")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["home.settings"].tap()
        XCTAssertTrue(app.buttons["sheet.done"].waitForExistence(timeout: 5), "Settings sheet did not open")
        shot("21-settings")
        app.buttons["sheet.done"].tap()
        app.buttons["home.addDevice"].tap()
        XCTAssertTrue(app.buttons["sheet.done"].waitForExistence(timeout: 5), "Add Device sheet did not open")
        sleep(2)
        shot("22-add-device")
    }
}

