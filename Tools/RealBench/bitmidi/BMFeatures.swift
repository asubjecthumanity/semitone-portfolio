import Foundation
import Accelerate

// Features for aligning a MIDI file with a recording. Everything runs on one
// 20 ms frame grid (441 samples at 22050 Hz):
// - chroma: log-compressed pitch energies (STFT 4096) folded into 12 pitch
//   classes, unit length; quiet frames get the flat vector.
// - onset: 12 pitch-class onset channels (rectified rise of log pitch energy,
//   STFT 2048, kept at local peaks), one rhythm channel (broadband spectral
//   flux, STFT 1024) and three drum-band channels (flux at 40-150 Hz for the
//   kick, 1-4 kHz for the snare, 6-10 kHz for hi-hats), each group normalised
//   by its local maximum and given a decaying tail ("DLNCO" features, Ewert,
//   Muller & Grosche 2009). The drum bands tell beat 1 from beat 2 in a groove
//   where every beat has an onset.
// The MIDI side gets the same features from its notes: sounding notes with a
// few harmonics for chroma, onset impulses for the onset channels (drums feed
// the rhythm channel only).

let bmSampleRate = 22050.0
let bmHopSamples = 441
let bmHop = Double(bmHopSamples) / bmSampleRate   // 0.02 s
/// Onset feature layout: 12 pitch classes, broadband rhythm, kick band, snare band, hi-hat band.
let onsetDims = 16
let onsetGroups: [Range<Int>] = [0..<12, 12..<13, 13..<14, 14..<15, 15..<16]

/// General MIDI drum key -> onset channel (13 kick, 14 snare, 15 hi-hat/ride), nil for toms, crashes and others.
func drumChannel(_ key: Int) -> Int? {
    switch key {
    case 35, 36: return 13
    case 37, 38, 39, 40: return 14
    case 42, 44, 46, 51, 53, 59: return 15
    default: return nil
    }
}

/// Real FFT power spectrum (vDSP), Hann window.
final class PowerFFT {
    let n: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    private var buf: [Float]
    private var re: [Float]
    private var im: [Float]

    init(n: Int) {
        self.n = n
        log2n = vDSP_Length(log2(Double(n)).rounded())
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        buf = [Float](repeating: 0, count: n)
        re = [Float](repeating: 0, count: n / 2)
        im = [Float](repeating: 0, count: n / 2)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Power of bins 0...n/2 for the frame centred on sample `center` (zero padded at the edges).
    func power(_ x: [Float], center: Int, into out: inout [Float]) {
        let start = center - n / 2
        for k in 0..<n {
            let s = start + k
            buf[k] = (s >= 0 && s < x.count) ? x[s] * window[k] : 0
        }
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                buf.withUnsafeBufferPointer { bp in
                    bp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                out[0] = rp[0] * rp[0]
                out[n / 2] = ip[0] * ip[0]
                for k in 1..<(n / 2) { out[k] = rp[k] * rp[k] + ip[k] * ip[k] }
            }
        }
    }
}

/// Sparse triangular filterbank from FFT bins to semitone bands (MIDI pitches
/// lo...hi), tuned by `cents`. A band is at least about two bins wide, so the
/// low bands overlap where the FFT cannot separate semitones.
struct PitchFilterbank {
    let lo: Int, hi: Int
    var bins: [[(k: Int, w: Float)]] = []

    init(n: Int, lo: Int, hi: Int, cents: Double) {
        self.lo = lo; self.hi = hi
        let df = bmSampleRate / Double(n)
        for p in lo...hi {
            let fc = 440 * pow(2, (Double(p) - 69) / 12 + cents / 1200)
            // Width in semitones: one semitone, or the bin spacing if that is wider.
            let binInSemis = 12 * log2((fc + df) / fc)
            let width = max(1.0, 1.5 * binInSemis)
            let fLo = fc * pow(2, -width / 12), fHi = fc * pow(2, width / 12)
            var list: [(Int, Float)] = []
            for k in max(1, Int(fLo / df))...min(n / 2, Int(fHi / df) + 1) {
                let f = Double(k) * df
                let semis = 12 * log2(f / fc)
                let w = 1 - abs(semis) / width
                if w > 0 { list.append((k, Float(w))) }
            }
            if list.isEmpty { list.append((min(n / 2, max(1, Int((fc / df).rounded()))), 1)) }
            let total = list.reduce(Float(0)) { $0 + $1.1 }
            bins.append(list.map { ($0.0, $0.1 / total) })
        }
    }

