import XCTest
import SwiftUI
import UIKit
@testable import Semitone

/// Home's library: every word on the empty library's navy sample card reads
/// at AA (4.5:1) on the navy, as do the rows' words on the ground, the
/// search field's on its fill and the chips' on theirs; every mark on a
/// Tone's navy thumbnail at 3:1; and a song's countermelody stays apart from
/// its other parts with simulated protanopia or deuteranopia. Then the rolls' calmer part colours (`Voice.color`,
/// `Voice.outline`, the falling notes' black-key shade) and the record red,
/// the roll's firmer shades with Increase Contrast, and the app being light
/// only.
/// Worked out from the palette itself (WCAG 2 contrast, CIE76 and CIEDE2000
/// in CIELAB, Machado et al. 2009 at full severity), so a colour changed
/// later is checked again.
final class HomePaletteTests: XCTestCase {
    @MainActor
    func testSampleCardWordsReadOnTheNavy() {
        let navy = SRGB(HomeTheme.tile)
        for (kind, tint) in [("piano", ToneTint.piano), ("instrument", .instrument), ("song", .song)] {
            XCTAssertEqual(SRGB(tint.fill), navy, "Every thumbnail is the same navy (\(kind)).")
            XCTAssertGreaterThanOrEqual(SRGB(tint.title).contrast(navy), 4.5, "\(kind) title")
            XCTAssertGreaterThanOrEqual(SRGB(tint.label).contrast(navy), 4.5, "\(kind) label")
            XCTAssertGreaterThanOrEqual(SRGB(tint.secondary).contrast(navy), 4.5, "\(kind) date and counts")
        }
        // The kinds' labels differ in colour, which is all that tells them apart now.
        let labels = [ToneTint.piano, .instrument, .song].map { SRGB($0.label).lab }
        for (a, b) in [(0, 1), (0, 2), (1, 2)] {
            XCTAssertGreaterThan(distance(labels[a], labels[b]), 20)
        }
        // The thumbnail stands out from the ground.
        XCTAssertGreaterThanOrEqual(navy.contrast(SRGB(HomeTheme.ground)), 3)
    }

    /// The library's words off the navy: a row's title and its line under
    /// it on the ground, the search field's icon and prompt on its fill (the
    /// closest pair, 4.7:1), a chip's name on white, the chosen chip's on
    /// the navy.
    @MainActor
    func testLibraryWordsReadOnTheGround() {
        let ground = SRGB(HomeTheme.ground), secondary = SRGB(HomeTheme.secondary)
        XCTAssertGreaterThanOrEqual(SRGB(Color.black).contrast(ground), 4.5, "titles")
        XCTAssertGreaterThanOrEqual(secondary.contrast(ground), 4.5, "kind, key, length and day")
        XCTAssertGreaterThanOrEqual(secondary.contrast(SRGB(HomeTheme.searchFill)), 4.5, "the search field's prompt")
        XCTAssertGreaterThanOrEqual(SRGB(Color.black).contrast(SRGB(HomeTheme.searchFill)), 4.5, "what's typed")
        XCTAssertGreaterThanOrEqual(SRGB(HomeTheme.controlInk).contrast(.white), 4.5, "a chip")
        XCTAssertGreaterThanOrEqual(SRGB.white.contrast(SRGB(HomeTheme.navy)), 4.5, "the chosen chip")
        // The chips and the field stand apart from the ground they're on.
        XCTAssertGreaterThan(SRGB.white.contrast(ground), 1.05)
        XCTAssertGreaterThan(ground.contrast(SRGB(HomeTheme.searchFill)), 1.05)
    }

    @MainActor
    func testTonePreviewMarksStandOut() {
        let navy = SRGB(HomeTheme.tile)
        XCTAssertGreaterThanOrEqual(SRGB(ToneTint.piano.note).contrast(navy), 3, "right hand")
        XCTAssertGreaterThanOrEqual(SRGB(ToneTint.piano.noteLow).contrast(navy), 3, "left hand")
        XCTAssertGreaterThan(SRGB(ToneTint.piano.note).contrast(SRGB(ToneTint.piano.noteLow)), 1.5,
                             "The hands differ in lightness, not only hue.")
        XCTAssertGreaterThanOrEqual(SRGB(ToneTint.instrument.note).contrast(navy), 3, "instrument line")
        // A song's parts, each in its colour on the navy.
        for part in TonePreview.Part.allCases {
            XCTAssertGreaterThanOrEqual(SRGB(ToneTint.part(part)).contrast(navy), 3, part.name)
        }
    }

