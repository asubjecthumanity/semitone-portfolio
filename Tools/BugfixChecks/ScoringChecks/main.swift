import Foundation

nonisolated struct OracleCase: Decodable {
    var name: String
    var kind: String
    var pred: [Double]
    var ref: [Double]
    var predPitch: [Int]
    var refPitch: [Int]
    var tolerance: Double
    var expectedTP: Int
}
nonisolated struct Oracle: Decodable {
    var mir_eval_version: String
    var cases: [OracleCase]
}
guard CommandLine.arguments.count == 2 else {
    print("usage: scoringchecks <scoring_oracle.json>"); exit(2)
}
let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
guard oracle.mir_eval_version == "0.8.2" else { print("Unexpected oracle version"); exit(2) }
var checks = 0
var failures: [String] = []
func expect(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { failures.append(message) }
}
for c in oracle.cases {
    let pairs: [(Int, Int)]
    if c.kind == "note" {
        let pred = c.pred.indices.map {
            NoteEvent(startTime: c.pred[$0], endTime: c.pred[$0] + 0.1, pitch: c.predPitch[$0], amplitude: 0.8)
        }
        let ref = c.ref.indices.map {
            TruthNote(pitch: c.refPitch[$0], on: c.ref[$0], off: c.ref[$0] + 0.1,
                      velocity: 80, role: .melody, program: 0)
        }
        let score = scoreNotes(pred: pred, ref: ref, tolerance: c.tolerance)
        pairs = score.matches.map { ($0.key, $0.value) }
        expect(score.prf.tp == c.expectedTP && score.prf.fp == c.pred.count - c.expectedTP &&
               score.prf.fn == c.ref.count - c.expectedTP, "\(c.name): incorrect PRF counts")
        let expectedF1 = c.pred.count + c.ref.count == 0 ? 0 :
            Double(2 * c.expectedTP) / Double(c.pred.count + c.ref.count)
        expect(abs(score.prf.f1 - expectedF1) < 1e-12, "\(c.name): incorrect F1")
    } else {
        pairs = matchOnsets(pred: c.pred, ref: c.ref, tolerance: c.tolerance)
    }
    expect(pairs.count == c.expectedTP, "\(c.name): count disagrees with mir_eval")
    expect(Set(pairs.map { $0.0 }).count == pairs.count && Set(pairs.map { $0.1 }).count == pairs.count,
           "\(c.name): a note/event was matched more than once")
    for (p, r) in pairs {
        let distance = abs(c.pred[p] - c.ref[r])
        let eligible = c.kind == "note" ? (distance * 10_000).rounded(.toNearestOrEven) / 10_000 : distance
        expect(eligible <= c.tolerance && (c.kind != "note" || c.predPitch[p] == c.refPitch[r]),
               "\(c.name): an ineligible edge was accepted")
    }
}
// Exercise the public drum/beat wrappers as well as their shared matcher.
let drumScore = scoreDrums(pred: [(0.04, .kick), (0.10, .kick)],
                           ref: [TruthDrum(time: 0, gmNote: 36, velocity: 80),
                                 TruthDrum(time: 0.06, gmNote: 36, velocity: 80)])
expect(drumScore[.kick]?.tp == 2, "Drum wrapper retained greedy matching")
expect(scoreBeats(pred: [0.04, 0.10], ref: [0, 0.06], tolerance: 0.05).tp == 2,
       "Beat wrapper retained greedy matching")
if failures.isEmpty { print("All \(checks) Swift scorer checks passed across \(oracle.cases.count) mir_eval cases.") }
else { for failure in failures { print("FAIL: \(failure)") }; exit(1) }
