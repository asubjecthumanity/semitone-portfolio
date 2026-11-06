import Foundation
import AudioToolbox

// Confidence per section, the RealBench key (realbench-truth-1) built from an
// aligned MIDI, an octave check per voice, and the aligned MIDI for listening.

nonisolated struct SectionConfidence: Codable {
    var label: String
    var midiStart: Double, midiEnd: Double
    var audioStart: Double, audioEnd: Double
    /// Mean chroma cosine along the map, and the same MIDI frames against recording frames 4-11 s away.
    var chromaSim: Double, chromaBackground: Double
    /// Warped MIDI onset clusters (drums included); the share within 50 ms of a recording onset peak, and the
    /// share of the section's time within 50 ms of a peak (what random onsets would score).
    var onsets: Int
    var hit50: Double, chance50: Double
    /// Lag profile: mean recording onset novelty at the warped MIDI onsets shifted by -250...+250 ms.
    /// `onsetLag` is the best lag (ms); `onsetContrast` is 1 - (mean at +-40...100 ms) / (value at 0):
    /// near 1 when the onsets sit on the recording's onsets, near 0 when they do not.
    var onsetLag: Double, onsetContrast: Double
    /// Kick and snare check: the MIDI's kick and snare hits scored on the recording's kick and snare bands
    /// with the MIDI shifted by -1, 0, +1 beat; `drumBeatShift` is -1 or +1 when a shifted MIDI fits clearly
    /// (15%) better, else 0; `drumHits` is how many hits took part (8 needed).
    var drumBeatShift: Int, drumHits: Int
    /// The section's kick and snare pattern repeats every beat (for example a kick on every beat and no
    /// snare), so a one-beat shift looks the same and the kick/snare check is skipped.
    var drumPeriodic: Bool = false
    /// Chroma beat-phase reading (information, not a flag): chroma similarity along the map with the MIDI
    /// shifted by -2...+2 beats; `chromaBeatShift` is the best shift and `chromaBeatGain` how much better
    /// it is than no shift (0 when no shift is best). Chords that change on the bar line make a one-beat
    /// slip visible here even when the drums cannot show it.
    var chromaBeatShift: Int = 0, chromaBeatGain: Double = 0
    /// Tempo steadiness: median relative deviation of the map's 1 s slopes from the section's slope.
    /// A fan MIDI against the real song keeps a steady ratio (a few %); a forced match wobbles.
    var slopeJitter: Double
    /// Chroma similarity along the map with the chosen transposition minus the best other transposition.
    var keyMargin: Double
    /// Share of the section's MIDI frames with a pitched note sounding.
    var midiSounding: Double
    var low: Bool
    var reason: String
}

nonisolated struct ConfidenceRules {
    var minChromaLift = 0.04      // chromaSim - chromaBackground
    var minOnsetContrast = 0.3
    var maxOnsetLag = 0.03        // seconds; a better lag elsewhere (by more than 10%) flags the section
    var minOnsets = 6
    var minSounding = 0.3
    var maxSlopeJitter = 0.10
    var minKeyMargin = 0.03
}

