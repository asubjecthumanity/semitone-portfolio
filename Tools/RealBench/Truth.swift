import Foundation

// RealBench answer-key format ("realbench-truth-1"). See README.md for the
// full description and an example. Times are seconds on the audio file's own
// timeline. Every section except `notes` is optional; a missing section is
// simply not scored.

nonisolated struct RBTruthNote: Codable {
    var on: Double
    var off: Double
    var pitch: Int
    var velocity: Int?
    /// "melody", "chords" or "bass" are scored against the app's parts of the
    /// same name; any other value ("piano", "soprano", "guitar 1") is a named
    /// part scored by recall.
    var part: String?
    /// Free text, e.g. "Acoustic Guitar (nylon)". Scored by recall like a part.
    var instrument: String?

    enum CodingKeys: String, CodingKey { case on, off, pitch, velocity, part, instrument }

    init(on: Double, off: Double, pitch: Int, velocity: Int? = nil, part: String? = nil, instrument: String? = nil) {
        self.on = on; self.off = off; self.pitch = pitch; self.velocity = velocity; self.part = part; self.instrument = instrument
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        on = try c.decode(Double.self, forKey: .on)
        off = try c.decodeIfPresent(Double.self, forKey: .off) ?? on
        // Fractional pitches (GuitarSet) round to the nearest semitone.
        pitch = Int(try c.decode(Double.self, forKey: .pitch).rounded())
        velocity = (try c.decodeIfPresent(Double.self, forKey: .velocity)).map { Int($0.rounded()) }
        part = try c.decodeIfPresent(String.self, forKey: .part)
        instrument = try c.decodeIfPresent(String.self, forKey: .instrument)
    }

    var partName: String { (part?.isEmpty == false ? part! : "notes") }
}

nonisolated struct RBTruthDrum: Codable {
    var time: Double
    /// "kick", "snare", "hihat" (scored) or anything else (kept, not scored).
    var `class`: String?
    /// General MIDI percussion key; used when `class` is missing.
    var gmNote: Int?
    var velocity: Int?

    /// The scored class, if any (MusicBench's 3-class convention).
    var scoredClass: DrumClass? {
        if let name = `class` { return RBTruthDrum.drumClass(named: name) }
        if let gm = gmNote { return DrumClass.of(gmNote: gm) }
        return nil
    }

    static func drumClass(named raw: String) -> DrumClass? {
        let s = raw.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        switch s {
        case "kick", "bd", "bassdrum", "kickdrum": return .kick
        case "snare", "sd", "snaredrum", "rimshot", "sidestick", "clap", "handclap", "electricsnare": return .snare
        case "hihat", "hh", "hat", "closedhat", "closedhihat", "openhat", "openhihat", "pedalhat", "pedalhihat",
             "chh", "ohh", "ride", "ridecymbal", "ridebell": return .hihat
        default: return nil
        }
    }
}

nonisolated struct RBTruthChord: Codable {
    var start: Double
    var end: Double
    /// "C:maj", "A:min7", "Bb:7/3", "N" (Harte) or app style "Am7", "F#", "Bbmaj7".
    var label: String?
    /// Pitch class of the root (0 = C); overrides the label's root.
    var root: Int?
    /// "maj", "min", "7", "maj7", "min7", "dim", "sus4", ...; overrides the label's quality.
    var quality: String?
}

nonisolated struct RBTruth: Codable {
    var format: String?
    var name: String?
    var notes: [RBTruthNote]?
    /// nil: drums not scored. [] : a drumless song (any detected hit is a false alarm).
    var drums: [RBTruthDrum]?
    var beats: [Double]?
    var downbeats: [Double]?
    var beatsPerBar: Int?
    var chords: [RBTruthChord]?
    /// [start, end] spans left out of every score (misaligned or unlabelled passages).
    var ignore: [[Double]]?
    /// false when audible pitched parts have no key (precision then counts real notes as false).
    var notesComplete: Bool?
    /// false when offsets are estimated (GuitarSet) or meaningless: offset/duration metrics are flagged.
    var offsetsReliable: Bool?
    var source: String?
    var comment: String?

    static func load(_ path: String) throws -> RBTruth {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var truth = try JSONDecoder().decode(RBTruth.self, from: data)
        if truth.format == nil { truth.format = "realbench-truth-1" }
        for (i, span) in (truth.ignore ?? []).enumerated() where span.count != 2 || !(span[0] <= span[1]) {
            throw RBError("truth ignore[\(i)] must be [start, end] with start <= end")
        }
        for (i, n) in (truth.notes ?? []).enumerated() where !(n.on.isFinite && n.off.isFinite) {
            throw RBError("truth notes[\(i)] has a non-finite time")
        }
        return truth
    }
}

nonisolated struct RBError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

// MARK: - Chords

