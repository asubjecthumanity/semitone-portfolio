import Foundation

// Chords per beat from the MIDI's own notes (symbolic): a port of
// als2truth.py's derive_chords, independent of the app's chord code.
// Chord-role notes count by how long they sound in the beat (countermelody
// notes at a third of that); the lowest bass note sounding through a quarter
// of the beat names the inversion and helps pick the root. A Viterbi pass
// charges a cost per chord change, so a rolled chord or a one-beat gap does
// not flip the label. Labels are Harte ("A:min7", "F#:maj/3", "N").

let chordTemplates: [(String, [Int])] = [
    ("maj", [0, 4, 7]), ("min", [0, 3, 7]), ("dim", [0, 3, 6]), ("aug", [0, 4, 8]),
    ("sus4", [0, 5, 7]), ("sus2", [0, 2, 7]), ("7", [0, 4, 7, 10]), ("maj7", [0, 4, 7, 11]),
    ("min7", [0, 3, 7, 10]), ("hdim7", [0, 3, 6, 10]), ("dim7", [0, 3, 6, 9]), ("minmaj7", [0, 3, 7, 11]),
    ("maj6", [0, 4, 7, 9]), ("min6", [0, 3, 7, 9]), ("5", [0, 7]),
]
private let qualityPrior: [String: Double] = ["maj": 0, "min": 0, "7": 0, "maj7": 0, "min7": 0, "5": -0.3, "sus4": -0.05,
                                              "sus2": -0.1, "dim": -0.1, "aug": -0.15, "hdim7": -0.05, "dim7": -0.1,
                                              "maj6": -0.1, "min6": -0.1, "minmaj7": -0.2]