/// Sections of 4 MIDI bars (8 s when the MIDI has no bars) inside the matched segments.
func sectionConfidence(af: AudioFeatures, sym: SymFeatures, notes: [SymNote], midi: MidiContents, res: AlignResult,
                       rules: ConfidenceRules = ConfidenceRules()) -> [SectionConfidence] {
    let chromaM = rollRows(sym.chroma, frames: sym.frames, dims: 12, k: res.transpose)
    // Frames where pitched MIDI notes sound.
    var sounding = [Bool](repeating: false, count: sym.frames)
    for n in notes where !n.drum {
        let a = max(0, Int((n.on / bmHop).rounded())), b = min(sym.frames - 1, Int((n.off / bmHop).rounded()))
        if a <= b { for f in a...b { sounding[f] = true } }
    }
    let clusters = onsetClusters(notes)
    let peaks = af.peaks
    let nov = gaussianSmooth(af.novelty, sigma: 0.5)
    func novAt(_ t: Double) -> Double {
        let x = t / bmHop, i = Int(floor(x))
        guard i >= 0 && i + 1 < nov.count else { return 0 }
        return Double(nov[i]) * (1 - (x - Double(i))) + Double(nov[i + 1]) * (x - Double(i))
    }
    let lags = Array(stride(from: -250, through: 250, by: 5)).map { Double($0) / 1000 }
    // Kick and snare bands, each scaled by its mean so they weigh alike.
    let bandCurves = af.bandNovelty.prefix(2).map { c -> [Float] in
        let m = max(c.reduce(0, +) / Float(max(1, c.count)), 1e-9)
        return gaussianSmooth(c, sigma: 0.5).map { $0 / m }
    }
    func bandAt(_ q: Int, _ t: Double) -> Double {
        let i = Int((t / bmHop).rounded())
        return i >= 0 && i < bandCurves[q].count ? Double(bandCurves[q][i]) : 0
    }
    let kickSnare = notes.filter { $0.drum && (drumChannel($0.pitch) == 13 || drumChannel($0.pitch) == 14) }
        .map { (t: $0.on, q: drumChannel($0.pitch)! - 13, w: Double(max($0.velocity, 1)) / 127) }
    func nearestPeak(_ t: Double) -> Double {
        var lo = 0, hi = peaks.count
        while lo < hi { let m = (lo + hi) / 2; if peaks[m] < t { lo = m + 1 } else { hi = m } }
        var d = Double.infinity
        if lo < peaks.count { d = min(d, abs(peaks[lo] - t)) }
        if lo > 0 { d = min(d, abs(peaks[lo - 1] - t)) }
        return d
    }
    var bounds: [Double] = []
    let downs = midi.downbeats
    if downs.count >= 2 {
        var k = 0
        while k < downs.count { bounds.append(downs[k]); k += 4 }
        if let last = midi.beats.last, last > bounds.last! + 0.5 { bounds.append(last) }
    } else {
        var t = 0.0
        while t < sym.frames.d * bmHop { bounds.append(t); t += 8 }
    }
    var out: [SectionConfidence] = []
    for (si, seg) in res.map.segments.enumerated() {
        let m0 = seg.midi[0], m1 = seg.midi[seg.midi.count - 1]
        var edges = [m0] + bounds.filter { $0 > m0 + 0.5 && $0 < m1 - 0.5 } + [m1]
        edges = edges.sorted()
        for e in 0..<(edges.count - 1) {
            let a = edges[e], b = edges[e + 1]
            guard b - a > 0.5 else { continue }
            let barA = downs.lastIndex { $0 <= a + 0.05 }.map { $0 + 1 } ?? 1
            let barB = max(barA, downs.lastIndex { $0 < b - 0.05 }.map { $0 + 1 } ?? 1)
            let label = downs.count >= 2 ? "bars \(barA)-\(barB)" : String(format: "%.0f-%.0f s", a, b)
            var sim = 0.0, bg = 0.0, nSim = 0, nBg = 0, nSound = 0, nAll = 0
            var j = Int((a / bmHop).rounded())
            while Double(j) * bmHop < b && j < sym.frames {
                nAll += 1
                if sounding[j], let at = res.map.audio(Double(j) * bmHop) {
                    nSound += 1
                    let i = Int((at / bmHop).rounded())
                    if i >= 0 && i < af.frames {
                        var d: Float = 0
                        for c in 0..<12 { d += af.chroma[i * 12 + c] * chromaM[j * 12 + c] }
                        sim += Double(d); nSim += 1
                        for off in [-550, -350, -200, 200, 350, 550] {
                            let ii = i + off
                            guard ii >= 0 && ii < af.frames else { continue }
                            var x: Float = 0
                            for c in 0..<12 { x += af.chroma[ii * 12 + c] * chromaM[j * 12 + c] }
                            bg += Double(x); nBg += 1
                        }
                    }
                }
                j += 2
            }
            let aa = res.map.audio(a) ?? seg.audio[0], ab = res.map.audio(b) ?? seg.audio[seg.audio.count - 1]
            let localW = clusters.filter { $0.t >= a && $0.t < b }.compactMap { c in res.map.audio(c.t).map { ($0, c.w) } }
            let local = localW.map(\.0)
            let d = local.map(nearestPeak)
            let hit50 = d.isEmpty ? 0 : Double(d.filter { $0 <= 0.05 }.count) / Double(d.count)
            var c50 = 0, cn = 0
            var t = aa
            while t < ab { if nearestPeak(t) <= 0.05 { c50 += 1 }; cn += 1; t += 0.01 }
            let ch50 = cn > 0 ? Double(c50) / Double(cn) : 0
            var profile = [Double](repeating: 0, count: lags.count)
            for (at, w) in localW { for (k, l) in lags.enumerated() { profile[k] += w * novAt(at + l) } }
            let zero = profile[lags.count / 2]
            let pmax = profile.max() ?? 0
            let bestLag = pmax > 0 ? lags[profile.firstIndex(of: pmax)!] : 0
            let side = lags.indices.filter { abs(lags[$0]) >= 0.04 && abs(lags[$0]) <= 0.1 }.map { profile[$0] }
            let contrast = zero > 0 ? 1 - side.reduce(0, +) / Double(max(1, side.count)) / zero : 0
            let simM = nSim > 0 ? sim / Double(nSim) : 0, bgM = nBg > 0 ? bg / Double(nBg) : 0
            let soundShare = nAll > 0 ? Double(nSound) / Double(nAll) : 0
            var reasons: [String] = []
            if soundShare < rules.minSounding { reasons.append("MIDI nearly silent") }
            if nSim > 0 && simM - bgM < rules.minChromaLift { reasons.append(String(format: "chroma lift %.2f", simM - bgM)) }
            // Tempo steadiness and key margin.
            var sl: [Double] = []
            var tt = a
            while tt + 1 <= b { if let x = res.map.audio(tt), let y = res.map.audio(tt + 1) { sl.append(y - x) }; tt += 0.5 }
            let secSlope = (ab - aa) / max(1e-6, b - a)
            let jit = sl.isEmpty ? 0 : sl.map { abs($0 / max(1e-6, secSlope) - 1) }.sorted()[sl.count / 2]
            var simK = [Double](repeating: 0, count: 12), nK = 0
            var jj = Int((a / bmHop).rounded())
            while Double(jj) * bmHop < b && jj < sym.frames {
                if sounding[jj], let at = res.map.audio(Double(jj) * bmHop) {
                    let i = Int((at / bmHop).rounded())
                    if i >= 0 && i < af.frames {
                        nK += 1
                        for k in 0..<12 {
                            var d: Float = 0
                            for c in 0..<12 { d += af.chroma[i * 12 + ((c + k) % 12)] * sym.chroma[jj * 12 + c] }
                            simK[k] += Double(d)
                        }
                    }
                }
                jj += 4
            }
            let kc = res.transpose
            let margin = nK > 0 ? (simK[kc] - (0..<12).filter { $0 != kc }.map { simK[$0] }.max()!) / Double(nK) : 0
            // Beat-phase check with the kick and snare.
            let localBeats = midi.beats.filter { $0 >= a - 2 && $0 <= b + 2 }
            var beatShift = 0, hitsUsed = 0, periodic = false
            var chromaShift = 0, chromaGain = 0.0
            if localBeats.count >= 3 {
                let gaps = zip(localBeats.dropFirst(), localBeats).map { $0 - $1 }.sorted()
                let beatP = gaps[gaps.count / 2]
                // Chroma beat phase: the same sounding MIDI frames against the recording at the map
                // shifted by -2...+2 beats (frames where any shift falls outside the map are skipped).
                var cs = [Double](repeating: 0, count: 5), nc = 0
                var jc = Int((a / bmHop).rounded())
                while Double(jc) * bmHop < b && jc < sym.frames {
                    let t = Double(jc) * bmHop
                    if sounding[jc] {
                        let idx = (-2...2).map { k in res.map.audio(t + Double(k) * beatP).map { Int(($0 / bmHop).rounded()) } }
                        if idx.allSatisfy({ $0 != nil && $0! >= 0 && $0! < af.frames }) {
                            nc += 1
                            for (k, i) in idx.enumerated() {
                                var d: Float = 0
                                for c in 0..<12 { d += af.chroma[i! * 12 + c] * chromaM[jc * 12 + c] }
                                cs[k] += Double(d)
                            }
                        }
                    }
                    jc += 2
                }
                if nc >= 10, let best = cs.indices.max(by: { cs[$0] < cs[$1] }), cs[2] > 0 {
                    chromaShift = best - 2
                    chromaGain = cs[best] / cs[2] - 1
                }
                // A kick/snare pattern that repeats every beat cannot show a one-beat shift: compare the
                // pattern (hits on a half-beat grid) with itself moved by one beat.
                func pattern(_ q: Int) -> Set<Int> {
                    Set(kickSnare.filter { $0.q == q && $0.t >= a && $0.t < b }.map { Int((($0.t - a) / (beatP / 2)).rounded()) })
                }
                periodic = [0, 1].allSatisfy { q in
                    let p = pattern(q)
                    guard !p.isEmpty else { return true }
                    let up = p.filter { p.contains($0 + 2) || $0 + 2 > Int(((b - a) / (beatP / 2)).rounded()) }.count
                    let down = p.filter { p.contains($0 - 2) || $0 - 2 < 0 }.count
                    return Double(min(up, down)) >= 0.9 * Double(p.count)
                }
                var score = [Double](repeating: 0, count: 5)
                for h in kickSnare where h.t >= a && h.t < b {
                    let mapped = (-2...2).map { res.map.audio(h.t + Double($0) * beatP) }
                    if mapped.contains(where: { $0 == nil }) { continue }
                    hitsUsed += 1
                    for (k, at) in mapped.enumerated() { score[k] += h.w * bandAt(h.q, at!) }
                }
                if ProcessInfo.processInfo.environment["BITMIDI_DEBUG"] != nil {
                    FileHandle.standardError.write("drum phase \(a)-\(b): hits \(hitsUsed) scores \(score.map { String(format: "%.1f", $0) })\n".data(using: .utf8)!)
                }
                // Only +-1 beat: most grooves repeat every 2 beats (kick on 1 and 3, snare on 2 and 4), so a
                // 2-beat shift looks the same and its score is noise.
                if hitsUsed >= 8, !periodic, let best = [1, 3].max(by: { score[$0] < score[$1] }), score[best] > 1.15 * score[2] {
                    beatShift = best - 2
                }
            }
            if sl.count >= 4 && jit > rules.maxSlopeJitter { reasons.append(String(format: "tempo wobbles %.0f%%", 100 * jit)) }
            if nK >= 10 && margin < rules.minKeyMargin { reasons.append(String(format: "key margin %.2f", margin)) }
            if beatShift != 0 { reasons.append("kick/snare line up better \(beatShift > 0 ? "+" : "")\(beatShift) beat\(abs(beatShift) > 1 ? "s" : "")") }
            if d.count >= rules.minOnsets {
                if abs(bestLag) > rules.maxOnsetLag && zero < 0.9 * pmax {
                    reasons.append(String(format: "onsets line up best at %+.0f ms", bestLag * 1000))
                } else if contrast < rules.minOnsetContrast {
                    reasons.append(String(format: "onset contrast %.2f", contrast))
                }
            }
            out.append(SectionConfidence(label: label + (res.map.segments.count > 1 ? " (segment \(si + 1))" : ""),
                                         midiStart: r3(a), midiEnd: r3(b), audioStart: r3(aa), audioEnd: r3(ab),
                                         chromaSim: r3(simM), chromaBackground: r3(bgM), onsets: d.count,
                                         hit50: r3(hit50), chance50: r3(ch50), onsetLag: r3(bestLag * 1000), onsetContrast: r3(contrast),
                                         drumBeatShift: beatShift, drumHits: hitsUsed, drumPeriodic: periodic && hitsUsed >= 8,
                                         chromaBeatShift: chromaShift, chromaBeatGain: r3(chromaGain),
                                         slopeJitter: r3(jit), keyMargin: r3(margin),
                                         midiSounding: r3(soundShare), low: !reasons.isEmpty, reason: reasons.joined(separator: ", ")))
        }
    }
    return out
}

