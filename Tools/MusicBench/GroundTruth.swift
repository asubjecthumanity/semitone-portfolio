import Foundation

// Labels for one synthetic song: the sampler schedule and arrangement, so a
// transcription can be scored per part. Written by `render` next to each WAV
// (<name>.json) and read by `musicbench`. Times are seconds on the render
// timeline, not measured acoustic boundaries. Attacks, releases and reverb
// can move audible onsets/ends away from the scheduled commands.

/// Which part of the arrangement a pitched note belongs to.
nonisolated enum PartRole: String, Codable, CaseIterable {
    case melody
    case chords
    case bass
}

nonisolated struct TruthNote: Codable {
    var pitch: Int
    /// Slice-quantized note-on command, not the audible onset.
    var on: Double
    /// Slice-quantized key-release command, not the end of acoustic decay.
    var off: Double
    var velocity: Int
    var role: PartRole
    /// General MIDI program the part was rendered with (0-127).
    var program: Int
}

/// One drum hit. `gmNote` is the General MIDI percussion key (35-81).
nonisolated struct TruthDrum: Codable {
    /// Slice-quantized sampler trigger, not a measured acoustic onset.
    var time: Double
    var gmNote: Int
    var velocity: Int
}

/// The harmony of one span, as written by the generator.
nonisolated struct TruthChord: Codable {
    var start: Double
    var end: Double
    /// Pitch class of the root, 0 = C.
    var root: Int
    /// "maj", "min", "7", "maj7", "min7", "dim", "sus4", "sus2", ...
    var quality: String
    /// Display label, e.g. "F#m7".
    var label: String
}

nonisolated struct SongTruth: Codable {
    var name: String
    var style: String
    var bpm: Double
    var beatsPerBar: Int
    var duration: Double
    /// Tonic pitch class and mode, e.g. 9 / "minor" for A minor.
    var keyRoot: Int
    var keyMode: String
    var notes: [TruthNote]
    var drums: [TruthDrum]
    var beats: [Double]
    var downbeats: [Double]
    var chords: [TruthChord]
    /// Whether the mix went through a reverb.
    var reverb: Bool
}

/// Drum classes the benchmark scores (standard 3-class drum transcription).
nonisolated enum DrumClass: String, Codable, CaseIterable {
    case kick
    case snare
    case hihat

    /// General MIDI percussion key -> scored class; nil for toms, crashes and
    /// other percussion, which are left out of the drum score.
    static func of(gmNote: Int) -> DrumClass? {
        switch gmNote {
        case 35, 36: return .kick
        case 37, 38, 39, 40: return .snare
        case 42, 44, 46, 51, 53, 59: return .hihat
        default: return nil
        }
    }
}
