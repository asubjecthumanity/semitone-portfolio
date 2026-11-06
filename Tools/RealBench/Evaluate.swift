import Foundation

// Scores one pipeline's prediction against a RealBench truth and explains the
// errors. Matching reuses MusicBench's Scoring.swift (`matchOnsets`, the
// maximum-cardinality matcher with mir_eval's 4-decimal note rounding;
// `scoreDrums`, `scoreBeats`, `scoreChords`), so the numbers agree with
// musicbench on synthetic songs.

/// A note on the scored timeline. `label` is the predicted part (none /
/// melody / countermelody / chords / bass) or the truth part.
nonisolated struct ENote {
    let on: Double
    let off: Double
    let pitch: Int
    let label: String
    var instrument: String = ""
    var velocity: Int? = nil
}

let roleNames = ["melody", "countermelody", "chords", "bass"]
let pitchNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
func noteName(_ p: Int) -> String { "\(pitchNames[((p % 12) + 12) % 12])\(p / 12 - 1)" }

// MARK: - Matching

/// Note matches (pred index -> ref index): same pitch (or pitch class), onset
/// within `tolerance` after mir_eval's 4-decimal rounding, one-to-one,
/// maximum cardinality. `shift` is added to predicted onsets.
func noteMatches(pred: [ENote], ref: [ENote], tolerance: Double, chroma: Bool = false, shift: Double = 0) -> [Int: Int] {
    func key(_ p: Int) -> Int { chroma ? ((p % 12) + 12) % 12 : p }
    var byKeyPred: [Int: [Int]] = [:], byKeyRef: [Int: [Int]] = [:]
    for (i, n) in pred.enumerated() { byKeyPred[key(n.pitch), default: []].append(i) }
    for (i, n) in ref.enumerated() { byKeyRef[key(n.pitch), default: []].append(i) }
    var matches: [Int: Int] = [:]
    for (k, refIdx) in byKeyRef.sorted(by: { $0.key < $1.key }) {
        guard let predIdx = byKeyPred[k] else { continue }
        let pairs = matchOnsets(pred: predIdx.map { pred[$0].on + shift }, ref: refIdx.map { ref[$0].on },
                                tolerance: tolerance, roundNoteDistances: true)
        for (p, r) in pairs { matches[predIdx[p]] = refIdx[r] }
    }
    return matches
}

func rounded4(_ x: Double) -> Double { (x * 10_000).rounded(.toNearestOrEven) / 10_000 }

/// Onset + offset matching (mir_eval defaults: offset within max(50 ms, 20% of the reference duration)).
func noteMatchesWithOffsets(pred: [ENote], ref: [ENote], tolerance: Double = 0.05,
                            offsetRatio: Double = 0.2, offsetMin: Double = 0.05) -> [Int: Int] {
    var refByPitch: [Int: [Int]] = [:]
    for (i, n) in ref.enumerated() { refByPitch[n.pitch, default: []].append(i) }
    var adjacency = [[Int]](repeating: [], count: pred.count)
    for (p, n) in pred.enumerated() {
        for r in refByPitch[n.pitch] ?? [] {
            let m = ref[r]
            guard rounded4(abs(n.on - m.on)) <= tolerance else { continue }
            let offTol = max(offsetMin, offsetRatio * (m.off - m.on))
            if rounded4(abs(n.off - m.off)) <= offTol { adjacency[p].append(r) }
        }
        adjacency[p].sort { abs(pred[p].on - ref[$0].on) < abs(pred[p].on - ref[$1].on) }
    }
    let matched = maximumMatching(predCount: pred.count, refCount: ref.count, adjacency: adjacency)
    var out: [Int: Int] = [:]
    for (p, r) in matched.enumerated() where r >= 0 { out[p] = r }
    return out
}

