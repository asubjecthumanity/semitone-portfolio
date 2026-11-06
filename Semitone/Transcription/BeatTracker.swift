import Foundation

/// Beat and downbeat tracking from transcribed notes with a bar-pointer model
/// (after Krebs, Böck & Widmer 2015 — the model behind madmom's downbeat
/// tracker). Hidden state = (tempo, position within the bar); a Viterbi pass
/// finds the most likely path. Beats have to line up with note onsets, beat 1
/// with bass notes and harmony changes, and the tempo may only drift
/// gradually — which keeps beats steady through rubato instead of jumping to
/// whatever note is nearest.
///
/// Validated against MIDI ground truth in "semitone training" (see
/// Tools/PianoModel/README.md): beat / bar-line F1 1.00 / 1.00 on clip 1 and
/// 0.96 / 0.94 on clip 3 (0.92 / 0.89 in its rubato half), vs 0.60 / 0.23 for
/// the previous nearest-onset grid.
nonisolated enum BeatTracker {
    static let fps = 100.0

    /// How much a drum-heavy take's percussive part (`AudioOnsets.Percussion`)
    /// counts as beat evidence, next to the notes (about 1 per note) and the
    /// tonal onsets (0.3). The percussive onsets have to outweigh the notes: in
    /// funk the notes sit on the sixteenths around the beat, and at the tonal
    /// weight the grid stayed a sixteenth or half a beat off. Chosen on
    /// MusicBench dev, on its funk song (beats 0.57 to 0.80): 2-3 give the same
    /// grid there; 1.25 or less does not fix it. A lighter kit's counts less
    /// (times `AudioOnsets.Percussion.weight`).
    static let percussionWeight: Float = 2

    /// How much a drum-heavy take's kick band (`AudioOnsets.Percussion.low`)
    /// adds to the evidence for beat 1. It is added to beat 1's activation
    /// only, not to the bar-line evidence that also takes weight from the
    /// other beats (as it was until October 2026): a kick on every beat then
    /// made every beat less likely to be a beat that is not beat 1, so a grid
    /// on the off-beats fit better, and Superstition's sat there (beat F1
    /// 0.04). A kick is evidence for a beat, a little more for beat 1; on real
    /// records its onset is often no louder on 1 than on 3, so it stays light.
    /// On the bitmidi dev songs 0.25-0.8 give the same grids. A lighter kit's
    /// counts less (times `AudioOnsets.Percussion.weight`).
    static let kickWeight: Float = 0.5

    /// How much the chord changes heard in an any-instrument take's tonal part
    /// (`AudioOnsets.harmony`) count as bar-line evidence, next to the bass
    /// notes and the notes' own harmony changes (up to 1 each). A light
    /// tie-break: chords change on beat 1 more often than on other beats, but
    /// anticipated chords (pushed an eighth early) change between beats, and a
    /// heavier weight pulled the grid toward them. On the bitmidi dev songs
    /// 0.05-0.2 give the same grids (Bohemian Rhapsody's bar lines 0.29 ->
    /// 0.61); 0.25-0.5 put Viva la Vida's grid at half tempo for longer and
    /// 1 moved Never Gonna Give You Up's beats onto its pushed chords.
    static let harmonyWeight: Float = 0.1

    /// What a bar cut short by half costs the decoder, in log-likelihood (in
    /// meters with an even count, so 4/4 can hold a 2/4 bar). Songs drop half
    /// a bar now and then (Africa six times, Bohemian Rhapsody and Country
    /// Roads too), and the bar-pointer model had no way to follow: it kept
    /// counting four, and beat 1 sat on beat 3 until the next short bar put
    /// it back (Africa's bar lines 0.52). A cut has to
    /// pay for itself with several bars of bar-line evidence, so it is not
    /// taken to fix one bar. On the bitmidi dev songs 8-12 give the same
    /// grids (Africa's bar lines 0.52 -> 0.87); 6 cuts Superstition's and
    /// Country Roads' bars where they are whole, 16 misses Bohemian
    /// Rhapsody's 2/4 bar. In Song mode a 4/4 take's bar lines are then
    /// decided again from the audio's chord changes (`BarPhase`).
    static let halfBarCost = 10.0

    struct Result {
        var beats: [Double] = []
        /// Position of each beat within its bar (0 = downbeat).
        var barPositions: [Int] = []
        var beatsPerBar: Int = 4
        /// Average log-likelihood per frame (comparable across meters).
        var score: Double = -.infinity

        var medianBPM: Double {
            guard beats.count > 2 else { return 0 }
            let gaps = zip(beats.dropFirst(), beats).map { $0 - $1 }.sorted()
            return 60 / gaps[gaps.count / 2]
        }
    }

    /// Frame-wise evidence that a beat / a downbeat starts here.
    struct Activations {
        var beat: [Float]
        var down: [Float]
    }

    // MARK: - Evidence from notes

    static func activations(notes: [NoteEvent], duration: Double, downbeatPitchClass: Int? = nil,
                            audioOnsets: AudioOnsets? = nil, audioWeight: Float = 0.3) -> Activations {
        let n = Int(duration * fps) + 2
        var onset = [Float](repeating: 0, count: n)
        var bass = [Float](repeating: 0, count: n)
        var harm = [Float](repeating: 0, count: n)
        let sorted = notes.sorted { $0.startTime < $1.startTime }

        // Cluster near-simultaneous onsets (35 ms) into one event.
        var clusters: [[NoteEvent]] = []
        for note in sorted {
            if let first = clusters.last?.first, note.startTime - first.startTime <= 0.035 {
                clusters[clusters.count - 1].append(note)
            } else {
                clusters.append([note])
            }
        }

        // Sweep line for the harmony-change windows: `live` holds, in `sorted`
        // order, every note that can overlap [t - 0.5, t + 0.5]. Scanning all
        // notes per cluster was O(clusters x notes), seconds at -Onone on a
        // dense take; same notes in the same order keeps the sums bit-identical.
        var live: [NoteEvent] = []
        var admitted = 0
        func chroma(_ a: Double, _ b: Double) -> [Double] {
            var v = [Double](repeating: 0, count: 12)
            for note in live where note.startTime < b && note.endTime > a {
                v[((note.pitch % 12) + 12) % 12] += min(note.endTime, b) - max(note.startTime, a)
            }
            return v
        }

        for group in clusters {
            let t = group[0].startTime
            while admitted < sorted.count, sorted[admitted].startTime < t + 0.5 {
                live.append(sorted[admitted])
                admitted += 1
            }
            live.removeAll { $0.endTime <= t - 0.5 }
            let f = Int((t * fps).rounded())
            guard f >= 0, f < n else { continue }
            onset[f] += Float(group.reduce(0) { $0 + 0.3 + $1.amplitude })
            let low = group.min { $0.pitch < $1.pitch }!
            if low.pitch < 55 {
                bass[f] += Float(1 + min(low.endTime - low.startTime, 2))
            }
            if let pc = downbeatPitchClass, group.contains(where: { ((($0.pitch % 12) + 12) % 12) == pc }) {
                bass[f] += 1.5   // the user's "this note starts each bar" hint
            }
            // Harmony change: pitch-class content just after vs just before.
            let before = chroma(t - 0.5, t), after = chroma(t, t + 0.5)
            let dot = zip(before, after).reduce(0) { $0 + $1.0 * $1.1 }
            let norm = sqrt(before.reduce(0) { $0 + $1 * $1 }) * sqrt(after.reduce(0) { $0 + $1 * $1 })
            harm[f] = Float(norm > 0 ? 1 - dot / norm : 1)
        }

        // +-1 frame tolerance, then scale so typical strong events read ~1.
        func spread(_ x: [Float]) -> [Float] {
            (0..<x.count).map { i in max(x[max(i - 1, 0)], x[i], x[min(i + 1, x.count - 1)]) }
        }
        func normalized(_ x: [Float]) -> [Float] {
            let nonzero = x.filter { $0 > 0 }.sorted()
            guard !nonzero.isEmpty else { return x }
            // numpy-style linear-interpolated 90th percentile
            let pos = 0.9 * Double(nonzero.count - 1)
            let lo = Int(pos.rounded(.down)), hi = min(lo + 1, nonzero.count - 1)
            let p90 = nonzero[lo] + Float(pos - Double(lo)) * (nonzero[hi] - nonzero[lo])
            return x.map { min($0 / max(p90, 1e-9), 1) }
        }
        // The audio's own onset envelope (spectral flux at `fps`, see
        // OnsetEnvelope; the tonal part's for any-instrument takes): attacks
        // the note engine merged or never transcribed (strums, re-picked
        // chords) still mark the beat's phase. Kept light (0.3): at full
        // weight its subdivisions halved one MusicBench song's tempo and
        // flipped a waltz to 4/4.
        if let env = audioOnsets?.onsets, !env.isEmpty {
            let scaled = normalized(env)
            for i in 0..<min(n, scaled.count) { onset[i] += audioWeight * scaled[i] }
        }
        // A take's percussive part: the kit's attacks mark the beat where the
        // notes are syncopated (see `percussionWeight`), in full on a
        // drum-heavy take and less on a lighter kit (`Percussion.weight`). The
        // kit itself is not transcribed.
        let percussion = audioOnsets?.percussion
        let kit = percussion?.weight ?? 0
        if let env = percussion?.onsets, !env.isEmpty {
            let scaled = normalized(env)
            for i in 0..<min(n, scaled.count) { onset[i] += kit * percussionWeight * scaled[i] }
        }
        let on = normalized(spread(onset))
        let bassMax = bass.max() ?? 0
        let downRaw = (0..<n).map { (bassMax > 0 ? bass[$0] / bassMax : 0) + harm[$0] }
        var down = normalized(spread(downRaw))
        // Chord changes heard in the audio (see `harmonyWeight`).
        if let change = audioOnsets?.harmony, !change.isEmpty {
            let scaled = normalized(change)
            for i in 0..<min(n, scaled.count) { down[i] = min(down[i] + harmonyWeight * scaled[i], 1) }
        }

        // The kit's kick leans toward beat 1 (see `kickWeight`).
        var kick = [Float](repeating: 0, count: n)
        if let env = percussion?.low, !env.isEmpty {
            let scaled = normalized(spread(env))
            for i in 0..<min(n, scaled.count) { kick[i] = kit * scaled[i] }
        }

        // Onsets are evidence, not certainty: cap at 0.5 so a note between
        // beats costs a little rather than ruling a tempo out.
        let beatAct = (0..<n).map { max(0.5 * on[$0] * (1 - 0.7 * down[$0]), 1e-4) }
        let downAct = (0..<n).map { max(0.5 * on[$0] * (0.2 + 0.7 * down[$0] + kickWeight * kick[$0]), 1e-4) }
        return Activations(beat: beatAct, down: downAct)
    }

    // MARK: - Bar-pointer Viterbi

    /// `intervalRange` (in frames per beat) defaults to 55–215 BPM.
    static func decode(
        _ act: Activations,
        beatsPerBar n: Int,
        intervalRange: ClosedRange<Int>? = nil,
        transitionLambda: Double = 60,
        observationLambda: Int = 16,
        preferredBPM: Double = 120,
        preferenceOctaves: Double = 1,
        transitionBand: Double = 0.12,
        halfBarCost: Double = BeatTracker.halfBarCost
    ) -> Result {
        let frames = act.beat.count
        let range = intervalRange ?? Int((60 * fps / 215).rounded(.up))...Int((60 * fps / 55).rounded(.down))
        let intervals = Array(range)
        let K = intervals.count
        guard frames > 1, K > 0, n >= 1 else { return Result(beatsPerBar: n) }

        // State blocks: tempo k owns n * I_k positions, stored as a ring so the
        // per-frame advance is free: logical position p at frame t lives at
        // physical slot offsets[k] + (p - t) mod L_k. `phase[k]` tracks t mod L_k.
        // (Hot loops use raw buffers and while-loops so Debug builds stay usable.)
        let lengths = intervals.map { n * $0 }
        var offsets = [Int](repeating: 0, count: K + 1)
        for k in 0..<K { offsets[k + 1] = offsets[k] + lengths[k] }

        // Tempo transitions: exp(-lambda |ratio - 1|), row-normalized, plus a
        // gentle preference for moderate tempi, paid once per beat. Flattened
        // by destination: sources transFrom[transStart[k]..<transStart[k+1]].
        // Beyond ~12% per beat the transition probability is e^-7 or less:
        // searching further only costs time.
        let band = transitionBand
        var incoming = [[(from: Int, logp: Double)]](repeating: [], count: K)
        for kp in 0..<K {
            var row: [(Int, Double)] = []
            for k in 0..<K {
                let ratio = Double(intervals[k]) / Double(intervals[kp])
                if abs(ratio - 1) <= band { row.append((k, -transitionLambda * abs(ratio - 1))) }
            }
            let lse = log(row.reduce(0) { $0 + exp($1.1) })
            for (k, lp) in row {
                let bpm = 60 * fps / Double(intervals[k])
                let pref = 0.5 * pow(log2(bpm / preferredBPM) / preferenceOctaves, 2)
                incoming[k].append((kp, lp - lse - pref))
            }
        }
        var transStart = [Int](repeating: 0, count: K + 1)
        for k in 0..<K { transStart[k + 1] = transStart[k] + incoming[k].count }
        let transFrom = incoming.flatMap { $0.map(\.from) }
        let transLogp = incoming.flatMap { $0.map(\.logp) }

        let negInf = -Double.greatestFiniteMagnitude / 4
        var value = [Double](repeating: negInf, count: offsets[K])
        // choice[t][k][j]: tempo index we came from when beat j began at tempo k.
        var choice = [UInt8](repeating: 0, count: frames * K * n)
        // A bar cut short (see `halfBarCost`): beat 1 may also follow the end
        // of beat `half` (0-based `half - 1`) instead of the bar's last beat.
        // cut[t][k]: beat 1 began at tempo k at frame t after half a bar.
        let half = n >= 4 && n % 2 == 0 && halfBarCost.isFinite ? n / 2 : 0
        var cut = [Bool](repeating: false, count: half > 0 ? frames * K : 0)
        var ends = [Double](repeating: 0, count: K * n)
        var phase = [Int](repeating: 0, count: K)
        // Each beat's first 1/observationLambda is its beat region (madmom's
        // observation model). In whole frames that was rounded down, so the
        // region's share of the beat swung with the tempo: 2 frames of a 43-frame
        // beat (4.7%, 140 BPM) but 5 of an 87 (5.7%, 69 BPM). The tempo octave
        // then followed the rounding: Viva la Vida tracked at half its 137 BPM
        // for most of the song, and its grid wandered between 69 and 92 BPM.
        // The frame after the whole ones now counts by the fraction left over,
        // so the region is exactly 1/observationLambda of every beat.
        let regionLength = intervals.map { max(1, $0 / observationLambda) }
        let regionFraction = zip(intervals, regionLength).map {
            max(0, Double($0) / Double(observationLambda) - Double($1))
        }
        let oneMinus = Double(observationLambda - 1)

        value.withUnsafeMutableBufferPointer { V in
        choice.withUnsafeMutableBufferPointer { C in
        cut.withUnsafeMutableBufferPointer { Cut in
        ends.withUnsafeMutableBufferPointer { E in
        phase.withUnsafeMutableBufferPointer { ph in
        intervals.withUnsafeBufferPointer { Iv in
        lengths.withUnsafeBufferPointer { Ln in
        offsets.withUnsafeBufferPointer { Off in
        regionLength.withUnsafeBufferPointer { Rg in
        regionFraction.withUnsafeBufferPointer { Fr in
        transStart.withUnsafeBufferPointer { TS in
        transFrom.withUnsafeBufferPointer { TF in
        transLogp.withUnsafeBufferPointer { TL in
        act.beat.withUnsafeBufferPointer { AB in
        act.down.withUnsafeBufferPointer { AD in
            // Physical index of logical position p for tempo k at the current phase.
            @inline(__always) func at(_ k: Int, _ p: Int) -> Int {
                var i = p - ph[k]
                if i < 0 { i += Ln[k] }
                return Off[k] + i
            }
            // Every state gets the non-beat observation each frame; rather than
            // adding it everywhere, add only the difference to beat-region states.
            @inline(__always) func observe(_ t: Int) {
                let b = Double(AB[t]), d = Double(AD[t])
                let none = log(max(1 - b - d, 1e-4) / oneMinus)
                let beatDelta = log(b) - none, downDelta = log(d) - none
                var k = 0
                while k < K {
                    let I = Iv[k], r = Rg[k], f = Fr[k]
                    var j = 0
                    while j < n {
                        let delta = j == 0 ? downDelta : beatDelta
                        var q = 0
                        while q < r { V[at(k, j * I + q)] += delta; q += 1 }
                        if f > 0 { V[at(k, j * I + r)] += f * delta }
                        j += 1
                    }
                    k += 1
                }
            }

            // Uniform prior: the take may start at any tempo and any point in the
            // bar (as in madmom). Starting every path on beat 1 at frame 0 put a
            // fake downbeat at 0 s and, after a lead-in of silence, bent the
            // grid (or the meter) to reach the music's real phase.
            var s0 = 0
            while s0 < Off[K] { V[s0] = 0; s0 += 1 }
            observe(0)

            var t = 1
            while t < frames {
                // Read every beat end (frame t-1) before writing beat starts (frame t):
                // the start of beat j now occupies the slot beat j-1 ended in.
                var k = 0
                while k < K {
                    let I = Iv[k]
                    var j = 0
                    while j < n { E[k * n + j] = V[at(k, (j + 1) * I - 1)]; j += 1 }
                    // advance this tempo's ring by one frame
                    ph[k] += 1
                    if ph[k] == Ln[k] { ph[k] = 0 }
                    k += 1
                }
                let base = t * K * n
                k = 0
                while k < K {
                    let I = Iv[k]
                    var j = 0
                    while j < n {
                        let prevBeat = j == 0 ? n - 1 : j - 1
                        var best = negInf, arg = 0
                        var e = TS[k]
                        while e < TS[k + 1] {
                            let v = E[TF[e] * n + prevBeat] + TL[e]
                            if v > best { best = v; arg = TF[e] }
                            e += 1
                        }
                        if j == 0, half > 0 {
                            var shortened = false
                            e = TS[k]
                            while e < TS[k + 1] {
                                let v = E[TF[e] * n + half - 1] + TL[e] - halfBarCost
                                if v > best { best = v; arg = TF[e]; shortened = true }
                                e += 1
                            }
                            Cut[t * K + k] = shortened
                        }
                        V[at(k, j * I)] = best
                        C[base + k * n + j] = UInt8(arg)
                        j += 1
                    }
                    k += 1
                }
                observe(t)
                t += 1
            }
        }}}}}}}}}}}}}}}

        // Best final state (phase now = (frames - 1) mod L_k), then walk back.
        let last = frames - 1
        var bestK = 0, bestP = 0, bestV = negInf
        for k in 0..<K {
            let L = lengths[k], ph = last % L
            for p in 0..<L {
                var i = p - ph
                if i < 0 { i += L }
                let v = value[offsets[k] + i]
                if v > bestV { bestV = v; bestK = k; bestP = p }
            }
        }
        var beatFrames: [(frame: Int, position: Int)] = []
        var k = bestK, p = bestP
        var t = last
        while true {
            let I = intervals[k]
            // A path that starts inside a beat's region (the music begins on a
            // beat at frame 0) still reports that beat.
            if p % I == 0 || (t == 0 && p % I < regionLength[k]) { beatFrames.append((t, p / I)) }
            if t == 0 { break }
            if p % I == 0 {
                let j = p / I
                let kp = Int(choice[t * K * n + k * n + j])
                let previous = j == 0 && half > 0 && cut[t * K + k] ? half - 1 : (j - 1 + n) % n
                k = kp
                p = (previous + 1) * intervals[kp] - 1
            } else {
                p -= 1
            }
            t -= 1
        }
        beatFrames.reverse()

        // Constant per-frame non-beat term omitted above is the same for every
        // meter, so bestV / frames already compares meters fairly.
        return Result(
            beats: beatFrames.map { Double($0.frame) / fps },
            barPositions: beatFrames.map(\.position),
            beatsPerBar: n,
            score: bestV / Double(frames)
        )
    }

    // MARK: - Public entry

    /// `beatsPerBar` nil = pick 3, 4 or 5 automatically. `tempoOctave` -1 / +1
    /// re-tracks at half / double the detected tempo. `barShift` moves beat 1
    /// by that many beats. With `audioOnsets.chroma` (Song mode) and `barPhase`,
    /// the bar lines of a 4/4 take come from `BarPhase`.
    static func track(
        notes: [NoteEvent],
        duration: Double,
        beatsPerBar: Int?,
        downbeatPitchClass: Int? = nil,
        tempoOctave: Int = 0,
        barShift: Int = 0,
        audioOnsets: AudioOnsets? = nil,
        meterMargin: Double = TempoChoice.meterMargin,
        barPhase: Bool = true
    ) -> Result {
        guard duration > 1, notes.count >= 4 else { return Result() }
        let act = activations(notes: notes, duration: duration, downbeatPitchClass: downbeatPitchClass,
                              audioOnsets: audioOnsets)
        let meters = beatsPerBar.map { [$0] } ?? TempoChoice.autoMeters
        var result = TempoChoice.meter(of: decodeMeters(act, meters), margin: meterMargin)

        // Tempo octave: the onsets cannot tell a beat from its subdivision. In
        // a ballad the eighths are as loud as the beats, and below about 125
        // BPM a beat's region (1/16 of it) is wider than a note's evidence (3
        // frames), so the slower grid pays for empty frames and the decoder
        // takes the eighths. After decoding, a Song mode grid of
        // `TempoChoice.slowestHalvedGrid` or faster is halved when the take's
        // slow layers mark only every other grid beat
        // (`TempoChoice.countsSubdivisions`). The half-tempo grid is decoded on
        // those beats: the evidence between them is set aside, so the new grid
        // keeps their phase and does not settle on the off-beats (Country
        // Roads' boom-chick: beat F1 0.88 so, 0.73 decoded freely).
        // Song mode only (its refine pass is the only caller with the audio's
        // chroma): Piano mode's passes and the Home row's thumbnail (notes only)
        // keep the decoder's grid, since a solo pianist's left hand in half
        // notes marks alternate beats at any tempo.
        if audioOnsets?.chroma != nil, result.medianBPM >= TempoChoice.slowestHalvedGrid,
           let parity = TempoChoice.countsSubdivisions(beats: result.beats, notes: notes,
                                                       percussion: audioOnsets?.percussion) {
            let kept = result.beats.enumerated().filter { $0.offset % 2 == parity }.map(\.element)
            let range = octaveRange(of: result, octave: -1)
            result = TempoChoice.meter(of: decodeMeters(Self.only(act, near: kept, reach: 0.25 * 60 / result.medianBPM),
                                                        meters, intervalRange: range, preferenceOctaves: 100),
                                       margin: meterMargin)
        }

        // The user's half / double tempo, from the tempo shown.
        if tempoOctave != 0, result.medianBPM > 0 {
            result = decode(act, beatsPerBar: result.beatsPerBar, intervalRange: octaveRange(of: result, octave: tempoOctave),
                            preferenceOctaves: 100)
        }
        // The model has to keep beating through a lead-in of silence; those
        // beats are extrapolation, not evidence. Keep one beat before the first
        // sound (room for a pickup) and drop the rest.
        let firstSound = notes.map(\.startTime).min() ?? .infinity
        if result.beats.count > 2, firstSound.isFinite {
            let gaps = zip(result.beats.dropFirst(), result.beats).map { $0 - $1 }.sorted()
            let cutoff = firstSound - gaps[gaps.count / 2] - 0.07
            if let keep = result.beats.firstIndex(where: { $0 >= cutoff }), keep > 0 {
                result.beats.removeFirst(keep)
                result.barPositions.removeFirst(keep)
            }
        }
        // Song mode: the bar lines again, from the audio's chord changes (see BarPhase).
        if barPhase, let chroma = audioOnsets?.chroma, BarPhase.meters.contains(result.beatsPerBar) {
            result.barPositions = BarPhase.positions(beats: result.beats, beatsPerBar: result.beatsPerBar,
                                                     notes: notes, chroma: chroma, decoded: result.barPositions,
                                                     downbeatPitchClass: downbeatPitchClass)
        }
        if barShift != 0 {
            let m = result.beatsPerBar
            result.barPositions = result.barPositions.map { (($0 - barShift) % m + m) % m }
        }
        return result
    }

    /// `act` with the evidence further than `reach` seconds from every one of
    /// `beats` set to the floor.
    static func only(_ act: Activations, near beats: [Double], reach: Double) -> Activations {
        var out = Activations(beat: [Float](repeating: 1e-4, count: act.beat.count),
                              down: [Float](repeating: 1e-4, count: act.down.count))
        let r = Int((reach * fps).rounded())
        for t in beats {
            let f = Int((t * fps).rounded())
            let lo = max(0, f - r), hi = min(act.beat.count - 1, f + r)
            guard lo <= hi else { continue }
            for i in lo...hi { out.beat[i] = act.beat[i]; out.down[i] = act.down[i] }
        }
        return out
    }

    /// Every meter decoded in parallel.
    static func decodeMeters(_ act: Activations, _ meters: [Int], intervalRange: ClosedRange<Int>? = nil,
                             preferenceOctaves: Double = 1) -> [Result] {
        var decoded = [Result](repeating: Result(), count: meters.count)
        decoded.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let out = buffer   // each iteration writes only its own slot
            DispatchQueue.concurrentPerform(iterations: meters.count) { i in
                out[i] = decode(act, beatsPerBar: meters[i], intervalRange: intervalRange,
                                preferenceOctaves: preferenceOctaves)
            }
        }
        return decoded
    }

    /// Frames per beat around `result`'s tempo times 2^octave (-25% / +33%).
    static func octaveRange(of result: Result, octave: Int) -> ClosedRange<Int> {
        let target = 60 * fps / (result.medianBPM * pow(2, Double(octave)))
        let lo = max(8, Int((target * 0.75).rounded())), hi = max(lo, Int((target * 1.33).rounded()))
        return lo...hi
    }
}

