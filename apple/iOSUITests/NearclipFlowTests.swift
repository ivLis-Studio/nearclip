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

    /// Cross-device acceptance on an onboarded app: joins the group of NC_PAIR_LINK first when it is set, expects the
    /// clips named in NC_EXPECT (comma separated) to arrive through catch-up, then sends NC_SEND_TEXT with the system
    /// Paste button.
    func testReceiveThenSend() throws {
        app.launchArguments = language()
        app.launch()
        XCTAssertTrue(app.buttons["home.devices"].waitForExistence(timeout: 10))
        if let link = ProcessInfo.processInfo.environment["NC_PAIR_LINK"] {
            app.open(URL(string: link)!)
            XCTAssertTrue(app.staticTexts["join.success"].waitForExistence(timeout: 30))
            app.buttons["join.done"].tap()
            tapIfExists(app.buttons["sheet.done"])
        }
        for expected in (ProcessInfo.processInfo.environment["NC_EXPECT"] ?? "").split(separator: ",").map(String.init) where !expected.isEmpty {
            let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", expected)).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 20), "missing clip: \(expected)")
        }
        shot("30-received")
        UIPasteboard.general.string = ProcessInfo.processInfo.environment["NC_SEND_TEXT"] ?? "FINAL from iPhone"
        app.activate()
        let paste = app.buttons["send.paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        XCTAssertTrue(app.staticTexts["toast"].waitForExistence(timeout: 8) || app.otherElements["toast"].waitForExistence(timeout: 2))
        sleep(1)
        shot("31-sent")
    }

    /// A large image from another device (PROTOCOL.md §6.6), driven by apple/tools/ios_transfer.py: pairs through
    /// NC_PAIR_LINK, then the peer announces an image and sends it slowly. The card above the send bar shows
    /// "Receiving an image from …" (first "Preparing…", then "3.1 / 10.6 MB"), then "Copied from …" takes its place.
    func testIncomingImageProgress() throws {
        let link = try XCTUnwrap(ProcessInfo.processInfo.environment["NC_PAIR_LINK"], "set TEST_RUNNER_NC_PAIR_LINK")
        app.launchArguments = language()
        app.launch()
        if app.buttons["onboarding.next"].waitForExistence(timeout: 4) {
            app.buttons["onboarding.next"].tap()
            app.buttons["onboarding.next"].tap()
            app.tap()
            if app.buttons["onboarding.later"].waitForExistence(timeout: 5) { app.buttons["onboarding.later"].tap() }
        }
        XCTAssertTrue(app.buttons["home.devices"].waitForExistence(timeout: 10))
        app.open(URL(string: link)!)
        XCTAssertTrue(app.staticTexts["join.success"].waitForExistence(timeout: 30))
        app.buttons["join.done"].tap()
        tapIfExists(app.buttons["sheet.done"])

        let card = app.descendants(matching: .any)["transfer"]
        XCTAssertTrue(card.waitForExistence(timeout: 60), "no card for the announced image")
        shot("40-transfer-preparing")
        let sized = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS ' MB'"), object: card)
        XCTAssertEqual(XCTWaiter().wait(for: [sized], timeout: 30), .completed, "no progress: \(card.label)")
        sleep(3)
        shot("41-transfer-receiving")
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: card)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 60), .completed, "the card did not go away")
        let toast = app.descendants(matching: .any)["toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 3), "no toast when the image came in")
        shot("42-transfer-copied")
        XCTAssertTrue(app.buttons.matching(identifier: "clip.row").firstMatch.exists)
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

    /// Settings › About › Open-source licenses: the embedded Tailscale node's components and one full license text.
    /// Needs an already onboarded app.
    func testOpenSourceLicenses() throws {
        app.launchArguments = language()
        app.launch()
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 10))
        app.buttons["home.settings"].tap()
        let link = app.buttons["about.licenses"]
        XCTAssertTrue(app.buttons["sheet.done"].waitForExistence(timeout: 5), "Settings sheet did not open")
        for _ in 0..<8 where !(link.exists && link.isHittable) { app.swipeUp() } // the list is lazy
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any.matching(NSPredicate(format: "label CONTAINS %@", "Tailscale (tsnet)")).firstMatch.waitForExistence(timeout: 5))
        shot("50-licenses")
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "tailscale.com ")).firstMatch
        for _ in 0..<12 where !(row.exists && row.isHittable) { app.swipeUp() }
        row.tap()
        XCTAssertTrue(any.matching(NSPredicate(format: "label CONTAINS %@", "Tailscale Inc")).firstMatch.waitForExistence(timeout: 5))
        shot("51-license-text")
    }

    /// Remote connection (PROTOCOL.md §10) against a test control server: pair through NC_PAIR_LINK, turn on
    /// "Sync across networks", wait until the peer is reached through the tailnet (apple/tools/ios_remote.py makes
    /// the peer LAN-unreachable), then expect NC_EXPECT to arrive. Pass NC_TAILNET_CONTROL to the app.
    func testRemoteConnection() throws {
        let env = ProcessInfo.processInfo.environment
        let link = try XCTUnwrap(env["NC_PAIR_LINK"], "set TEST_RUNNER_NC_PAIR_LINK")
        addUIInterruptionMonitor(withDescription: "system alerts") { alert in
            for label in ["Allow", "허용", "OK", "확인", "Open", "열기"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launchArguments = language()
        app.launchEnvironment["NC_TAILNET_CONTROL"] = env["NC_TAILNET_CONTROL"]
        app.launch()
        let next = app.buttons["onboarding.next"]
        if next.waitForExistence(timeout: 6) {
            next.tap()
            if next.waitForExistence(timeout: 3) { next.tap() }
            app.tap()
            tapIfExists(app.buttons["onboarding.later"], timeout: 5)
        }
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 10))
        app.open(URL(string: link)!)
        XCTAssertTrue(app.staticTexts["join.success"].waitForExistence(timeout: 30))
        app.buttons["join.done"].tap()
        tapIfExists(app.buttons["sheet.done"])

        app.buttons["home.settings"].tap()
        let toggle = app.switches["remote.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if (toggle.value as? String) != "1" {
            let knob = toggle.switches.firstMatch
            if knob.exists { knob.tap() } else { toggle.tap() }
        }
        let running = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "On ·", "켜짐 ·")).firstMatch
        XCTAssertTrue(running.waitForExistence(timeout: 60), "remote connection did not come up")
        sleep(1)
        shot("40-remote-on")
        app.buttons["sheet.done"].tap()

        app.buttons["home.devices"].tap()
        XCTAssertTrue(app.collectionViews["devices.list"].waitForExistence(timeout: 5))
        let remote = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "Connected · Remote", "연결됨 · 원격")).firstMatch
        XCTAssertTrue(remote.waitForExistence(timeout: 120), "peer never connected through the tailnet")
        sleep(1)
        shot("41-devices-remote")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        for expected in (env["NC_EXPECT"] ?? "").split(separator: ",").map(String.init) where !expected.isEmpty {
            let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", expected)).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 60), "missing clip: \(expected)")
        }
        sleep(1)
        shot("42-home-remote-clip")

        // iOS: networking pauses 8 s after Nearclip goes to the background, which stops the embedded node; a fresh one
        // starts when the app is active again (tailscale/tailscale#20060). The remote session must come back.
        XCUIDevice.shared.press(.home)
        sleep(14)
        app.activate()
        XCTAssertTrue(app.buttons["home.devices"].waitForExistence(timeout: 10))
        app.buttons["home.devices"].tap()
        let again = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "Connected · Remote", "연결됨 · 원격")).firstMatch
        XCTAssertTrue(again.waitForExistence(timeout: 60), "remote session did not come back after the background pause")
        sleep(1)
        shot("43-devices-remote-after-background")
    }
}

