import Foundation
import Accelerate

/// One decoded note in a segment, in seconds relative to the segment start.
nonisolated struct PianoSegmentNote {
    var start: Double
    var end: Double
    let pitch: Int
    let velocity: Int
    let hasOnset: Bool
    var hasOffset: Bool
}

/// Ports Transkun's ScaledInnerProductIntervalScorer, backward semi-CRF
/// Viterbi decode, and velocity / refined-onset-offset heads.
nonisolated final class PianoDecoder {
    private let weights: PianoWeights
    private let T = PianoModel.frames
    private var scorerOut: [Float]     // [T][513] for the current key
    private var gram: [Float]          // B[b][e] = k_b . q_e / 16
    private var diag: [Float]
    private var value: [Float]
    private var pointer: [Int]
    private var candidates: [Float]    // one Viterbi step's scores
    private let lengths: [Float]       // 1, 2, ... T - 1: interval length in frames
    /// Rows of [ctx_begin, ctx_end, ctx_begin * ctx_end] for the attribute heads.
    private var headInput = [Float]()

    init(weights: PianoWeights) {
        self.weights = weights
        let T = PianoModel.frames
        scorerOut = [Float](repeating: 0, count: T * PianoModel.scorerOut)
        gram = [Float](repeating: 0, count: T * T)
        diag = [Float](repeating: 0, count: T)
        value = [Float](repeating: 0, count: T)
        pointer = [Int](repeating: -1, count: T)
        candidates = [Float](repeating: 0, count: T)
        lengths = (1..<T).map(Float.init)
    }

    /// Decodes all 90 symbols: the two pedals, then the 88 keys; pedal events
    /// come back as notes with negative pitch (PianoModel.pedalPitches).
    /// `symbolContext(symbol)` returns that symbol's backbone embeddings, contiguous
    /// [T][256]; the pointer only has to stay valid until the next call.
    /// `forcedStart[symbol]` is where backtracking begins for each symbol.
    /// Returns notes sorted by (start, end, pitch) and each symbol's last offset frame.
    func decode(symbolContext: (Int) -> UnsafePointer<Float>, forcedStart: [Int]) -> (notes: [PianoSegmentNote], lastP: [Int]) {
        let m = PianoModel.self
        let d = m.ctxDim, inDim = 3 * d
        var intervals: [(symbol: Int, begin: Int, end: Int)] = []
        for symbol in 0..<m.symbols {
            let c = symbolContext(symbol)
            let found = viterbi(context: c, forcedStart: forcedStart[symbol])
            // The heads read this symbol's embeddings, so gather their rows now.
            let needed = (intervals.count + found.count) * inDim
            if headInput.count < needed {
                headInput.append(contentsOf: [Float](repeating: 0, count: max(needed - headInput.count, headInput.count)))
            }
            headInput.withUnsafeMutableBufferPointer { x in
                for (i, (b, e)) in found.enumerated() {
                    let row = x.baseAddress! + (intervals.count + i) * inDim
                    row.update(from: c + b * d, count: d)
                    (row + d).update(from: c + e * d, count: d)
                    vDSP_vmul(c + b * d, 1, c + e * d, 1, row + 2 * d, 1, vDSP_Length(d))
                }
            }
            for (b, e) in found { intervals.append((symbol, b, e)) }
        }
        let attrs = attributes(count: intervals.count)

        var notes: [PianoSegmentNote] = []
        var lastP = [Int](repeating: 0, count: m.symbols)
        var lastEnd = 0.0
        var currentSymbol = -1
        for (n, iv) in intervals.enumerated() {
            if iv.symbol != currentSymbol { currentSymbol = iv.symbol; lastEnd = 0 }
            let a = attrs[n]
            var start = (Double(iv.begin) + a.onsetShift) * m.frameDuration
            var end = (Double(iv.end) + a.offsetShift) * m.frameDuration
            let hasOnset = iv.begin > 0 || a.onsetPresent
            let hasOffset = iv.end < m.lastFrameIdx || a.offsetPresent
            start = max(start, lastEnd)
            end = max(end, start + 1e-8)
            lastEnd = end
            notes.append(PianoSegmentNote(start: start, end: end, pitch: m.pitch(symbol: iv.symbol),
                                          velocity: a.velocity, hasOnset: hasOnset, hasOffset: hasOffset))
            if hasOffset { lastP[iv.symbol] = iv.end }
        }
        notes.sort { ($0.start, $0.end, $0.pitch) < ($1.start, $1.end, $1.pitch) }
        return (notes, lastP)
    }

    // MARK: - Scorer + Viterbi

    /// score[e][b] = (q_e . k_b / 16) * |e - b| for e != b, diag_e on the diagonal.
    /// The recursion runs on vDSP so it stays fast in unoptimized Debug builds.
    private func viterbi(context c: UnsafePointer<Float>, forcedStart: Int) -> [(Int, Int)] {
        let d = PianoModel.ctxDim, o = PianoModel.scorerOut
        let T = T

        scorerOut.withUnsafeMutableBufferPointer { so in
            // [T x 256] x [256 x 513] + bias
            weights.scorerW.withUnsafeBufferPointer { w in
                cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(T), Int32(o), Int32(d),
                            1, c, Int32(d), w.baseAddress!, Int32(d), 0, so.baseAddress!, Int32(o))
            }
            weights.scorerB.withUnsafeBufferPointer { bias in
                for t in 0..<T {
                    vDSP_vadd(so.baseAddress! + t * o, 1, bias.baseAddress!, 1, so.baseAddress! + t * o, 1, vDSP_Length(o))
                }
            }
            // gram[b][e] = k_b . q_e / sqrt(256)  (rows = begin, so the DP reads rows)
            gram.withUnsafeMutableBufferPointer { g in
                cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(T), Int32(T), Int32(d),
                            1.0 / 16.0, so.baseAddress! + d, Int32(o), so.baseAddress!, Int32(o),
                            0, g.baseAddress!, Int32(T))
            }
            diag.withUnsafeMutableBufferPointer { dg in
                cblas_scopy(Int32(T), so.baseAddress! + 2 * d, Int32(o), dg.baseAddress!, 1)
            }
        }

        // Backward recursion; noise (skip) score is 0 in this model. For each
        // begin t: best over ends e of v[e] + gram[t][e] * (e - t), else skip.
        gram.withUnsafeBufferPointer { g in
            value.withUnsafeMutableBufferPointer { v in
                candidates.withUnsafeMutableBufferPointer { cand in
                    lengths.withUnsafeBufferPointer { len in
                        pointer.withUnsafeMutableBufferPointer { ptr in
                            diag.withUnsafeBufferPointer { dg in
                                v[T - 1] = dg[T - 1] > 0 ? dg[T - 1] : 0
                                for t in stride(from: T - 2, through: 0, by: -1) {
                                    let n = vDSP_Length(T - 1 - t)
                                    vDSP_vmul(g.baseAddress! + t * T + t + 1, 1, len.baseAddress!, 1, cand.baseAddress!, 1, n)
                                    vDSP_vadd(cand.baseAddress!, 1, v.baseAddress! + t + 1, 1, cand.baseAddress!, 1, n)
                                    var best: Float = 0
                                    var index: vDSP_Length = 0
                                    vDSP_maxvi(cand.baseAddress!, 1, &best, &index, n)   // first index on ties
                                    if best > v[t + 1] {
                                        ptr[t] = Int(index)
                                    } else {
                                        ptr[t] = -1
                                        best = v[t + 1]
                                    }
                                    v[t] = best + (dg[t] > 0 ? dg[t] : 0)
                                }
                            }
                        }
                    }
                }
            }
        }

        var result: [(Int, Int)] = []
        var j = forcedStart
        while j < T - 1 {
            if diag[j] > 0 { result.append((j, j)) }
            let selection = pointer[j]
            if selection < 0 {
                j += 1
            } else {
                let i = selection + j + 1
                result.append((j, i))
                j = i
            }
        }
        if diag[T - 1] > 0 { result.append((T - 1, T - 1)) }
        return result
    }

    // MARK: - Attribute heads

    private struct Attributes {
        let velocity: Int
        let onsetShift: Double
        let offsetShift: Double
        let onsetPresent: Bool
        let offsetPresent: Bool
    }

    /// Runs the velocity and refined-timing heads on the first `n` rows of `headInput`.
    private func attributes(count n: Int) -> [Attributes] {
        guard n > 0 else { return [] }
        let h = PianoModel.headHidden, inDim = 3 * PianoModel.ctxDim

        func mlp(_ w1: [Float], _ b1: [Float], _ w2: [Float], _ b2: [Float], outDim: Int) -> [Float] {
            var hidden = [Float](repeating: 0, count: n * h)
            headInput.withUnsafeBufferPointer { x in
                w1.withUnsafeBufferPointer { w in
                    hidden.withUnsafeMutableBufferPointer { hp in
                        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(n), Int32(h), Int32(inDim),
                                    1, x.baseAddress!, Int32(inDim), w.baseAddress!, Int32(inDim),
                                    0, hp.baseAddress!, Int32(h))
                    }
                }
            }
            hidden.withUnsafeMutableBufferPointer { hp in
                b1.withUnsafeBufferPointer { bias in
                    let sqrt2 = Float(2).squareRoot()
                    for r in 0..<n {
                        let row = hp.baseAddress! + r * h
                        vDSP_vadd(row, 1, bias.baseAddress!, 1, row, 1, vDSP_Length(h))
                        for k in 0..<h {
                            let z = row[k]
                            row[k] = 0.5 * z * (1 + erf(z / sqrt2))   // exact GELU
                        }
                    }
                }
            }
            var out = [Float](repeating: 0, count: n * outDim)
            hidden.withUnsafeBufferPointer { hp in
                w2.withUnsafeBufferPointer { w in
                    out.withUnsafeMutableBufferPointer { op in
                        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(n), Int32(outDim), Int32(h),
                                    1, hp.baseAddress!, Int32(h), w.baseAddress!, Int32(h),
                                    0, op.baseAddress!, Int32(outDim))
                        b2.withUnsafeBufferPointer { bias in
                            for r in 0..<n {
                                let row = op.baseAddress! + r * outDim
                                vDSP_vadd(row, 1, bias.baseAddress!, 1, row, 1, vDSP_Length(outDim))
                            }
                        }
                    }
                }
            }
            return out
        }

        let vel = mlp(weights.velW1, weights.velB1, weights.velW2, weights.velB2, outDim: 128)
        let of = mlp(weights.ofW1, weights.ofB1, weights.ofW2, weights.ofB2, outDim: 4)

        return vel.withUnsafeBufferPointer { v in
            (0..<n).map { r in
                var top: Float = 0
                var best: vDSP_Length = 0
                vDSP_maxvi(v.baseAddress! + r * 128, 1, &top, &best, 128)   // first index on ties
                return Attributes(
                    velocity: Int(best),
                    onsetShift: Self.refinedShift(logit: of[r * 4]),
                    offsetShift: Self.refinedShift(logit: of[r * 4 + 1]),
                    onsetPresent: of[r * 4 + 2] > 0,
                    offsetPresent: of[r * 4 + 3] > 0
                )
            }
        }
    }

    /// torch ContinuousBernoulli(logits).mean, mapped to a sub-frame shift in [-0.5, 0.5].
    static func refinedShift(logit: Float) -> Double {
        let eps = Double(Float.ulpOfOne)
        let p = min(max(1 / (1 + exp(-Double(logit))), eps), 1 - eps)
        let mean: Double
        if p <= 0.499 || p > 0.501 {
            mean = p / (2 * p - 1) + 1 / (log1p(-p) - log(p))
        } else {
            let x = p - 0.5
            mean = 0.5 + (1.0 / 3.0 + 16.0 / 45.0 * x * x) * x
        }
        return min(max((mean - 0.5) / 0.99, -0.5), 0.5)
    }
}

