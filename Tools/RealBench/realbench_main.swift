import Foundation
import CoreML

// realbench: runs every Semitone transcription pipeline on a real recording
// and scores it against an answer key. See README.md.

let usage = """
usage:
  realbench <audio> <truth.json | none> --out DIR [options]      transcribe + score
  realbench score <runDir> <truth.json> [--out DIR] [--ignore a:b]  re-score a run's saved predictions
  realbench regrid <runDir> <truth.json | none> [--out DIR]          beat grid and chords again on saved evidence
  realbench midi2truth <out.json> --midi FILE.mid [--part P] ...    MIDI -> truth JSON (see `realbench midi2truth`)
  realbench check <truth.json>                                       validate and summarize a truth file
  realbench parse-chord LABEL...                                     show how truth chord labels are read

options for a run:
  --pipelines quick,quick-music,piano,music   which pipelines (default: all four)
  --start S --duration D     transcribe only this clip of the file (seconds); times stay on the file's timeline
  --ignore a:b               extra span to leave out of scoring (repeatable; adds to the truth's "ignore")
  --detection piano|auto|gentle|dense   the quick passes' detection preset (app default: piano = Balanced)
  --beats-per-bar N          the app's "beats per bar" setting (default auto: 3, 4 or 5)
  --tempo-octave -1|0|1      the app's 1/2x / 2x tempo buttons
  --downbeat-pitch-class N   the app's "note on beat 1" hint (0 = C)
  --piano-units ane|cpu|all|gpu   Core ML units for the piano model (app: ane = .cpuAndNeuralEngine)
  --save-evidence            also write <pipeline>/evidence.json (notes and audio evidence) for `regrid`
"""

nonisolated struct Args {
    var positional: [String] = []
    var options: [String: [String]] = [:]

    init(_ raw: [String], flags: Set<String> = []) throws {
        var i = 0
        while i < raw.count {
            let a = raw[i]
            if a.hasPrefix("--") {
                if flags.contains(a) { options[a, default: []].append("1") } else {
                    guard i + 1 < raw.count else { throw RBError("\(a) needs a value") }
                    options[a, default: []].append(raw[i + 1])
                    i += 1
                }
            } else {
                positional.append(a)
            }
            i += 1
        }
    }

    func last(_ k: String) -> String? { options[k]?.last }
    func double(_ k: String) throws -> Double? {
        guard let v = last(k) else { return nil }
        guard let d = Double(v), d.isFinite else { throw RBError("\(k) needs a number, got \(v)") }
        return d
    }
    func spans(_ k: String) throws -> [(Double, Double)] {
        try (options[k] ?? []).map { s in
            let v = s.split(separator: ":").compactMap { Double($0) }
            guard v.count == 2, v[0] <= v[1] else { throw RBError("\(k) takes start:end, got \(s)") }
            return (v[0], v[1])
        }
    }
}

func writeJSON(_ object: Any, to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url)
}

/// The scored window. A clip that starts inside the file gets a 100 ms edge
/// guard: notes held across the cut are heard as onsets at the clip start.
func makeWindow(start: Double, duration: Double, truth: RBTruth?, extra: [(Double, Double)]) -> ScoreWindow {
    let guardSpan: [(Double, Double)] = start > 0 ? [(start, start + 0.1)] : []
    return ScoreWindow(start: start, end: start + duration,
                       ignore: guardSpan + (truth?.ignore ?? []).map { ($0[0], $0[1]) } + extra)
}

