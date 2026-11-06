import Foundation

/// A chord label as the app writes it ("C", "F#m7", "D#m7♭5/A", "Gsus4"),
/// read back into pitch classes: the root, the chord tones and the bass.
///
/// Two producers write labels, both from `ChordAnalyzer`'s vocabulary:
/// `ChordAnalyzer.segments` (any of its 13 templates, with a "/X" bass when
/// another chord tone is lowest) and `HarmonyStage.label` (triads, 7, maj7, 6,
/// m7 and m6, with a slash bass on the third or fifth). Both name roots and
/// basses with sharps (`ChordAnalyzer.names`). The parser is the inverse of
/// that naming, so it reads the vocabulary from `ChordAnalyzer` itself; it
/// also takes flats ("Bb", "E♭") and the ASCII "m7b5" that MIDI markers carry
/// (`MidiExport.markerText`). Anything else, including "N" and "", is no
/// chord (nil).
///
/// `ChordSegment` keeps its plain string label: segments are shown, sent to
/// the AI chart and compared by label, so the symbol is parsed where it is
/// needed instead of stored beside it.
nonisolated struct ChordSymbol: Equatable {
    /// Root pitch class, 0 = C.
    let root: Int
    /// The quality as the app writes it: "", "m", "maj7", "m7♭5", ...
    let quality: String
    /// Intervals above the root, ascending, from `ChordAnalyzer.templates`.
    let intervals: [Int]
    /// The slash bass's pitch class; nil when the root is the bass.
    let slashBass: Int?

    /// The chord tones' pitch classes, root first.
    var tones: [Int] { intervals.map { (root + $0) % 12 } }
    /// Bit k set = pitch class k is a chord tone.
    var toneMask: Int { tones.reduce(0) { $0 | 1 << $1 } }
    /// The pitch class the chord stands on: the slash bass, else the root.
    var bass: Int { slashBass ?? root }

    init(root: Int, quality: String, intervals: [Int], slashBass: Int? = nil) {
        self.root = ((root % 12) + 12) % 12
        self.quality = quality
        self.intervals = intervals
        self.slashBass = slashBass.map { (($0 % 12) + 12) % 12 }
    }

    /// nil for "N", "", or anything outside the app's vocabulary.
    init?(_ label: String) {
        let text = label.trimmingCharacters(in: .whitespaces)
        let parts = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let head = parts.first, let name = Self.pitchClass(prefixOf: head) else { return nil }
        let root = name.pc
        var slash: Int?
        if parts.count == 2 {
            guard let bass = Self.pitchClass(prefixOf: parts[1]), bass.rest.isEmpty else { return nil }
            slash = bass.pc == root ? nil : bass.pc
        }
        let quality = name.rest == "m7b5" ? "m7♭5" : String(name.rest)
        guard let template = ChordAnalyzer.templates.first(where: { $0.suffix == quality }) else { return nil }
        self.init(root: root, quality: quality, intervals: template.intervals, slashBass: slash)
    }

    /// A note name at the start of `text` ("C", "F#", "Bb", "E♭") and what follows it.
    private static func pitchClass(prefixOf text: Substring) -> (pc: Int, rest: Substring)? {
        guard let letter = text.first else { return nil }
        let natural: Int
        switch letter {
        case "C": natural = 0
        case "D": natural = 2
        case "E": natural = 4
        case "F": natural = 5
        case "G": natural = 7
        case "A": natural = 9
        case "B": natural = 11
        default: return nil
        }
        var rest = text.dropFirst()
        var pc = natural
        // One accidental at most: no app label has a double sharp, and "b"
        // never starts a quality.
        if let sign = rest.first {
            switch sign {
            case "#", "♯": pc += 1; rest = rest.dropFirst()
            case "b", "♭": pc -= 1; rest = rest.dropFirst()
            default: break
            }
        }
        return ((pc % 12 + 12) % 12, rest)
    }
}
