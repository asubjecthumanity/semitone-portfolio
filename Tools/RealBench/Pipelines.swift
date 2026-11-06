import Foundation
import CoreML

// Runs the app's transcription pipelines on an audio file the way
// TranscriberViewModel.transcribeFile + completeTake + the refine passes do,
// with the app's own sources (compiled in by build.sh). Nothing here
// reimplements a pipeline: it only loads audio, calls the app code and
// collects what the app would show (notes, parts, beat grid, chords).

// MARK: - Prediction file ("realbench-prediction-1")

nonisolated struct PredNote: Codable {
    var start: Double
    var end: Double
    var pitch: Int
    /// MIDI velocity as the app's MIDI export writes it.
    var velocity: Int
    /// NoteEvent.amplitude (Basic Pitch activation, or Transkun velocity / 127).
    var amplitude: Double
    /// "none" (unsplit), "melody", "chords" or "bass".
    var part: String
}

/// A drum hit in a prediction saved before the app stopped transcribing drums
/// (October 2026); kept so `realbench score` still reads and scores those.
nonisolated struct PredDrum: Codable {
    var time: Double
    /// kick, snare, closedHat, openHat, crash, ride, lowTom or highTom.
    var kind: String
    var gmNote: Int
    var velocity: Double
}

nonisolated struct PredSpan: Codable {
    var start: Double
    var end: Double
}

nonisolated struct PredChord: Codable {
    var start: Double
    var end: Double
    var label: String
}

/// One section of the bar-phase decision (`BarPhase.sections`): how much more
/// evidence the bar lines shown have than the best shift of them.
nonisolated struct PredPhaseSection: Codable {
    var start: Double
    var end: Double
    var beats: Int
    /// Clipped z-score units summed over the section's bars; small = fragile.
    var margin: Double
    /// The runner-up: every bar line moved this many beats later.
    var runnerUpShift: Int
    /// Whether the bar-pointer model alone put the bar lines in the same place.
    var decoderAgrees: Bool
}

nonisolated struct Prediction: Codable {
    var format = "realbench-prediction-1"
    var pipeline: String
    var description: String
    var audio: String
    /// Times are on the audio file's timeline; the pipeline saw [clipStart, clipStart + clipDuration).
    var clipStart: Double
    var clipDuration: Double
    /// Whether notes carry parts (melody / countermelody / chords / bass).
    var split: Bool
    var notes: [PredNote]
    /// The melody the app shows: LeadLine over the notes for unsplit takes, the melody part otherwise.
    var leadLine: [PredNote]
    var sustain: [PredSpan]
    /// nil: no pipeline transcribes drums any more (older predictions may have them).
    var drums: [PredDrum]?
    var beats: [Double]
    var downbeats: [Double]
    var beatsPerBar: Int
    var bpm: Double
    var chords: [PredChord]
    var info: [String: String]
    var seconds: Double
    /// Song mode's bar-phase margin per section of `BarPhase.sectionBars` bars (nil without the audio's chroma).
    var barPhase: [PredPhaseSection]? = nil
}

nonisolated let allPipelines = ["quick", "quick-music", "piano", "music"]
let pipelineDescriptions = [
    "quick": "Basic Pitch quick pass, Piano mode (what the app shows live and when the piano model is off): first channel at 22050 Hz, detection preset (default Piano/Balanced 0.70/0.30/150 ms), no parts",
    "quick-music": "Basic Pitch quick pass, Any-instrument mode (the preview before the any-instrument pass finishes): all channels mixed, preset resolved for music (Balanced = 0.70/0.40/90 ms), VoiceSplitter parts, no drums",
    "piano": "Piano mode refine pass (TakePipeline): Transkun v2 on the 44.1 kHz mixed take, notes + sustain pedal; the quick notes when the engine arbiter rejects it, as the app shows",
    "music": "Any-instrument refine pass (TakePipeline): input conditioning, source profile, note engine + arbiter, VoiceSplitter parts (no drums)",
]

nonisolated struct RunSettings {
    var pipelines = allPipelines
    var clipStart = 0.0
    var clipDuration: Double? = nil
    var detection = DetectionMode.piano
    var beatsPerBar: Int? = nil
    var tempoOctave = 0
    var downbeatPitchClass: Int? = nil
    var pianoUnits = MLComputeUnits.cpuAndNeuralEngine
}

