import SwiftUI

extension Voice {
    /// Each part's colour on the roll and on the lit keys: the notes' fill
    /// (at the note's loudness), the lit keys, a part chip's dot. With
    /// Increase Contrast the rolls and the chips' dots fill with `outline`
    /// instead (`fill(for:)`).
    ///
    /// Calmer than the system colours they replace (orange, blue, purple,
    /// mint), as the owner asked: each has 29-43% less OKLCH chroma, and
    /// they differ in lightness as well as hue (bass deepest, then chords,
    /// melody, countermelody lightest), which is what keeps them apart with
    /// colour blindness. Measured on a note as the roll draws it (80%
    /// loudness: 83% over white), simulated (Machado et al. 2009, full
    /// severity), the closest pair is now 20 CIEDE2000 apart with protanopia
    /// (chords and bass; 11 in the system colours), 16 with deuteranopia
    /// (chords and bass; 4 before, where the blue and purple all but met),
    /// 14 with tritanopia (chords and countermelody; 12 before) and 27 with
    /// normal vision (34 before: calmer colours sit closer). A quiet note
    /// (55% over white) keeps at least 10 with any of the three (3 before).
    /// The countermelody's nearest part is the chords, 18-27 CIEDE2000 with
    /// normal vision, protanopia or deuteranopia (CIE76 34-47); from the
    /// melody it keeps CIE76 38-61 (the system mint kept 52-94).
    var color: Color {
        switch self {
        case .none, .chords: PartColors.chords
        case .melody: PartColors.melody
        case .bass: PartColors.bass
        case .countermelody: PartColors.countermelody
        }
    }

    /// A deeper shade of the part's colour, for the notes' outlines (and a
    /// part chip's ring round its dot), so a quiet note's light fill still
    /// has a clear edge: each reads at 3:1 or better on the roll's white and
    /// shaded rows (melody 3.8:1 and 3.4:1, chords 5.0:1 and 4.5:1, bass
    /// 9.2:1 and 8.3:1, countermelody 3.8:1 and 3.4:1).
    var outline: Color {
        switch self {
        case .none, .chords: PartColors.chordsOutline
        case .melody: PartColors.melodyOutline
        case .bass: PartColors.bassOutline
        case .countermelody: PartColors.countermelodyOutline
        }
    }

    /// The part's fill as the rolls draw it (the notes, the lit keys):
    /// `color`, or with Increase Contrast the deeper `outline` (the system
    /// colours the parts had before darkened with it too). As drawn (83% over
    /// white) those read at 2.9:1 (melody, countermelody) to 6.0:1 (bass)
    /// on white, where the calm fills are 1.4:1 to 4.2:1, and stay apart:
    /// closest 27 CIEDE2000 with normal vision, 18 with protanopia, 14 with
    /// deuteranopia, 10 with tritanopia (chords and countermelody; the
    /// system colours were 34, 11, 4 and 12), and a quiet note (55%) at
    /// least 9 with any of the three.
    func fill(for contrast: ColorSchemeContrast) -> Color {
        contrast == .increased ? outline : color
    }

    /// On the falling notes, an unsplit take's notes on the black keys: a
    /// deeper violet than the white keys' cornflower (it was the system
    /// indigo), with its outline (8.2:1 on white). As drawn (83% over
    /// white) the two are 20 CIEDE2000 apart with normal vision (the indigo
    /// and blue were 20 too), 15 with protanopia (9), 13 with deuteranopia
    /// (6), 33 with tritanopia (14); a quiet note (55%) 14, 8, 7 and 23
    /// (18, 5, 2 and 17). With Increase Contrast it fills with its outline,
    /// as the parts do: 18, 13, 10 and 33 from the chords' outline.
    static let blackKeyNote = Color(hex: 0x7A5BAC)
    static let blackKeyNoteOutline = Color(hex: 0x5E3F8C)
}

/// The parts' colours, made once: the rolls ask for them per note, and on
/// the falling notes every frame.
private enum PartColors {
    /// Cornflower, the brand navy's hue. Unsplit notes (a piano take's) are
    /// drawn in it too.
    static let chords = Color(hex: 0x759CEF)
    static let chordsOutline = Color(hex: 0x476DC3)
    /// Apricot.
    static let melody = Color(hex: 0xF8AA6D)
    static let melodyOutline = Color(hex: 0xC06F2C)
    /// Plum: the deepest, so the chords' blue and it stay apart with
    /// red-green colour blindness, where blue and purple meet.
    static let bass = Color(hex: 0x974391)
    static let bassOutline = Color(hex: 0x772473)
    /// Pale aqua: the lightest, and bluer than a mint, so it stays apart
    /// from the melody with red-green colour blindness.
    static let countermelody = Color(hex: 0x83E8E7)
    static let countermelodyOutline = Color(hex: 0x0F9293)
}

extension Voice {
    /// The chords part is drawn under the other parts where notes overlap at
    /// a pitch. Simplified's voicings are held to the next strike, so drawn
    /// over the lines they covered a melody, countermelody or bass note at
    /// their pitch from the voicing's strike on, and the line looked cut
    /// short though it is unchanged.
    var drawnBeneath: Bool { self == .chords }
}

/// The keys lit under the playhead: per pitch, the brightest sounding note's
/// level, in the colour of the part drawn on top there
/// (`Voice.drawnBeneath`), so a key shared by a line and a chord shows the
/// line, as the roll does. The part is kept, not its colour: the keys take
/// its fill for the Increase Contrast setting (`Voice.fill(for:)`).
struct KeyLights {
    private var lights: [Int: (level: Double, voice: Voice, beneath: Bool)] = [:]

    mutating func light(_ note: NoteEvent, level: Double) {
        let beneath = note.voice.drawnBeneath
        guard let lit = lights[note.pitch] else {
            lights[note.pitch] = (level, note.voice, beneath)
            return
        }
        let shows = beneath != lit.beneath ? !beneath : level > lit.level
        lights[note.pitch] = (max(level, lit.level), shows ? note.voice : lit.voice, beneath && lit.beneath)
    }

    subscript(pitch: Int) -> (level: Double, voice: Voice)? {
        lights[pitch].map { ($0.level, $0.voice) }
    }

    /// The keys lit, in no set order.
    var pitches: [Int] { Array(lights.keys) }
}