/// Scores every prediction, writes per-pipeline score/diagnostics/errors and the summary.
func scoreAndWrite(predictions: [Prediction], truth: RBTruth, window: ScoreWindow, outDir: URL, header: [String: Any]) throws {
    var summary: [String: Any] = header
    var rows: [(String, [String: Double], Double)] = []
    var scores: [String: Any] = [:]
    for pred in predictions {
        let dir = outDir.appendingPathComponent(pred.pipeline)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ev = evaluate(prediction: pred, truth: truth, window: window)
        var score = ev.score
        score["info"] = pred.info
        score["runSeconds"] = pred.seconds
        try writeJSON(score, to: dir.appendingPathComponent("score.json"))
        try writeJSON(ev.diagnostics, to: dir.appendingPathComponent("diagnostics.json"))
        try ev.errorsCSV.write(to: dir.appendingPathComponent("errors.csv"), atomically: true, encoding: .utf8)
        scores[pred.pipeline] = score
        rows.append((pred.pipeline, ev.row, pred.seconds))
    }
    summary["scores"] = scores
    try writeJSON(summary, to: outDir.appendingPathComponent("summary.json"))
    let text = summaryTable(rows: rows, truth: truth, window: window)
    try text.write(to: outDir.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
    print(text)
}

func summaryTable(rows: [(String, [String: Double], Double)], truth: RBTruth, window: ScoreWindow) -> String {
    func f(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "  -  " }
    var lines: [String] = []
    let ref = (truth.notes ?? []).filter { window.contains($0.on) }
    lines.append(String(format: "truth %@: %d notes in %.1f s scored (window %.1f-%.1f s%@)%@%@",
                        truth.name ?? "?", ref.count, window.scoredSeconds, window.start, window.end,
                        window.ignore.isEmpty ? "" : ", ignoring " + window.ignore.map { String(format: "%.1f-%.1f", $0.0, $0.1) }.joined(separator: ", "),
                        truth.notesComplete == false ? "; key INCOMPLETE: precision undercounts" : "",
                        truth.offsetsReliable == false ? "; offsets estimated" : ""))
    lines.append("")
    func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
    lines.append("pipeline     notes50   P50    R50  | notes100 octfold50 on+off50 | melody counter chords  bass  partAcc |  kick  snare  hihat  | beats  downb | chRoot chMajMin |  sec")
    for (name, r, sec) in rows {
        let drums: String
        if r["drumsNotScored"] != nil {
            drums = pad("   not scored", 17)
        } else if let n = r["drumFalseHits"] {
            drums = pad(String(format: "drumless:%3.0f hits", n), 17)
        } else {
            drums = "\(f(r["drum.kick"])) \(f(r["drum.snare"])) \(f(r["drum.hihat"]))"
        }
        lines.append(pad(name, 12) + " " + [f(r["notes50"]), f(r["P50"]), f(r["R50"])].joined(separator: "  ")
            + " | " + [f(r["notes100"]), "  " + f(r["chroma50"]), "  " + f(r["onoff50"])].joined(separator: "   ")
            + "  | " + [f(r["melody"]), " " + f(r["countermelody"]), f(r["chords"]), f(r["bass"]), f(r["partAcc"])].joined(separator: "  ")
            + "  | " + drums + " | " + f(r["beats"]) + "  " + f(r["downbeats"])
            + " | " + f(r["chordRoot"]) + "  " + f(r["chordMajMin"]) + "   | " + String(format: "%5.1f", sec))
    }
    for (name, r, _) in rows {
        guard let n = r["phaseSections"] else { continue }
        lines.append(String(format: "bar phase (%@): %.0f sections of %d bars scored, %.0f fragile (margin < %.0f), %.0f wrong per the key (%.0f of them fragile)",
                            name, n, BarPhase.sectionBars, r["phaseFragile"] ?? 0, fragilePhaseMargin, r["phaseWrong"] ?? 0,
                            r["phaseWrongFragile"] ?? 0))
    }
    lines.append("")
    lines.append("notes: exact pitch, onset +-50 / +-100 ms, one-to-one (mir_eval); octfold = pitch class only; on+off adds mir_eval's offset rule.")
    lines.append("melody for unsplit pipelines = the app's LeadLine; parts / drums / beats / chords only where the truth has them.")
    if rows.contains(where: { $0.1["drumsNotScored"] != nil }) {
        lines.append("drums: not scored; the app no longer transcribes drums (the truth's drum hits are kept for old predictions).")
    }
    return lines.joined(separator: "\n") + "\n"
}

// MARK: - Commands

func runCommand(_ raw: [String]) throws {
    let args = try Args(raw, flags: ["--save-evidence"])
    guard args.positional.count == 2, let outPath = args.last("--out") else { throw RBError(usage) }
    if args.last("--save-evidence") != nil { evidenceSink = [:] }
    let audioPath = args.positional[0], truthPath = args.positional[1]
    guard FileManager.default.fileExists(atPath: audioPath) else { throw RBError("no audio file at \(audioPath)") }
    let truth: RBTruth? = truthPath == "none" ? nil : try RBTruth.load(truthPath)
    var settings = RunSettings()
    if let p = args.last("--pipelines") {
        settings.pipelines = p.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        for name in settings.pipelines where !allPipelines.contains(name) {
            throw RBError("unknown pipeline \(name) (known: \(allPipelines.joined(separator: ", ")))")
        }
    }
    settings.clipStart = try args.double("--start") ?? 0
    settings.clipDuration = try args.double("--duration")
    if let d = args.last("--detection") {
        guard let m = DetectionMode(rawValue: d), m != .custom else { throw RBError("--detection piano|auto|gentle|dense") }
        settings.detection = m
    }
    if let b = args.last("--beats-per-bar") {
        guard let n = Int(b), (1...16).contains(n) else { throw RBError("--beats-per-bar takes 1-16") }
        settings.beatsPerBar = n
    }
    if let t = args.last("--tempo-octave") { settings.tempoOctave = Int(t) ?? 0 }
    if let pc = args.last("--downbeat-pitch-class") { settings.downbeatPitchClass = Int(pc).map { (($0 % 12) + 12) % 12 } }
    if let u = args.last("--piano-units") {
        let map: [String: MLComputeUnits] = ["ane": .cpuAndNeuralEngine, "cpu": .cpuOnly, "all": .all, "gpu": .cpuAndGPU]
        guard let units = map[u] else { throw RBError("--piano-units ane|cpu|all|gpu") }
        settings.pianoUnits = units
    }
    let extra = try args.spans("--ignore")

    let outDir = URL(fileURLWithPath: outPath)
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let started = Date()
    let results = try runPipelines(audioPath: audioPath, settings: settings)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    for (pred, midi) in results {
        let dir = outDir.appendingPathComponent(pred.pipeline)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encoder.encode(pred).write(to: dir.appendingPathComponent("notes.json"))
        try midi.write(to: dir.appendingPathComponent("notes.mid"))
        if let ev = evidenceSink?[pred.pipeline] {
            try JSONEncoder().encode(ev).write(to: dir.appendingPathComponent("evidence.json"))
        }
    }
    let header: [String: Any] = [
        "format": "realbench-summary-1",
        "command": CommandLine.arguments.joined(separator: " "),
        "audio": audioPath, "truth": truthPath,
        "clipStart": settings.clipStart, "clipDuration": results.first?.0.clipDuration ?? 0,
        "pipelines": settings.pipelines,
        "settings": ["detection": settings.detection.rawValue, "beatsPerBar": settings.beatsPerBar.map(String.init) ?? "auto",
                     "tempoOctave": settings.tempoOctave, "pianoUnits": settings.pianoUnits.rawValue],
        "totalSeconds": r1(Date().timeIntervalSince(started)),
        "date": ISO8601DateFormatter().string(from: Date()),
    ]
    guard let truth else {
        try writeJSON(header, to: outDir.appendingPathComponent("summary.json"))
        print("transcribed (no truth): \(outDir.path)")
        return
    }
    let duration = results.first?.0.clipDuration ?? 0
    try scoreAndWrite(predictions: results.map(\.0), truth: truth,
                      window: makeWindow(start: settings.clipStart, duration: duration, truth: truth, extra: extra),
                      outDir: outDir, header: header)
    print("results: \(outDir.path)")
}

func scoreCommand(_ raw: [String]) throws {
    let args = try Args(raw)
    guard args.positional.count == 2 else { throw RBError(usage) }
    let runDir = URL(fileURLWithPath: args.positional[0])
    let truth = try RBTruth.load(args.positional[1])
    let outDir = args.last("--out").map { URL(fileURLWithPath: $0) } ?? runDir
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: runDir.path)) ?? []).sorted()
    var preds: [Prediction] = []
    for name in names {
        let file = runDir.appendingPathComponent(name).appendingPathComponent("notes.json")
        guard let data = try? Data(contentsOf: file) else { continue }
        preds.append(try JSONDecoder().decode(Prediction.self, from: data))
    }
    guard let first = preds.first else { throw RBError("no <pipeline>/notes.json under \(runDir.path)") }
    preds.sort { (allPipelines.firstIndex(of: $0.pipeline) ?? 99) < (allPipelines.firstIndex(of: $1.pipeline) ?? 99) }
    if outDir != runDir {
        for p in preds {
            let dir = outDir.appendingPathComponent(p.pipeline)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for f in ["notes.json", "notes.mid"] {
                let src = runDir.appendingPathComponent(p.pipeline).appendingPathComponent(f)
                let dst = dir.appendingPathComponent(f)
                try? FileManager.default.removeItem(at: dst)
                try? FileManager.default.copyItem(at: src, to: dst)
            }
        }
    }
    let header: [String: Any] = ["format": "realbench-summary-1", "command": CommandLine.arguments.joined(separator: " "),
                                 "audio": first.audio, "truth": args.positional[1], "clipStart": first.clipStart,
                                 "clipDuration": first.clipDuration, "rescoredFrom": runDir.path,
                                 "date": ISO8601DateFormatter().string(from: Date())]
    try scoreAndWrite(predictions: preds, truth: truth,
                      window: makeWindow(start: first.clipStart, duration: first.clipDuration, truth: truth,
                                         extra: try args.spans("--ignore")),
                      outDir: outDir, header: header)
}

