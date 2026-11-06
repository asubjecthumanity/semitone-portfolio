import Foundation

let scoringVersion = "maximum-cardinality-onset-v2"

// Scores a transcription against a synthetic song's ground truth.
// Conventions follow the usual MIR evaluations (mir_eval):
// - notes: same pitch, onset within ±50 ms, one-to-one matching;
// - drums: same class, onset within ±50 ms;
// - beats: F-measure with a ±70 ms window;
// - chords: fraction of time with the right root and major/minor quality,
//   over the time the truth has a major- or minor-type chord ("majmin").

nonisolated struct PRF: Codable {
    var tp = 0
    var fp = 0
    var fn = 0

    var precision: Double { tp + fp == 0 ? 0 : Double(tp) / Double(tp + fp) }
    var recall: Double { tp + fn == 0 ? 0 : Double(tp) / Double(tp + fn) }
    var f1: Double {
        let p = precision, r = recall
        return p + r == 0 ? 0 : 2 * p * r / (p + r)
    }

    static func + (a: PRF, b: PRF) -> PRF { PRF(tp: a.tp + b.tp, fp: a.fp + b.fp, fn: a.fn + b.fn) }

    var short: String { String(format: "F1 %.3f (P %.3f R %.3f)", f1, precision, recall) }
}

/// One-to-one matching of predicted onsets to reference onsets within
/// `tolerance`, maximizing the number of matches. An augmenting path can
/// reassign an earlier pair instead of letting a nearest-first choice block
/// two valid matches. Ties are deterministic; minimum total distance is not
/// part of this metric. Note scoring rounds distances to 4 decimals, matching
/// mir_eval.transcription; generic beat/drum event matching does not.
func matchOnsets(pred: [Double], ref: [Double], tolerance: Double,
                 roundNoteDistances: Bool = false) -> [(Int, Int)] {
    guard tolerance.isFinite, tolerance >= 0 else { return [] }
    var adjacent = [[(dist: Double, r: Int)]](repeating: [], count: pred.count)
    let order = pred.indices.filter { pred[$0].isFinite }.sorted {
        pred[$0] == pred[$1] ? $0 < $1 : pred[$0] < pred[$1]
    }
    let sortedPred = order.map { pred[$0] }
    let searchWindow = tolerance + (roundNoteDistances ? 0.00005 : 0)
    for (r, t) in ref.enumerated() where t.isFinite {
        // The extra half rounding unit includes note edges that round inside
        // the tolerance; eligibility is still checked on each actual distance.
        var lo = 0, hi = sortedPred.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sortedPred[mid] < t - searchWindow { lo = mid + 1 } else { hi = mid }
        }
        var i = lo
        while i < sortedPred.count, sortedPred[i] <= t + searchWindow {
            let distance = abs(sortedPred[i] - t)
            let eligibleDistance = roundNoteDistances
                ? (distance * 10_000).rounded(.toNearestOrEven) / 10_000 : distance
            if eligibleDistance <= tolerance { adjacent[order[i]].append((distance, r)) }
            i += 1
        }
    }
    for p in adjacent.indices {
        adjacent[p].sort { $0.dist == $1.dist ? $0.r < $1.r : $0.dist < $1.dist }
    }
    var matchedP = [Int](repeating: -1, count: pred.count)
    var matchedR = [Int](repeating: -1, count: ref.count)
    var seenP = [Int](repeating: 0, count: pred.count)
    var seenR = [Int](repeating: 0, count: ref.count)
    var parentR = [Int](repeating: -1, count: ref.count)
    // Iterative breadth-first augmenting paths avoid a recursion-depth limit
    // on long passages. Reused visitation stamps avoid clearing arrays per root.
    for (rootNumber, root) in order.enumerated() {
        let stamp = rootNumber + 1
        var queue = [root], head = 0, freeRef = -1
        seenP[root] = stamp
        while head < queue.count, freeRef == -1 {
            let p = queue[head]
            head += 1
            for edge in adjacent[p] where seenR[edge.r] != stamp {
                let r = edge.r
                seenR[r] = stamp
                parentR[r] = p
                let previousPred = matchedR[r]
                if previousPred == -1 { freeRef = r; break }
                if seenP[previousPred] != stamp {
                    seenP[previousPred] = stamp
                    queue.append(previousPred)
                }
            }
        }
        var r = freeRef
        while r != -1 {
            let p = parentR[r]
            let previousRef = matchedP[p]
            matchedP[p] = r
            matchedR[r] = p
            r = previousRef
        }
    }
    return pred.indices.compactMap { matchedP[$0] == -1 ? nil : ($0, matchedP[$0]) }
}

/// Note onset matching, pitch by pitch. Returns the counts plus, for each
/// matched predicted note index, the index of the reference note it matched.
func scoreNotes(pred: [NoteEvent], ref: [TruthNote], tolerance: Double = 0.05) -> (prf: PRF, matches: [Int: Int]) {
    var byPitchPred: [Int: [Int]] = [:]
    var byPitchRef: [Int: [Int]] = [:]
    for (i, n) in pred.enumerated() { byPitchPred[n.pitch, default: []].append(i) }
    for (i, n) in ref.enumerated() { byPitchRef[n.pitch, default: []].append(i) }
    var matches: [Int: Int] = [:]
    for (pitch, refIdx) in byPitchRef {
        guard let predIdx = byPitchPred[pitch] else { continue }
        let pairs = matchOnsets(pred: predIdx.map { pred[$0].startTime }, ref: refIdx.map { ref[$0].on },
                                tolerance: tolerance, roundNoteDistances: true)
        for (p, r) in pairs { matches[predIdx[p]] = refIdx[r] }
    }
    let tp = matches.count
    return (PRF(tp: tp, fp: pred.count - tp, fn: ref.count - tp), matches)
}