/// Maximum-cardinality bipartite matching by breadth-first augmenting paths
/// (the same scheme as Scoring.matchOnsets, over arbitrary edges).
func maximumMatching(predCount: Int, refCount: Int, adjacency: [[Int]]) -> [Int] {
    var matchedP = [Int](repeating: -1, count: predCount)
    var matchedR = [Int](repeating: -1, count: refCount)
    var seenP = [Int](repeating: 0, count: predCount)
    var seenR = [Int](repeating: 0, count: refCount)
    var parentR = [Int](repeating: -1, count: refCount)
    for root in 0..<predCount where !adjacency[root].isEmpty {
        let stamp = root + 1
        var queue = [root], head = 0, freeRef = -1
        seenP[root] = stamp
        while head < queue.count, freeRef == -1 {
            let p = queue[head]
            head += 1
            for r in adjacency[p] where seenR[r] != stamp {
                seenR[r] = stamp
                parentR[r] = p
                let prev = matchedR[r]
                if prev == -1 { freeRef = r; break }
                if seenP[prev] != stamp { seenP[prev] = stamp; queue.append(prev) }
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
    return matchedP
}

func prf(_ tp: Int, predCount: Int, refCount: Int) -> PRF { PRF(tp: tp, fp: predCount - tp, fn: refCount - tp) }

func prfJSON(_ s: PRF) -> [String: Any] {
    ["tp": s.tp, "fp": s.fp, "fn": s.fn, "precision": r4(s.precision), "recall": r4(s.recall), "f1": r4(s.f1)]
}

func r4(_ x: Double) -> Double { x.isFinite ? (x * 10_000).rounded() / 10_000 : 0 }
func r1(_ x: Double) -> Double { x.isFinite ? (x * 10).rounded() / 10 : 0 }

func median(_ xs: [Double]) -> Double? {
    guard !xs.isEmpty else { return nil }
    let s = xs.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

// MARK: - Evaluation

nonisolated struct Evaluation {
    var score: [String: Any] = [:]
    var diagnostics: [String: Any] = [:]
    var errorsCSV = ""
    /// One line for the summary table.
    var row: [String: Double] = [:]
}

func predNotesToE(_ notes: [PredNote], window: ScoreWindow) -> [ENote] {
    notes.filter { window.contains($0.start) }.map { ENote(on: $0.start, off: $0.end, pitch: $0.pitch, label: $0.part) }
}

func evaluate(prediction pred: Prediction, truth: RBTruth, window: ScoreWindow) -> Evaluation {
    var ev = Evaluation()
    let offsetsReliable = truth.offsetsReliable ?? true
    let notesComplete = truth.notesComplete ?? true
    let ref: [ENote] = (truth.notes ?? []).filter { window.contains($0.on) }
        .map { ENote(on: $0.on, off: max($0.off, $0.on), pitch: $0.pitch, label: $0.partName, instrument: $0.instrument ?? "",
                     velocity: $0.velocity) }
        .sorted { ($0.on, $0.pitch) < ($1.on, $1.pitch) }
    let est = predNotesToE(pred.notes, window: window).sorted { ($0.on, $0.pitch) < ($1.on, $1.pitch) }

    ev.score["pipeline"] = pred.pipeline
    ev.score["truth"] = truth.name ?? ""
    ev.score["window"] = ["start": r4(window.start), "end": r4(window.end),
                          "ignore": window.ignore.map { [r4($0.0), r4($0.1)] }, "scoredSeconds": r4(window.scoredSeconds)]
    ev.score["counts"] = ["truthNotes": ref.count, "predNotes": est.count]

    // 1. Notes, overall.
    let hasNotes = !ref.isEmpty
    var m50: [Int: Int] = [:]
    if hasNotes {
        m50 = noteMatches(pred: est, ref: ref, tolerance: 0.05)
        let m100 = noteMatches(pred: est, ref: ref, tolerance: 0.1)
        let c50 = noteMatches(pred: est, ref: ref, tolerance: 0.05, chroma: true)
        let c100 = noteMatches(pred: est, ref: ref, tolerance: 0.1, chroma: true)
        let off50 = noteMatchesWithOffsets(pred: est, ref: ref)
        let s50 = prf(m50.count, predCount: est.count, refCount: ref.count)
        let s100 = prf(m100.count, predCount: est.count, refCount: ref.count)
        let sc50 = prf(c50.count, predCount: est.count, refCount: ref.count)
        let sc100 = prf(c100.count, predCount: est.count, refCount: ref.count)
        let soff = prf(off50.count, predCount: est.count, refCount: ref.count)
        ev.score["notes"] = [
            "onset50": prfJSON(s50), "onset100": prfJSON(s100),
            "onset50OctaveFolded": prfJSON(sc50), "onset100OctaveFolded": prfJSON(sc100),
            "onsetOffset50": prfJSON(soff),
            "offsetsReliable": offsetsReliable, "notesComplete": notesComplete,
            "conventions": "exact MIDI pitch (octave-folded: pitch class), onset |d| <= tol after rounding to 4 decimals, one-to-one maximum matching; onsetOffset50 adds mir_eval's offset rule max(50 ms, 20% of the true duration)",
        ]
        ev.row["notes50"] = s50.f1; ev.row["notes100"] = s100.f1; ev.row["chroma50"] = sc50.f1
        ev.row["P50"] = s50.precision; ev.row["R50"] = s50.recall; ev.row["onoff50"] = soff.f1
        let pairs = wrongPitchPairs(est: est, ref: ref, m50: m50)
        let causes = explainErrors(est: est, ref: ref, m50: m50, pairs: pairs)
        ev.diagnostics = noteDiagnostics(est: est, ref: ref, m50: m50, m100: m100, window: window,
                                         offsetsReliable: offsetsReliable, pairs: pairs, causes: causes)
        ev.errorsCSV = errorRows(est: est, ref: ref, m50: m50, causes: causes)
    }

    // 2. Parts.
    if hasNotes {
        var parts: [String: Any] = [:]
        var roles: [String: Any] = [:]
        let lead = predNotesToE(pred.leadLine, window: window)
        for role in roleNames {
            let refRole = ref.filter { $0.label == role }
            guard !refRole.isEmpty else { continue }
            let source: String
            let estRole: [ENote]
            if pred.split {
                source = "app part '\(role)'"
                estRole = est.filter { $0.label == role }
            } else if role == "melody" {
                source = "LeadLine (the app's melody for unsplit takes)"
                estRole = lead
            } else {
                roles[role] = ["truthNotes": refRole.count, "source": "n/a (pipeline does not split parts)"]
                continue
            }
            let a = prf(noteMatches(pred: estRole, ref: refRole, tolerance: 0.05).count, predCount: estRole.count, refCount: refRole.count)
            let b = prf(noteMatches(pred: estRole, ref: refRole, tolerance: 0.1).count, predCount: estRole.count, refCount: refRole.count)
            let c = prf(noteMatches(pred: estRole, ref: refRole, tolerance: 0.05, chroma: true).count, predCount: estRole.count, refCount: refRole.count)
            roles[role] = ["truthNotes": refRole.count, "predNotes": estRole.count, "source": source,
                           "onset50": prfJSON(a), "onset100": prfJSON(b), "onset50OctaveFolded": prfJSON(c)]
            ev.row[role] = a.f1
        }
        parts["roles"] = roles
        if pred.split {
            var correct = 0, total = 0
            for (p, r) in m50 where roleNames.contains(ref[r].label) {
                total += 1
                if est[p].label == ref[r].label { correct += 1 }
            }
            parts["partAccuracy"] = ["matchedRoleNotes": total, "rightPart": correct,
                                     "accuracy": r4(total == 0 ? 0 : Double(correct) / Double(total))]
            if total > 0 { ev.row["partAcc"] = Double(correct) / Double(total) }
        }
        // Every named part and instrument: how much of it the whole prediction finds,
        // and which app part those notes landed in.
        var named: [String: Any] = [:]
        func subsetRecall(_ subset: [ENote]) -> [String: Any] {
            let a = noteMatches(pred: est, ref: subset, tolerance: 0.05)
            let b = noteMatches(pred: est, ref: subset, tolerance: 0.1)
            let c = noteMatches(pred: est, ref: subset, tolerance: 0.05, chroma: true)
            var voices: [String: Int] = [:]
            for (p, _) in a { voices[est[p].label, default: 0] += 1 }
            let lo = subset.map(\.pitch).min() ?? 0, hi = subset.map(\.pitch).max() ?? 0
            return ["truthNotes": subset.count, "range": "\(noteName(lo))-\(noteName(hi))",
                    "recall50": r4(Double(a.count) / Double(max(subset.count, 1))),
                    "recall100": r4(Double(b.count) / Double(max(subset.count, 1))),
                    "recall50OctaveFolded": r4(Double(c.count) / Double(max(subset.count, 1))),
                    "foundAsPart": voices]
        }
        for part in Set(ref.map(\.label)).sorted() { named["part:" + part] = subsetRecall(ref.filter { $0.label == part }) }
        for inst in Set(ref.map(\.instrument)).sorted() where !inst.isEmpty {
            named["instrument:" + inst] = subsetRecall(ref.filter { $0.instrument == inst })
        }
        parts["named"] = named
        ev.score["parts"] = parts
    }

    // 3. Drums (truth has a drums section; [] = drumless song). The app no
    // longer transcribes drums, so new predictions carry none and are reported
    // as not scored; predictions saved before then still score.
    if truth.drums != nil, pred.drums == nil {
        ev.score["drums"] = ["scored": false,
                             "note": "not scored: the pipeline transcribes no drums (Any-instrument mode dropped drum tracking)"]
        ev.row["drumsNotScored"] = 1
    }
    if let truthDrums = truth.drums, pred.drums != nil {
        let refDrums: [TruthDrum] = truthDrums.filter { window.contains($0.time) }.compactMap { d in
            guard let cls = d.scoredClass else { return nil }
            return TruthDrum(time: d.time, gmNote: cls.gm, velocity: d.velocity ?? 100)
        }
        let predHits: [(time: Double, cls: DrumClass)] = (pred.drums ?? []).filter { window.contains($0.time) }.compactMap { h in
            guard let cls = predDrumClass(h.kind) else { return nil }
            return (h.time, cls)
        }
        let perClass = scoreDrums(pred: predHits, ref: refDrums)
        var drums: [String: Any] = ["truthHits": refDrums.count, "predHits": predHits.count,
                                    "unscoredTruthHits": truthDrums.filter { window.contains($0.time) && $0.scoredClass == nil }.count,
                                    "pipelineHasDrums": pred.drums != nil]
        var all = PRF()
        for cls in DrumClass.allCases {
            let s = perClass[cls] ?? PRF()
            drums[cls.rawValue] = prfJSON(s)
            all = all + s
            if s.tp + s.fn > 0 { ev.row["drum." + cls.rawValue] = s.f1 }
        }
        if refDrums.isEmpty {
            drums["note"] = "drumless truth: every detected kick/snare/hi-hat hit is a false alarm"
            ev.row["drumFalseHits"] = Double(predHits.count)
        }
        drums["all"] = prfJSON(all)
        ev.score["drums"] = drums
        ev.diagnostics["drums"] = drumDiagnostics(pred: predHits, ref: refDrums, all: truthDrums.filter { window.contains($0.time) })
    }

    // 4. Beats and downbeats.
    let refBeats = (truth.beats ?? []).filter { window.contains($0) }
    let refDown = (truth.downbeats ?? []).filter { window.contains($0) }
    if !refBeats.isEmpty || !refDown.isEmpty {
        let estBeats = pred.beats.filter { window.contains($0) }
        let estDown = pred.downbeats.filter { window.contains($0) }
        var beats: [String: Any] = ["predBeatsPerBar": pred.beatsPerBar, "predBPM": r1(pred.bpm)]
        if let bpb = truth.beatsPerBar { beats["truthBeatsPerBar"] = bpb }
        if refBeats.count > 2, let gap = median(zip(refBeats.dropFirst(), refBeats).map { $0 - $1 }) { beats["truthBPM"] = r1(60 / gap) }
        if !refBeats.isEmpty {
            let s = scoreBeats(pred: estBeats, ref: refBeats)
            beats["beats"] = prfJSON(s)
            ev.row["beats"] = s.f1
        }
        if !refDown.isEmpty {
            let s = scoreBeats(pred: estDown, ref: refDown)
            beats["downbeats"] = prfJSON(s)
            ev.row["downbeats"] = s.f1
        }
        beats["conventions"] = "F-measure, +/-70 ms, one-to-one (MusicBench scoreBeats)"
        ev.score["beats"] = beats
        ev.diagnostics["beats"] = beatDiagnostics(pred: pred, estBeats: estBeats, refBeats: refBeats, refDown: refDown, window: window)
        if let sections = pred.barPhase, !refDown.isEmpty {
            let report = phaseDiagnostics(sections: sections, pred: pred, refDown: refDown, window: window)
            ev.diagnostics["barPhase"] = report.json
            for (k, v) in report.row { ev.row[k] = v }
        }
    }

    // 5. Chords.
    if let chords = truth.chords, !chords.isEmpty {
        let segments = pred.chords
        func labelAt(_ t: Double) -> String? { segments.first { t >= $0.start && t < $0.end }?.label }
        var truthChords: [TruthChord] = []
        var allRootSeconds = 0.0, allRootHit = 0.0, covered = 0.0
        for c in chords {
            guard let rq = truthChordRootQuality(c) else { continue }
            for (a, b) in window.clip(c.start, c.end) {
                truthChords.append(TruthChord(start: a, end: b, root: rq.root, quality: rq.quality, label: c.label ?? ""))
                var t = a + 0.025
                while t < b {
                    allRootSeconds += 0.05
                    if let l = labelAt(t) {
                        covered += 0.05
                        if let parsed = parseChordLabel(l), parsed.root == rq.root { allRootHit += 0.05 }
                    }
                    t += 0.05
                }
            }
        }
        let s = scoreChords(truth: truthChords, labelAt: labelAt)
        ev.score["chords"] = ["root": r4(s.rootAccuracy), "majmin": r4(s.majMinAccuracy), "scoredSeconds": r1(s.scoredSeconds),
                              "rootAllChords": r4(allRootSeconds > 0 ? allRootHit / allRootSeconds : 0),
                              "allChordSeconds": r1(allRootSeconds),
                              "predChordCoverage": r4(allRootSeconds > 0 ? covered / allRootSeconds : 0),
                              "conventions": "share of time (50 ms steps) with the right root / root and major-minor class, over truth chords that reduce to maj or min (MusicBench scoreChords); rootAllChords also counts dim/sus/aug spans"]
        ev.row["chordRoot"] = s.rootAccuracy
        ev.row["chordMajMin"] = s.majMinAccuracy
    }
    return ev
}

func predDrumClass(_ kind: String) -> DrumClass? {
    switch kind {
    case "kick": .kick
    case "snare": .snare
    case "closedHat", "openHat", "ride": .hihat
    default: nil
    }
}

extension DrumClass {
    var gm: Int {
        switch self {
        case .kick: 36
        case .snare: 38
        case .hihat: 42
        }
    }
}

// MARK: - Note diagnostics

func noteDiagnostics(est: [ENote], ref: [ENote], m50: [Int: Int], m100: [Int: Int], window: ScoreWindow,
                     offsetsReliable: Bool, pairs: [(p: Int, r: Int)],
                     causes: (fp: [Int: String], fn: [Int: String])) -> [String: Any] {
    var d: [String: Any] = [:]
    let matchedRef50 = Set(m50.values)

    // Onset timing of exact-pitch matches within 100 ms.
    let errs = m100.map { est[$0.key].on - ref[$0.value].on }
    var hist = [Int](repeating: 0, count: 20)   // [-100, 100) ms in 10 ms bins
    for e in errs {
        let b = Int(((e * 1000 + 100) / 10).rounded(.down))
        hist[min(max(b, 0), 19)] += 1
    }
    d["onsetError"] = [
        "matchesWithin100ms": errs.count,
        "binsMs": (0..<20).map { -100 + 10 * $0 }, "counts": hist,
        "meanMs": r1((errs.reduce(0, +) / Double(max(errs.count, 1))) * 1000),
        "medianMs": r1((median(errs) ?? 0) * 1000),
        "share25ms": r4(Double(errs.filter { abs($0) <= 0.025 }.count) / Double(max(errs.count, 1))),
        "share50ms": r4(Double(errs.filter { abs($0) <= 0.05 }.count) / Double(max(errs.count, 1))),
        "note": "predicted minus true onset; a median far from 0 means a constant latency or a misaligned key",
    ]

    // Global shift scan: which constant offset of the predictions maximizes F1.
    var shifts: [Int] = [], f1s: [Double] = []
    for ms in stride(from: -200, through: 200, by: 10) {
        let m = noteMatches(pred: est, ref: ref, tolerance: 0.05, shift: Double(ms) / 1000)
        shifts.append(ms)
        f1s.append(r4(prf(m.count, predCount: est.count, refCount: ref.count).f1))
    }
    let best = f1s.indices.max { f1s[$0] < f1s[$1] || (f1s[$0] == f1s[$1] && abs(shifts[$0]) > abs(shifts[$1])) }!
    d["alignmentScan"] = ["shiftMs": shifts, "f1": f1s, "bestShiftMs": shifts[best], "bestF1": f1s[best],
                          "f1AtZero": f1s[shifts.firstIndex(of: 0)!],
                          "note": "F1 (50 ms) after adding shiftMs to every predicted onset; best at -30 means the predictions run 30 ms late"]

    // Pitch errors: leftover predictions paired with leftover true notes struck within 50 ms.
    let freeP = est.indices.filter { m50[$0] == nil }
    let freeR = ref.indices.filter { !matchedRef50.contains($0) }
    var intervals: [String: Int] = [:]
    var categories: [String: Int] = ["octave (+-12/24/36)": 0, "fifth or twelfth (+-7/19)": 0, "fourth (+-5/17)": 0,
                                     "semitone (+-1)": 0, "whole tone (+-2)": 0, "third (+-3/4)": 0, "other": 0]
    for (p, r) in pairs {
        let iv = est[p].pitch - ref[r].pitch
        intervals[String(format: "%+d", iv), default: 0] += 1
        let a = abs(iv)
        let cat: String
        if a % 12 == 0 { cat = "octave (+-12/24/36)" }
        else if a == 7 || a == 19 { cat = "fifth or twelfth (+-7/19)" }
        else if a == 5 || a == 17 { cat = "fourth (+-5/17)" }
        else if a == 1 { cat = "semitone (+-1)" }
        else if a == 2 { cat = "whole tone (+-2)" }
        else if a == 3 || a == 4 { cat = "third (+-3/4)" }
        else { cat = "other" }
        categories[cat, default: 0] += 1
    }
    d["pitchErrors"] = [
        "wrongPitchPairs": pairs.count,
        "extraNotes": freeP.count - pairs.count,
        "missedNotes": freeR.count - pairs.count,
        "intervalPredMinusTrue": intervals,
        "categories": categories,
        "note": "after exact matching (50 ms), each leftover prediction is paired with a leftover true note struck within 50 ms (smallest interval first); unpaired leftovers are extra (FP) or missed (FN) notes",
    ]

    // Why each false positive / false negative happened (first rule that applies; see errors.csv).
    func tally(_ m: [Int: String], _ notes: [ENote]) -> [String: Any] {
        var counts: [String: Int] = [:], examples: [String: [Double]] = [:]
        for (i, c) in m.sorted(by: { notes[$0.key].on < notes[$1.key].on }) {
            counts[c, default: 0] += 1
            if examples[c, default: []].count < 8 { examples[c, default: []].append(r4(notes[i].on)) }
        }
        return ["counts": counts, "exampleTimes": examples]
    }
    d["errorCauses"] = [
        "falsePositives": tally(causes.fp, est),
        "falseNegatives": tally(causes.fn, ref),
        "note": "each FP / FN gets the first cause that applies, in this order. FP: wrong pitch (paired with a missed note), duplicate onset, timing 50-150 ms, re-onset inside a held true note, ghost octave/harmonic (2nd-8th partial or sub-octave) of a struck then of a sounding true note, neighbour, unrelated / in silence. FN: wrong pitch, one prediction for two true notes, timing 50-150 ms, not re-struck inside a held predicted note, masked by a found octave/harmonic, nothing / other notes detected",
    ]
    let vFound = m50.values.compactMap { ref[$0].velocity }.map(Double.init)
    let vMissed = ref.indices.filter { !matchedRef50.contains($0) }.compactMap { ref[$0].velocity }.map(Double.init)
    if !vFound.isEmpty || !vMissed.isEmpty {
        d["velocity"] = ["medianTrueVelocityFound": median(vFound) ?? 0, "medianTrueVelocityMissed": median(vMissed) ?? 0,
                         "found": vFound.count, "missed": vMissed.count,
                         "note": "true MIDI velocities of found vs missed notes (a lower median for missed notes = quiet notes are lost)"]
    }

    // Pitch-class and octave confusion over exact matches plus wrong-pitch pairs.
    var pcm = [[Int]](repeating: [Int](repeating: 0, count: 12), count: 12)
    let octaves = Array(-1...9)
    var om = [[Int]](repeating: [Int](repeating: 0, count: octaves.count), count: octaves.count)
    func oct(_ p: Int) -> Int { min(max(p / 12 - 1, -1), 9) + 1 }
    for (p, r) in m50.map({ ($0.key, $0.value) }) + pairs.map({ ($0.p, $0.r) }) {
        pcm[ref[r].pitch % 12][est[p].pitch % 12] += 1
        om[oct(ref[r].pitch)][oct(est[p].pitch)] += 1
    }
    let usedOct = octaves.indices.filter { i in om[i].contains { $0 > 0 } || om.contains { $0[i] > 0 } }
    d["pitchClassConfusion"] = ["rowsTrue": pitchNames, "colsPred": pitchNames, "matrix": pcm,
                                "note": "exact matches (diagonal) plus wrong-pitch pairs, by pitch class"]
    d["octaveConfusion"] = ["octaves": usedOct.map { octaves[$0] },
                            "matrix": usedOct.map { i in usedOct.map { om[i][$0] } },
                            "note": "rows = true octave, cols = predicted octave (C4 = middle C = octave 4)"]

    // By pitch range (octave) and by pitch class.
    var byOct: [[String: Any]] = []
    for o in -1...9 {
        let lo = (o + 1) * 12, hi = lo + 11
        let tp = m50.filter { ref[$0.value].pitch >= lo && ref[$0.value].pitch <= hi }.count
        let nRef = ref.filter { $0.pitch >= lo && $0.pitch <= hi }.count
        let nEst = est.filter { $0.pitch >= lo && $0.pitch <= hi }.count
        guard nRef + nEst > 0 else { continue }
        let s = prf(tp, predCount: nEst, refCount: nRef)
        byOct.append(["octave": o, "range": "\(noteName(lo))-\(noteName(hi))", "truth": nRef, "pred": nEst,
                      "tp": tp, "fp": s.fp, "fn": s.fn, "precision": r4(s.precision), "recall": r4(s.recall), "f1": r4(s.f1)])
    }
    d["byOctave"] = byOct
    var byPC: [[String: Any]] = []
    for pc in 0..<12 {
        let tp = m50.filter { ref[$0.value].pitch % 12 == pc }.count
        let nRef = ref.filter { $0.pitch % 12 == pc }.count
        let nEst = est.filter { $0.pitch % 12 == pc }.count
        let s = prf(tp, predCount: nEst, refCount: nRef)
        byPC.append(["pitchClass": pitchNames[pc], "truth": nRef, "pred": nEst, "tp": tp, "fp": s.fp, "fn": s.fn,
                     "f1": r4(s.f1)])
    }
    d["byPitchClass"] = byPC

    // Over time, 10 s windows.
    var overTime: [[String: Any]] = []
    var t0 = window.start
    while t0 < window.end {
        let t1 = min(t0 + 10, window.end)
        let tp = m50.filter { ref[$0.value].on >= t0 && ref[$0.value].on < t1 }.count
        let nRef = ref.filter { $0.on >= t0 && $0.on < t1 }.count
        let nEst = est.filter { $0.on >= t0 && $0.on < t1 }.count
        let s = prf(tp, predCount: nEst, refCount: nRef)
        overTime.append(["start": r1(t0), "end": r1(t1), "truth": nRef, "pred": nEst, "tp": tp, "fp": s.fp, "fn": s.fn,
                         "f1": r4(s.f1)])
        t0 = t1
    }
    d["overTime"] = overTime

    // Durations and offsets of exact matches (50 ms).
    var offErr: [Double] = [], ratios: [Double] = []
    for (p, r) in m50 {
        offErr.append(est[p].off - ref[r].off)
        let dr = ref[r].off - ref[r].on, dp = est[p].off - est[p].on
        if dr > 0, dp > 0 { ratios.append(dp / dr) }
    }
    var offHist = [Int](repeating: 0, count: 22)   // <-1 s, [-1, 1) in 100 ms bins, >= 1 s
    for e in offErr {
        let b = e < -1 ? 0 : (e >= 1 ? 21 : 1 + Int(((e + 1) * 10).rounded(.down)))
        offHist[min(max(b, 0), 21)] += 1
    }
    var ratioHist = [Int](repeating: 0, count: 14)   // log2 ratio: < -3, [-3, 3) in 0.5 steps, >= 3
    for x in ratios {
        let l = log2(x)
        let b = l < -3 ? 0 : (l >= 3 ? 13 : 1 + Int(((l + 3) * 2).rounded(.down)))
        ratioHist[min(max(b, 0), 13)] += 1
    }
    let offBins: [String] = ["<-1000"] + (0..<20).map { String(-1000 + 100 * $0) } + [">=1000"]
    let ratioBins: [String] = ["<-3"] + (0..<12).map { String(format: "%.1f", -3 + 0.5 * Double($0)) } + [">=3"]
    var dur: [String: Any] = [:]
    dur["matched"] = m50.count
    dur["offsetsReliable"] = offsetsReliable
    dur["offsetErrorBinsMs"] = offBins
    dur["offsetErrorCounts"] = offHist
    dur["medianOffsetErrorMs"] = r1((median(offErr) ?? 0) * 1000)
    dur["medianAbsOffsetErrorMs"] = r1((median(offErr.map(abs)) ?? 0) * 1000)
    dur["durationRatioLog2Bins"] = ratioBins
    dur["durationRatioCounts"] = ratioHist
    dur["medianDurationRatio"] = r4(median(ratios) ?? 0)
    dur["tooShort(<0.5x)"] = ratios.filter { $0 < 0.5 }.count
    dur["tooLong(>2x)"] = ratios.filter { $0 > 2 }.count
    dur["medianTrueDurationS"] = r4(median(ref.map { $0.off - $0.on }) ?? 0)
    dur["medianPredDurationS"] = r4(median(est.map { $0.off - $0.on }) ?? 0)
    dur["note"] = "predicted minus true offset, and predicted / true duration, for exact 50 ms matches"
    d["duration"] = dur
    return d
}

/// After exact matching, pairs each leftover prediction with a leftover true
/// note struck within 50 ms (smallest interval, then nearest onset first).
func wrongPitchPairs(est: [ENote], ref: [ENote], m50: [Int: Int]) -> [(p: Int, r: Int)] {
    let matchedRef50 = Set(m50.values)
    let freeP = est.indices.filter { m50[$0] == nil }
    let freeR = ref.indices.filter { !matchedRef50.contains($0) }
    var cands: [(p: Int, r: Int, dp: Int, dt: Double)] = []
    let freeRSorted = freeR.sorted { ref[$0].on < ref[$1].on }
    let freeROns = freeRSorted.map { ref[$0].on }
    for p in freeP {
        var lo = 0, hi = freeROns.count
        while lo < hi { let mid = (lo + hi) / 2; if freeROns[mid] < est[p].on - 0.05001 { lo = mid + 1 } else { hi = mid } }
        var i = lo
        while i < freeROns.count, freeROns[i] <= est[p].on + 0.05001 {
            let r = freeRSorted[i]
            let dt = abs(est[p].on - ref[r].on)
            if rounded4(dt) <= 0.05 { cands.append((p, r, abs(est[p].pitch - ref[r].pitch), dt)) }
            i += 1
        }
    }
    cands.sort { ($0.dp, $0.dt, $0.p, $0.r) < ($1.dp, $1.dt, $1.p, $1.r) }
    var usedP = Set<Int>(), usedR = Set<Int>()
    var pairs: [(p: Int, r: Int)] = []
    for c in cands where !usedP.contains(c.p) && !usedR.contains(c.r) {
        usedP.insert(c.p); usedR.insert(c.r); pairs.append((c.p, c.r))
    }
    return pairs
}

func intervalKind(_ iv: Int) -> String {
    let a = abs(iv)
    if a == 0 { return "unison" }
    if a % 12 == 0 { return "octave" }
    if a == 7 || a == 19 || a == 31 { return "fifth/twelfth" }
    if a == 1 { return "semitone" }
    return "other interval"
}

/// Upper partials of a note (2nd-8th harmonic) and sub-octaves: where Basic Pitch's ghost notes sit.
func isHarmonicRelation(_ iv: Int) -> Bool { [12, 19, 24, 28, 31, 34, 36, -12, -24].contains(iv) }

/// One cause per false positive (pred index) and false negative (ref index), first rule that applies.
func explainErrors(est: [ENote], ref: [ENote], m50: [Int: Int], pairs: [(p: Int, r: Int)])
    -> (fp: [Int: String], fn: [Int: String]) {
    let matchedRef = Set(m50.values)
    let refToEst = Dictionary(uniqueKeysWithValues: m50.map { ($0.value, $0.key) })
    let pairP = Dictionary(uniqueKeysWithValues: pairs.map { ($0.p, $0.r) })
    let pairR = Dictionary(uniqueKeysWithValues: pairs.map { ($0.r, $0.p) })
    let refOrder = ref.indices.sorted { ref[$0].on < ref[$1].on }
    let estOrder = est.indices.sorted { est[$0].on < est[$1].on }
    let maxRefDur = ref.map { $0.off - $0.on }.max() ?? 0
    let maxEstDur = est.map { $0.off - $0.on }.max() ?? 0
    /// Indices (in `order`) of notes with onset in [a, b].
    func range(_ notes: [ENote], _ order: [Int], _ a: Double, _ b: Double) -> ArraySlice<Int> {
        var lo = 0, hi = order.count
        while lo < hi { let mid = (lo + hi) / 2; if notes[order[mid]].on < a { lo = mid + 1 } else { hi = mid } }
        var end = lo
        while end < order.count, notes[order[end]].on <= b { end += 1 }
        return order[lo..<end]
    }
    var fp: [Int: String] = [:], fn: [Int: String] = [:]
    for (p, e) in est.enumerated() where m50[p] == nil {
        if let r = pairP[p] { fp[p] = "wrong pitch (" + intervalKind(e.pitch - ref[r].pitch) + ")"; continue }
        let near = range(ref, refOrder, e.on - 0.15, e.on + 0.15)
        let samePitch = near.filter { ref[$0].pitch == e.pitch }
        if samePitch.contains(where: { rounded4(abs(ref[$0].on - e.on)) <= 0.05 && matchedRef.contains($0) }) {
            fp[p] = "duplicate onset (true note already matched)"; continue
        }
        if !samePitch.isEmpty { fp[p] = "timing off by 50-150 ms"; continue }
        let sounding = range(ref, refOrder, e.on - maxRefDur, e.on).filter { ref[$0].off > e.on }
        if sounding.contains(where: { ref[$0].pitch == e.pitch }) { fp[p] = "re-onset inside a held true note"; continue }
        let struck = near.filter { rounded4(abs(ref[$0].on - e.on)) <= 0.05 }
        if struck.contains(where: { isHarmonicRelation(e.pitch - ref[$0].pitch) }) {
            fp[p] = "ghost: octave/harmonic of a struck true note"; continue
        }
        if sounding.contains(where: { isHarmonicRelation(e.pitch - ref[$0].pitch) }) {
            fp[p] = "ghost: octave/harmonic of a sounding true note"; continue
        }
        if (struck + sounding).contains(where: { abs(e.pitch - ref[$0].pitch) <= 2 }) {
            fp[p] = "neighbour (1-2 semitones) of a true note"; continue
        }
        fp[p] = struck.isEmpty && sounding.isEmpty ? "no true note sounding (extra note in silence)" : "unrelated pitch over true notes"
    }
    for (r, n) in ref.enumerated() where !matchedRef.contains(r) {
        if let p = pairR[r] { fn[r] = "wrong pitch (" + intervalKind(est[p].pitch - n.pitch) + ")"; continue }
        let near = range(est, estOrder, n.on - 0.15, n.on + 0.15)
        let samePitch = near.filter { est[$0].pitch == n.pitch }
        if samePitch.contains(where: { rounded4(abs(est[$0].on - n.on)) <= 0.05 && m50[$0] != nil }) {
            fn[r] = "one predicted note for two true notes (unison / repeated)"; continue
        }
        if !samePitch.isEmpty { fn[r] = "timing off by 50-150 ms"; continue }
        let held = range(est, estOrder, n.on - maxEstDur, n.on).filter { est[$0].off > n.on && est[$0].pitch == n.pitch }
        if !held.isEmpty { fn[r] = "not re-struck: inside a held predicted note"; continue }
        let found = range(ref, refOrder, n.on - 0.05, n.on + 0.05)
            .filter { refToEst[$0] != nil && isHarmonicRelation(n.pitch - ref[$0].pitch) }
        if !found.isEmpty { fn[r] = "masked: an octave/harmonic of a found true note"; continue }
        let struckPreds = near.filter { rounded4(abs(est[$0].on - n.on)) <= 0.05 }
        fn[r] = struckPreds.isEmpty ? "nothing detected at that moment" : "other notes detected, not this one"
    }
    return (fp, fn)
}

func errorRows(est: [ENote], ref: [ENote], m50: [Int: Int], causes: (fp: [Int: String], fn: [Int: String])) -> String {
    func t(_ x: Double) -> String { String(format: "%.4f", x) }
    var rows: [(Double, Int, String)] = []
    let refToEst = Dictionary(uniqueKeysWithValues: m50.map { ($0.value, $0.key) })
    for (r, n) in ref.enumerated() {
        var cols = [t(n.on), t(n.off), String(n.pitch), noteName(n.pitch), csvSafe(n.label), csvSafe(n.instrument)]
        if let p = refToEst[r] {
            let e = est[p]
            cols = ["TP"] + cols + [e.label, noteName(e.pitch), t(e.on), t(e.off), String(format: "%.1f", (e.on - n.on) * 1000), ""]
        } else {
            cols = ["FN"] + cols + ["", "", "", "", "", csvSafe(causes.fn[r] ?? "")]
        }
        rows.append((n.on, n.pitch, cols.joined(separator: ",")))
    }
    for (p, e) in est.enumerated() where m50[p] == nil {
        let cols = ["FP", t(e.on), t(e.off), String(e.pitch), noteName(e.pitch), "", "", e.label, noteName(e.pitch),
                    t(e.on), t(e.off), "", csvSafe(causes.fp[p] ?? "")]
        rows.append((e.on, e.pitch, cols.joined(separator: ",")))
    }
    rows.sort { ($0.0, $0.1) < ($1.0, $1.1) }
    return "status,time,end,pitch,name,truthPart,truthInstrument,predPart,predName,predStart,predEnd,onsetErrorMs,cause\n"
        + rows.map(\.2).joined(separator: "\n") + "\n"
}

func csvSafe(_ s: String) -> String { s.replacingOccurrences(of: ",", with: ";") }

// MARK: - Drums and beats

func drumDiagnostics(pred: [(time: Double, cls: DrumClass)], ref: [TruthDrum], all: [RBTruthDrum]) -> [String: Any] {
    var d: [String: Any] = [:]
    var conf: [String: [String: Int]] = [:]
    var timing: [String: Any] = [:]
    var unmatchedPred: [(time: Double, cls: DrumClass)] = []
    var unmatchedRef: [(time: Double, cls: DrumClass)] = []
    for cls in DrumClass.allCases {
        let p = pred.filter { $0.cls == cls }.map(\.time)
        let r = ref.filter { DrumClass.of(gmNote: $0.gmNote) == cls }.map(\.time)
        let pairs = matchOnsets(pred: p, ref: r, tolerance: 0.05)
        let errs = pairs.map { p[$0.0] - r[$0.1] }
        timing[cls.rawValue] = ["matched": errs.count, "medianErrorMs": r1((median(errs) ?? 0) * 1000)]
        let mp = Set(pairs.map(\.0)), mr = Set(pairs.map(\.1))
        unmatchedPred += p.indices.filter { !mp.contains($0) }.map { (p[$0], cls) }
        unmatchedRef += r.indices.filter { !mr.contains($0) }.map { (r[$0], cls) }
    }
    // A leftover predicted hit next to a leftover true hit of another class: a class confusion.
    var usedRef = Set<Int>()
    var otherNear = 0
    for h in unmatchedPred {
        if let j = unmatchedRef.indices.filter({ !usedRef.contains($0) && abs(unmatchedRef[$0].time - h.time) <= 0.05 })
            .min(by: { abs(unmatchedRef[$0].time - h.time) < abs(unmatchedRef[$1].time - h.time) }) {
            usedRef.insert(j)
            conf["pred " + h.cls.rawValue, default: [:]]["true " + unmatchedRef[j].cls.rawValue, default: 0] += 1
        } else if all.contains(where: { $0.scoredClass == nil && abs($0.time - h.time) <= 0.05 }) {
            otherNear += 1
        } else {
            conf["pred " + h.cls.rawValue, default: [:]]["nothing", default: 0] += 1
        }
    }
    d["timing"] = timing
    d["falseHitsExplained"] = conf
    d["falseHitsOnUnscoredDrums"] = otherNear
    d["note"] = "false hits paired with a missed hit of another class within 50 ms (class confusion), on a tom/crash/other true hit, or on nothing"
    return d
}

func beatDiagnostics(pred: Prediction, estBeats: [Double], refBeats: [Double], refDown: [Double], window: ScoreWindow) -> [String: Any] {
    var d: [String: Any] = [:]
    if refBeats.count > 1 {
        let doubled = zip(refBeats, refBeats.dropFirst()).flatMap { [$0.0, ($0.0 + $0.1) / 2] } + [refBeats.last!]
        let halfA = refBeats.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        let halfB = refBeats.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
        d["beatF1vsMetricalVariants"] = [
            "asIs": r4(scoreBeats(pred: estBeats, ref: refBeats).f1),
            "truthAtDoubleTempo": r4(scoreBeats(pred: estBeats, ref: doubled).f1),
            "truthAtHalfTempoEven": r4(scoreBeats(pred: estBeats, ref: halfA).f1),
            "truthAtHalfTempoOdd": r4(scoreBeats(pred: estBeats, ref: halfB).f1),
            "note": "a high double/half score means the tracker locked to twice/half the tempo (the app's 2x / 1/2x buttons)",
        ]
    }
    // Downbeats under every bar shift of the predicted grid (the app's bar-nudge control).
    let m = max(pred.beatsPerBar, 1)
    if !refDown.isEmpty, let firstDown = pred.downbeats.first, let i0 = pred.beats.firstIndex(of: firstDown) {
        var byShift: [String: Double] = [:]
        for shift in 0..<m {
            let downs = pred.beats.enumerated().filter { ((($0.offset - i0 - shift) % m) + m) % m == 0 }.map(\.element)
                .filter { window.contains($0) }
            byShift[String(shift)] = r4(scoreBeats(pred: downs, ref: refDown).f1)
        }
        d["downbeatF1byBarShift"] = byShift
    }
    let gaps = zip(estBeats.dropFirst(), estBeats).map { $0 - $1 }
    if gaps.count > 2 {
        d["predTempoSpreadBPM"] = ["p10": r1(60 / (gaps.sorted()[gaps.count * 9 / 10])), "p90": r1(60 / (gaps.sorted()[gaps.count / 10]))]
    }
    return d
}

/// A section whose bar lines beat their best shift by less than this (clipped
/// z-score units summed over the section, `BarPhase.sections`) is fragile: a
/// small change in the evidence can move them.
let fragilePhaseMargin = 2.0

/// Song mode's bar-phase margins (`Prediction.barPhase`) with the key's verdict
/// on each section: its downbeat F1 against the key, and whether it is wrong
/// (F1 under 0.5) or fragile (margin under `fragilePhaseMargin`).
func phaseDiagnostics(sections: [PredPhaseSection], pred: Prediction, refDown: [Double], window: ScoreWindow)
    -> (json: [String: Any], row: [String: Double]) {
    var list: [[String: Any]] = []
    var scored = 0, fragile = 0, wrong = 0, wrongFragile = 0, overridden = 0
    for (k, s) in sections.enumerated() {
        // The section runs to the next one's first beat.
        let end = k + 1 < sections.count ? sections[k + 1].start : s.end + 1e-6
        let est = pred.downbeats.filter { $0 >= s.start - 0.035 && $0 < end - 0.035 && window.contains($0) }
        let ref = refDown.filter { $0 >= s.start - 0.035 && $0 < end - 0.035 }
        var item: [String: Any] = ["start": r4(s.start), "end": r4(s.end), "beats": s.beats, "margin": r4(s.margin),
                                   "runnerUpShift": s.runnerUpShift, "decoderAgrees": s.decoderAgrees,
                                   "fragile": s.margin < fragilePhaseMargin]
        if !s.decoderAgrees { overridden += 1 }
        if ref.count >= 2 {
            let f1 = scoreBeats(pred: est, ref: ref).f1
            item["downbeatF1"] = r4(f1)
            scored += 1
            if s.margin < fragilePhaseMargin { fragile += 1 }
            if f1 < 0.5 { wrong += 1; if s.margin < fragilePhaseMargin { wrongFragile += 1 } }
        }
        list.append(item)
    }
    let json: [String: Any] = [
        "sections": list,
        "scoredSections": scored, "fragile": fragile, "wrong": wrong, "wrongAndFragile": wrongFragile,
        "decoderOverridden": overridden,
        "note": "BarPhase.sections: per section of BarPhase.sectionBars bars, the evidence for the bar lines shown minus the best shift of them (clipped z-scores); fragile below \(fragilePhaseMargin); wrong = downbeat F1 against the key under 0.5; decoderAgrees = the bar-pointer model alone had the same bar lines",
    ]
    return (json, ["phaseSections": Double(scored), "phaseFragile": Double(fragile), "phaseWrong": Double(wrong),
                   "phaseWrongFragile": Double(wrongFragile)])
}
