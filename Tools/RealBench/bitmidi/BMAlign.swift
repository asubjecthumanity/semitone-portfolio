import Foundation
import Accelerate

// MIDI -> recording alignment in two stages.
// 1. Coarse (0.2 s frames, chroma smoothed over 1 s): for each of the 12
//    transpositions, a local alignment (Smith-Waterman style: the path may
//    start and end anywhere) over the chroma similarity matrix. Steps (1,1),
//    (2,1), (1,2) follow tempo (slope 1/2 to 2); gap steps (1,0) and (0,1)
//    pay a penalty and stand for material only one side has (a section the
//    MIDI leaves out or repeats). The transposition with the best score wins.
//    The path is cut into matched segments at gap runs of 0.6 s or more.
// 2. Fine (20 ms frames): per segment, DTW in a band of +-0.6 s around the
//    coarse path on chroma plus onset (DLNCO) features. The fine path becomes
//    a time map: a weighted local line fit (onset frames weigh most) every
//    0.1 s of MIDI time, made monotone; then optionally each anchor is nudged
//    (+-60 ms) to the shift that best lines the warped MIDI onsets up with the
//    recording's onset novelty, smoothed over neighbours.

nonisolated struct AlignParams {
    var factor = 10              // fine frames per coarse frame (0.2 s)
    var coarseWindow = 50        // fine frames in the coarse smoothing window (1 s)
    var z0: Float = 0.5          // coarse match threshold: similarity above mean + z0 std scores positive
    var gap: Float = 0.5         // coarse gap penalty per frame after the first (std units)
    var gapOpen: Float = 8       // coarse cost of opening a gap
    var minGapRun = 3            // coarse gap run (frames) that splits segments
    var minSegment = 4.0         // seconds; shorter matched segments are dropped
    var band = 30                // fine frames each side of the coarse path
    var onsetWeight: Float = 1.0
    var offDiagonalPenalty: Float = 0.5
    var fitWindow = 0.4          // seconds each side for the path line fit
    var anchorStep = 0.1         // seconds of MIDI time between map anchors
    var refine = true            // onset refinement of the anchors
    var refineRange = 0.06
    var transpose: Int?          // fixed transposition (nil: search all 12)
    var twoPass = true           // second pass on the tempo-normalised MIDI
    var slopePenalty: Float = 0.5 // second pass: cost of each coarse tempo step ((2,1) or (1,2))

    /// The settings that the command line and roles.json can change, in their units (seconds for band and window).
    var summary: [String: Any] {
        ["band": Double(band) * bmHop, "coarse-window": Double(coarseWindow) * bmHop, "z0": Double(z0), "gap": Double(gap),
         "gap-open": Double(gapOpen), "onset-weight": Double(onsetWeight), "offdiag": Double(offDiagonalPenalty),
         "slope-penalty": Double(slopePenalty), "refine": refine, "two-pass": twoPass]
    }
}

nonisolated struct MapSegment: Codable {
    /// Increasing MIDI times and the recording times they map to (piecewise linear).
    var midi: [Double]
    var audio: [Double]
}

nonisolated struct TimeMap: Codable {
    var segments: [MapSegment]

    /// Recording time for a MIDI time, nil outside the matched segments.
    func audio(_ t: Double) -> Double? {
        for s in segments where t >= s.midi[0] && t <= s.midi[s.midi.count - 1] {
            return interp(s.midi, s.audio, t)
        }
        return nil
    }

    /// MIDI time for a recording time, nil outside the matched segments.
    func midi(_ a: Double) -> Double? {
        for s in segments where a >= s.audio[0] && a <= s.audio[s.audio.count - 1] {
            return interp(s.audio, s.midi, a)
        }
        return nil
    }

    var audioSpans: [(Double, Double)] { segments.map { ($0.audio[0], $0.audio[$0.audio.count - 1]) } }
    var midiSpans: [(Double, Double)] { segments.map { ($0.midi[0], $0.midi[$0.midi.count - 1]) } }
}