/// Song mode's bar lines, decided again on the beats the bar-pointer model
/// found, from evidence that does not hang on the fine detail of the notes.
///
/// The bar-pointer decode reads beat 1 from the notes: bass notes and the
/// notes' harmony changes, and a light kick. On real records that evidence
/// is thin where it matters. A bass line that anticipates the bar (Still
/// D.R.E.: the bass comes in on beat 4, and the engine misses its re-strike
/// on 1) or a kick as loud on 3 as on 1 (Never Gonna Give You Up) put beat 1
/// on the wrong beat for a whole song, and where the bar lines were right
/// they rested on so thin a margin that changing which notes the engine kept
/// (a retuned take, another melody) moved them by two beats for a minute or
/// more (Bohemian Rhapsody's rock section, Africa, Viva la Vida).
///
/// Here each beat's evidence that it starts a bar is mostly the audio's own
/// chord change: the tonal part's pitch classes over the beat after it
/// against the beat before it (`OnsetEnvelope.tonalChroma`, the chroma the
/// chord stage reads), which no choice of notes changes. A bass note starting
/// on the beat counts for half as much: on a one-chord vamp whose riff
/// changes notes inside the bar (Superstition's verses) it is the only cue.
/// Each cue is a z-score over the take, clipped at `clip`, so no single beat
/// decides and the scale is the same on every take. A beat-level Viterbi over
/// the bar phase then places the bar lines; they may move by half a bar (a
/// 2/4 bar in 4/4, or a bar two beats long) at `halfBarCost`, which only
/// several bars of evidence pay for (typical evidence is one unit a bar).
///
/// Measured on the Song mode scoreboard's dev songs, all in 4/4, each with
/// four sets of notes (round 2's, with the retune, with the melody change,
/// with both): the bar lines come out the same for every set of notes;
/// downbeat F1 Still D.R.E. 0 -> 1.00, Never Gonna Give You Up 0 -> 0.90,
/// Bohemian Rhapsody 0.75 -> 0.79, Africa 0.87 -> 0.86, the others unchanged.
/// `bassWeight` 0.5-0.6 with `halfBarCost` 8-11 give the same bar lines on
/// all of them; with less bass Superstition's first verse sits two beats off,
/// with more (0.7) Still D.R.E.'s anticipated bass pulls beat 1 to beat 4 on
/// round 2's notes; a cut cost of 12 or more misses Africa's 2/4 bars.
///
/// The user's "note on beat 1" (`downbeatPitchClass`, the Downbeat note
/// setting) is a third cue, at `hintWeight`: where that note is played on
/// beat 1 it places the bar lines, as it does in the bar-pointer model.
///
/// Known limits: where the harmony changes every two beats and nothing else
/// tells beat 1 from beat 3, the choice between them is weak (a funk song of
/// MusicBench's test set comes out two beats off, where the bar-pointer model
/// had it); an arpeggiated accompaniment changes pitch classes on every beat,
/// so the opening of a solo-piano piece can stay two beats off until a 2/4
/// bar (Tools/RealBench/piano44). RealBench reports each section's margin.
/// Other meters keep the bar-pointer model's bar lines: no dev song is in 3
/// or 5, and a 5/4 vamp may change chord inside the bar (3 + 2).
nonisolated enum BarPhase {
    /// Meters whose bar lines this pass decides.
    static let meters: Set<Int> = [4]
    /// A bass note's onset next to the chord change (which counts 1).
    static let bassWeight = 0.5
    /// What moving the bar lines by half a bar costs, in clipped z-scores.
    static let halfBarCost = 10.0
    /// Each cue's z-score is clipped at +-clip.
    static let clip = 2.5
    /// Bass notes are below this pitch (as in `BeatTracker.activations`).
    static let bassCeiling = 55
    /// The user's note on beat 1 (`downbeatPitchClass`), next to the chord
    /// change (which counts 1). It is the player's own word for where the bar
    /// starts, so it outweighs the chord changes: where the note is played
    /// once a bar it places the bar lines even where the chords say
    /// otherwise, and where it is not played the audio's cues decide. At 1
    /// a note on beat 3 against chords changing on beat 1 is a tie.
    static let hintWeight = 2.0

    /// Bar positions for `beats` (0 = beat 1). `decoded` (the bar-pointer
    /// model's) breaks exact ties and is returned when the take has no
    /// evidence at all (silence, a drum solo). `downbeatPitchClass` is the
    /// user's note on beat 1, if any.
    static func positions(beats: [Double], beatsPerBar n: Int, notes: [NoteEvent], chroma: [Float],
                          decoded: [Int], downbeatPitchClass: Int? = nil) -> [Int] {
        guard beats.count >= 2 * n, decoded.count == beats.count else { return decoded }
        guard let ev = evidence(beats: beats, notes: notes, chroma: chroma, downbeatPitchClass: downbeatPitchClass)
        else { return decoded }
        return decode(ev, beatsPerBar: n, prefer: decoded)
    }

    /// Each beat's evidence that it starts a bar, nil when no cue varies.
    static func evidence(beats: [Double], notes: [NoteEvent], chroma: [Float],
                         downbeatPitchClass: Int? = nil) -> [Double]? {
        let change = chordChange(beats: beats, chroma: chroma)
        let bass = bassOnsets(beats: beats, notes: notes)
        let z1 = zScores(change), z2 = zScores(bass)
        let z3 = downbeatPitchClass.flatMap { zScores(hintOnsets(beats: beats, notes: notes, pitchClass: $0)) }
        guard z1 != nil || z2 != nil || z3 != nil else { return nil }
        return (0..<beats.count).map {
            (z1?[$0] ?? 0) + bassWeight * (z2?[$0] ?? 0) + hintWeight * (z3?[$0] ?? 0)
        }
    }

    /// How much the tonal part's pitch classes over the beat after each beat
    /// differ from those over the beat before it: 1 - their correlation (as
    /// `OnsetEnvelope.harmonyChange`). 0 for the first and last beat.
    static func chordChange(beats: [Double], chroma: [Float]) -> [Double] {
        let frames = chroma.count / 12
        let fps = OnsetEnvelope.chromaFPS
        func mean(_ a: Double, _ b: Double) -> [Double] {
            let lo = max(0, Int((a * fps).rounded(.down)))
            let hi = min(frames, max(Int((b * fps).rounded(.up)), lo + 1))
            var v = [Double](repeating: 0, count: 12)
            guard hi > lo else { return v }
            for f in lo..<hi { for pc in 0..<12 { v[pc] += Double(chroma[f * 12 + pc]) } }
            return v.map { $0 / Double(hi - lo) }
        }
        var out = [Double](repeating: 0, count: beats.count)
        guard beats.count > 2, frames > 0 else { return out }
        for i in 1..<(beats.count - 1) {
            out[i] = 1 - correlation(mean(beats[i - 1], beats[i]), mean(beats[i], beats[i + 1]))
        }
        return out
    }

    /// Correlation of two vectors (cosine of their deviations from their own
    /// means); 1 when either is flat, so silence reads as no change.
    static func correlation(_ u: [Double], _ v: [Double]) -> Double {
        let mu = u.reduce(0, +) / Double(u.count), mv = v.reduce(0, +) / Double(v.count)
        var dot = 0.0, nu = 0.0, nv = 0.0
        for k in u.indices {
            let a = u[k] - mu, b = v[k] - mv
            dot += a * b; nu += a * a; nv += b * b
        }
        let norm = (nu * nv).squareRoot()
        return norm > 1e-9 ? dot / norm : 1
    }

    /// Bass notes starting within an eighth of a beat's length of each beat,
    /// each counting 1 plus its length (up to 2 s), as the bar-pointer
    /// model's bass evidence does.
    static func bassOnsets(beats: [Double], notes: [NoteEvent]) -> [Double] {
        onsets(beats: beats, notes: notes.filter { $0.pitch < bassCeiling }, combine: +)
    }

    /// Notes of `pitchClass`, in any octave, starting within an eighth of a
    /// beat's length of each beat: the longest one's 1 plus its length (up to
    /// 2 s), so an octave doubling counts once.
    static func hintOnsets(beats: [Double], notes: [NoteEvent], pitchClass: Int) -> [Double] {
        let pc = ((pitchClass % 12) + 12) % 12
        return onsets(beats: beats, notes: notes.filter { (($0.pitch % 12) + 12) % 12 == pc }, combine: max)
    }

    /// `notes` starting within an eighth of a beat's length of each beat, each
    /// worth 1 plus its length (up to 2 s), combined per beat by `combine`.
    static func onsets(beats: [Double], notes: [NoteEvent], combine: (Double, Double) -> Double) -> [Double] {
        let sorted = notes.sorted { $0.startTime < $1.startTime }
        let starts = sorted.map(\.startTime)
        func firstIndex(atLeast t: Double) -> Int {
            var lo = 0, hi = starts.count
            while lo < hi { let mid = (lo + hi) / 2; if starts[mid] < t { lo = mid + 1 } else { hi = mid } }
            return lo
        }
        return beats.indices.map { i in
            let period = i + 1 < beats.count ? beats[i + 1] - beats[i] : (i > 0 ? beats[i] - beats[i - 1] : 0.5)
            let w = period / 8
            var sum = 0.0, k = firstIndex(atLeast: beats[i] - w)
            while k < sorted.count, starts[k] <= beats[i] + w {
                sum = combine(sum, 1 + min(sorted[k].endTime - sorted[k].startTime, 2))
                k += 1
            }
            return sum
        }
    }

    /// z-scores over the take, clipped at +-`clip`; nil when the values do not vary.
    static func zScores(_ x: [Double]) -> [Double]? {
        guard !x.isEmpty else { return nil }
        let mean = x.reduce(0, +) / Double(x.count)
        let sd = (x.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(x.count)).squareRoot()
        guard sd > 1e-9 else { return nil }
        return x.map { min(max(($0 - mean) / sd, -clip), clip) }
    }

    /// The bar phase path: state = the beat index of a bar line, mod n. A
    /// beat gets its evidence in the state where it is beat 1; the state may
    /// move by half a bar (even meters of 4 or more) at `halfBarCost`.
    /// `prefer` adds a negligible amount where it puts beat 1, so exact ties
    /// keep those bar lines.
    static func decode(_ ev: [Double], beatsPerBar n: Int, halfBarCost cost: Double = halfBarCost,
                       prefer: [Int]? = nil) -> [Int] {
        let count = ev.count
        guard count > 0, n >= 1 else { return [] }
        let half = n >= 4 && n % 2 == 0 ? n / 2 : 0
        let tie = 1e-6
        var value = [Double](repeating: 0, count: n)
        var back = [Int](repeating: 0, count: count * n)
        for i in 0..<count {
            if i > 0, half > 0 {
                var next = value
                for phase in 0..<n {
                    let from = (phase - half + n) % n
                    let moved = value[from] - cost
                    if moved > value[phase] { next[phase] = moved; back[i * n + phase] = from } else { back[i * n + phase] = phase }
                }
                value = next
            } else if i > 0 {
                for phase in 0..<n { back[i * n + phase] = phase }
            }
            // The state whose bar line falls on beat i.
            let phase = i % n
            value[phase] += ev[i]
            if let prefer, prefer[i] == 0 { value[phase] += tie }
        }
        var phase = value.indices.max { value[$0] < value[$1] } ?? 0
        var out = [Int](repeating: 0, count: count)
        for i in stride(from: count - 1, through: 0, by: -1) {
            out[i] = ((i - phase) % n + n) % n
            phase = back[i * n + phase]
        }
        return out
    }

    /// The decision's margin, section by section: for each run of
    /// `barsPerSection` bars, how much more evidence the chosen bar lines
    /// have than the best shift of them by 1 to n - 1 beats, and that shift.
    /// A small margin is a fragile section (RealBench reports them).
    struct Section {
        var firstBeat: Int
        var lastBeat: Int
        var margin: Double
        var runnerUpShift: Int
    }

    /// Bars per section in `sections`.
    static let sectionBars = 8

    static func sections(evidence ev: [Double], positions: [Int], beatsPerBar n: Int,
                         barsPerSection: Int = sectionBars) -> [Section] {
        guard ev.count == positions.count, n >= 1, !ev.isEmpty else { return [] }
        let length = barsPerSection * n
        var out: [Section] = []
        var start = 0
        while start < ev.count {
            let end = min(ev.count, start + length)
            // score[s]: the evidence on the beats that would be beat 1 with
            // every bar line moved s beats later (the beats now at position s).
            var score = [Double](repeating: 0, count: n)
            for i in start..<end { score[((positions[i] % n) + n) % n] += ev[i] }
            let best = n > 1 ? (1..<n).max { score[$0] < score[$1] } : nil
            out.append(Section(firstBeat: start, lastBeat: end - 1,
                               margin: best.map { score[0] - score[$0] } ?? 0, runnerUpShift: best ?? 0))
            start = end
        }
        return out
    }
}

