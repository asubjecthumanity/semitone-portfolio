import Foundation
import CoreML

// Headless raw refined-piano or fixed piano-preset quick output. Calls the
// checked-out app code; capture/auto preset/AI/fallback/export are separate.
// audio model weights output [ane|cpu|default] [offset-semantics] [transkun|basic-pitch]
do {
    let args = CommandLine.arguments
    guard args.count >= 5 && args.count <= 8 else {
        throw NSError(domain: "PianoBench", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "usage: pianobench-native audio model weights output [ane|cpu|default] [key_release|pedal_extended|unspecified] [transkun|basic-pitch]"])
    }
    let engineName = args.count > 7 ? args[7] : "transkun"
    let quick = engineName == "basic-pitch"
    let compute = args.count > 5 ? args[5] : (quick ? "default" : "ane")
    let semantics = args.count > 6 ? args[6] : "unspecified"
    guard ["transkun", "basic-pitch"].contains(engineName),
          (quick ? compute == "default" : ["ane", "cpu"].contains(compute)),
          ["key_release", "pedal_extended", "unspecified"].contains(semantics) else {
        throw NSError(domain: "PianoBench", code: 2, userInfo: [NSLocalizedDescriptionKey: "invalid engine/compute/offset semantics"])
    }
    let t0 = Date()
    let rate = quick ? BPConstants.sampleRate : PianoModel.sampleRate
    let samples = try AudioFileLoader.loadMono(url: URL(fileURLWithPath: args[1]), sampleRate: rate)
    let loaded = Date()
    guard !samples.isEmpty else {
        throw NSError(domain: "PianoBench", code: 3, userInfo: [NSLocalizedDescriptionKey: "audio is empty"])
    }
    let duration = Double(samples.count) / rate
    let ready: Date
    let notes: [[String: Any]]
    let pedals: [[String: Any]]
    var stage: [String: Any]
    if quick {
        let model = try BasicPitchModel(modelURL: URL(fileURLWithPath: args[2]))
        let engine = TranscriptionEngine(model: model)
        ready = Date()
        try engine.append(samples)
        try engine.finalize()
        let config = NoteExtraction.Config()
        notes = engine.extractNotes(config: config).filter {
            $0.startTime >= 0 && $0.startTime < duration && min($0.endTime, duration) > $0.startTime
        }.map {
            ["onset": $0.startTime, "offset": min($0.endTime, duration), "pitch": $0.pitch,
             "activation": $0.amplitude, "channel": 0]
        }
        pedals = []
        stage = ["engine": "semitone-swift-basic-pitch-quick", "compute": "CoreML default",
                 "velocity_semantics": "activation", "detection_preset": "piano",
                 "config": ["onsetThreshold": config.onsetThreshold, "frameThreshold": config.frameThreshold,
                            "minNoteLengthMs": config.minNoteLengthMs, "inferOnsets": config.inferOnsets,
                            "melodiaTrick": config.melodiaTrick, "energyTolerance": config.energyTolerance,
                            "suppressOctaveLeak": config.suppressOctaveLeak],
                 "scope": "Fixed piano-preset quick output; auto preset/capture/AI/fallback/export not invoked"]
    } else {
        let tr = try PianoTranscriber(modelURL: URL(fileURLWithPath: args[2]),
                                     weightsURL: URL(fileURLWithPath: args[3]),
                                     computeUnits: compute == "cpu" ? .cpuOnly : .cpuAndNeuralEngine)
        ready = Date()
        guard let result = try tr.transcribe(samples: samples) else {
            throw NSError(domain: "PianoBench", code: 4, userInfo: [NSLocalizedDescriptionKey: "transcription cancelled"])
        }
        notes = result.notes.map {
            ["onset": $0.startTime, "offset": $0.endTime, "pitch": $0.pitch,
             "velocity": Int(($0.amplitude * 127).rounded()), "channel": 0]
        }
        pedals = result.sustain.map {
            ["onset": $0.startTime, "offset": $0.endTime, "controller": 64, "channel": 0]
        }
        stage = ["engine": "semitone-swift-transkun-refined", "compute": compute,
                 "velocity_semantics": "midi_velocity",
                 "looks_valid": PianoTranscriber.looksValid(result.notes, seconds: duration),
                 "scope": "Raw native PianoTranscriber output; app fallback/capture/AI/export not invoked"]
    }
    let finished = Date()
    stage.merge(["sample_rate": rate, "channel_policy": "AudioFileLoader.loadMono",
                 "audio_load_seconds": loaded.timeIntervalSince(t0), "model_load_seconds": ready.timeIntervalSince(loaded),
                 "inference_seconds": finished.timeIntervalSince(ready), "total_seconds": finished.timeIntervalSince(t0),
                 "platform": ProcessInfo.processInfo.operatingSystemVersionString]) { _, new in new }
    let output: [String: Any] = ["schema_version": 1, "duration_seconds": duration, "offset_semantics": semantics,
                               "notes": notes, "pedals": pedals, "pedal_controllers": quick ? [] : [64], "metadata": stage]
    let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: args[4]), options: .atomic)
    FileHandle.standardError.write(Data("\(engineName): \(notes.count) notes; \(duration)s audio\n".utf8))
} catch {
    FileHandle.standardError.write(Data("PianoBench: \(error.localizedDescription)\n".utf8))
    exit(2)
}
