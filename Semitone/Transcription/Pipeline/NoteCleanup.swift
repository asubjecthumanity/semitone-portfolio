import Foundation
import Accelerate

/// Stage 3b (any-instrument mode): every note must have an attack at its own
/// pitch. A note whose pitch gains no new energy where it starts continues a
/// note already sounding there, or echoes another note, and is merged into the
/// note before it or dropped. A Basic Pitch note that started late moves to
/// its attack.
///
/// Why: sustained synths with sidechain pumping, an LFO or tremolo swell and
/// dip while a key is held, and both engines read the swells as new notes.
/// "Re-onset inside a held true note" was the largest false-positive cause on
/// the Ableton songs (112 of 202 on In The Rain's keyed tracks, 263 of 587 on
/// Patience). Basic Pitch's late duplicates and harmonic ghosts also sit on a
/// pitch that is already sounding. A real note, struck, plucked, bowed or sung,
/// raises the level of its own harmonics within a few tens of milliseconds; a
/// swell of a held note does not, or far less. The check reads the audio, not
/// either engine, so it judges both alike.
///
/// Notes both engines start at the same moment need no attack: on the
/// benchmark songs 97% of those were right. They are only merged with a note
/// of their pitch that starts within `onsetTolerance` (one attack read twice).
nonisolated enum NoteCleanup {
    struct Settings: Equatable {
        /// Off keeps the engines' notes as they are.
        var enabled = true
        /// Minimum attack strength (`PitchAttackMeter`) for a note only Basic
        /// Pitch heard. On the dev songs this one number told right from wrong
        /// notes with 0.85 AUC (notes of a pitch heard before), and 1.1 was the
        /// best cut for onset F1 (0.9 and 1.3 within 0.005).
        var minAttack: Float = 1.1
        /// ... for a note Transkun started. Its onsets are more often right
        /// (a guitar or piano re-strike in a dense mix is quiet at its own
        /// pitch), so it needs less.
        var minAttackTranskun: Float = 0.8
        /// A note Transkun started where the note before it at its pitch
        /// still rang (the fused note was held up to this onset: the preview
        /// heard it ringing on, and Transkun, which ends a note where its key
        /// is struck again, heard a new stroke) needs only this share of its
        /// threshold. A string re-struck while it rings rises little at its
        /// own pitch in a full mix. Of the notes the full threshold removed
        /// on the dev songs, such notes with at least half of it were real
        /// 17 times in 20 on the two guitar songs (Angie, MusicBench's nylon
        /// guitar) and 2 times in 18 on the others (synth pads that Transkun
        /// splits). At half the threshold the nylon guitar's recall rises
        /// 0.015 and its onset F1 0.008; the Ableton songs' F1 falls 0.001.
        var ringingRestrike: Float = 0.5
        /// A note without an attack that starts within this long (s) of the
        /// end of the note before it at the same pitch extends that note; one
        /// starting later is dropped. Extending over longer gaps found more
        /// held notes but made notes so long that the part split mislabels
        /// what sounds under them (Angie's part accuracy fell 0.06 at 2 s).
        var mergeGap = 0.6
        /// Two notes of one pitch starting closer than this (s) are one attack
        /// read twice (Basic Pitch's onset 50-150 ms off Transkun's, or a
        /// split note): the one with the stronger attack stays. Measured from
        /// the first onset of such a run, so a tremolo is not chained into one
        /// note; and two notes both engines started more than
        /// `onsetTolerance` apart are two attacks (fast repeats).
        var sameAttack = 0.1
        /// Two engines "heard the same onset" within this distance (s).
        var onsetTolerance = 0.05
        /// A note only Basic Pitch heard that has no attack at its onset moves
        /// to the strongest attack of its pitch up to `retimeEarlier` (s)
        /// before it, if that one reaches `retimeMinAttack`, instead of being
        /// merged or dropped. Basic Pitch writes some onsets 50-150 ms late
        /// (low notes, soft attacks; four times as often late as early on the
        /// dev songs), and a late onset scores as a wrong note. Transkun's
        /// onsets are on time: of its failed notes that found an attack nearby,
        /// 5 in 86 were real, so its notes are not moved.
        var retime = true
        var retimeEarlier = 0.15
        var retimeMinAttack: Float = 1.5
        /// ... and only a note at least this long (s). Ghosts and swells are
        /// short; a note Basic Pitch heard ring on is real even when it noticed
        /// it late. On the dev songs moved notes under 0.3 s were wrong two
        /// times in three, longer ones right two times in three.
        var retimeMinDuration = 0.3
        var meter = PitchAttackMeter.Settings()
    }

    /// What `verify` did, for logs and benchmarks.
    struct Report: Equatable {
        var checked = 0
        var merged = 0
        var dropped = 0
        var duplicates = 0
        var retimed = 0
        var summary: String {
            "checked \(checked), merged \(merged), dropped \(dropped), duplicates \(duplicates), retimed \(retimed)"
        }
    }

    /// `notes` with every unconfirmed note checked for an attack at its pitch.
    /// - Parameters:
    ///   - audio22k: the mix the notes were heard in (22.05 kHz). The attack
    ///     check reads it: separating the drums also softens plucked and
    ///     struck attacks.
    ///   - tonal22k: the take's harmonic part (HPSS), where a late onset looks
    ///     for its attack. A kick under a bass note otherwise lends low ghost
    ///     notes an attack, and they slip under the real bass line. nil
    ///     searches the mix.
    ///   - transkun: Transkun's own notes (empty when it did not run or was
    ///     rejected). A note it started needs `minAttackTranskun`.
    ///   - basicPitch: the quick Basic Pitch notes. A note both engines
    ///     started is kept unchecked.
    ///   - tuningCents: the take's offset from A440 (InputConditioner).
    static func verify(_ notes: [NoteEvent], audio22k: [Float], tonal22k: [Float]? = nil,
                       transkun: [NoteEvent], basicPitch: [NoteEvent], tuningCents: Double = 0,
                       settings: Settings = Settings()) -> (notes: [NoteEvent], report: Report) {
        guard settings.enabled, !notes.isEmpty,
              let meter = PitchAttackMeter(audio: audio22k, sampleRate: BPConstants.sampleRate,
                                           tuningCents: tuningCents, settings: settings.meter) else { return (notes, Report()) }
        let searchMeter = tonal22k.flatMap {
            PitchAttackMeter(audio: $0, sampleRate: BPConstants.sampleRate, tuningCents: tuningCents, settings: settings.meter)
        } ?? meter
        let byTranskun = OnsetIndex(transkun), byBasicPitch = OnsetIndex(basicPitch)
        let tolerance = settings.onsetTolerance

        // Measure in time order, so the meters' spectra are shared by a chord
        // and freed once passed.
        let order = notes.indices.sorted { notes[$0].startTime < notes[$1].startTime }
        var attack = [Float](repeating: 0, count: notes.count)
        var threshold = [Float](repeating: 0, count: notes.count)
        var confirmed = [Bool](repeating: false, count: notes.count)
        var struck = [Bool](repeating: false, count: notes.count)
        var start = notes.map(\.startTime)
        var stats = Report()
        for i in order {
            let n = notes[i]
            struck[i] = byTranskun.has(n.pitch, near: n.startTime, tolerance: tolerance)
            confirmed[i] = struck[i] && byBasicPitch.has(n.pitch, near: n.startTime, tolerance: tolerance)
            threshold[i] = struck[i] ? settings.minAttackTranskun : settings.minAttack
            meter.release(before: n.startTime - settings.retimeEarlier)
            if searchMeter !== meter { searchMeter.release(before: n.startTime - settings.retimeEarlier) }
            attack[i] = meter.attack(pitch: n.pitch, at: n.startTime)
            if settings.retime, !struck[i], attack[i] < threshold[i], n.endTime - n.startTime >= settings.retimeMinDuration,
               let found = searchMeter.strongestAttack(pitch: n.pitch, from: n.startTime - settings.retimeEarlier,
                                                       to: n.startTime),
               found.strength >= settings.retimeMinAttack {
                start[i] = found.time
                attack[i] = found.strength
                stats.retimed += 1
            }
        }

        var byPitch: [Int: [Int]] = [:]
        for i in order { byPitch[notes[i].pitch, default: []].append(i) }
        var out: [NoteEvent] = []
        out.reserveCapacity(notes.count)
        for pitch in byPitch.keys.sorted() {
            // Kept notes of this pitch: the note whose onset (and attack) each
            // carries, its end time after merges, and the first onset of the
            // notes merged into it as one attack.
            var kept: [(index: Int, end: Double, first: Double)] = []
            for i in byPitch[pitch]!.sorted(by: { start[$0] < start[$1] }) {
                let n = notes[i]
                if !confirmed[i] { stats.checked += 1 }
                if let last = kept.last, start[i] - last.first < settings.sameAttack,
                   !(confirmed[i] && confirmed[last.index] && start[i] - start[last.index] > settings.onsetTolerance) {
                    // One attack read twice: keep the confirmed one, else the stronger.
                    let j = last.index
                    let replace = confirmed[i] != confirmed[j] ? confirmed[i] : attack[i] > attack[j]
                    kept[kept.count - 1] = (replace ? i : j, max(last.end, n.endTime), last.first)
                    stats.duplicates += 1
                    continue
                }
                let ringing = struck[i] && kept.last.map { abs($0.end - start[i]) < 0.002 } == true
                if !confirmed[i], attack[i] < threshold[i] * (ringing ? settings.ringingRestrike : 1) {
                    if let last = kept.last, start[i] - last.end <= settings.mergeGap {
                        kept[kept.count - 1].end = max(last.end, n.endTime)
                        stats.merged += 1
                    } else {
                        stats.dropped += 1
                    }
                    continue
                }
                kept.append((i, n.endTime, start[i]))
            }
            for k in kept {
                let n = notes[k.index], onset = start[k.index]
                out.append(NoteEvent(startTime: onset, endTime: max(k.end, onset + settings.sameAttack), pitch: n.pitch,
                                     amplitude: n.amplitude, voice: n.voice))
            }
        }
        return (out.sorted { ($0.startTime, $0.pitch) < ($1.startTime, $1.pitch) }, stats)
    }

    /// Onset times per pitch, for "did this engine start a note here".
    private struct OnsetIndex {
        var starts: [Int: [Double]] = [:]

        init(_ notes: [NoteEvent]) {
            for n in notes { starts[n.pitch, default: []].append(n.startTime) }
            for k in starts.keys { starts[k]!.sort() }
        }

        func has(_ pitch: Int, near t: Double, tolerance: Double) -> Bool {
            guard let s = starts[pitch] else { return false }
            var lo = 0, hi = s.count
            while lo < hi { let m = (lo + hi) / 2; if s[m] < t - tolerance { lo = m + 1 } else { hi = m } }
            return lo < s.count && s[lo] <= t + tolerance
        }
    }
}

