import Foundation
import Accelerate

/// Stage 1: one consistent input for every later stage. The 44.1 kHz take is
/// already a mix of all channels (AudioFileLoader.loadMono, MicRecorder), so
/// conditioning is the 22.05 kHz copy plus a tuning estimate.
nonisolated enum InputConditioner {
    /// `take22k` is used as is when there is no 44.1 kHz take (a live take
    /// whose full-rate copy is missing).
    static func condition(take44k: [Float], take22k: [Float]? = nil) throws -> ConditionedTake {
        let audio22k = try take22k ?? AudioFileLoader.resampleMono(take44k, from: PianoModel.sampleRate,
                                                                  to: BPConstants.sampleRate)
        return ConditionedTake(audio44k: take44k, audio22k: audio22k,
                               tuning: estimateTuning(audio22k, sampleRate: BPConstants.sampleRate))
    }

    // MARK: - Tuning and drift

    /// Window length for the drift track, seconds.
    static let driftWindow = 10.0

    /// Spectral-peak tuning estimate. Every clear peak between 100 Hz and 2 kHz
    /// votes for its offset from the nearest equal-tempered pitch (A440), as a
    /// direction on a 100-cent circle weighted by its level; a circular mean
    /// per window gives the drift track, unwrapped so a choir sagging past a
    /// quarter tone keeps going instead of jumping back to sharp. About 10 FFTs
    /// a second of audio: negligible next to the note models.
    static func estimateTuning(_ x: [Float], sampleRate: Double) -> TuningEstimate {
        let n = 4096, hop = 2048
        guard x.count > n, sampleRate > 8000 else { return TuningEstimate() }
        let log2n = vDSP_Length(12)
        guard let fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return TuningEstimate() }
        defer { vDSP_destroy_fftsetup(fft) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        let half = n / 2
        let binHz = sampleRate / Double(n)
        let lo = Int(100 / binHz), hi = min(half - 2, Int(2000 / binHz))

        var frame = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        let framesPerWindow = max(1, Int(driftWindow * sampleRate) / hop)
        var windows: [(c: Double, s: Double, w: Double, frames: Int, voiced: Int)] = []
        var total = (c: 0.0, s: 0.0, w: 0.0)
        var voicedFrames = 0, frameCount = 0

        var start = 0
        while start + n <= x.count {
            let index = frameCount / framesPerWindow
            if index == windows.count { windows.append((0, 0, 0, 0, 0)) }
            x.withUnsafeBufferPointer { vDSP_vmul($0.baseAddress! + start, 1, window, 1, &frame, 1, vDSP_Length(n)) }
            re.withUnsafeMutableBufferPointer { r in
                im.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    frame.withUnsafeBufferPointer {
                        $0.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
                }
            }
            var peak: Float = 0
            vDSP_maxv(power, 1, &peak, vDSP_Length(half))
            // Peaks within 40 dB of the frame's loudest, and above a fixed floor (silence).
            let floor = max(peak * 1e-4, 1e-7)
            var votes = 0
            if peak > 1e-5 {
                var k = lo + 1
                while k < hi {
                    let p = power[k]
                    if p > floor, p > power[k - 1], p >= power[k + 1] {
                        // Parabolic interpolation on log power.
                        let a = log(Double(power[k - 1])), b = log(Double(p)), c = log(Double(power[k + 1]))
                        let denom = a - 2 * b + c
                        let offset = denom < 0 ? 0.5 * (a - c) / denom : 0
                        let f = (Double(k) + offset) * binHz
                        let cents = 1200 * log2(f / 440)
                        let dev = cents - 100 * (cents / 100).rounded()
                        let angle = 2 * Double.pi * dev / 100
                        let w = Double(p / peak).squareRoot()
                        windows[index].c += w * cos(angle)
                        windows[index].s += w * sin(angle)
                        windows[index].w += w
                        votes += 1
                    }
                    k += 1
                }
            }
            windows[index].frames += 1
            if votes > 0 { windows[index].voiced += 1; voicedFrames += 1 }
            frameCount += 1
            start += hop
        }
        for w in windows { total.c += w.c; total.s += w.s; total.w += w.w }
        guard total.w > 0 else { return TuningEstimate() }
        func cents(_ c: Double, _ s: Double) -> Double { atan2(s, c) / (2 * .pi) * 100 }

        // Unwrapped drift over windows that heard enough (a third of their frames).
        var drift: [(time: Double, cents: Double)] = []
        var previous: Double?
        for (i, w) in windows.enumerated() where w.w > 0 && w.voiced * 3 >= w.frames {
            var value = cents(w.c, w.s)
            if let p = previous {
                while value - p > 50 { value -= 100 }
                while value - p < -50 { value += 100 }
            }
            previous = value
            drift.append((Double(i * framesPerWindow * hop) / sampleRate, value))
        }
        return TuningEstimate(cents: cents(total.c, total.s), drift: drift,
                              confidence: Double(voicedFrames) / Double(max(frameCount, 1)))
    }
}

nonisolated extension TuningEstimate {
    /// Semitones to add at time `t` so the take reads in the tuning it started
    /// in: once the drift track has moved at least `threshold` cents from its
    /// first window, notes are re-snapped by the rounded drift. A choir that
    /// sags a semitone over two minutes is then written at the pitches it
    /// began with (the score), not a semitone low.
    func correction(at t: Double, threshold: Double = 60) -> Int {
        guard let reference = drift.first?.cents, drift.count >= 3 else { return 0 }
        // The window containing t (the last one that starts at or before t).
        var value = reference
        for w in drift where w.time <= t { value = w.cents }
        let moved = value - reference
        guard abs(moved) >= threshold else { return 0 }
        return -Int((moved / 100).rounded())
    }

    /// Cents from A440 of the semitones the take's notes are named in at
    /// time `t`: the take's tuning, moved by the semitones `correction(at:)`
    /// re-snaps a drifted take's notes by.
    func namingOffset(at t: Double) -> Double {
        cents - 100 * Double(correction(at: t))
    }

    /// `notes` re-snapped by `correction(at:)`.
    func corrected(_ notes: [NoteEvent]) -> [NoteEvent] {
        guard drift.count >= 3 else { return notes }
        return notes.map { n in
            let shift = correction(at: n.startTime)
            guard shift != 0 else { return n }
            return NoteEvent(startTime: n.startTime, endTime: n.endTime, pitch: min(127, max(0, n.pitch + shift)),
                             amplitude: n.amplitude, voice: n.voice)
        }
    }
}
