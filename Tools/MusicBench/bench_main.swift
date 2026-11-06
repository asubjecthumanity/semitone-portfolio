import Foundation
import CoreML

// MusicBench: scores the any-instrument pipeline on the synthetic songs made
// by `render`, stage by stage, with the app's own code.
//
//   musicbench <songsDir> [--set dev|test|all] [--sweep notes|voices|all] [--json out.json]
//
// Tune on the dev songs only; report the test songs as the held-out result.

/// Everything slow about a song, computed once.
struct SongRun {
    let truth: SongTruth
    let mix: TranscriptionEngine
    let tonal: TranscriptionEngine
    let percussive: [Float]
    let mixAudio: [Float]
    /// The rhythm evidence the app's beat tracker reads next to the notes: the tonal part's
    /// onsets, and the percussive part's on a song with a kit (OnsetEnvelope.music).
    let onsets: AudioOnsets

    /// What MusicTranscriber transcribes: the tonal part when drums are prominent.
    var usesTonal: Bool {
        MusicTranscriber.percussiveShare(mix: mixAudio, percussive: percussive) >= MusicTranscriber.Settings().tonalPartAbove
    }
    /// The app's pitched notes for this song (before part splitting).
    func pipelineNotes() -> [NoteEvent] {
        let s = MusicTranscriber.Settings()
        return usesTonal ? tonal.extractNotes(config: s.tonalExtraction) : mix.extractNotes(config: s.extraction)
    }
    var pitched: [TruthNote] { truth.notes }
}

func runEngine(_ samples: [Float], model: BasicPitchModel) throws -> TranscriptionEngine {
    let engine = TranscriptionEngine(model: model)
    try engine.append(samples)
    try engine.finalize()
    return engine
}

struct NoteScore {
    var all = PRF()
    var octave = 0
    var byVoice: [PartRole: PRF] = [:]
    /// Matched notes whose predicted part equals the true part.
    var roleCorrect = 0
    var roleTotal = 0

    static func + (a: NoteScore, b: NoteScore) -> NoteScore {
        var s = NoteScore(all: a.all + b.all, octave: a.octave + b.octave)
        for r in PartRole.allCases { s.byVoice[r] = (a.byVoice[r] ?? PRF()) + (b.byVoice[r] ?? PRF()) }
        s.roleCorrect = a.roleCorrect + b.roleCorrect
        s.roleTotal = a.roleTotal + b.roleTotal
        return s
    }

    var roleAccuracy: Double { roleTotal == 0 ? 0 : Double(roleCorrect) / Double(roleTotal) }

    var line: String {
        let v = PartRole.allCases.map { String(format: "%@ %.3f", $0.rawValue, byVoice[$0]?.f1 ?? 0) }.joined(separator: "  ")
        return String(format: "notes %@  oct %d | parts: %@ | part acc %.3f", all.short, octave, v, roleAccuracy)
    }
}

func voice(for role: PartRole) -> Voice {
    switch role {
    case .melody: .melody
    case .chords: .chords
    case .bass: .bass
    }
}

func scoreNotesAndVoices(_ notes: [NoteEvent], truth: SongTruth) -> NoteScore {
    var s = NoteScore()
    let (prf, matches) = scoreNotes(pred: notes, ref: truth.notes)
    s.all = prf
    s.octave = octaveErrors(pred: notes, ref: truth.notes, matches: matches)
    for (p, r) in matches {
        s.roleTotal += 1
        if notes[p].voice == voice(for: truth.notes[r].role) { s.roleCorrect += 1 }
    }
    for role in PartRole.allCases {
        let pred = notes.filter { $0.voice == voice(for: role) }
        let ref = truth.notes.filter { $0.role == role }
        s.byVoice[role] = scoreNotes(pred: pred, ref: ref).prf
    }
    return s
}

func chordLabeler(_ segments: [ChordSegment]) -> (Double) -> String? {
    { t in segments.first { t >= $0.startTime && t < $0.endTime }?.label }
}

// MARK: - Main

let options: Options
do {
    options = try parseOptions()
} catch {
    fputs("musicbench: \(error)\n", stderr)
    exit(2)
}
guard !options.dir.isEmpty else {
    print("usage: musicbench <songsDir> [--set dev|test|all] [--sweep notes|voices|all] [--json out.json]")
    exit(2)
}
let fm = FileManager.default
let names = ((try? fm.contentsOfDirectory(atPath: options.dir)) ?? [])
    .filter { $0.hasSuffix(".json") }
    .map { String($0.dropLast(5)) }
    .filter { options.set == "all" || $0.hasPrefix(options.set) }
    .sorted()