extension Int { var d: Double { Double(self) } }
func r3(_ x: Double) -> Double { x.isFinite ? (x * 1000).rounded() / 1000 : 0 }
func r4(_ x: Double) -> Double { x.isFinite ? (x * 10_000).rounded() / 10_000 : 0 }

/// Merges overlapping or touching spans (within `gap` seconds).
func mergeSpans(_ spans: [(Double, Double)], gap: Double = 0.05) -> [(Double, Double)] {
    var out: [(Double, Double)] = []
    for s in spans.filter({ $0.1 > $0.0 }).sorted(by: { $0.0 < $1.0 }) {
        if let l = out.last, s.0 <= l.1 + gap { out[out.count - 1].1 = max(l.1, s.1) } else { out.append(s) }
    }
    return out
}

/// Recording spans to leave out of the key: everything outside the matched
/// segments, the low-confidence sections, and any extra spans.
func ignoreSpans(duration: Double, map: TimeMap, sections: [SectionConfidence], extra: [(Double, Double)]) -> [(Double, Double)] {
    var spans: [(Double, Double)] = []
    var cursor = 0.0
    for (a, b) in map.audioSpans.sorted(by: { $0.0 < $1.0 }) {
        if a > cursor + 0.01 { spans.append((cursor, a)) }
        cursor = max(cursor, b)
    }
    if cursor < duration - 0.01 { spans.append((cursor, duration)) }
    spans += sections.filter(\.low).map { ($0.audioStart, $0.audioEnd) }
    spans += extra
    return mergeSpans(spans).map { (r3($0.0), r3($0.1)) }
}