    /// 0.98's rule for the countermelody: with protanopia or deuteranopia
    /// simulated it keeps at least 38 CIELAB units from the melody, chords
    /// and bass. (A light mint, #3FD0B8, comes within 16 of the chords.)
    @MainActor
    func testCountermelodyStaysApartWithColourBlindness() {
        let others: [TonePreview.Part] = [.melody, .chords, .bass]
        for deficiency in [SRGB.protanopia, SRGB.deuteranopia, SRGB.normal] {
            let counter = SRGB(ToneTint.part(.countermelody)).simulating(deficiency).lab
            for part in others {
                let other = SRGB(ToneTint.part(part)).simulating(deficiency).lab
                XCTAssertGreaterThanOrEqual(distance(counter, other), 38, "countermelody and \(part.name)")
            }
        }
    }

    // MARK: The rolls' parts

    /// What the parts' colours replaced in Prerelease 0.96: iOS 26's light
    /// orange, blue, purple and mint (melody, chords, bass, countermelody).
    private static let systemParts: [Voice: SRGB] = [
        .melody: SRGB(hex: 0xFF8D28), .chords: SRGB(hex: 0x0088FF),
        .bass: SRGB(hex: 0xCB30E0), .countermelody: SRGB(hex: 0x00C8B3),
    ]

    /// Every part's outline reads at 3:1 or better on the roll's white and
    /// shaded rows, so a quiet note's light fill still has an edge.
    @MainActor
    func testRollPartOutlinesReadOnTheRows() {
        let shaded = SRGB(RollTheme.shadedRow)
        for voice in [Voice.none] + Voice.parts {
            let outline = SRGB(voice.outline)
            XCTAssertGreaterThanOrEqual(outline.contrast(.white), 3, "\(voice) on white")
            XCTAssertGreaterThanOrEqual(outline.contrast(shaded), 3, "\(voice) on the shaded rows")
        }
        XCTAssertGreaterThanOrEqual(SRGB(Voice.blackKeyNoteOutline).contrast(.white), 3)
    }

    /// The owner asked for less strong colours: every part's colour has at
    /// most 70% of the CIELAB chroma of the system colour it replaced (they
    /// measure 55-68%), and the record red at most 80% of 0.96's (74%).
    @MainActor
    func testRollPartsAndRecordAreCalmer() {
        for (voice, system) in Self.systemParts {
            XCTAssertLessThanOrEqual(SRGB(voice.color).chroma, 0.7 * system.chroma, "\(voice)")
        }
        XCTAssertLessThanOrEqual(SRGB(HomeTheme.record).chroma, 0.8 * SRGB(hex: 0xD70015).chroma)
        // Still a red to record with: the white clef on it, and "● REC" on the ground.
        XCTAssertGreaterThanOrEqual(SRGB.white.contrast(SRGB(HomeTheme.record)), 4.5)
        XCTAssertGreaterThanOrEqual(SRGB(HomeTheme.record).contrast(SRGB(HomeTheme.ground)), 4.5)
    }

    /// Each pair of parts, as the roll draws a note (80% loudness: 83% over
    /// white, and a quiet one at 55%), stays apart with normal vision and
    /// with simulated protanopia, deuteranopia and tritanopia: at least 13
    /// CIEDE2000 (the closest measure 14-27), and 9 for the quiet note
    /// (10-22). The system colours they replaced fail it: their chords blue
    /// and bass purple were 4 apart with deuteranopia.
    @MainActor
    func testRollPartsStayApartWithColourBlindness() {
        let parts = Voice.parts
        func closest(_ colours: [Voice: SRGB], opacity: Double, _ deficiency: [[Double]]) -> Double {
            var nearest = Double.infinity
            for (i, a) in parts.enumerated() {
                for b in parts[(i + 1)...] {
                    let x = colours[a]!.drawn(opacity: opacity).simulating(deficiency).lab
                    let y = colours[b]!.drawn(opacity: opacity).simulating(deficiency).lab
                    nearest = min(nearest, ciede2000(x, y))
                }
            }
            return nearest
        }
        let calm = Dictionary(uniqueKeysWithValues: parts.map { ($0, SRGB($0.color)) })
        for deficiency in [SRGB.normal, SRGB.protanopia, SRGB.deuteranopia, SRGB.tritanopia] {
            XCTAssertGreaterThanOrEqual(closest(calm, opacity: 0.83, deficiency), 13)
            XCTAssertGreaterThanOrEqual(closest(calm, opacity: 0.55, deficiency), 9)
        }
        XCTAssertLessThan(closest(Self.systemParts, opacity: 0.83, SRGB.deuteranopia), 5,
                          "The system blue and purple all but met.")
    }

