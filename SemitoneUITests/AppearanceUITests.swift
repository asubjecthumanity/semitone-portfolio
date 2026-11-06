import XCTest
import CoreGraphics

/// The app is light whatever the system setting: with the simulator switched
/// to dark mode, Home, the transcription screen (in Home's look: the grey
/// ground, the white roll, navy black keys) and a Tone's Settings are drawn
/// light, as read back from the screen. Before, the transcription screen and
/// its sheets followed the system into dark mode, and this test failed there.
final class AppearanceUITests: XCTestCase {
    private var app: XCUIApplication!

    /// Home's ground (`HomeTheme.ground`, `RollTheme.ground`) and the brand navy.
    private static let ground = Pixel(r: 0xF2, g: 0xF2, b: 0xF7)
    private static let navy = Pixel(r: 0x0F, g: 0x1E, b: 0x3A)

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.appearance = .dark
        // The system takes a moment to switch over.
        Thread.sleep(forTimeInterval: 2)
    }

    override func tearDownWithError() throws {
        if let app, (testRun?.totalFailureCount ?? 0) > 0 {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Failure"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        app?.terminate()
        XCUIDevice.shared.appearance = .light
    }

    private func launch(_ arguments: [String]) {
        app?.terminate()
        app = XCUIApplication()
        app.launchArguments = ["-semitone-skip-intro", "-aiProvider", "off"] + arguments
        app.launch()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testEveryScreenStaysLightInDarkMode() throws {
        XCTAssertEqual(XCUIDevice.shared.appearance, .dark, "The system is in dark mode.")

        // Home: the ground in the right margin, beside the library.
        launch(["-semitone-home-no-tones"])
        XCTAssertTrue(app.buttons["home-record"].waitForExistence(timeout: 10))
        let window = app.windows.firstMatch.frame
        var screen = try XCTUnwrap(ScreenPixels(app))
        let homeGround = screen.median([0.35, 0.45, 0.55].map { CGPoint(x: window.maxX - 6, y: window.height * $0) })
        XCTAssertTrue(homeGround.isClose(to: Self.ground), "Home's ground: \(homeGround)")
        attachScreenshot("Home, system in dark mode")

        // The transcription screen, on a Song fixture.
        launch(["-semitone-ui-fixture", "song", "-semitone-fixture-cue", "2"])
        XCTAssertTrue(element("regression-state").waitForExistence(timeout: 15))
        let melody = element("part-melody")
        let keyboard = element("piano-keyboard")
        let blackKey = element("piano-key-61")
        let roll = element("piano-roll-scroll")
        XCTAssertTrue(melody.exists && keyboard.exists && blackKey.exists && roll.exists)
        screen = try XCTUnwrap(ScreenPixels(app))
        // Home's grey around the roll, right of the parts' chips.
        let partsGround = screen.median([-6, 0, 6].map { CGPoint(x: window.maxX - 10, y: melody.frame.midY + $0) })
        XCTAssertTrue(partsGround.isClose(to: Self.ground), "The ground around the roll: \(partsGround)")
        // White keys (right of the black keys, left of the octave names)
        // and a navy black key.
        let k = keyboard.frame
        let whiteKeys = screen.median((1...5).map { CGPoint(x: k.minX + 38, y: k.minY + k.height * CGFloat($0) / 6) })
        XCTAssertGreaterThan(whiteKeys.luminance, 0.95, "White keys: \(whiteKeys)")
        let black = screen.median([-2, 0, 2].map { CGPoint(x: k.minX + 10, y: blackKey.frame.midY + $0) })
        XCTAssertTrue(black.isClose(to: Self.navy, tolerance: 6), "A black key: \(black)")
        // The roll's rows, white and shaded, down its right edge (notes and
        // lines here and there don't sway the middle value).
        let r = roll.frame
        let rows = screen.median((1...19).map { CGPoint(x: r.maxX - 3, y: r.minY + r.height * CGFloat($0) / 20) })
        XCTAssertGreaterThan(rows.luminance, 0.85, "The roll's rows: \(rows)")
        // A shown part's chip is light glass, as a hidden one's (they were
        // navy pills): inside the capsule's right end, past the name.
        let m = melody.frame
        let chip = screen.median([-2, 0, 2].map { CGPoint(x: m.maxX - 5, y: m.midY + $0) })
        XCTAssertGreaterThan(chip.luminance, 0.85, "A shown part's chip: \(chip)")
        attachScreenshot("Transcription screen, system in dark mode")

        // A Tone's Settings, from the gear, which opens them straight away.
        let gear = app.buttons["tone-settings"]
        XCTAssertTrue(gear.exists, "The gear")
        gear.tap()
        XCTAssertTrue(app.buttons["settings-close"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.8)
        screen = try XCTUnwrap(ScreenPixels(app))
        // In the right margin, above and below the sideways row of
        // Detection cards, the one thing that runs to the edge.
        let sheetGround = screen.median([0.38, 0.6, 0.85].map { CGPoint(x: window.maxX - 6, y: window.height * $0) })
        XCTAssertTrue(sheetGround.isClose(to: Self.ground), "The Settings sheet's ground: \(sheetGround)")
        attachScreenshot("A Tone's Settings, system in dark mode")
    }
}
