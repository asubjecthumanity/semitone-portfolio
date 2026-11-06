import Foundation

// Deterministic generator for the synthetic benchmark songs.
//
// A `SongSpec` (name, style, seed) fully determines a song: tempo, meter, key, form,
// harmony and every note of every part. Music is written on a beat grid (beats counted
// from the first downbeat) and turned into seconds by a `TempoMap`, which also applies
// swing and the optional gentle tempo drift. `Render.swift` plays the result through
// Apple's General MIDI bank and writes the audio plus exact ground truth.
//
// Only `SplitMix64` supplies randomness, and each part draws from its own stream, so a
// change to (say) the drum writer leaves the melody of every song untouched.

// MARK: - Random numbers

/// SplitMix64 (Steele, Lea & Flood 2014). Tiny and fully specified, so a seed gives the
/// same songs on every machine and toolchain. It deliberately does not conform to
/// `RandomNumberGenerator`: the stdlib's sampling algorithms may change between Swift
/// releases, so all sampling below is done by hand.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    /// Seed of a named sub-stream of `seed` (FNV-1a of the label, mixed through SplitMix).
    static func seed(_ seed: UInt64, _ label: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in label.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        var mixer = SplitMix64(seed: seed ^ hash)
        return mixer.next()
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) * 0x1p-53 }

    mutating func uniform(_ range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * unit()
    }

    /// Uniform integer in `range` (multiply-shift; the bias is negligible for small ranges).
    mutating func int(_ range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(((next() >> 32) &* span) >> 32)
    }

    mutating func chance(_ probability: Double) -> Bool { unit() < probability }

    /// Uniform in ±`amount`.
    mutating func jitter(_ amount: Double) -> Double { (unit() * 2 - 1) * amount }

    mutating func pick<T>(_ items: [T]) -> T {
        precondition(!items.isEmpty, "pick from an empty list")
        return items[int(0...(items.count - 1))]
    }

    mutating func weighted<T>(_ items: [(T, Double)]) -> T {
        let total = items.reduce(0) { $0 + $1.1 }
        var x = unit() * total
        for (item, weight) in items {
            if x < weight { return item }
            x -= weight
        }
        return items[items.count - 1].0
    }

    /// Fisher-Yates.
    mutating func shuffled<T>(_ items: [T]) -> [T] {
        var result = items
        for i in stride(from: result.count - 1, to: 0, by: -1) { result.swapAt(i, int(0...i)) }
        return result
    }

    /// An independent stream, so extra draws in one place don't shift another.
    mutating func fork() -> SplitMix64 { SplitMix64(seed: next()) }
}

// MARK: - Harmony

/// Positive remainder mod 12 (pitch class of a MIDI note or interval).
func mod12(_ x: Int) -> Int { ((x % 12) + 12) % 12 }

/// Chord qualities. Raw values are the strings written to the ground truth.
enum ChordQuality: String {
    case maj, min, dom7 = "7", maj7, min7, dim, m7b5, sus4, sus2, maj6 = "6", min6, aug

    /// Semitones above the root, in chord order (root, third, fifth, seventh/sixth).
    var intervals: [Int] {
        switch self {
        case .maj: [0, 4, 7]
        case .min: [0, 3, 7]
        case .dom7: [0, 4, 7, 10]
        case .maj7: [0, 4, 7, 11]
        case .min7: [0, 3, 7, 10]
        case .dim: [0, 3, 6]
        case .m7b5: [0, 3, 6, 10]
        case .sus4: [0, 5, 7]
        case .sus2: [0, 2, 7]
        case .maj6: [0, 4, 7, 9]
        case .min6: [0, 3, 7, 9]
        case .aug: [0, 4, 8]
        }
    }

    var labelSuffix: String {
        switch self {
        case .maj: ""
        case .min: "m"
        case .dom7: "7"
        case .maj7: "maj7"
        case .min7: "m7"
        case .dim: "dim"
        case .m7b5: "m7b5"
        case .sus4: "sus4"
        case .sus2: "sus2"
        case .maj6: "6"
        case .min6: "m6"
        case .aug: "aug"
        }
    }
}

struct Chord: Equatable {
    static func noteName(_ pc: Int, sharps: Bool) -> String {
        (sharps ? ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
                : ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"])[mod12(pc)]
    }

    /// Pitch class of the root, 0 = C.
    var root: Int
    var quality: ChordQuality

    /// Pitch classes in chord order, root first.
    var tones: [Int] { quality.intervals.map { mod12(root + $0) } }
    func label(sharps: Bool) -> String { Chord.noteName(root, sharps: sharps) + quality.labelSuffix }
    /// Second chord tone above the root (the third, or the suspended tone).
    var thirdInterval: Int { quality.intervals[1] }
    var fifthInterval: Int { quality.intervals[2] }
    /// The seventh (or sixth) when the chord has one.
    var seventhInterval: Int? { quality.intervals.count > 3 ? quality.intervals[3] : nil }
}

struct Key {
    var tonic: Int
    var isMinor: Bool

    var mode: String { isMinor ? "minor" : "major" }

    /// Spell names with sharps in keys whose (relative) major is G, D, A, E, B or F#.
    var usesSharps: Bool { [7, 2, 9, 4, 11, 6].contains(mod12(tonic + (isMinor ? 3 : 0))) }

    /// e.g. "F#m", "Bb".
    var name: String { Chord.noteName(tonic, sharps: usesSharps) + (isMinor ? "m" : "") }

    /// Pitch classes of the natural major / natural minor scale.
    var scale: [Int] {
        (isMinor ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 4, 5, 7, 9, 11]).map { mod12(tonic + $0) }
    }

    /// The key's scale with each clashing degree swapped for the chord's own tone (the
    /// raised 7th over V in minor, the b7 over I7, the #4 over a dorian IV7...), sorted.
    func scale(over chord: Chord) -> [Int] {
        var pcs = scale
        for tone in chord.tones where !pcs.contains(tone) {
            if let i = pcs.firstIndex(where: { abs(mod12($0 - tone + 6) - 6) == 1 && !chord.tones.contains($0) }) {
                pcs[i] = tone
            } else {
                pcs.append(tone)
            }
        }
        return pcs.sorted()
    }

    /// A space-separated Roman-numeral progression, e.g. "i bVI bIII bVII".
    func progression(_ text: String) -> [Chord] {
        text.split(separator: " ").map { chord(String($0)) }
    }

    /// Parses one Roman-numeral symbol relative to the tonic. Upper case is major, lower
    /// case minor; a leading "b"/"#" shifts the root. Suffixes: "7" (dominant on upper
    /// case, minor seventh on lower), "maj7", "6", "ø7" (half-diminished), "°", "+",
    /// "sus2", "sus4".
    func chord(_ symbol: String) -> Chord {
        var rest = Substring(symbol)
        var shift = 0
        while let c = rest.first, c == "b" || c == "#" {
            shift += c == "b" ? -1 : 1
            rest = rest.dropFirst()
        }
        // Longest numerals first, so "VII" isn't read as "V".
        let numerals = [("VII", 11), ("VI", 9), ("IV", 5), ("V", 7), ("III", 4), ("II", 2), ("I", 0)]
        for (numeral, degree) in numerals {
            let upper = rest.hasPrefix(numeral)
            guard upper || rest.hasPrefix(numeral.lowercased()) else { continue }
            let quality: ChordQuality
            switch rest.dropFirst(numeral.count) {
            case "": quality = upper ? .maj : .min
            case "7": quality = upper ? .dom7 : .min7
            case "maj7": quality = .maj7
            case "6": quality = upper ? .maj6 : .min6
            case "ø7": quality = .m7b5
            case "°": quality = .dim
            case "+": quality = .aug
            case "sus2": quality = .sus2
            case "sus4": quality = .sus4
            default: preconditionFailure("unknown chord suffix in \(symbol)")
            }
            return Chord(root: mod12(tonic + degree + shift), quality: quality)
        }
        preconditionFailure("unknown Roman numeral \(symbol)")
    }
}

/// The pitch with pitch class `pc` nearest to `target` (ties go down).
func nearestPitch(pc: Int, to target: Int) -> Int {
    let below = target - mod12(target - pc)
    return target - below <= below + 12 - target ? below : below + 12
}

/// Folds `pitch` into `range` by octaves.
func fold(_ pitch: Int, into range: ClosedRange<Int>) -> Int {
    var p = pitch
    while p > range.upperBound { p -= 12 }
    while p < range.lowerBound { p += 12 }
    return p
}

/// `pitch` if it is in the scale, else its nearest scale neighbour (lower on a tie).
func snapToScale(_ pitch: Int, _ scale: [Int]) -> Int {
    if scale.contains(mod12(pitch)) { return pitch }
    if scale.contains(mod12(pitch - 1)) { return pitch - 1 }
    return pitch + 1
}

/// Moves `steps` scale degrees from `pitch` (after snapping it to the scale).
func moveInScale(_ pitch: Int, steps: Int, scale: [Int]) -> Int {
    var p = snapToScale(pitch, scale)
    for _ in 0..<abs(steps) {
        repeat { p += steps > 0 ? 1 : -1 } while !scale.contains(mod12(p))
    }
    return p
}

/// The chord tone nearest to `pitch`; with a `direction`, ties and near-ties favour
/// continuing that way.
func nearestChordTone(_ pitch: Int, _ chord: Chord, direction: Int = 0) -> Int {
    let tones = chord.tones
    var best = pitch
    var bestScore = Double.infinity
    for p in (pitch - 7)...(pitch + 7) where tones.contains(mod12(p)) {
        var score = Double(abs(p - pitch))
        if direction != 0 && (p - pitch) * direction < 0 { score += 0.6 }
        if score < bestScore { best = p; bestScore = score }
    }
    return best
}

