// render_gm: render a realbench-truth-1 key's notes to audio with the General MIDI sounds that ship
// with macOS (gs_instruments.dls), one stem per instrument (Ableton track) plus a mix.
//
//   swift render_gm.swift truth.json OUTDIR [--trust-flagged] [--programs map.json] [--tail 2.5]
//
// The notes are rendered exactly as written, so the key is the truth for this audio. With
// --trust-flagged the key's unreliableNotes (raw notes of tracks behind MIDI effects) are rendered
// too, and OUTDIR/truth.json is the key with those notes moved into "notes".
// --programs: {"Track name": 38, ...} picks the GM program (0-127) for a track; otherwise it is
// chosen from the track's part and name.
import AVFoundation
import Foundation

struct Note { var on: Double; var off: Double; var pitch: Int; var velocity: Int; var part: String; var instrument: String }

func die(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }

var args = Array(CommandLine.arguments.dropFirst())
var trustFlagged = false
var programsPath: String?
var tail = 2.5
var positional: [String] = []
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--trust-flagged": trustFlagged = true
    case "--programs": programsPath = args.removeFirst()
    case "--tail": tail = Double(args.removeFirst()) ?? tail
    default: positional.append(a)
    }
}
guard positional.count == 2 else { die("usage: render_gm truth.json OUTDIR [--trust-flagged] [--programs map.json] [--tail S]") }
let truthURL = URL(fileURLWithPath: positional[0])
let outURL = URL(fileURLWithPath: positional[1])
try FileManager.default.createDirectory(at: outURL.appendingPathComponent("stems"), withIntermediateDirectories: true)

guard var truth = try JSONSerialization.jsonObject(with: Data(contentsOf: truthURL)) as? [String: Any] else { die("bad key") }
func notes(_ key: String) -> [Note] {
    ((truth[key] as? [[String: Any]]) ?? []).compactMap { d in
        guard let on = d["on"] as? Double, let off = d["off"] as? Double, let p = d["pitch"] as? Int else { return nil }
        return Note(on: on, off: off, pitch: p, velocity: (d["velocity"] as? Int) ?? 90,
                    part: (d["part"] as? String) ?? "other", instrument: (d["instrument"] as? String) ?? "track")
    }
}
var all = notes("notes")
if trustFlagged {
    all += notes("unreliableNotes")
    var moved = (truth["notes"] as? [[String: Any]]) ?? []
    for var d in (truth["unreliableNotes"] as? [[String: Any]]) ?? [] { d.removeValue(forKey: "flags"); moved.append(d) }
    moved.sort { ($0["on"] as! Double) < ($1["on"] as! Double) }
    // A flagged track doubling a keyed one (same pitch, onsets within 50 ms) is heard as one note,
    // as als2truth merges unisons within each list.
    var merged: [[String: Any]] = []
    for d in moved {
        let on = d["on"] as! Double, p = d["pitch"] as! Int
        if let i = merged.lastIndex(where: { on - ($0["on"] as! Double) <= 0.05 && ($0["pitch"] as! Int) == p }) {
            merged[i]["off"] = max(merged[i]["off"] as! Double, d["off"] as! Double)
            merged[i]["instrument"] = "\(merged[i]["instrument"] ?? "") + \(d["instrument"] ?? "")"
        } else {
            merged.append(d)
        }
    }
    truth["notes"] = merged
    truth.removeValue(forKey: "unreliableNotes")
}
var programs: [String: Int] = [:]
if let p = programsPath { programs = (try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: p))) as? [String: Int]) ?? [:] }

// GM programs (0-based) by part and track name.
func program(for track: String, part: String) -> Int {
    if let p = programs[track] { return p }
    let n = track.lowercased()
    func has(_ words: String...) -> Bool { words.contains { n.contains($0) } }
    switch part {
    case "bass": return has("sub", "808") ? 38 : has("reese", "short", "synth") ? 39 : 33
    case "melody": return has("flute") ? 73 : has("string") ? 40 : 81
    case "countermelody": return has("string") ? 48 : has("bell") ? 10 : has("sample", "synth") ? 80 : 73
    default:
        if has("guit", "strum") { return has("strum") ? 24 : 27 }
        if has("brass", "horn") { return 61 }
        if has("string") { return 48 }
        if has("bell", "toy", "music box") { return has("toy") ? 10 : 14 }
        if has("pad", "vacuum", "mello", "star") { return 89 }
        if has("key", "leaf", "rhodes", "ep") { return 4 }
        if has("organ") { return 16 }
        return 0
    }
}

let sampleRate = 44100.0
let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
let dls = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")
let end = (all.map(\.off).max() ?? 0) + tail
let totalFrames = AVAudioFramePosition(end * sampleRate)