/// Locates the repository (binary in Tools/RealBench/.build) and the models.
nonisolated struct ModelFiles {
    let repo: URL
    let buildDir: URL

    init() {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        buildDir = exe.deletingLastPathComponent()
        if let env = ProcessInfo.processInfo.environment["REALBENCH_REPO"] {
            repo = URL(fileURLWithPath: env)
        } else {
            repo = buildDir.appendingPathComponent("../../..").standardized
        }
    }

    /// The compiled model next to the binary (build.sh), else compiled now from the app's package.
    func compiled(_ name: String) throws -> URL {
        let prebuilt = buildDir.appendingPathComponent(name + ".mlmodelc")
        if FileManager.default.fileExists(atPath: prebuilt.path) { return prebuilt }
        let package = repo.appendingPathComponent("Semitone/\(name).mlpackage")
        log("compiling \(package.path)")
        return try MLModel.compileModel(at: package)
    }

    var pianoWeights: URL { repo.appendingPathComponent("Semitone/TranskunWeights.bin") }
}

nonisolated func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

/// Audio as each code path in the app loads it, trimmed to the clip.
nonisolated struct TakeAudio {
    /// AudioFileLoader.loadMono22k: Piano mode's live/quick input (first channel unless it is quiet).
    let pianoQuick22k: [Float]
    /// AudioFileLoader.loadMono(22050, downmix): Any-instrument mode's quick input.
    let musicQuick22k: [Float]
    /// AudioFileLoader.loadMono(44100): the take kept for the refine passes (all channels mixed).
    let take44k: [Float]
    let fileSeconds: Double
    let firstChannelQuiet: Bool

    init(url: URL, start: Double, duration: Double?, need: Set<String>) throws {
        func trim(_ x: [Float], rate: Double) -> [Float] {
            let a = min(max(Int((start * rate).rounded()), 0), x.count)
            let b = duration.map { min(x.count, a + Int(($0 * rate).rounded())) } ?? x.count
            return Array(x[a..<max(a, b)])
        }
        firstChannelQuiet = try AudioFileLoader.firstChannelIsQuiet(url: url)
        let full44 = try AudioFileLoader.loadMono(url: url, sampleRate: PianoModel.sampleRate)
        fileSeconds = Double(full44.count) / PianoModel.sampleRate
        take44k = trim(full44, rate: PianoModel.sampleRate)
        pianoQuick22k = need.contains("quick") || need.contains("piano")
            ? trim(try AudioFileLoader.loadMono22k(url: url), rate: BPConstants.sampleRate) : []
        musicQuick22k = need.contains("quick-music") || need.contains("music")
            ? trim(try AudioFileLoader.loadMono(url: url, sampleRate: BPConstants.sampleRate, downmix: true), rate: BPConstants.sampleRate) : []
    }
}

nonisolated enum Velocity {
    /// MidiExport's mapping (Dynamics.detected / .activation).
    static func midi(_ amplitude: Double, detected: Bool) -> Int {
        let a = amplitude.isFinite ? amplitude : 0
        let v = detected ? (a * 127).rounded() : (a * 95).rounded(.towardZero) + 38
        return Int(min(max(v, 1), 127))
    }
}

func partName(_ v: Voice) -> String {
    switch v {
    case .none: "none"
    case .melody: "melody"
    case .chords: "chords"
    case .bass: "bass"
    case .countermelody: "countermelody"
    }
}

/// What the app derives from a note list once a take is final
/// (TranscriberViewModel.derive): melody, chords and the beat grid.
func derive(notes: [NoteEvent], duration: Double, settings: RunSettings, onsets: AudioOnsets? = nil,
            harmonyNotes: [NoteEvent] = [])
    -> (melody: [NoteEvent], chords: [ChordSegment], grid: BeatGrid) {
    let a = TakeAnalysis.derive(notes: notes, duration: duration,
                                rhythm: RhythmSettings(beatsPerMeasure: settings.beatsPerBar,
                                                       downbeatPitchClass: settings.downbeatPitchClass,
                                                       tempoOctave: settings.tempoOctave),
                                audioOnsets: onsets, harmonyNotes: harmonyNotes)
    return (a.melody, a.chords, a.grid)
}