/// Linear interpolation in an increasing table (clamped at the ends).
func interp(_ xs: [Double], _ ys: [Double], _ x: Double) -> Double {
    if x <= xs[0] { return ys[0] }
    if x >= xs[xs.count - 1] { return ys[ys.count - 1] }
    var lo = 0, hi = xs.count - 1
    while hi - lo > 1 {
        let mid = (lo + hi) / 2
        if xs[mid] <= x { lo = mid } else { hi = mid }
    }
    let span = xs[hi] - xs[lo]
    return span > 0 ? ys[lo] + (ys[hi] - ys[lo]) * (x - xs[lo]) / span : ys[lo]
}

nonisolated struct CoarseCell { var i: Int; var j: Int; var step: UInt8 }   // step: 1 diag, 2 (2,1), 3 (1,2), 4 audio gap, 5 midi gap

nonisolated struct AlignResult {
    var transpose: Int
    /// Coarse local-alignment score per transposition (index = semitones up, 0...11).
    var scores: [Float]
    var map: TimeMap
    /// Coarse gap runs: recording spans the MIDI lacks, and MIDI spans the recording lacks.
    var audioOnly: [(Double, Double)]
    var midiOnly: [(Double, Double)]
    /// The fine paths (audio frame, MIDI frame), all segments, for diagnostics.
    var finePath: [(Int, Int)]
    var coarseStats: (mean: Float, std: Float)
    /// Recording seconds per MIDI second over the song (median).
    var rate: Double?
}

/// True for rows that are the flat vector (nothing sounding).
func flatRows(_ c: [Float], frames: Int) -> [Bool] {
    let flat = Float(1 / sqrt(12.0))
    return (0..<frames).map { i in (0..<12).allSatisfy { abs(c[i * 12 + $0] - flat) < 1e-6 } }
}

/// Coarse frames where at least half of the window's fine frames sound.
func coarseSounding(_ flat: [Bool], factor: Int, window: Int) -> [Bool] {
    let rows = (flat.count + factor - 1) / factor
    return (0..<rows).map { r in
        let center = r * factor + factor / 2
        let lo = max(0, center - window / 2), hi = min(flat.count, center + window / 2)
        guard hi > lo else { return false }
        return Double(flat[lo..<hi].filter { !$0 }.count) >= 0.5 * Double(hi - lo)
    }
}

/// Smoothed, unit-length chroma at the coarse rate.
func coarseChroma(_ c: [Float], frames: Int, factor: Int, window: Int) -> (rows: Int, m: [Float]) {
    let rows = (frames + factor - 1) / factor
    let w = (0..<window).map { Float(0.5 - 0.5 * cos(2 * Double.pi * (Double($0) + 0.5) / Double(window))) }
    var out = [Float](repeating: 0, count: rows * 12)
    for r in 0..<rows {
        let center = r * factor + factor / 2
        for k in 0..<window {
            let f = center - window / 2 + k
            guard f >= 0 && f < frames else { continue }
            for d in 0..<12 { out[r * 12 + d] += w[k] * c[f * 12 + d] }
        }
        var s: Float = 0
        for d in 0..<12 { s += out[r * 12 + d] * out[r * 12 + d] }
        let inv = s > 0 ? 1 / sqrt(s) : 0
        for d in 0..<12 { out[r * 12 + d] *= inv }
    }
    return (rows, out)
}

/// S = A * B^T for row-major A (na x d) and B (nb x d).
func similarity(_ a: [Float], _ na: Int, _ b: [Float], _ nb: Int, dims: Int) -> [Float] {
    var s = [Float](repeating: 0, count: na * nb)
    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, __LAPACK_int(na), __LAPACK_int(nb), __LAPACK_int(dims),
                1, a, __LAPACK_int(dims), b, __LAPACK_int(dims), 0, &s, __LAPACK_int(nb))
    return s
}