// MARK: - Notes per role

nonisolated struct KeyNote { var on: Double; var off: Double; var pitch: Int; var velocity: Int; var part: String; var instrument: String; var voice: Int }

/// Splits a polyphonic voice into its top (or bottom) line and the rest.
func splitLine(_ notes: [SymNote], top: Bool) -> (line: [SymNote], rest: [SymNote]) {
    var line: [SymNote] = [], rest: [SymNote] = []
    for (k, n) in notes.enumerated() {
        // Notes struck with it (within 30 ms) or still sounding at its onset.
        var beaten = false
        for (q, o) in notes.enumerated() where q != k {
            let together = abs(o.on - n.on) <= 0.03 || (o.on < n.on - 0.03 && o.off > n.on + 0.05)
            if together && (top ? o.pitch > n.pitch : o.pitch < n.pitch) { beaten = true; break }
            if o.on > n.on + 0.05 { break }
        }
        if beaten { rest.append(n) } else { line.append(n) }
    }
    return (line, rest)
}

/// The pitched notes of every voice with a role, in MIDI time, pitch unshifted.
func roleNotes(_ m: BMMidi) -> [(SymNote, String)] {
    var out: [(SymNote, String)] = []
    for (vi, v) in m.voices.enumerated() {
        let ns = m.notes.filter { $0.voice == vi }
        switch v.role {
        case "melody", "countermelody", "chords", "bass": out += ns.map { ($0, v.role) }
        case "melody+chords", "melody+countermelody":
            let (l, r) = splitLine(ns, top: true)
            out += l.map { ($0, "melody") } + r.map { ($0, v.role == "melody+chords" ? "chords" : "countermelody") }
        case "chords+bass":
            let (l, r) = splitLine(ns, top: false)
            out += l.map { ($0, "bass") } + r.map { ($0, "chords") }
        default: break
        }
    }
    return out
}