// MARK: - Styles

enum Style: String, CaseIterable {
    case pop, rock, funk, ballad, waltz, jazz, edm, acoustic
}

/// Melody rhythm vocabulary: how often each rhythm cell is drawn.
struct MelodyFeel {
    /// One-beat and two-beat cells, as note lengths in beats (negative = rest).
    static let oneBeatCells: [[Double]] = [[1], [0.5, 0.5], [-0.5, 0.5], [0.75, 0.25], [0.25, 0.25, 0.5], [0.5, -0.5]]
    static let twoBeatCells: [[Double]] = [[2], [1.5, 0.5], [0.5, 1, 0.5], [0.5, 1.5], [1, 1], [-1, 1], [1, 0.5, 0.5]]

    var twoBeatChance: Double
    var oneBeatWeights: [Double]
    var twoBeatWeights: [Double]
}

/// Everything that distinguishes one style at the arrangement level.
struct StyleProfile {
    var bpm: ClosedRange<Double>
    var meters: [Int]
    var minorChance: Double
    /// Where the off-beat eighth falls (0.5 straight, 0.67 triplet swing).
    var swing: ClosedRange<Double> = 0.5...0.5
    var bassPrograms: [Int]
    var chordPrograms: [Int]
    var melodyPrograms: [Int]
    /// Chance the song has drums at all.
    var drumChance: Double
    /// False for a light kit: no fills, soft cymbals, lower in the mix.
    var fullKit: Bool
    var introDrumChance: Double
    var majorProgressions: [String]
    var minorProgressions: [String]
    var bluesMajor: String? = nil
    var bluesMinor: String? = nil
    var bluesChance: Double = 0
    var twoChordsPerBarChance: Double
    var melodyFeel: MelodyFeel

    static func of(_ style: Style) -> StyleProfile {
        switch style {
        case .pop:
            StyleProfile(
                bpm: 90...125, meters: [4], minorChance: 0.35,
                bassPrograms: [33, 34], chordPrograms: [0, 4], melodyPrograms: [73, 65, 56, 80, 81, 40, 71, 53],
                drumChance: 1, fullKit: true, introDrumChance: 0.25,
                majorProgressions: ["I V vi IV", "vi IV I V", "I vi IV V", "I IV vi V", "IV I V vi"],
                minorProgressions: ["i bVI bIII bVII", "i bVII bVI bVII", "i iv bVI bVII", "i bIII bVII iv"],
                twoChordsPerBarChance: 0.2,
                melodyFeel: MelodyFeel(twoBeatChance: 0.5, oneBeatWeights: [2, 4, 1.5, 1.5, 0.3, 1], twoBeatWeights: [1.5, 2.5, 2, 1.5, 2, 1, 2]))
        case .rock:
            StyleProfile(
                bpm: 110...150, meters: [4], minorChance: 0.4,
                bassPrograms: [34], chordPrograms: [29, 30], melodyPrograms: [81, 80, 65, 56, 30, 29],
                drumChance: 1, fullKit: true, introDrumChance: 0.5,
                majorProgressions: ["I bVII IV I", "I IV V IV", "I V bVII IV", "I bIII IV I"],
                minorProgressions: ["i bVII bVI bVII", "i bIII bVII iv", "i bVI bIII bVII", "i iv bVII i"],
                bluesMajor: "I I I I IV IV I I V IV I V", bluesMinor: "i i i i iv iv i i bVI V i V", bluesChance: 0.3,
                twoChordsPerBarChance: 0.1,
                melodyFeel: MelodyFeel(twoBeatChance: 0.5, oneBeatWeights: [2, 4, 1.5, 1, 0.3, 1], twoBeatWeights: [2, 2, 2, 1.5, 2, 1, 2]))
        case .funk:
            StyleProfile(
                bpm: 95...115, meters: [4], minorChance: 0.55,
                bassPrograms: [36], chordPrograms: [7, 4], melodyPrograms: [65, 56, 66, 61],
                drumChance: 1, fullKit: true, introDrumChance: 0.5,
                majorProgressions: ["I7 IV7", "ii7 V7", "I7 I7 IV7 IV7", "I7 bVII7 IV7 I7"],
                minorProgressions: ["i7 IV7", "i7 iv7 i7 V7", "i7 bVII7 i7 IV7", "i7 i7 iv7 bVII7"],
                bluesMajor: "I7 I7 I7 I7 IV7 IV7 I7 I7 V7 IV7 I7 V7",
                bluesMinor: "i7 i7 i7 i7 iv7 iv7 i7 i7 bVI7 V7 i7 V7", bluesChance: 0.25,
                twoChordsPerBarChance: 0,
                melodyFeel: MelodyFeel(twoBeatChance: 0.4, oneBeatWeights: [1, 3, 2, 2, 1.5, 1.5], twoBeatWeights: [0.5, 2, 3, 2, 1, 1.5, 2]))
        case .ballad:
            StyleProfile(
                bpm: 60...80, meters: [4, 3], minorChance: 0.35,
                bassPrograms: [32, 33], chordPrograms: [0, 48], melodyPrograms: [73, 40, 53, 68],
                drumChance: 0.4, fullKit: false, introDrumChance: 0,
                majorProgressions: ["I V vi IV", "I vi IV V", "I iii IV V", "I IV vi V", "Imaj7 IVmaj7 vi7 V"],
                minorProgressions: ["i bVI bIII bVII", "i iv bVII bIII", "i bVI iv V", "i iv i V"],
                twoChordsPerBarChance: 0.15,
                melodyFeel: MelodyFeel(twoBeatChance: 0.6, oneBeatWeights: [3, 3, 1, 1, 0, 0.5], twoBeatWeights: [3, 3, 1, 1.5, 2, 1, 1]))
        case .waltz:
            StyleProfile(
                bpm: 120...170, meters: [3], minorChance: 0.3,
                bassPrograms: [32, 33], chordPrograms: [21, 0, 24], melodyPrograms: [40, 73, 71, 68, 21],
                drumChance: 0.5, fullKit: false, introDrumChance: 0,
                majorProgressions: ["I IV V7 I", "I vi ii V7", "I I IV V7", "I V7 V7 I", "I IV I V7"],
                minorProgressions: ["i iv V7 i", "i bVI iv V7", "i i iv V7", "i bVII bVI V7"],
                twoChordsPerBarChance: 0,
                melodyFeel: MelodyFeel(twoBeatChance: 0.5, oneBeatWeights: [3, 3, 1, 1.5, 0, 0.5], twoBeatWeights: [2, 3, 1, 1, 2, 0.5, 1.5]))
        case .jazz:
            StyleProfile(
                bpm: 110...160, meters: [4], minorChance: 0.3, swing: 0.6...0.67,
                bassPrograms: [32], chordPrograms: [0, 0, 4], melodyPrograms: [65, 66, 56],
                drumChance: 1, fullKit: true, introDrumChance: 0.4,
                majorProgressions: ["ii7 V7 Imaj7 vi7", "Imaj7 vi7 ii7 V7", "iii7 vi7 ii7 V7", "ii7 V7 Imaj7 Imaj7"],
                minorProgressions: ["iiø7 V7 i6 i6", "i7 iv7 iiø7 V7", "i7 bVImaj7 iiø7 V7", "i6 i6 iiø7 V7"],
                twoChordsPerBarChance: 0.35,
                melodyFeel: MelodyFeel(twoBeatChance: 0.4, oneBeatWeights: [1.5, 5, 2, 0.5, 0, 1], twoBeatWeights: [1, 2, 3, 2, 1, 1, 2.5]))
        case .edm:
            StyleProfile(
                bpm: 118...128, meters: [4], minorChance: 0.6,
                bassPrograms: [38, 39], chordPrograms: [89, 90, 91], melodyPrograms: [80, 81],
                drumChance: 1, fullKit: true, introDrumChance: 0.7,
                majorProgressions: ["vi IV I V", "I V vi IV", "IV I V vi", "I IV vi V"],
                minorProgressions: ["i bVI bIII bVII", "i bVII bVI bVII", "i iv bVI bVII", "bVI bVII i i"],
                twoChordsPerBarChance: 0,
                melodyFeel: MelodyFeel(twoBeatChance: 0.45, oneBeatWeights: [1.5, 4, 2, 1.5, 1, 1], twoBeatWeights: [1, 2, 2.5, 2, 1.5, 1, 2]))
        case .acoustic:
            StyleProfile(
                bpm: 80...110, meters: [4, 3], minorChance: 0.3,
                bassPrograms: [32, 33], chordPrograms: [24, 25], melodyPrograms: [73, 40, 53, 22],
                drumChance: 0.5, fullKit: false, introDrumChance: 0,
                majorProgressions: ["I V vi IV", "I IV vi V", "vi IV I V", "Isus2 IV I V", "I V IV I"],
                minorProgressions: ["i bVII bVI bVII", "i bIII bVII iv", "i iv bVI bVII"],
                twoChordsPerBarChance: 0.15,
                melodyFeel: MelodyFeel(twoBeatChance: 0.5, oneBeatWeights: [3, 3.5, 1, 1.5, 0.2, 0.5], twoBeatWeights: [2, 3, 1.5, 1.5, 2, 1, 1.5]))
        }
    }
}

// MARK: - Song list

/// What to generate: a named song of a style, fully determined by its seed.
struct SongSpec {
    var name: String
    var style: Style
    var seed: UInt64
    var tempoDrift: Bool
    var reverb: Bool
}

