import Foundation

// What a refine pass hands the post-take analysis (TakeAnalysis.derive): the
// notes, the notes the chords also read, and the audio's rhythm and pitch
// evidence. `realbench ... --save-evidence` writes it next to each pipeline's
// prediction (<pipeline>/evidence.json); `realbench regrid` reads it back and
// runs only the analysis (beat grid, chords, melody) with the current code, in
// a second or two instead of a full transcription. Use it to tune the rhythm
// and chord stages on fixed notes; anything that changes the notes needs a
// full run.

nonisolated struct EvidenceNote: Codable {
    var s: Double
    var e: Double
    var p: Int
    var a: Double
    var v: UInt8

    init(_ n: NoteEvent) { s = n.startTime; e = n.endTime; p = n.pitch; a = n.amplitude; v = n.voice.rawValue }
    var note: NoteEvent { NoteEvent(startTime: s, endTime: e, pitch: p, amplitude: a, voice: Voice(rawValue: v) ?? .none) }
}

nonisolated struct EvidenceOnsets: Codable {
    var onsets: [Float]
    var harmony: [Float]?
    var chroma: [Float]?
    var percussionOnsets: [Float]?
    var percussionLow: [Float]?
    var percussionWeight: Float?

    init(_ o: AudioOnsets) {
        onsets = o.onsets; harmony = o.harmony; chroma = o.chroma
        percussionOnsets = o.percussion?.onsets; percussionLow = o.percussion?.low; percussionWeight = o.percussion?.weight
    }
    var audioOnsets: AudioOnsets {
        var o = AudioOnsets(onsets: onsets, harmony: harmony, chroma: chroma)
        if let p = percussionOnsets, let l = percussionLow {
            o.percussion = AudioOnsets.Percussion(onsets: p, low: l, weight: percussionWeight ?? 1)
        }
        return o
    }
}

nonisolated struct Evidence: Codable {
    var format = "realbench-evidence-1"
    var pipeline: String
    var audio: String
    /// Clip time: notes and onsets start at 0; `clipStart` puts them on the file's timeline.
    var clipStart: Double
    var duration: Double
    var notes: [EvidenceNote]
    var harmonyNotes: [EvidenceNote]
    var sustain: [PredSpan]
    var detected: Bool
    var onsets: EvidenceOnsets?
    var info: [String: String]
    var seconds: Double
}

/// Filled by makePrediction while a run saves evidence (`--save-evidence`).
var evidenceSink: [String: Evidence]? = nil

/// `realbench regrid <runDir> <truth.json | none> [--out DIR] [--beats-per-bar N] [--tempo-octave K]
/// [--downbeat-pitch-class N] [--ignore a:b]`: the analysis again on a run's saved evidence.
func regridCommand(_ raw: [String]) throws {
    let args = try Args(raw)
    guard args.positional.count == 2 else {
        throw RBError("usage: realbench regrid <runDir> <truth.json | none> [--out DIR] [--beats-per-bar N] [--ignore a:b]")
    }
    let runDir = URL(fileURLWithPath: args.positional[0])
    let truthPath = args.positional[1]
    let truth: RBTruth? = truthPath == "none" ? nil : try RBTruth.load(truthPath)
    let outDir = args.last("--out").map { URL(fileURLWithPath: $0) } ?? runDir
    var settings = RunSettings()
    if let b = args.last("--beats-per-bar") {
        guard let n = Int(b), (1...16).contains(n) else { throw RBError("--beats-per-bar takes 1-16") }
        settings.beatsPerBar = n
    }
    if let t = args.last("--tempo-octave") { settings.tempoOctave = Int(t) ?? 0 }
    if let pc = args.last("--downbeat-pitch-class") { settings.downbeatPitchClass = Int(pc).map { (($0 % 12) + 12) % 12 } }
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: runDir.path)) ?? []).sorted()
    var preds: [Prediction] = []
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    for name in names {
        let file = runDir.appendingPathComponent(name).appendingPathComponent("evidence.json")
        guard let data = try? Data(contentsOf: file) else { continue }
        let ev = try JSONDecoder().decode(Evidence.self, from: data)
        settings.clipStart = ev.clipStart
        let started = Date()
        var (pred, midi) = makePrediction(
            pipeline: ev.pipeline, audioPath: ev.audio, settings: settings, duration: ev.duration,
            notes: ev.notes.map(\.note),
            sustain: ev.sustain.map { PedalEvent(startTime: $0.start - ev.clipStart, endTime: $0.end - ev.clipStart) },
            detected: ev.detected, info: ev.info, seconds: ev.seconds, onsets: ev.onsets?.audioOnsets,
            harmonyNotes: ev.harmonyNotes.map(\.note))
        pred.info["regridSeconds"] = String(format: "%.2f", Date().timeIntervalSince(started))
        let dir = outDir.appendingPathComponent(ev.pipeline)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encoder.encode(pred).write(to: dir.appendingPathComponent("notes.json"))
        try midi.write(to: dir.appendingPathComponent("notes.mid"))
        if outDir != runDir {
            let dst = dir.appendingPathComponent("evidence.json")
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.copyItem(at: file, to: dst)
        }
        preds.append(pred)
    }
    guard let first = preds.first else { throw RBError("no <pipeline>/evidence.json under \(runDir.path) (run with --save-evidence)") }
    let header: [String: Any] = ["format": "realbench-summary-1", "command": CommandLine.arguments.joined(separator: " "),
                                 "audio": first.audio, "truth": truthPath, "clipStart": first.clipStart,
                                 "clipDuration": first.clipDuration, "regriddedFrom": runDir.path,
                                 "date": ISO8601DateFormatter().string(from: Date())]
    guard let truth else {
        try writeJSON(header, to: outDir.appendingPathComponent("summary.json"))
        print("regridded (no truth): \(outDir.path)")
        return
    }
    try scoreAndWrite(predictions: preds, truth: truth,
                      window: makeWindow(start: first.clipStart, duration: first.clipDuration, truth: truth,
                                         extra: try args.spans("--ignore")),
                      outDir: outDir, header: header)
}