/// The choices between the decoded grids: the meter, and the tempo octave.
nonisolated enum TempoChoice {
    /// 3/4 must beat 4/4 by this share of 4/4's average log-likelihood per
    /// frame. Real waltzes win by 20-30%; a 4/4 take flips to 3/4 only by
    /// noise (0.7% on strummed guitar, 0.7% on a MusicBench pop song).
    static let meterMargin = 0.05
    /// The beats per bar Auto chooses from (4 unless another fits clearly better).
    static let autoMeters = [3, 4, 5]

    /// How many `meterMargin`s a meter must beat 4/4 by. Five is rarer than
    /// three or four, so it needs twice the margin: clip 3 of "semitone
    /// training" (10/8, counted in 5) wins by 13-15% (Piano and Song mode),
    /// while on the 4/4 and 3/4 songs tried (bitmidi dev, MusicBench dev, the
    /// other RealBench recordings) five came within 4% of four at most.
    static func marginScale(beatsPerBar: Int) -> Double {
        beatsPerBar == 5 ? 2 : 1
    }

    /// Meter: 4/4 unless another count fits clearly better. Every decode
    /// explains the same onsets, so a tiny edge is noise (one MusicBench 4/4
    /// song flipped to 3/4 by 0.002 when the note engine changed).
    static func meter(of decoded: [BeatTracker.Result], margin: Double = meterMargin) -> BeatTracker.Result {
        var result = decoded.first { $0.beatsPerBar == 4 } ?? decoded[0]
        let four = result.score
        for other in decoded where other.beatsPerBar != 4 && other.score > result.score {
            if other.score > four + margin * marginScale(beatsPerBar: other.beatsPerBar) * abs(four) { result = other }
        }
        return result
    }

    /// The slowest grid that may be halved, in BPM. Halving is a choice
    /// between two counts of the same music, and it is only a fair one where
    /// the half tempo is as natural a count as the grid: 155 is the geometric
    /// mean of about 110 BPM (the middle of the 100-120 BPM that listeners
    /// tap along to most readily) and its double, so from here up the half
    /// tempo (78 BPM or more, a moderate ballad) is the nearer count, and
    /// below it the grid is. Below it a bass on alternate beats is mostly
    /// just a half-note bass: with a floor of 120 (round 3 of the Song mode
    /// tuning) solo-piano pieces in 4/4 with a half-note left hand at 120-150
    /// BPM, drumless, were halved (beat F1 0.99 -> 0.66, and one went to 5/4).
    /// The grids that counted eighths on the dev takes ran at 162-182 BPM
    /// (Country Roads, MusicBench's acoustic songs). Known cost: a ballad
    /// under 78 BPM counted in eighths keeps the double tempo (Let It Be, 70
    /// BPM, tracks at 140); the ½× button halves it.
    static let slowestHalvedGrid = 155.0
    /// Bass notes are below this pitch (MIDI 52 = E3).
    static let bassCeiling = 52
    /// The bass marks every other grid beat when at least this share of its
    /// notes on the grid (on a beat or halfway between two) fall on the same
    /// alternate beats ...
    static let bassOnOnePhase = 0.65
    /// ... and its notes are about two grid beats apart (the median gap, in
    /// grid beats). A bass once a bar (four or more) marks bars, not beats.
    static let bassSpacing = 1.5..<3.0
    /// A kit's kick and snare: the grid's weaker alternate beats get at least
    /// this share of the stronger ones' hits when every grid beat is a beat
    /// (kick on one, snare on the next), and at most `kitOnOnePhase` when the
    /// grid also counts the off-beats.
    static let kitOnBothPhases: Float = 0.8
    static let kitOnOnePhase: Float = 0.7

    /// Whether a grid counts the music's subdivisions as beats, from the
    /// layers that move once a beat or slower: eighth notes can fill every
    /// grid beat, but a bass line and a kit's kick and snare mark only the
    /// real beats. `BeatTracker.track` asks only in Song mode, and only of a
    /// grid of `slowestHalvedGrid` or faster.
    /// - A kit (`percussion`, on a take with one): kick and snare alike on
    ///   both alternate grid beats keep the grid (rock and pop alternate kick
    ///   and snare from beat to beat); on one of them only, the grid is halved.
    /// - Otherwise the bass: its notes about two grid beats apart, on the same
    ///   alternate grid beats, halve the grid. A waltz's bass, once a bar,
    ///   falls on both alternate beats; a bass on every beat or in eighths
    ///   fills both.
    /// Returns the parity (0 = even, 1 = odd) of the grid beats that are
    /// beats, or nil to keep the grid.
    static func countsSubdivisions(beats: [Double], notes: [NoteEvent], percussion: AudioOnsets.Percussion?) -> Int? {
        guard beats.count > 16 else { return nil }
        let gaps = zip(beats.dropFirst(), beats).map { $0 - $1 }.sorted()
        let gap = gaps[gaps.count / 2]
        guard gap > 0 else { return nil }
        if let kit = percussion, kit.weight > 0, !kit.low.isEmpty, !kit.mid.isEmpty {
            let (ratio, stronger) = kitPhases(beats: beats, kick: kit.low, snare: kit.mid)
            if ratio >= kitOnBothPhases { return nil }
            if ratio <= kitOnOnePhase { return stronger }
        }
        // Bass onsets, one per 80 ms (a doubled or re-struck note counts once).
        var bass: [Double] = []
        for t in notes.filter({ $0.pitch < bassCeiling }).map(\.startTime).sorted()
        where bass.last.map({ t - $0 > 0.08 }) ?? true { bass.append(t) }
        guard bass.count >= 24 else { return nil }
        let spacing = zip(bass.dropFirst(), bass).map { $0 - $1 }.filter { $0 < 2 }.sorted()
        guard spacing.count >= 16, bassSpacing.contains(spacing[spacing.count / 2] / gap) else { return nil }
        // Bass notes on even and odd grid beats, and halfway between two.
        let tolerance = min(0.07, gap / 6)
        var even = 0, odd = 0, between = 0
        var i = 0
        for t in bass {
            while i + 1 < beats.count, beats[i + 1] <= t { i += 1 }
            guard t >= beats[0] - tolerance, i + 1 < beats.count else { continue }
            let a = beats[i], b = beats[i + 1]
            if t - a <= tolerance { if i % 2 == 0 { even += 1 } else { odd += 1 } }
            else if b - t <= tolerance { if (i + 1) % 2 == 0 { even += 1 } else { odd += 1 } }
            else if abs(t - (a + b) / 2) <= tolerance { between += 1 }
        }
        let onGrid = even + odd + between
        guard onGrid >= 12, Double(max(even, odd)) >= bassOnOnePhase * Double(onGrid) else { return nil }
        return even >= odd ? 0 : 1
    }

    /// The kit's hits on the weaker alternate grid beats as a share of those
    /// on the stronger, and the stronger's parity. A beat's hit is its kick
    /// or its snare, whichever is stronger (each envelope scaled to its 90th
    /// percentile, the strongest frame within 50 ms of the beat): a kick on
    /// every beat with the snare on two and four is a hit on every beat.
    static func kitPhases(beats: [Double], kick: [Float], snare: [Float]) -> (ratio: Float, stronger: Int) {
        func scaled(_ x: [Float]) -> [Float] {
            let nonzero = x.filter { $0 > 0 }.sorted()
            guard !nonzero.isEmpty else { return x }
            let p90 = max(nonzero[Int(0.9 * Double(nonzero.count - 1))], 1e-9)
            return x.map { $0 / p90 }
        }
        let k = scaled(kick), s = scaled(snare)
        let reach = Int((0.05 * BeatTracker.fps).rounded())
        var sum: [Float] = [0, 0], count: [Float] = [0, 0]
        for (n, t) in beats.enumerated() {
            let f = Int((t * BeatTracker.fps).rounded())
            let lo = max(0, f - reach), hi = min(min(k.count, s.count) - 1, f + reach)
            guard lo <= hi else { continue }
            sum[n % 2] += max(k[lo...hi].max()!, s[lo...hi].max()!)
            count[n % 2] += 1
        }
        guard count[0] > 0, count[1] > 0 else { return (1, 0) }
        let a = sum[0] / count[0], b = sum[1] / count[1]
        return (max(a, b) > 0 ? min(a, b) / max(a, b) : 1, a >= b ? 0 : 1)
    }
}

