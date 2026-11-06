import XCTest

/// The record transition from Home to the roll: the piano flies out of the
/// record button into the roll's keyboard, which is hidden only while it is
/// in the air; going back mid-flight leaves Home as it was; Reduce Motion
/// crossfades. The simulator can't reliably record, so these launch with
/// -semitone-record-transition-demo, where the record button starts an
/// empty take without the microphone, and read the transition from DEBUG
/// elements: "record-transition-state" says whether anything is still in
/// the air, of which kind, and how the last flight ended ("idle, landed on
/// horizontal", "flying (fly), keyboard hidden"); and
/// "record-transition-keyboard-<layout>" whether the keyboard is drawn or
/// out of sight ("shown" or "hidden"), which the keyboard's own element,
/// there either way, can't say. -semitone-record-transition-slow stretches
/// the flight for the tests that act during it, since XCUITest waits for
/// each tap to settle.
final class RecordTransitionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        if let app, (testRun?.totalFailureCount ?? 0) > 0 {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "Failure"
            shot.lifetime = .keepAlways
            add(shot)
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "Accessibility hierarchy"
            tree.lifetime = .keepAlways
            add(tree)
        }
        app?.terminate()
    }

    private func launchHome(_ arguments: [String] = [], layout: String = "horizontal") {
        app?.terminate()
        app = XCUIApplication()
        app.launchArguments = ["-semitone-skip-intro", "-aiProvider", "off",
                               "-semitone-record-transition-demo", "-rollLayout", layout] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["home-record"].waitForExistence(timeout: 10), "Home is the app's root.")
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private var transitionState: String { element("record-transition-state").value as? String ?? "" }

    private var isIdle: Bool { transitionState.hasPrefix("idle") }

    /// Whether `layout`'s keyboard is drawn ("shown") or out of sight.
    private func keyboardShown(_ layout: String) -> String {
        element("record-transition-keyboard-\(layout)").value as? String ?? "missing"
    }

    private func wait(_ description: String, timeout: TimeInterval = 8,
                      file: StaticString = #filePath, line: UInt = #line,
                      until condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
                       "\(description). Transition: \(transitionState)", file: file, line: line)
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Tap record: the transcription screen comes up and the piano lands on
    /// the roll's keyboard (not let go short of it), which is then drawn
    /// down the left edge, not left hidden.
    func testRecordTapFliesIntoTheRollsKeyboard() {
        launchHome()
        XCTAssertEqual(transitionState, "idle")
        app.buttons["home-record"].tap()
        XCTAssertTrue(app.buttons["record-button"].waitForExistence(timeout: 5), "The transcription screen.")
        wait("The piano has landed", timeout: 4) { self.isIdle }
        XCTAssertEqual(transitionState, "idle, landed on horizontal", "On the keyboard itself, swapped unseen.")
        let keyboard = element("piano-keyboard")
        XCTAssertTrue(keyboard.waitForExistence(timeout: 1.5))
        XCTAssertEqual(keyboardShown("horizontal"), "shown", "The keyboard is shown again, not left hidden.")
        let window = app.windows.firstMatch.frame
        XCTAssertEqual(keyboard.frame.minX, window.minX, accuracy: 0.5, "Down the left side.")
        XCTAssertEqual(keyboard.frame.width, 56, accuracy: 0.5)
        XCTAssertEqual(keyboard.frame.maxY, window.maxY, accuracy: 0.5)
        XCTAssertGreaterThan(keyboard.frame.height, window.height / 2)
        XCTAssertEqual(app.buttons["record-button"].label, "Stop recording", "The take is recording.")
        attachScreenshot("Landed")
    }

    /// While the piano is in the air the keyboard it flies to is out of
    /// sight; it shows once the piano lands. (Out of sight only: its
    /// VoiceOver element stays, so the state element says which.)
    func testTheKeyboardIsHiddenOnlyWhileThePianoFlies() {
        launchHome(["-semitone-record-transition-slow", "8"])
        app.buttons["home-record"].tap()
        XCTAssertTrue(app.buttons["record-button"].waitForExistence(timeout: 10))
        XCTAssertEqual(transitionState, "flying (fly), keyboard hidden", "Out of sight while the piano is on its way.")
        wait("The keyboard's hook says so", timeout: 3) { self.keyboardShown("horizontal") == "hidden" }
        attachScreenshot("Mid-flight, slowed")
        wait("The piano lands", timeout: 20) { self.isIdle }
        XCTAssertEqual(transitionState, "idle, landed on horizontal")
        XCTAssertTrue(element("piano-keyboard").waitForExistence(timeout: 2))
        XCTAssertEqual(keyboardShown("horizontal"), "shown")
    }

    /// Stop the take and go back while the piano is still in the air: Home
    /// is as it was, nothing left over it, and the next take flies again.
    func testGoingBackMidFlightLeavesHomeUsable() {
        launchHome(["-semitone-record-transition-slow", "12"])
        app.buttons["home-record"].tap()
        let stop = app.buttons["record-button"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        XCTAssertTrue(transitionState.hasPrefix("flying"))
        stop.tap()
        let back = app.navigationBars.buttons.element(boundBy: 0)
        wait("Stopped, the back button shows", timeout: 5) { back.exists && back.isHittable }
        XCTAssertTrue(transitionState.hasPrefix("flying"), "Still in the air: this is mid-flight.")
        back.tap()
        let record = app.buttons["home-record"]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        // The pop ends it; under a full suite's load the pop itself can take
        // over 2 s to settle (it did once), so allow 5.
        wait("Nothing left in the air", timeout: 5) { self.isIdle }
        XCTAssertEqual(transitionState, "idle, cancelled", "Back on Home ended it at once.")
        XCTAssertTrue(record.isHittable, "Home takes taps: no stray overlay.")
        XCTAssertEqual(record.label, "Start Listening")
        attachScreenshot("Back on Home")

        record.tap()
        XCTAssertTrue(app.buttons["record-button"].waitForExistence(timeout: 10))
        XCTAssertEqual(transitionState, "flying (fly), keyboard hidden", "A second take flies too.")
        wait("And lands", timeout: 25) { self.isIdle }
        XCTAssertEqual(transitionState, "idle, landed on horizontal")
        XCTAssertTrue(element("piano-keyboard").waitForExistence(timeout: 2))
        XCTAssertEqual(keyboardShown("horizontal"), "shown")
    }

    /// Reduce Motion: no spiral and no spin, a short crossfade; the keyboard
    /// is simply there. (A UI test can't turn the setting on; the DEBUG
    /// argument puts the transition in its Reduce Motion form.)
    func testReduceMotionCrossfadesAndStillLands() {
        // Slowed to an 8 s crossfade: the state is read mid-crossfade only
        // once the tap has settled and the screen is up, which has taken
        // over two and a half seconds; slowed less, a busy runner could
        // find it over already.
        launchHome(["-semitone-reduce-motion", "-semitone-record-transition-slow", "20"])
        app.buttons["home-record"].tap()
        XCTAssertTrue(app.buttons["record-button"].waitForExistence(timeout: 10))
        XCTAssertEqual(transitionState, "flying (crossfade)", "A crossfade, the keyboard never out of sight.")
        XCTAssertEqual(keyboardShown("horizontal"), "shown")
        wait("The crossfade is over", timeout: 20) { self.isIdle }
        XCTAssertEqual(transitionState, "idle, crossfaded")
        XCTAssertTrue(element("piano-keyboard").waitForExistence(timeout: 1.5))
    }

    /// With the falling notes chosen the piano flies to their keys along the
    /// bottom instead, and lands there.
    func testFallingNotesLandAlongTheBottom() {
        launchHome(layout: "falling")
        app.buttons["home-record"].tap()
        XCTAssertTrue(app.buttons["record-button"].waitForExistence(timeout: 5))
        wait("The piano has landed", timeout: 4) { self.isIdle }
        XCTAssertEqual(transitionState, "idle, landed on falling", "On the falling notes' keys, not the column's.")
        XCTAssertTrue(element("falling-notes-view").waitForExistence(timeout: 2))
        XCTAssertFalse(element("piano-keyboard").exists, "Not the horizontal roll.")
        XCTAssertEqual(keyboardShown("falling"), "shown", "The keys along the bottom are drawn.")
        attachScreenshot("Landed on the falling notes")
    }

    /// The take can't start (the microphone refused): the transcription
    /// screen comes straight up with its alert (Home's never shows), and the
    /// piano is let go where it is rather than flown on to a keyboard that
    /// won't come. Slowed, a full flight would take over ten seconds; let go,
    /// it is over in about one.
    func testATakeThatCantStartLetsThePianoGo() {
        launchHome(["-semitone-record-transition-deny", "-semitone-record-transition-slow", "8"])
        app.buttons["home-record"].tap()
        let alert = app.alerts["Something went wrong"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "The error, as before the transition.")
        attachScreenshot("Couldn't start")
        alert.buttons["OK"].tap()
        XCTAssertTrue(app.buttons["record-button"].waitForExistence(timeout: 3), "On the transcription screen.")
        let home = app.buttons["home-record"]
        XCTAssertFalse(home.exists && home.isHittable, "Not back on Home.")
        wait("Let go, not flown on", timeout: 4) { self.isIdle }
        XCTAssertEqual(transitionState, "idle, released")
        XCTAssertFalse(alert.exists, "One alert, dismissed: Home's never followed it.")
        XCTAssertTrue(app.buttons["record-button"].isHittable, "The screen takes taps: nothing left over it.")
    }
}