func render(_ track: [Note], program: Int) throws -> AVAudioPCMBuffer {
    let engine = AVAudioEngine()
    let sampler = AVAudioUnitSampler()
    engine.attach(sampler)
    engine.connect(sampler, to: engine.mainMixerNode, format: format)
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
    try sampler.loadSoundBankInstrument(at: dls, program: UInt8(program),
                                        bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB), bankLSB: 0)
    try engine.start()
    // Events in frames; offs sort before ons at the same frame. A re-struck pitch stops the old note,
    // and an older note's off never cuts a newer one.
    struct Ev { var frame: AVAudioFramePosition; var on: Bool; var pitch: Int; var vel: Int; var id: Int }
    var evs: [Ev] = []
    for (i, n) in track.enumerated() {
        let a = AVAudioFramePosition(n.on * sampleRate), b = max(a + 64, AVAudioFramePosition(n.off * sampleRate))
        evs.append(Ev(frame: a, on: true, pitch: n.pitch, vel: max(1, min(127, n.velocity)), id: i))
        evs.append(Ev(frame: b, on: false, pitch: n.pitch, vel: 0, id: i))
    }
    evs.sort { $0.frame != $1.frame ? $0.frame < $1.frame : (!$0.on && $1.on) }
    var latest: [Int: Int] = [:]
    let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames))!
    let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64)!
    var pos: AVAudioFramePosition = 0, k = 0
    while pos < totalFrames {
        while k < evs.count && evs[k].frame < pos + 64 {
            let e = evs[k]; k += 1
            if e.on {
                if latest[e.pitch] != nil { sampler.stopNote(UInt8(e.pitch), onChannel: 0) }
                sampler.startNote(UInt8(e.pitch), withVelocity: UInt8(e.vel), onChannel: 0)
                latest[e.pitch] = e.id
            } else if latest[e.pitch] == e.id {
                sampler.stopNote(UInt8(e.pitch), onChannel: 0)
                latest[e.pitch] = nil
            }
        }
        let n = AVAudioFrameCount(min(64, totalFrames - pos))
        let status = try engine.renderOffline(n, to: chunk)
        guard status == .success else { die("render status \(status.rawValue)") }
        for c in 0..<2 {
            let src = chunk.floatChannelData![c], dst = out.floatChannelData![c] + Int(pos)
            for i in 0..<Int(chunk.frameLength) { dst[i] = src[i] }
        }
        pos += AVAudioFramePosition(chunk.frameLength)
    }
    out.frameLength = AVAudioFrameCount(totalFrames)
    engine.stop()
    return out
}

func write(_ buf: AVAudioPCMBuffer, to url: URL, gain: Float = 1) throws {
    if gain != 1 { for c in 0..<2 { let p = buf.floatChannelData![c]; for i in 0..<Int(buf.frameLength) { p[i] *= gain } } }
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
                                   AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
    let f = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    try f.write(from: buf)
}

// Each stem is levelled to a loudness for its part (RMS over the windows where it sounds), so a
// track written at velocity 30 is not buried and a dense strum does not cover the rest.
let partLevel: [String: Float] = ["bass": -16, "melody": -16, "countermelody": -20, "chords": -23]
func activeRMS(_ buf: AVAudioPCMBuffer) -> Float {
    var acc = 0.0, n = 0
    let w = 2048
    for start in stride(from: 0, to: Int(buf.frameLength) - w, by: w) {
        var s = 0.0
        for c in 0..<2 { let p = buf.floatChannelData![c] + start; for i in 0..<w { s += Double(p[i] * p[i]) } }
        if s / Double(2 * w) > 1e-6 { acc += s; n += 2 * w }   // windows above -60 dB
    }
    return n > 0 ? Float((acc / Double(n)).squareRoot()) : 0
}
// A merged unison ("Sub + Mid") plays once, on its first layer's track.
let tracks = Dictionary(grouping: all) { $0.instrument.components(separatedBy: " + ")[0] }.sorted { $0.key < $1.key }
let mix = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames))!
mix.frameLength = AVAudioFrameCount(totalFrames)
for c in 0..<2 { memset(mix.floatChannelData![c], 0, Int(totalFrames) * 4) }
var used: [String: Any] = [:]
for (name, track) in tracks {
    let part = track[0].part
    let prog = program(for: name, part: part)
    let buf = try render(track, program: prog)
    let rms = activeRMS(buf)
    let g = rms > 0 ? min(20, max(0.05, powf(10, (partLevel[part] ?? -23) / 20) / rms)) : 1
    for c in 0..<2 { let s = buf.floatChannelData![c], m = mix.floatChannelData![c]; for i in 0..<Int(totalFrames) { m[i] += s[i] * g } }
    try write(buf, to: outURL.appendingPathComponent("stems/\(name.replacingOccurrences(of: "/", with: "-")).wav"))
    used[name] = ["program": prog, "part": part, "notes": track.count, "gain": g]
    print("\(name): \(part), GM program \(prog), \(track.count) notes")
}
var peak: Float = 0
for c in 0..<2 { let m = mix.floatChannelData![c]; for i in 0..<Int(totalFrames) { peak = max(peak, abs(m[i])) } }
let norm = peak > 0 ? 0.89 / peak : 1   // -1 dBFS
try write(mix, to: outURL.appendingPathComponent("mix.wav"), gain: norm)
truth["notesComplete"] = true   // every rendered note is in the key
truth["source"] = ((truth["source"] as? String) ?? "") + "; rendered with the macOS General MIDI bank (render_gm)" + (trustFlagged ? ", flagged tracks' raw notes included" : "")
truth["render"] = ["tool": "render_gm", "bank": "gs_instruments.dls", "tracks": used, "mixGain": norm]
let data = try JSONSerialization.data(withJSONObject: truth, options: [.prettyPrinted, .sortedKeys])
try data.write(to: outURL.appendingPathComponent("truth.json"))
print("wrote \(outURL.path)/mix.wav (\(String(format: "%.1f", end)) s) and truth.json")
