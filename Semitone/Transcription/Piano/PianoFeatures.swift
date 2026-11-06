import Foundation
import Accelerate

/// Transkun's front end: gain-normalize the segment's frames, take six
/// windowed power spectra per frame (orthonormal rFFT), project onto 229
/// mel bands and log-compress. Output layout is [frame][mel][window].
nonisolated final class PianoFeatureExtractor {
    private let weights: PianoWeights
    private let fftSetup: FFTSetup
    private let log2n: vDSP_Length = 12
    /// Power spectra are projected onto mels this many frames at a time, so
    /// only a slice of the [frames * 6][2049] spectra is ever held (~3 MB, not 34).
    private static let chunkFrames = 64
    private var padded = [Float]()
    private var power = [Float]()          // [(chunk frame * 6 + window)][2049]
    private var mel = [Float]()            // [(frame * 6 + window)][229]

    init(weights: PianoWeights) {
        self.weights = weights
        fftSetup = vDSP_create_fftsetup(12, FFTRadix(kFFTRadix2))!
        let m = PianoModel.self
        padded = [Float](repeating: 0, count: (m.frames - 1) * m.hop + m.window)
        power = [Float](repeating: 0, count: Self.chunkFrames * m.windowCount * m.bins)
        mel = [Float](repeating: 0, count: m.frames * m.windowCount * m.mels)
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    /// `segment` holds exactly PianoModel.segmentSamples samples; `out` receives
    /// frames * mels * windowCount values.
    func features(segment: UnsafeBufferPointer<Float>, into out: UnsafeMutablePointer<Float>) {
        let m = PianoModel.self
        precondition(segment.count == m.segmentSamples)
        let n = m.window, half = n / 2, hop = m.hop
        let frames = m.frames, windows = m.windowCount, bins = m.bins, mels = m.mels

        // makeFrame: half a window of zeros on the left, zeros to the end.
        padded.withUnsafeMutableBufferPointer { p in
            p.update(repeating: 0)
            p.baseAddress!.advanced(by: half).update(from: segment.baseAddress!, count: segment.count)
        }

        // Gain normalization over every sample of every (overlapping) frame,
        // torch.std-style (unbiased).
        var sum = 0.0, sumSq = 0.0
        padded.withUnsafeBufferPointer { p in
            for f in 0..<frames {
                var s: Float = 0, ss: Float = 0
                vDSP_sve(p.baseAddress! + f * hop, 1, &s, vDSP_Length(n))
                vDSP_svesq(p.baseAddress! + f * hop, 1, &ss, vDSP_Length(n))
                sum += Double(s); sumSq += Double(ss)
            }
        }
        let count = Double(frames * n)
        let mean = sum / count
        let std = sqrt(max(0, (sumSq - count * mean * mean) / (count - 1)))
        var shift = Float(-mean)
        var scale = Float(1 / (std + 1e-8))
        padded.withUnsafeMutableBufferPointer { p in
            vDSP_vsadd(p.baseAddress!, 1, &shift, p.baseAddress!, 1, vDSP_Length(p.count))
            vDSP_vsmul(p.baseAddress!, 1, &scale, p.baseAddress!, 1, vDSP_Length(p.count))
        }

        // Six windowed power spectra per frame, projected onto mels a chunk at a time.
        var windowed = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: half)
        var im = [Float](repeating: 0, count: half)
        // vDSP's real FFT returns 2x the DFT; "ortho" divides by sqrt(n).
        // Power therefore scales by 1 / (4 n).
        var powerScale = Float(1.0 / (4.0 * Double(n)))
        padded.withUnsafeBufferPointer { p in
            weights.windows.withUnsafeBufferPointer { w in
                weights.melFilterbank.withUnsafeBufferPointer { fb in
                    power.withUnsafeMutableBufferPointer { pw in
                        mel.withUnsafeMutableBufferPointer { mp in
                            for first in stride(from: 0, to: frames, by: Self.chunkFrames) {
                                let chunk = min(Self.chunkFrames, frames - first)
                                for f in first..<(first + chunk) {
                                    let frame = p.baseAddress! + f * hop
                                    for k in 0..<windows {
                                        vDSP_vmul(frame, 1, w.baseAddress! + k * n, 1, &windowed, 1, vDSP_Length(n))
                                        let row = pw.baseAddress! + ((f - first) * windows + k) * bins
                                        re.withUnsafeMutableBufferPointer { rp in
                                            im.withUnsafeMutableBufferPointer { ip in
                                                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                                                windowed.withUnsafeBufferPointer { wb in
                                                    wb.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                                                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                                                    }
                                                }
                                                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                                                let dc = rp[0], nyquist = ip[0]
                                                rp[0] = 0; ip[0] = 0
                                                vDSP_zvmags(&split, 1, row, 1, vDSP_Length(half))
                                                row[0] = dc * dc
                                                row[half] = nyquist * nyquist
                                                vDSP_vsmul(row, 1, &powerScale, row, 1, vDSP_Length(bins))
                                            }
                                        }
                                    }
                                }
                                // Mel projection: [chunk*6 x 2049] x [2049 x 229].
                                cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans,
                                            Int32(chunk * windows), Int32(mels), Int32(bins),
                                            1, pw.baseAddress!, Int32(bins), fb.baseAddress!, Int32(mels),
                                            0, mp.baseAddress! + first * windows * mels, Int32(mels))
                            }
                        }
                    }
                }
            }
        }

        // log((mel + eps)) normalized to [0, 1]-ish, scattered to [frame][mel][window].
        var eps: Float = 1e-5
        var negLogEps = -log(eps)
        mel.withUnsafeMutableBufferPointer { mp in
            let values = mp.baseAddress!
            var total = Int32(mp.count)
            vDSP_vsadd(values, 1, &eps, values, 1, vDSP_Length(total))
            vvlogf(values, values, &total)
            vDSP_vsadd(values, 1, &negLogEps, values, 1, vDSP_Length(total))
            vDSP_vsdiv(values, 1, &negLogEps, values, 1, vDSP_Length(total))
            for f in 0..<frames {
                for k in 0..<windows {
                    cblas_scopy(Int32(mels), values + (f * windows + k) * mels, 1,
                                out + f * mels * windows + k, Int32(windows))
                }
            }
        }
    }
}