nonisolated struct KeyResult {
    var truth: [String: Any]
    var notes: [KeyNote]
    var chords: [ChordSpan]
    var ignore: [(Double, Double)]
    var warnings: [String]
    var keyName: String
    var bpm: Double
}

/// Per-song fixes from roles.json that shape the key (not the alignment).
nonisolated struct KeyOptions {
    /// Extra recording spans to leave out.
    var ignore: [(Double, Double)] = []
    /// Beats to move the bar lines by (the MIDI's bar 1 is not the song's), counted in key beats.
    var barShift = 0
    /// 0.5 keeps every other MIDI beat (the MIDI counts twice the song's tempo); 2 adds a beat between MIDI beats.
    var tempoScale = 1.0
    /// Beats per bar for the key (replaces the MIDI's meter; bars then run from the first downbeat).
    var beatsPerBar: Int? = nil
    /// Recording spans whose flagged sections are kept (roles.json "trust").
    var trust: [(Double, Double)] = []

    init() {}
    init(_ r: RolesFile) {
        ignore = r.ignore.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
        barShift = r.barShift ?? 0
        tempoScale = r.tempoScale ?? 1
        beatsPerBar = r.beatsPerBar
        trust = (r.trust ?? []).compactMap { $0.count == 2 && $0[1] > $0[0] ? ($0[0], $0[1]) : nil }
    }
    var summary: [String: Any] { ["barShift": barShift, "tempoScale": tempoScale, "beatsPerBar": beatsPerBar ?? 0,
                                  "trust": trust.map { [$0.0, $0.1] }] }
}

/// The key's beat grid in MIDI time: the MIDI's beats and bars, rescaled and re-barred as asked.
func keyGrid(_ mc: MidiContents, _ o: KeyOptions, warnings: inout [String]) -> (beats: [Double], downs: [Double], perBar: Int) {
    var beats = mc.beats
    var bpb = mc.beatsPerBar ?? 4
    let firstDown = mc.downbeats.first.flatMap { d in beats.firstIndex { abs($0 - d) < 1e-6 } } ?? 0
    var downIdx = Set(mc.downbeats.compactMap { d in beats.firstIndex { abs($0 - d) < 1e-6 } })
    if o.tempoScale == 0.5 {
        let keep = beats.indices.filter { ($0 - firstDown) % 2 == 0 }
        downIdx = Set(keep.enumerated().filter { downIdx.contains($0.element) }.map(\.offset))
        beats = keep.map { beats[$0] }
        bpb = max(1, bpb / 2)
    } else if o.tempoScale == 2 {
        var out: [Double] = [], newDown = Set<Int>()
        for (k, b) in beats.enumerated() {
            if downIdx.contains(k) { newDown.insert(out.count) }
            out.append(b)
            if k + 1 < beats.count { out.append((b + beats[k + 1]) / 2) }
        }
        beats = out; downIdx = newDown; bpb *= 2
    } else if o.tempoScale != 1 {
        warnings.append("tempoScale \(o.tempoScale) ignored (use 0.5 or 2)")
    }
    if let n = o.beatsPerBar { bpb = n }
    var downs = beats.indices.filter { downIdx.contains($0) }.map { beats[$0] }
    if o.beatsPerBar != nil || o.barShift != 0 {
        let phase = (downIdx.min() ?? 0) + o.barShift
        downs = beats.indices.filter { ((($0 - phase) % bpb) + bpb) % bpb == 0 }.map { beats[$0] }
        if Set(mc.meters.map { "\($0.num)/\($0.den)" }).count > 1 {
            warnings.append("barShift/beatsPerBar replace the MIDI's meter changes with a constant \(bpb) beats per bar")
        }
    }
    return (beats, downs, bpb)
}

