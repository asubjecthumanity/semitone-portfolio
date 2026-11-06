import XCTest
import CoreGraphics

/// Runs the production views with deterministic detected events. These tests
/// validate rendering/state integration, not model accuracy or audible output.
final class RegressionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        if let app, testRun?.hasSucceeded == false {
            attachScreenshot("Failure")
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "Accessibility hierarchy"
            tree.lifetime = .keepAlways
            add(tree)
        }
        app?.terminate()
    }

    private func launch(_ fixture: String, cue: Double = 0, textSize: String? = nil, layout: String? = nil,
                        extra: [String] = []) {
        app?.terminate()
        app = XCUIApplication()
        app.launchArguments = ["-semitone-ui-fixture", fixture,
                               "-semitone-fixture-cue", String(cue),
                               "-aiProvider", "off"] + extra
        if let textSize { app.launchArguments += ["-UIPreferredContentSizeCategoryName", textSize] }
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

    private func wait(_ description: String, timeout: TimeInterval = 8,
                      file: StaticString = #filePath, line: UInt = #line,
                      until condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
                       "\(description). Actual fixture state: \(state)", file: file, line: line)
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testFullPianoRangeAlignsBothEdgeNotesWithKeyboard() {
        launch("piano-range")
        let scroll = element("piano-roll-scroll")
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))

        // A take spanning all 88 keys is taller than the screen. Visit both
        // ends with actual scroll gestures and inspect the painted Canvas pixels.
        for _ in 0..<4 {
            if element("piano-key-108").exists { break }
            scroll.swipeDown()
        }
        wait("C8 is visible at the top") { self.element("piano-key-108").exists }
        assertAligned(pitch: 108)
        attachScreenshot("SEM-018 C8 MIDI 108")

        for _ in 0..<4 {
            if element("piano-key-21").exists { break }
            scroll.swipeUp()
        }
        wait("A0 is visible at the bottom") { self.element("piano-key-21").exists }
        assertAligned(pitch: 21)
        attachScreenshot("SEM-018 A0 MIDI 21")
        XCTAssertLessThan(cue, 0.1, "Vertical swipes must leave the horizontal cue at the start.")
    }

    private func assertAligned(pitch: Int, file: StaticString = #filePath, line: UInt = #line) {
        let key = element("piano-key-\(pitch)")
        XCTAssertGreaterThan(key.frame.height, 0, file: file, line: line)
        XCTAssertTrue(element("piano-keyboard").frame.contains(key.frame),
                      "The key must be inside the painted keyboard", file: file, line: line)
        // Canvas virtual children can report union frames for positioned
        // siblings. Measure the actual blue bar independently of those proxies.
        guard let image = app.screenshot().image.cgImage else {
            return XCTFail("Screenshot has no raster image", file: file, line: line)
        }
        let scale = CGFloat(image.width) / app.frame.width
        let scrollFrame = element("piano-roll-scroll").frame
        let x0 = max(0, Int((scrollFrame.minX + 70) * scale))
        let x1 = min(image.width, Int((scrollFrame.minX + 145) * scale))
        let y0 = max(0, Int((key.frame.midY - 10) * scale))
        let y1 = min(image.height, Int((key.frame.midY + 10) * scale))
        guard x1 > x0, y1 > y0 else {
            return XCTFail("Piano row lies outside the screenshot", file: file, line: line)
        }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                                              CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
            return true
        }
        XCTAssertTrue(rendered, file: file, line: line)
        guard rendered else { return }
        let blueRows = (y0..<y1).filter { y in
            let blueCount = (x0..<x1).filter { x in
                let offset = (y * image.width + x) * 4
                let red = Int(bytes[offset]), green = Int(bytes[offset + 1]), blue = Int(bytes[offset + 2])
                return blue > 130 && blue > red + 70 && blue > green + 35
            }.count
            return blueCount * 2 > x1 - x0
        }
        guard let first = blueRows.first, let last = blueRows.last else {
            return XCTFail("The painted MIDI \(pitch) note is missing beside its key", file: file, line: line)
        }
        let paintedHeight = CGFloat(last - first + 1) / scale
        let paintedCenter = CGFloat(first + last + 1) / (2 * scale)
        XCTAssertEqual(blueRows.count, last - first + 1,
                       "The painted note must form one contiguous band", file: file, line: line)
        XCTAssertTrue((8...13).contains(paintedHeight), "The bar must occupy one note row", file: file, line: line)
        XCTAssertEqual(paintedCenter, key.frame.midY, accuracy: 2,
                       "The painted edge note and pinned piano key must share a row.", file: file, line: line)
    }

    /// The keyboard is a little bigger (56 pt keys, 15 pt rows) and runs
    /// down to the bottom edge, like the roll beside it.
    func testHorizontalKeyboardIsBiggerAndReachesTheBottomEdge() {
        launch("piano-range")
        let keyboard = element("piano-keyboard")
        let scroll = element("piano-roll-scroll")
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        let key = element("piano-key-60")
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        XCTAssertEqual(keyboard.frame.width, 56, accuracy: 0.5)
        XCTAssertEqual(key.frame.height, 15, accuracy: 0.5)
        XCTAssertEqual(keyboard.frame.minX + 56, scroll.frame.minX, accuracy: 0.5)
        XCTAssertEqual(keyboard.frame.maxY, scroll.frame.maxY, accuracy: 0.5, "No roll without keys at the bottom.")
        XCTAssertEqual(keyboard.frame.maxY, app.windows.firstMatch.frame.maxY, accuracy: 0.5)
    }

    /// During playback the roll moves under a fixed play line, the
    /// keyboard's edge: the play marker stays put on screen, against the
    /// keys, while the time runs on.
    func testHorizontalRollFollowsPlaybackOnThePlayLine() {
        launch("song-long")
        let scroll = element("piano-roll-scroll")
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        app.buttons["playback-button"].tap()
        wait("Playback starts") { self.state.contains("playing=true") }
        let line = element("roll-playhead")
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        let playLine = scroll.frame.minX
        let first = cue
        var offsets: [CGFloat] = []
        for _ in 0..<6 {
            offsets.append(line.frame.minX - playLine)
            Thread.sleep(forTimeInterval: 0.3)
        }
        wait("Time runs on") { self.cue > first + 1.5 }
        for offset in offsets {
            XCTAssertEqual(offset, 0, accuracy: 2, "The playhead stays on the play line: \(offsets)")
        }
        attachScreenshot("Horizontal roll following playback")
        app.buttons["playback-button"].tap()
        wait("Playback stops") { self.state.contains("playing=false") }
    }

    /// During playback a drag through the horizontal roll holds the sound
    /// and scrubs, as on the falling notes, and playback carries on from the
    /// play line; a drag only up or down keeps playing.
    func testHorizontalRollDragDuringPlaybackScrubsThenPlaysOn() {
        launch("song-long", cue: 20)
        let scroll = element("piano-roll-scroll")
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        app.buttons["playback-button"].tap()
        wait("Playback starts") { self.state.contains("playing=true") && self.cue > 20.3 }
        let before = cue
        let started = Date()
        // Finger right about 2.3 s (250 pt at 110 pt/s): back in time, and
        // the sound held for the second or so the drag takes. Had playback
        // carried on under the drag, the cue would be where it was plus the
        // time gone by (however long the test takes to start the drag).
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 250, dy: 0)),
                    withVelocity: 300, thenHoldForDuration: 0.4)
        wait("The drag moved playback back and it plays on", timeout: 3) {
            self.state.contains("playing=true") && self.cue < before + Date().timeIntervalSince(started) - 2
        }
        let after = cue
        wait("Playback carries on from there") { self.cue > after + 0.5 }
        let line = element("roll-playhead")
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        XCTAssertEqual(line.frame.minX, scroll.frame.minX, accuracy: 2, "Followed again, on the play line.")
        attachScreenshot("Horizontal roll playing on after a scrub")

        // Up or down only: a look at other notes, and playback goes on.
        let playing = cue
        let middle = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        middle.press(forDuration: 0.1, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: -150)),
                     withVelocity: 300, thenHoldForDuration: 0.3)
        XCTAssertTrue(state.contains("playing=true"))
        XCTAssertGreaterThan(cue, playing + 0.4, "Playback went on under a drag up or down.")
        wait("The roll caught up at once (it used to wait 2.5 s)", timeout: 1.5) {
            abs(line.frame.minX - scroll.frame.minX) < 2
        }
        app.buttons["playback-button"].tap()
        wait("Playback stops") { self.state.contains("playing=false") }
    }

    /// The play marker: 3 pt wide, against the keys while playing. Stopped
    /// where the take opened, or where playback stopped, it waits behind the
    /// keys, so the notes on the play line meet them; dragged to a spot while
    /// stopped, it comes out against the keys to show where play will start.
    func testPlayMarkerSitsBehindTheKeysUntilTheUserPicksASpot() {
        launch("song-long", cue: 20)
        let scroll = element("piano-roll-scroll")
        let keyboard = element("piano-keyboard")
        let marker = element("roll-cue-marker")
        let playing = element("roll-playhead")
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        XCTAssertEqual(keyboard.frame.maxX, scroll.frame.minX, accuracy: 0.5, "The play line is the keyboard's edge.")
        wait("Opened on its cue") { abs(self.cue - 20) < 0.001 }
        XCTAssertTrue(marker.waitForExistence(timeout: 5))
        wait("Where the take opened, the marker waits behind the keys") { marker.value as? String == "Behind the keys" }
        XCTAssertFalse(playing.exists)
        attachScreenshot("Play marker: stopped where the take opened, behind the keys")

        app.buttons["playback-button"].tap()
        wait("Playback starts") { self.state.contains("playing=true") && self.cue > 20.3 }
        XCTAssertTrue(playing.waitForExistence(timeout: 5))
        XCTAssertEqual(playing.frame.minX, scroll.frame.minX, accuracy: 1, "Playing, the marker's left edge is against the keys.")
        XCTAssertEqual(playing.frame.width, 3, accuracy: 0.5, "Twice the old 1.5 pt line.")
        XCTAssertFalse(marker.exists, "One marker while playing.")
        attachScreenshot("Play marker: playing, against the keys")

        app.buttons["playback-button"].tap()
        wait("Playback stops") { self.state.contains("playing=false") }
        wait("Stopped, the marker tucks back behind the keys") {
            marker.value as? String == "Behind the keys" && !playing.exists
        }
        let stopped = cue

        // A drag up or down picks no spot, even when the roll then settles
        // onto a beat beside the stop (the beat snap after any drag).
        let middle = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        middle.press(forDuration: 0.1, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: -120)),
                     withVelocity: 300, thenHoldForDuration: 0.3)
        XCTAssertEqual(marker.value as? String, "Behind the keys", "Up or down only, nothing is picked.")
        XCTAssertEqual(cue, stopped, accuracy: 0.33, "At most the snap's catch zone away.")

        // Through time (finger left about 2 s: later in the take), it comes out.
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: -220, dy: 0)),
                    withVelocity: 300, thenHoldForDuration: 0.4)
        wait("Dragged to a spot, the marker comes out") { marker.value as? String == "Out" }
        wait("The drag cued later in the take") { self.cue > stopped + 1.5 }
        XCTAssertEqual(marker.frame.minX, scroll.frame.minX, accuracy: 0.5, "Out, against the keys.")
        XCTAssertEqual(marker.frame.width, 3, accuracy: 0.5)
        XCTAssertEqual(marker.frame.maxY, keyboard.frame.maxY, accuracy: 0.5, "Down to the bottom edge, as the keys run.")
        XCTAssertTrue(state.contains("playing=false"))
        attachScreenshot("Play marker: stopped after a drag, out against the keys")

        // Play from there and stop: back behind the keys.
        app.buttons["playback-button"].tap()
        wait("Playback starts from the spot") { self.state.contains("playing=true") }
        XCTAssertTrue(playing.waitForExistence(timeout: 5))
        XCTAssertEqual(playing.frame.minX, scroll.frame.minX, accuracy: 1)
        app.buttons["playback-button"].tap()
        wait("Playback stops") { self.state.contains("playing=false") }
        wait("And the marker tucks back behind the keys") {
            marker.value as? String == "Behind the keys" && !playing.exists
        }
    }

    /// Drags the element's content by `dy` points, holding at the end so it
    /// doesn't fling.
    private func drag(_ element: XCUIElement, from y: CGFloat, by dy: CGFloat) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: y))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: dy)),
                    withVelocity: 300, thenHoldForDuration: 0.4)
    }

    /// Falling notes follow the finger: up goes back in time, down runs the
    /// notes in. Let go and they settle on a nearby bar and cue there; a
    /// flick coasts and stops at either end of the take.
    func testFallingNotesScrubSettlesOnABarAndCuesThere() {
        launch("song", cue: 4, layout: "falling")
        let scrub = element("falling-notes-scrub")
        XCTAssertTrue(scrub.waitForExistence(timeout: 5))
        XCTAssertFalse(element("piano-roll-scroll").exists)
        wait("Cued at bar 3") { abs(self.cue - 4) < 0.001 }
        XCTAssertEqual(scrub.value as? String, "Bar 3 of 4, F, 0:04")

        // Finger up about 2 s (240 pt at 120 pt/s): back to bar 2.
        drag(scrub, from: 0.8, by: -250)
        wait("Dragging up went back and settled on bar 2") { abs(self.cue - 2) < 0.001 }
        XCTAssertEqual(scrub.value as? String, "Bar 2 of 4, Am, 0:02")
        attachScreenshot("Falling notes scrubbed back to bar 2")

        // Finger down about 2 s: on to bar 3.
        drag(scrub, from: 0.2, by: 230)
        wait("Dragging down ran the notes in and settled on bar 3") { abs(self.cue - 4) < 0.001 }

        // A flick coasts well past the finger and stops at either end.
        scrub.swipeDown(velocity: .fast)
        wait("A flick down coasts to the end") { abs(self.cue - 8) < 0.001 }
        scrub.swipeUp(velocity: .fast)
        wait("A flick up coasts back more than half the take") { self.cue < 4 }
        scrub.swipeUp(velocity: .fast)
        wait("Another stops at 0:00") { abs(self.cue) < 0.001 }
        XCTAssertTrue(state.contains("playing=false"))
    }

    /// During playback a drag holds the sound and scrubs; playback then
    /// carries on from the hit line.
    func testFallingNotesDragDuringPlaybackScrubsThenPlaysOn() {
        launch("song-long", layout: "falling")
        let scrub = element("falling-notes-scrub")
        XCTAssertTrue(scrub.waitForExistence(timeout: 5))
        app.buttons["playback-button"].tap()
        wait("Playback starts") { self.state.contains("playing=true") && self.cue > 0.5 }
        let before = cue
        // About 3.75 s forward. Without the scrub, the gesture's 1.6 s would
        // move the cue under 2 s.
        drag(scrub, from: 0.05, by: 450)
        wait("The drag moved playback forward and it plays on", timeout: 3) {
            self.state.contains("playing=true") && self.cue > before + 3
        }
        let after = cue
        wait("Playback carries on from there") { self.cue > after + 0.5 }
        attachScreenshot("Falling notes playing on after a scrub")
        app.buttons["playback-button"].tap()
        wait("Playback stops") { self.state.contains("playing=false") }
    }

    func testChordLabelUsesSegmentContainmentAndPreservesShortRestBridge() {
        let cases: [(Double, String?)] = [
            (0, nil), (1, "C"), (1.5, "C"), (2, nil),
            (3.5, nil), (5, "G"), (6, nil), (7.8, "C"), (8.6, nil)
        ]
        for (time, expected) in cases {
            launch("chords", cue: time)
            wait("The fixture reached cue \(time)") { abs(self.cue - time) < 0.001 }
            let chord = element("current-chord")
            if let expected {
                XCTAssertTrue(chord.exists, "Expected chord \(expected) at \(time).")
                XCTAssertEqual(chord.label, expected)
            } else {
                XCTAssertFalse(chord.exists, "No stale or future chord should display at \(time).")
            }
            if time == 3.5 { attachScreenshot("SEM-057 long rest has no chord") }
        }
    }

    func testStoppedRollGestureCuesLongRestWithoutStaleChord() {
        launch("chords")
        let scroll = element("piano-roll-scroll")
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        start.press(forDuration: 0.15, thenDragTo: end)
        wait("Horizontal dragging settled in the long rest") { self.cue >= 2 && self.cue < 5 }
        XCTAssertFalse(element("current-chord").exists)
        attachScreenshot("SEM-057 actual scroll cue in long rest")
    }

    func testPartVisibilityControlsPlaybackAndMIDIExport() {
        launch("parts")
        let play = app.buttons["playback-button"]
        XCTAssertTrue(play.isEnabled)
        XCTAssertFalse(app.buttons["part-drums"].exists, "Any-instrument takes have no drum part.")
        for part in ["melody", "countermelody", "chords", "bass"] {
            let chip = app.buttons["part-\(part)"]
            XCTAssertEqual(chip.value as? String, "Shown")
            chip.tap()
            XCTAssertEqual(chip.value as? String, "Hidden")
        }
        wait("All hidden notes are absent and export is disabled") {
            self.state.contains("visible=0") && self.state.contains("export=false")
        }
        XCTAssertFalse(play.isEnabled)

        app.buttons["part-melody"].tap()
        wait("Restoring melody restores playback and export") {
            self.state.contains("visible=1") && self.state.contains("export=true")
        }
        XCTAssertTrue(play.isEnabled)
        attachScreenshot("Shown melody permits MIDI export")
    }

    func testHidingLastAudiblePartStopsActivePlayback() {
        launch("parts")
        app.buttons["playback-button"].tap()
        wait("AVAudioSequencer playback starts") { self.state.contains("playing=true") }
        app.buttons["part-melody"].tap()
        XCTAssertTrue(state.contains("playing=true"), "Remaining parts keep playback running.")
        for part in ["countermelody", "chords", "bass"] { app.buttons["part-\(part)"].tap() }
        wait("Muting the last part stops playback") { self.state.contains("playing=false") }
        XCTAssertFalse(app.buttons["playback-button"].isEnabled)
        XCTAssertFalse(app.alerts["Something went wrong"].exists)
    }

    func testSongResultListsEveryPartInOrderWithCountermelody() {
        launch("song")
        let order = ["melody", "countermelody", "chords", "bass"]
        let chips = order.map { app.buttons["part-\($0)"] }
        for (part, chip) in zip(order, chips) {
            XCTAssertTrue(chip.exists, "The \(part) chip is shown.")
            XCTAssertEqual(chip.value as? String, "Shown")
        }
        assertReadingOrder(chips, "Parts are listed melody, countermelody, chords, bass.")
        wait("All 56 notes are visible") { self.state.contains("visible=56") }
        chips[1].tap()
        wait("Hiding the countermelody hides its four notes") { self.state.contains("visible=52") }
        chips[1].tap()
        attachScreenshot("Song result with a countermelody")
    }

    /// At the largest non-accessibility text size the four chips wrap
    /// instead of pushing the bass chip off screen.
    func testSongPartChipsStayOnScreenWithLargeText() {
        launch("song", textSize: "UICTContentSizeCategoryXXXL")
        let order = ["melody", "countermelody", "chords", "bass"]
        let chips = order.map { app.buttons["part-\($0)"] }
        let screen = app.windows.firstMatch.frame
        for (part, chip) in zip(order, chips) {
            XCTAssertTrue(chip.waitForExistence(timeout: 5), "The \(part) chip is shown.")
            XCTAssertTrue(screen.contains(chip.frame), "The \(part) chip lies on screen: \(chip.frame) in \(screen).")
        }
        assertReadingOrder(chips, "Wrapped parts still read melody, countermelody, chords, bass.")
        let style = app.buttons["chord-style"]
        XCTAssertTrue(screen.contains(style.frame), "The chord style pop-up lies on screen: \(style.frame) in \(screen).")
        assertReadingOrder([chips[2], style, chips[3]], "The chord style follows the Chords chip.")
        chips[3].tap()
        XCTAssertEqual(chips[3].value as? String, "Hidden")
        attachScreenshot("Song parts with large text")
    }

    /// At the largest accessibility text size the Countermelody chip alone
    /// is wider than the screen, so the bar scrolls sideways. The chord
    /// style pop-up then takes a row of its own under the chips: beside the
    /// Chords chip it pushed the Bass chip out of sight.
    func testChordStylePopUpLeavesTheBassChipOnScreenAtAccessibilitySizes() {
        launch("song-transcribed", textSize: "UICTContentSizeCategoryAccessibilityXXXL")
        let screen = app.windows.firstMatch.frame
        let chords = app.buttons["part-chords"], bass = app.buttons["part-bass"], style = app.buttons["chord-style"]
        for (name, element) in [("Chords chip", chords), ("Bass chip", bass), ("chord style pop-up", style)] {
            XCTAssertTrue(element.waitForExistence(timeout: 5), "The \(name) is shown.")
            XCTAssertTrue(screen.contains(element.frame), "The \(name) lies on screen: \(element.frame) in \(screen).")
            XCTAssertTrue(element.isHittable, "The \(name) can be tapped without scrolling.")
        }
        XCTAssertGreaterThanOrEqual(style.frame.minY, bass.frame.maxY - 1, "The pop-up has a row under the chips.")
        attachScreenshot("Song parts at the largest accessibility text size")
        bass.tap()
        XCTAssertEqual(bass.value as? String, "Hidden")
        choose("Simplified", in: style)
        wait("The pop-up on its own row still switches the style") { self.state.contains("chordStyle=simplified") }
    }

    /// The chords part's style pop-up sits beside its chip. As played shows
    /// the transcribed chord notes (34: open, doubled shapes); Simplified
    /// shows the chord names' voicings instead (12: C, Am, F and G, three
    /// notes each, struck once and held to the change, 0.79) and leaves the
    /// other parts alone; hiding the chords
    /// hides either; Simplified chords play. (Switching while playing is the
    /// hosted tests' job: the menu's idle waits outlast this 8 s fixture.)
    func testChordStyleSwitchesTheChordsPartBetweenAsPlayedAndSimplified() {
        launch("song-transcribed")
        let style = app.buttons["chord-style"]
        let chords = app.buttons["part-chords"]
        XCTAssertTrue(style.waitForExistence(timeout: 5))
        XCTAssertEqual(style.label, "Chord notes")
        XCTAssertEqual(style.value as? String, "As played")
        XCTAssertGreaterThanOrEqual(style.frame.height, 44, "The pop-up is a 44 pt target.")
        XCTAssertGreaterThanOrEqual(chords.frame.height, 44, "So is the chip beside it.")
        XCTAssertEqual(style.frame.midY, chords.frame.midY, accuracy: 1, "On the Chords chip's row.")
        XCTAssertGreaterThan(style.frame.minX, chords.frame.maxX - 1, "Right of the Chords chip.")
        wait("The transcribed chords show") {
            self.state.contains("chordStyle=asPlayed") && self.state.contains("chordNotes=34/2087")
                && self.state.contains("visible=66")
        }
        attachScreenshot("Song result, chords as played")

        choose("Simplified", in: style)
        wait("The chord names' voicings show instead") {
            self.state.contains("chordStyle=simplified") && self.state.contains("chordNotes=12/766")
                && self.state.contains("visible=44")
        }
        XCTAssertEqual(style.value as? String, "Simplified")
        attachScreenshot("Song result, chords simplified")

        chords.tap()
        wait("Hiding the chords hides the voicings") {
            self.state.contains("chordNotes=0/0") && self.state.contains("visible=32")
        }
        chords.tap()
        app.buttons["playback-button"].tap()
        wait("Simplified chords play") { self.state.contains("playing=true") }
        app.buttons["playback-button"].tap()
        wait("Playback stops") { self.state.contains("playing=false") }
        choose("As played", in: style)
        wait("As played brings the transcribed chords back") {
            self.state.contains("chordStyle=asPlayed") && self.state.contains("chordNotes=34/2087")
        }
        XCTAssertEqual(style.value as? String, "As played")
        XCTAssertFalse(app.alerts["Something went wrong"].exists)
    }

    private func choose(_ option: String, in menu: XCUIElement) {
        menu.tap()
        let item = app.buttons[option]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "The menu offers \(option).")
        item.tap()
    }

    /// Left to right, row by row.
    private func assertReadingOrder(_ elements: [XCUIElement], _ message: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let frames = elements.map(\.frame)
        let order = frames.indices.sorted {
            (frames[$0].midY.rounded(), frames[$0].minX) < (frames[$1].midY.rounded(), frames[$1].minX)
        }
        XCTAssertEqual(order, Array(frames.indices), message, file: file, line: line)
    }

    func testSustainCompletionAndImmediateManualStop() {
        launch("sustain")
        app.buttons["playback-button"].tap()
        wait("Sustain fixture playback starts") { self.state.contains("playing=true") }
        wait("Natural completion includes the pedal and release tail", timeout: 10) {
            self.state.contains("playing=false")
        }
        XCTAssertEqual(cue, 4.5, accuracy: 0.15,
                       "One-second note plus pedal through three seconds and 1.5-second tail.")

        launch("sustain")
        app.buttons["playback-button"].tap()
        wait("Playback starts for manual-stop check") { self.state.contains("playing=true") }
        app.buttons["playback-button"].tap()
        wait("Manual Stop takes effect", timeout: 2) { self.state.contains("playing=false") }
        XCTAssertLessThan(cue, 4.4, "Manual Stop must not wait for the release tail.")
        XCTAssertFalse(app.alerts["Something went wrong"].exists)
    }

    func testSettingsCanSwitchBetweenBothActualRollLayouts() {
        launch("piano-range")
        openToneSettings()
        let falling = app.buttons["Falling notes"]
        XCTAssertTrue(falling.waitForExistence(timeout: 5))
        XCTAssertFalse(falling.isSelected)
        falling.tap()
        wait("The Falling notes card is chosen") { falling.isSelected }
        closeSettings()
        wait("Horizontal roll disappears after choosing falling notes") {
            !self.element("piano-roll-scroll").exists
        }
        attachScreenshot("SEM-018 full keyboard in falling layout")
        openToneSettings()
        app.buttons["Horizontal roll"].tap()
        closeSettings()
        XCTAssertTrue(element("piano-roll-scroll").waitForExistence(timeout: 5))
    }

    // MARK: Settings

    /// The transcription screen's gear: this Tone's settings.
    private func openToneSettings() {
        app.buttons["tone-settings"].tap()
        XCTAssertTrue(element("tone-settings-sheet").waitForExistence(timeout: 5), "A Tone's Settings open.")
    }

    /// The Liquid Glass close button, on any page of either sheet.
    private func closeSettings() {
        let close = app.buttons["settings-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertEqual(close.label, "Close Settings")
        // The system's glass circle is 44 pt; the frame reported is the
        // glyph's button inside it.
        XCTAssertTrue(close.isHittable)
        close.tap()
        wait("Settings close") { !close.exists }
    }

    /// The section headers on screen's sheet, top to bottom.
    private var settingsSections: [String] {
        let headers = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'settings-section-'")).allElementsBoundByIndex
        return headers.sorted { $0.frame.minY < $1.frame.minY }
            .map { String($0.identifier.dropFirst("settings-section-".count)) }
    }

    /// Scrolls the open Settings page up by about half a screen, from its
    /// lower part (clear of the sideways preset row).
    private func scrollSettingsUp() {
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        from.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
    }

    /// Goes back a page in the open Settings sheet (the glass back button).
    private func settingsBack() {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
    }

    /// Home's Settings hold what applies to the whole app and to new takes:
    /// transcription, AI cleanup, importing from links, playback and
    /// credits. Nothing of a Tone's own.
    func testHomeSettingsHoldOnlyAppWideSettings() {
        launchHome()
        app.buttons["home-settings"].tap()
        XCTAssertTrue(element("home-settings-sheet").waitForExistence(timeout: 5), "Home's Settings open.")
        XCTAssertEqual(settingsSections, ["transcription", "ai", "experimental", "playback"])
        for id in ["settings-piano-model-default", "settings-ai-cleanup", "settings-link-import", "settings-playback"] {
            XCTAssertTrue(element(id).exists, "Home's Settings have \(id).")
            // (Within a rounding error: a frame laid out at a fractional y
            // can come back as 43.99999999999994.)
            XCTAssertGreaterThanOrEqual(element(id).frame.height, 44 - 1e-6, "\(id) is a 44 pt target.")
        }
        for id in ["roll-style-horizontal", "preset-auto", "tone-beat-grid", "tone-show-beat-grid"] {
            XCTAssertFalse(element(id).exists, "\(id) belongs to a Tone's Settings.")
        }
        XCTAssertFalse(menuItem("Transcription").exists, "A Tone's transcription is in its long-press menu.")
        let linkSwitch = element("settings-link-import").switches.firstMatch
        XCTAssertEqual(linkSwitch.label, "Import from links, Experimental")
        // The whole row flips the switch, not only the switch itself.
        let linkOn = linkSwitch.value as? String
        element("settings-link-import").coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).tap()
        wait("A tap at the row's leading edge flips it") { linkSwitch.value as? String != linkOn }
        linkSwitch.tap()
        wait("A tap on the switch flips it back, once") { linkSwitch.value as? String == linkOn }
        attachScreenshot("Home Settings")

        app.buttons["settings-ai-cleanup"].tap()
        XCTAssertTrue(element("settings-ai-provider").waitForExistence(timeout: 5), "AI cleanup has its own page.")
        XCTAssertEqual(element("settings-ai-provider").value as? String, "Off")
        XCTAssertTrue(element("settings-ai-cleanup-toggle").exists)
        XCTAssertFalse(app.buttons["Clean up with AI"].exists,
                       "Cleaning up a Tone is under Transcription in its long-press menu.")
        attachScreenshot("Home Settings, AI cleanup")
        settingsBack()

        app.buttons["settings-playback"].tap()
        XCTAssertTrue(app.staticTexts["Piano sound, Yamaha grand"].waitForExistence(timeout: 5))
        attachScreenshot("Home Settings, Playback and credits")
        closeSettings()
        XCTAssertTrue(app.buttons["home-record"].isHittable)
    }

    /// A Tone's Settings hold the three groups the owner gave them: roll
    /// style, the detection presets and the beat grid, whose page has beats
    /// per bar, tempo and bar lines. Nothing app-wide, and nothing that acts
    /// on the take (transcribing it again, its piano model, its AI cleanup:
    /// those are under Transcription in its long-press menu on Home).
    func testToneSettingsHoldOnlyThisTonesSettings() {
        launch("song")
        openToneSettings()
        XCTAssertEqual(settingsSections, ["roll-style", "detection", "beat-grid"])
        for id in ["roll-style-horizontal", "roll-style-falling", "preset-auto", "preset-gentle", "preset-piano",
                   "preset-dense", "preset-custom", "tone-beat-grid", "tone-show-beat-grid"] {
            XCTAssertTrue(element(id).exists, "A Tone's Settings have \(id).")
        }
        for id in ["settings-piano-model-default", "settings-ai-cleanup", "settings-link-import", "settings-playback",
                   "settings-ai-provider"] {
            XCTAssertFalse(element(id).exists, "\(id) belongs to Home's Settings.")
        }
        for title in ["Transcribed as", "High-accuracy piano model", "Clean up with AI", "Revert to raw"] {
            XCTAssertFalse(app.staticTexts[title].exists || app.buttons[title].exists || app.switches[title].exists,
                           "\(title) is under Transcription in the Tone's long-press menu.")
        }
        XCTAssertTrue(app.buttons["Horizontal roll"].isSelected)
        XCTAssertTrue(app.buttons["preset-\(presetSelected)"].isSelected)
        XCTAssertEqual(app.buttons["preset-piano"].label, "Balanced", "The balanced preset is named for mixed instruments.")
        XCTAssertTrue((element("tone-beat-grid").value as? String ?? "").hasPrefix("4 beats per bar · 120 BPM"),
                      element("tone-beat-grid").value as? String ?? "")
        attachScreenshot("Tone Settings")

        element("tone-beat-grid").tap()
        XCTAssertTrue(element("beat-grid-page").waitForExistence(timeout: 5), "The beat grid has its own page.")
        XCTAssertEqual(settingsSections, ["beats-per-bar", "tempo", "bars"])
        XCTAssertTrue(element("beat-grid-detected").label.hasPrefix("Detected: 4 beats per bar · 120 BPM."),
                      element("beat-grid-detected").label)
        XCTAssertTrue(app.buttons["beats-per-bar-0"].isSelected, "Auto (3 to 5) is the default.")
        XCTAssertEqual(app.buttons["beats-per-bar-0"].label, "Auto, 3 to 5")
        XCTAssertTrue(app.buttons["tempo-0"].isSelected)
        for id in ["beats-per-bar-0", "beats-per-bar-7", "tempo--1", "tempo-1", "bar-lines-earlier", "bar-lines-later"] {
            let control = app.buttons[id]
            XCTAssertGreaterThanOrEqual(control.frame.height, 44, "\(id) is a 44 pt target.")
            XCTAssertGreaterThanOrEqual(control.frame.width, 44, "\(id) is a 44 pt target.")
        }
        attachScreenshot("Tone Settings, Beat grid")

        // Each choice lands on the take: the bar lines move a beat later and back.
        app.buttons["bar-lines-later"].tap()
        wait("The nudge reads +1 beat") { self.element("bar-lines-value").label == "Bar lines, +1 beat" }
        app.buttons["bar-lines-earlier"].tap()
        wait("And back") { self.element("bar-lines-value").label == "Bar lines, as detected" }
        app.buttons["tempo--1"].tap()
        wait("Half tempo is chosen") { self.app.buttons["tempo--1"].isSelected }
        app.buttons["tempo-0"].tap()
        wait("As detected again") { self.app.buttons["tempo-0"].isSelected }
        settingsBack()
        XCTAssertTrue(element("tone-settings-sheet").waitForExistence(timeout: 5))
        closeSettings()
        XCTAssertFalse(app.alerts["Something went wrong"].exists)
    }

    /// The transcription screen's gear opens the Tone's Settings at once:
    /// no drop-down, nothing else to choose (importing, the saved Tones, the
    /// MIDI export and the take's transcription are all on Home).
    func testGearOpensTheTonesSettingsAtOnce() {
        launch("song")
        let gear = app.buttons["tone-settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 5))
        XCTAssertEqual(gear.label, "Settings")
        gear.tap()
        XCTAssertTrue(element("tone-settings-sheet").waitForExistence(timeout: 5), "One tap opens the Tone's Settings.")
        XCTAssertEqual(settingsSections, ["roll-style", "detection", "beat-grid"])
        for title in ["Import audio or video", "Import from Photos", "Import from link", "Saved takes",
                      "Export MIDI file", "Transcription"] {
            XCTAssertFalse(menuItem(title).exists, "\(title) isn't behind the gear any more.")
        }
        attachScreenshot("gear-settings")
        closeSettings()
        XCTAssertTrue(gear.isHittable)
        XCTAssertFalse(app.alerts["Something went wrong"].exists)
    }

    /// A Tone's row on Home, by the start of its VoiceOver label (its title).
    private func tone(_ title: String) -> XCUIElement {
        app.buttons.matching(identifier: "home-tone").matching(NSPredicate(format: "label BEGINSWITH %@", "\(title).")).firstMatch
    }

    /// Touches and holds a Tone's row until its long-press menu is up.
    private func openToneMenu(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = tone(title)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "\(title) is on Home.", file: file, line: line)
        row.press(forDuration: 1.2)
        XCTAssertTrue(menuItem("Rename").waitForExistence(timeout: 5), "\(title)'s long-press menu is up.",
                      file: file, line: line)
        // A tap while the menu is still settling is lost.
        Thread.sleep(forTimeInterval: 1)
    }

    /// Opens the Transcription submenu of the long-press menu that's up.
    private func openTranscriptionSubmenu(file: StaticString = #filePath, line: UInt = #line) {
        menuItem("Transcription").tap()
        let items = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Transcribed as '"))
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 5), "The Transcription submenu opens.",
                      file: file, line: line)
        Thread.sleep(forTimeInterval: 1)
    }

    /// Closes an open long-press menu (a tap outside it, at the masthead).
    private func dismissToneMenu() {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        wait("The menu closes") { !self.menuItem("Rename").exists }
    }

    /// The transcription screen's readout: "42 notes · 0:08".
    private var noteReadout: XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS ' notes · ' OR label CONTAINS ' note · '")).firstMatch
    }

    /// A Tone's long-press menu on Home: Rename, Export MIDI file, its
    /// Transcription (how it was transcribed, named as Home names its row,
    /// with the other kind to transcribe it again, and on a Piano Tone its
    /// piano-model switch), and Delete.
    func testToneLongPressMenuOffersExportAndTranscription() {
        launchHome(["-semitone-home-sample-tones"])
        openToneMenu("Band demo")
        let titles = ["Rename", "Export MIDI file", "Transcription", "Delete"]
        for title in titles {
            XCTAssertTrue(menuItem(title).exists, "The menu has \(title).")
        }
        // Top to bottom, Delete last.
        XCTAssertEqual(titles.map { menuItem($0).frame.minY }, titles.map { menuItem($0).frame.minY }.sorted())
        XCTAssertTrue(menuItem("Export MIDI file").isEnabled)
        XCTAssertTrue(menuItem("Transcription").isEnabled)
        attachScreenshot("gear-home-menu")

        openTranscriptionSubmenu()
        XCTAssertTrue(menuItem("Transcribed as Song").waitForExistence(timeout: 5))
        XCTAssertTrue(menuItem("Transcribed as Song").isSelected, "Checked: the kind it is.")
        XCTAssertTrue(menuItem("Transcribe again as Piano").exists, "The other kind, to transcribe it again.")
        XCTAssertLessThan(menuItem("Transcribed as Song").frame.minY, menuItem("Transcribe again as Piano").frame.minY,
                          "The kind it is comes first.")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Any instrument'")).firstMatch.exists,
                       "Home's names, not the engine's.")
        XCTAssertFalse(menuItem("High-accuracy piano model").exists, "A Song has no piano model.")
        XCTAssertFalse(menuItem("Clean up with AI").exists, "No AI provider is chosen.")
        XCTAssertFalse(menuItem("Revert to raw").exists, "Nothing to revert.")
        attachScreenshot("gear-home-transcription-song")
        dismissToneMenu()

        openToneMenu("Whistled tune")
        openTranscriptionSubmenu()
        XCTAssertTrue(menuItem("Transcribed as Instrument").waitForExistence(timeout: 5), "One line is an Instrument.")
        XCTAssertTrue(menuItem("Transcribe again as Piano").exists)
        dismissToneMenu()

        openToneMenu("Piano sketch")
        openTranscriptionSubmenu()
        XCTAssertTrue(menuItem("Transcribed as Piano").waitForExistence(timeout: 5))
        XCTAssertTrue(menuItem("Transcribe again as Song").exists)
        XCTAssertTrue(menuItem("High-accuracy piano model").exists, "A Piano Tone's own piano-model switch.")
        XCTAssertTrue(menuItem("High-accuracy piano model").isSelected, "Saved with the model's notes.")
        attachScreenshot("gear-home-transcription")
        dismissToneMenu()
        XCTAssertTrue(app.buttons["home-record"].isHittable, "Still on Home.")
        XCTAssertFalse(app.alerts["Something went wrong"].exists)
    }

    /// Export MIDI file, from a Tone's long-press menu, hands its file to the
    /// share sheet on Home: a Tone that isn't open is opened behind Home for
    /// it (its beat grid comes from its audio), and the open one as it stands.
    func testExportFromHomeGivesAShareSheet() {
        launchHome(["-semitone-home-sample-tones"])
        openToneMenu("Piano sketch")
        menuItem("Export MIDI file").tap()
        let share = shareSheet
        XCTAssertTrue(share.waitForExistence(timeout: 15), "The share sheet comes up.")
        XCTAssertFalse(app.buttons["record-button"].exists, "Home stays where it is.")
        XCTAssertFalse(app.alerts["Something went wrong"].exists)
        Thread.sleep(forTimeInterval: 1)
        attachScreenshot("gear-home-export-share")
        closeShareSheet()
        XCTAssertFalse(element("home-export-progress").exists)
        XCTAssertTrue(app.buttons["home-record"].isHittable)

        // The open Tone exports as it stands: a part hidden on screen stays out.
        tone("Band demo").tap()
        let melody = app.buttons["part-melody"]
        XCTAssertTrue(melody.waitForExistence(timeout: 15))
        melody.tap()
        XCTAssertEqual(melody.value as? String, "Hidden")
        goBackHome()
        openToneMenu("Band demo")
        XCTAssertTrue(menuItem("Export MIDI file").isEnabled)
        menuItem("Export MIDI file").tap()
        XCTAssertTrue(shareSheet.waitForExistence(timeout: 10), "The open Tone's file comes up at once.")
        closeShareSheet()
        XCTAssertFalse(app.alerts["Something went wrong"].exists)
    }

    /// A Transcription item chosen from a Tone's long-press menu opens the
    /// Tone, as tapping its row does, and acts on it there: its piano model
    /// goes off (the quick detector hears nothing in the sample's silent
    /// recording) and, from the open Tone's menu, back on.
    func testTranscriptionActionFromHomeOpensTheToneAndActs() {
        launchHome(["-semitone-home-sample-tones"])
        let row = tone("Piano sketch")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        // "Piano sketch. Piano. 0:08, 42 notes. Today"
        let words = row.label.components(separatedBy: " ")
        let saved = words.firstIndex { $0.hasPrefix("notes") }.flatMap { $0 > 0 ? Int(words[$0 - 1]) : nil } ?? -1
        XCTAssertGreaterThan(saved, 0, row.label)

        openToneMenu("Piano sketch")
        openTranscriptionSubmenu()
        let model = menuItem("High-accuracy piano model")
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        model.tap()
        XCTAssertTrue(app.buttons["record-button"].waitForExistence(timeout: 10), "The Tone opens.")
        XCTAssertTrue(noteReadout.waitForExistence(timeout: 15))
        wait("Its piano model goes off: no notes in the silence", timeout: 15) {
            self.noteReadout.label.hasPrefix("0 notes")
        }
        attachScreenshot("gear-home-transcription-opened")
        XCTAssertFalse(app.alerts["Something went wrong"].exists)

        // Back on Home, the open Tone's menu reads from it, and acts at once.
        goBackHome()
        openToneMenu("Piano sketch")
        openTranscriptionSubmenu()
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        XCTAssertFalse(model.isSelected, "The open Tone's piano model is off now.")
        model.tap()
        XCTAssertTrue(app.buttons["record-button"].waitForExistence(timeout: 10))
        wait("And back to the piano model's notes", timeout: 15) {
            self.noteReadout.label.hasPrefix("\(saved) notes")
        }
        XCTAssertFalse(app.alerts["Something went wrong"].exists)
    }

    /// The system share sheet.
    private var shareSheet: XCUIElement {
        app.otherElements.matching(identifier: "ActivityListView").firstMatch
    }

    private func closeShareSheet() {
        let sheet = shareSheet
        let close = app.buttons.matching(NSPredicate(format: "identifier == 'Close' OR label == 'Close'")).firstMatch
        if close.exists { close.tap() } else { app.swipeDown() }
        wait("The share sheet closes") { !sheet.exists }
    }

    /// Back from the transcription screen to Home.
    private func goBackHome() {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(app.buttons["home-record"].waitForExistence(timeout: 5))
    }

    /// An item of the system menu on screen, by its title (a subtitle may
    /// follow it in the label).
    private func menuItem(_ title: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, "\(title), "))
            .matching(NSPredicate(format: "elementType == %d OR elementType == %d OR elementType == %d",
                                  XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.switch.rawValue,
                                  XCUIElement.ElementType.menuItem.rawValue))
            .firstMatch
    }

    /// The notes the roll shows, from the fixture's state.
    private var visibleCount: Int {
        let field = state.split(separator: ";").first { $0.hasPrefix("visible=") }
        return field.flatMap { Int($0.dropFirst("visible=".count)) } ?? -1
    }

    /// The preset this run's simulator has chosen (Balanced unless a test changed it).
    private var presetSelected: String {
        ["auto", "gentle", "piano", "dense", "custom"].first { app.buttons["preset-\($0)"].isSelected } ?? "none"
    }

    /// At larger text both sheets keep every control on screen's width and
    /// the beats-per-bar chips wrap rather than run off the side.
    func testSettingsMenusAtLargeText() {
        for size in ["UICTContentSizeCategoryXXL", "UICTContentSizeCategoryAccessibilityXXXL"] {
            let name = size.hasSuffix("AccessibilityXXXL") ? "AX5" : "XXL"
            launch("song", textSize: size)
            let screen = app.windows.firstMatch.frame
            openToneSettings()
            attachScreenshot("Tone Settings \(name)")
            for id in ["roll-style-horizontal", "roll-style-falling", "preset-auto"] {
                XCTAssertLessThanOrEqual(element(id).frame.maxX, screen.maxX + 0.5, "\(id) fits across at \(name).")
                XCTAssertGreaterThanOrEqual(element(id).frame.minX, screen.minX - 0.5)
            }
            let beatGrid = element("tone-beat-grid")
            for _ in 0..<8 where !screen.contains(beatGrid.frame) { scrollSettingsUp() }
            XCTAssertTrue(screen.contains(beatGrid.frame), "The Beat grid row scrolls into view at \(name).")
            attachScreenshot("Tone Settings \(name), scrolled")
            XCTAssertGreaterThanOrEqual(element("tone-show-beat-grid").frame.height, 44)
            beatGrid.tap()
            XCTAssertTrue(element("beat-grid-page").waitForExistence(timeout: 5))
            attachScreenshot("Tone Settings, Beat grid \(name)")
            let lastChip = app.buttons["beats-per-bar-7"]
            for _ in 0..<8 where !screen.contains(lastChip.frame) { scrollSettingsUp() }
            for count in [0, 2, 3, 4, 5, 6, 7] {
                let chip = app.buttons["beats-per-bar-\(count)"]
                XCTAssertTrue(chip.exists)
                XCTAssertLessThanOrEqual(chip.frame.maxX, screen.maxX + 0.5, "The \(count) chip wraps at \(name).")
                XCTAssertGreaterThanOrEqual(chip.frame.height, 44)
            }
            let later = app.buttons["bar-lines-later"]
            for _ in 0..<8 where !screen.contains(later.frame) { scrollSettingsUp() }
            XCTAssertTrue(screen.contains(later.frame), "The bar-line nudges fit at \(name).")
            XCTAssertTrue(screen.contains(element("bar-lines-value").frame))
            attachScreenshot("Tone Settings, Beat grid \(name), scrolled")
            closeSettings()

            launchHome(["-UIPreferredContentSizeCategoryName", size])
            app.buttons["home-settings"].tap()
            XCTAssertTrue(element("home-settings-sheet").waitForExistence(timeout: 5))
            attachScreenshot("Home Settings \(name)")
            for id in ["settings-piano-model-default", "settings-link-import"] {
                XCTAssertLessThanOrEqual(element(id).frame.maxX, screen.maxX + 0.5, "\(id) fits across at \(name).")
            }
            closeSettings()
        }
    }

    /// Home, the app's root, without a fixture or the intro.
    private func launchHome(_ arguments: [String] = []) {
        app?.terminate()
        app = XCUIApplication()
        app.launchArguments = ["-semitone-skip-intro", "-aiProvider", "off"] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["home-record"].waitForExistence(timeout: 10), "Home is the app's root.")
    }

    func testHomeModeSegmentsAndImportFan() {
        launchHome(["-linkImportEnabled", "NO"])
        let record = app.buttons["home-record"]
        XCTAssertEqual(record.label, "Start Listening")

        // Each segment selects its mode, and the label over the record button follows.
        let label = element("home-mode-label")
        let selected = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home-mode-' AND selected == true"))
        for (id, name) in [("song", "Song"), ("instrument", "Instrument"), ("piano", "Piano")] {
            let segment = app.buttons["home-mode-\(id)"]
            XCTAssertEqual(segment.label, name)
            segment.tap()
            wait("Tapping \(name) selects it") { segment.isSelected }
            wait("The label names \(name)") { label.label.hasPrefix(name) }
            XCTAssertEqual(selected.count, 1, "One mode is selected at a time.")
        }
        wait("The spelled-out label settles back to the mode's name") { label.label == "Piano" }
        XCTAssertTrue(record.isHittable)
        attachScreenshot("Home on Piano")

        // Import fans out three choices; Link is off until Settings turns it on.
        let toggle = app.buttons["home-import"]
        let files = app.buttons["import-option-files"]
        let photos = app.buttons["import-option-photos"]
        let link = app.buttons["import-option-link"]
        XCTAssertEqual(toggle.label, "Import")
        XCTAssertFalse(files.exists, "The closed fan has no choices.")
        toggle.tap()
        XCTAssertTrue(files.waitForExistence(timeout: 3))
        wait("The choices land on the arc") { files.isHittable && photos.isHittable }
        XCTAssertTrue(files.isEnabled)
        XCTAssertTrue(photos.isEnabled)
        XCTAssertTrue(link.exists)
        XCTAssertFalse(link.isEnabled, "Link is disabled while the experimental setting is off.")
        XCTAssertTrue(link.label.contains("Turn on in Settings"), link.label)
        XCTAssertEqual(toggle.label, "Close Import")
        attachScreenshot("Import fan open, Link off")
        toggle.tap()
        wait("× closes the fan") { !files.exists }
        XCTAssertEqual(toggle.label, "Import")

        // A tap anywhere outside closes it too.
        toggle.tap()
        XCTAssertTrue(files.waitForExistence(timeout: 3))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        wait("Tapping outside closes the fan") { !files.exists }
        XCTAssertTrue(record.isHittable)

        // With the setting on, Link is a live choice.
        launchHome(["-linkImportEnabled", "YES"])
        app.buttons["home-import"].tap()
        let liveLink = app.buttons["import-option-link"]
        XCTAssertTrue(liveLink.waitForExistence(timeout: 3))
        XCTAssertTrue(liveLink.isEnabled)
        XCTAssertEqual(liveLink.label, "Link, Experimental")
    }

    func testHomeRecordingLookLocksModeAndImport() {
        // The simulator can't record, so a DEBUG preview shows the recording look.
        launchHome(["-semitone-home-recording-preview"])
        let record = app.buttons["home-record"]
        XCTAssertEqual(record.label, "Stop Listening")
        XCTAssertTrue((record.value as? String ?? "").hasPrefix("Recording, 0:12"))
        XCTAssertTrue(element("home-mode-label").label.hasPrefix("Recording, 0:12"))
        for id in ["instrument", "piano", "song"] {
            XCTAssertFalse(app.buttons["home-mode-\(id)"].isEnabled, "Modes are locked while recording.")
        }
        XCTAssertFalse(app.buttons["home-import"].isEnabled, "Import waits until the take is done.")
        attachScreenshot("Recording look")

        record.tap()
        wait("Stopping returns to the idle look") { record.label == "Start Listening" }
        XCTAssertTrue(app.buttons["home-mode-song"].isEnabled)
        XCTAssertTrue(app.buttons["home-import"].isEnabled)
    }

    /// The masthead's clef isn't read on its own: the logo and wordmark read
    /// once, as "Semitone", a heading.
    func testHomeMastheadReadsOnceAsSemitone() {
        launchHome()
        let artwork = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'intro' OR identifier CONTAINS[c] 'intro'"))
        XCTAssertEqual(artwork.count, 0, "The clef's artwork names reach VoiceOver.")
        // The wordmark reads as the app's name, a header; the clef is hidden.
        let wordmark = element("home-wordmark")
        XCTAssertTrue(wordmark.exists)
        XCTAssertEqual(wordmark.label, "Semitone")
        XCTAssertEqual(wordmark.elementType, .staticText)
        XCTAssertEqual(app.images.matching(NSPredicate(format: "label CONTAINS[c] 'clef' OR label CONTAINS[c] 'semitone'")).count, 0)
        let settings = app.buttons["home-settings"]
        XCTAssertEqual(settings.label, "Settings")
        XCTAssertGreaterThanOrEqual(settings.frame.width, 44)
        XCTAssertGreaterThanOrEqual(settings.frame.height, 44)
    }

    /// Tones are rows of one list, newest first, every kind the library's
    /// width, each with the day it was made, and named to VoiceOver as its
    /// kind (a song's parts in order).
    func testHomeTonesAreListRows() {
        launchHome(["-semitone-home-sample-tones"])
        let tones = app.buttons.matching(identifier: "home-tone")
        func tone(_ format: String) -> XCUIElement {
            tones.matching(NSPredicate(format: format)).firstMatch
        }
        // A one-line take shows as an Instrument tone (noted when it was saved).
        let instrument = tone("label BEGINSWITH 'Whistled tune.' AND label CONTAINS 'Instrument, one line'")
        XCTAssertTrue(instrument.waitForExistence(timeout: 10))
        let piano = tone("label BEGINSWITH 'Piano sketch.' AND label CONTAINS '. Piano.'")
        // A song with a countermelody: VoiceOver names it second.
        let fourParts = tone("label BEGINSWITH 'Band demo.' AND label CONTAINS 'Song in four parts: melody, countermelody, chords, and bass.'")
        let threeParts = tone("label BEGINSWITH 'Trio, first pass.' AND label CONTAINS 'Song in three parts: melody, chords, and bass.'")
        // Saved by Prerelease 0.99 with drum hits and a drums part: its drums are gone.
        let twoParts = tone("label BEGINSWITH 'Guitar and drums.' AND label CONTAINS 'Song in two parts: chords and bass.'")
        XCTAssertTrue(piano.exists)
        XCTAssertTrue(fourParts.waitForExistence(timeout: 5))
        XCTAssertTrue(twoParts.waitForExistence(timeout: 5))

        let width = app.windows.firstMatch.frame.width
        let rowHeight = piano.frame.height
        for row in [piano, instrument, fourParts, twoParts] {
            XCTAssertEqual(row.frame.width, width - 32, accuracy: 1, "Every kind is a full-width row: \(row.label)")
            XCTAssertGreaterThanOrEqual(row.frame.height, 44)
            XCTAssertEqual(row.frame.height, rowHeight, accuracy: 1, "Every row is as tall: \(row.label)")
            XCTAssertEqual(row.frame.minX, piano.frame.minX, accuracy: 1)
        }
        // Newest first, one list (0.90's day headings are gone; each row has its day).
        XCTAssertLessThan(piano.frame.minY, instrument.frame.minY)
        XCTAssertLessThan(instrument.frame.minY, fourParts.frame.minY)
        XCTAssertLessThan(fourParts.frame.minY, twoParts.frame.minY)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "home-day").count, 0)
        XCTAssertTrue(piano.label.contains(". Today"), piano.label)
        XCTAssertTrue(instrument.label.contains(". Yesterday"), instrument.label)
        XCTAssertTrue(piano.label.contains("notes"), piano.label)
        // One note is "1 note", to VoiceOver as it always was, and has no
        // key. Its notes are read before the trio's, a row further down: once
        // the trio has its key, the single note's absence of one is final.
        let single = tone("label BEGINSWITH 'A single note.'")
        XCTAssertTrue(single.waitForExistence(timeout: 5))
        XCTAssertTrue(single.label.contains(", 1 note."), single.label)
        XCTAssertTrue(threeParts.waitForExistence(timeout: 5), "The trio's row is built too, below the single note.")
        wait("The trio's key is read") { threeParts.label.contains(". In ") }
        XCTAssertFalse(single.label.contains(". In "), "One note has no key: \(single.label)")
        attachScreenshot("Tones as list rows")

        // The library scrolls under the bottom controls, which stay usable.
        app.swipeUp()
        XCTAssertTrue(app.buttons["home-record"].isHittable)
        XCTAssertTrue(app.buttons["home-import"].isHittable)
        attachScreenshot("Tones scrolled under the controls")

        // Last month's trio: three parts, a row as tall as four parts'.
        for _ in 0..<3 where !threeParts.exists { app.swipeUp() }
        XCTAssertTrue(threeParts.waitForExistence(timeout: 10))
        XCTAssertEqual(threeParts.frame.height, rowHeight, accuracy: 1)
        // Last month's are older: the day, its month spelled out (with the
        // year, should last month have been last year).
        let made = Date.now.addingTimeInterval(-33 * 86_400)
        let sameYear = Calendar.current.component(.year, from: made) == Calendar.current.component(.year, from: .now)
        let day = sameYear ? made.formatted(.dateTime.month(.wide).day())
            : made.formatted(.dateTime.month(.wide).day().year())
        XCTAssertTrue(threeParts.label.contains(". \(day)."), "\(day): \(threeParts.label)")

        // An older one-line take, saved before kinds were kept, becomes an
        // Instrument tone once its notes are read.
        let older = tone("label BEGINSWITH 'Hummed line.' AND label CONTAINS 'Instrument, one line'")
        for _ in 0..<3 where !older.exists { app.swipeUp() }
        XCTAssertTrue(older.waitForExistence(timeout: 10))
        XCTAssertEqual(older.frame.width, width - 32, accuracy: 1)

        // A melody over drums, saved by Prerelease 0.99 as a song, is one line now.
        let tune = tone("label BEGINSWITH 'Tune over a drum loop.' AND label CONTAINS 'Instrument, one line'")
        for _ in 0..<3 where !tune.exists { app.swipeUp() }
        XCTAssertTrue(tune.waitForExistence(timeout: 10))
        XCTAssertEqual(tune.frame.width, width - 32, accuracy: 1)
        // No row lists a drums part.
        XCTAssertEqual(tones.matching(NSPredicate(format: "label CONTAINS 'drums.' AND NOT label BEGINSWITH 'Guitar and drums.'")).count, 0)
    }
}
