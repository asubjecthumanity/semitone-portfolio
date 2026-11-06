import Foundation

/// A detected note with times in seconds and MIDI pitch.
nonisolated struct NoteEvent: Hashable {
    let startTime: Double
    let endTime: Double
    let pitch: Int
    let amplitude: Double
    /// The part of the arrangement this note belongs to. Only the any-instrument
    /// mode splits a take into parts; piano takes leave it `.none`.
    var voice: Voice = .none

    var noteName: String { Self.name(for: pitch) }

    static func name(for pitch: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return "\(names[pitch % 12])\(pitch / 12 - 1)"
    }

    var isBlackKey: Bool {
        [1, 3, 6, 8, 10].contains(pitch % 12)
    }

    /// The same note assigned to another part.
    func with(voice: Voice) -> NoteEvent {
        var copy = self
        copy.voice = voice
        return copy
    }
}

/// Which part of an arrangement a pitched note was assigned to. The raw
/// values are stored in saved takes, so new parts are appended, never inserted.
nonisolated enum Voice: UInt8, CaseIterable, Hashable {
    case none
    case melody
    case chords
    case bass
    /// A second single line beside the melody: above the bass, outside the
    /// block chords, answering the melody or moving against it.
    case countermelody

    /// The parts of a split take, in the order the app lists them.
    static let parts: [Voice] = [.melody, .countermelody, .chords, .bass]

    var label: String {
        switch self {
        case .none: "Notes"
        case .melody: "Melody"
        case .chords: "Chords"
        case .bass: "Bass"
        case .countermelody: "Countermelody"
        }
    }
}

/// A span with the sustain pedal held down, in seconds.
nonisolated struct PedalEvent: Hashable {
    let startTime: Double
    let endTime: Double
}