/// Builds the realbench-truth-1 key.
func buildKey(m: BMMidi, res: AlignResult, semitones: Int, sections: [SectionConfidence], audioDuration: Double,
              options: KeyOptions, name: String, source: String) -> KeyResult {
    var warnings: [String] = []
    let ignore = ignoreSpans(duration: audioDuration, map: res.map, sections: sections, extra: options.ignore)
    func ignored(_ t: Double) -> Bool { ignore.contains { t >= $0.0 && t < $0.1 } }
    let rn = roleNotes(m)
    var notes: [KeyNote] = []
    for (n, part) in rn {
        guard let on = res.map.audio(n.on) else { continue }
        let off = res.map.audio(n.off) ?? (on + (n.off - n.on))
        guard !ignored(on) else { continue }
        let v = m.voices[n.voice]
        let pitch = n.pitch + semitones + v.addTranspose
        guard pitch >= 0 && pitch <= 127 else { continue }
        notes.append(KeyNote(on: r4(on), off: r4(max(off, on + 0.01)), pitch: pitch, velocity: n.velocity, part: part,
                             instrument: v.name.isEmpty ? v.programName : "\(v.name) (\(v.programName))", voice: n.voice))
    }
    // Unisons: one note per pitch and onset (within 50 ms), the higher role kept.
    let priority = ["melody": 0, "bass": 1, "countermelody": 2, "chords": 3]
    notes.sort { ($0.on, priority[$0.part] ?? 9) < ($1.on, priority[$1.part] ?? 9) }
    var kept: [KeyNote] = []
    var byPitchLast: [Int: Int] = [:]
    var merged = 0
    for n in notes {
        if let k = byPitchLast[n.pitch], n.on - kept[k].on < 0.05 {
            if (priority[n.part] ?? 9) < (priority[kept[k].part] ?? 9) { kept[k].part = n.part; kept[k].instrument = n.instrument }
            kept[k].off = max(kept[k].off, n.off)
            merged += 1
            continue
        }
        byPitchLast[n.pitch] = kept.count
        kept.append(n)
    }
    if merged > 0 { warnings.append("\(merged) unison doublings merged (same pitch, onsets within 50 ms)") }

    // Beat grid from the MIDI's tempo map and meter, warped.
    let mc = m.contents
    if Set(mc.meters.map { "\($0.num)/\($0.den)" }).count > 1 {
        warnings.append("meter changes: " + mc.meters.map { String(format: "%d/%d at %.1f s", $0.num, $0.den, $0.seconds) }.joined(separator: ", "))
    }
    let grid = keyGrid(mc, options, warnings: &warnings)
    let bpb = grid.perBar
    let beats = grid.beats.compactMap { res.map.audio($0) }.map(r4)
    let downs = grid.downs.compactMap { res.map.audio($0) }.map(r4)
    let gaps = zip(beats.dropFirst(), beats).map { $0 - $1 }.filter { $0 > 0 }.sorted()
    let bpm = gaps.isEmpty ? 0 : 60 / gaps[gaps.count / 2]
    if bpm > 0 && (bpm > 170 || bpm < 55) {
        warnings.append(String(format: "the key's tempo is %.0f BPM: if the song is felt at %.0f BPM, set \"tempoScale\": %@ in roles.json", bpm,
                               bpm > 170 ? bpm / 2 : bpm * 2, bpm > 170 ? "0.5" : "2"))
    }

    // Chords per MIDI beat from the harmony (chords role; countermelody at a third; bass for the inversion).
    var pcw = [Double](repeating: 0, count: 12)
    for (n, part) in rn where part != "melody" { pcw[((n.pitch + semitones) % 12 + 12) % 12] += (n.off - n.on) }
    let key = estimateKey(pcw)
    func sounding(_ n: SymNote) -> Int { n.pitch + semitones + m.voices[n.voice].addTranspose }
    var harmony = rn.filter { $0.1 == "chords" }.map { ($0.0.on, $0.0.off, sounding($0.0), 1.0) }
    harmony += rn.filter { $0.1 == "countermelody" }.map { ($0.0.on, $0.0.off, sounding($0.0), 0.33) }
    if harmony.isEmpty {
        warnings.append("no chords-role voice: chords come from the bass and countermelody only")
        harmony = rn.filter { $0.1 != "melody" }.map { ($0.0.on, $0.0.off, sounding($0.0), 1.0) }
    }
    var bassNotes = rn.filter { $0.1 == "bass" }.map { ($0.0.on, $0.0.off, sounding($0.0)) }
    if bassNotes.isEmpty && !harmony.isEmpty {
        // No bass voice (an arrangement without a bass part): the lowest chord note sounding through a quarter
        // of the beat stands in for the bass when naming chords, so an add9 or drone voicing keeps its root.
        bassNotes = rn.filter { $0.1 == "chords" }.map { ($0.0.on, $0.0.off, sounding($0.0)) }
        if !bassNotes.isEmpty { warnings.append("no bass voice: chords are named with the lowest chord note as the bass") }
    }
    let midiChords = deriveChords(harmony: harmony, bass: bassNotes, beats: grid.beats, names: key.names)
    var chords: [ChordSpan] = []
    for c in midiChords {
        guard let a = res.map.audio(c.start), let b = res.map.audio(c.end), b > a else { continue }
        chords.append(ChordSpan(start: r4(a), end: r4(b), label: c.label))
    }

    var byPart: [String: Int] = [:]
    for n in kept { byPart[n.part, default: 0] += 1 }
    for role in ["melody", "bass", "chords"] where byPart[role] == nil { warnings.append("no \(role) notes in the key") }
    let truth: [String: Any] = [
        "format": "realbench-truth-1",
        "name": name,
        "source": source,
        "comment": "Fan-made MIDI aligned to the recording (Tools/RealBench/bitmidi). The MIDI is an arrangement: notes are approximate (notesComplete false, offsetsReliable false); beats, downbeats and chords are the MIDI's, warped. Spans the alignment does not trust are in ignore.",
        "notesComplete": false,
        "offsetsReliable": false,
        "notes": kept.map { ["on": $0.on, "off": $0.off, "pitch": $0.pitch, "velocity": $0.velocity, "part": $0.part, "instrument": $0.instrument] as [String: Any] },
        "beats": beats,
        "downbeats": downs,
        "beatsPerBar": bpb,
        "chords": chords.map { ["start": $0.start, "end": $0.end, "label": $0.label] as [String: Any] },
        "ignore": ignore.map { [$0.0, $0.1] },
    ]
    return KeyResult(truth: truth, notes: kept, chords: chords, ignore: ignore, warnings: warnings,
                     keyName: "\(key.names[key.tonic]) \(key.mode)", bpm: bpm)
}