/// Packs a pipeline's result, shifted onto the file's timeline.
func makePrediction(pipeline: String, audioPath: String, settings: RunSettings, duration: Double,
                    notes: [NoteEvent], sustain: [PedalEvent], detected: Bool,
                    info: [String: String], seconds: Double, onsets: AudioOnsets? = nil,
                    harmonyNotes: [NoteEvent] = []) -> (Prediction, midi: Data) {
    let d = derive(notes: notes, duration: duration, settings: settings, onsets: onsets, harmonyNotes: harmonyNotes)
    let o = settings.clipStart
    if evidenceSink != nil {
        evidenceSink?[pipeline] = Evidence(
            pipeline: pipeline, audio: audioPath, clipStart: o, duration: duration,
            notes: notes.map(EvidenceNote.init), harmonyNotes: harmonyNotes.map(EvidenceNote.init),
            sustain: sustain.map { PredSpan(start: $0.startTime + o, end: $0.endTime + o) }, detected: detected,
            onsets: onsets.map(EvidenceOnsets.init), info: info, seconds: seconds)
    }
    func shift(_ n: NoteEvent) -> NoteEvent {
        NoteEvent(startTime: n.startTime + o, endTime: n.endTime + o, pitch: n.pitch, amplitude: n.amplitude, voice: n.voice)
    }
    func pack(_ n: NoteEvent) -> PredNote {
        PredNote(start: n.startTime + o, end: n.endTime + o, pitch: n.pitch,
                 velocity: Velocity.midi(n.amplitude, detected: detected), amplitude: (n.amplitude * 10_000).rounded() / 10_000,
                 part: partName(n.voice))
    }
    let phase = phaseSections(notes: notes, duration: duration, settings: settings, onsets: onsets, grid: d.grid)?
        .map { s in PredPhaseSection(start: s.start + o, end: s.end + o, beats: s.beats, margin: (s.margin * 1000).rounded() / 1000,
                                     runnerUpShift: s.runnerUpShift, decoderAgrees: s.decoderAgrees) }
    let shiftedGrid = BeatGrid(beats: d.grid.beats.map { $0 + o }, downbeats: d.grid.downbeats.map { $0 + o },
                               beatsPerMeasure: d.grid.beatsPerMeasure, bpm: d.grid.bpm)
    let shiftedSustain = sustain.map { PedalEvent(startTime: $0.startTime + o, endTime: $0.endTime + o) }
    let shiftedChords = d.chords.map { ChordSegment(startTime: $0.startTime + o, endTime: $0.endTime + o, label: $0.label) }
    let midi = MidiExport.file(title: "\(URL(fileURLWithPath: audioPath).deletingPathExtension().lastPathComponent) (\(pipeline))",
                               notes: notes.map(shift), sustain: shiftedSustain, chords: shiftedChords,
                               grid: shiftedGrid, dynamics: detected ? .detected : .activation)
    let pred = Prediction(
        pipeline: pipeline, description: pipelineDescriptions[pipeline] ?? pipeline,
        audio: audioPath, clipStart: o, clipDuration: duration,
        split: notes.contains { $0.voice != .none },
        notes: notes.map(pack).sorted { ($0.start, $0.pitch) < ($1.start, $1.pitch) },
        leadLine: d.melody.map(pack),
        sustain: shiftedSustain.map { PredSpan(start: $0.startTime, end: $0.endTime) },
        drums: nil,
        beats: shiftedGrid.beats, downbeats: shiftedGrid.downbeats,
        beatsPerBar: shiftedGrid.beatsPerMeasure, bpm: shiftedGrid.bpm,
        chords: shiftedChords.map { PredChord(start: $0.startTime, end: $0.endTime, label: $0.label) },
        info: info, seconds: (seconds * 100).rounded() / 100, barPhase: phase)
    return (pred, midi)
}