/// Local alignment over a coarse similarity matrix with affine gaps (Gotoh):
/// opening a gap costs `gapOpen`, each further frame `gap`, so material one
/// side lacks becomes one gap rather than many small ones. Returns (best score, path).
func localAlign(_ s: [Float], na: Int, nm: Int, mean: Float, std: Float, p: AlignParams,
                aSound: [Bool], mSound: [Bool], slopePenalty: Float = 0) -> (Float, [CoarseCell]) {
    let neg = -Float.greatestFiniteMagnitude / 4
    // backH: low 2 bits = step into the cell (0 start, 1 diag, 2 (2,1), 3 (1,2)), bits 2-3 = state it came from.
    var backH = [UInt8](repeating: 0, count: na * nm)
    var backX = [UInt8](repeating: 0, count: na * nm)   // state the audio gap came from
    var backY = [UInt8](repeating: 0, count: na * nm)   // state the MIDI gap came from
    var hp = [Float](repeating: neg, count: nm), xp = hp, yp = hp     // row i-1 per state
    var bp = hp, bp2 = hp                                              // best over states, rows i-1 and i-2
    var sp = [UInt8](repeating: 0, count: nm), sp2 = sp
    var hc = hp, xc = hp, yc = hp, bc = hp
    var scur = sp
    var best: Float = 0, bi = 0, bj = 0
    let inv = 1 / max(std, 1e-6)
    let open = p.gapOpen, ext = p.gap, slope = slopePenalty
    for i in 0..<na {
        for j in 0..<nm {
            // A silent frame on either side says nothing: neutral (z = 0).
            let sc = (aSound[i] && mSound[j] ? (s[i * nm + j] - mean) * inv : 0) - p.z0
            var v = neg, b: UInt8 = 0
            if sc > 0 { v = sc }   // a path may start here
            if i >= 1 && j >= 1 && bp[j - 1] > neg { let c = bp[j - 1] + sc; if c > v { v = c; b = 1 | (sp[j - 1] << 2) } }
            if i >= 2 && j >= 1 && bp2[j - 1] > neg { let c = bp2[j - 1] + 1.5 * sc - slope; if c > v { v = c; b = 2 | (sp2[j - 1] << 2) } }
            if i >= 1 && j >= 2 && bp[j - 2] > neg { let c = bp[j - 2] + 1.5 * sc - slope; if c > v { v = c; b = 3 | (sp[j - 2] << 2) } }
            hc[j] = v; backH[i * nm + j] = b
            var x = neg, bx: UInt8 = 0
            if i >= 1 {
                if hp[j] > neg, hp[j] - open > x { x = hp[j] - open; bx = 0 }
                if xp[j] > neg, xp[j] - ext > x { x = xp[j] - ext; bx = 1 }
                if yp[j] > neg, yp[j] - open > x { x = yp[j] - open; bx = 2 }
            }
            xc[j] = x; backX[i * nm + j] = bx
            var y = neg, by: UInt8 = 0
            if j >= 1 {
                if hc[j - 1] > neg, hc[j - 1] - open > y { y = hc[j - 1] - open; by = 0 }
                if yc[j - 1] > neg, yc[j - 1] - ext > y { y = yc[j - 1] - ext; by = 2 }
                if xc[j - 1] > neg, xc[j - 1] - open > y { y = xc[j - 1] - open; by = 1 }
            }
            yc[j] = y; backY[i * nm + j] = by
            var m = v, st: UInt8 = 0
            if x > m { m = x; st = 1 }
            if y > m { m = y; st = 2 }
            bc[j] = m; scur[j] = st
            if v > best { best = v; bi = i; bj = j }
        }
        swap(&bp2, &bp); swap(&bp, &bc)
        swap(&sp2, &sp); swap(&sp, &scur)
        swap(&hp, &hc); swap(&xp, &xc); swap(&yp, &yc)
    }
    var path: [CoarseCell] = []
    var i = bi, j = bj
    var state: UInt8 = 0
    while i >= 0 && j >= 0 {
        if state == 0 {
            let b = backH[i * nm + j]
            let step = b & 3
            path.append(CoarseCell(i: i, j: j, step: step))
            if step == 0 { break }
            state = b >> 2
            switch step { case 1: i -= 1; j -= 1; case 2: i -= 2; j -= 1; default: i -= 1; j -= 2 }
        } else if state == 1 {
            path.append(CoarseCell(i: i, j: j, step: 4))
            state = backX[i * nm + j]; i -= 1
        } else {
            path.append(CoarseCell(i: i, j: j, step: 5))
            state = backY[i * nm + j]; j -= 1
        }
    }
    path.reverse()
    // Gap steps at either end carry no match: trim them.
    while let last = path.last, last.step >= 4 { path.removeLast() }
    while path.count > 1, path[1].step >= 4 { path.removeFirst() }
    return (best, path)
}

