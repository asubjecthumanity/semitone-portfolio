import Foundation
import Accelerate

/// Converts model posteriors (onset/frame activation matrices) into note events.
/// Ported from basic_pitch's output_to_notes_polyphonic.
///
/// Live recording re-extracts the whole take after every model window (~1.6 s
/// of audio), and the app ships Debug (-Onone) builds, where Array subscripts
/// and for-in loops cost ~10-100x their Release price. So the whole-matrix
/// passes run on Accelerate and the per-note walks use raw pointers and while
/// loops. Each step does the same float operations as the scalar port, so the
/// notes are identical to it.
nonisolated enum NoteExtraction {
    struct Config: Equatable {
        /// Minimum onset activation for a new note (0-1).
        /// 0.70 / 0.30 / 150 ms scored 90% F1 against the MIDI ground truth
        /// in "semitone training"; 0.60 / 0.45 / 120 ms scored 84%.
        var onsetThreshold: Float = 0.70
        /// Activation below which a sounding note ends (0-1).
        var frameThreshold: Float = 0.30
        var minNoteLengthMs: Double = 150
        /// Add onsets where frame energy jumps sharply.
        var inferOnsets = true
        /// Recover notes with no detected onset from leftover frame energy.
        var melodiaTrick = true
        /// Frames a note may dip below frameThreshold before it ends.
        var energyTolerance = 11
        /// Drop weak notes that are harmonic echoes of a loud onset-mate.
        var suppressOctaveLeak = true

        /// Mixed instruments (the any-instrument mode), tuned on the synthetic
        /// band recordings in Tools/MusicBench: the raw mix, and the tonal part
        /// left after separating out the drums (its onsets are softer).
        static let music = Config(onsetThreshold: 0.70, frameThreshold: 0.40, minNoteLengthMs: 90)
        static let musicTonal = Config(onsetThreshold: 0.60, frameThreshold: 0.40, minNoteLengthMs: 90)
    }

    /// Matrices are row-major [frameCount x 88].
    static func notes(
        onsets rawOnsets: [Float],
        frames: [Float],
        frameCount n: Int,
        config: Config
    ) -> [NoteEvent] {
        let nf = BPConstants.pitchCount
        guard n > 1, rawOnsets.count >= n * nf, frames.count >= n * nf else { return [] }

        let onsets = config.inferOnsets
            ? inferredOnsets(onsets: rawOnsets, frames: frames, frameCount: n)
            : rawOnsets
        let minNoteLen = Int((config.minNoteLengthMs / 1000.0 * BPConstants.fps).rounded())
        let onsetPoints = onsetPeaks(onsets, frameCount: n, threshold: config.onsetThreshold)
        let threshold = config.frameThreshold
        let tolerance = config.energyTolerance

        var remaining = frames
        var events: [(start: Int, end: Int, pitch: Int, amp: Float)] = []

        frames.withUnsafeBufferPointer { frameBuffer in
            remaining.withUnsafeMutableBufferPointer { remainingBuffer in
                let fr = frameBuffer.baseAddress!
                let rem = remainingBuffer.baseAddress!

                // Mean activation of key f over frames [start, end), summed in time order.
                func meanFrames(_ start: Int, _ end: Int, _ f: Int) -> Float {
                    var sum: Float = 0
                    var t = start
                    while t < end {
                        sum += fr[t * nf + f]
                        t += 1
                    }
                    return sum / Float(end - start)
                }
                // Claims key f and its neighbours at frame t.
                func clear(_ t: Int, _ f: Int) {
                    let cell = t * nf + f
                    rem[cell] = 0
                    if f < nf - 1 { rem[cell + 1] = 0 }
                    if f > 0 { rem[cell - 1] = 0 }
                }

                // Walk onsets backwards in time, tracking each note until its
                // frame energy stays below threshold for energyTolerance frames.
                var p = onsetPoints.count
                while p > 0 {
                    p -= 1
                    let t0 = onsetPoints[p] / nf
                    let f = onsetPoints[p] % nf
                    guard t0 < n - 1 else { continue }
                    var i = t0 + 1
                    var k = 0
                    while i < n - 1 && k < tolerance {
                        if rem[i * nf + f] < threshold { k += 1 } else { k = 0 }
                        i += 1
                    }
                    i -= k
                    guard i - t0 > minNoteLen else { continue }
                    var t = t0
                    while t < i {
                        clear(t, f)
                        t += 1
                    }
                    events.append((t0, i, f + BPConstants.midiOffset, meanFrames(t0, i, f)))
                }

                // Melodia trick: sweep up leftover energy into onset-less notes,
                // strongest first. rowMax[t] caches frame t's largest remaining
                // value, so each argmax scans n values instead of n x 88 (the
                // flat scan made this quadratic in take length). Cells only ever
                // drop to 0, so only the frames a sweep touched need refreshing.
                // The first frame holding the maximum, then its first key, is the
                // cell a flat vDSP_maxvi returns (the lowest index on ties).
                guard config.melodiaTrick else { return }
                var rowMax = [Float](repeating: 0, count: n)
                rowMax.withUnsafeMutableBufferPointer { rowMaxBuffer in
                    let rowPeak = rowMaxBuffer.baseAddress!
                    func refreshRows(_ lo: Int, _ hi: Int) {
                        var t = lo
                        while t <= hi {
                            vDSP_maxv(rem + t * nf, 1, rowPeak + t, vDSP_Length(nf))
                            t += 1
                        }
                    }
                    refreshRows(0, n - 1)

                    while true {
                        var maxValue: Float = 0
                        var row: vDSP_Length = 0
                        vDSP_maxvi(rowPeak, 1, &maxValue, &row, vDSP_Length(n))
                        guard maxValue > threshold else { break }
                        let iMid = Int(row)
                        var keyValue: Float = 0
                        var key: vDSP_Length = 0
                        vDSP_maxvi(rem + iMid * nf, 1, &keyValue, &key, vDSP_Length(nf))
                        let f = Int(key)
                        rem[iMid * nf + f] = 0

                        var i = iMid + 1
                        var k = 0
                        while i < n - 1 && k < tolerance {
                            if rem[i * nf + f] < threshold { k += 1 } else { k = 0 }
                            clear(i, f)
                            i += 1
                        }
                        let lastCleared = i - 1
                        let iEnd = i - 1 - k

                        i = iMid - 1
                        k = 0
                        while i > 0 && k < tolerance {
                            if rem[i * nf + f] < threshold { k += 1 } else { k = 0 }
                            clear(i, f)
                            i -= 1
                        }
                        let firstCleared = i + 1
                        let iStart = i + 1 + k

                        refreshRows(min(firstCleared, iMid), max(lastCleared, iMid))
                        guard iEnd - iStart > minNoteLen else { continue }
                        events.append((iStart, iEnd, f + BPConstants.midiOffset, meanFrames(iStart, iEnd, f)))
                    }
                }
            }
        }

        return events
            .map {
                NoteEvent(
                    startTime: BPConstants.frameToTime($0.start),
                    endTime: BPConstants.frameToTime($0.end),
                    pitch: $0.pitch,
                    amplitude: Double($0.amp)
                )
            }
            .sorted { ($0.startTime, $0.pitch) < ($1.startTime, $1.pitch) }
    }

    /// Ported from piano-scribe's suppress_octave_leak (decode.py). Notes whose
    /// onsets land within 40 ms are clustered; in each cluster a weak note
    /// (amplitude < 0.55) sitting one harmonic interval away from a louder
    /// onset-mate — octave, octave + fifth, double octave (the 2nd, 3rd, 4th
    /// harmonics) — at most half its strength is treated as overtone leakage
    /// and dropped. Strict, so genuine doublings are preserved.
    static func suppressOctaveLeak(_ notes: [NoteEvent]) -> [NoteEvent] {
        let sorted = notes.sorted { ($0.startTime, $0.pitch) < ($1.startTime, $1.pitch) }
        var result: [NoteEvent] = []
        var cluster: [NoteEvent] = []
        for note in sorted {
            if let first = cluster.first, abs(note.startTime - first.startTime) > 0.04 {
                result.append(contentsOf: cleanCluster(cluster))
                cluster.removeAll(keepingCapacity: true)
            }
            cluster.append(note)
        }
        if !cluster.isEmpty {
            result.append(contentsOf: cleanCluster(cluster))
        }
        return result
    }

    private static let harmonicIntervals: Set<Int> = [12, 19, 24]

    private static func cleanCluster(_ cluster: [NoteEvent]) -> [NoteEvent] {
        let strong = cluster.map(\.amplitude).max() ?? 0
        guard strong >= 0.6 else { return cluster }

        var dropped = Set<Int>()
        for (i, note) in cluster.enumerated() where note.amplitude < 0.55 {
            for (j, other) in cluster.enumerated() where j != i && !dropped.contains(j) {
                if harmonicIntervals.contains(abs(note.pitch - other.pitch)),
                   note.amplitude <= 0.5 * other.amplitude {
                    dropped.insert(i)
                    break
                }
            }
        }
        return cluster.enumerated().compactMap { dropped.contains($0.offset) ? nil : $0.element }
    }

    /// Augment predicted onsets with sharp rises in frame energy,
    /// rescaled to the onset matrix's peak. For t >= nDiff the rise is
    /// max(0, min over d in 1...nDiff of frames[t] - frames[t - d]); it is 0 before.
    static func inferredOnsets(
        onsets: [Float],
        frames: [Float],
        frameCount n: Int,
        nDiff: Int = 2
    ) -> [Float] {
        let nf = BPConstants.pitchCount
        let count = n * nf
        guard count > 0 else { return [] }
        precondition(nDiff >= 1 && onsets.count >= count && frames.count >= count)

        var frameDiff = [Float](repeating: 0, count: count)
        onsets.withUnsafeBufferPointer { onsetBuffer in
            frames.withUnsafeBufferPointer { frameBuffer in
                frameDiff.withUnsafeMutableBufferPointer { diffBuffer in
                    let o = onsetBuffer.baseAddress!
                    let diff = diffBuffer.baseAddress!
                    if n > nDiff {
                        let len = vDSP_Length((n - nDiff) * nf)
                        let cur = frameBuffer.baseAddress! + nDiff * nf
                        let out = diff + nDiff * nf
                        vDSP_vsub(cur - nf, 1, cur, 1, out, 1, len)   // x[t] - x[t-1]
                        if nDiff > 1 {
                            var lagged = [Float](repeating: 0, count: Int(len))
                            var d = 2
                            while d <= nDiff {
                                vDSP_vsub(cur - d * nf, 1, cur, 1, &lagged, 1, len)
                                vDSP_vmin(out, 1, lagged, 1, out, 1, len)
                                d += 1
                            }
                        }
                        var zero: Float = 0
                        vDSP_vthres(out, 1, &zero, out, 1, len)       // max(0, rise)
                    }
                    var onsetMax: Float = 0
                    var diffMax: Float = 0
                    vDSP_maxv(o, 1, &onsetMax, vDSP_Length(onsets.count))
                    vDSP_maxv(diff, 1, &diffMax, vDSP_Length(count))
                    if diffMax > 0 {
                        var scale = onsetMax / diffMax
                        vDSP_vsmul(diff, 1, &scale, diff, 1, vDSP_Length(count))
                    }
                    vDSP_vmax(o, 1, diff, 1, diff, 1, vDSP_Length(count))
                }
            }
        }
        return frameDiff
    }

    /// Flat indices t * 88 + f of the onset cells that are strict local maxima
    /// in time (t in 1..<n-1) and at least `threshold`, ascending: the
    /// argrelmax + threshold step. A cell is a strict peak exactly when
    /// min(cur - prev, cur - next) > 0, and passes exactly when
    /// cur - threshold >= 0 (the difference of two unequal floats this large is
    /// never rounded to 0), so the vector test matches the scalar comparisons.
    private static func onsetPeaks(_ onsets: [Float], frameCount n: Int, threshold: Float) -> [Int] {
        let nf = BPConstants.pitchCount
        guard n > 2 else { return [] }
        let len = vDSP_Length((n - 2) * nf)
        var gate = [Float](repeating: 0, count: Int(len))
        var level = [Float](repeating: 0, count: Int(len))
        var points: [Int] = []
        onsets.withUnsafeBufferPointer { onsetBuffer in
            gate.withUnsafeMutableBufferPointer { gateBuffer in
                level.withUnsafeMutableBufferPointer { levelBuffer in
                    let prev = onsetBuffer.baseAddress!
                    let cur = prev + nf
                    let next = cur + nf
                    let g = gateBuffer.baseAddress!
                    let e = levelBuffer.baseAddress!
                    var zero: Float = 0
                    var one: Float = 1
                    var both: Float = 1.5
                    var negThreshold = -threshold
                    vDSP_vsub(prev, 1, cur, 1, g, 1, len)         // cur - prev
                    vDSP_vsub(next, 1, cur, 1, e, 1, len)         // cur - next
                    vDSP_vmin(g, 1, e, 1, g, 1, len)              // > 0 only at a strict peak
                    vDSP_vneg(g, 1, g, 1, len)
                    vDSP_vlim(g, 1, &zero, &one, g, 1, len)       // -1 at a peak, else +1
                    vDSP_vsadd(cur, 1, &negThreshold, e, 1, len)  // >= 0 iff cur >= threshold
                    vDSP_vlim(e, 1, &zero, &one, e, 1, len)       // +1 if so, else -1
                    vDSP_vsub(g, 1, e, 1, g, 1, len)              // 2 only where both hold
                    vDSP_vthres(g, 1, &both, g, 1, len)           // 2 there, 0 elsewhere

                    // Frames holding a peak list its keys in order.
                    var keys = [Float](repeating: 0, count: nf)
                    var rowMax: Float = 0
                    var rowSum: Float = 0
                    var r = 0
                    while r < n - 2 {
                        let row = g + r * nf
                        vDSP_maxv(row, 1, &rowMax, vDSP_Length(nf))
                        if rowMax > 0 {
                            vDSP_sve(row, 1, &rowSum, vDSP_Length(nf))
                            vDSP_vcmprs(keyIndices, 1, row, 1, &keys, 1, vDSP_Length(nf))
                            let found = Int(rowSum) / 2
                            var j = 0
                            while j < found {
                                points.append((r + 1) * nf + Int(keys[j]))
                                j += 1
                            }
                        }
                        r += 1
                    }
                }
            }
        }
        return points
    }

    /// 0, 1, ..., 87 as floats, for vDSP_vcmprs.
    private static let keyIndices: [Float] = (0..<BPConstants.pitchCount).map(Float.init)
}