enum SongSet {
    static let defaultSeed: UInt64 = 2026
    static let defaultCountPerSplit = 8

    /// `countPerSplit` dev songs and as many test songs. Each split plays every style once
    /// per 8 songs (in shuffled order) and puts half its songs through reverb; about 3 in
    /// 16 songs drift in tempo. Dev and test use different seeds: same style mix, no
    /// shared material.
    static func standard(seed: UInt64 = defaultSeed, countPerSplit: Int = defaultCountPerSplit) -> [SongSpec] {
        var specs: [SongSpec] = []
        for split in ["dev", "test"] {
            var rng = SplitMix64(seed: SplitMix64.seed(seed, split))
            var styles: [Style] = []
            while styles.count < countPerSplit { styles += rng.shuffled(Style.allCases) }
            let reverb = rng.shuffled((0..<countPerSplit).map { $0 < (countPerSplit + 1) / 2 })
            for i in 0..<countPerSplit {
                specs.append(SongSpec(name: split + String(format: "%02d", i + 1), style: styles[i],
                                      seed: rng.next(), tempoDrift: false, reverb: reverb[i]))
            }
        }
        // Tempo drift on 3 of every 16 songs; never EDM, whose drum machines don't drift.
        var rng = SplitMix64(seed: SplitMix64.seed(seed, "drift"))
        let driftCount = max(1, Int((Double(specs.count) * 3 / 16).rounded()))
        for i in rng.shuffled(specs.indices.filter { specs[$0].style != .edm }).prefix(driftCount) {
            specs[i].tempoDrift = true
        }
        return specs
    }
}

// MARK: - Generated song

enum PartKind: String {
    case melody, chords, bass, drums

    /// Ground-truth role of a pitched part (drums have none).
    var role: PartRole? {
        switch self {
        case .melody: .melody
        case .chords: .chords
        case .bass: .bass
        case .drums: nil
        }
    }
}

struct PartSpec {
    var kind: PartKind
    /// General MIDI program; the drum kit is program 0 of the percussion bank.
    var program: Int
    /// Mix level in dB relative to the other parts, applied to RMS-matched stems.
    var levelDB: Double
}

/// One note as written (after humanizing), in seconds. Drum hits are notes on the drum
/// part whose pitch is the General MIDI percussion key.
struct NoteEvent {
    var part: Int
    var pitch: Int
    var on: Double
    var off: Double
    var velocity: Int
}

enum ReverbRoom: String {
    case smallRoom, mediumRoom, largeRoom
}

struct ReverbSpec {
    var room: ReverbRoom
    /// Percent wet (0-100).
    var wetDryMix: Double
}

/// A song ready to render: the parts, every note, and the grid-level ground truth.
struct GeneratedSong {
    var name: String
    var style: Style
    var bpm: Double
    var beatsPerBar: Int
    var key: Key
    var tempoDrift: Bool
    var reverb: ReverbSpec?
    var parts: [PartSpec]
    /// Sorted by onset.
    var notes: [NoteEvent]
    var beats: [Double]
    var downbeats: [Double]
    var chords: [TruthChord]
    /// Form summary for logs, e.g. "intro2 verse8 chorus8 ending1".
    var form: String
}

/// Limits shared by the generator and the renderer.
enum SongLimits {
    /// Allowed audio length, including the tail.
    static let duration: ClosedRange<Double> = 28...40
    /// Audio rendered after the last note-off.
    static let tail = 1.5
    /// Pitch ranges per role.
    static let bass = 28...55
    static let chords = 48...76
    static let melody = 60...88
    /// Minimum silence between consecutive melody notes in the ground truth.
    static let melodyGap = 0.010
}

extension GeneratedSong {
    static func generate(_ spec: SongSpec) -> GeneratedSong { SongBuilder(spec: spec).build() }
}

// MARK: - Timing

/// Gentle tempo drift: the tempo follows 1 + depth * sin(2π cycles x + phase) over the song.
struct TempoDrift {
    var depth: Double
    var cycles: Double
    var phase: Double

    func multiplier(at fraction: Double) -> Double { 1 + depth * sin(2 * .pi * cycles * fraction + phase) }
}

/// Maps beats (from the first downbeat) to seconds.
struct TempoMap {
    /// Time of every beat, plus one extra entry so the last beat has an end.
    let beatTimes: [Double]
    /// Where the off-beat eighth falls inside a beat: 0.5 straight, 2/3 triplet swing.
    let swing: Double

    init(start: Double, bpm: Double, beatCount: Int, swing: Double, drift: TempoDrift?) {
        var times = [start]
        for i in 0..<beatCount {
            let tempo = bpm * (drift?.multiplier(at: (Double(i) + 0.5) / Double(beatCount)) ?? 1)
            times.append(times[i] + 60 / tempo)
        }
        beatTimes = times
        self.swing = swing
    }

    func time(_ beat: Double) -> Double {
        let index = min(max(Int(beat.rounded(.down)), 0), beatTimes.count - 2)
        let fraction = beat - Double(index)
        // Swing moves the off-beat eighth later; outside the map, extrapolate linearly.
        let warped: Double
        if fraction < 0 || fraction > 1 {
            warped = fraction
        } else if fraction <= 0.5 {
            warped = fraction * swing / 0.5
        } else {
            warped = swing + (fraction - 0.5) * (1 - swing) / 0.5
        }
        return beatTimes[index] + warped * (beatTimes[index + 1] - beatTimes[index])
    }
}

// MARK: - Step patterns

/// One onset of a step pattern: position and length in beats, and its symbol.
struct PatternHit {
    var beat: Double
    var length: Double
    var symbol: Character
}

/// Parses a one-bar step pattern of space-separated tokens, all the same length: a
/// symbol starts a note, "-" holds the previous note, "." is a rest.
/// Example (bass, 8ths in 4/4): "R - R R 5 - 5 R".
func parsePattern(_ text: String, beatsPerBar: Int) -> [PatternHit] {
    let tokens = text.split(separator: " ")
    let step = Double(beatsPerBar) / Double(tokens.count)
    var hits: [PatternHit] = []
    var holding = false
    for (i, token) in tokens.enumerated() {
        switch token {
        case "-":
            if holding { hits[hits.count - 1].length += step }
        case ".":
            holding = false
        default:
            hits.append(PatternHit(beat: Double(i) * step, length: step, symbol: token.first!))
            holding = true
        }
    }
    return hits
}

/// A drum groove: one step pattern per GM key. Symbols: "X" accent, "x" normal,
/// "o" soft, "g" ghost.
struct DrumGroove {
    var lanes: [(key: Int, pattern: String)]

    static func velocity(_ symbol: Character) -> Int {
        switch symbol {
        case "X": 112
        case "x": 94
        case "o": 72
        default: 40
        }
    }

    func hits(beatsPerBar: Int) -> [DrumHit] {
        lanes.flatMap { lane in
            parsePattern(lane.pattern, beatsPerBar: beatsPerBar).map {
                DrumHit(beat: $0.beat, key: lane.key, velocity: DrumGroove.velocity($0.symbol))
            }
        }
    }
}

struct DrumHit {
    var beat: Double
    var key: Int
    var velocity: Int
}

// MARK: - Form

enum SectionKind: String {
    case intro, verse, chorus, ending
}

struct Section {
    var kind: SectionKind
    var bars: Int
    var progression: [Chord]
    var chordsPerBar: Int
}

struct Bar {
    var index: Int
    /// Index into the song's sections.
    var section: Int
    var kind: SectionKind
    var barInSection: Int
}

/// A stretch of one written chord, in beats.
struct ChordSpan {
    var start: Double
    var end: Double
    var chord: Chord
}

/// How the chord part plays each bar.
enum ChordTexture {
    /// Whole-voicing hits from a step pattern ("X - - X ..."), articulation range.
    case block(String, ClosedRange<Double>)
    /// Guitar power chords (root, fifth, octave) from a step pattern.
    case power(String, ClosedRange<Double>)
    /// Broken chord: voicing indices, one per `step` beats, ringing until the chord changes.
    case arpeggio([Int], step: Double)
    /// Guitar strums from a pattern of "D" (down: low to high) and "U" (up: top notes, high to low).
    case strum(String)
    /// Jazz comping: a new syncopated rhythm every bar.
    case comp
    /// One sustained, legato voicing per chord.
    case pad
}

/// Melody motif note: position and length in beats from the motif start, and the move
/// from the previous note in scale steps (for the first note: offset from the anchor).
struct MotifNote {
    var beat: Double
    var length: Double
    var step: Int
}

/// A phrase: a call motif and its answers. The answer repeats the call's opening and
/// ends on a long note (a cadence); primed letters (A', A'') reuse the call with a
/// freshly varied answer.
struct PhraseMaterial {
    var call: [MotifNote]
    var answers: [[MotifNote]]
    /// Semitones added to the section's anchor pitch (B phrases sit higher).
    var anchorShift: Int
}

// MARK: - Song builder

/// Writes one song. Create with a spec and call `build()` once.
final class SongBuilder {
    private let spec: SongSpec
    private let profile: StyleProfile
    private let beatsPerBar: Int
    private let bpm: Double
    private let key: Key
    private let swing: Double
    /// Form, instrument and mix choices. Each part writer gets its own fork.
    private var rng: SplitMix64

    private var sections: [Section] = []
    private var bars: [Bar] = []
    private var spans: [ChordSpan] = []
    private var tempo = TempoMap(start: 0, bpm: 120, beatCount: 1, swing: 0.5, drift: nil)
    private var parts: [PartSpec] = []
    private var notes: [NoteEvent] = []

    private var style: Style { spec.style }
    private var bpb: Double { Double(beatsPerBar) }
    private var barSeconds: Double { bpb * 60 / bpm }