/// Fine DTW in a band; returns the path (audio frame, MIDI frame).
func bandDTW(af: AudioFeatures, chromaM: [Float], onsetM: [Float], mFrames: Int, channels: [Int],
             start: (Int, Int), end: (Int, Int), jlo: [Int], jhi: [Int], p: AlignParams) -> [(Int, Int)] {
    let i0 = start.0, i1 = end.0
    let rows = i1 - i0 + 1
    var offs = [Int](repeating: 0, count: rows + 1)
    for r in 0..<rows { offs[r + 1] = offs[r] + max(0, jhi[r] - jlo[r] + 1) }
    let inf = Float.greatestFiniteMagnitude / 4
    var d = [Float](repeating: inf, count: offs[rows])
    var back = [UInt8](repeating: 0, count: offs[rows])
    func cost(_ i: Int, _ j: Int) -> Float {
        var dot: Float = 0
        for c in 0..<12 { dot += af.chroma[i * 12 + c] * chromaM[j * 12 + c] }
        var dist: Float = 0
        for c in channels { let x = af.onset[i * onsetDims + c] - onsetM[j * onsetDims + c]; dist += x * x }
        return (1 - dot) + p.onsetWeight * sqrt(dist)
    }
    func idx(_ r: Int, _ j: Int) -> Int? {
        guard r >= 0, r < rows, j >= jlo[r], j <= jhi[r] else { return nil }
        return offs[r] + j - jlo[r]
    }
    for r in 0..<rows {
        let i = i0 + r
        guard jlo[r] <= jhi[r] else { continue }
        for j in jlo[r]...jhi[r] {
            let c = cost(i, j)
            let k = offs[r] + j - jlo[r]
            if r == 0 && j == start.1 { d[k] = c; back[k] = 0; continue }
            var v = inf, b: UInt8 = 0
            if let q = idx(r - 1, j - 1), d[q] < inf { let x = d[q] + 2 * c; if x < v { v = x; b = 1 } }
            if let q = idx(r - 1, j), d[q] < inf { let x = d[q] + c + p.offDiagonalPenalty; if x < v { v = x; b = 2 } }
            if j - 1 >= jlo[r], d[k - 1] < inf { let x = d[k - 1] + c + p.offDiagonalPenalty; if x < v { v = x; b = 3 } }
            d[k] = v; back[k] = b
        }
    }
    // End cell, or the nearest reachable cell on the last row.
    var r = rows - 1
    var j = min(max(end.1, jlo[r]), jhi[r])
    if idx(r, j).map({ d[$0] >= inf }) ?? true {
        var bestJ = -1; var bestV = inf
        for jj in jlo[r]...jhi[r] { let k = offs[r] + jj - jlo[r]; if d[k] < bestV { bestV = d[k]; bestJ = jj } }
        if bestJ < 0 { return [] }
        j = bestJ
    }
    var path: [(Int, Int)] = []
    while r >= 0 {
        guard let k = idx(r, j) else { break }
        path.append((i0 + r, j))
        switch back[k] {
        case 1: r -= 1; j -= 1
        case 2: r -= 1
        case 3: j -= 1
        default: r = -1
        }
    }
    return path.reversed()
}

/// Pool-adjacent-violators: the closest non-decreasing sequence (least squares).
func isotonic(_ y: [Double]) -> [Double] {
    var vals: [Double] = [], wts: [Double] = [], lens: [Int] = []
    for v in y {
        vals.append(v); wts.append(1); lens.append(1)
        while vals.count > 1 && vals[vals.count - 2] > vals[vals.count - 1] {
            let w = wts[wts.count - 2] + wts[wts.count - 1]
            let m = (vals[vals.count - 2] * wts[wts.count - 2] + vals[vals.count - 1] * wts[wts.count - 1]) / w
            let l = lens[lens.count - 2] + lens[lens.count - 1]
            vals.removeLast(); wts.removeLast(); lens.removeLast()
            vals[vals.count - 1] = m; wts[wts.count - 1] = w; lens[lens.count - 1] = l
        }
    }
    var out: [Double] = []
    for (v, l) in zip(vals, lens) { out += [Double](repeating: v, count: l) }
    return out
}