/// Parses a truth chord into (root pitch class, quality string understood by
/// Scoring.majMin). nil root = no chord ("N", "X", unparseable).
nonisolated func truthChordRootQuality(_ chord: RBTruthChord) -> (root: Int, quality: String)? {
    var root: Int? = chord.root.map { (($0 % 12) + 12) % 12 }
    var quality = chord.quality
    if let label = chord.label?.trimmingCharacters(in: .whitespaces), !label.isEmpty,
       root == nil || quality == nil, let parsed = parseAnyChordLabel(label) {
        if root == nil { root = parsed.root }
        if quality == nil { quality = parsed.quality }
    }
    guard let r = root else { return nil }
    return (r, normalizeQuality(quality ?? "maj"))
}

private nonisolated let noteLetters: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]

/// Harte ("A:min7/b3", "N") or app/lead-sheet ("Am7", "F#", "Bbmaj7", "C-7", "Dm7b5") labels.
nonisolated func parseAnyChordLabel(_ raw: String) -> (root: Int, quality: String)? {
    let label = raw.trimmingCharacters(in: .whitespaces)
    if label.isEmpty || label == "N" || label == "X" || label.uppercased() == "NC" || label == "N.C." { return nil }
    var chars = Array(label)
    guard let first = chars.first.map({ Character($0.uppercased()) }), let base = noteLetters[first] else { return nil }
    var root = base
    chars.removeFirst()
    while let c = chars.first, c == "#" || c == "♯" || c == "b" || c == "♭" {
        // "b" right after the letter is a flat, unless the rest reads as a quality (none start with b).
        root += (c == "#" || c == "♯") ? 1 : -1
        chars.removeFirst()
    }
    root = ((root % 12) + 12) % 12
    var rest = String(chars)
    if rest.hasPrefix(":") { rest.removeFirst() }
    if let slash = rest.firstIndex(of: "/") { rest = String(rest[..<slash]) }
    if let paren = rest.firstIndex(of: "(") { rest = String(rest[..<paren]) }
    return (root, normalizeQuality(rest))
}

/// Maps quality spellings onto the names Scoring.majMin knows ("maj", "min",
/// "7", "maj7", "6", "min7", "min6") or a non-maj/min name ("dim", "aug", "sus4", ...).
nonisolated func normalizeQuality(_ raw: String) -> String {
    let q = raw.trimmingCharacters(in: .whitespaces)
    switch q {
    case "", "maj", "M", "major", "add9", "maj(9)", "69", "6/9", "add2": return "maj"
    case "5", "1", "power": return "power"
    case "min", "m", "-", "minor", "madd9", "minadd9": return "min"
    case "7", "dom7", "9", "11", "13", "7b9", "7#9", "7#11", "7b13": return "7"
    case "maj7", "M7", "Δ", "Δ7", "maj9", "M9", "maj13", "maj11": return "maj7"
    case "6", "maj6", "M6": return "6"
    case "min7", "m7", "-7", "min9", "m9", "min11", "m11", "min13", "m13": return "min7"
    case "min6", "m6", "-6": return "min6"
    case "minmaj7", "mM7", "m(maj7)", "min(maj7)", "mmaj7": return "min"
    case "dim", "o", "°": return "dim"
    case "dim7", "o7", "°7": return "dim7"
    case "hdim7", "m7b5", "m7♭5", "ø", "ø7", "-7b5", "min7b5": return "hdim7"
    case "aug", "+", "aug7", "+7": return "aug"
    case "sus4", "sus", "7sus", "7sus4", "9sus4", "9sus": return "sus4"
    case "sus2": return "sus2"
    default:
        if q.hasPrefix("maj") || q.hasPrefix("M") { return "maj7" }
        if q.hasPrefix("min") || q.hasPrefix("m") || q.hasPrefix("-") { return "min7" }
        if q.first.map({ $0.isNumber }) == true { return "7" }
        return q
    }
}

// MARK: - Scoring window

/// Which part of the timeline is scored: the clip [start, end) minus ignore spans.
nonisolated struct ScoreWindow {
    var start: Double
    var end: Double
    var ignore: [(Double, Double)]

    func contains(_ t: Double) -> Bool {
        guard t >= start, t < end else { return false }
        return !ignore.contains { t >= $0.0 && t < $0.1 }
    }

    /// Seconds of [a, b) inside the window, as sub-intervals.
    func clip(_ a: Double, _ b: Double) -> [(Double, Double)] {
        var parts: [(Double, Double)] = [(max(a, start), min(b, end))].filter { $0.0 < $0.1 }
        for (ia, ib) in ignore.sorted(by: { $0.0 < $1.0 }) {
            parts = parts.flatMap { p -> [(Double, Double)] in
                if ib <= p.0 || ia >= p.1 { return [p] }
                return [(p.0, ia), (ib, p.1)].filter { $0.0 < $0.1 }
            }
        }
        return parts
    }

    var scoredSeconds: Double { clip(start, end).reduce(0) { $0 + $1.1 - $1.0 } }
}