/// Unmatched predictions that sit a whole number of octaves from an unmatched
/// reference note with the same onset: the classic harmonic confusion.
func octaveErrors(pred: [NoteEvent], ref: [TruthNote], matches: [Int: Int], tolerance: Double = 0.05) -> Int {
    let matchedRef = Set(matches.values)
    var used = Set<Int>()
    var count = 0
    for (i, p) in pred.enumerated() where matches[i] == nil {
        for (j, r) in ref.enumerated() where !matchedRef.contains(j) && !used.contains(j) {
            if p.pitch != r.pitch, abs(p.pitch - r.pitch) % 12 == 0, abs(p.startTime - r.on) <= tolerance {
                used.insert(j)
                count += 1
                break
            }
        }
    }
    return count
}

func scoreDrums(pred: [(time: Double, cls: DrumClass)], ref: [TruthDrum], tolerance: Double = 0.05) -> [DrumClass: PRF] {
    var out: [DrumClass: PRF] = [:]
    for cls in DrumClass.allCases {
        let p = pred.filter { $0.cls == cls }.map(\.time)
        let r = ref.filter { DrumClass.of(gmNote: $0.gmNote) == cls }.map(\.time)
        let tp = matchOnsets(pred: p, ref: r, tolerance: tolerance).count
        out[cls] = PRF(tp: tp, fp: p.count - tp, fn: r.count - tp)
    }
    return out
}

func scoreBeats(pred: [Double], ref: [Double], tolerance: Double = 0.07) -> PRF {
    let tp = matchOnsets(pred: pred, ref: ref, tolerance: tolerance).count
    return PRF(tp: tp, fp: pred.count - tp, fn: ref.count - tp)
}

// MARK: - Chords

/// Major/minor class of a chord quality, or nil when it is neither (dim, sus, aug).
func majMin(quality: String) -> String? {
    switch quality {
    case "maj", "7", "maj7", "6": return "maj"
    case "min", "min7", "min6": return "min"
    default: return nil
    }
}

private let pitchClassNames: [String: Int] = [
    "C": 0, "C#": 1, "D♭": 1, "Db": 1, "D": 2, "D#": 3, "E♭": 3, "Eb": 3, "E": 4, "F": 5,
    "F#": 6, "G♭": 6, "Gb": 6, "G": 7, "G#": 8, "A♭": 8, "Ab": 8, "A": 9, "A#": 10, "B♭": 10, "Bb": 10, "B": 11,
]

/// Parses a ChordAnalyzer label ("D#m7♭5/A", "F", "Csus4") into root pitch
/// class and major/minor class (nil class for dim/sus/aug and friends).
func parseChordLabel(_ label: String) -> (root: Int, cls: String?)? {
    let body = label.split(separator: "/").first.map(String.init) ?? label
    var rootName = String(body.prefix(1))
    var rest = body.dropFirst()
    if let next = rest.first, next == "#" || next == "♭" || next == "b" {
        rootName.append(next)
        rest = rest.dropFirst()
    }
    guard let root = pitchClassNames[rootName] else { return nil }
    let suffix = String(rest)
    let cls: String?
    switch suffix {
    case "", "7", "maj7", "6": cls = "maj"
    case "m", "m7", "m6": cls = "min"
    default: cls = nil
    }
    return (root, cls)
}

nonisolated struct ChordScore: Codable {
    /// Seconds with a scorable (maj/min) truth chord.
    var scoredSeconds = 0.0
    var rootSeconds = 0.0
    var majMinSeconds = 0.0
    var rootAccuracy: Double { scoredSeconds > 0 ? rootSeconds / scoredSeconds : 0 }
    var majMinAccuracy: Double { scoredSeconds > 0 ? majMinSeconds / scoredSeconds : 0 }
    static func + (a: ChordScore, b: ChordScore) -> ChordScore {
        ChordScore(scoredSeconds: a.scoredSeconds + b.scoredSeconds, rootSeconds: a.rootSeconds + b.rootSeconds,
                   majMinSeconds: a.majMinSeconds + b.majMinSeconds)
    }
}

/// Time-weighted chord accuracy, sampled every 50 ms. `labelAt` returns the
/// predicted label sounding at a time (nil = no chord).
func scoreChords(truth: [TruthChord], labelAt: (Double) -> String?) -> ChordScore {
    var s = ChordScore()
    let step = 0.05
    for chord in truth {
        guard let cls = majMin(quality: chord.quality) else { continue }
        var t = chord.start + step / 2
        while t < chord.end {
            s.scoredSeconds += step
            if let label = labelAt(t), let parsed = parseChordLabel(label), parsed.root == chord.root {
                s.rootSeconds += step
                if parsed.cls == cls { s.majMinSeconds += step }
            }
            t += step
        }
    }
    return s
}