/// Turns a fine path into map anchors: weighted local line fits of recording
/// time against MIDI time, every `anchorStep` seconds of MIDI time.
func pathToSegment(_ path: [(Int, Int)], weight: [Float], p: AlignParams) -> MapSegment? {
    guard let first = path.first, let last = path.last, last.1 > first.1 else { return nil }
    let j0 = first.1, j1 = last.1
    var sum = [Double](repeating: 0, count: j1 - j0 + 1), cnt = [Double](repeating: 0, count: j1 - j0 + 1)
    for (i, j) in path { sum[j - j0] += Double(i); cnt[j - j0] += 1 }
    let a = zip(sum, cnt).map { $1 > 0 ? $0 / $1 : 0 }   // every MIDI frame in [j0, j1] is on a monotone path
    let w = (j0...j1).map { Double(0.15 + min(1, $0 < weight.count ? weight[$0] : 0)) }
    let half = Int((p.fitWindow / bmHop).rounded())
    var midi: [Double] = [], audio: [Double] = []
    var t = Double(j0) * bmHop
    let tEnd = Double(j1) * bmHop
    while true {
        let jc = t / bmHop
        let lo = max(j0, Int(jc.rounded()) - half), hi = min(j1, Int(jc.rounded()) + half)
        var sw = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
        for j in lo...hi {
            let x = Double(j) - jc, y = a[j - j0], ww = w[j - j0]
            sw += ww; sx += ww * x; sy += ww * y; sxx += ww * x * x; sxy += ww * x * y
        }
        let den = sw * sxx - sx * sx
        var est = sy / sw
        if den > 1e-9 {
            let beta = (sw * sxy - sx * sy) / den
            let alpha = (sy - beta * sx) / sw
            if beta > 0.2 && beta < 5 { est = alpha }
        }
        midi.append(t); audio.append(est * bmHop)
        if t >= tEnd - 1e-9 { break }
        t = min(tEnd, t + p.anchorStep)
    }
    audio = isotonic(audio).map { max(0, $0) }
    // Strictly increasing for inversion.
    for k in 1..<audio.count where audio[k] <= audio[k - 1] { audio[k] = audio[k - 1] + 1e-4 }
    return MapSegment(midi: midi, audio: audio)
}

/// Nudges map anchors so warped MIDI onsets sit on the recording's onset novelty.
func refineSegment(_ seg: MapSegment, onsets: [(t: Double, w: Double)], novelty: [Float], p: AlignParams) -> MapSegment {
    // Smoothed novelty for a tolerant match.
    let sm = gaussianSmooth(novelty, sigma: 1.0)
    func nov(_ t: Double) -> Double {
        let x = t / bmHop
        let i = Int(floor(x))
        guard i >= 0 && i + 1 < sm.count else { return 0 }
        let f = x - Double(i)
        return Double(sm[i]) * (1 - f) + Double(sm[i + 1]) * f
    }
    let steps = Int((p.refineRange / 0.005).rounded())
    var shifts = [Double](repeating: 0, count: seg.midi.count)
    var have = [Bool](repeating: false, count: seg.midi.count)
    var oi = 0
    for (k, t) in seg.midi.enumerated() {
        while oi < onsets.count && onsets[oi].t < t - 1.0 { oi += 1 }
        var local: [(Double, Double)] = []
        var q = oi
        while q < onsets.count && onsets[q].t <= t + 1.0 {
            let d = onsets[q].t - t
            local.append((interp(seg.midi, seg.audio, onsets[q].t), onsets[q].w * exp(-d * d / (2 * 0.5 * 0.5))))
            q += 1
        }
        if local.count < 2 { continue }
        var bestS = 0.0, bestV = -1.0
        var scoreAt0 = 0.0
        for s in -steps...steps {
            let dt = Double(s) * 0.005
            var v = 0.0
            for (a, ww) in local { v += ww * nov(a + dt) }
            if s == 0 { scoreAt0 = v }
            if v > bestV + 1e-12 || (abs(v - bestV) <= 1e-12 && abs(dt) < abs(bestS)) { bestV = v; bestS = dt }
        }
        if bestV > scoreAt0 * 1.02 { shifts[k] = bestS } else { shifts[k] = 0 }
        have[k] = true
    }
    // Median over +-0.5 s of anchors, then add.
    let half = max(1, Int((0.5 / p.anchorStep).rounded()))
    var out = seg
    for k in seg.midi.indices {
        let window = (max(0, k - half)...min(seg.midi.count - 1, k + half)).filter { have[$0] }.map { shifts[$0] }.sorted()
        let m = window.isEmpty ? 0 : window[window.count / 2]
        out.audio[k] = seg.audio[k] + m
    }
    out.audio = isotonic(out.audio)
    for k in 1..<out.audio.count where out.audio[k] <= out.audio[k - 1] { out.audio[k] = out.audio[k - 1] + 1e-4 }
    return out
}