    var count: Int { hi - lo + 1 }

    func apply(_ power: [Float], into out: inout [Float], offset: Int) {
        for (b, list) in bins.enumerated() {
            var s: Float = 0
            for (k, w) in list { s += power[k] * w }
            out[offset + b] = s
        }
    }
}

nonisolated struct AudioFeatures {
    var frames: Int
    var duration: Double
    var tuningCents: Double
    /// frames x 12, unit length (flat for quiet frames).
    var chroma: [Float]
    /// frames x onsetDims: 12 pitch-class onset channels, rhythm, kick, snare, hi-hat.
    var onset: [Float]
    /// Broadband onset novelty (spectral flux), frames.
    var novelty: [Float]
    /// Kick-, snare- and hi-hat-band novelty (detrended flux), frames each.
    var bandNovelty: [[Float]]
    /// Onset peak times (s) picked from the novelty.
    var peaks: [Double]
    /// frames x (pitchHi - pitchLo + 1): log-compressed pitch energies (STFT 4096), for octave checks.
    var pitchLog: [Float]
    var pitchLo: Int
    var pitchHi: Int
    /// Frame loudness in dB relative to the loud frames.
    var loudnessDB: [Float]
}

/// Global tuning in cents relative to A440, from the deviations of spectral
/// peaks (100-2000 Hz) from the equal-tempered grid (circular mean).
func estimateTuning(_ x: [Float]) -> Double {
    let n = 4096
    let fft = PowerFFT(n: n)
    var p = [Float](repeating: 0, count: n / 2 + 1)
    let df = bmSampleRate / Double(n)
    var sx = 0.0, sy = 0.0
    let frames = x.count / bmHopSamples
    var i = 0
    while i < frames {
        fft.power(x, center: i * bmHopSamples, into: &p)
        let lo = Int(100 / df), hi = Int(2000 / df)
        let mx = p[lo...hi].max() ?? 0
        if mx > 0 {
            for k in (lo + 1)..<hi where p[k] > p[k - 1] && p[k] >= p[k + 1] && p[k] > mx * 0.05 {
                // Parabolic interpolation on log power.
                let a = log(Double(p[k - 1]) + 1e-20), b = log(Double(p[k]) + 1e-20), c = log(Double(p[k + 1]) + 1e-20)
                let den = a - 2 * b + c
                let d = den != 0 ? 0.5 * (a - c) / den : 0
                let f = (Double(k) + max(-0.5, min(0.5, d))) * df
                let midi = 69 + 12 * log2(f / 440)
                let dev = midi - midi.rounded()          // -0.5...0.5 semitone
                let w = sqrt(Double(p[k]))
                sx += w * cos(2 * .pi * dev); sy += w * sin(2 * .pi * dev)
            }
        }
        i += 10
    }
    if sx == 0 && sy == 0 { return 0 }
    return atan2(sy, sx) / (2 * .pi) * 100
}

/// Log-compressed pitch energies, frames x bands, normalised so that loud frames are around 1 before compression.
func pitchEnergies(_ x: [Float], frames: Int, n: Int, lo: Int, hi: Int, cents: Double, gamma: Float = 100)
    -> (log: [Float], total: [Float]) {
    let fft = PowerFFT(n: n)
    let fb = PitchFilterbank(n: n, lo: lo, hi: hi, cents: cents)
    var p = [Float](repeating: 0, count: n / 2 + 1)
    let bands = fb.count
    var e = [Float](repeating: 0, count: frames * bands)
    var total = [Float](repeating: 0, count: frames)
    for i in 0..<frames {
        fft.power(x, center: i * bmHopSamples, into: &p)
        fb.apply(p, into: &e, offset: i * bands)
        var s: Float = 0
        vDSP_sve(Array(e[(i * bands)..<((i + 1) * bands)]), 1, &s, vDSP_Length(bands))
        total[i] = s
    }
    // Reference: the 95th percentile of the frames' strongest band.
    var maxima = (0..<frames).map { i in e[(i * bands)..<((i + 1) * bands)].max() ?? 0 }
    maxima.sort()
    let ref = max(maxima.isEmpty ? 1 : maxima[min(maxima.count - 1, Int(Double(maxima.count) * 0.95))], 1e-12)
    var scale = gamma / ref
    vDSP_vsmul(e, 1, &scale, &e, 1, vDSP_Length(e.count))
    var one: Float = 1
    vDSP_vsadd(e, 1, &one, &e, 1, vDSP_Length(e.count))
    var count32 = Int32(e.count)
    vvlogf(&e, e, &count32)
    var tscale = 1 / ref
    vDSP_vsmul(total, 1, &tscale, &total, 1, vDSP_Length(frames))
    return (e, total)
}