/// The bar-phase margins of a grid (`BarPhase.sections`), for takes with the
/// audio's chroma (Song mode): each section's evidence for the bar lines shown
/// against their best shift, and whether the bar-pointer model alone agreed.
func phaseSections(notes: [NoteEvent], duration: Double, settings: RunSettings, onsets: AudioOnsets?,
                   grid: BeatGrid) -> [(start: Double, end: Double, beats: Int, margin: Double, runnerUpShift: Int,
                                       decoderAgrees: Bool)]? {
    guard let chroma = onsets?.chroma, !chroma.isEmpty, grid.beats.count >= 2 * grid.beatsPerMeasure,
          let ev = BarPhase.evidence(beats: grid.beats, notes: notes, chroma: chroma,
                                     downbeatPitchClass: settings.downbeatPitchClass) else { return nil }
    let n = max(grid.beatsPerMeasure, 1)
    let downs = Set(grid.downbeats)
    var positions = [Int](repeating: 0, count: grid.beats.count)
    let first = grid.beats.firstIndex { downs.contains($0) } ?? 0
    var p = 0
    for i in grid.beats.indices {
        if downs.contains(grid.beats[i]) { p = 0 } else if i > first { p += 1 }
        // A bar held longer than n beats keeps its last beats at n - 1.
        positions[i] = i < first ? ((i - first) % n + n) % n : min(p, n - 1)
    }
    // The bar-pointer model's own bar lines on the same beats (the grid's beats are its beats).
    let decoded = BeatTracker.track(notes: notes, duration: duration, beatsPerBar: settings.beatsPerBar,
                                    downbeatPitchClass: settings.downbeatPitchClass, tempoOctave: settings.tempoOctave,
                                    audioOnsets: onsets, barPhase: false)
    let sameBeats = decoded.beats == grid.beats
    return BarPhase.sections(evidence: ev, positions: positions, beatsPerBar: n).map { s in
        let agrees = sameBeats && (s.firstBeat...s.lastBeat).allSatisfy { (decoded.barPositions[$0] == 0) == (positions[$0] == 0) }
        return (grid.beats[s.firstBeat], grid.beats[s.lastBeat], s.lastBeat - s.firstBeat + 1, s.margin, s.runnerUpShift, agrees)
    }
}

func configString(_ c: NoteExtraction.Config) -> String {
    String(format: "onset %.2f frame %.2f min %.0f ms octaveLeak %@", c.onsetThreshold, c.frameThreshold,
           c.minNoteLengthMs, c.suppressOctaveLeak ? "on" : "off")
}

/// The app's refine pipeline with models loaded from disk.
func takePipeline(files: ModelFiles, bpModel: BasicPitchModel, settings: RunSettings) throws -> TakePipeline {
    let modelURL = try files.compiled("TranskunBackbone"), weights = files.pianoWeights, units = settings.pianoUnits
    return TakePipeline(basicPitch: BasicPitchNoteEngine(model: { bpModel }),
                        transkun: TranskunNoteEngine(transcriber: {
                            try PianoTranscriber(modelURL: modelURL, weightsURL: weights, computeUnits: units)
                        }))
}