/// Transkun's segment stitching: notes (and pedal events) that straddle a
/// segment boundary are continued (forced decoding start) and merged; the
/// result is de-overlapped per pitch.
nonisolated struct PianoStitcher {
    private var byPitch: [Int: [PianoSegmentNote]] = [:]
    private(set) var forcedStart = [Int](repeating: PianoModel.startFrameIdx, count: PianoModel.symbols)

    mutating func add(segmentNotes: [PianoSegmentNote], lastP: [Int], beginTime: Double) {
        forcedStart = lastP.map { max($0 - PianoModel.stepFrames, 0) }
        for var e in segmentNotes {
            e.start += beginTime
            e.end += beginTime
            e.start = max(e.start, 0)
            e.end = max(e.end, e.start)

            if var list = byPitch[e.pitch], let last = list.last, e.start < last.end {
                if e.hasOnset {
                    list[list.count - 1] = e
                } else {
                    list[list.count - 1].hasOffset = e.hasOffset
                    list[list.count - 1].end = max(e.end, last.end)
                }
                byPitch[e.pitch] = list
                continue
            }
            if e.hasOnset { byPitch[e.pitch, default: []].append(e) }
        }
    }

    func finish() -> [PianoSegmentNote] {
        var all: [PianoSegmentNote] = []
        for (_, list) in byPitch {
            var list = list
            if !list.isEmpty { list[list.count - 1].hasOffset = true }
            all.append(contentsOf: list.filter(\.hasOffset))
        }
        // resolveOverlapping: a re-struck key cuts off its previous note.
        all.sort { ($0.start, $0.end, $0.pitch) < ($1.start, $1.end, $1.pitch) }
        var lastIndex: [Int: Int] = [:]
        for i in all.indices {
            if let j = lastIndex[all[i].pitch], all[j].end > all[i].start {
                all[j].end = all[i].start
            }
            lastIndex[all[i].pitch] = i
        }
        return all
            .filter { $0.start < $0.end }
            .sorted { ($0.start, $0.end, $0.pitch) < ($1.start, $1.end, $1.pitch) }
    }
}