func gaussianSmooth(_ x: [Float], sigma: Double) -> [Float] {
    let r = Int(ceil(3 * sigma))
    let k = (-r...r).map { Float(exp(-Double($0 * $0) / (2 * sigma * sigma))) }
    let ks = k.reduce(0, +)
    return x.indices.map { i in
        var s: Float = 0
        for (o, w) in zip(-r...r, k) { let j = i + o; if j >= 0 && j < x.count { s += x[j] * w } }
        return s / ks
    }
}

/// Onset clusters of the notes (within 30 ms), weighted by summed velocity.
func onsetClusters(_ notes: [SymNote], includeDrums: Bool = true) -> [(t: Double, w: Double)] {
    let ons = notes.filter { includeDrums || !$0.drum }.map { ($0.on, Double(max($0.velocity, 1)) / 127) }.sorted { $0.0 < $1.0 }
    var out: [(t: Double, w: Double)] = []
    for (t, w) in ons {
        if let last = out.last, t - last.t < 0.03 { out[out.count - 1].w += w } else { out.append((t, w)) }
    }
    return out
}

/// Two passes: the first finds the transposition and the overall tempo ratio; the second aligns the MIDI
/// stretched by that ratio, with a cost on every tempo step, so the path keeps a steady slope unless the
/// music says otherwise (in loop-based songs, where many bars look alike, the path cannot slip a bar for free).
func align(af: AudioFeatures, sym: SymFeatures, notes: [SymNote], p: AlignParams, log: (String) -> Void = { _ in }) -> AlignResult? {
    guard let first = alignPass(af: af, sym: sym, notes: notes, p: p, slopePenalty: 0, log: log) else { return nil }
    guard p.twoPass, let rate = first.rate, rate > 0.3, rate < 3 else { return first }
    var p2 = p
    p2.transpose = first.transpose
    let scaled = notes.map { n -> SymNote in var x = n; x.on *= rate; x.off *= rate; return x }
    let dur = (Double(sym.frames) * bmHop) * rate
    let sym2 = computeSymbolicFeatures(scaled, duration: dur)
    guard var second = alignPass(af: af, sym: sym2, notes: scaled, p: p2, slopePenalty: p.slopePenalty, log: log) else { return first }
    log(String(format: "second pass: MIDI stretched x%.3f, %d tempo-step cost", rate, Int(p.slopePenalty * 10)))
    second.map.segments = second.map.segments.map { s in MapSegment(midi: s.midi.map { $0 / rate }, audio: s.audio) }
    second.midiOnly = second.midiOnly.map { ($0.0 / rate, $0.1 / rate) }
    second.finePath = second.finePath.map { ($0.0, Int((Double($0.1) / rate).rounded())) }
    second.scores = first.scores
    second.rate = rate
    return second
}