/// The audio's own rhythm evidence, which the beat tracker reads next to the
/// notes (`BeatTracker.activations`).
nonisolated struct AudioOnsets: Equatable {
    /// Onset strength at `BeatTracker.fps` (`OnsetEnvelope`): the whole take's
    /// in Piano mode, the tonal part's in Any-instrument mode.
    var onsets: [Float]
    /// Any-instrument takes with a kit (`OnsetEnvelope.kitShare`).
    var percussion: Percussion? = nil
    /// Any-instrument takes: how much the tonal part's pitch classes change at
    /// each frame (`OnsetEnvelope.harmonyChange`). nil in Piano mode.
    var harmony: [Float]? = nil
    /// Any-instrument takes: the tonal part's pitch classes, 12 values per
    /// frame at `OnsetEnvelope.chromaFPS` (`OnsetEnvelope.tonalChroma`), which
    /// the chord stage reads beside the notes. The beat tracker reads its
    /// chord changes for the bar lines once the beats are found (`BarPhase`),
    /// not for the beats. nil in Piano mode.
    var chroma: [Float]? = nil

    /// A kit's rhythm without transcribing it: where the take's percussive
    /// part (HPSS) attacks, and where its lowest bands, the kick, do.
    struct Percussion: Equatable {
        /// The percussive part's onset strength over every FFT bin.
        var onsets: [Float]
        /// The same over its 30-150 Hz bands.
        var low: [Float]
        /// The same over its 150-2000 Hz bands: the snare, without the hats
        /// and cymbals above.
        var mid: [Float] = []
        /// How much the beat tracker trusts it, 0-1: 1 on a drum-heavy take,
        /// less on a lighter kit (`OnsetEnvelope.kitWeight`).
        var weight: Float = 1
    }
}
