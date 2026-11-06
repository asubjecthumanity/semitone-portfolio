import XCTest

/// The horizontal roll's keyboard runs down the left edge, where the Back
/// swipe starts, and holding it a moment now lifts it to switch layouts. The
/// hold comes first, so a swipe that starts on the keyboard still goes back
/// to Home, while a hold then a pull right flips the roll instead.
///
/// A class of its own, run before `RollLayoutUITests` (classes run in name
/// order): in the simulator, once a test had set the device's orientation,
/// synthesized edge swipes later in the same run no longer reached the
/// system's Back gesture, even back in portrait.
final class RollBackSwipeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        // Not `hasSucceeded`: the run is still going in tear-down, so that is
        // false for a passing test too.
        if let app, (testRun?.totalFailureCount ?? 0) > 0 {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Failure"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        app?.terminate()
    }

    private func launchSong() {
        app?.terminate()
        app = XCUIApplication()
        app.launchArguments = ["-semitone-ui-fixture", "song", "-semitone-fixture-cue", "0", "-aiProvider", "off"]
        app.launch()
        XCTAssertTrue(element("regression-state").waitForExistence(timeout: 15))
        XCTAssertTrue(element("piano-roll-scroll").waitForExistence(timeout: 5))
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        app.windows.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }

    /// Swipes that start on the keyboard go back: from the very edge, a
    /// little way in, and a quick flick (each from a fresh launch).
    func testBackSwipesFromTheKeyboardStillGoBack() {
        let swipes: [(name: String, x: CGFloat, press: TimeInterval, speed: CGFloat)] = [
            ("from the edge", 1, 0.1, 600),
            ("from the black keys", 20, 0.05, 1500),
            ("a quick flick", 3, 0, 2500),
        ]
        for swipe in swipes {
            launchSong()
            let window = app.windows.firstMatch.frame
            let y = window.midY + 80   // on the keyboard
            point(swipe.x, y).press(forDuration: swipe.press, thenDragTo: point(window.width * 0.9, y),
                                    withVelocity: XCUIGestureVelocity(swipe.speed), thenHoldForDuration: 0.1)
            XCTAssertTrue(app.buttons["home-record"].waitForExistence(timeout: 5),
                          "A swipe \(swipe.name) on the keyboard goes back to Home.")
            XCTAssertFalse(element("falling-notes-view").exists)
        }
    }

    /// Held first, the same edge is the keyboard: pulled right and down round
    /// the corner, the roll flips to the falling notes and stays on screen.
    func testHoldingTheKeyboardEdgeFirstLiftsItInstead() {
        launchSong()
        let window = app.windows.firstMatch.frame
        let hingeY = window.maxY - 34 - 96
        point(10, hingeY - 300).press(forDuration: 0.6, thenDragTo: point(window.width - 20, hingeY + 20),
                                      withVelocity: 600, thenHoldForDuration: 0.2)
        XCTAssertTrue(element("falling-notes-view").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["home-record"].exists, "Still on the Tone, not back on Home.")
    }
}