    init(spec: SongSpec) {
        var rng = SplitMix64(seed: spec.seed)
        let profile = StyleProfile.of(spec.style)
        self.spec = spec
        self.profile = profile
        beatsPerBar = rng.pick(profile.meters)
        bpm = rng.uniform(profile.bpm).rounded()
        key = Key(tonic: rng.int(0...11), isMinor: rng.chance(profile.minorChance))
        swing = rng.uniform(profile.swing)
        self.rng = rng
    }

    func build() -> GeneratedSong {
        let start = rng.uniform(0.2...0.95)
        planForm(start: start)
        layOutBars()
        let drift = spec.tempoDrift
            ? TempoDrift(depth: rng.uniform(0.03...0.04), cycles: rng.uniform(0.5...1), phase: rng.uniform(0...(2 * .pi)))
            : nil
        tempo = TempoMap(start: start, bpm: bpm, beatCount: bars.count * beatsPerBar, swing: swing, drift: drift)

        // Instruments. A lead never doubles the chord instrument.
        let hasDrums = rng.chance(profile.drumChance)
        let bassProgram = rng.pick(profile.bassPrograms)
        let chordProgram = rng.pick(profile.chordPrograms)
        var melodyProgram = rng.pick(profile.melodyPrograms)
        if melodyProgram == chordProgram {
            melodyProgram = profile.melodyPrograms.first { $0 != chordProgram }!
        }

        // Mix: sensible defaults +-3 dB, with the melody kept at least 1 dB in front.
        var levels: [PartKind: Double] = [
            .drums: (profile.fullKit ? -5 : -10) + rng.uniform(-3...3),
            .bass: -3 + rng.uniform(-3...3),
            .chords: -5 + rng.uniform(-3...3),
            .melody: rng.uniform(-3...3),
        ]
        levels[.melody] = max(levels[.melody]!, levels[.bass]! + 1, levels[.chords]! + 1, levels[.drums]! + 1)

        var drumRNG = rng.fork(), bassRNG = rng.fork(), chordRNG = rng.fork(), melodyRNG = rng.fork()
        if hasDrums {
            parts.append(PartSpec(kind: .drums, program: 0, levelDB: levels[.drums]!))
            writeDrums(part: parts.count - 1, rng: &drumRNG)
        }
        parts.append(PartSpec(kind: .bass, program: bassProgram, levelDB: levels[.bass]!))
        writeBass(part: parts.count - 1, rng: &bassRNG)
        parts.append(PartSpec(kind: .chords, program: chordProgram, levelDB: levels[.chords]!))
        writeChords(part: parts.count - 1, program: chordProgram, rng: &chordRNG)
        parts.append(PartSpec(kind: .melody, program: melodyProgram, levelDB: levels[.melody]!))
        writeMelody(part: parts.count - 1, program: melodyProgram, rng: &melodyRNG)
        finalizeNotes()

        let reverb = spec.reverb
            ? ReverbSpec(room: rng.pick([.mediumRoom, .mediumRoom, .smallRoom, .largeRoom]), wetDryMix: rng.uniform(12...25).rounded())
            : nil
        let beatCount = bars.count * beatsPerBar
        let beats = Array(tempo.beatTimes.prefix(beatCount))
        return GeneratedSong(
            name: spec.name, style: style, bpm: bpm, beatsPerBar: beatsPerBar, key: key,
            tempoDrift: spec.tempoDrift, reverb: reverb, parts: parts, notes: notes,
            beats: beats, downbeats: stride(from: 0, to: beatCount, by: beatsPerBar).map { beats[$0] },
            chords: truthChords(),
            form: sections.map { "\($0.kind.rawValue)\($0.bars)" }.joined(separator: " "))
    }

    // MARK: Form

    /// Chooses progressions, harmonic rhythm and a form (intro, verses and choruses of 4,
    /// 8 or 12 bars, a one-bar ending) that puts the song inside `SongLimits.duration`.
    private func planForm(start: Double) {
        // Aim 1.2 s inside the limits: the last notes end a little before the final bar
        // line, and tempo drift (up to 4%) moves the end by up to about a second.
        let margin = 1.2
        let music = (SongLimits.duration.lowerBound + margin - start - SongLimits.tail)...(SongLimits.duration.upperBound - margin - start - SongLimits.tail)
        let progressions = key.isMinor ? profile.minorProgressions : profile.majorProgressions
        let blues = key.isMinor ? profile.bluesMinor : profile.bluesMajor

        for attempt in 0..<40 {
            let useBlues = blues != nil && attempt < 20 && rng.chance(profile.bluesChance)
            let verseText = useBlues ? blues! : rng.pick(progressions)
            let chorusText = !useBlues && rng.chance(0.35) ? verseText : rng.pick(progressions.filter { $0 != verseText })
            let verse = key.progression(verseText)
            let chorus = key.progression(chorusText)
            let verseCPB = chordsPerBar(verse, blues: useBlues)
            let chorusCPB = chordsPerBar(chorus, blues: false)

            func lengths(_ progression: [Chord], _ perBar: Int) -> [Int] {
                let cycle = progression.count / perBar
                return cycle == 12 ? [12] : [4, 8].filter { $0 % cycle == 0 }
            }
            let verseLengths = lengths(verse, verseCPB)
            let chorusLengths = lengths(chorus, chorusCPB)
            let forms: [[SectionKind]] = verseLengths == [12]
                ? [[.verse], [.verse, .chorus]]
                : [[.verse, .chorus], [.verse, .chorus, .chorus], [.verse, .verse, .chorus],
                   [.verse, .chorus, .verse, .chorus], [.verse, .chorus, .verse, .chorus, .chorus]]
            let introWeights: [(Int, Double)] = [(0, 0.3), (1, 0.2), (2, 0.5)]

            var candidates: [([Section], Double)] = []
            for (intro, _) in introWeights {
                for form in forms {
                    for verseBars in verseLengths {
                        for chorusBars in chorusLengths {
                            var plan: [Section] = []
                            if intro > 0 {
                                plan.append(Section(kind: .intro, bars: intro, progression: verse, chordsPerBar: verseCPB))
                            }
                            for kind in form {
                                plan.append(kind == .verse
                                    ? Section(kind: .verse, bars: verseBars, progression: verse, chordsPerBar: verseCPB)
                                    : Section(kind: .chorus, bars: chorusBars, progression: chorus, chordsPerBar: chorusCPB))
                            }
                            plan.append(Section(kind: .ending, bars: 1, progression: [endingChord], chordsPerBar: 1))
                            let seconds = Double(plan.reduce(0) { $0 + $1.bars }) * barSeconds
                            guard music.contains(seconds) else { continue }
                            // Favour balanced forms (verse as long as chorus) with more sections;
                            // a chorus shorter than its verse is a last resort.
                            let balance = !form.contains(.chorus) || verseBars == chorusBars ? 4.0
                                : chorusBars > verseBars || verseBars == 12 ? 1.5 : 0.2
                            candidates.append((plan, balance * Double(form.count)))
                        }
                    }
                }
            }
            if !candidates.isEmpty {
                // Use the drawn intro length when some form fits with it, else any fit.
                let intro = rng.weighted(introWeights)
                let withIntro = candidates.filter { ($0.0.first?.kind == .intro ? $0.0[0].bars : 0) == intro }
                sections = rng.weighted(withIntro.isEmpty ? candidates : withIntro)
                return
            }
        }
        preconditionFailure("\(spec.name): no form fits \(bpm) BPM")
    }

    private func chordsPerBar(_ progression: [Chord], blues: Bool) -> Int {
        guard beatsPerBar == 4, !blues, progression.count % 2 == 0,
              rng.chance(profile.twoChordsPerBarChance) else { return 1 }
        return 2
    }

    /// The final chord: the tonic, with the style's usual colour.
    private var endingChord: Chord {
        switch style {
        case .jazz: Chord(root: key.tonic, quality: key.isMinor ? .min6 : .maj7)
        case .funk: Chord(root: key.tonic, quality: key.isMinor ? .min7 : .dom7)
        default: Chord(root: key.tonic, quality: key.isMinor ? .min : .maj)
        }
    }

    private func layOutBars() {
        for (s, section) in sections.enumerated() {
            let spanBeats = beatsPerBar / section.chordsPerBar
            for b in 0..<section.bars {
                let index = bars.count
                bars.append(Bar(index: index, section: s, kind: section.kind, barInSection: b))
                for c in 0..<section.chordsPerBar {
                    let chord = section.progression[(b * section.chordsPerBar + c) % section.progression.count]
                    let start = Double(index * beatsPerBar + c * spanBeats)
                    spans.append(ChordSpan(start: start, end: start + Double(spanBeats), chord: chord))
                }
            }
        }
    }

