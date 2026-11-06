import Foundation

nonisolated struct ChordSegment: Hashable {
    let startTime: Double
    let endTime: Double
    let label: String
}

/// Turns detected notes into a chord progression by template-matching the
/// sounding pitch classes over each harmonic segment.
nonisolated enum ChordAnalyzer {
    /// Root and slash-bass names, by pitch class. `ChordSymbol` reads labels
    /// back with these.
    static let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    /// (intervals from root, display suffix). Ordered simplest-first. Every
    /// chord label in the app uses one of these suffixes (`HarmonyStage.label`
    /// writes a subset), so `ChordSymbol` parses labels with this table.
    static let templates: [(intervals: [Int], suffix: String)] = [
        ([0, 4, 7], ""),
        ([0, 3, 7], "m"),
        ([0, 3, 6], "dim"),
        ([0, 4, 8], "aug"),
        ([0, 5, 7], "sus4"),
        ([0, 2, 7], "sus2"),
        ([0, 4, 7, 10], "7"),
        ([0, 4, 7, 11], "maj7"),
        ([0, 3, 7, 10], "m7"),
        ([0, 3, 6, 10], "m7♭5"),
        ([0, 3, 6, 9], "dim7"),
        ([0, 4, 7, 9], "6"),
        ([0, 3, 7, 9], "m6"),
    ]

    /// The smallest segment (seconds) worth showing; shorter ones merge into
    /// their neighbor so passing tones don't spawn spurious chords.
    private static let minSegment = 0.18

    /// Broken chords (arpeggios, Alberti bass, fingerpicking) rarely sound
    /// three pitch classes at once. When the notes sounding now name no chord,
    /// the notes of the next `lookahead` seconds are pooled instead.
    private static let lookahead = 0.5
    /// In that pool a pitch class counts once it has this share of the
    /// strongest one (seconds x loudness).
    private static let presence = 0.15
    /// A rest up to this long between two equal chords doesn't split the
    /// chord (comping and stabs leave gaps; the harmony carries on).
    private static let maxBridge = 2.0

    private struct Chord {
        let label: String
        let root: Int
        /// Chord tones, bit k = pitch class k.
        let tones: Int
    }

    private typealias Segment = (a: Double, b: Double, chord: Chord?)

    static func segments(_ notes: [NoteEvent]) -> [ChordSegment] {
        guard !notes.isEmpty else { return [] }

        // Harmony only changes at a note start or end, so those are the boundaries.
        // Sweep lines keep the notes sounding at each segment's midpoint and the
        // notes of its look-ahead window (filtering every note per segment was
        // O(n²): seconds at -Onone on a dense take, and this runs after every
        // live window).
        let bounds = Set(notes.flatMap { [$0.startTime, $0.endTime] }).sorted()
        let byStart = notes.sorted { $0.startTime < $1.startTime }
        var admitted = 0
        var active: [NoteEvent] = []
        var admittedAhead = 0
        var ahead: [NoteEvent] = []
        // A chord depends only on the pitch-class set and the bass pitch class.
        var memo: [Int: Chord?] = [:]
        func chord(_ pcs: Int, bass: Int) -> Chord? {
            let key = pcs | bass << 12
            if let known = memo[key] { return known }
            let found = Self.chord(pitchClasses: pcs, bass: bass)
            memo[key] = found
            return found
        }

        var segs: [Segment] = []
        // The last named chord and when it ended: a short rest (a detached
        // arpeggio) doesn't break its carry-on.
        var lastChord: Chord?
        var lastChordEnd = -Double.infinity
        for i in 0..<(bounds.count - 1) {
            let a = bounds[i], b = bounds[i + 1]
            guard b - a > 1e-4 else { continue }
            let mid = (a + b) / 2
            while admitted < byStart.count, byStart[admitted].startTime <= mid {
                active.append(byStart[admitted])
                admitted += 1
            }
            active.removeAll { $0.endTime <= mid }
            var mask = 0, bass = Int.max
            for note in active {
                mask |= 1 << (note.pitch % 12)
                bass = min(bass, note.pitch)
            }
            guard !active.isEmpty else {
                segs.append((a, b, nil))
                continue
            }
            var found = chord(mask, bass: bass % 12)
            if found == nil, let previous = lastChord, a - lastChordEnd < minSegment, mask & ~previous.tones == 0 {
                // Too few notes to name a chord, but all of them belong to the
                // chord just heard: it carries on (the end of an arpeggio, a
                // power chord under the same harmony).
                found = previous
            } else if found == nil {
                // Pool the look-ahead window [a, b + lookahead].
                while admittedAhead < byStart.count, byStart[admittedAhead].startTime < b + lookahead {
                    ahead.append(byStart[admittedAhead])
                    admittedAhead += 1
                }
                ahead.removeAll { $0.endTime <= a }
                var weight = [Double](repeating: 0, count: 12)
                var low = Int.max
                for note in ahead {
                    let overlap = min(note.endTime, b + lookahead) - max(note.startTime, a)
                    weight[note.pitch % 12] += overlap * note.amplitude
                    low = min(low, note.pitch)
                }
                let strongest = weight.max() ?? 0
                if strongest > 0 {
                    var pooled = 0
                    for pc in 0..<12 where weight[pc] > presence * strongest { pooled |= 1 << pc }
                    found = chord(pooled, bass: low % 12)
                }
            }
            segs.append((a, b, found))
            if let found {
                lastChord = found
                lastChordEnd = b
            }
        }

        return absorbShort(mergeEqual(segs)).compactMap { seg in
            seg.chord.map { ChordSegment(startTime: seg.a, endTime: seg.b, label: $0.label) }
        }
    }

    /// Folds segments shorter than `minSegment` into their neighbors. Only
    /// gaps are folded into whatever came before; a short chord never
    /// disappears into a rest, and a run of short chords (a fast melody over
    /// one harmony) is judged as a whole instead of snowballing into the
    /// chord before it.
    private static func absorbShort(_ input: [Segment]) -> [Segment] {
        func length(_ s: Segment) -> Double { s.b - s.a }

        // 1. A short gap continues the chord before it, and a rest between
        //    two equal chords joins them.
        var segs: [Segment] = []
        for s in input {
            let n = segs.count
            if s.chord == nil, length(s) < minSegment, n > 0 {
                segs[n - 1].b = s.b
            } else if let c = s.chord, n >= 2, segs[n - 1].chord == nil, length(segs[n - 1]) <= maxBridge,
                      segs[n - 2].chord?.label == c.label {
                segs.removeLast()
                segs[n - 2].b = s.b
            } else if n > 0, segs[n - 1].chord?.label == s.chord?.label {
                segs[n - 1].b = s.b
            } else {
                segs.append(s)
            }
        }

        // 2. A run of consecutive short chords becomes one chord per root,
        //    named by the label heard longest (G / Gmaj7 / G / G6 under a
        //    16th-note melody is G; a change of root is a real change).
        var grouped: [Segment] = []
        var i = 0
        while i < segs.count {
            guard let first = segs[i].chord, length(segs[i]) < minSegment else {
                grouped.append(segs[i])
                i += 1
                continue
            }
            var j = i
            var heard: [(chord: Chord, seconds: Double)] = []
            while j < segs.count, let c = segs[j].chord, length(segs[j]) < minSegment, c.root == first.root {
                if let k = heard.firstIndex(where: { $0.chord.label == c.label }) {
                    heard[k].seconds += length(segs[j])
                } else {
                    heard.append((c, length(segs[j])))
                }
                j += 1
            }
            var best = heard[0]
            for h in heard where h.seconds > best.seconds { best = h }
            grouped.append((segs[i].a, segs[j - 1].b, best.chord))
            i = j
        }
        grouped = mergeEqual(grouped)

        // 3. A chord still too short joins a chord next to it: the one with the
        //    same root, else the longer one. With rests on both sides it stays
        //    (a stab is a chord, not noise).
        var out: [Segment] = []
        var carriedStart: Double?
        for k in grouped.indices {
            var s = grouped[k]
            if let start = carriedStart {
                s.a = start
                carriedStart = nil
            }
            if let c = s.chord, length(s) < minSegment {
                let left = out.last?.chord != nil ? out.last : nil
                let right = k + 1 < grouped.count && grouped[k + 1].chord != nil ? grouped[k + 1] : nil
                var intoLeft: Bool?
                if let l = left, let r = right {
                    let sameLeft = l.chord!.root == c.root, sameRight = r.chord!.root == c.root
                    intoLeft = sameLeft != sameRight ? sameLeft : length(l) >= length(r)
                } else if left != nil {
                    intoLeft = true
                } else if right != nil {
                    intoLeft = false
                }
                if let intoLeft {
                    if intoLeft { out[out.count - 1].b = s.b } else { carriedStart = s.a }
                    continue
                }
            }
            if let last = out.last, last.chord?.label == s.chord?.label {
                out[out.count - 1].b = s.b
            } else {
                out.append(s)
            }
        }
        return out
    }

    private static func mergeEqual(_ segs: [Segment]) -> [Segment] {
        var out: [Segment] = []
        for seg in segs {
            if !out.isEmpty, out[out.count - 1].chord?.label == seg.chord?.label {
                out[out.count - 1].b = seg.b
            } else {
                out.append(seg)
            }
        }
        return out
    }

    /// Template masks, `templateMasks[root][template]`: bit k = pitch class k.
    private static let templateMasks: [[Int]] = (0..<12).map { root in
        templates.map { $0.intervals.reduce(0) { $0 | 1 << ((root + $1) % 12) } }
    }

    /// Best template for a pitch-class set (bit k = pitch class k) over a bass
    /// pitch class; bit counting instead of Set algebra keeps Debug builds fast.
    private static func chord(pitchClasses pcs: Int, bass bassPC: Int) -> Chord? {
        guard pcs.nonzeroBitCount >= 3 else { return nil }

        var best: (score: Double, root: Int, suffix: String, tones: Int)?
        for root in 0..<12 {
            for (index, template) in templates.enumerated() {
                let tones = templateMasks[root][index]
                let matched = (pcs & tones).nonzeroBitCount
                guard matched >= 3 else { continue }
                let missing = (tones & ~pcs).nonzeroBitCount
                let extra = (pcs & ~tones).nonzeroBitCount
                var score = Double(matched) - 0.5 * Double(missing) - 0.85 * Double(extra)
                if root == bassPC { score += 0.1 }           // prefer root in the bass
                score -= 0.01 * Double(template.intervals.count) // prefer simpler on ties
                if best == nil || score > best!.score {
                    best = (score, root, template.suffix, tones)
                }
            }
        }

        guard let best, best.score >= 2.0 else { return nil }
        var label = names[best.root] + best.suffix
        if bassPC != best.root, best.tones & (1 << bassPC) != 0 {
            label += "/" + names[bassPC]
        }
        return Chord(label: label, root: best.root, tones: best.tones)
    }
}