/// How sharply one pitch's harmonics rise at a moment: the positive spectral
/// flux of the log magnitude, summed over the pitch's first harmonics (each a
/// band half a semitone either side), at its peak in a short window. Only the
/// frames around the asked moments are transformed (8 FFTs of 2048 points per
/// onset, shared by the notes of a chord), so a take costs a fraction of a
/// Basic Pitch pass.
nonisolated final class PitchAttackMeter {
    struct Settings: Equatable {
        /// FFT length and hop at 22.05 kHz: 93 ms windows (a semitone is
        /// resolved from about G3 up; lower notes are read on their upper
        /// harmonics) every 11.6 ms, Basic Pitch's frame rate.
        var fftSize = 2048
        var hop = 256
        /// Harmonics summed. Six told right from wrong notes better than one,
        /// two or four: a low or masked fundamental says little, and timbres
        /// differ in which partials carry the attack.
        var harmonics = 6
        /// The window searched for the attack, before and after the onset (s):
        /// the engines' onsets land up to a few frames either side of it.
        var before = 0.03
        var after = 0.05
        /// The take is scaled to this RMS first, so the thresholds don't
        /// depend on the recording level.
        var referenceRMS: Float = 0.1
        /// The flux peaks this long before the onset written in the benchmark
        /// keys (median over the dev songs' notes, 3-23 ms by song): the window
        /// hears the attack before its centre reaches it.
        var attackLag = 0.012
    }

    private let x: [Float]
    private let settings: Settings
    private let sampleRate: Double
    private let tuning: Double
    private let fft: FFTSetup
    private let log2n: vDSP_Length
    private var window: [Float]
    /// Magnitude spectra by frame index, until `release` frees them.
    private var cache: [Int: [Float]] = [:]
    private var re: [Float], im: [Float], buffer: [Float]

    init?(audio: [Float], sampleRate: Double, tuningCents: Double = 0, settings: Settings = Settings()) {
        let n = settings.fftSize
        guard n >= 256, n & (n - 1) == 0, settings.hop > 0, audio.count > n,
              let setup = vDSP_create_fftsetup(vDSP_Length(n.trailingZeroBitCount), FFTRadix(kFFTRadix2)) else { return nil }
        fft = setup
        log2n = vDSP_Length(n.trailingZeroBitCount)
        x = audio
        self.settings = settings
        self.sampleRate = sampleRate
        tuning = tuningCents
        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        // Scale the window by the level correction, so every spectrum comes out normalized.
        var rms: Float = 0
        vDSP_rmsqv(audio, 1, &rms, vDSP_Length(audio.count))
        var gain = rms > 1e-6 ? settings.referenceRMS / rms : 1
        vDSP_vsmul(window, 1, &gain, &window, 1, vDSP_Length(n))
        re = [Float](repeating: 0, count: n / 2)
        im = [Float](repeating: 0, count: n / 2)
        buffer = [Float](repeating: 0, count: n)
    }

    deinit { vDSP_destroy_fftsetup(fft) }

    /// Attack strength of `pitch` (MIDI) at `time` (s): the flux peak in the
    /// window `before`...`after` around it.
    func attack(pitch: Int, at time: Double) -> Float {
        let hopSeconds = Double(settings.hop) / sampleRate
        let centre = frame(at: time)
        let frames = (centre - Int(settings.before / hopSeconds))...(centre + Int(settings.after / hopSeconds))
        return peak(pitch: pitch, frames: frames)?.flux ?? 0
    }

    /// The strongest attack of `pitch` between two times: its onset time
    /// (`attackLag` after the flux peak) and strength.
    func strongestAttack(pitch: Int, from a: Double, to b: Double) -> (time: Double, strength: Float)? {
        let first = frame(at: a), last = max(first, frame(at: b))
        guard let p = peak(pitch: pitch, frames: first...last) else { return nil }
        let centre = (Double(p.frame * settings.hop) + Double(settings.fftSize) / 2) / sampleRate
        return (centre + settings.attackLag, p.flux)
    }

    /// Frees the spectra of frames that end before `time`. Ask about moments
    /// in time order and release behind them, and only a few frames are held.
    func release(before time: Double) {
        let first = frame(at: time) - 1
        for k in cache.keys where k < first { cache[k] = nil }
    }

    /// The frame centred at or just before `time` (frame i is centred at i * hop + fftSize / 2).
    private func frame(at time: Double) -> Int {
        Int(((time * sampleRate - Double(settings.fftSize) / 2) / Double(settings.hop)).rounded(.down))
    }

    /// The largest summed positive change of the harmonic levels from frame
    /// f - 1 to f, over f in `frames`; nil for a pitch with no band below Nyquist.
    private func peak(pitch: Int, frames: ClosedRange<Int>) -> (frame: Int, flux: Float)? {
        let bands = harmonicBands(pitch)
        guard !bands.isEmpty else { return nil }
        var previous = levels(frame: frames.lowerBound - 1, bands: bands)
        var best: (frame: Int, flux: Float) = (frames.lowerBound, 0)
        for f in frames {
            let current = levels(frame: f, bands: bands)
            var flux: Float = 0
            for b in 0..<bands.count { flux += max(0, current[b] - previous[b]) }
            if flux > best.flux { best = (f, flux) }
            previous = current
        }
        return best
    }

    /// log(1 + 10 |X|) of each band's strongest bin in frame `f`.
    private func levels(frame f: Int, bands: [(Int, Int)]) -> [Float] {
        let spectrum = magnitudes(frame: f)
        return spectrum.withUnsafeBufferPointer { m in
            bands.map { band in
                var v: Float = 0
                vDSP_maxv(m.baseAddress! + band.0, 1, &v, vDSP_Length(band.1 - band.0 + 1))
                return log(1 + 10 * v)
            }
        }
    }

    /// Bin ranges (inclusive) of the pitch's harmonics below Nyquist.
    private func harmonicBands(_ pitch: Int) -> [(Int, Int)] {
        let half = settings.fftSize / 2
        let binHz = sampleRate / Double(settings.fftSize)
        let f0 = 440 * pow(2, (Double(pitch - 69) + tuning / 100) / 12)
        var bands: [(Int, Int)] = []
        for h in 1...max(1, settings.harmonics) {
            let f = f0 * Double(h)
            let lo = Int((f * pow(2, -0.5 / 12) / binHz).rounded()), hi = Int((f * pow(2, 0.5 / 12) / binHz).rounded())
            guard lo < half - 1 else { break }
            bands.append((max(lo, 1), min(max(lo, hi), half - 1)))
        }
        return bands
    }

    /// The windowed spectrum of the samples from `f * hop`. Samples outside
    /// the take are silence: clamping a note in the first 46 ms to frame 0,
    /// which already holds its attack, measured no rise, and every note a
    /// take opens on was dropped.
    private func magnitudes(frame f: Int) -> [Float] {
        if let m = cache[f] { return m }
        let n = settings.fftSize, half = n / 2
        var mag = [Float](repeating: 0, count: half)
        let first = f * settings.hop
        let lo = max(first, 0), hi = min(first + n, x.count)
        guard lo < hi else { return mag }
        if lo == first, hi == first + n {
            x.withUnsafeBufferPointer { vDSP_vmul($0.baseAddress! + first, 1, window, 1, &buffer, 1, vDSP_Length(n)) }
        } else {
            vDSP_vclr(&buffer, 1, vDSP_Length(n))
            x.withUnsafeBufferPointer { p in
                window.withUnsafeBufferPointer { w in
                    buffer.withUnsafeMutableBufferPointer { b in
                        vDSP_vmul(p.baseAddress! + lo, 1, w.baseAddress! + (lo - first), 1,
                                  b.baseAddress! + (lo - first), 1, vDSP_Length(hi - lo))
                    }
                }
            }
        }
        re.withUnsafeMutableBufferPointer { r in
            im.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                buffer.withUnsafeBufferPointer {
                    $0.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mag, 1, vDSP_Length(half))
            }
        }
        cache[f] = mag
        return mag
    }
}