// MARK: - Octave check

/// For each pitched voice with a role, two readings of where its notes sound in the recording, with the
/// key's pitches shifted by -24...+24 semitones (log pitch energy, STFT 4096, trusted spans only):
/// - level: energy during the notes (first 400 ms) above the frame's median band;
/// - rise: energy 80-200 ms after each onset minus 120-250 ms before it.
/// When both put the strongest shift at the same place, that is the suggestion; otherwise it is unclear.
/// Other parts on the same pitch classes (a bass under a riff, a pad doubling the tune) blur both
/// readings, and bass fundamentals below about 55 Hz are not measured: a hint, to confirm by ear.
func octaveCheck(m: BMMidi, res: AlignResult, af: AudioFeatures, semitones: Int, ignore: [(Double, Double)]) -> [String] {
    let bands = af.pitchHi - af.pitchLo + 1
    var med = [Float](repeating: 0, count: af.frames)
    for i in 0..<af.frames {
        let row = af.pitchLog[(i * bands)..<((i + 1) * bands)].sorted()
        med[i] = row[row.count / 2]
    }
    func energy(_ band: Int, _ a: Double, _ b: Double, relative: Bool) -> Double? {
        let f0 = max(0, Int((a / bmHop).rounded())), f1 = min(af.frames - 1, Int((b / bmHop).rounded()))
        guard f1 >= f0 else { return nil }
        var s = 0.0
        for f in f0...f1 { s += Double(af.pitchLog[f * bands + band] - (relative ? med[f] : 0)) }
        return s / Double(f1 - f0 + 1)
    }
    let shifts = [-24, -12, 0, 12, 24]
    var lines: [String] = []
    let rn = roleNotes(m)
    for (vi, v) in m.voices.enumerated() where ["melody", "countermelody", "chords", "bass", "melody+chords", "melody+countermelody", "chords+bass"].contains(v.role) {
        var level: [Int: (Double, Int)] = [:], rise: [Int: (Double, Int)] = [:]
        for (n, _) in rn where n.voice == vi {
            guard let on = res.map.audio(n.on), !ignore.contains(where: { on >= $0.0 && on < $0.1 }) else { continue }
            let off = res.map.audio(n.off) ?? on + (n.off - n.on)
            for s in shifts {
                let band = n.pitch + semitones + v.addTranspose + s - af.pitchLo
                guard band >= 0 && band < bands else { continue }
                if let l = energy(band, on + 0.03, min(off, on + 0.4), relative: true) {
                    let e = level[s] ?? (0, 0); level[s] = (e.0 + l, e.1 + 1)
                }
                if off - on >= 0.12, let after = energy(band, on + 0.08, min(off, on + 0.2), relative: false),
                   let before = energy(band, on - 0.25, on - 0.12, relative: false) {
                    let e = rise[s] ?? (0, 0); rise[s] = (e.0 + after - before, e.1 + 1)
                }
            }
        }
        let lv = level.filter { $0.value.1 >= 5 }.mapValues { $0.0 / Double($0.1) }
        let rs = rise.filter { $0.value.1 >= 5 }.mapValues { $0.0 / Double($0.1) }
        let name = "\(v.id) \(v.name.isEmpty ? v.programName : v.name) [\(v.role)]"
        guard let bestL = lv.max(by: { $0.value < $1.value })?.key else { lines.append(name + ": too few trusted notes"); continue }
        let bestR = rs.max(by: { $0.value < $1.value })?.key
        func fmt(_ d: [Int: Double]) -> String { shifts.compactMap { s in d[s].map { String(format: "%+d %.2f", s, $0) } }.joined(separator: ", ") }
        let verdict: String
        if lv[0] == nil { verdict = "unmeasured (notes below the analysed range)" }
        else if let r = bestR, r == bestL {
            verdict = bestL == 0 ? "octave looks right" : "sounds \(bestL > 0 ? "+" : "")\(bestL): check by ear, then set addTranspose"
                + (bestL == 12 && v.role == "bass" ? " (often a false alarm for bass: the 2nd harmonic is louder in most mixes)" : "")
        }
        else { verdict = "unclear (level says \(bestL > 0 ? "+" : "")\(bestL), rise says \(bestR.map { ($0 > 0 ? "+" : "") + String($0) } ?? "-")): listen" }
        lines.append(name + ": " + verdict + "   level [\(fmt(lv))]  rise [\(fmt(rs))]")
    }
    return lines
}

