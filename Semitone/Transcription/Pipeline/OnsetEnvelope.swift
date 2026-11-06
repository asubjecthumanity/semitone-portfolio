import Foundation
import Accelerate

/// The audio's onset strength at `BeatTracker.fps` frames a second: positive
/// spectral flux of the log-compressed magnitude spectrum. It shows every
/// attack, including those no note engine wrote down (strums merged into one
/// note, re-picked chords, a drum kit, which the app doesn't transcribe), so
/// the beat tracker can find the beat's phase from the sound itself.
nonisolated enum OnsetEnvelope {
    /// Bands per octave for the any-instrument mode's envelope, which reads the
    /// tonal part of the take (TakePipeline).
    static let tonalBandsPerOctave = 3.0

    /// From this percussive share (`SourceProfile.percussiveShare`) on, an
    /// any-instrument take is drum-heavy: the beat tracker reads its
    /// percussive part (`AudioOnsets.Percussion`) in full. MusicBench's funk
    /// songs reach 0.24-0.28; its other kits and the Slakh band 0.05-0.15; the
    /// real drumless recordings up to 0.09 (strummed guitar). The share
    /// measures attacks, not a kit: Patience's General MIDI render (Ableton
    /// dev; strummed nylon guitar and plucked bass, no drums) reaches 0.22 and
    /// gets the cue, which costs it beats 0.59 to 0.54 and chord root 0.50 to
    /// 0.47. (VoiceSplitter also reads this share: a take this percussive is
    /// not one solo line.)
    static let drumHeavyShare = 0.2
    /// Above this share a take has some kit, and the beat tracker reads its
    /// percussive part at a weight that rises with the share, from 0 here to
    /// full at `drumHeavyShare` (`kitWeight`); the drumless recordings stay
    /// under it (up to 0.09). An on/off gate at 0.2 left a lighter kit out
    /// entirely: Viva la Vida (0.149) and Bohemian Rhapsody (0.166) had only
    /// their notes and tonal onsets, and lost the beat for whole sections
    /// (Viva's bridge on the off-beats, Bohemian's opera section and coda at
    /// double tempo). A light kit at full weight
    /// is too much: MusicBench's rock song (0.15) fell to half tempo with the
    /// gate at 0.15; at the half weight it now gets, it keeps its tempo. On
    /// the bitmidi dev songs any start from 0.05 to 0.13 gives the same grids;
    /// from 0, MusicBench's jazz song (0.07) halves.
    static let kitShare = 0.1

    /// How much the beat tracker trusts a take's percussive part, 0-1, from
    /// its percussive share: 0 up to `kitShare`, rising in a straight line to
    /// 1 at `drumHeavyShare`.
    static func kitWeight(share: Double) -> Float {
        Float(min(max((share - kitShare) / (drumHeavyShare - kitShare), 0), 1))
    }
    /// The percussive part's kick band, Hz.
    static let kickBand = 30.0...150.0
    /// The percussive part's snare band, Hz: the drum's body and crack, below
    /// the hats and cymbals.
    static let snareBand = 150.0...2000.0

    /// The any-instrument rhythm evidence of a take split into its tonal and
    /// percussive parts: the tonal part's onsets, every octave weighted alike
    /// (summed over linear FFT bins the flux follows whatever fills the many
    /// bins above 2 kHz: hats and cymbals in eighths and sixteenths, pick and
    /// breath noise; pooled into octave bands it follows the attacks of the
    /// notes), and its chord changes (`harmonyChange`), plus the percussive
    /// part's onsets when the take has a kit, weighted by its percussive share
    /// (`kitWeight`).
    static func music(_ parts: HarmonicPercussive.Output, percussiveShare: Double,
                      sampleRate: Double) -> AudioOnsets {
        let tonal = compute(parts.harmonic, sampleRate: sampleRate, bandsPerOctave: tonalBandsPerOctave)
        let harmony = harmonyChange(parts.harmonic, sampleRate: sampleRate)
        let weight = kitWeight(share: percussiveShare)
        guard weight > 0 else { return AudioOnsets(onsets: tonal, harmony: harmony) }
        let percussion = AudioOnsets.Percussion(
            onsets: compute(parts.percussive, sampleRate: sampleRate),
            low: compute(parts.percussive, sampleRate: sampleRate, bandsPerOctave: tonalBandsPerOctave,
                         low: kickBand.lowerBound, high: kickBand.upperBound),
            mid: compute(parts.percussive, sampleRate: sampleRate, bandsPerOctave: tonalBandsPerOctave,
                         low: snareBand.lowerBound, high: snareBand.upperBound),
            weight: weight)
        return AudioOnsets(onsets: tonal, percussion: percussion, harmony: harmony)
    }

    /// Seconds of audio on each side of a frame that `harmonyChange` compares:
    /// about half a beat, so a chord that lasts a beat or more shows as one
    /// change, and an eighth-note anticipation is still close to its beat.
    static let harmonyWindow = 0.25

    /// How much the pitch-class content changes at each frame, at
    /// `BeatTracker.fps`: 1 - the correlation of the mean chroma over
    /// `harmonyWindow` before the frame with the mean over `harmonyWindow`
    /// after it (0 = the same chord, up to 2). Read from the audio, so it hears
    /// the chord changes the note engine missed or put in the wrong octave
    /// (a sampled riff, a pad, a choir). Chroma: a 4096-point FFT of the tonal
    /// part, log-compressed, bins from 50 Hz to 2 kHz each added to its nearest
    /// pitch class.
    static func harmonyChange(_ x: [Float], sampleRate: Double) -> [Float] {
        let n = 4096, half = n / 2
        let step = sampleRate / BeatTracker.fps
        guard x.count > n, step >= 1 else { return [] }
        let log2n = vDSP_Length(12)
        guard let fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(fft) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var frame = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
        var mag = [Float](repeating: 0, count: half)
        let binHz = sampleRate / Double(n)
        let lo = max(1, Int((50 / binHz).rounded(.up))), hi = min(half - 1, Int(2000 / binHz))
        guard lo < hi else { return [] }
        let pitchClass = (lo...hi).map { k -> Int in
            let midi = 69 + 12 * log2(Double(k) * binHz / 440)
            return ((Int(midi.rounded()) % 12) + 12) % 12
        }
        // Frames as in `compute`: frame i is centred at i * step + n / 2.
        let frames = Int(Double(x.count - n) / step) + 1
        let lead = Int(Double(n) / (2 * step))
        let total = frames + lead
        // Running sums of the chroma, so each window's mean is one subtraction.
        var cumulative = [Double](repeating: 0, count: (total + 1) * 12)
        var gain: Float = 100, one: Float = 1
        for i in 0..<frames {
            let start = min(Int((Double(i) * step).rounded()), x.count - n)
            x.withUnsafeBufferPointer { vDSP_vmul($0.baseAddress! + start, 1, window, 1, &frame, 1, vDSP_Length(n)) }
            re.withUnsafeMutableBufferPointer { r in
                im.withUnsafeMutableBufferPointer { m in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: m.baseAddress!)
                    frame.withUnsafeBufferPointer {
                        $0.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &mag, 1, vDSP_Length(half))
                }
            }
            // log(1 + 100 |X|)
            vDSP_vsmsa(mag, 1, &gain, &one, &mag, 1, vDSP_Length(half))
            var count = Int32(half)
            vvlogf(&mag, mag, &count)
            var chroma = [Double](repeating: 0, count: 12)
            for (j, pc) in pitchClass.enumerated() { chroma[pc] += Double(mag[lo + j]) }
            let row = (i + lead + 1) * 12
            for pc in 0..<12 { cumulative[row + pc] = chroma[pc] }
        }
        for t in 1...total { for pc in 0..<12 { cumulative[t * 12 + pc] += cumulative[(t - 1) * 12 + pc] } }

        let w = max(1, Int((harmonyWindow * BeatTracker.fps).rounded()))
        var out = [Float](repeating: 0, count: total)
        guard total > 2 * w else { return out }
        var before = [Double](repeating: 0, count: 12), after = [Double](repeating: 0, count: 12)
        for t in w..<(total - w) {
            for pc in 0..<12 {
                before[pc] = cumulative[t * 12 + pc] - cumulative[(t - w) * 12 + pc]
                after[pc] = cumulative[(t + w) * 12 + pc] - cumulative[t * 12 + pc]
            }
            let meanBefore = before.reduce(0, +) / 12, meanAfter = after.reduce(0, +) / 12
            var dot = 0.0, normBefore = 0.0, normAfter = 0.0
            for pc in 0..<12 {
                let u = before[pc] - meanBefore, v = after[pc] - meanAfter
                dot += u * v; normBefore += u * u; normAfter += v * v
            }
            // Near-silence on either side says nothing.
            if normBefore > 1e-6, normAfter > 1e-6 { out[t] = Float(1 - dot / (normBefore * normAfter).squareRoot()) }
        }
        return out
    }

    /// Frames per second of `tonalChroma`.
    static let chromaFPS = 20.0
    /// MIDI pitches `tonalChroma` reads: E2 to E6. Lower, a 4096-point FFT
    /// cannot tell semitones apart; higher, overtones outweigh notes.
    static let chromaPitches = 40...88

    /// The pitch classes the tonal part sounds, for the chord stage (Song
    /// mode): 12 values per frame at `chromaFPS`, frame i centred at
    /// i / chromaFPS s. Each frame's 4096-point magnitude spectrum gives
    /// every semitone of `chromaPitches` its strongest bin, and the semitones
    /// add up per pitch class. The semitones are centred `tuningCents(t)`
    /// cents from A440 (the take's tuning, `TuningEstimate.namingOffset(at:)`),
    /// so a recording 48 cents flat is read in the semitones its notes are
    /// named in, not smeared over two. Magnitudes stay linear: a log
    /// scale lifts overtones and noise to nearly the level of the notes
    /// (on the Song mode scoreboard's dev songs the chords read from this
    /// chroma alone scored 0.40 with log(1 + 10x), 0.67 linear).
    static func tonalChroma(_ x: [Float], sampleRate: Double,
                            tuningCents: (Double) -> Double = { _ in 0 }) -> [Float] {
        let n = 4096, half = n / 2
        let frames = Int(Double(x.count) / sampleRate * chromaFPS)
        guard frames > 0, x.count > n else { return [] }
        let log2n = vDSP_Length(12)
        guard let fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(fft) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        let binHz = sampleRate / Double(n)
        // Semitone bands (first bin, last bin, pitch class) for a tuning offset in cents.
        func bands(_ cents: Double) -> [(Int, Int, Int)] {
            chromaPitches.compactMap { p in
                func bin(_ m: Double) -> Double { 440 * pow(2, (m - 69 + cents / 100) / 12) / binHz }
                let lo = Int(bin(Double(p) - 0.5).rounded(.up)), hi = Int(bin(Double(p) + 0.5).rounded(.down))
                guard hi < half - 1 else { return nil }
                return (max(1, min(lo, hi)), max(lo, hi), p % 12)
            }
        }
        var cache: [Int: [(Int, Int, Int)]] = [:]
        var frame = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
        var mag = [Float](repeating: 0, count: half)
        var out = [Float](repeating: 0, count: frames * 12)
        for i in 0..<frames {
            let t = Double(i) / chromaFPS
            let start = Int((t * sampleRate).rounded()) - half
            // The frame, zero-padded at the take's ends.
            let a = max(0, -start), b = min(n, x.count - start)
            frame.withUnsafeMutableBufferPointer { f in
                f.update(repeating: 0)
                guard b > a else { return }
                x.withUnsafeBufferPointer { src in
                    window.withUnsafeBufferPointer { w in
                        vDSP_vmul(src.baseAddress! + start + a, 1, w.baseAddress! + a, 1, f.baseAddress! + a, 1, vDSP_Length(b - a))
                    }
                }
            }
            re.withUnsafeMutableBufferPointer { r in
                im.withUnsafeMutableBufferPointer { m in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: m.baseAddress!)
                    frame.withUnsafeBufferPointer {
                        $0.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &mag, 1, vDSP_Length(half))
                }
            }
            let key = Int(tuningCents(t).rounded())
            if cache[key] == nil { cache[key] = bands(Double(key)) }
            for (lo, hi, pc) in cache[key]! {
                var peak: Float = 0
                for k in lo...hi { peak = max(peak, mag[k]) }
                out[i * 12 + pc] += peak
            }
        }
        return out
    }

    /// - Parameters:
    ///   - bandsPerOctave: nil sums the flux over every FFT bin, where the many
    ///     bins above 2 kHz (cymbals, hats, breath, string noise) weigh most. A
    ///     value first pools the bins into that many log-spaced bands per octave
    ///     from `low` to `high` Hz, so every octave counts alike.
    static func compute(_ x: [Float], sampleRate: Double, bandsPerOctave: Double? = nil,
                        low: Double = 30, high: Double = 11000) -> [Float] {
        let n = 1024, half = n / 2
        // Frames start at exact multiples of 1 / fps: at 22050 Hz the hop is
        // 220.5 samples, and a whole-sample hop (221) drifted 0.23% late, so a
        // 4-minute take's last beats were scored against audio half a second off.
        let step = sampleRate / BeatTracker.fps
        guard x.count > n, step >= 1 else { return [] }
        let log2n = vDSP_Length(10)
        guard let fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(fft) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var frame = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
        var mag = [Float](repeating: 0, count: half)
        let edges = bandsPerOctave.map {
            bandEdges(bins: half, binHz: sampleRate / Double(n), bandsPerOctave: $0, low: low, high: high)
        }
        let width = edges.map { $0.count - 1 } ?? half
        var level = [Float](repeating: 0, count: width), previous = [Float](repeating: 0, count: width)
        var diff = [Float](repeating: 0, count: width)
        let frames = Int(Double(x.count - n) / step) + 1
        let lead = Int(Double(n) / (2 * step))   // frame i is centred at i * step + n / 2
        var out = [Float](repeating: 0, count: frames + lead)
        var zero: Float = 0
        for i in 0..<frames {
            let start = min(Int((Double(i) * step).rounded()), x.count - n)
            x.withUnsafeBufferPointer { vDSP_vmul($0.baseAddress! + start, 1, window, 1, &frame, 1, vDSP_Length(n)) }
            re.withUnsafeMutableBufferPointer { r in
                im.withUnsafeMutableBufferPointer { m in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: m.baseAddress!)
                    frame.withUnsafeBufferPointer {
                        $0.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &mag, 1, vDSP_Length(half))
                }
            }
            if let edges {
                // Each band's mean magnitude.
                mag.withUnsafeBufferPointer { m in
                    for b in 0..<width {
                        var sum: Float = 0
                        vDSP_sve(m.baseAddress! + edges[b], 1, &sum, vDSP_Length(edges[b + 1] - edges[b]))
                        level[b] = sum / Float(edges[b + 1] - edges[b])
                    }
                }
            } else {
                level = mag
            }
            // log(1 + 100 |X|)
            var gain: Float = 100, one: Float = 1
            vDSP_vsmsa(level, 1, &gain, &one, &level, 1, vDSP_Length(width))
            var count = Int32(width)
            vvlogf(&level, level, &count)
            if i > 0 {
                vDSP_vsub(previous, 1, level, 1, &diff, 1, vDSP_Length(width))
                vDSP_vthres(diff, 1, &zero, &diff, 1, vDSP_Length(width))
                var sum: Float = 0
                vDSP_sve(diff, 1, &sum, vDSP_Length(width))
                out[i + lead] = sum
            }
            swap(&level, &previous)
        }
        // Subtract a local mean (0.5 s) so sustained loudness doesn't count.
        let mean = movingAverage(out, radius: Int(BeatTracker.fps / 4))
        return zip(out, mean).map { max($0 - $1, 0) }
    }

    /// Bin edges of log-spaced bands, `bandsPerOctave` to the octave from `low`
    /// to `high` Hz. Bands narrower than a bin merge with the next, so every
    /// band holds at least one bin.
    static func bandEdges(bins: Int, binHz: Double, bandsPerOctave: Double,
                          low: Double = 30, high: Double = 11000) -> [Int] {
        var edges: [Int] = []
        var f = low
        while f < high {
            let b = min(bins, Int((f / binHz).rounded()))
            if edges.last.map({ b > $0 }) ?? true { edges.append(b) }
            f *= pow(2, 1 / bandsPerOctave)
        }
        let top = min(bins, Int((high / binHz).rounded()))
        if let last = edges.last, top > last { edges.append(top) }
        return edges.count >= 2 ? edges : [0, bins]
    }

    /// Mean of `x` over a centred window of 2 * radius + 1 frames (zero padded).
    static func movingAverage(_ x: [Float], radius: Int) -> [Float] {
        let t = x.count, m = max(1, radius)
        guard t > 0 else { return [] }
        var out = [Float](repeating: 0, count: t)
        var padded = [Float](repeating: 0, count: t + 2 * m)
        padded.withUnsafeMutableBufferPointer { p in
            x.withUnsafeBufferPointer { (p.baseAddress! + m).update(from: $0.baseAddress!, count: t) }
            out.withUnsafeMutableBufferPointer {
                vDSP_vswsum(p.baseAddress!, 1, $0.baseAddress!, 1, vDSP_Length(t), vDSP_Length(2 * m + 1))
            }
        }
        var inv = 1 / Float(2 * m + 1)
        vDSP_vsmul(out, 1, &inv, &out, 1, vDSP_Length(t))
        return out
    }
}