guard !names.isEmpty else { print("no songs for set \(options.set) in \(options.dir)"); exit(1) }

// The binary lives in Tools/MusicBench/.build; the model in Semitone/.
let modelPackage = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    .deletingLastPathComponent().appendingPathComponent("../../../Semitone/NMP.mlpackage").standardized
let model = try BasicPitchModel(modelURL: try MLModel.compileModel(at: modelPackage))

var runs: [SongRun] = []
let loadStart = Date()
for name in names {
    let base = URL(fileURLWithPath: options.dir).appendingPathComponent(name)
    let truth = try JSONDecoder().decode(SongTruth.self, from: Data(contentsOf: base.appendingPathExtension("json")))
    let audio = try AudioFileLoader.loadMono(url: base.appendingPathExtension("wav"), sampleRate: BPConstants.sampleRate, downmix: true)
    var hpss = HarmonicPercussive.Settings()
    if let spec = ProcessInfo.processInfo.environment["HPSS"] {   // HPSS="31,9": harmonic, percussive kernels
        let k = spec.split(separator: ",").compactMap { Int($0) }
        hpss.harmonicKernel = k[0]
        hpss.percussiveKernel = k[1]
    }
    guard let parts = HarmonicPercussive.separate(audio, settings: hpss) else { fatalError("separation failed") }
    // The audio's evidence as Song mode passes it (TakePipeline.audioEvidence): onsets, chord
    // changes, the kit, and the tonal part's pitch classes, which the tracker reads for the bar
    // lines (BarPhase). The renders are in tune, so the chroma is read at A440.
    var onsets = OnsetEnvelope.music(parts, percussiveShare: SourceProfiler.percussiveShare(
        mix: audio, percussive: parts.percussive), sampleRate: BPConstants.sampleRate)
    onsets.chroma = OnsetEnvelope.tonalChroma(parts.harmonic, sampleRate: BPConstants.sampleRate)
    runs.append(SongRun(truth: truth, mix: try runEngine(audio, model: model),
                        tonal: try runEngine(parts.harmonic, model: model),
                        percussive: parts.percussive, mixAudio: audio, onsets: onsets))
}
print(String(format: "%d songs (%@) prepared in %.1f s\n", runs.count, options.set, Date().timeIntervalSince(loadStart)))
for run in runs {
    func energy(_ x: [Float]) -> Double { x.reduce(0) { $0 + Double($1) * Double($1) } }
    let ratio = energy(run.percussive) / max(energy(run.mixAudio), 1e-12)
    print(String(format: "  %-7@ %-9@ percussive energy %.3f  drums in truth %d%@",
                 run.truth.name, run.truth.style, ratio, run.truth.drums.count,
                 run.onsets.percussion.map {
                     String(format: "  (percussive onsets in the beat evidence, weight %.2f)", $0.weight)
                 } ?? ""))
}

print("Evaluation: \(options.evaluationKind) (set: \(options.set))")
print("Scorer: \(scoringVersion) (note distances rounded to 4 decimals; inclusive tolerance)")
var report: [String: Any] = ["set": options.set, "evaluationKind": options.evaluationKind, "sweep": options.sweep,
                           "scoringVersion": scoringVersion, "noteOnsetToleranceSeconds": 0.05,
                           "noteDistanceDecimals": 4, "onsetBoundary": "inclusive", "pitchMatch": "exact"]

func evaluateNotes(config: NoteExtraction.Config, tonal: Bool, voices: VoiceSplitter.Settings,
                   perSong: Bool = false) -> NoteScore {
    var total = NoteScore()
    for run in runs {
        let engine = tonal ? run.tonal : run.mix
        let notes = VoiceSplitter.assign(engine.extractNotes(config: config), settings: voices)
        let s = scoreNotesAndVoices(notes, truth: run.truth)
        if perSong { print(String(format: "  %-7@ %-9@ %@", run.truth.name, run.truth.style, s.line)) }
        total = total + s
    }
    return total
}