    /// On a piano take's falling notes, the black keys' notes (a deeper
    /// violet) stay apart from the white keys' cornflower as drawn (83%
    /// over white): at least 15 CIEDE2000 with normal vision (they measure
    /// 20, as the system indigo and blue did), 12 with protanopia or
    /// deuteranopia (15 and 13; the system pair was 9 and 6) and 20 with
    /// tritanopia (33); a quiet note (55%) at least 7 (7-23). The first
    /// calmer shade, #7377C6, was only 11 with normal vision.
    @MainActor
    func testBlackKeyNotesStayApartFromWhiteKeyNotes() {
        let white = SRGB(Voice.none.color), black = SRGB(Voice.blackKeyNote)
        func apart(_ a: SRGB, _ b: SRGB, opacity: Double, _ deficiency: [[Double]]) -> Double {
            ciede2000(a.drawn(opacity: opacity).simulating(deficiency).lab, b.drawn(opacity: opacity).simulating(deficiency).lab)
        }
        XCTAssertGreaterThanOrEqual(apart(white, black, opacity: 0.83, SRGB.normal), 15)
        XCTAssertGreaterThanOrEqual(apart(white, black, opacity: 0.83, SRGB.protanopia), 12)
        XCTAssertGreaterThanOrEqual(apart(white, black, opacity: 0.83, SRGB.deuteranopia), 12)
        XCTAssertGreaterThanOrEqual(apart(white, black, opacity: 0.83, SRGB.tritanopia), 20)
        for deficiency in [SRGB.normal, SRGB.protanopia, SRGB.deuteranopia, SRGB.tritanopia] {
            XCTAssertGreaterThanOrEqual(apart(white, black, opacity: 0.55, deficiency), 7)
        }
        XCTAssertLessThan(apart(white, SRGB(hex: 0x7377C6), opacity: 0.83, SRGB.normal), 12, "The first calmer shade.")
        // Calmer than the system indigo it replaced, and its outline reads on the rows.
        XCTAssertLessThanOrEqual(black.chroma, 0.7 * SRGB(hex: 0x6155F5).chroma)
        XCTAssertGreaterThanOrEqual(SRGB(Voice.blackKeyNoteOutline).contrast(SRGB(RollTheme.shadedRow)), 3)
    }

    // MARK: Increase Contrast

