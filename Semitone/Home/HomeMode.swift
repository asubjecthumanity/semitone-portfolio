import Foundation

/// What the record button and Import listen for, chosen on the mode
/// segments: Instrument · Piano · Song, left to right. Piano is the default.
enum HomeMode: String, CaseIterable, Identifiable {
    case instrument
    case piano
    case song

    var id: String { rawValue }

    var title: String {
        switch self {
        case .instrument: "Instrument"
        case .piano: "Piano"
        case .song: "Song"
        }
    }

    /// What the label over the record button spells out just after a change.
    var summary: String {
        switch self {
        case .instrument: "One instrument or voice"
        case .piano: "Solo piano"
        case .song: "Melody, chords and bass"
        }
    }

    /// The record button's hint.
    var caption: String {
        switch self {
        case .instrument: "Listens for one instrument or voice"
        case .piano: "Listens for solo piano"
        case .song: "Listens for a whole song and writes its melody, chords and bass"
        }
    }

    /// The engine mode a take started in this mode uses.
    var transcriptionMode: TranscriptionMode {
        switch self {
        case .piano:
            .piano
        case .song:
            .music
        case .instrument:
            // Instrument (a single line: one instrument or a voice) has no
            // engine mode of its own yet. It uses the any-instrument pass, which
            // splits the take into parts; a monophonic take comes out as a lone
            // melody part, which the library then shows as an Instrument tone.
            .music
        }
    }
}
