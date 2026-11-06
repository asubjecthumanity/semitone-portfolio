import Foundation
import Accelerate

/// Harmonic/percussive separation by median filtering (FitzGerald 2010, the
/// method behind librosa's `hpss`). In a magnitude spectrogram sustained tones
/// are horizontal lines and drum hits vertical ones, so a median across time
/// keeps the tones and a median across frequency keeps the hits. Soft masks
/// built from the two split the mix, and both parts are resynthesized with the
/// original phase, so `harmonic + percussive` is the input again (up to the
/// masks' tiny floor).
///
/// Runs on Accelerate in blocks of frames: the medians are compare-exchange
/// networks of whole-row `vDSP_vmin`/`vDSP_vmax` calls, so it stays fast in
/// unoptimized builds, and a 5-minute take never holds more than a few MB of
/// spectrogram.
nonisolated enum HarmonicPercussive {
    struct Settings: Equatable {
        /// FFT length (power of two) and hop, in samples.
        var fftSize = 2048
        var hop = 512
        /// Median length across time, in frames (odd). 17 frames is ~0.4 s at 22050 Hz.
        var harmonicKernel = 17
        /// Median length across frequency, in bins (odd). 17 bins is ~180 Hz at 22050 Hz.
        var percussiveKernel = 17
        /// Mask exponent: 2 gives Wiener-style soft masks; higher is harder.
        var power: Float = 2
    }

    struct Output {
        var harmonic: [Float]
        var percussive: [Float]
    }

    /// Frames per processing block (~12 s at 22050 Hz with the default hop).
    private static let blockFrames = 512

    /// Returns nil if cancelled or the settings are invalid.
    static func separate(
        _ x: [Float],
        settings: Settings = Settings(),
        isCancelled: () -> Bool = { false }
    ) -> Output? {
        let n = settings.fftSize
        let hop = settings.hop
        let half = n / 2
        let bins = half + 1
        guard n >= 16, n & (n - 1) == 0, hop > 0, hop <= half,
              settings.harmonicKernel % 2 == 1, settings.percussiveKernel % 2 == 1 else { return nil }
        guard !x.isEmpty else { return Output(harmonic: [], percussive: []) }

        let log2n = vDSP_Length(n.trailingZeroBitCount)
        guard let fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(fft) }

        // Periodic Hann for analysis and synthesis; the output is divided by the
        // summed squared window, so any hop up to n/2 reconstructs exactly.
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_DENORM))

        let sampleCount = x.count
        let totalFrames = 1 + sampleCount / hop
        let hTime = settings.harmonicKernel / 2
        let timeNet = MedianNetwork(size: settings.harmonicKernel)
        let freqNet = MedianNetwork(size: settings.percussiveKernel)
        let hFreq = settings.percussiveKernel / 2

        // Output accumulators in "centered" coordinates: frame t covers samples
        // [t*hop - n/2, t*hop + n/2).
        var harmonic = [Float](repeating: 0, count: sampleCount)
        var percussive = [Float](repeating: 0, count: sampleCount)
        var windowSum = [Float](repeating: 0, count: sampleCount)

        // Scratch buffers, reused for every frame.
        let frameBuf = UnsafeMutablePointer<Float>.allocate(capacity: n)
        let re = UnsafeMutablePointer<Float>.allocate(capacity: half)
        let im = UnsafeMutablePointer<Float>.allocate(capacity: half)
        let hMed = UnsafeMutablePointer<Float>.allocate(capacity: bins)
        let pMed = UnsafeMutablePointer<Float>.allocate(capacity: bins)
        let hMask = UnsafeMutablePointer<Float>.allocate(capacity: bins)
        let pMask = UnsafeMutablePointer<Float>.allocate(capacity: bins)
        let tmp = UnsafeMutablePointer<Float>.allocate(capacity: bins)
        let padded = UnsafeMutablePointer<Float>.allocate(capacity: bins + 2 * hFreq)
        let timeLanes = LaneSet(count: timeNet.lanes + 1, length: bins)
        let freqLanes = LaneSet(count: freqNet.lanes + 1, length: bins)
        defer {
            for p in [frameBuf, re, im, hMed, pMed, hMask, pMask, tmp, padded] { p.deallocate() }
            timeLanes.deallocate()
            freqLanes.deallocate()
        }

        /// Windowed FFT of frame t into (re, im), vDSP's packed layout:
        /// re[0] = DC, im[0] = Nyquist, (re[k], im[k]) = bin k.
        func analyze(frame t: Int) {
            let start = t * hop - half
            frameBuf.update(repeating: 0, count: n)
            let lo = max(0, start), hi = min(sampleCount, start + n)
            if lo < hi {
                x.withUnsafeBufferPointer { src in
                    (frameBuf + (lo - start)).update(from: src.baseAddress! + lo, count: hi - lo)
                }
            }
            vDSP_vmul(frameBuf, 1, window, 1, frameBuf, 1, vDSP_Length(n))
            var split = DSPSplitComplex(realp: re, imagp: im)
            frameBuf.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
            }
            vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        }

        /// Magnitudes of the packed spectrum in (re, im) into `out` (bins values).
        func magnitudes(into out: UnsafeMutablePointer<Float>) {
            var split = DSPSplitComplex(realp: re, imagp: im)
            vDSP_zvabs(&split, 1, out, 1, vDSP_Length(half))
            out[0] = abs(re[0])
            out[half] = abs(im[0])
        }

        /// Masks a stored spectrum, inverts it, windows it and overlap-adds it.
        func synthesize(frame t: Int, mask: UnsafeMutablePointer<Float>, re0: UnsafePointer<Float>, im0: UnsafePointer<Float>,
                        into out: inout [Float], accumulateWindow: Bool) {
            let nyquist = im0[0] * mask[half]
            vDSP_vmul(re0, 1, mask, 1, re, 1, vDSP_Length(half))
            vDSP_vmul(im0, 1, mask, 1, im, 1, vDSP_Length(half))
            im[0] = nyquist
            var split = DSPSplitComplex(realp: re, imagp: im)
            vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_INVERSE))
            frameBuf.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(half))
            }
            // A forward + inverse zrip round trip scales by 2n.
            var scale = 1 / Float(2 * n)
            vDSP_vsmul(frameBuf, 1, &scale, frameBuf, 1, vDSP_Length(n))
            vDSP_vmul(frameBuf, 1, window, 1, frameBuf, 1, vDSP_Length(n))

            let start = t * hop - half
            let lo = max(0, start), hi = min(sampleCount, start + n)
            guard lo < hi else { return }
            let len = vDSP_Length(hi - lo)
            out.withUnsafeMutableBufferPointer { o in
                vDSP_vadd(o.baseAddress! + lo, 1, frameBuf + (lo - start), 1, o.baseAddress! + lo, 1, len)
            }
            if accumulateWindow {
                windowSum.withUnsafeMutableBufferPointer { w in
                    window.withUnsafeBufferPointer { win in
                        vDSP_vma(win.baseAddress! + (lo - start), 1, win.baseAddress! + (lo - start), 1,
                                 w.baseAddress! + lo, 1, w.baseAddress! + lo, 1, len)
                    }
                }
            }
        }

        var block = 0
        while block < totalFrames {
            if isCancelled() { return nil }
            let keptLo = block, keptHi = min(totalFrames, block + blockFrames)
            let extLo = max(0, keptLo - hTime), extHi = min(totalFrames, keptHi + hTime)
            let extCount = extHi - extLo
            let keptCount = keptHi - keptLo

            // Magnitudes for the block plus its time-median margins, and the
            // complex spectra of the kept frames.
            var mags = [Float](repeating: 0, count: extCount * bins)
            var specRe = [Float](repeating: 0, count: keptCount * half)
            var specIm = [Float](repeating: 0, count: keptCount * half)
            mags.withUnsafeMutableBufferPointer { m in
                specRe.withUnsafeMutableBufferPointer { sr in
                    specIm.withUnsafeMutableBufferPointer { si in
                        for t in extLo..<extHi {
                            analyze(frame: t)
                            magnitudes(into: m.baseAddress! + (t - extLo) * bins)
                            if t >= keptLo, t < keptHi {
                                (sr.baseAddress! + (t - keptLo) * half).update(from: re, count: half)
                                (si.baseAddress! + (t - keptLo) * half).update(from: im, count: half)
                            }
                        }
                    }
                }
            }

            for t in keptLo..<keptHi {
                mags.withUnsafeBufferPointer { m in
                    let rows = m.baseAddress!
                    // Median across time (edges repeat the outermost frame).
                    for j in 0..<timeNet.size {
                        let row = min(max(t + j - hTime, extLo), extHi - 1) - extLo
                        timeLanes[j].update(from: rows + row * bins, count: bins)
                    }
                    timeNet.fillSentinels(timeLanes)
                    hMed.update(from: timeNet.run(timeLanes), count: bins)

                    // Median across frequency (edges repeat the outermost bin).
                    let own = rows + (t - extLo) * bins
                    padded.update(repeating: own[0], count: hFreq)
                    (padded + hFreq).update(from: own, count: bins)
                    (padded + hFreq + bins).update(repeating: own[bins - 1], count: hFreq)
                    for j in 0..<freqNet.size {
                        freqLanes[j].update(from: padded + j, count: bins)
                    }
                    freqNet.fillSentinels(freqLanes)
                    pMed.update(from: freqNet.run(freqLanes), count: bins)
                }

                // Soft masks: H^p / (H^p + P^p) and P^p / (H^p + P^p).
                let count = vDSP_Length(bins)
                var power = settings.power
                var binCount = Int32(bins)
                vvpowsf(hMask, &power, hMed, &binCount)
                vvpowsf(pMask, &power, pMed, &binCount)
                vDSP_vadd(hMask, 1, pMask, 1, tmp, 1, count)
                var floor: Float = 1e-12
                vDSP_vsadd(tmp, 1, &floor, tmp, 1, count)
                vDSP_vdiv(tmp, 1, hMask, 1, hMask, 1, count)
                vDSP_vdiv(tmp, 1, pMask, 1, pMask, 1, count)

                let k = t - keptLo
                specRe.withUnsafeBufferPointer { sr in
                    specIm.withUnsafeBufferPointer { si in
                        synthesize(frame: t, mask: hMask, re0: sr.baseAddress! + k * half, im0: si.baseAddress! + k * half,
                                   into: &harmonic, accumulateWindow: true)
                        synthesize(frame: t, mask: pMask, re0: sr.baseAddress! + k * half, im0: si.baseAddress! + k * half,
                                   into: &percussive, accumulateWindow: false)
                    }
                }
            }
            block = keptHi
        }

        // Undo the window overlap. Every sample is covered by several frames,
        // so the sum never gets near zero; the floor only guards the math.
        var floor: Float = 1e-6
        let count = vDSP_Length(sampleCount)
        windowSum.withUnsafeMutableBufferPointer { w in
            vDSP_vthr(w.baseAddress!, 1, &floor, w.baseAddress!, 1, count)
            harmonic.withUnsafeMutableBufferPointer { h in
                vDSP_vdiv(w.baseAddress!, 1, h.baseAddress!, 1, h.baseAddress!, 1, count)
            }
            percussive.withUnsafeMutableBufferPointer { p in
                vDSP_vdiv(w.baseAddress!, 1, p.baseAddress!, 1, p.baseAddress!, 1, count)
            }
        }
        return Output(harmonic: harmonic, percussive: percussive)
    }
}