    private func spanIndex(at beat: Double) -> Int {
        var lo = 0, hi = spans.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if spans[mid].start <= beat + 1e-9 { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    private func chord(at beat: Double) -> Chord { spans[spanIndex(at: beat)].chord }

    private func isLastBarOfSection(_ bar: Bar) -> Bool {
        bar.barInSection == sections[bar.section].bars - 1
    }

    private func nextSection(after bar: Bar) -> SectionKind? {
        bar.section + 1 < sections.count ? sections[bar.section + 1].kind : nil
    }

    /// Splits hits (bar-relative) at chord changes so nothing rings into the next chord;
    /// the piece after a change is re-struck with `restrike`. Returns absolute beats.
    private func splitAtChordChanges(_ hits: [PatternHit], bar: Bar, restrike: Character) -> [PatternHit] {
        var result: [PatternHit] = []
        let barStart = Double(bar.index) * bpb
        for hit in hits {
            var beat = barStart + hit.beat
            let end = beat + hit.length
            var symbol = hit.symbol
            while true {
                let spanEnd = spans[spanIndex(at: beat)].end
                if spanEnd >= end - 1e-9 { break }
                result.append(PatternHit(beat: beat, length: spanEnd - beat, symbol: symbol))
                beat = spanEnd
                symbol = restrike
            }
            result.append(PatternHit(beat: beat, length: end - beat, symbol: symbol))
        }
        return result
    }

    // MARK: Notes

    /// Adds a note written at `beat` for `length` beats. It sounds for `articulation` of
    /// the written length and starts `offset` seconds off the grid (humanizing, strums).
    private func addNote(part: Int, pitch: Int, beat: Double, length: Double, articulation: Double,
                         velocity: Int, offset: Double) {
        let start = tempo.time(beat)
        let written = tempo.time(beat + length) - start
        let on = max(0, start + offset)
        notes.append(NoteEvent(part: part, pitch: pitch, on: on, off: on + written * articulation,
                               velocity: min(127, max(1, velocity))))
    }

    /// Makes the notes playable and the truth exact: a re-struck key ends the earlier
    /// note just before, the melody keeps a clear gap between notes, and nothing is
    /// shorter than 25 ms.
    private func finalizeNotes() {
        let melodyPart = parts.firstIndex { $0.kind == .melody }
        var byKey: [Int: [Int]] = [:]
        for (i, note) in notes.enumerated() { byKey[note.part * 128 + note.pitch, default: []].append(i) }
        for (_, indices) in byKey {
            let sorted = indices.sorted { notes[$0].on < notes[$1].on }
            for (a, b) in zip(sorted, sorted.dropFirst()) {
                notes[a].off = min(notes[a].off, notes[b].on - 0.005)
            }
        }
        if let melodyPart {
            let melody = notes.indices.filter { notes[$0].part == melodyPart }.sorted { notes[$0].on < notes[$1].on }
            for (a, b) in zip(melody, melody.dropFirst()) {
                notes[a].off = min(notes[a].off, notes[b].on - 0.015)
            }
        }
        notes.removeAll { $0.off - $0.on < 0.025 }
        notes.sort { ($0.on, $0.part, $0.pitch) < ($1.on, $1.part, $1.pitch) }
    }

    /// Chord spans in seconds, with repeats of the same chord merged.
    private func truthChords() -> [TruthChord] {
        var merged: [ChordSpan] = []
        for span in spans {
            if let last = merged.last, last.chord == span.chord, abs(last.end - span.start) < 1e-9 {
                merged[merged.count - 1].end = span.end
            } else {
                merged.append(span)
            }
        }
        return merged.map {
            TruthChord(start: tempo.time($0.start), end: tempo.time($0.end), root: $0.chord.root,
                       quality: $0.chord.quality.rawValue, label: $0.chord.label(sharps: key.usesSharps))
        }
    }

    // MARK: Drums

    private func drumGrooves(_ r: inout SplitMix64) -> (verse: DrumGroove, chorus: DrumGroove) {
        let backbeat = ". . . . X . . . . . . . X . . ."
        switch style {
        case .pop:
            let kicks = r.shuffled(["x . . . . . . . x . x . . . . .", "x . . . . . x . x . . . . . . .",
                                    "x . . . . . . x x . . . . . . .", "x . . . . . . . x . . . . . x ."])
            let hats = "x . o . x . o . x . o . x . o ."
            let chorusCymbals: [(key: Int, pattern: String)] = r.chance(0.5)
                ? [(51, hats)]
                : [(42, "x . o . x . o . x . o . x . . ."), (46, ". . . . . . . . . . . . . . o .")]
            return (DrumGroove(lanes: [(36, kicks[0]), (38, backbeat), (42, hats)]),
                    DrumGroove(lanes: [(36, kicks[1]), (38, backbeat)] + chorusCymbals))
        case .rock:
            let kicks = r.shuffled(["x . . . . . . . x . x . . . . .", "x . . . . . . x x . x . . . . .",
                                    "x . x . . . . . x . x . . . . ."])
            let eighths = "x . x . x . x . x . x . x . x ."
            return (DrumGroove(lanes: [(36, kicks[0]), (38, backbeat), (r.chance(0.7) ? 42 : 51, eighths)]),
                    DrumGroove(lanes: [(36, kicks[1]), (38, backbeat), (51, eighths)]))
        case .funk:
            let kicks = r.shuffled(["x . . x . . x . . . x . . . . .", "x . . . . . . x . . x . . x . .",
                                    "x . x . . . . . . . x . . . . x", "x . . x . . . . . . x . . x . ."])
            let snare = ". . . . X . . g . g . . X . . g"
            return (DrumGroove(lanes: [(36, kicks[0]), (38, snare), (42, "x o x o x o x o x o x o x o . o"),
                                       (46, ". . . . . . . . . . . . . . x .")]),
                    DrumGroove(lanes: [(36, kicks[1]), (38, snare), (42, "x o x o x o . o x o x o x o . o"),
                                       (46, ". . . . . . x . . . . . . . x .")]))
        case .jazz:
            // Light kick: feathered quarters, or a soft "one" and a push on the and of three.
            let kick: (key: Int, pattern: String) = (36, r.chance(0.5) ? "g . g . g . g ." : "g . . . . g . .")
            return (DrumGroove(lanes: [(51, "x . x o x . x o"), (44, ". . x . . . x ."), kick]),
                    DrumGroove(lanes: [(51, "X . x o X . x o"), (44, ". . x . . . x ."), kick]))
        case .edm:
            let clap = r.chance(0.6) ? 39 : 38
            let verse: [(key: Int, pattern: String)] = [
                (36, "X . . . X . . . X . . . X . . ."), (clap, ". . . . x . . . . . . . x . . ."),
                (46, ". . x . . . x . . . x . . . x ."),
            ]
            return (DrumGroove(lanes: verse), DrumGroove(lanes: verse + [(42, "o o . o o o . o o o . o o o . o")]))
        case .ballad:
            let groove = beatsPerBar == 4
                ? DrumGroove(lanes: [(36, "o . . . . . . ."), (37, ". . o . . . o ."), (42, "g . g . g . g .")])
                : DrumGroove(lanes: [(36, "o . . . . ."), (37, ". . o . o ."), (42, "g . g . g .")])
            return (groove, groove)
        case .waltz:
            let verse: [(key: Int, pattern: String)] = [(36, "x . . . . ."), (42, ". . o . o .")]
            return (DrumGroove(lanes: verse), DrumGroove(lanes: verse + [(38, ". . g . g .")]))
        case .acoustic:
            if beatsPerBar == 4 {
                return (DrumGroove(lanes: [(36, "o . . . o . . ."), (38, ". . o . . . o ."), (42, "g g g g g g g g")]),
                        DrumGroove(lanes: [(36, "o . . . o . . ."), (38, ". . o . . . o ."), (42, "o g o g o g o g")]))
            }
            return (DrumGroove(lanes: [(36, "o . . . . ."), (38, ". . o . o ."), (42, "g g g g g g")]),
                    DrumGroove(lanes: [(36, "o . . . . ."), (38, ". . o . o ."), (42, "o g o g o g")]))
        }
    }

    private func writeDrums(part: Int, rng r: inout SplitMix64) {
        let grooves = drumGrooves(&r)
        let introDrums = r.chance(profile.introDrumChance)
        let jitter = r.uniform(0.001...0.003)
        let cymbals: Set<Int> = [42, 44, 46, 51]
        let tomFills = [[50, 50, 48, 48, 45, 45, 43, 43], [38, 38, 50, 48, 47, 45, 43, 41], [48, 48, 47, 47, 45, 45, 41, 41],
                        [50, 48, 45, 43], [38, 48, 45, 41]]

        for bar in bars {
            var hits: [DrumHit]
            switch bar.kind {
            case .intro: hits = introDrums ? grooves.verse.hits(beatsPerBar: beatsPerBar) : []
            case .verse: hits = style == .ballad ? [] : grooves.verse.hits(beatsPerBar: beatsPerBar)
            case .chorus: hits = grooves.chorus.hits(beatsPerBar: beatsPerBar)
            case .ending: hits = [DrumHit(beat: 0, key: 36, velocity: profile.fullKit ? 100 : 72)]
            }
            if hits.isEmpty { continue }

            // Crash on the first beat of each verse, chorus and the ending.
            if bar.barInSection == 0 && bar.kind != .intro {
                hits.removeAll { $0.beat == 0 && cymbals.contains($0.key) }
                hits.append(DrumHit(beat: 0, key: 49, velocity: profile.fullKit ? 110 : 72))
                if !hits.contains(where: { $0.beat == 0 && $0.key == 36 }) {
                    hits.append(DrumHit(beat: 0, key: 36, velocity: profile.fullKit ? 100 : 72))
                }
            }

            // A one-bar fill into the chorus (sometimes into verse 2).
            let next = nextSection(after: bar)
            if profile.fullKit && style != .jazz && isLastBarOfSection(bar) && bar.kind != .ending
                && (next == .chorus && r.chance(0.7) || next == .verse && r.chance(0.3)) {
                if style == .edm {
                    // Build-up: a 16th snare roll getting louder over the whole bar.
                    hits.removeAll { $0.key == 38 || $0.key == 39 }
                    let steps = beatsPerBar * 4
                    for k in 0..<steps {
                        hits.append(DrumHit(beat: Double(k) * 0.25, key: 38, velocity: 45 + 70 * k / (steps - 1)))
                    }
                } else {
                    let fill = r.pick(tomFills)
                    let fillStart = bpb - 2
                    let step = 2 / Double(fill.count)
                    hits.removeAll { $0.beat >= fillStart }
                    for (k, tom) in fill.enumerated() {
                        hits.append(DrumHit(beat: fillStart + Double(k) * step, key: tom, velocity: 88 + 20 * k / fill.count))
                    }
                }
            }

            // Jazz: the snare drops a soft comping note or two.
            if style == .jazz && bar.kind != .ending && r.chance(0.5) {
                for _ in 0..<r.int(1...2) {
                    hits.append(DrumHit(beat: Double(r.int(0...(beatsPerBar - 1))) + 0.5, key: 38, velocity: 40))
                }
            }

            var seen = Set<Int>()
            for hit in hits {
                let slot = Int(hit.beat * 48) * 128 + hit.key
                guard seen.insert(slot).inserted else { continue }
                let spread = hit.velocity <= 40 ? 6 : 12
                let beat = Double(bar.index) * bpb + hit.beat
                addNote(part: part, pitch: hit.key, beat: beat, length: 0, articulation: 1,
                        velocity: hit.velocity + r.int(-spread...spread), offset: r.jitter(jitter))
                // Drum samples are one-shots; the note-off only tidies up the sampler.
                notes[notes.count - 1].off = notes[notes.count - 1].on + 0.3
            }
        }
    }

    // MARK: Bass

    /// Bass step patterns per style ("R" root, "5" fifth, "8" octave, "3" third, "7" seventh).
    private var bassPatterns: [String] {
        switch (style, beatsPerBar) {
        case (.pop, _): ["R R R R R R R R", "R R R R 5 5 5 5", "R - R R 5 - 5 R", "R - - R 5 - R -", "R R 5 R 8 R 5 R"]
        case (.rock, _): ["R R R R R R R R", "R R R R R R 5 8", "R R R R 5 5 5 5"]
        case (.funk, _): ["R - . 8 . . R . R - . 5 7 . 8 .", "R . . R . . 8 . . R . 7 . 5 8 .",
                          "R - . . . R . 8 R - . 7 . 5 . 8", "R . 8 . . R . . R . . 5 . 7 8 ."]
        case (.ballad, 4): ["R - - -", "R - 5 -", "R - - 5"]
        case (.ballad, _): ["R - -", "R - 5"]
        case (.waltz, _): ["R . ."]
        case (.edm, _): [". R . R . R . R", "R R R R R R R R", ". R . R . R 8 R", "R . R R . R R ."]
        case (.acoustic, 4): ["R - 5 -", "R - - 5", "R 5 R 5"]
        case (.acoustic, _): ["R - 5", "R 5 5"]
        case (.jazz, _): []
        }
    }

    private func writeBass(part: Int, rng r: inout SplitMix64) {
        let patterns = bassPatterns
        let versePattern = patterns.isEmpty ? "" : r.pick(patterns)
        let chorusPattern = patterns.isEmpty ? "" : r.pick(patterns)
        let introBass = r.chance(style == .funk || style == .edm ? 0.5 : 0.2)
        let jitter = r.uniform(0.002...0.006)
        let articulation: ClosedRange<Double> = switch style {
        case .funk: 0.45...0.65
        case .rock, .edm, .waltz: 0.6...0.8
        case .ballad, .acoustic, .jazz: 0.85...0.95
        default: 0.7...0.9
        }
        let baseVelocity = style == .funk ? 96 : 88

        // One root per chord span, each near the last, so the line stays in one register.
        var roots: [Int] = []
        var last = r.int(33...40)
        for span in spans {
            last = fold(nearestPitch(pc: span.chord.root, to: last), into: 28...43)
            roots.append(last)
        }

        func pitch(_ symbol: Character, span: Int) -> Int {
            let root = roots[span]
            let chord = spans[span].chord
            let interval = switch symbol {
            case "5": chord.fifthInterval
            case "8": 12
            case "3": chord.thirdInterval
            case "7": chord.seventhInterval ?? 10
            default: 0
            }
            return fold(root + interval, into: SongLimits.bass)
        }

        for bar in bars {
            let barStart = Double(bar.index) * bpb
            if bar.kind == .intro && !introBass { continue }
            if bar.kind == .ending {
                addNote(part: part, pitch: roots[spanIndex(at: barStart)], beat: barStart, length: bpb,
                        articulation: 0.95, velocity: baseVelocity, offset: r.jitter(jitter))
                continue
            }
            if style == .jazz {
                writeWalkingBar(part: part, bar: bar, roots: roots, jitter: jitter, rng: &r)
                continue
            }
            var pattern = bar.kind == .chorus ? chorusPattern : versePattern
            // Waltz: root, then the fifth when the chord carries over into the next bar.
            if style == .waltz, bar.index > 0, chord(at: barStart) == chord(at: barStart - 1) {
                pattern = "5 . ."
            }
            for hit in splitAtChordChanges(parsePattern(pattern, beatsPerBar: beatsPerBar), bar: bar, restrike: "R") {
                let span = spanIndex(at: hit.beat)
                let downbeat = hit.beat == barStart
                addNote(part: part, pitch: pitch(hit.symbol, span: span), beat: hit.beat, length: hit.length,
                        articulation: r.uniform(articulation),
                        velocity: baseVelocity + (downbeat ? 6 : 0) + r.int(-12...12), offset: r.jitter(jitter))
            }
        }
    }

    /// Walking bass: quarter notes through chord tones and scale steps, with the last
    /// beat of each chord approaching the next root (chromatically, by step or from its fifth).
    private func writeWalkingBar(part: Int, bar: Bar, roots: [Int], jitter: Double, rng r: inout SplitMix64) {
        let barStart = Double(bar.index) * bpb
        var span = spanIndex(at: barStart)
        while span < spans.count && spans[span].start < barStart + bpb - 1e-9 {
            let chord = spans[span].chord
            let beats = Int(spans[span].end - spans[span].start)
            let root = roots[span]
            let next = span + 1 < spans.count ? roots[span + 1] : root
            var line = [root]
            if beats >= 3 {
                let scale = key.scale(over: chord)
                let up = next > root || (next == root && r.chance(0.5))
                let middle: [Int] = switch r.int(0...2) {
                case 0: up ? [root + chord.thirdInterval, root + chord.fifthInterval, root + (chord.seventhInterval ?? 12)]
                           : [root + chord.fifthInterval - 12, root + chord.thirdInterval - 12, root - 12]
                case 1: (1...3).map { moveInScale(root, steps: up ? $0 : -$0, scale: scale) }
                default: [root + chord.fifthInterval, moveInScale(root + chord.fifthInterval, steps: up ? 1 : -1, scale: scale), root + 12]
                }
                line += middle.prefix(beats - 2)
            }
            if beats >= 2 {
                let previous = line.last!
                let approach: Int = switch r.weighted([(0, 0.55), (1, 0.25), (2, 0.2)]) {
                case 0: previous < next ? next - 1 : next + 1
                case 1: moveInScale(next, steps: previous < next ? -1 : 1, scale: key.scale(over: chord))
                default: next + 7 <= SongLimits.bass.upperBound ? next + 7 : next - 5
                }
                line.append(approach)
            }
            for (k, pitch) in line.enumerated() {
                addNote(part: part, pitch: fold(pitch, into: SongLimits.bass), beat: spans[span].start + Double(k),
                        length: 1, articulation: r.uniform(0.85...0.95),
                        velocity: 84 + (k == 0 ? 6 : 0) + r.int(-12...12), offset: r.jitter(jitter))
            }
            span += 1
        }
    }

    // MARK: Chords

    /// Close and drop-2 voicings of `chord` with `count` notes inside `range`. Triads
    /// played with four notes double the root; seventh chords played with three drop the fifth.
    private func candidateVoicings(_ chord: Chord, count: Int, range: ClosedRange<Int>) -> [[Int]] {
        var tones = chord.tones
        if count == 3 && tones.count == 4 { tones.remove(at: 2) }
        var result: [[Int]] = []
        for rotation in 0..<tones.count {
            let order = Array(tones[rotation...] + tones[..<rotation])
            for bottom in range where mod12(bottom) == order[0] {
                var voicing = [bottom]
                for pc in order.dropFirst() { voicing.append(voicing.last! + mod12(pc - voicing.last!)) }
                if count == 4 && tones.count == 3 {
                    voicing.append(voicing.last! + mod12(chord.root - voicing.last!) + (mod12(chord.root - voicing.last!) == 0 ? 12 : 0))
                }
                guard voicing.last! <= range.upperBound else { continue }
                result.append(voicing)
                if voicing.count == 4 {
                    var drop2 = voicing
                    drop2[2] -= 12
                    drop2.sort()
                    if drop2[0] >= range.lowerBound { result.append(drop2) }
                }
            }
        }
        return result
    }

    /// The voicing that moves least from `previous` while staying near `center`.
    private func voiceLead(_ chord: Chord, count: Int, center: Double, previous: [Int]?, rng r: inout SplitMix64) -> [Int] {
        var best: [Int] = []
        var bestCost = Double.infinity
        for voicing in candidateVoicings(chord, count: count, range: SongLimits.chords) {
            let mean = Double(voicing.reduce(0, +)) / Double(voicing.count)
            var cost = abs(mean - center) * 0.35 + r.unit() * 0.8
            if let previous {
                if previous.count == voicing.count {
                    cost += Double(zip(previous, voicing).reduce(0) { $0 + abs($1.0 - $1.1) })
                } else {
                    cost += abs(mean - Double(previous.reduce(0, +)) / Double(previous.count)) * Double(voicing.count)
                }
            } else {
                cost += abs(mean - center) * 2
            }
            if cost < bestCost { best = voicing; bestCost = cost }
        }
        return best
    }

    private func chordTextures(_ r: inout SplitMix64, program: Int) -> (verse: ChordTexture, chorus: ChordTexture) {
        let four = beatsPerBar == 4
        switch style {
        case .pop:
            let verse: ChordTexture = r.pick([
                .arpeggio([0, 1, 2, 3, 1, 2, 3, 2], step: 0.5), .block("X - - - X - - -", 0.8...0.95),
                .block("X - - X - - X -", 0.7...0.9),
            ])
            let chorus: ChordTexture = r.pick([.block("X - X - X - X -", 0.7...0.9), .block("X - - X - - X -", 0.75...0.92),
                                               .block("X - - - X - X -", 0.75...0.92)])
            return (verse, chorus)
        case .rock:
            return (.power("X X X X X X X X", 0.55...0.7),
                    r.pick([.power("X - - X - - X -", 0.88...0.96), .power("X - - - X - - -", 0.9...0.97)]))
        case .funk:
            let stabs = r.shuffled([". . X . . . X . . . X . . X . .", ". . X . . X . . . . X . . . X .",
                                    ". X . X . . X . . X . X . . X .", ". . X . X . . . . . X . X . . ."])
            return (.block(stabs[0], 0.35...0.55), .block(stabs[1], 0.35...0.55))
        case .ballad:
            if program == 48 { return (.pad, .pad) }
            let arp = four ? [0, 1, 2, 3, 2, 3, 1, 2] : [0, 1, 2, 3, 2, 1]
            return (.arpeggio(arp, step: 0.5), r.chance(0.5) ? .arpeggio(arp, step: 0.5) : .block(four ? "X - - - X - - -" : "X - -", 0.9...0.97))
        case .waltz:
            return (.block(". X X", 0.55...0.75), .block(". X X", 0.55...0.75))
        case .jazz:
            return (.comp, .comp)
        case .edm:
            return (.pad, .pad)
        case .acoustic:
            if r.chance(0.4) {
                let pick = four ? [0, 2, 1, 3, 0, 2, 1, 3] : [0, 2, 3, 1, 3, 2]
                return (.arpeggio(pick, step: 0.5), .arpeggio(pick, step: 0.5))
            }
            let strums = four ? ["D - D U - U D U", "D - D - D U D U", "D - - U - U D U"] : ["D - D U D U", "D - D - D U"]
            return (.strum(r.pick(strums)), .strum(r.pick(strums)))
        }
    }

    private func writeChords(part: Int, program: Int, rng r: inout SplitMix64) {
        let textures = chordTextures(&r, program: program)
        let jitter = r.uniform(0.002...0.008)
        let (count, center, baseVelocity): (Int, Double, Int) = switch style {
        case .pop: (r.pick([3, 4]), 62, 72)
        case .rock: (3, 55, 88)
        case .funk: (3, 66, 84)
        case .ballad: (4, 62, 66)
        case .waltz: (3, 64, 64)
        case .jazz: (4, 62, 62)
        case .edm: (4, 62, 78)
        case .acoustic: (4, 60, 74)
        }

        // One voicing per chord span, each voice-led from the one before.
        var voicings: [[Int]] = []
        var powerRoot = r.int(50...55)
        for span in spans {
            if style == .rock {
                powerRoot = fold(nearestPitch(pc: span.chord.root, to: powerRoot), into: 48...57)
                voicings.append([powerRoot, powerRoot + 7, powerRoot + 12])
            } else {
                voicings.append(voiceLead(span.chord, count: count, center: center, previous: voicings.last, rng: &r))
            }
        }

        func block(_ hit: PatternHit, articulation: Double, velocity: Int) {
            let voicing = voicings[spanIndex(at: hit.beat)]
            let offset = r.jitter(jitter)
            for pitch in voicing {
                addNote(part: part, pitch: pitch, beat: hit.beat, length: hit.length, articulation: articulation,
                        velocity: velocity + r.int(-3...3), offset: offset + r.jitter(0.002))
            }
        }

        let compRhythms = ["X - - . . . . .", "X - . X - . . .", ". . . X - . . .", ". . X - . . X .",
                           ". X - . . . X .", "X - . . . X - .", "X - . . X - . ."]

        for bar in bars {
            let barStart = Double(bar.index) * bpb
            if bar.kind == .ending {
                let hit = PatternHit(beat: barStart, length: bpb, symbol: "X")
                if case .strum = textures.verse {
                    strum(part: part, hit: hit, voicing: voicings[spanIndex(at: barStart)], down: true,
                          velocity: baseVelocity, jitter: jitter, rng: &r)
                } else {
                    block(hit, articulation: 0.95, velocity: baseVelocity)
                }
                continue
            }
            let texture = bar.kind == .chorus ? textures.chorus : textures.verse
            let chorusLift = bar.kind == .chorus ? 6 : 0
            switch texture {
            case .block(let pattern, let articulation), .power(let pattern, let articulation):
                for hit in splitAtChordChanges(parsePattern(pattern, beatsPerBar: beatsPerBar), bar: bar, restrike: "X") {
                    let accent = hit.beat == barStart ? 6 : 0
                    block(hit, articulation: r.uniform(articulation), velocity: baseVelocity + chorusLift + accent + r.int(-12...12))
                }
            case .comp:
                for hit in splitAtChordChanges(parsePattern(r.pick(compRhythms), beatsPerBar: beatsPerBar), bar: bar, restrike: "X") {
                    block(hit, articulation: r.uniform(0.55...0.85), velocity: baseVelocity + chorusLift + r.int(-12...12))
                }
            case .pad:
                for hit in splitAtChordChanges([PatternHit(beat: 0, length: bpb, symbol: "X")], bar: bar, restrike: "X") {
                    block(hit, articulation: 1, velocity: baseVelocity + chorusLift + r.int(-12...12))
                }
            case .arpeggio(let indices, let step):
                for k in 0..<Int(bpb / step) {
                    let beat = barStart + Double(k) * step
                    let span = spanIndex(at: beat)
                    let voicing = voicings[span]
                    addNote(part: part, pitch: voicing[indices[k % indices.count] % voicing.count], beat: beat,
                            length: spans[span].end - beat, articulation: 0.97,
                            velocity: baseVelocity + chorusLift + (k == 0 ? 8 : 0) + r.int(-12...12), offset: r.jitter(jitter))
                }
            case .strum(let pattern):
                for hit in splitAtChordChanges(parsePattern(pattern, beatsPerBar: beatsPerBar), bar: bar, restrike: "D") {
                    strum(part: part, hit: hit, voicing: voicings[spanIndex(at: hit.beat)], down: hit.symbol == "D",
                          velocity: baseVelocity + chorusLift + r.int(-12...12), jitter: jitter, rng: &r)
                }
            }
        }
    }

    /// A guitar strum: the notes spread 8-25 ms, low to high on a down-strum; an up-strum
    /// catches only the top three strings, high to low, and softer.
    private func strum(part: Int, hit: PatternHit, voicing: [Int], down: Bool, velocity: Int, jitter: Double,
                       rng r: inout SplitMix64) {
        let strings = down ? voicing : Array(voicing.reversed().prefix(3))
        let spread = r.uniform(0.008...0.025)
        let offset = r.jitter(jitter)
        for (k, pitch) in strings.enumerated() {
            addNote(part: part, pitch: pitch, beat: hit.beat, length: hit.length, articulation: 0.95,
                    velocity: velocity - (down ? 0 : 14) + r.int(-4...4),
                    offset: offset + spread * Double(k) / Double(strings.count - 1))
        }
    }

    // MARK: Melody

    /// Comfortable centre of each lead instrument (MIDI).
    private func melodyCenter(_ program: Int) -> Int {
        switch program {
        case 73: 75  // flute
        case 40: 73  // violin
        case 68: 72  // oboe
        case 53: 68  // voice oohs
        case 71: 70  // clarinet
        case 65: 69  // alto sax
        case 66: 66  // tenor sax
        case 56: 71  // trumpet
        case 61: 69  // brass section
        case 22: 71  // harmonica
        case 21: 71  // accordion
        case 29, 30: 70  // lead guitar
        default: 72  // synth leads
        }
    }

    /// Fills one bar of motif rhythm from the style's cells.
    private func rhythmBar(at offset: Double, feel: MelodyFeel, rng r: inout SplitMix64) -> [MotifNote] {
        var notes: [MotifNote] = []
        var beat = 0.0
        var restPending = false
        while beat < bpb - 1e-9 {
            var cell: [Double]
            repeat {
                if bpb - beat >= 2 && r.chance(feel.twoBeatChance) {
                    cell = r.weighted(Array(zip(MelodyFeel.twoBeatCells, feel.twoBeatWeights)))
                } else {
                    cell = r.weighted(Array(zip(MelodyFeel.oneBeatCells, feel.oneBeatWeights)))
                }
            } while restPending && cell[0] < 0   // no two rests in a row
            for length in cell {
                if length > 0 { notes.append(MotifNote(beat: offset + beat, length: length, step: 0)) }
                beat += abs(length)
            }
            restPending = cell.last! < 0
        }
        return notes
    }

    /// Scale steps for a melodic contour: mostly steps and thirds along an arch, a descent,
    /// an ascent or a wave; a leap is followed by a step back, the line stays within four
    /// scale steps of where it started and heads back toward it at the end, so the next
    /// motif (which starts near the same place) joins on without a jump.
    private func contour(_ count: Int, rng r: inout SplitMix64) -> [Int] {
        let shape = r.int(0...3)
        var steps = [r.int(-2...2)]
        var position = 0
        var lastLeap = 0
        for i in 1..<max(count, 1) {
            let x = Double(i) / Double(max(count - 1, 1))
            var preferred: Int = switch shape {
            case 0: x < 0.55 ? 1 : -1
            case 1: -1
            case 2: 1
            default: sin(3 * .pi * x) >= 0 ? 1 : -1
            }
            if i >= count - 2 && abs(position) >= 2 { preferred = position > 0 ? -1 : 1 }
            var step: Int
            if lastLeap != 0 {
                step = lastLeap > 0 ? -1 : 1
                lastLeap = 0
            } else {
                let size = r.weighted([(0, 0.12), (1, 0.5), (2, 0.28), (3, 0.07), (4, 0.03)])
                step = size * (r.chance(0.75) ? preferred : -preferred)
                if size >= 3 { lastLeap = step }
            }
            if abs(position + step) > 4 {
                step = -step
                lastLeap = 0
            }
            position += step
            steps.append(step)
        }
        return steps
    }

    private func makeCall(bars motifBars: Int, rng r: inout SplitMix64) -> [MotifNote] {
        var rhythm: [MotifNote] = []
        for attempt in 0..<20 {
            rhythm = (0..<motifBars).flatMap { rhythmBar(at: Double($0) * bpb, feel: profile.melodyFeel, rng: &r) }
            if rhythm.count >= 3 * motifBars || attempt == 19 { break }
        }
        let steps = contour(rhythm.count, rng: &r)
        return zip(rhythm, steps).map { MotifNote(beat: $0.beat, length: $0.length, step: $1) }
    }

    /// An answer to `call`: the call's opening (its first bar, or first half bar for
    /// one-bar motifs), then a cadence: a short lead-in, a long note on a beat, a breath.
    private func makeAnswer(to call: [MotifNote], bars motifBars: Int, rng r: inout SplitMix64) -> [MotifNote] {
        let keep = motifBars == 2 ? bpb : (beatsPerBar == 4 ? 2 : 1)
        let end = Double(motifBars) * bpb
        var notes = call.filter { $0.beat < keep - 1e-9 }.map { note -> MotifNote in
            var n = note
            n.length = min(n.length, keep - n.beat)
            return n
        }
        // Occasionally vary one kept note so repeats aren't mechanical.
        if notes.count > 2 && r.chance(0.3) {
            notes[r.int(1...(notes.count - 1))].step += r.chance(0.5) ? 1 : -1
        }

        let available = end - keep
        let options: [(long: Double, rest: Double, weight: Double)] = [
            (3, 1, 1), (2, 1, 2), (2.5, 0.5, 1), (1.5, 0.5, 1.5), (2, 0, 1.5), (1, 1, 0.5), (1, 0, 0.3),
        ].filter { $0.long + $0.rest <= available + 1e-9 }
        let (long, rest) = r.weighted(options.map { (($0.long, $0.rest), $0.weight) })
        let longStart = end - rest - long
        var beat = keep
        while beat < longStart - 1e-9 {
            let length = longStart - beat >= 1 && r.chance(0.4) ? 1.0 : 0.5
            notes.append(MotifNote(beat: beat, length: length, step: r.weighted([(-1, 0.5), (-2, 0.2), (1, 0.2), (0, 0.1)])))
            beat += length
        }
        if notes.isEmpty {
            notes.append(MotifNote(beat: longStart, length: long, step: 0))
        } else {
            notes.append(MotifNote(beat: longStart, length: long, step: r.chance(0.7) ? -1 : 1))
        }
        return notes
    }

    /// The letters of a section's phrases, e.g. ["A", "A'", "B", "A''"].
    private func phraseForm(_ count: Int, rng r: inout SplitMix64) -> [String] {
        let base: [String] = switch count {
        case 1: ["A"]
        case 2: r.chance(0.4) ? ["A", "A'"] : ["A", "B"]
        case 3: ["A", "A'", "B"]
        default: r.pick([["A", "A'", "B", "A''"], ["A", "B", "A'", "B'"], ["A", "A'", "B", "B'"]])
        }
        var form = base
        while form.count < count { form.append(base[form.count % base.count] + "''") }
        return Array(form.prefix(count))
    }

    private func writeMelody(part: Int, program: Int, rng r: inout SplitMix64) {
        let center = melodyCenter(program)
        let verseRange = max(SongLimits.melody.lowerBound, center - 9)...min(SongLimits.melody.upperBound, center + 9)
        let chorusRange = min(verseRange.lowerBound + 3, 70)...min(verseRange.upperBound + 3, SongLimits.melody.upperBound)
        let motifBars = barSeconds >= 2.2 ? 1 : 2
        let phraseBars = motifBars * 2
        let jitter = r.uniform(0.0...0.008)
        let articulation: ClosedRange<Double> = switch program {
        case 73, 40, 53, 68, 71, 22, 21: 0.82...0.95
        case 80, 81: 0.7...0.9
        default: style == .funk ? 0.6...0.8 : 0.72...0.92
        }

        var materials: [SectionKind: [Character: PhraseMaterial]] = [:]
        var forms: [SectionKind: [String]] = [:]
        var previous: Int? = nil

        /// Plays a motif from `bar`, its first note on the chord tone nearest `anchor`, strong
        /// beats and long notes on chord tones, and (for a `home` cadence) the last note on the tonic.
        func realize(_ motif: [MotifNote], bar: Int, anchor: Int, range: ClosedRange<Int>, home: Bool, velocity: Int) {
            var last: Int? = nil
            for (i, note) in motif.enumerated() {
                let beat = Double(bar) * bpb + note.beat
                let chord = chord(at: beat)
                let scale = key.scale(over: chord)
                var pitch: Int
                if let last {
                    pitch = moveInScale(last, steps: note.step, scale: scale)
                    if !range.contains(pitch) { pitch = moveInScale(last, steps: -note.step, scale: scale) }
                } else {
                    pitch = nearestChordTone(moveInScale(anchor, steps: note.step, scale: scale), chord)
                }
                let inBar = beat - (beat / bpb).rounded(.down) * bpb
                let onStrongBeat = inBar == 0 || (beatsPerBar == 4 && inBar == 2)
                if onStrongBeat || note.length >= 1 {
                    let snapped = nearestChordTone(pitch, chord, direction: note.step.signum())
                    if let last, snapped == last, note.step != 0 {
                        // Snapping undid the step; keep the contour moving to the next chord tone.
                        pitch = last + note.step.signum()
                        while !chord.tones.contains(mod12(pitch)) { pitch += note.step.signum() }
                    } else {
                        pitch = snapped
                    }
                }
                if home && i == motif.count - 1 {
                    // A section's last cadence comes home: the tonic when the chord has it,
                    // else the root, whichever octave lies nearest the note before.
                    let target = chord.tones.contains(key.tonic) ? key.tonic : chord.root
                    let near = nearestPitch(pc: target, to: pitch)
                    let reference = last ?? pitch
                    pitch = [near - 12, near, near + 12].filter { range.contains($0) }
                        .min { abs($0 - reference) < abs($1 - reference) } ?? near
                }
                if let last, abs(pitch - last) > 9 { pitch += pitch > last ? -12 : 12 }
                pitch = fold(pitch, into: range)
                let downbeat = inBar == 0 ? 4 : 0
                let longNote = note.length >= 1.5
                addNote(part: part, pitch: pitch, beat: beat, length: note.length,
                        articulation: longNote ? r.uniform(0.85...0.95) : r.uniform(articulation),
                        velocity: velocity + downbeat + r.int(-10...10), offset: r.jitter(jitter))
                last = pitch
            }
            previous = last ?? previous
        }

        for (s, section) in sections.enumerated() {
            let firstBar = sections[..<s].reduce(0) { $0 + $1.bars }
            switch section.kind {
            case .intro:
                continue
            case .ending:
                // Hold the tonic through the final bar.
                let range = verseRange
                let pitch = fold(nearestPitch(pc: key.tonic, to: previous ?? center), into: range)
                addNote(part: part, pitch: pitch, beat: Double(firstBar) * bpb, length: bpb, articulation: 0.9,
                        velocity: 86 + r.int(-6...6), offset: r.jitter(jitter))
                continue
            case .verse, .chorus:
                break
            }
            let chorus = section.kind == .chorus
            let range = chorus ? chorusRange : verseRange
            let anchor = center + (chorus ? 3 : -1)
            let velocity = chorus ? 94 : 82
            let count = max(1, section.bars / phraseBars)
            let form = forms[section.kind] ?? phraseForm(count, rng: &r)
            forms[section.kind] = form

            for (p, letterName) in form.prefix(count).enumerated() {
                let letter = letterName.first!
                let variant = letterName.count - 1
                var material: PhraseMaterial
                if let existing = materials[section.kind]?[letter] {
                    material = existing
                } else {
                    material = PhraseMaterial(call: makeCall(bars: motifBars, rng: &r), answers: [],
                                              anchorShift: letter == "A" ? 0 : r.int(2...4))
                }
                while material.answers.count <= variant {
                    material.answers.append(makeAnswer(to: material.call, bars: motifBars, rng: &r))
                }
                materials[section.kind, default: [:]][letter] = material

                let bar = firstBar + p * phraseBars
                let phraseAnchor = anchor + material.anchorShift
                realize(material.call, bar: bar, anchor: phraseAnchor, range: range, home: false, velocity: velocity)
                realize(material.answers[variant], bar: bar + motifBars, anchor: phraseAnchor, range: range,
                        home: p == count - 1, velocity: velocity)
            }
        }
    }
}
