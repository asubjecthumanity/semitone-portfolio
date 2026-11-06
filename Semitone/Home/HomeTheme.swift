import SwiftUI

/// The home screen's palette: a grouped-list grey ground, brand navy for the
/// wordmark, the selected mode, the selected filter chip, Settings and every
/// Tone's thumbnail (its kind told by colour, `ToneTint`), black headings
/// and titles on the ground. Set in the system font. The whole app is light only (`RootView`), and the transcription
/// screen takes this look too (`RollTheme`).
enum HomeTheme {
    /// The ground under the library (iOS's grouped background).
    static let ground = Color(hex: 0xF2F2F7)
    /// The brand navy (14.9:1 on the ground).
    static let navy = Color(hex: 0x0F1E3A)
    /// Secondary text on the ground, like a Tone's kind, key and length
    /// under its title (5.4:1), and the search field's icon and prompt
    /// (4.7:1 on its fill).
    static let secondary = Color(hex: 0x636366)
    /// The search field's fill: iOS's tertiary fill as it shows on the
    /// grouped ground.
    static let searchFill = Color(hex: 0xE3E3E8)
    /// The hairline between two Tones' rows: iOS's separator as it shows on
    /// the grouped ground.
    static let separator = Color(hex: 0xD1D1D6)
    /// The record disc and the level ring, here and on the transcription
    /// screen. A step softer than 0.96's #D70015 (OKLCH chroma 20% lower,
    /// same lightness, a touch toward crimson), still plainly red: the white
    /// clef on it reads at 5.3:1 (was 5.4:1), and as the "● REC" text on the
    /// ground it reads at 4.7:1 (the system red it replaces there was 3.2:1).
    /// Written here only: the roll's live edge (`RollTheme.liveEdge`) and a
    /// Tone's Settings (`SettingsTheme.destructive`) take it from here, so
    /// it is nonisolated for the rolls' palette.
    nonisolated static let record = Color(hex: 0xC63639)

    /// Ink on the glass controls: labels, the "+", the import choices.
    static let controlInk = Color(hex: 0x1C1C1E)
    /// Unselected mode icons and secondary text on glass (10.4:1 on white).
    static let controlSecondary = Color(hex: 0x3C3C43)
    /// A choice that's switched off, like Link (6.4:1 on white; 4.8:1 on its
    /// glass over navy, as measured when Tones were navy tiles).
    static let controlDisabled = Color(hex: 0x5E5E63)
    /// The "Experimental" chip's text (7.4:1 on white). Over navy (Tones
    /// were navy tiles then) the chip's glass measured #D5DBE5, where 0.97's
    /// #9A4D00 read at 4.4:1; this one reads at 5.3:1.
    static let experimental = Color(hex: 0x874300)

    static func navy(_ opacity: Double) -> Color { navy.opacity(opacity) }

    /// A Tone's thumbnail (and the empty library's sample card): the brand
    /// navy lifted a step (the owner found it harsh on the tiles the library
    /// was before), a softer slate navy at 12.5:1 on the ground. The
    /// wordmark, the selected mode and the other navy marks keep the brand
    /// navy itself.
    static let tile = Color(hex: 0x1D2C4A)

    /// The bottom controls' glass, pinned light. The library passes under
    /// it, navy thumbnails and all, and plain glass takes on what's under it:
    /// over a navy tile (as the library was) it measured #A0A6B0, where the
    /// unselected mode icons read at 4.5:1 and the navy thumb at 6.8:1. With
    /// this white tint it measured #C6CCD6: ink 10.5:1, icons 6.8:1, the
    /// thumb 10.3:1 (`controlInk`, `controlSecondary`).
    static let controlTint = Color.white.opacity(0.45)
}

/// The colours on a Tone's navy: its thumbnail, and the empty library's
/// sample card, which also carries words. Every one is the softer navy
/// (`HomeTheme.tile`) with a hairline white edge; its kind is told by
/// colour: the shades its notes are drawn in (and on the sample card the
/// kind's label), each remapped to read on the navy. The card's title is
/// white, its words a pale slate.
///
/// The kind colours are calmer than 0.96's (the owner asked for less strong
/// colours): each keeps its hue and lightness with about 28% less OKLCH
/// chroma (the countermelody 24% less, and deeper; see `part`). 0.93's
/// lighter navy costs every colour on it some contrast (the brand navy gave
/// about 1.2 times these); the figures below are on that navy.
struct ToneTint {
    let fill = HomeTheme.tile
    let edge = Color.white.opacity(0.10)
    /// White: 13.9:1.
    let title = Color.white
    /// The sample card's words: 7.4:1.
    let secondary = Color(hex: 0xB4BED3)
    /// The kind's name and icon.
    let label: Color
    /// Piano's right hand, Instrument's line.
    let note: Color
    /// Piano's left hand, where the take has one (`TonePreview.handSplit`);
    /// the other kinds draw no second shade.
    let noteLow: Color

    init(label: Color, note: Color, noteLow: Color? = nil) {
        self.label = label
        self.note = note
        self.noteLow = noteLow ?? note
    }

    /// Blue: label 7.8:1; the right hand 6.4:1, the left hand a deeper blue
    /// at 3.2:1, which still tells the hands apart (2.0:1 between them).
    static let piano = ToneTint(label: Color(hex: 0xB0C3E7), note: Color(hex: 0x97B1E2), noteLow: Color(hex: 0x6379A7))
    /// Green: label 8.2:1, the line 6.6:1.
    static let instrument = ToneTint(label: Color(hex: 0x9AD4B1), note: Color(hex: 0x7AC296))
    /// Peach: label 7.8:1. The three kinds' labels
    /// stay 41-48 CIELAB units apart (they were 58-68).
    static let song = ToneTint(label: Color(hex: 0xEAB992), note: Color(hex: 0xE4A271))

    /// A song's parts, each at least 3:1 on the navy: melody, chords and bass
    /// in oranges and browns, which differ in lightness as well as hue
    /// (chords lightest, bass darkest, as on the peach tiles of 0.96), and
    /// the countermelody in a soft cerulean.
    /// A light mint (#3FD0B8), simulated with protanopia, comes within 16
    /// CIELAB units of the light chords (CIE76), as close as the melody to
    /// the bass. Softened as the others, 0.96's turquoise (#40C8E0) would
    /// have come within 29 of the chords; so it is a little deeper and bluer
    /// than that, which keeps it at least 40 units from the other three with
    /// protanopia or deuteranopia (50 with normal vision). The other three
    /// sit 16-37 apart from each other (17-44 before).
    static func part(_ part: TonePreview.Part) -> Color {
        switch part {
        // 6.4:1
        case .melody: Color(hex: 0xE4A271)
        // 4.9:1
        case .countermelody: Color(hex: 0x53A4C1)
        // 10.2:1
        case .chords: Color(hex: 0xF2D9BF)
        // 3.9:1
        case .bass: Color(hex: 0xB37A53)
        }
    }
}

extension TonePreview.Kind {
    var tint: ToneTint {
        switch self {
        case .piano: .piano
        case .instrument: .instrument
        case .song: .song
        }
    }
}

extension Color {
    /// Nonisolated, so the rolls' palette (`RollTheme`) can use it too.
    nonisolated init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// A press that shrinks a little (a Tone's row, a filter chip), or only dims
/// with Reduce Motion.
struct PressScaleStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.85 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// A glass control's press: the content gives a little (the glass responds
/// on its own). Unlike `.plain` it doesn't fade a disabled control, whose
/// colours are chosen to stay legible (AA).
struct GlassControlStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.7 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}
