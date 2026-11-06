import Foundation

/// A key: tonic pitch class and mode.
nonisolated struct MusicalKey: Equatable {
    var tonic: Int
    var minor: Bool

    var label: String {
        ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"][tonic] + (minor ? "m" : "")
    }
}

/// Stage 7: the chord progression, decoded beat by beat.
///
/// The note-boundary analyzer (`ChordAnalyzer.segments`) names whatever pitch
/// classes sound at each instant, so passing tones and comping stabs make the
/// chords flicker (0.4 s segments against 1.3 s bars on the jazz recording).
/// Here the notes are pooled into a duration- and loudness-weighted chroma per
/// beat, and a Viterbi pass over the 24 major and minor triads picks one chord
/// per beat with a cost for every change (cheaper on a downbeat), a weak
/// prior toward chords of the take's key and a bonus for the chord whose root
/// the bass plays. In Song mode the beat also hears the take's tonal part
/// itself (`AudioOnsets.chroma`), so a chord the note engines missed or only
/// half heard still gets named. Labels are then filled in with sevenths,
/// sixths and slash basses from `ChordAnalyzer`'s vocabulary where the
/// segment's notes support them.
nonisolated enum HarmonyStage {
    struct Settings: Equatable {
        /// Emission sharpness: log-score = sharpness * cosine(chroma, triad).
        var sharpness = 8.0
        /// Cost of changing chord on a beat / on a downbeat.
        var changeCost = 2.0
        var downbeatChangeCost = 1.0
        /// Bonus for a chord diatonic to the estimated key.
        var keyBonus = 0.5
        /// Bonus for the chord whose root the beat's bass plays, times the
        /// root's share of the bass: a bass that alternates root and fifth
        /// gives each about half. The bass is what tells a minor seventh
        /// from its relative major (Fm7 holds all of Ab) and a chord from its
        /// neighbour a fourth or fifth away when the third is missing. Was
        /// 0.6 for the strongest bass note alone; the Song mode scoreboard's
        /// dev songs gain from 1.2 to 1.5 and lose at 2 and more (a walking
        /// bass then names its passing notes).
        var bassBonus = 1.4
        /// Share of the quietest notes left out of the chroma. 0 keeps every
        /// note: the square-root amplitude weight already discounts ghosts and
        /// bleed, and on transcribed songs the quiet notes are mostly real
        /// chord tones (a pad under a lead, an inner voice). Dropping the
        /// quietest 15% cost 0.027 chord accuracy on the Ableton songs and
        /// 0.012 on MusicBench.
        var quietNoteShare = 0.0
        /// Beats with less weighted note-time than this have no chord.
        var minBeatWeight = 0.02
        /// A rest up to this long keeps the chord going (comping leaves gaps).
        var maxBridge = 2.0
        /// Need at least this many beats, else the note-boundary analyzer runs.
        var minBeats = 8
        /// Song mode: the tonal part's chroma (`AudioOnsets.chroma`) is added
        /// to each beat's notes with the weight of this share of a typical
        /// beat's notes (the median over the take's sounding beats). A beat
        /// full of notes is decided by them; where the transcription is thin
        /// (a sampled loop, a pad, a part the engines miss) or silent, the
        /// sound decides. On the Song mode scoreboard's dev songs (real
        /// recordings) chord accuracy, the mean of root and major/minor, rose
        /// from 0.651 to 0.736 at 0.5, every song gaining, about flat from 0.5
        /// to 1 (0.725 at 0.35). On rendered songs, whose notes come out
        /// cleaner, it costs a little: MusicBench's dev songs 0.1 points, the
        /// Ableton renders 2, flat from 0.25 to 0.5 and more above it.
        var audioWeight = 0.5
        /// Audio frames quieter than this share of the take's median chroma
        /// level are silence: a beat with neither notes nor audio above it
        /// has no chord.
        var audioFloor = 0.1
    }

    /// `alsoHeard`: notes that sound in the take but are not in `notes`,
    /// read as harmony only (Song mode passes the preview's notes, see
    /// `RefineOutput.harmonyNotes`). Both lists count, so a note both hold
    /// counts twice. `audio`: the take's own pitch-class content
    /// (`AudioOnsets.chroma`, Song mode only); nil or without a chroma, the
    /// chords come from the notes alone, as in Piano mode.
    static func chords(notes shown: [NoteEvent], grid: BeatGrid, alsoHeard: [NoteEvent] = [],
                       audio: AudioOnsets? = nil, settings: Settings = Settings()) -> [ChordSegment] {
        let notes = shown + alsoHeard
        guard grid.beats.count >= settings.minBeats, !notes.isEmpty else { return ChordAnalyzer.segments(notes) }
        // Chords sound only while notes do: a rest longer than `maxBridge`
        // is a gap, a shorter one is bridged (as in ChordAnalyzer).
        var coverage: [ChordSegment] = []
        for n in notes.sorted(by: { $0.startTime < $1.startTime }) {
            if let last = coverage.last, n.startTime <= last.endTime + settings.maxBridge {
                coverage[coverage.count - 1] = ChordSegment(startTime: last.startTime, endTime: max(last.endTime, n.endTime), label: "")
            } else {
                coverage.append(ChordSegment(startTime: n.startTime, endTime: n.endTime, label: ""))
            }
        }
        // ... or while the audio sounds, where it names the chord.
        let decoded = beatSynchronous(notes: notes, grid: grid, audio: audio, settings: settings)
        return clip(decoded.chords, to: coverage + decoded.heard)
    }

    /// `segments` intersected with the union of `coverage`'s spans.
    static func clip(_ segments: [ChordSegment], to coverage: [ChordSegment]) -> [ChordSegment] {
        var spans: [(Double, Double)] = []
        for c in coverage.sorted(by: { $0.startTime < $1.startTime }) {
            if let last = spans.last, c.startTime <= last.1 + 1e-6 { spans[spans.count - 1].1 = max(last.1, c.endTime) }
            else { spans.append((c.startTime, c.endTime)) }
        }
        var out: [ChordSegment] = []
        for seg in segments {
            for span in spans where span.1 > seg.startTime && span.0 < seg.endTime {
                let a = max(seg.startTime, span.0), b = min(seg.endTime, span.1)
                if b - a > 1e-6 {
                    if let last = out.last, last.label == seg.label, abs(last.endTime - a) < 1e-6 {
                        out[out.count - 1] = ChordSegment(startTime: last.startTime, endTime: b, label: seg.label)
                    } else {
                        out.append(ChordSegment(startTime: a, endTime: b, label: seg.label))
                    }
                }
            }
        }
        return out
    }

    // MARK: - Chroma

    /// Per beat span [beats[i], beats[i+1]) (the last beat spans one median
    /// beat): 12-bin chroma and bass chroma, each note weighted by its overlap
    /// in seconds times the square root of its amplitude. The quietest
    /// `quietShare` of the notes are left out.
    static func beatChroma(notes: [NoteEvent], beats: [Double], quietShare: Double = 0)
        -> (spans: [(Double, Double)], chroma: [[Double]], bass: [[Double]]) {
        let gaps = zip(beats.dropFirst(), beats).map { $0 - $1 }.sorted()
        let typical = gaps.isEmpty ? 0.5 : gaps[gaps.count / 2]
        let spans = beats.indices.map { i in (beats[i], i + 1 < beats.count ? beats[i + 1] : beats[i] + typical) }
        let amps = notes.map(\.amplitude).sorted()
        let floor = quietShare > 0 ? amps[Int(Double(amps.count - 1) * min(quietShare, 1))] : -Double.infinity
        var chroma = [[Double]](repeating: [Double](repeating: 0, count: 12), count: spans.count)
        var bass = chroma
        var lowest = [Int](repeating: Int.max, count: spans.count)
        let sorted = notes.filter { $0.amplitude >= floor || amps.count < 20 }.sorted { $0.startTime < $1.startTime }
        // Sweep: notes are short relative to the take, so a moving start index suffices.
        var first = 0
        for (i, span) in spans.enumerated() {
            while first < sorted.count, sorted[first].startTime < span.0 - 8 { first += 1 }
            var j = first
            while j < sorted.count, sorted[j].startTime < span.1 {
                let n = sorted[j]
                let overlap = min(n.endTime, span.1) - max(n.startTime, span.0)
                if overlap > 0 {
                    let w = overlap * max(n.amplitude, 0.05).squareRoot()
                    let pc = ((n.pitch % 12) + 12) % 12
                    chroma[i][pc] += w
                    lowest[i] = min(lowest[i], n.pitch)
                }
                j += 1
            }
            // Bass chroma: notes within a fifth of the beat's lowest note.
            if lowest[i] != Int.max {
                j = first
                while j < sorted.count, sorted[j].startTime < span.1 {
                    let n = sorted[j]
                    let overlap = min(n.endTime, span.1) - max(n.startTime, span.0)
                    if overlap > 0, n.pitch <= lowest[i] + 7 { bass[i][((n.pitch % 12) + 12) % 12] += overlap }
                    j += 1
                }
            }
        }
        return (spans, chroma, bass)
    }

    /// The mean of `chroma` (12 values per frame at `fps`, frame i centred at
    /// i / fps s) over each span, at unit length; nil where the span is
    /// silent: its mean level is under `floor` times the take's median
    /// frame level.
    static func spanChroma(_ chroma: [Float], fps: Double, spans: [(Double, Double)], floor: Double) -> [[Double]?] {
        let frames = chroma.count / 12
        guard frames > 0, fps > 0 else { return spans.map { _ in nil } }
        let levels = (0..<frames).map { f in (0..<12).reduce(0.0) { $0 + Double(chroma[f * 12 + $1]) } }
        let sounding = levels.filter { $0 > 0 }.sorted()
        let reference = sounding.isEmpty ? 0 : sounding[sounding.count / 2]
        return spans.map { span in
            let f0 = max(0, Int((span.0 * fps).rounded(.up))), f1 = min(frames, Int((span.1 * fps).rounded(.up)))
            guard f1 > f0 else { return nil }
            var mean = [Double](repeating: 0, count: 12)
            for f in f0..<f1 { for pc in 0..<12 { mean[pc] += Double(chroma[f * 12 + pc]) } }
            let level = mean.reduce(0, +) / Double(f1 - f0)
            guard level > 0, level > floor * reference else { return nil }
            let norm = mean.map { $0 * $0 }.reduce(0, +).squareRoot()
            return mean.map { $0 / norm }
        }
    }

    // MARK: - Key

    /// Krumhansl-Kessler key profiles correlated with the whole take's chroma.
    static func estimateKey(_ chroma: [Double]) -> MusicalKey? {
        let major = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
        let minor = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
        guard chroma.reduce(0, +) > 0 else { return nil }
        func corr(_ a: [Double], _ b: [Double]) -> Double {
            let ma = a.reduce(0, +) / 12, mb = b.reduce(0, +) / 12
            var num = 0.0, da = 0.0, db = 0.0
            for i in 0..<12 { num += (a[i] - ma) * (b[i] - mb); da += (a[i] - ma) * (a[i] - ma); db += (b[i] - mb) * (b[i] - mb) }
            return da > 0 && db > 0 ? num / (da * db).squareRoot() : 0
        }
        var best: (Double, MusicalKey)?
        for tonic in 0..<12 {
            for (profile, isMinor) in [(major, false), (minor, true)] {
                let rotated = (0..<12).map { profile[((($0 - tonic) % 12) + 12) % 12] }
                let r = corr(chroma, rotated)
                if best == nil || r > best!.0 { best = (r, MusicalKey(tonic: tonic, minor: isMinor)) }
            }
        }
        return best?.1
    }

    /// Triads (root, minor) that belong to `key`: the diatonic triads, plus
    /// the major dominant in minor.
    static func diatonic(_ key: MusicalKey) -> Set<Int> {
        // State index = root * 2 + (minor ? 1 : 0).
        let degrees: [(Int, Bool)] = key.minor
            ? [(0, true), (3, false), (5, true), (7, true), (7, false), (8, false), (10, false)]
            : [(0, false), (2, true), (4, true), (5, false), (7, false), (9, true)]
        return Set(degrees.map { (((key.tonic + $0.0) % 12) * 2) + ($0.1 ? 1 : 0) })
    }

    // MARK: - Decoding

    /// The decoded chords, and the beats whose audio sounds (`heard`, empty
    /// without an audio chroma), which keep their chord where no note does.
    static func beatSynchronous(notes: [NoteEvent], grid: BeatGrid, audio: AudioOnsets? = nil,
                                settings: Settings) -> (chords: [ChordSegment], heard: [ChordSegment]) {
        let (spans, chroma, bass) = beatChroma(notes: notes, beats: grid.beats, quietShare: settings.quietNoteShare)
        let sound = audio?.chroma.map { spanChroma($0, fps: OnsetEnvelope.chromaFPS, spans: spans, floor: settings.audioFloor) }
            ?? spans.map { _ in nil }
        // The audio counts as `audioWeight` of a typical sounding beat's notes.
        let norms = chroma.map { $0.map { $0 * $0 }.reduce(0, +).squareRoot() }.filter { $0 > 0 }.sorted()
        let audioScale = settings.audioWeight * (norms.isEmpty ? 1 : norms[norms.count / 2])
        let total = (0..<12).map { pc in chroma.reduce(0) { $0 + $1[pc] } }
        let key = estimateKey(total)
        let inKey = key.map(diatonic) ?? []
        let downbeats = Set(grid.downbeats.map { Int(($0 * 1000).rounded()) })

        // States 0..<24 are triads (root * 2 + minor); 24 is "no chord".
        let states = 25, none = 24
        let templates: [[Double]] = (0..<24).map { s in
            let root = s / 2, third = s % 2 == 1 ? 3 : 4
            var t = [Double](repeating: 0, count: 12)
            t[root] = 1; t[(root + third) % 12] = 1; t[(root + 7) % 12] = 1
            return t
        }
        func emission(_ i: Int) -> [Double] {
            var c = chroma[i]
            let energy = c.reduce(0, +)
            let beatLength = spans[i].1 - spans[i].0
            let silent = energy < settings.minBeatWeight * max(beatLength, 0.1)
            if let heard = sound[i] {
                // Where the notes are silent this is the sound's chroma alone.
                if silent { c = [Double](repeating: 0, count: 12) }
                for pc in 0..<12 { c[pc] += audioScale * heard[pc] }
            } else if silent {
                // A silent beat favours nothing, so the chord carries through
                // it; rests longer than `maxBridge` are cut out afterwards.
                return [Double](repeating: 0, count: states)
            }
            let norm = c.map { $0 * $0 }.reduce(0, +).squareRoot()
            let bassTotal = bass[i].reduce(0, +)
            var e = (0..<24).map { s -> Double in
                let dot = zip(c, templates[s]).reduce(0) { $0 + $1.0 * $1.1 }
                var v = settings.sharpness * dot / (norm * 3.0.squareRoot())
                if inKey.contains(s) { v += settings.keyBonus }
                if bassTotal > 0 { v += settings.bassBonus * bass[i][s / 2] / bassTotal }
                return v
            }
            e.append(settings.sharpness * 0.35)   // "no chord" for unclear beats
            return e
        }

        var score = emission(0)
        var back = [[Int]](repeating: [], count: spans.count)
        for i in 1..<spans.count {
            let isDown = downbeats.contains(Int((spans[i].0 * 1000).rounded()))
            let cost = isDown ? settings.downbeatChangeCost : settings.changeCost
            let bestPrev = score.indices.max { score[$0] < score[$1] }!
            let e = emission(i)
            var next = [Double](repeating: 0, count: states)
            var pointers = [Int](repeating: 0, count: states)
            for s in 0..<states {
                let stay = score[s], change = score[bestPrev] - cost
                if stay >= change { next[s] = stay + e[s]; pointers[s] = s } else { next[s] = change + e[s]; pointers[s] = bestPrev }
            }
            score = next
            back[i] = pointers
        }
        var path = [Int](repeating: 0, count: spans.count)
        path[spans.count - 1] = score.indices.max { score[$0] < score[$1] }!
        var i = spans.count - 1
        while i > 0 { path[i - 1] = back[i][path[i]]; i -= 1 }

        // Merge equal beats into segments and label each.
        var out: [ChordSegment] = []
        var start = 0
        for k in 1...spans.count where k == spans.count || path[k] != path[start] {
            let s = path[start]
            if s != none {
                let pooled = (0..<12).map { pc in (start..<k).reduce(0) { $0 + chroma[$1][pc] } }
                let pooledBass = (0..<12).map { pc in (start..<k).reduce(0) { $0 + bass[$1][pc] } }
                out.append(ChordSegment(startTime: spans[start].0, endTime: spans[k - 1].1,
                                        label: label(root: s / 2, minor: s % 2 == 1, chroma: pooled, bass: pooledBass)))
            }
            start = k
        }
        let heard = spans.indices.filter { sound[$0] != nil }
            .map { ChordSegment(startTime: spans[$0].0, endTime: spans[$0].1, label: "") }
        return (out, heard)
    }

    /// A triad's display label, with a 7th or 6th when the notes hold one
    /// strongly and a slash bass when another chord tone is clearly lowest.
    static func label(root: Int, minor: Bool, chroma: [Double], bass: [Double]) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let third = minor ? 3 : 4
        let triad = [0, third, 7].map { chroma[(root + $0) % 12] }
        let reference = triad.reduce(0, +) / 3
        var suffix = minor ? "m" : ""
        let options: [(Int, String)] = minor ? [(10, "m7"), (9, "m6")] : [(10, "7"), (11, "maj7"), (9, "6")]
        if reference > 0, let best = options.max(by: { chroma[(root + $0.0) % 12] < chroma[(root + $1.0) % 12] }),
           chroma[(root + best.0) % 12] >= 0.6 * reference {
            suffix = best.1
        }
        var text = names[root] + suffix
        let bassTotal = bass.reduce(0, +)
        if bassTotal > 0, let low = bass.indices.max(by: { bass[$0] < bass[$1] }), low != root,
           bass[low] >= 0.6 * bassTotal, [third, 7].contains(((low - root) % 12 + 12) % 12) {
            text += "/" + names[low]
        }
        return text
    }
}