func alignPass(af: AudioFeatures, sym: SymFeatures, notes: [SymNote], p: AlignParams, slopePenalty: Float,
               log: (String) -> Void) -> AlignResult? {
    let (na, ac) = coarseChroma(af.chroma, frames: af.frames, factor: p.factor, window: p.coarseWindow)
    let (nm, mc) = coarseChroma(sym.chroma, frames: sym.frames, factor: p.factor, window: p.coarseWindow)
    guard na > 4, nm > 4 else { return nil }
    let ks = p.transpose.map { [(($0 % 12) + 12) % 12] } ?? Array(0..<12)
    let aSound = coarseSounding(flatRows(af.chroma, frames: af.frames), factor: p.factor, window: p.coarseWindow)
    let mSound = coarseSounding(flatRows(sym.chroma, frames: sym.frames), factor: p.factor, window: p.coarseWindow)
    // Similarity statistics over sounding cells, pooled over all 12 transpositions (even when one is fixed):
    // random matches dominate, so this is the level a chance match reaches.
    var sims: [Int: [Float]] = [:]
    var mean = 0.0, sq = 0.0, n = 0.0
    for k in 0..<12 {
        let s = similarity(ac, na, rollRows(mc, frames: nm, dims: 12, k: k), nm, dims: 12)
        for i in 0..<na where aSound[i] {
            for j in 0..<nm where mSound[j] { let x = Double(s[i * nm + j]); mean += x; sq += x * x; n += 1 }
        }
        if ks.contains(k) { sims[k] = s }
    }
    if n < 1 { return nil }
    let mu = Float(mean / n), sd = Float(sqrt(max(1e-12, sq / n - (mean / n) * (mean / n))))
    var scores = [Float](repeating: 0, count: 12)
    var bestK = ks[0], bestScore: Float = -1, bestPath: [CoarseCell] = []
    for k in ks {
        let (score, path) = localAlign(sims[k]!, na: na, nm: nm, mean: mu, std: sd, p: p, aSound: aSound, mSound: mSound,
                                       slopePenalty: slopePenalty)
        scores[k] = score
        if score > bestScore { bestScore = score; bestK = k; bestPath = path }
    }
    sims = [:]
    guard bestPath.count > 2 else { return nil }
    let chromaM = rollRows(sym.chroma, frames: sym.frames, dims: 12, k: bestK)
    let onsetM = rollRows(sym.onset, frames: sym.frames, dims: onsetDims, k: bestK)

    // Split at gap runs.
    var segments: [[CoarseCell]] = [[]]
    var audioOnly: [(Double, Double)] = [], midiOnly: [(Double, Double)] = []
    var run: [CoarseCell] = []
    func flushRun() {
        guard !run.isEmpty else { return }
        let aGaps = run.filter { $0.step == 4 }, mGaps = run.filter { $0.step == 5 }
        if run.count >= p.minGapRun {
            if !segments[segments.count - 1].isEmpty { segments.append([]) }
            let ct = Double(p.factor) * bmHop
            if let f = aGaps.first, let l = aGaps.last { audioOnly.append((Double(f.i) * ct, Double(l.i + 1) * ct)) }
            if let f = mGaps.first, let l = mGaps.last { midiOnly.append((Double(f.j) * ct, Double(l.j + 1) * ct)) }
        } else {
            segments[segments.count - 1] += run
        }
        run = []
    }
    for c in bestPath {
        if c.step >= 4 { run.append(c) } else { flushRun(); segments[segments.count - 1].append(c) }
    }
    flushRun()

    var mapSegs: [MapSegment] = []
    var fine: [(Int, Int)] = []
    let F = p.factor
    let onsetW = sym.onsetStrength.indices.map { i -> Float in
        var m: Float = 0
        for j in max(0, i - 2)...min(sym.onsetStrength.count - 1, i + 2) { m = max(m, sym.onsetStrength[j]) }
        return m
    }
    let clusters = onsetClusters(notes)
    // Drum-band channels count only when the MIDI has those drums (20+ hits); otherwise the recording's
    // drums would only add distance everywhere.
    var drumHits = [0, 0, 0]
    for n in notes where n.drum { if let c = drumChannel(n.pitch) { drumHits[c - 13] += 1 } }
    let channels = Array(0..<13) + (0..<3).filter { drumHits[$0] >= 20 }.map { 13 + $0 }
    for seg in segments where seg.count >= 2 {
        let ct = Double(F) * bmHop
        if Double(seg[seg.count - 1].i - seg[0].i) * ct < p.minSegment { continue }
        let iS = seg[0].i * F, jS = seg[0].j * F
        let iE = min(af.frames - 1, seg[seg.count - 1].i * F + F - 1), jE = min(sym.frames - 1, seg[seg.count - 1].j * F + F - 1)
        var jlo = [Int](repeating: Int.max, count: iE - iS + 1), jhi = [Int](repeating: Int.min, count: iE - iS + 1)
        // Band: every coarse cell (and the cells a (2,1)/(1,2) step skips) widened by `band`.
        var cells: [(Int, Int)] = []
        for (q, c) in seg.enumerated() {
            if q > 0 {
                let pr = seg[q - 1]
                if c.i - pr.i == 2 { cells.append((pr.i + 1, pr.j)); cells.append((pr.i + 1, c.j)) }
                if c.j - pr.j == 2 { cells.append((pr.i, pr.j + 1)); cells.append((c.i, pr.j + 1)) }
            }
            cells.append((c.i, c.j))
        }
        for (ci, cj) in cells {
            for i in (ci * F)..<(ci * F + F) where i >= iS && i <= iE {
                jlo[i - iS] = min(jlo[i - iS], cj * F - p.band)
                jhi[i - iS] = max(jhi[i - iS], cj * F + F - 1 + p.band)
            }
        }
        // Fill rows the cells missed, keep the band inside [jS, jE] and connected.
        for r in jlo.indices {
            if jlo[r] == Int.max { jlo[r] = r > 0 ? jlo[r - 1] : jS; jhi[r] = r > 0 ? jhi[r - 1] : jS + p.band }
            jlo[r] = max(jS, jlo[r]); jhi[r] = min(jE, jhi[r])
        }
        for r in 1..<jlo.count { jlo[r] = max(jlo[r], jlo[r - 1]); jhi[r] = max(jhi[r], jhi[r - 1]) }
        for r in stride(from: jlo.count - 2, through: 0, by: -1) { jhi[r] = min(jhi[r], jhi[r + 1]); jlo[r] = min(jlo[r], jlo[r + 1]) }
        for r in jlo.indices where jlo[r] > jhi[r] { jhi[r] = jlo[r] }
        jlo[0] = min(jlo[0], jS); jhi[jhi.count - 1] = max(jhi[jhi.count - 1], jE)
        let path = bandDTW(af: af, chromaM: chromaM, onsetM: onsetM, mFrames: sym.frames, channels: channels,
                           start: (iS, jS), end: (iE, jE), jlo: jlo, jhi: jhi, p: p)
        guard path.count > 10, var ms = pathToSegment(path, weight: onsetW, p: p) else { continue }
        if p.refine {
            let segOnsets = clusters.filter { $0.t >= ms.midi[0] && $0.t <= ms.midi[ms.midi.count - 1] }
            ms = refineSegment(ms, onsets: segOnsets, novelty: af.novelty, p: p)
        }
        mapSegs.append(ms)
        fine += path
    }
    guard !mapSegs.isEmpty else { return nil }
    log(String(format: "coarse: %d x %d frames, transposition +%d (score %.0f, next best %.0f)", na, nm, bestK, bestScore,
               scores.enumerated().filter { $0.offset != bestK }.map(\.element).max() ?? 0))
    // Overall tempo ratio (recording seconds per MIDI second): median slope over 10 s stretches of the map.
    var slopes: [Double] = []
    for seg in mapSegs {
        var k = 0
        while k < seg.midi.count {
            let q = min(seg.midi.count - 1, k + 100)
            if q > k + 50 { slopes.append((seg.audio[q] - seg.audio[k]) / (seg.midi[q] - seg.midi[k])) }
            k += 100
        }
    }
    slopes.sort()
    let rate: Double? = slopes.isEmpty ? nil : slopes[slopes.count / 2]
    return AlignResult(transpose: bestK, scores: scores, map: TimeMap(segments: mapSegs), audioOnly: audioOnly,
                       midiOnly: midiOnly, finePath: fine, coarseStats: (mu, sd), rate: rate)
}