// MARK: - Median by compare-exchange network

/// Buffers ("lanes") a `MedianNetwork` sorts, one row each. The network swaps
/// lane pointers instead of copying rows, so the set owns one spare lane.
nonisolated final class LaneSet {
    private(set) var lanes: [UnsafeMutablePointer<Float>]
    private let all: [UnsafeMutablePointer<Float>]
    let length: Int

    init(count: Int, length: Int) {
        all = (0..<count).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: length) }
        lanes = all
        self.length = length
    }

    subscript(i: Int) -> UnsafeMutablePointer<Float> { lanes[i] }

    func swapWithSpare(_ i: Int) { lanes.swapAt(i, lanes.count - 1) }

    func deallocate() { for p in all { p.deallocate() } }
}

/// Compare-exchange steps that leave the median of `size` values in lane
/// `size / 2`: Batcher's odd-even merge sort, padded to a power of two with
/// +infinity and pruned to the steps that do something and that the median
/// depends on (about 60 steps for 17 values). Each step is one `vDSP_vmin` and
/// one `vDSP_vmax` over a whole row, so the median of every column comes out at once.
nonisolated struct MedianNetwork {
    let size: Int
    let lanes: Int
    private let steps: [(Int, Int)]
    /// Padding lanes some step reads; they must hold +infinity.
    private let sentinels: [Int]

    init(size: Int) {
        var n = 1
        while n < size { n *= 2 }
        var all: [(Int, Int)] = []
        var p = 1
        while p < n {
            var k = p
            while k >= 1 {
                var j = k % p
                while j + k < n {
                    for i in 0..<k where i + j + k < n && (i + j) / (2 * p) == (i + j + k) / (2 * p) {
                        all.append((i + j, i + j + k))
                    }
                    j += 2 * k
                }
                k /= 2
            }
            p *= 2
        }

        // Lanes from `size` up start as +infinity. A step whose upper lane holds
        // infinity changes nothing; one whose lower lane does moves a value down.
        var isInfinite = (0..<n).map { $0 >= size }
        var live: [(Int, Int)] = []
        for (a, b) in all {
            if isInfinite[b] { continue }
            if isInfinite[a] {
                isInfinite[a] = false
                isInfinite[b] = true
            }
            live.append((a, b))
        }

        // Walk back from the median lane, keeping only steps it depends on.
        var needed: Set<Int> = [size / 2]
        var kept: [(Int, Int)] = []
        for (a, b) in live.reversed() where needed.contains(a) || needed.contains(b) {
            needed.insert(a)
            needed.insert(b)
            kept.append((a, b))
        }
        steps = kept.reversed()
        sentinels = needed.filter { $0 >= size }.sorted()
        lanes = n
        self.size = size
    }

    func fillSentinels(_ set: LaneSet) {
        for lane in sentinels { set[lane].update(repeating: .infinity, count: set.length) }
    }

    /// Runs the network over lanes 0..<size (already filled) and returns the
    /// lane holding the medians. Valid until the lanes are refilled.
    func run(_ set: LaneSet) -> UnsafeMutablePointer<Float> {
        let length = vDSP_Length(set.length)
        let spare = set.lanes.count - 1
        for (a, b) in steps {
            vDSP_vmin(set[a], 1, set[b], 1, set[spare], 1, length)
            vDSP_vmax(set[a], 1, set[b], 1, set[b], 1, length)
            set.swapWithSpare(a)   // lane a now holds the minimums
        }
        return set[size / 2]
    }
}