// 1. Pitched notes: presets on the raw mix vs the tonal part.
let presets: [(String, NoteExtraction.Config)] = [
    ("piano", DetectionMode.piano.config),
    ("gentle", DetectionMode.gentle.config),
    ("dense", DetectionMode.dense.config),
    ("bp-default", NoteExtraction.Config(onsetThreshold: 0.5, frameThreshold: 0.3, minNoteLengthMs: 127.7, suppressOctaveLeak: false)),
    ("music", .music),
]
print("== Pitched notes (all parts, instrument-agnostic) ==")
var presetJSON: [[String: Any]] = []
for tonal in [false, true] {
    for (name, config) in presets {
        let s = evaluateNotes(config: config, tonal: tonal, voices: VoiceSplitter.Settings())
        print(String(format: "%-6@ %-10@ %@", tonal ? "tonal" : "mix", name, s.line))
        presetJSON.append(["input": tonal ? "tonal" : "mix", "preset": name, "f1": s.all.f1,
                           "precision": s.all.precision, "recall": s.all.recall, "partAccuracy": s.roleAccuracy])
    }
}
report["presets"] = presetJSON
print("\n== App pipeline (input chosen per song, music presets) ==")
var pipelineTotal = NoteScore()
for run in runs {
    let s = scoreNotesAndVoices(VoiceSplitter.assign(run.pipelineNotes()), truth: run.truth)
    print(String(format: "  %-7@ %-9@ %@ %@", run.truth.name, run.truth.style, run.usesTonal ? "tonal" : "mix  ", s.line))
    pipelineTotal = pipelineTotal + s
}
print("  total                   \(pipelineTotal.line)")
report["pipeline"] = ["f1": pipelineTotal.all.f1, "precision": pipelineTotal.all.precision, "recall": pipelineTotal.all.recall,
                      "melodyF1": pipelineTotal.byVoice[.melody]?.f1 ?? 0, "chordsF1": pipelineTotal.byVoice[.chords]?.f1 ?? 0,
                      "bassF1": pipelineTotal.byVoice[.bass]?.f1 ?? 0, "partAccuracy": pipelineTotal.roleAccuracy]
if let spec = ProcessInfo.processInfo.environment["COMPARE"] {
    // COMPARE="mix:0.7:0.4:90,tonal:0.6:0.4:90" prints each config per song.
    for item in spec.split(separator: ",") {
        let f = item.split(separator: ":")
        let c = NoteExtraction.Config(onsetThreshold: Float(f[1])!, frameThreshold: Float(f[2])!, minNoteLengthMs: Double(f[3])!)
        print("\nper song: \(item)")
        let s = evaluateNotes(config: c, tonal: f[0] == "tonal", voices: VoiceSplitter.Settings(), perSong: true)
        print("  total   \(s.line)")
    }
}

// 2. Optional sweeps (dev only!).
if options.sweep == "notes" || options.sweep == "all" {
    print("\n== Sweep: extraction thresholds ==")
    var results: [(String, Double, NoteScore)] = []
    for tonal in [false, true] {
        for onset: Float in [0.3, 0.4, 0.5, 0.6, 0.7] {
            for frame: Float in [0.2, 0.25, 0.3, 0.4] {
                for minMs in [60.0, 90.0, 120.0, 150.0] {
                    for leak in [true, false] {
                        let c = NoteExtraction.Config(onsetThreshold: onset, frameThreshold: frame, minNoteLengthMs: minMs, suppressOctaveLeak: leak)
                        let s = evaluateNotes(config: c, tonal: tonal, voices: VoiceSplitter.Settings())
                        let label = String(format: "%@ onset %.2f frame %.2f min %3.0f leak %@", tonal ? "tonal" : "mix  ", onset, frame, minMs, leak ? "on " : "off")
                        results.append((label, s.all.f1, s))
                    }
                }
            }
        }
    }
    for r in results.sorted(by: { $0.1 > $1.1 }).prefix(15) { print("\(r.0)  \(r.2.line)") }
}

if options.sweep == "voices" || options.sweep == "all" {
    print("\n== Sweep: part splitting (app pipeline notes) ==")
    var results: [(String, Double, NoteScore)] = []
    let notesPerSong = runs.map { $0.pipelineNotes() }
    for ceiling in [48, 50, 52, 55] {
        for floor in [55, 57, 60] {
            for gap in [0, 3, 5] {
                for doubt in [3, 99] {
                    for memory in [0.5, 1.5, 3.0] {
                        let v = VoiceSplitter.Settings(bassCeiling: ceiling, melodyFloor: floor, melodyGapOverChord: gap,
                                                       chordSizeForDoubt: doubt, melodyMemory: memory)
                        var total = NoteScore()
                        for (run, notes) in zip(runs, notesPerSong) {
                            total = total + scoreNotesAndVoices(VoiceSplitter.assign(notes, settings: v), truth: run.truth)
                        }
                        let partF1 = PartRole.allCases.map { total.byVoice[$0]?.f1 ?? 0 }.reduce(0, +) / 3
                        results.append((String(format: "ceil %d floor %d gap %d doubt %2d mem %.1f", ceiling, floor, gap, doubt, memory), partF1, total))
                    }
                }
            }
        }
    }
    for r in results.sorted(by: { $0.1 > $1.1 }).prefix(12) { print(String(format: "%@  mean part F1 %.3f  %@", r.0, r.1, r.2.line)) }
}

