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
        XCTAssertTrue(app.staticTexts["onboarding.codes.title"].waitForExistence(timeout: 5))
        shot("03-codes")
        app.buttons["onboarding.codes.guide"].tap()
        XCTAssertTrue(app.staticTexts["codes.guide.title"].waitForExistence(timeout: 5))
        shot("03b-codes-guide")
        app.buttons["codes.guide.done"].tap()
        start.tap()
        XCTAssertTrue(app.buttons["onboarding.later"].waitForExistence(timeout: 5))
        shot("04-add-devices")
        app.buttons["onboarding.later"].tap()
        XCTAssertTrue(app.buttons["home.addDevice"].waitForExistence(timeout: 5))
        shot("05-home-empty")

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
        // Native per-device settings persist when reopened.
        let peer = app.staticTexts["CI Windows PC"]
        if ProcessInfo.processInfo.environment["NC_CI"] == "1" { XCTAssertTrue(peer.waitForExistence(timeout: 5)) }
        if peer.exists {
            peer.tap()
            let send = app.switches["policy.send"]
            XCTAssertTrue(send.waitForExistence(timeout: 5))
            XCTAssertEqual(send.value as? String, "1")
            send.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            let disabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0'"), object: send)
            XCTAssertEqual(XCTWaiter().wait(for: [disabled], timeout: 5), .completed)
            shot("09b-device-policy")
            app.buttons["policy.done"].tap()
            peer.tap()
            XCTAssertEqual(app.switches["policy.send"].value as? String, "0")
            app.switches["policy.send"].coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            app.buttons["policy.done"].tap()
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["home.settings"].tap()
        sleep(1)
        shot("10-settings")
        app.buttons["sheet.done"].tap()
        app.buttons["home.addDevice"].tap()
        sleep(2)
        shot("11-add-device")
    }

    /// Exercises the real system share extension, hosted by Safari, against the same paired CLI peer.
    func testShareFromSafari() throws {
        let url = try XCTUnwrap(ProcessInfo.processInfo.environment["NC_SHARE_URL"])
        addUIInterruptionMonitor(withDescription: "share network access") { alert in
            for label in ["Allow", "OK"] where alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            return false
        }
        app.launchArguments = language(); app.launch()
        XCTAssertTrue(app.buttons["home.devices"].waitForExistence(timeout: 10))
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launchArguments = language(); safari.launch(); safari.open(URL(string: url)!)
        tapIfExists(safari.buttons["Continue"], timeout: 2)
        tapIfExists(safari.buttons["Start Browsing"], timeout: 2)
        shot("60a-safari-open")
        let share = safari.buttons["Share"].firstMatch
        if !share.waitForExistence(timeout: 10) { tapIfExists(safari.buttons["More"].firstMatch) }
        XCTAssertTrue(share.waitForExistence(timeout: 10)); share.tap()
        shot("60-safari-share")
        print("Share hierarchy: \(safari.debugDescription)")
        func visible(_ label: String) -> XCUIElement? {
            safari.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label))
                .allElementsBoundByIndex.first { $0.exists && $0.isHittable }
        }
        if visible("Nearclip") == nil {
            // App activities are horizontally scrollable; the accessibility tree also includes offscreen More buttons.
            for _ in 0..<4 {
                if let nearclip = visible("Nearclip") { nearclip.tap(); break }
                if let more = visible("More") { more.tap(); break }
                let apps = safari.collectionViews.firstMatch
                if apps.exists { apps.swipeLeft() } else { safari.swipeUp() }
            }
            if let nearclip = visible("Nearclip") { nearclip.tap() }
        } else { visible("Nearclip")?.tap() }
        print("Extension hierarchy: \(safari.debugDescription)")
        let destination = safari.staticTexts["CI Windows PC"].firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 15)); shot("61-share-destination"); destination.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: destination)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 25), .completed)
        shot("62-share-finished")
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
            app.buttons["onboarding.next"].tap()
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

    /// A verification code from another device (PROTOCOL.md §6.7), driven by apple/tools/ios_code.py: pairs through
    /// NC_PAIR_LINK, then the peer sends two codes. The banner asks "Copy it?" with the code in large digits and
    /// nothing is copied on its own; Copy puts it on the clipboard ("Copied"); the second code goes away with Not Now.
    /// Then Settings › Verification codes shows the Shortcuts guide.
    func testCodeOffer() throws {
        let link = try XCTUnwrap(ProcessInfo.processInfo.environment["NC_PAIR_LINK"], "set TEST_RUNNER_NC_PAIR_LINK")
        app.launchArguments = language()
        app.launch()
        if app.buttons["onboarding.next"].waitForExistence(timeout: 4) {
            app.buttons["onboarding.next"].tap()
            app.buttons["onboarding.next"].tap()
            app.tap()
            app.buttons["onboarding.next"].tap()
            if app.buttons["onboarding.later"].waitForExistence(timeout: 5) { app.buttons["onboarding.later"].tap() }
        }
        XCTAssertTrue(app.buttons["home.devices"].waitForExistence(timeout: 10))
        app.open(URL(string: link)!)
        XCTAssertTrue(app.staticTexts["join.success"].waitForExistence(timeout: 30))
        app.buttons["join.done"].tap()
        tapIfExists(app.buttons["sheet.done"])

        let banner = app.descendants(matching: .any)["codeOffer"]
        XCTAssertTrue(banner.waitForExistence(timeout: 60), "no banner for the code")
        let toast = app.descendants(matching: .any)["toast"]
        XCTAssertFalse(toast.exists, "the code was copied on its own")
        sleep(1)
        shot("50-code-offer")
        app.buttons["codeOffer.copy"].tap()
        XCTAssertTrue(toast.waitForExistence(timeout: 3), "no Copied after Copy")
        shot("51-code-copied")
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: banner)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 5), .completed, "the banner stayed after Copy")

        XCTAssertTrue(banner.waitForExistence(timeout: 40), "no banner for the second code")
        app.buttons["codeOffer.dismiss"].tap()
        let gone2 = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: banner)
        XCTAssertEqual(XCTWaiter().wait(for: [gone2], timeout: 5), .completed, "the banner stayed after Not Now")

        app.buttons["home.settings"].tap()
        let guide = app.buttons["codes.guide"]
        for _ in 0..<4 where !guide.isHittable { app.swipeUp() }
        shot("52-settings-codes")
        guide.tap()
        XCTAssertTrue(app.staticTexts["codes.guide.title"].waitForExistence(timeout: 5))
        shot("53-codes-guide")
    }

    /// "Send Verification Code" (SendCodeIntent) as a Shortcuts automation runs it, through the Debug-only
    /// nearclip://debug-send-code link; driven by apple/tools/ios_code.py --intent, whose peer checks that just the
    /// code arrives, marked as a code, and that a message without a code sends nothing.
    func testSendCodeIntent() throws {
        let link = try XCTUnwrap(ProcessInfo.processInfo.environment["NC_PAIR_LINK"], "set TEST_RUNNER_NC_PAIR_LINK")
        app.launchArguments = language()
        app.launch()
        if app.buttons["onboarding.next"].waitForExistence(timeout: 4) {
            app.buttons["onboarding.next"].tap()
            app.buttons["onboarding.next"].tap()
            app.tap()
            app.buttons["onboarding.next"].tap()
            if app.buttons["onboarding.later"].waitForExistence(timeout: 5) { app.buttons["onboarding.later"].tap() }
        }
        XCTAssertTrue(app.buttons["home.devices"].waitForExistence(timeout: 10))
        app.open(URL(string: link)!)
        XCTAssertTrue(app.staticTexts["join.success"].waitForExistence(timeout: 30))
        app.buttons["join.done"].tap()
        tapIfExists(app.buttons["sheet.done"])
        sleep(4)
        for message in ["[카카오] 인증번호는 482915입니다. 타인에게 절대 알려주지 마세요.", "내일 3시에 회의실에서 봬요"] {
            var c = URLComponents(string: "nearclip://debug-send-code")!
            c.queryItems = [URLQueryItem(name: "message", value: message)]
            app.open(c.url!)
            sleep(8)
        }
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
            if next.waitForExistence(timeout: 3) { next.tap() }
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