/// Sliding maximum over +-w frames.
func slidingMax(_ x: [Float], _ w: Int) -> [Float] {
    var out = [Float](repeating: 0, count: x.count)
    for i in x.indices {
        var m: Float = 0
        for j in max(0, i - w)...min(x.count - 1, i + w) where x[j] > m { m = x[j] }
        out[i] = m
    }
    return out
}

/// DLNCO post-processing on an onset matrix (frames x dims): each channel group
/// is divided by the local maximum (+-1.5 s) of its frame norm, then given a
/// decaying tail of `tail` frames.
func dlnco(_ raw: [Float], frames: Int, dims: Int, groups: [Range<Int>], tail: Int = 10) -> [Float] {
    var norm = raw
    for g in groups {
        var nrm = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            var s: Float = 0
            for d in g { s += raw[i * dims + d] * raw[i * dims + d] }
            nrm[i] = sqrt(s)
        }
        let peak = slidingMax(nrm, 75)
        // Floor: a quiet passage is not blown up to full scale.
        let floor = max((nrm.max() ?? 0) * 0.02, 1e-9)
        for i in 0..<frames {
            let den = max(peak[i], floor)
            for d in g { norm[i * dims + d] = raw[i * dims + d] / den }
        }
    }
    var out = [Float](repeating: 0, count: frames * dims)
    let weights = (0..<tail).map { Float(sqrt(Double(tail - $0) / Double(tail))) }
    for i in 0..<frames {
        for d in 0..<dims {
            let v = norm[i * dims + d]
            if v == 0 { continue }
            for k in 0..<tail where i + k < frames {
                out[(i + k) * dims + d] = max(out[(i + k) * dims + d], v * weights[k])
            }
        }
    }
    return out
}

/// Unit-length chroma rows; rows whose energy is under `quiet` get the flat vector.
func normalizeChroma(_ c: inout [Float], frames: Int, energy: [Float], quiet: Float) {
    let flat = Float(1 / sqrt(12.0))
    for i in 0..<frames {
        var s: Float = 0
        for d in 0..<12 { s += c[i * 12 + d] * c[i * 12 + d] }
        if energy[i] <= quiet || s <= 1e-12 {
            for d in 0..<12 { c[i * 12 + d] = flat }
        } else {
            let r = 1 / sqrt(s)
            for d in 0..<12 { c[i * 12 + d] *= r }
        }
    }
}