func checkCommand(_ raw: [String]) throws {
    guard let path = raw.first else { throw RBError(usage) }
    let t = try RBTruth.load(path)
    let notes = t.notes ?? []
    print("\(path): \(t.name ?? "(no name)")")
    if let lo = notes.map(\.on).min(), let hi = notes.map(\.off).max() {
        print(String(format: "  notes: %d (%.2f-%.2f s, pitch %@-%@)", notes.count, lo, hi,
                     noteName(notes.map(\.pitch).min()!), noteName(notes.map(\.pitch).max()!)))
    } else {
        print("  notes: 0")
    }
    var byPart: [String: Int] = [:], byInst: [String: Int] = [:]
    for n in notes { byPart[n.partName, default: 0] += 1; if let i = n.instrument { byInst[i, default: 0] += 1 } }
    print("  parts: " + byPart.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)\(roleNames.contains($0.key) ? " (role)" : "")" }.joined(separator: ", "))
    if !byInst.isEmpty { print("  instruments: " + byInst.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")) }
    let bad = notes.filter { $0.off < $0.on || $0.pitch < 0 || $0.pitch > 127 }
    if !bad.isEmpty { print("  WARNING: \(bad.count) notes with off < on or pitch outside 0-127") }
    if let d = t.drums {
        var byClass: [String: Int] = [:]
        for h in d { byClass[h.scoredClass?.rawValue ?? "unscored", default: 0] += 1 }
        print("  drums: \(d.count) (" + byClass.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + ")")
    } else { print("  drums: not scored") }
    print("  beats: \(t.beats?.count ?? 0), downbeats: \(t.downbeats?.count ?? 0)\(t.beatsPerBar.map { ", \($0) per bar" } ?? "")")
    if let c = t.chords {
        let parsed = c.filter { truthChordRootQuality($0) != nil }
        let majmin = parsed.filter { majMin(quality: truthChordRootQuality($0)!.quality) != nil }
        print("  chords: \(c.count) spans (\(parsed.count) with a root, \(majmin.count) scorable as maj/min)")
        let unparsed = Set(c.filter { truthChordRootQuality($0) == nil }.compactMap(\.label))
        if !unparsed.isEmpty { print("    no chord / unparsed labels: " + unparsed.sorted().prefix(20).joined(separator: " ")) }
    } else { print("  chords: none") }
    if let ig = t.ignore, !ig.isEmpty { print("  ignore: " + ig.map { String(format: "%.1f-%.1f", $0[0], $0[1]) }.joined(separator: ", ")) }
    if t.notesComplete == false { print("  notesComplete: false (precision is a lower bound)") }
    if t.offsetsReliable == false { print("  offsetsReliable: false") }
}

// MARK: - Main

var argv = Array(CommandLine.arguments.dropFirst())
do {
    switch argv.first {
    case nil, "-h", "--help", "help": print(usage); exit(argv.isEmpty ? 2 : 0)
    case "score": try scoreCommand(Array(argv.dropFirst()))
    case "regrid": try regridCommand(Array(argv.dropFirst()))
    case "midi2truth":
        if argv.count == 1 { print(midiUsage); exit(2) }
        try midiToTruthCommand(Array(argv.dropFirst()))
    case "check": try checkCommand(Array(argv.dropFirst()))
    case "parse-chord":
        // How truth chord labels are read: root pitch class, quality, maj/min class (nil = not scored by majmin).
        for label in argv.dropFirst() {
            if let rq = truthChordRootQuality(RBTruthChord(start: 0, end: 1, label: label)) {
                print("\(label)\troot \(pitchNames[rq.root])\tquality \(rq.quality)\tmajmin \(majMin(quality: rq.quality) ?? "-")")
            } else {
                print("\(label)\tno chord")
            }
        }
    case "run": try runCommand(Array(argv.dropFirst()))
    default: try runCommand(argv)
    }
} catch {
    log("realbench: \(error)")
    exit(1)
}