    /// With Increase Contrast the roll firms up, as the system colours it
    /// drew before did: every line is firmer, those that carry the grid or a
    /// key's edge read at 3:1 or better on white, and the notes fill with
    /// their parts' outline colours, which as drawn (83% over white) stay at
    /// least 9 CIEDE2000 apart with normal vision and each simulated
    /// deficiency (they measure 10-27), 8 for a quiet note (9-21).
    @MainActor
    func testIncreaseContrastFirmsTheRoll() {
        let standard = EnvironmentValues()
        var increased = EnvironmentValues()
        increased._colorSchemeContrast = .increased
        let lines: [(String, RollLine)] = [
            ("hairline", RollTheme.hairline), ("octave line", RollTheme.octaveLine), ("bar line", RollTheme.barLine),
            ("beat line", RollTheme.beatLine), ("second line", RollTheme.secondLine), ("chord line", RollTheme.chordLine),
            ("hit line", RollTheme.hitLine), ("lane", RollTheme.lane), ("C lane", RollTheme.octaveLane),
            ("key seam", RollTheme.keySeam),
        ]
        for (name, line) in lines {
            let quiet = SRGB(line.resolve(in: standard)).over(.white)
            let firm = SRGB(line.resolve(in: increased)).over(.white)
            XCTAssertGreaterThan(firm.contrast(.white), quiet.contrast(.white) + 0.3, name)
        }
        for line in [RollTheme.barLine, RollTheme.beatLine, RollTheme.octaveLine, RollTheme.hitLine,
                     RollTheme.octaveLane, RollTheme.keySeam] {
            XCTAssertGreaterThanOrEqual(SRGB(line.resolve(in: increased)).over(.white).contrast(.white), 3)
        }

        let parts = Voice.parts
        for voice in [Voice.none] + parts {
            XCTAssertEqual(SRGB(voice.fill(for: .standard)), SRGB(voice.color))
            XCTAssertEqual(SRGB(voice.fill(for: .increased)), SRGB(voice.outline))
        }
        for deficiency in [SRGB.normal, SRGB.protanopia, SRGB.deuteranopia, SRGB.tritanopia] {
            for (i, a) in parts.enumerated() {
                for b in parts[(i + 1)...] {
                    let (x, y) = (SRGB(a.fill(for: .increased)), SRGB(b.fill(for: .increased)))
                    let loud = ciede2000(x.drawn(opacity: 0.83).simulating(deficiency).lab,
                                         y.drawn(opacity: 0.83).simulating(deficiency).lab)
                    let quiet = ciede2000(x.drawn(opacity: 0.55).simulating(deficiency).lab,
                                          y.drawn(opacity: 0.55).simulating(deficiency).lab)
                    XCTAssertGreaterThanOrEqual(loud, 9, "\(a) and \(b)")
                    XCTAssertGreaterThanOrEqual(quiet, 8, "\(a) and \(b), quiet")
                }
            }
        }
    }

    // MARK: Light only

    /// The app is light whatever the system setting: Info.plist says so for
    /// everything UIKit draws (and `RootView` asks SwiftUI for light too).
    /// `AppearanceUITests` checks the screens with the system in dark mode.
    func testTheAppIsLightOnly() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "UIUserInterfaceStyle") as? String, "Light")
    }
}

/// A colour as sRGB components (0...1, gamma-encoded) and its opacity.
private struct SRGB: Equatable {
    var r: Double, g: Double, b: Double, a: Double = 1

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        (self.r, self.g, self.b, self.a) = (r, g, b, a)
    }

    init(hex: UInt32) {
        self.init(r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255, b: Double(hex & 0xFF) / 255)
    }

    static let white = SRGB(r: 1, g: 1, b: 1)

    init(_ color: Color) {
        var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(r: r, g: g, b: b, a: a)
        // Compared in 8-bit steps, as the colours are written.
        (self.r, self.g, self.b) = ((self.r * 255).rounded() / 255, (self.g * 255).rounded() / 255, (self.b * 255).rounded() / 255)
    }

    /// At `opacity` over white, as the roll draws a note on a white row.
    func drawn(opacity: Double) -> SRGB { SRGB(r: r, g: g, b: b, a: opacity).over(.white) }

    /// Drawn over an opaque colour (blended in sRGB, as the app draws it).
    func over(_ ground: SRGB) -> SRGB {
        SRGB(r: r * a + ground.r * (1 - a), g: g * a + ground.g * (1 - a), b: b * a + ground.b * (1 - a))
    }

    private static func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    private static func encoded(_ c: Double) -> Double {
        let c = min(max(c, 0), 1)
        return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }
    private var linear: [Double] { [r, g, b].map(Self.linear) }

    /// WCAG 2 relative luminance and contrast ratio.
    var luminance: Double { zip(linear, [0.2126, 0.7152, 0.0722]).map(*).reduce(0, +) }
    func contrast(_ other: SRGB) -> Double {
        let (hi, lo) = (max(luminance, other.luminance), min(luminance, other.luminance))
        return (hi + 0.05) / (lo + 0.05)
    }

    /// CIELAB (D65).
    var lab: [Double] {
        let l = linear
        let x = (0.4124564 * l[0] + 0.3575761 * l[1] + 0.1804375 * l[2]) / 0.95047
        let y = 0.2126729 * l[0] + 0.7151522 * l[1] + 0.0721750 * l[2]
        let z = (0.0193339 * l[0] + 0.1191920 * l[1] + 0.9503041 * l[2]) / 1.08883
        func f(_ t: Double) -> Double { t > 216 / 24389 ? cbrt(t) : (24389 / 27 * t + 16) / 116 }
        return [116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z))]
    }

    /// CIELAB chroma: how strong the colour is.
    var chroma: Double { let l = lab; return sqrt(l[1] * l[1] + l[2] * l[2]) }

    /// Machado, Oliveira and Fernandes (2009), severity 1, on linear RGB.
    static let normal: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
    static let protanopia: [[Double]] = [[0.152286, 1.052583, -0.204868],
                                         [0.114503, 0.786281, 0.099216],
                                         [-0.003882, -0.048116, 1.051998]]
    static let deuteranopia: [[Double]] = [[0.367322, 0.860646, -0.227968],
                                           [0.280085, 0.672501, 0.047413],
                                           [-0.011820, 0.042940, 0.968881]]
    static let tritanopia: [[Double]] = [[1.255528, -0.076749, -0.178779],
                                         [-0.078411, 0.930809, 0.147602],
                                         [0.004733, 0.691367, 0.303900]]

    func simulating(_ m: [[Double]]) -> SRGB {
        let l = linear
        let out = m.map { row in Self.encoded(zip(row, l).map(*).reduce(0, +)) }
        return SRGB(r: out[0], g: out[1], b: out[2], a: a)
    }
}