func computeAudioFeatures(_ x: [Float]) -> AudioFeatures {
    let frames = x.count / bmHopSamples + 1
    let tuning = estimateTuning(x)
    // Pitch energies from STFT 4096 (C1-B7; the octave check reads them all), chroma from A1 up.
    let lo = 24, hi = 107, chromaLo = 33
    let (pl, total) = pitchEnergies(x, frames: frames, n: 4096, lo: lo, hi: hi, cents: tuning)
    let bands = hi - lo + 1
    var chroma = [Float](repeating: 0, count: frames * 12)
    for i in 0..<frames {
        for b in (chromaLo - lo)..<bands { chroma[i * 12 + (lo + b) % 12] += pl[i * bands + b] }
    }
    var sortedTotal = total.sorted()
    let loud = sortedTotal.isEmpty ? 1 : max(sortedTotal[Int(Double(sortedTotal.count - 1) * 0.9)], 1e-12)
    normalizeChroma(&chroma, frames: frames, energy: total, quiet: loud * 1e-4)
    let loudness = total.map { Float(10 * log10(Double(max($0, 1e-12)) / Double(loud))) }
    sortedTotal = []

    // Pitch-class onsets from STFT 2048 (pitches E2-B7).
    let olo = 40, ohi = 107
    let (ol, _) = pitchEnergies(x, frames: frames, n: 2048, lo: olo, hi: ohi, cents: tuning)
    let ob = ohi - olo + 1
    var rise = [Float](repeating: 0, count: frames * ob)
    for i in 1..<frames {
        for b in 0..<ob { rise[i * ob + b] = max(0, ol[i * ob + b] - ol[(i - 1) * ob + b]) }
    }
    var raw = [Float](repeating: 0, count: frames * onsetDims)
    for i in 1..<(frames - 1) {
        for b in 0..<ob {
            let v = rise[i * ob + b]
            if v > 0, v >= rise[(i - 1) * ob + b], v > rise[(i + 1) * ob + b] {
                raw[i * onsetDims + (olo + b) % 12] += v
            }
        }
    }
    // Broadband flux from STFT 1024: log magnitude rise summed over bins.
    let fft = PowerFFT(n: 1024)
    var p = [Float](repeating: 0, count: 513)
    var prev = [Float](repeating: 0, count: 513)
    var novelty = [Float](repeating: 0, count: frames)
    var drumBands = [[Float]](repeating: [Float](repeating: 0, count: frames), count: 3)
    let df = Float(bmSampleRate / 1024)
    let bandBins: [Range<Int>] = [Int(40 / df)..<(Int(150 / df) + 1), Int(1000 / df)..<(Int(4000 / df) + 1), Int(6000 / df)..<(Int(10000 / df) + 1)]
    for i in 0..<frames {
        fft.power(x, center: i * bmHopSamples, into: &p)
        var s: Float = 0
        var bs: [Float] = [0, 0, 0]
        for k in 1..<513 {
            let l = log(1 + 1e4 * p[k])
            if i > 0 {
                let r = max(0, l - prev[k])
                if k >= 2 { s += r }
                for (q, br) in bandBins.enumerated() where br.contains(k) { bs[q] += r }
            }
            prev[k] = l
        }
        novelty[i] = s
        for q in 0..<3 { drumBands[q][i] = bs[q] }
    }
    // Subtract a local mean (+-0.5 s) so a sustained loud passage is not one long onset.
    let nov = localDetrend(novelty, 25)
    let bandNov = drumBands.map { localDetrend($0, 25) }
    for i in 1..<(frames - 1) {
        if nov[i] > 0 && nov[i] >= nov[i - 1] && nov[i] > nov[i + 1] { raw[i * onsetDims + 12] = nov[i] }
        for q in 0..<3 {
            let b = bandNov[q]
            if b[i] > 0 && b[i] >= b[i - 1] && b[i] > b[i + 1] { raw[i * onsetDims + 13 + q] = b[i] }
        }
    }
    let onset = dlnco(raw, frames: frames, dims: onsetDims, groups: onsetGroups)
    let peaks = pickPeaks(nov)
    return AudioFeatures(frames: frames, duration: Double(x.count) / bmSampleRate, tuningCents: tuning, chroma: chroma,
                         onset: onset, novelty: nov, bandNovelty: bandNov, peaks: peaks, pitchLog: pl, pitchLo: lo, pitchHi: hi,
                         loudnessDB: loudness)
}

/// x minus its local mean over +-w frames, floored at 0.
func localDetrend(_ x: [Float], _ w: Int) -> [Float] {
    var prefix = [Double](repeating: 0, count: x.count + 1)
    for i in x.indices { prefix[i + 1] = prefix[i] + Double(x[i]) }
    return x.indices.map { i in
        let a = max(0, i - w), b = min(x.count, i + w + 1)
        return max(0, x[i] - Float((prefix[b] - prefix[a]) / Double(b - a)))
    }
}

/// Onset peaks: local maxima over +-60 ms above an adaptive threshold
/// (local median-ish level: mean + 0.5 std over +-1 s), refined by parabolic interpolation.
func pickPeaks(_ nov: [Float]) -> [Double] {
    let n = nov.count
    guard n > 4 else { return [] }
    var prefix = [Double](repeating: 0, count: n + 1), prefix2 = [Double](repeating: 0, count: n + 1)
    for i in 0..<n { prefix[i + 1] = prefix[i] + Double(nov[i]); prefix2[i + 1] = prefix2[i] + Double(nov[i]) * Double(nov[i]) }
    let globalMax = Double(nov.max() ?? 0)
    var out: [Double] = []
    for i in 1..<(n - 1) {
        let v = Double(nov[i])
        if v <= 0.02 * globalMax { continue }
        var isMax = true
        for j in max(0, i - 3)...min(n - 1, i + 3) where j != i {
            if Double(nov[j]) > v || (Double(nov[j]) == v && j < i) { isMax = false; break }
        }
        if !isMax { continue }
        let a = max(0, i - 50), b = min(n, i + 51)
        let m = (prefix[b] - prefix[a]) / Double(b - a)
        let sd = sqrt(max(0, (prefix2[b] - prefix2[a]) / Double(b - a) - m * m))
        if v < m + 0.5 * sd { continue }
        let y0 = Double(nov[i - 1]), y2 = Double(nov[i + 1])
        let den = y0 - 2 * v + y2
        let d = den != 0 ? 0.5 * (y0 - y2) / den : 0
        out.append((Double(i) - 0.5 + max(-0.5, min(0.5, d))) * bmHop)
    }
    return out
}

