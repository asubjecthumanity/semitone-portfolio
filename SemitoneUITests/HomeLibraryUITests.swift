import XCTest
import CoreGraphics

/// Home's library as drawn: the Tones as full-width rows, newest first,
/// each with a navy thumbnail read back from the screen; the search field
/// and the kind chips narrowing them; the bottom controls' glass staying
/// light over the rows and staying put when the keyboard comes up; the
/// empty library's sample card; and the rows at the largest text size Home
/// allows (XXL).
final class HomeLibraryUITests: XCTestCase {
    private var app: XCUIApplication!

    /// The brand navy (the masthead's marks, the selected chip), and the
    /// controls' ink and unselected icons (`HomeTheme`).
    private static let navy = Pixel(r: 0x0F, g: 0x1E, b: 0x3A)
    /// The thumbnails' own fill, the brand navy lifted a step (`HomeTheme.tile`).
    private static let tile = Pixel(r: 0x1D, g: 0x2C, b: 0x4A)
    private static let controlInk = Pixel(r: 0x1C, g: 0x1C, b: 0x1E)
    private static let controlSecondary = Pixel(r: 0x3C, g: 0x3C, b: 0x43)
    private static let controlDisabled = Pixel(r: 0x5E, g: 0x5E, b: 0x63)
    private static let experimental = Pixel(r: 0x87, g: 0x43, b: 0x00)

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        if let app, (testRun?.totalFailureCount ?? 0) > 0 {
            attachScreenshot("Failure")
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "Accessibility hierarchy"
            tree.lifetime = .keepAlways
            add(tree)
        }
        app?.terminate()
    }

    /// Home, the app's root, without a fixture or the intro.
    private func launchHome(_ arguments: [String] = []) {
        app?.terminate()
        app = XCUIApplication()
        app.launchArguments = ["-semitone-skip-intro", "-aiProvider", "off"] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["home-record"].waitForExistence(timeout: 10), "Home is the app's root.")
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private var tones: XCUIElementQuery { app.buttons.matching(identifier: "home-tone") }

    /// A Tone's row, by the start of its VoiceOver label (its title).
    private func tone(_ title: String) -> XCUIElement {
        tones.matching(NSPredicate(format: "label BEGINSWITH %@", "\(title).")).firstMatch
    }

    /// A search field to XCUITest too, by its trait.
    private var search: XCUIElement { app.searchFields["home-search"] }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func wait(_ description: String, timeout: TimeInterval = 8,
                      file: StaticString = #filePath, line: UInt = #line,
                      until condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, description,
                       file: file, line: line)
    }

    /// Every Tone is a row the library's width, at least a touch target
    /// tall, newest first, with the day it was made and (once its notes are
    /// read) its key.
    func testTonesAreFullWidthRowsNewestFirst() {
        launchHome(["-semitone-home-sample-tones"])
        let piano = tone("Piano sketch")
        let instrument = tone("Whistled tune")
        let song = tone("Band demo")
        XCTAssertTrue(song.waitForExistence(timeout: 10))
        let width = app.windows.firstMatch.frame.width
        for row in [piano, instrument, song] {
            XCTAssertEqual(row.frame.width, width - 32, accuracy: 1, row.label)
            XCTAssertGreaterThanOrEqual(row.frame.height, 44, row.label)
            XCTAssertEqual(row.frame.height, piano.frame.height, accuracy: 1, "Every kind's row is as tall.")
        }
        XCTAssertLessThan(piano.frame.maxY, instrument.frame.minY + 1, "Today's, then yesterday's.")
        XCTAssertLessThan(instrument.frame.maxY, song.frame.minY + 1)
        XCTAssertTrue(piano.label.contains(". Today"), piano.label)
        XCTAssertTrue(instrument.label.contains(". Yesterday"), instrument.label)
        wait("Its key, once its notes are read") { piano.label.hasSuffix(". In C major.") }
        attachScreenshot("Tones as rows")
    }

    /// A row's thumbnail is the navy the tiles were, its notes on it.
    func testThumbnailsAreNavy() throws {
        launchHome(["-semitone-home-sample-tones"])
        let rows = [tone("Piano sketch"), tone("Whistled tune"), tone("Band demo")]
        XCTAssertTrue(rows[2].waitForExistence(timeout: 10))
        // Let the notes draw.
        Thread.sleep(forTimeInterval: 1)
        let screen = try XCTUnwrap(ScreenPixels(app))
        for row in rows {
            // The 56 pt thumbnail at the row's leading edge, centred on it:
            // in its 7 pt border, clear of the notes and the corners.
            let f = row.frame
            let fill = screen.median([CGPoint(x: f.minX + 3, y: f.midY), CGPoint(x: f.minX + 28, y: f.midY - 25),
                                      CGPoint(x: f.minX + 28, y: f.midY + 25)])
            XCTAssertTrue(fill.isClose(to: Self.tile), "\(row.label): \(fill)")
        }
    }

    /// The library passes under the bottom controls, navy thumbnails and
    /// all. Their glass is pinned light: their ink and unselected icons
    /// read on it at AA.
    func testBottomControlsStayLightOverTheLibrary() throws {
        launchHome(["-semitone-home-sample-tones", "-linkImportEnabled", "NO"])
        XCTAssertTrue(tones.firstMatch.waitForExistence(timeout: 10))
        let plus = app.buttons["home-import"]
        let modes = element("home-mode")
        let label = element("home-mode-label")
        XCTAssertTrue(label.exists)
        /// A row lies under the control's middle.
        func covered(_ control: XCUIElement) -> Bool {
            let middle = CGPoint(x: control.frame.midX, y: control.frame.midY)
            return tones.allElementsBoundByIndex.contains { $0.exists && $0.frame.contains(middle) }
        }
        XCTAssertTrue(covered(plus) && covered(modes), "The rows pass under the controls.")
        // Let the glass settle.
        Thread.sleep(forTimeInterval: 1)
        let screen = try XCTUnwrap(ScreenPixels(app))

        // The "+" glass, on its diagonals clear of the "+".
        let c = CGPoint(x: plus.frame.midX, y: plus.frame.midY)
        let plusGlass = screen.median([(-1, -1), (1, -1), (-1, 1), (1, 1)].map { CGPoint(x: c.x + 15 * $0.0, y: c.y + 15 * $0.1) })
        // The mode capsule's glass, above and below the Instrument and Song icons
        // and between them and the thumb.
        let f = modes.frame
        let modeGlass = screen.median([CGPoint(x: f.minX + 24, y: f.minY + 8), CGPoint(x: f.minX + 24, y: f.maxY - 8),
                                       CGPoint(x: f.maxX - 24, y: f.minY + 8), CGPoint(x: f.maxX - 24, y: f.maxY - 8),
                                       CGPoint(x: f.minX + 40, y: f.midY), CGPoint(x: f.maxX - 40, y: f.midY)])
        // The mode label's glass, either side of its words (its frame is the words').
        let l = label.frame
        let labelGlass = screen.median([CGPoint(x: l.minX - 6, y: l.midY), CGPoint(x: l.maxX + 6, y: l.midY),
                                        CGPoint(x: l.maxX + 7, y: l.midY + 2)])
        for (name, glass) in [("Import", plusGlass), ("Mode", modeGlass), ("Mode label", labelGlass)] {
            XCTAssertGreaterThanOrEqual(Self.controlInk.contrast(glass), 4.5, "\(name) ink on \(glass)")
            XCTAssertGreaterThanOrEqual(Self.controlSecondary.contrast(glass), 4.5, "\(name) icons on \(glass)")
            XCTAssertGreaterThanOrEqual(Self.navy.contrast(glass), 4.5, "\(name): the navy thumb on \(glass)")
        }
        attachScreenshot("Controls over the library")
        XCTAssertTrue(plus.isHittable)
        XCTAssertTrue(app.buttons["home-record"].isHittable)

        // Import's choices fan out over the rows on the same light glass;
        // Link is off, in its dimmer ink, with the Experimental chip beside it.
        plus.tap()
        let files = app.buttons["import-option-files"]
        XCTAssertTrue(files.waitForExistence(timeout: 3))
        wait("The choices land on the arc") { files.isHittable }
        Thread.sleep(forTimeInterval: 0.8)
        let open = try XCTUnwrap(ScreenPixels(app))
        for id in ["files", "photos", "link"] {
            let choice = app.buttons["import-option-\(id)"].frame
            let m = CGPoint(x: choice.midX, y: choice.midY)
            // Above the name, either side of the icon, and beside the name.
            let glass = open.median([CGPoint(x: m.x - 14, y: m.y - 14), CGPoint(x: m.x + 14, y: m.y - 14),
                                     CGPoint(x: m.x - 21, y: m.y + 2), CGPoint(x: m.x + 21, y: m.y + 2)])
            let ink = id == "link" ? Self.controlDisabled : Self.controlInk
            XCTAssertGreaterThanOrEqual(ink.contrast(glass), 4.5, "\(id) on \(glass)")
        }
        // The chip ends 6 pt left of Link, centred on it, 22 pt tall and about
        // 130 wide ("Experimental · Off"): its glass above and below its words,
        // along its length.
        let link = app.buttons["import-option-link"].frame
        let chipGlass = open.median(stride(from: 16.0, through: 126, by: 22).flatMap { x in
            [CGPoint(x: link.minX - x, y: link.midY - 9), CGPoint(x: link.minX - x, y: link.midY + 9)]
        })
        XCTAssertGreaterThanOrEqual(Self.experimental.contrast(chipGlass), 4.5, "Experimental on \(chipGlass)")
        attachScreenshot("Import open over the library")
        plus.tap()
        wait("× closes the fan") { !files.exists }
    }

    /// Scrolled, the rows pass under the masthead: the navy wordmark and
    /// Settings' navy gear still read there.
    func testMastheadStaysLegibleOverTheLibrary() throws {
        launchHome(["-semitone-home-sample-tones"])
        XCTAssertTrue(tones.firstMatch.waitForExistence(timeout: 10))
        let settings = app.buttons["home-settings"]
        let wordmark = element("home-wordmark")
        /// A row lies under the masthead, by the wordmark (over a thumbnail).
        func underMasthead() -> Bool {
            let behind = CGPoint(x: wordmark.frame.minX + 8, y: settings.frame.midY)
            return tones.allElementsBoundByIndex.contains { $0.exists && $0.frame.contains(behind) }
        }
        for _ in 0..<4 where !underMasthead() { app.swipeUp() }
        XCTAssertTrue(underMasthead(), "A row passes under the masthead.")
        Thread.sleep(forTimeInterval: 1)
        attachScreenshot("Tones scrolled under the masthead and the controls")
        let screen = try XCTUnwrap(ScreenPixels(app))

        // Beside the wordmark, what it's set on.
        let w = wordmark.frame
        let behindWordmark = screen.median([CGPoint(x: w.maxX + 8, y: w.midY), CGPoint(x: w.maxX + 24, y: w.midY),
                                            CGPoint(x: w.maxX + 40, y: w.midY)])
        XCTAssertGreaterThanOrEqual(Self.navy.contrast(behindWordmark), 4.5, "The wordmark on \(behindWordmark)")
        // Settings' glass, on its diagonals clear of the gear.
        let s = CGPoint(x: settings.frame.midX, y: settings.frame.midY)
        let gearGlass = screen.median([(-1, -1), (1, -1), (-1, 1), (1, 1)].map { CGPoint(x: s.x + 12 * $0.0, y: s.y + 12 * $0.1) })
        XCTAssertGreaterThanOrEqual(Self.navy.contrast(gearGlass), 3, "The gear on \(gearGlass)")
        XCTAssertTrue(settings.isHittable)
    }

    /// Typing narrows the list: by key, by chord, by nothing at all; the
    /// clear button brings every Tone back. The keyboard comes up over the
    /// controls, which stay where they were.
    func testSearchNarrowsTheLibrary() {
        launchHome(["-semitone-home-sample-tones"])
        let piano = tone("Piano sketch"), whistled = tone("Whistled tune"), band = tone("Band demo")
        let etude = tone("Evening étude")
        // The oldest sample, ten rows down, below the screen: its row isn't
        // built at launch, so nothing has read its notes (and its key) but
        // the search itself.
        let oldest = tone("Tune over a drum loop")
        XCTAssertTrue(band.waitForExistence(timeout: 10))
        XCTAssertFalse(oldest.exists, "The oldest Tone's row isn't built yet.")
        XCTAssertTrue(search.exists)
        XCTAssertEqual(search.label, "Search Tones")
        XCTAssertFalse(app.buttons["home-search-clear"].exists, "Nothing to clear yet.")
        let record = app.buttons["home-record"]
        let recordTop = record.frame.minY

        search.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 3), "The software keyboard is up.")
        search.typeText("A major")
        // The only sample in A major, found once the search has read it.
        XCTAssertTrue(oldest.waitForExistence(timeout: 10), "Tune over a drum loop is in A major.")
        wait("Every other Tone goes") { !piano.exists && !band.exists && !whistled.exists && !etude.exists }
        XCTAssertTrue(oldest.label.hasSuffix(". In A major."), oldest.label)
        XCTAssertEqual(record.frame.minY, recordTop, accuracy: 1,
                       "The keyboard covers the controls rather than pushing them up.")
        XCTAssertTrue(keyboard.frame.intersects(record.frame), "The keyboard is over the record button.")

        let clear = app.buttons["home-search-clear"]
        XCTAssertTrue(clear.exists)
        XCTAssertEqual(clear.label, "Clear search")
        XCTAssertGreaterThanOrEqual(clear.frame.width, 44, "A touch target wide.")
        XCTAssertGreaterThanOrEqual(clear.frame.height, 44, "And tall.")
        clear.tap()
        XCTAssertTrue(piano.waitForExistence(timeout: 5), "Cleared, every Tone is back.")
        XCTAssertTrue(whistled.exists)
        XCTAssertFalse(clear.exists)

        // A key's mode alone: the only sample in a minor key.
        search.typeText("minor")
        XCTAssertTrue(etude.waitForExistence(timeout: 10), "Evening étude is in A minor.")
        wait("The major-key Tones go") { !piano.exists && !band.exists && !whistled.exists }
        XCTAssertTrue(etude.label.hasSuffix(". In A minor."), etude.label)
        clear.tap()

        // A chord or a key: Band demo plays Am; Evening étude is in A minor.
        search.typeText("Am")
        XCTAssertTrue(band.waitForExistence(timeout: 10))
        XCTAssertTrue(etude.waitForExistence(timeout: 10))
        wait("A tune with no chords, in D major, goes") { !whistled.exists }
        attachScreenshot("home-search")

        clear.tap()
        search.typeText("zzqx")
        let none = element("home-no-results")
        XCTAssertTrue(none.waitForExistence(timeout: 10))
        XCTAssertTrue(none.label.contains("No Tones match"), none.label)
        XCTAssertEqual(tones.count, 0)
        clear.tap()
        XCTAssertTrue(piano.waitForExistence(timeout: 5))
        XCTAssertFalse(none.exists)
    }

    /// The whole grey field takes a tap, its magnifying glass and the
    /// margin above the text too, not only the line the text is on.
    func testTheWholeSearchFieldTakesATap() {
        launchHome(["-semitone-home-sample-tones"])
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        // On the glass, 20 pt left of where the text starts and 8 pt above it.
        search.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(CGVector(dx: -20, dy: -8)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "The field has the keyboard.")
    }

    /// The Piano chip leaves only Piano Tones, chosen in navy; All brings
    /// the rest back.
    func testKindChipsFilterTheLibrary() {
        launchHome(["-semitone-home-sample-tones"])
        XCTAssertTrue(tone("Band demo").waitForExistence(timeout: 10))
        let all = app.buttons["home-filter-all"], piano = app.buttons["home-filter-piano"]
        for id in ["all", "piano", "instrument", "song"] {
            let chip = app.buttons["home-filter-\(id)"]
            XCTAssertTrue(chip.isHittable, id)
            XCTAssertGreaterThanOrEqual(chip.frame.height, 43.5, "\(id) is a touch target tall (44 pt, give or take rounding).")
        }
        XCTAssertTrue(all.isSelected)
        XCTAssertFalse(piano.isSelected)

        piano.tap()
        wait("Only Piano Tones") { !self.tone("Band demo").exists && !self.tone("Whistled tune").exists }
        XCTAssertTrue(piano.isSelected)
        XCTAssertFalse(all.isSelected)
        XCTAssertTrue(tone("Piano sketch").exists)
        for row in tones.allElementsBoundByIndex where row.exists {
            XCTAssertTrue(row.label.contains(". Piano."), row.label)
        }
        attachScreenshot("Piano Tones")

        all.tap()
        XCTAssertTrue(tone("Band demo").waitForExistence(timeout: 5))
        XCTAssertTrue(tone("Whistled tune").exists)
        XCTAssertTrue(all.isSelected)
    }

    /// No Tones yet: the sample card is navy like a thumbnail, reads as one
    /// element, and there's nothing to search or filter.
    func testEmptyLibraryShowsItsSampleCardAlone() throws {
        launchHome(["-semitone-home-no-tones"])
        let empty = element("home-empty")
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        XCTAssertEqual(tones.count, 0)
        XCTAssertFalse(search.exists, "No search over an empty library.")
        XCTAssertFalse(app.buttons["home-filter-all"].exists)
        XCTAssertTrue(empty.label.contains("No Tones yet"), empty.label)
        XCTAssertTrue(empty.label.contains("Your first Tone"), empty.label)
        let screen = try XCTUnwrap(ScreenPixels(app))
        // The top right: "No Tones yet" is on the left.
        let fill = screen.median([CGPoint(x: empty.frame.maxX - 20, y: empty.frame.minY + 14),
                                  CGPoint(x: empty.frame.maxX - 30, y: empty.frame.minY + 14),
                                  CGPoint(x: empty.frame.maxX - 8, y: empty.frame.midY)])
        XCTAssertTrue(fill.isClose(to: Self.tile), "\(fill)")
        attachScreenshot("Empty library")
    }

    /// At XXL, Home's largest text size, the rows keep the library's width,
    /// grow rather than clip, and stay hittable, as do the chips and the
    /// controls.
    func testTonesAtXXLText() {
        launchHome(["-semitone-home-sample-tones", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXL"])
        let piano = tone("Piano sketch")
        let instrument = tone("Whistled tune")
        XCTAssertTrue(piano.waitForExistence(timeout: 10))
        XCTAssertTrue(instrument.waitForExistence(timeout: 5))
        let width = app.windows.firstMatch.frame.width
        for row in [piano, instrument] {
            XCTAssertEqual(row.frame.width, width - 32, accuracy: 1, row.label)
            XCTAssertGreaterThanOrEqual(row.frame.height, 44, row.label)
            XCTAssertTrue(row.isHittable, row.label)
        }
        XCTAssertLessThan(piano.frame.maxY, instrument.frame.minY + 1, "Rows don't overlap.")
        XCTAssertTrue(search.isHittable)
        XCTAssertTrue(app.buttons["home-filter-all"].isHittable)
        XCTAssertTrue(app.buttons["home-record"].isHittable)
        XCTAssertTrue(app.buttons["home-import"].isHittable)
        attachScreenshot("Tones at XXL")
    }
}

/// An 8-bit sRGB pixel (also used by `AppearanceUITests`).
struct Pixel: CustomStringConvertible {
    let r: Int, g: Int, b: Int

    var description: String { String(format: "#%02X%02X%02X", r, g, b) }

    /// WCAG 2 relative luminance.
    var luminance: Double {
        func linear(_ v: Int) -> Double {
            let c = Double(v) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    func contrast(_ other: Pixel) -> Double {
        let (hi, lo) = (max(luminance, other.luminance), min(luminance, other.luminance))
        return (hi + 0.05) / (lo + 0.05)
    }

    func isClose(to other: Pixel, tolerance: Int = 4) -> Bool {
        abs(r - other.r) <= tolerance && abs(g - other.g) <= tolerance && abs(b - other.b) <= tolerance
    }
}

/// The app's screen as sRGB pixels, addressed in points.
struct ScreenPixels {
    private let bytes: [UInt8]
    private let width: Int, height: Int
    private let scale: CGFloat

    init?(_ app: XCUIApplication) {
        guard let image = app.screenshot().image.cgImage else { return nil }
        width = image.width
        height = image.height
        scale = CGFloat(image.width) / app.frame.width
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                                              CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
            return true
        }
        guard drawn else { return nil }
        self.bytes = bytes
    }

    func pixel(_ point: CGPoint) -> Pixel {
        let x = min(max(Int(point.x * scale), 0), width - 1)
        let y = min(max(Int(point.y * scale), 0), height - 1)
        let offset = (y * width + x) * 4
        return Pixel(r: Int(bytes[offset]), g: Int(bytes[offset + 1]), b: Int(bytes[offset + 2]))
    }

    /// The middle of the points' pixels by luminance: one that lands on an
    /// edge or a mark doesn't sway it.
    func median(_ points: [CGPoint]) -> Pixel {
        let pixels = points.map(pixel).sorted { $0.luminance < $1.luminance }
        return pixels[pixels.count / 2]
    }
}