// MARK: - Aligned MIDI (for listening against the recording)

/// Writes the warped, transposed MIDI (every voice, drums too) at 60 BPM, so one beat is one second of the recording.
func writeAlignedMidi(m: BMMidi, res: AlignResult, semitones: Int, to path: String) throws {
    var seqOpt: MusicSequence?
    guard NewMusicSequence(&seqOpt) == noErr, let seq = seqOpt else { throw RBError("cannot create MusicSequence") }
    defer { DisposeMusicSequence(seq) }
    var tempoOpt: MusicTrack?
    MusicSequenceGetTempoTrack(seq, &tempoOpt)
    if let tempo = tempoOpt { MusicTrackNewExtendedTempoEvent(tempo, 0, 60) }
    for (vi, v) in m.voices.enumerated() {
        var trackOpt: MusicTrack?
        guard MusicSequenceNewTrack(seq, &trackOpt) == noErr, let track = trackOpt else { continue }
        let ch = UInt8((v.channel - 1) & 0x0F)
        if v.program >= 0 && !v.drum {
            var pc = MIDIChannelMessage(status: 0xC0 | ch, data1: UInt8(v.program), data2: 0, reserved: 0)
            MusicTrackNewMIDIChannelEvent(track, 0, &pc)
        }
        for n in m.notes where n.voice == vi {
            guard let on = res.map.audio(n.on) else { continue }
            let off = res.map.audio(n.off) ?? on + (n.off - n.on)
            let pitch = n.drum ? n.pitch : n.pitch + semitones + v.addTranspose
            guard pitch >= 0 && pitch <= 127 else { continue }
            var msg = MIDINoteMessage(channel: ch, note: UInt8(pitch), velocity: UInt8(max(1, min(127, n.velocity))),
                                      releaseVelocity: 0, duration: Float32(max(0.01, off - on)))
            MusicTrackNewMIDINoteEvent(track, on, &msg)
        }
    }
    let status = MusicSequenceFileCreate(seq, URL(fileURLWithPath: path) as CFURL, .midiType, .eraseFile, 480)
    guard status == noErr else { throw RBError("cannot write \(path) (OSStatus \(status))") }
}
