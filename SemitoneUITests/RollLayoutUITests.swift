import XCTest
import CoreGraphics

/// Switching the roll's layout: pulling the keyboard round the corner
/// (Roll Layout 1) and an iPhone on its side showing the falling notes (the
/// left-edge Back swipe that has to survive the first is in
/// `RollBackSwipeUITests`), and the falling notes while recording. Runs the
/// production views on the deterministic fixtures. (VoiceOver's switch
/// actions are performed in the hosted `RollStageAccessibilityTests`:
/// XCUITest can't perform a custom accessibility action.)
final class RollLayoutUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        // Not `hasSucceeded`: the run is still going in tear-down, so that is
        // false for a passing test too.
        if let app, (testRun?.totalFailureCount ?? 0) > 0 {
            attachScreenshot("Failure")
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "Accessibility hierarchy"
            tree.lifetime = .keepAlways
            add(tree)
        }
        // Only when turned: setting it, even to what it already is, can stop
        // later synthesized edge swipes from reaching the system's Back gesture.
        if XCUIDevice.shared.orientation != .portrait { XCUIDevice.shared.orientation = .portrait }
        app?.terminate()
    }

    private func launch(_ fixture: String, cue: Double = 0, layout: String? = nil, extra: [String] = []) {
        app?.terminate()
        app = XCUIApplication()
        app.launchArguments = ["-semitone-ui-fixture", fixture,
                               "-semitone-fixture-cue", String(cue),
                               "-aiProvider", "off"] + extra
        if let layout { app.launchArguments += ["-semitone-fixture-layout", layout] }
        app.launch()
        XCTAssertTrue(element("regression-state").waitForExistence(timeout: 15),
                      "The deterministic fixture must load before any assertions.")
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private var state: String { element("regression-state").value as? String ?? "" }

    private var cue: Double {
        let field = state.split(separator: ";").first { $0.hasPrefix("cue=") }
        return field.flatMap { Double($0.dropFirst(4)) } ?? -1
    }

    private var playing: Bool { state.contains("playing=true") }

    private func wait(_ description: String, timeout: TimeInterval = 8,
                      file: StaticString = #filePath, line: UInt = #line,
                      until condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
                       "\(description). Actual fixture state: \(state)", file: file, line: line)
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(image: uprightScreenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The screen as it looks. On its side a screenshot's pixels are the
    /// display's, a quarter turn round (and an app screenshot's lose half
    /// the screen), so it is drawn upright.
    private func uprightScreenshot() -> UIImage {
        let shot = XCUIScreen.main.screenshot().image
        let format = UIGraphicsImageRendererFormat()
        format.scale = shot.scale
        return UIGraphicsImageRenderer(size: shot.size, format: format).image { _ in shot.draw(at: .zero) }
    }

    private var horizontalRoll: XCUIElement { element("piano-roll-scroll") }
    private var fallingNotes: XCUIElement { element("falling-notes-view") }

    /// The time on the horizontal roll's play line (a fixture-only probe).
    private var timeOnPlayLine: Double {
        Double(element("roll-play-line").value as? String ?? "") ?? -1
    }

    /// A point `dx`, `dy` points from the window's top-left corner.
    private func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        app.windows.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }

    /// Holds at `from` long enough to lift the keyboard, then pulls to `to`
    /// and lets go.
    private func pull(from: CGPoint, to: CGPoint) {
        point(from.x, from.y).press(forDuration: 0.6, thenDragTo: point(to.x, to.y),
                                    withVelocity: 600, thenHoldForDuration: 0.2)
    }

    /// The hinge on screen: on the play line (the keyboard's edge), 96 pt
    /// (the falling notes' keys) above the bottom of the roll, which ends at
    /// the home indicator.
    private var hinge: CGPoint {
        let window = app.windows.firstMatch.frame
        return CGPoint(x: horizontalRoll.exists ? horizontalRoll.frame.minX : 56,
                       y: window.maxY - 34 - 96)
    }

    /// Hold the horizontal roll's keyboard and pull it round the bottom-left
    /// corner: the roll flips over to the falling notes with the cue on the
    /// hit line. Hold the falling notes' keys and pull them up round the
    /// corner: back to the roll, the cue on the play line. A pull short of
    /// halfway falls back.
    func testPullingTheKeyboardRoundTheCornerSwitchesLayoutsAndKeepsTheCue() {
        launch("song", cue: 2)
        XCTAssertTrue(horizontalRoll.waitForExistence(timeout: 5))
        wait("Cued at bar 2") { abs(self.cue - 2) < 0.001 }
        wait("The roll opens on the cue") { abs(self.timeOnPlayLine - 2) < 0.03 }
        XCTAssertEqual(element("roll-cue-marker").value as? String, "Behind the keys")
        let h = hinge

        // About a quarter of the way round, then let go: it falls back.
        pull(from: CGPoint(x: 28, y: h.y - 320), to: CGPoint(x: h.x + 110, y: h.y - 300))
        wait("Short of halfway it falls back to the roll") { self.horizontalRoll.exists && !self.fallingNotes.exists }
        XCTAssertEqual(cue, 2, accuracy: 0.001)

        // Right round to the bottom.
        pull(from: CGPoint(x: 28, y: h.y - 320), to: CGPoint(x: h.x + 300, y: h.y + 10))
        XCTAssertTrue(fallingNotes.waitForExistence(timeout: 5))
        wait("The horizontal roll is gone") { !self.horizontalRoll.exists }
        let scrub = element("falling-notes-scrub")
        XCTAssertEqual(cue, 2, accuracy: 0.001, "The moment on the line stays on the hinge.")
        XCTAssertEqual(scrub.value as? String, "Bar 2 of 4, Am, 0:02")
        attachScreenshot("Pulled round to the falling notes")

        // And back: the falling notes' keys, up round the corner to the left edge.
        let window = app.windows.firstMatch.frame
        pull(from: CGPoint(x: window.midX, y: h.y + 50), to: CGPoint(x: 30, y: h.y - 330))
        XCTAssertTrue(horizontalRoll.waitForExistence(timeout: 5))
        wait("The falling notes are gone") { !self.fallingNotes.exists }
        XCTAssertEqual(cue, 2, accuracy: 0.001)
        wait("The roll comes back on the cue") { abs(self.timeOnPlayLine - 2) < 0.03 }
        XCTAssertEqual(element("roll-cue-marker").value as? String, "Behind the keys",
                       "Turned over and back without a scrub, nothing is picked.")
        attachScreenshot("Pulled back round to the horizontal roll")
    }

    /// A Tone's Settings and the pull set one choice: the Roll style cards
    /// show what the pull last chose, and a card chosen there is what the
    /// roll shows. On its side the phone shows falling notes without
    /// changing that choice.
    func testRollStyleCardsAndThePullShareOneChoice() {
        launch("song", cue: 2)
        XCTAssertTrue(horizontalRoll.waitForExistence(timeout: 5))
        let h = hinge
        pull(from: CGPoint(x: 28, y: h.y - 320), to: CGPoint(x: h.x + 300, y: h.y + 10))
        XCTAssertTrue(fallingNotes.waitForExistence(timeout: 5))

        openToneSettings()
        let falling = app.buttons["roll-style-falling"]
        let horizontal = app.buttons["roll-style-horizontal"]
        XCTAssertTrue(falling.waitForExistence(timeout: 5))
        XCTAssertTrue(falling.isSelected, "The card shows the layout the pull chose.")
        XCTAssertFalse(horizontal.isSelected)
        horizontal.tap()
        wait("The Horizontal roll card is chosen") { horizontal.isSelected && !falling.isSelected }
        closeSettings()
        XCTAssertTrue(horizontalRoll.waitForExistence(timeout: 5))
        wait("The falling notes give way") { !self.fallingNotes.exists }
        XCTAssertEqual(cue, 2, accuracy: 0.001)

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(fallingNotes.waitForExistence(timeout: 5))
        openToneSettings()
        XCTAssertTrue(horizontal.waitForExistence(timeout: 5))
        XCTAssertTrue(horizontal.isSelected, "On its side the upright choice stays as it was.")
        XCTAssertFalse(falling.isSelected)
        closeSettings()
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(horizontalRoll.waitForExistence(timeout: 5))
    }

    /// The transcription screen's gear: this Tone's settings.
    private func openToneSettings() {
        app.buttons["tone-settings"].tap()
        XCTAssertTrue(element("tone-settings-sheet").waitForExistence(timeout: 5), "A Tone's Settings open.")
    }

    private func closeSettings() {
        let close = app.buttons["settings-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        wait("Settings close") { !close.exists }
    }

    /// Turned on its side, an iPhone shows the falling notes, 88 keys along
    /// the long edge, whatever the upright layout; upright again, the chosen
    /// layout comes back. The cue stays where it was both ways.
    func testTurningThePhoneOnItsSideShowsFallingNotesAndKeepsTheCue() {
        launch("song", cue: 4)
        XCTAssertTrue(horizontalRoll.waitForExistence(timeout: 5))
        wait("Cued at bar 3") { abs(self.cue - 4) < 0.001 }

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(fallingNotes.waitForExistence(timeout: 5))
        wait("The horizontal roll gives way") { !self.horizontalRoll.exists }
        let scrub = element("falling-notes-scrub")
        XCTAssertEqual(scrub.value as? String, "Bar 3 of 4, F, 0:04", "The cue is on the hit line.")
        assertLandscapeLayout()
        attachScreenshot("On its side: falling notes")

        // Scrub on its side, then stand it up: the roll shows the new cue.
        let before = cue
        scrub.swipeDown(velocity: .slow)
        wait("Scrubbed on its side") { abs(self.cue - before) > 0.4 }
        let scrubbed = cue
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(horizontalRoll.waitForExistence(timeout: 5))
        wait("The falling notes give way") { !self.fallingNotes.exists }
        XCTAssertEqual(cue, scrubbed, accuracy: 0.001)
        wait("The roll shows the cue on its play line") { abs(self.timeOnPlayLine - scrubbed) < 0.03 }
        XCTAssertEqual(element("roll-cue-marker").value as? String, "Out",
                       "The spot scrubbed to on its side is the user's: the marker shows it against the keys.")

        // Chosen falling notes stay falling notes either way up.
        launch("song", cue: 4, layout: "falling")
        XCTAssertTrue(fallingNotes.waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        wait("Still falling notes on its side") { self.fallingNotes.exists && !self.horizontalRoll.exists }
        XCTAssertEqual(element("falling-notes-scrub").value as? String, "Bar 3 of 4, F, 0:04")
        XCUIDevice.shared.orientation = .portrait
        wait("Still falling notes upright") { self.fallingNotes.exists && !self.horizontalRoll.exists }
    }

    /// On its side and upright again, the roll and the parts come back to
    /// the upright screen just as they were before the turn. Falling notes
    /// chosen, they once kept their width on its side: the keys came back
    /// magnified (about C3 to C6 across the screen) and the parts ran off its
    /// left edge, and stayed that way.
    func testTurningUprightAgainFitsTheRollToTheScreen() {
        launch("song", cue: 2, layout: "falling")
        XCTAssertTrue(fallingNotes.waitForExistence(timeout: 5))
        turnOnItsSideAndBack(keeping: ["falling-notes-view", "falling-notes-scrub", "falling-keyboard"] + partIDs)
        attachScreenshot("Falling notes upright again")

        launch("song", cue: 2)
        XCTAssertTrue(horizontalRoll.waitForExistence(timeout: 5))
        turnOnItsSideAndBack(keeping: ["piano-roll-scroll", "piano-keyboard"] + partIDs)
        attachScreenshot("Horizontal roll upright again")
    }

    private let partIDs = ["part-melody", "part-countermelody", "part-chords", "part-bass"]

    /// Turns the phone on its side and upright again: each element of `ids`
    /// that shows upright comes back to where it was, inside the screen.
    private func turnOnItsSideAndBack(keeping ids: [String], file: StaticString = #filePath, line: UInt = #line) {
        let window = app.windows.firstMatch
        let shown = ids.filter { element($0).waitForExistence(timeout: 5) }
        XCTAssertTrue(shown.contains("part-melody"), "The song's parts show.", file: file, line: line)
        func frames() -> [CGRect] { shown.map { element($0).frame } }
        let before = frames()
        for (id, frame) in zip(shown, before) {
            XCTAssertGreaterThanOrEqual(frame.minX, window.frame.minX - 0.5, "\(id) starts on screen.", file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, window.frame.maxX + 0.5, "\(id) ends on screen.", file: file, line: line)
        }

        XCUIDevice.shared.orientation = .landscapeLeft
        wait("On its side", file: file, line: line) { window.frame.width > window.frame.height }
        XCTAssertTrue(fallingNotes.waitForExistence(timeout: 5), file: file, line: line)
        assertLandscapeLayout(file: file, line: line)
        XCUIDevice.shared.orientation = .portrait
        wait("Upright", file: file, line: line) { window.frame.width < window.frame.height }

        func same(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1 && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
        }
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            zip(frames(), before).allSatisfy(same)
        }, object: nil)
        _ = XCTWaiter.wait(for: [settled], timeout: 5)
        for (id, (after, before)) in zip(shown, zip(frames(), before)) {
            XCTAssertTrue(same(after, before), "\(id) is back where it was: \(after), was \(before).", file: file, line: line)
            XCTAssertLessThanOrEqual(after.maxX, window.frame.maxX + 0.5, "\(id) ends on screen.", file: file, line: line)
        }
    }

    /// Playback carries on through a turn either way, the falling notes
    /// picking it up on their hit line and the roll on its play line.
    func testPlaybackCarriesOnWhileThePhoneTurns() {
        launch("song-long")
        XCTAssertTrue(horizontalRoll.waitForExistence(timeout: 5))
        app.buttons["playback-button"].tap()
        wait("Playback starts") { self.playing && self.cue > 0.5 }

        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertTrue(fallingNotes.waitForExistence(timeout: 5))
        wait("The horizontal roll gives way") { !self.horizontalRoll.exists }
        let turned = cue
        wait("Still playing on its side") { self.playing && self.cue > turned + 1 }
        assertLandscapeLayout()
        attachScreenshot("On its side: falling notes, playing")

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(horizontalRoll.waitForExistence(timeout: 5))
        let upright = cue
        wait("Still playing upright") { self.playing && self.cue > upright + 1 }
        let line = element("roll-playhead")
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        for _ in 0..<4 {
            XCTAssertEqual(line.frame.minX, horizontalRoll.frame.minX, accuracy: 2,
                           "The roll picked playback up on its play line.")
            Thread.sleep(forTimeInterval: 0.3)
        }
        app.buttons["playback-button"].tap()
        wait("Playback stops") { !self.playing }
    }

    /// While recording, the falling notes show what was just played coming in
    /// at the top and falling toward the keys. (The live edge sat on the
    /// keys, so everything recorded was drawn below them, out of sight.)
    /// Stopped, the take hands back to the scrubbable notes, the cue on the
    /// hit line. On its side, the same.
    func testWhileRecordingTheFallingNotesComeInAtTheTop() {
        // The song recorded up to 6.5 s and going on (the simulator can't record).
        launch("song", cue: 2, layout: "falling", extra: ["-semitone-fixture-recording", "6.5"])
        let notes = element("falling-notes-live")
        XCTAssertTrue(notes.waitForExistence(timeout: 5), "Recording: the live notes, not the scrubber.")
        XCTAssertFalse(element("falling-notes-scrub").exists)
        assertNotesComeInAtTheTop(notes)
        attachScreenshot("Recording: the notes come in at the top")

        app.buttons["record-button"].tap()
        let scrub = element("falling-notes-scrub")
        XCTAssertTrue(scrub.waitForExistence(timeout: 5), "Stopped: the notes scrub again.")
        wait("The live notes give way") { !notes.exists }
        XCTAssertEqual(cue, 2, accuracy: 0.001)
        let position = scrub.value as? String ?? ""
        XCTAssertTrue(position.hasPrefix("Bar 2 of") && position.hasSuffix("0:02"),
                      "The cue is on the hit line: \(position)")
        attachScreenshot("Stopped: back on the cue")
        scrub.swipeDown(velocity: .slow)
        wait("It scrubs") { abs(self.cue - 2) > 0.4 }

        launch("song", cue: 2, layout: "falling", extra: ["-semitone-fixture-recording", "6.5"])
        XCUIDevice.shared.orientation = .landscapeLeft
        let window = app.windows.firstMatch
        wait("On its side") { window.frame.width > window.frame.height }
        let sideways = element("falling-notes-live")
        XCTAssertTrue(sideways.waitForExistence(timeout: 5))
        assertNotesComeInAtTheTop(sideways)
        attachScreenshot("Recording on its side")
    }

    /// The top third of the falling notes is busy with the parts' colours
    /// (it was blank while recording), and so is the rest above the keys.
    private func assertNotesComeInAtTheTop(_ notes: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let thirds = colouredShares(of: notes.frame, bands: 3)
        let shares = thirds.map { String(format: "%.3f", $0) }.joined(separator: ", ")
        XCTAssertGreaterThan(thirds.first ?? 0, 0.03, "Notes at the top (coloured share by third: \(shares))",
                             file: file, line: line)
        XCTAssertGreaterThan(thirds.min() ?? 0, 0.03, "Notes all the way down (\(shares))", file: file, line: line)
    }

    /// The share of the pixels in each of `bands` bands of `area`, top to
    /// bottom, painted in a part's colour rather than the white, greys and
    /// black of the background, lanes and beat lines.
    private func colouredShares(of area: CGRect, bands: Int) -> [Double] {
        let upright = uprightScreenshot()
        guard let image = upright.cgImage else {
            XCTFail("Screenshot has no raster image")
            return []
        }
        let scale = CGFloat(image.width) / upright.size.width
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                                              CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
            return true
        }
        guard drawn else {
            XCTFail("Screenshot could not be read")
            return []
        }
        let x0 = max(Int(area.minX * scale), 0), x1 = min(Int(area.maxX * scale), image.width)
        return (0..<bands).map { band in
            let y0 = max(Int((area.minY + area.height * CGFloat(band) / CGFloat(bands)) * scale), 0)
            let y1 = min(Int((area.minY + area.height * CGFloat(band + 1) / CGFloat(bands)) * scale), image.height)
            var coloured = 0, total = 0
            for y in stride(from: y0, to: y1, by: 2) {
                for x in stride(from: x0, to: x1, by: 2) {
                    let offset = (y * image.width + x) * 4
                    let channels = [Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2])]
                    if channels.max()! - channels.min()! >= 60 { coloured += 1 }
                    total += 1
                }
            }
            return total > 0 ? Double(coloured) / Double(total) : 0
        }
    }

    /// On its side the toolbar, the parts and the notes all sit inside the
    /// safe area (clear of the Dynamic Island and the home indicator), the
    /// parts on one row, every control still a 44 pt target.
    private func assertLandscapeLayout(file: StaticString = #filePath, line: UInt = #line) {
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(window.width, window.height, "On its side.", file: file, line: line)
        let scrub = element("falling-notes-scrub")
        XCTAssertTrue(scrub.waitForExistence(timeout: 5), file: file, line: line)
        // The Dynamic Island is about 37 pt deep; the safe area keeps 62 pt clear on both sides.
        XCTAssertGreaterThanOrEqual(scrub.frame.minX, 50, "Clear of the Dynamic Island.", file: file, line: line)
        XCTAssertLessThanOrEqual(scrub.frame.maxX, window.maxX - 50, file: file, line: line)
        XCTAssertGreaterThanOrEqual(scrub.frame.height, 150, "Room for about 3 s of notes.", file: file, line: line)
        let chips = ["part-melody", "part-countermelody", "part-chords", "part-bass"].map(element)
        for chip in chips where chip.exists {
            XCTAssertLessThan(chip.frame.maxY, scrub.frame.minY + 1, file: file, line: line)
            XCTAssertGreaterThanOrEqual(chip.frame.height, 44, file: file, line: line)
        }
        let rows = Set(chips.filter(\.exists).map { Int($0.frame.midY.rounded()) })
        XCTAssertEqual(rows.count, 1, "The parts stay on one row.", file: file, line: line)
        for id in ["tone-settings", "playback-button", "record-button"] {
            XCTAssertTrue(element(id).isHittable, "\(id) is on screen.", file: file, line: line)
        }
    }

    /// Home turned on its side still shows its controls and Tones.
    func testHomeOnItsSide() {
        app?.terminate()
        app = XCUIApplication()
        app.launchArguments = ["-semitone-skip-intro", "-aiProvider", "off", "-semitone-home-sample-tones"]
        app.launch()
        XCTAssertTrue(app.buttons["home-record"].waitForExistence(timeout: 10))
        XCUIDevice.shared.orientation = .landscapeLeft
        let window = app.windows.firstMatch
        wait("On its side") { window.frame.width > window.frame.height }
        XCTAssertTrue(app.buttons["home-record"].isHittable)
        XCTAssertTrue(app.buttons["home-import"].isHittable)
        XCTAssertTrue(app.buttons["home-settings"].isHittable)
        let tone = app.buttons.matching(identifier: "home-tone").firstMatch
        XCTAssertTrue(tone.waitForExistence(timeout: 10))
        XCTAssertTrue(window.frame.contains(tone.frame) || tone.frame.minY > window.frame.maxY - 1,
                      "Tones lie within the screen's width.")
        attachScreenshot("Home on its side")
        app.swipeUp()
        attachScreenshot("Home on its side, scrolled")
        XCUIDevice.shared.orientation = .portrait
        wait("Upright") { window.frame.width < window.frame.height }
        XCTAssertTrue(app.buttons["home-record"].isHittable)
    }
}
