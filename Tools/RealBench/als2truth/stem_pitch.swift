// stem_pitch: check a key's pitches against the isolated stems Live exported, one per track.
// Sample-based instruments sound relative to their sample's root key and layered patches can sit
// an octave off, which the set file does not say. For every instrument in the key this measures,
// summed over its notes (the first 300 ms after onset), the stem's energy at the key's pitch shifted
// by -36...+36 semitones and suggests the shift where the fundamental is: the strongest shift, moved
// down to a fundamental below it (an octave, an octave and a fifth or two octaves: the 2nd, 3rd or
// 4th harmonic was strongest) while that still holds at least 40% of it. Chord tracks that double
// notes in octaves blur this; trust it most on single lines.
//
//   swift stem_pitch.swift truth.json STEMDIR
//
// STEMDIR holds "<track name>.aif" or ".wav" (Live's "All Individual Tracks" export, with the set
// name prefix removed). Apply a confirmed shift as "addTranspose" in roles.json and re-run
// als2truth. A high-passed layer (no fundamental) reports its 2nd harmonic: keep the written pitch.
import AVFoundation
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else { print("usage: stem_pitch truth.json STEMDIR"); exit(1) }
let truth = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1]))) as! [String: Any]
let all = ((truth["notes"] as? [[String: Any]]) ?? []) + ((truth["unreliableNotes"] as? [[String: Any]]) ?? [])
var byTrack: [String: [(on: Double, off: Double, pitch: Int)]] = [:]
for n in all {
    // merged unisons name every layer ("A + B"): check each layer's stem
    for name in (n["instrument"] as? String ?? "?").components(separatedBy: " + ") {
        byTrack[name, default: []].append((n["on"] as! Double, n["off"] as! Double, n["pitch"] as! Int))
    }
}
for (track, notes) in byTrack.sorted(by: { $0.key < $1.key }) {
    let base = URL(fileURLWithPath: args[2]).appendingPathComponent(track)
    guard let url = ["aif", "aiff", "wav"].map({ base.appendingPathExtension($0) })
        .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
        print("\(track): no stem"); continue
    }
    let f = try AVAudioFile(forReading: url)
    let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
    try f.read(into: buf)
    let x = buf.floatChannelData![0], sr = f.processingFormat.sampleRate, n = Int(buf.frameLength)
    func goertzel(_ s: Int, _ e: Int, _ hz: Double) -> Double {
        let c = 2 * cos(2 * Double.pi * hz / sr)
        var s1 = 0.0, s2 = 0.0
        for i in s..<e { let v = Double(x[i]) + c * s1 - s2; s2 = s1; s1 = v }
        return (s1 * s1 + s2 * s2 - c * s1 * s2) / Double(e - s)
    }
    var energy: [Int: Double] = [:]
    for nt in notes {
        let s = Int((nt.on + 0.02) * sr), e = min(n, Int(min(nt.off, nt.on + 0.3) * sr))
        guard e - s >= 2000 else { continue }
        for sh in -36...36 {
            let hz = 440 * pow(2, Double(nt.pitch + sh - 69) / 12)
            if hz > 20, hz < sr / 2 { energy[sh, default: 0] += goertzel(s, e, hz) }
        }
    }
    guard let peak = energy.values.max(), peak > 0 else { print("\(track): silent"); continue }
    var best = energy.max { $0.value < $1.value }!.key
    while let f0 = [12, 19, 24].map({ best - $0 }).first(where: { (energy[$0] ?? 0) >= 0.4 * energy[best]! }) { best = f0 }
    let top = energy.sorted { $0.value > $1.value }.prefix(4).map { "\($0.key >= 0 ? "+" : "")\($0.key) \(String(format: "%.2f", $0.value / peak))" }
    print("\(track): \(notes.count) notes, suggested shift \(best >= 0 ? "+" : "")\(best)  (strongest: \(top.joined(separator: ", ")))")
}
