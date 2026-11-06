import Foundation
// usage: trackcli <notes.csv> <beatsPerBar|0=auto> <duration> [octave] [shift]
let a = CommandLine.arguments
let notes: [NoteEvent] = try String(contentsOfFile: a[1], encoding: .utf8).split(separator: "\n").compactMap { l in
    let f = l.split(separator: ",").compactMap { Double($0) }
    return f.count >= 3 ? NoteEvent(startTime: f[0], endTime: f[1], pitch: Int(f[2]), amplitude: f.count > 3 ? f[3] / 127 : 0.5) : nil
}
let bpb = Int(a[2])!
let t0 = Date()
let r = BeatTracker.track(notes: notes, duration: Double(a[3])!, beatsPerBar: bpb == 0 ? nil : bpb,
                          tempoOctave: a.count > 4 ? Int(a[4])! : 0, barShift: a.count > 5 ? Int(a[5])! : 0)
FileHandle.standardError.write("\(r.beats.count) beats, \(r.beatsPerBar)/bar, \(Int(r.medianBPM)) BPM, \(String(format: "%.2f", Date().timeIntervalSince(t0))) s\n".data(using: .utf8)!)
for (b, p) in zip(r.beats, r.barPositions) { print("B,\(b)"); if p == 0 { print("D,\(b)") } }