// 3. Drums: not scored. The app no longer transcribes drums; the last
// transcriber it shipped is benchmarked by drums/build_drumbench.sh.
print("\n== Drums ==")
print("not scored: the any-instrument pipeline transcribes no drums")
report["drums"] = "not scored"

// 4. Beats (from the notes and the audio's onsets: the tonal part's, and the
// percussive part's on a drum-heavy song, as the app's tracker reads them) and
// chords from the music preset's notes.
print("\n== Beats and chords ==")
var beatPRF = PRF(), downPRF = PRF(), beatNotesOnly = PRF(), downNotesOnly = PRF(), downDecoder = PRF()
var chordAll = ChordScore(), chordNoMelody = ChordScore()
for run in runs {
    let notes = VoiceSplitter.assign(run.pipelineNotes())
    let result = BeatTracker.track(notes: notes, duration: run.truth.duration, beatsPerBar: nil, audioOnsets: run.onsets)
    let plain = BeatTracker.track(notes: notes, duration: run.truth.duration, beatsPerBar: nil)
    beatNotesOnly = beatNotesOnly + scoreBeats(pred: plain.beats, ref: run.truth.beats)
    downNotesOnly = downNotesOnly + scoreBeats(pred: zip(plain.beats, plain.barPositions).filter { $0.1 == 0 }.map(\.0),
                                               ref: run.truth.downbeats)
    let downbeats = zip(result.beats, result.barPositions).filter { $0.1 == 0 }.map(\.0)
    let songBeats = scoreBeats(pred: result.beats, ref: run.truth.beats)
    let songDown = scoreBeats(pred: downbeats, ref: run.truth.downbeats)
    beatPRF = beatPRF + songBeats
    downPRF = downPRF + songDown
    // The bar-pointer model's own bar lines on the same beats (no BarPhase).
    let decoder = BeatTracker.track(notes: notes, duration: run.truth.duration, beatsPerBar: nil, audioOnsets: run.onsets,
                                    barPhase: false)
    let decoderDown = scoreBeats(pred: zip(decoder.beats, decoder.barPositions).filter { $0.1 == 0 }.map(\.0),
                                 ref: run.truth.downbeats)
    downDecoder = downDecoder + decoderDown
    print(String(format: "  %-7@ %-9@ %3.0f bpm %d/4  beats F1 %.3f  downbeats F1 %.3f  (detected %.0f bpm, %d/bar; bar-pointer bar lines %.3f)",
                 run.truth.name, run.truth.style, run.truth.bpm, run.truth.beatsPerBar, songBeats.f1, songDown.f1,
                 result.medianBPM, result.beatsPerBar, decoderDown.f1))
    chordAll = chordAll + scoreChords(truth: run.truth.chords, labelAt: chordLabeler(ChordAnalyzer.segments(notes)))
    chordNoMelody = chordNoMelody + scoreChords(truth: run.truth.chords,
                                                labelAt: chordLabeler(ChordAnalyzer.segments(notes.filter { $0.voice != .melody })))
}
print("beats      \(beatPRF.short)   (notes only: \(beatNotesOnly.short))")
print("downbeats  \(downPRF.short)   (notes only: \(downNotesOnly.short); bar-pointer bar lines: \(downDecoder.short))")
print(String(format: "chords (all notes)       root %.3f  majmin %.3f", chordAll.rootAccuracy, chordAll.majMinAccuracy))
print(String(format: "chords (without melody)  root %.3f  majmin %.3f", chordNoMelody.rootAccuracy, chordNoMelody.majMinAccuracy))
report["beats"] = ["f1": beatPRF.f1, "downbeatF1": downPRF.f1, "downbeatF1BarPointer": downDecoder.f1]
report["chords"] = ["root": chordAll.rootAccuracy, "majmin": chordAll.majMinAccuracy,
                    "rootNoMelody": chordNoMelody.rootAccuracy, "majminNoMelody": chordNoMelody.majMinAccuracy]

if let path = options.json {
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: path))
    print("\nreport: \(path)")
}