/// Runs the requested pipelines. Returns predictions and their MIDI files.
func runPipelines(audioPath: String, settings: RunSettings) throws -> [(Prediction, Data)] {
    let url = URL(fileURLWithPath: audioPath)
    let files = ModelFiles()
    let need = Set(settings.pipelines)
    let t0 = Date()
    let audio = try TakeAudio(url: url, start: settings.clipStart, duration: settings.clipDuration, need: need)
    log(String(format: "loaded %@ (%.1f s file, clip %.1f s from %.1f s) in %.1f s", url.lastPathComponent,
               audio.fileSeconds, Double(audio.take44k.count) / PianoModel.sampleRate, settings.clipStart,
               Date().timeIntervalSince(t0)))
    guard !audio.take44k.isEmpty else { throw RBError("the clip is empty (check --start / --duration)") }
    let bpModel = try BasicPitchModel(modelURL: try files.compiled("NMP"))
    let snapshot = DetectionSnapshot(mode: settings.detection, customMinNoteLengthMs: CustomPad.defaultMinNoteLengthMs,
                                     customFrameThreshold: CustomPad.defaultFrameThreshold)
    var out: [(Prediction, Data)] = []

    // Piano mode's quick engine also sets the take duration in Piano mode.
    var pianoEngine: TranscriptionEngine?
    func pianoQuickEngine() throws -> TranscriptionEngine {
        if let e = pianoEngine { return e }
        let e = TranscriptionEngine(model: bpModel)
        try e.append(audio.pianoQuick22k)
        try e.finalize()
        pianoEngine = e
        return e
    }

    for pipeline in settings.pipelines {
        let started = Date()
        var info: [String: String] = ["firstChannelQuiet": String(audio.firstChannelQuiet)]
        switch pipeline {
        case "quick":
            let engine = try pianoQuickEngine()
            let config = settings.detection.resolved(snapshot: snapshot, stats: engine.stats(), for: .piano)
            let notes = engine.extractNotes(config: config)
            info["input"] = audio.firstChannelQuiet ? "all channels mixed (first channel quiet)" : "first channel"
            info["detection"] = settings.detection.rawValue
            info["config"] = configString(config)
            info["sustainedPolyphony"] = String(format: "%.2f", engine.stats().sustainedPolyphony)
            out.append(makePrediction(pipeline: pipeline, audioPath: audioPath, settings: settings, duration: engine.duration,
                                      notes: notes, sustain: [], detected: false, info: info,
                                      seconds: Date().timeIntervalSince(started)))
        case "quick-music":
            let engine = TranscriptionEngine(model: bpModel)
            try engine.append(audio.musicQuick22k)
            try engine.finalize()
            let config = settings.detection.resolved(snapshot: snapshot, stats: engine.stats(), for: .music)
            let notes = VoiceSplitter.assign(engine.extractNotes(config: config))
            info["input"] = "all channels mixed"
            info["detection"] = settings.detection.rawValue
            info["config"] = configString(config)
            info["sustainedPolyphony"] = String(format: "%.2f", engine.stats().sustainedPolyphony)
            out.append(makePrediction(pipeline: pipeline, audioPath: audioPath, settings: settings, duration: engine.duration,
                                      notes: notes, sustain: [], detected: false, info: info,
                                      seconds: Date().timeIntervalSince(started)))
        case "piano":
            let duration = try pianoQuickEngine().duration
            let quickEngine = try pianoQuickEngine()
            let quickNotes = quickEngine.extractNotes(config: settings.detection.resolved(
                snapshot: snapshot, stats: quickEngine.stats(), for: .piano))
            guard let output = try takePipeline(files: files, bpModel: bpModel, settings: settings).refine(
                RefineInput(mode: .piano, take44k: audio.take44k, quickNotes: quickNotes)) else {
                throw RBError("piano pass cancelled")
            }
            info["computeUnits"] = String(settings.pianoUnits.rawValue)
            info["summary"] = output.info["summary"]
            info["verdict"] = "\(output.verdict)"
            info["transkunNotes"] = String(output.notes.count)
            // What the app shows: the quick notes when the arbiter rejects the piano model.
            let shown = output.verdict == .accept
            info["appShows"] = shown ? "piano model" : "quick notes"
            out.append(makePrediction(pipeline: pipeline, audioPath: audioPath, settings: settings, duration: duration,
                                      notes: shown ? output.notes : quickNotes, sustain: shown ? output.sustain : [],
                                      detected: shown, info: info,
                                      seconds: Date().timeIntervalSince(started), onsets: shown ? output.onsetEnvelope : nil))
        case "music":
            // Duration as the app sets it: the Any-instrument quick engine's (22050 Hz mix).
            let duration = Double(audio.musicQuick22k.count) / BPConstants.sampleRate
            let quick = TranscriptionEngine(model: bpModel)
            try quick.append(audio.musicQuick22k)
            try quick.finalize()
            let quickNotes = quick.extractNotes(config: settings.detection.resolved(snapshot: snapshot, stats: quick.stats(), for: .music))
            guard let output = try takePipeline(files: files, bpModel: bpModel, settings: settings).refine(
                RefineInput(mode: .music, take44k: audio.take44k, quickNotes: quickNotes)) else {
                throw RBError("music pass cancelled")
            }
            let elapsed = Date().timeIntervalSince(started)
            for (k, v) in output.info where k != "summary" { info[k] = v }
            info["engine"] = output.engine.rawValue
            out.append(makePrediction(pipeline: pipeline, audioPath: audioPath, settings: settings, duration: duration,
                                      notes: output.notes, sustain: [],
                                      detected: output.engine == .transkun, info: info, seconds: elapsed,
                                      onsets: output.onsetEnvelope, harmonyNotes: output.harmonyNotes))
        default:
            throw RBError("unknown pipeline \(pipeline) (known: \(allPipelines.joined(separator: ", ")))")
        }
        let p = out.last!.0
        log(String(format: "  %-11@ %5d notes  %.1f s", pipeline, p.notes.count, Date().timeIntervalSince(started)))
    }
    return out
}