// MARK: - Symbolic side

nonisolated struct SymNote {
    var on: Double
    var off: Double
    var pitch: Int
    var velocity: Int
    var drum: Bool
    /// Index into the voice list (BMVoice), -1 if none.
    var voice: Int
}

nonisolated struct SymFeatures {
    var frames: Int
    /// Untransposed chroma, frames x 12, unit length (flat where nothing sounds).
    var chroma: [Float]
    /// frames x onsetDims onset features (untransposed).
    var onset: [Float]
    /// Raw onset strength per frame (all notes incl. drums), for weighting the path fit.
    var onsetStrength: [Float]
}

/// Harmonic partials added to each sounding note: (semitones above, weight).
private let partials: [(Int, Float)] = [(0, 1), (12, 0.5), (19, 0.33), (24, 0.25), (28, 0.2), (31, 0.16)]

func computeSymbolicFeatures(_ notes: [SymNote], duration: Double) -> SymFeatures {
    let frames = Int(duration / bmHop) + 2
    var energy = [Float](repeating: 0, count: frames * 128)
    var raw = [Float](repeating: 0, count: frames * onsetDims)
    var strength = [Float](repeating: 0, count: frames)
    for n in notes {
        // An audio rise at frame i is the change from frame i-1 to i (centred half a frame earlier), so a
        // note onset feeds the onset channels at the first frame centre at or after it.
        let f0 = max(0, Int(ceil(n.on / bmHop - 1e-9)))
        guard f0 < frames else { continue }
        let v = Float(max(n.velocity, 1)) / 127
        strength[f0] += v
        if n.drum {
            raw[f0 * onsetDims + 12] += v
            if let c = drumChannel(n.pitch) { raw[f0 * onsetDims + c] += v }
            continue
        }
        raw[f0 * onsetDims + ((n.pitch % 12) + 12) % 12] += v
        raw[f0 * onsetDims + 12] += v * 0.5
        let s0 = max(0, Int((n.on / bmHop).rounded()))
        let f1 = min(frames - 1, max(s0 + 1, Int((n.off / bmHop).rounded())))
        // A note's energy decays a little over long holds (most instruments do).
        for f in s0..<f1 {
            let age = Float(f - s0) * Float(bmHop)
            let w = v * max(0.3, exp(-age / 3))
            for (iv, pw) in partials {
                let p = n.pitch + iv
                if p >= 0 && p < 128 { energy[f * 128 + p] += w * pw }
            }
        }
    }
    var chroma = [Float](repeating: 0, count: frames * 12)
    var total = [Float](repeating: 0, count: frames)
    for f in 0..<frames {
        for p in 0..<128 {
            let e = energy[f * 128 + p]
            if e > 0 {
                chroma[f * 12 + p % 12] += log(1 + 10 * e)
                total[f] += e
            }
        }
    }
    normalizeChroma(&chroma, frames: frames, energy: total, quiet: 1e-6)
    let onset = dlnco(raw, frames: frames, dims: onsetDims, groups: onsetGroups)
    return SymFeatures(frames: frames, chroma: chroma, onset: onset, onsetStrength: strength)
}

/// Chroma (or the 12 pitched onset channels) of a matrix rolled by k semitones (notes moved up by k).
func rollRows(_ m: [Float], frames: Int, dims: Int, k: Int) -> [Float] {
    if k % 12 == 0 { return m }
    var out = m
    for i in 0..<frames {
        for c in 0..<12 { out[i * dims + ((c + k) % 12 + 12) % 12] = m[i * dims + c] }
    }
    return out
}