/// CIE76: the straight distance in CIELAB.
private func distance(_ a: [Double], _ b: [Double]) -> Double {
    sqrt(zip(a, b).map { ($0 - $1) * ($0 - $1) }.reduce(0, +))
}

/// CIEDE2000 (Sharma, Wu and Dalal 2005): distance in CIELAB weighted as
/// the eye judges small differences.
private func ciede2000(_ lab1: [Double], _ lab2: [Double]) -> Double {
    func degrees(_ r: Double) -> Double { r * 180 / .pi }
    func radians(_ d: Double) -> Double { d * .pi / 180 }
    let (l1, a1, b1) = (lab1[0], lab1[1], lab1[2])
    let (l2, a2, b2) = (lab2[0], lab2[1], lab2[2])
    let cBar = (sqrt(a1 * a1 + b1 * b1) + sqrt(a2 * a2 + b2 * b2)) / 2
    let g = 0.5 * (1 - sqrt(pow(cBar, 7) / (pow(cBar, 7) + pow(25, 7))))
    let (a1p, a2p) = ((1 + g) * a1, (1 + g) * a2)
    let (c1p, c2p) = (sqrt(a1p * a1p + b1 * b1), sqrt(a2p * a2p + b2 * b2))
    func hue(_ b: Double, _ a: Double) -> Double {
        let h = degrees(atan2(b, a))
        return h < 0 ? h + 360 : h
    }
    let (h1p, h2p) = (hue(b1, a1p), hue(b2, a2p))
    var dh = 0.0
    if c1p * c2p != 0 {
        dh = h2p - h1p
        if dh > 180 { dh -= 360 } else if dh < -180 { dh += 360 }
    }
    let dL = l2 - l1, dC = c2p - c1p
    let dH = 2 * sqrt(c1p * c2p) * sin(radians(dh / 2))
    let lBar = (l1 + l2) / 2, cBarP = (c1p + c2p) / 2
    var hBar = h1p + h2p
    if c1p * c2p != 0 {
        if abs(h1p - h2p) <= 180 { hBar = (h1p + h2p) / 2 }
        else if h1p + h2p < 360 { hBar = (h1p + h2p + 360) / 2 }
        else { hBar = (h1p + h2p - 360) / 2 }
    }
    let t = 1 - 0.17 * cos(radians(hBar - 30)) + 0.24 * cos(radians(2 * hBar))
        + 0.32 * cos(radians(3 * hBar + 6)) - 0.20 * cos(radians(4 * hBar - 63))
    let dTheta = 30 * exp(-pow((hBar - 275) / 25, 2))
    let rc = 2 * sqrt(pow(cBarP, 7) / (pow(cBarP, 7) + pow(25, 7)))
    let sl = 1 + 0.015 * pow(lBar - 50, 2) / sqrt(20 + pow(lBar - 50, 2))
    let sc = 1 + 0.045 * cBarP, sh = 1 + 0.015 * cBarP * t
    let rt = -sin(radians(2 * dTheta)) * rc
    return sqrt(pow(dL / sl, 2) + pow(dC / sc, 2) + pow(dH / sh, 2) + rt * (dC / sc) * (dH / sh))
}
