import Foundation
// usage: harness <audio> <model.mlmodelc> <weights.bin> <out-prefix>
let a = CommandLine.arguments
let samples = try AudioFileLoader.loadMono(url: URL(fileURLWithPath: a[1]), sampleRate: 44100)
let prefix = a[4]
try samples.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: URL(fileURLWithPath: prefix + "_samples.f32"))
let weights = try PianoWeights(url: URL(fileURLWithPath: a[3]))
if let segEnv = ProcessInfo.processInfo.environment["DUMP_SEGMENT"], let k = Int(segEnv) {
    // features of segment k exactly as the transcriber builds it
    let m = PianoModel.self; let i = k * m.stepSamples
    var seg = [Float](repeating: 0, count: m.segmentSamples)
    for p in 0..<m.segmentSamples { let g = i + p - m.padSamples; if g >= 0 && g < samples.count { seg[p] = samples[g] } }
    var out = [Float](repeating: 0, count: m.frames * m.mels * m.windowCount)
    let fx = PianoFeatureExtractor(weights: weights)
    seg.withUnsafeBufferPointer { s in out.withUnsafeMutableBufferPointer { fx.features(segment: s, into: $0.baseAddress!) } }
    try out.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: URL(fileURLWithPath: prefix + "_feat\(k).f32"))
}
let t0 = Date()
let tr = try PianoTranscriber(modelURL: URL(fileURLWithPath: a[2]), weightsURL: URL(fileURLWithPath: a[3]))
let result = try tr.transcribe(samples: samples)!
let notes = result.notes
try result.sustain.map { "\($0.startTime),\($0.endTime)" }.joined(separator: "\n")
    .write(toFile: prefix + "_sustain.csv", atomically: true, encoding: .utf8)
let dt = Date().timeIntervalSince(t0)
var csv = ""
for n in notes { csv += "\(n.startTime),\(n.endTime),\(n.pitch),\(Int((n.amplitude * 127).rounded()))\n" }
try csv.write(toFile: prefix + "_swift.csv", atomically: true, encoding: .utf8)
FileHandle.standardError.write("\(notes.count) notes, \(String(format: "%.1f", dt)) s for \(String(format: "%.1f", Double(samples.count) / 44100)) s of audio\n".data(using: .utf8)!)