private let degreeNames = [1: "b2", 2: "2", 3: "b3", 4: "3", 5: "4", 6: "b5", 7: "5", 8: "#5", 9: "6", 10: "b7", 11: "7"]
private let sharpNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
private let flatNames = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]
private let mixedNames = ["C", "Db", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
private let kkMajor = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
private let kkMinor = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

/// (tonic, "major"/"minor", root spellings) from pitch-class weights (Krumhansl-Kessler).
func estimateKey(_ w: [Double]) -> (tonic: Int, mode: String, names: [String]) {
    func corr(_ a: [Double], _ b: [Double]) -> Double {
        let ma = a.reduce(0, +) / 12, mb = b.reduce(0, +) / 12
        var num = 0.0, da = 0.0, db = 0.0
        for k in 0..<12 { num += (a[k] - ma) * (b[k] - mb); da += (a[k] - ma) * (a[k] - ma); db += (b[k] - mb) * (b[k] - mb) }
        return da > 0 && db > 0 ? num / sqrt(da * db) : 0
    }
    var best = (-2.0, 0, "major")
    for t in 0..<12 {
        for (mode, prof) in [("major", kkMajor), ("minor", kkMinor)] {
            let rot = (0..<12).map { prof[(($0 - t) % 12 + 12) % 12] }
            let c = corr(w, rot)
            if c > best.0 { best = (c, t, mode) }
        }
    }
    let major = best.2 == "major" ? best.1 : (best.1 + 3) % 12
    let names = [7, 2, 9, 4, 11, 6].contains(major) ? sharpNames : [5, 10, 3, 8, 1].contains(major) ? flatNames : mixedNames
    return (best.1, best.2, names)
}

private func present(_ w: [Double], _ bass: Int?) -> [Int: Double] {
    let mx = w.max() ?? 0
    var p: [Int: Double] = [:]
    if mx > 0 { for (pc, x) in w.enumerated() where x / mx >= 0.2 { p[pc] = x / mx } }
    if let b = bass { p[b] = max(p[b] ?? 0, 0.5) }
    return p
}

private func chordScore(_ p: [Int: Double], _ bass: Int?, _ root: Int, _ ivs: [Int], _ q: String) -> Double {
    let tones = Set(ivs.map { (root + $0) % 12 })
    var hit = 0.0, extra = 0.0
    for (pc, w) in p { if tones.contains(pc) { hit += w } else { extra += w } }
    let miss = tones.subtracting(p.keys).count
    var s = hit - extra - 0.6 * Double(miss) - 0.15 * Double(max(0, ivs.count - 3)) + (qualityPrior[q] ?? 0)
    if p[root] == nil { s -= 0.5 }
    if let b = bass, b == root { s += 0.35 }
    return s + 0.05 * (p[root] ?? 0)
}

func harteLabel(_ root: Int, _ q: String, _ bass: Int?, _ names: [String]) -> String {
    let ivs = chordTemplates.first { $0.0 == q }!.1
    var label = "\(names[root]):\(q)"
    if let b = bass, b != root, ivs.contains((b - root + 12) % 12), let d = degreeNames[(b - root + 12) % 12] { label += "/" + d }
    return label
}

nonisolated struct ChordSpan { var start: Double; var end: Double; var label: String }

/// notes: (on, off, pitch, weight) of the harmony; bass: (on, off, pitch) of the bass role.
func deriveChords(harmony: [(Double, Double, Int, Double)], bass: [(Double, Double, Int)], beats: [Double],
                  names: [String], changeCost: Double = 0.4) -> [ChordSpan] {
    struct Beat { var a: Double; var b: Double; var w: [Double]; var bass: Int? }
    var bs: [Beat] = []
    // Index notes by onset to keep this linear-ish.
    let h = harmony.sorted { $0.0 < $1.0 }, bl = bass.sorted { $0.0 < $1.0 }
    let maxDur = max(h.map { $0.1 - $0.0 }.max() ?? 0, bl.map { $0.1 - $0.0 }.max() ?? 0)
    func firstIndex<T>(_ arr: [T], _ on: (T) -> Double, from t: Double) -> Int {
        var lo = 0, hi = arr.count
        while lo < hi { let m = (lo + hi) / 2; if on(arr[m]) < t { lo = m + 1 } else { hi = m } }
        return lo
    }
    for k in 0..<max(0, beats.count - 1) {
        let a = beats[k], b = beats[k + 1]
        guard b > a + 1e-9 else { continue }
        var w = [Double](repeating: 0, count: 12)
        var q = firstIndex(h, { $0.0 }, from: a - maxDur)
        while q < h.count && h[q].0 < b {
            let o = min(h[q].1, b) - max(h[q].0, a)
            if o > 1e-6 { w[((h[q].2 % 12) + 12) % 12] += o * h[q].3 }
            q += 1
        }
        var low: Int?
        q = firstIndex(bl, { $0.0 }, from: a - maxDur)
        while q < bl.count && bl[q].0 < b {
            let o = min(bl[q].1, b) - max(bl[q].0, a)
            if o > 0.25 * (b - a), low == nil || bl[q].2 < low! { low = bl[q].2 }
            q += 1
        }
        bs.append(Beat(a: a, b: b, w: w, bass: low.map { (($0 % 12) + 12) % 12 }))
    }
    guard !bs.isEmpty else { return [] }
    // States: tone sets of the best few candidates per beat.
    var namesOf: [Set<Int>: [(Int, String)]] = [:]
    for r in 0..<12 { for (q, ivs) in chordTemplates { namesOf[Set(ivs.map { (r + $0) % 12 }), default: []].append((r, q)) } }
    var cands = Set<Set<Int>>()
    for beat in bs {
        let p = present(beat.w, beat.bass)
        if p.count < 2 { continue }
        var scored: [(Double, Int, String)] = []
        for r in 0..<12 { for (q, ivs) in chordTemplates { scored.append((chordScore(p, beat.bass, r, ivs, q), r, q)) } }
        scored.sort { $0.0 > $1.0 }
        for (_, r, q) in scored.prefix(4) { cands.insert(Set(chordTemplates.first { $0.0 == q }!.1.map { (r + $0) % 12 })) }
    }
    let states: [Set<Int>?] = [nil] + cands.sorted { $0.sorted().lexicographicallyPrecedes($1.sorted()) }
    func bestName(_ k: Int, _ st: Set<Int>?) -> (Double, (Int, String)?) {
        let beat = bs[k]
        let p: [Int: Double] = (beat.w.max() ?? 0) > 0 ? present(beat.w, beat.bass) : (beat.bass.map { [$0: 0.5] } ?? [:])
        guard let st else { return (p.isEmpty ? 0.5 : (p.count < 2 ? 0 : -1), nil) }
        if p.isEmpty { return (-0.2, namesOf[st]![0]) }
        var best: (Double, (Int, String))? = nil
        for (r, q) in namesOf[st]! {
            let s = chordScore(p, beat.bass, r, chordTemplates.first { $0.0 == q }!.1, q)
            if best == nil || s > best!.0 + 1e-12 { best = (s, (r, q)) }
        }
        return (best!.0, best!.1)
    }
    let table = (0..<bs.count).map { k in states.map { bestName(k, $0) } }
    var dp = table[0].map(\.0)
    var back: [[Int]] = []
    for k in 1..<bs.count {
        let bi = dp.indices.max { dp[$0] < dp[$1] }!
        var ptr: [Int] = [], nxt: [Double] = []
        for i in states.indices {
            let stay = dp[i], sw = dp[bi] - changeCost
            ptr.append(stay >= sw ? i : bi)
            nxt.append(max(stay, sw) + table[k][i].0)
        }
        back.append(ptr); dp = nxt
    }
    var i = dp.indices.max { dp[$0] < dp[$1] }!
    var path = [i]
    for ptr in back.reversed() { i = ptr[i]; path.append(i) }
    path.reverse()
    var out: [ChordSpan] = []
    for (k, si) in path.enumerated() {
        let name = table[k][si].1
        let text = name.map { harteLabel($0.0, $0.1, bs[k].bass, names) } ?? "N"
        if let last = out.last, last.label == text, abs(last.end - bs[k].a) < 1e-9 {
            out[out.count - 1].end = bs[k].b
        } else {
            out.append(ChordSpan(start: bs[k].a, end: bs[k].b, label: text))
        }
    }
    return out
}
