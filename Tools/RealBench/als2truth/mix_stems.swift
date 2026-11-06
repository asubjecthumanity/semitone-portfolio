// mix_stems: sum audio stems (any format AVFoundation reads, same sample rate) into one WAV,
// peak-normalised to -1 dBFS. Stems are summed at unity gain, as Live's mixer would.
//
//   swift mix_stems.swift OUT.wav STEM...
import AVFoundation
import Foundation

let a = Array(CommandLine.arguments.dropFirst())
guard a.count >= 2 else { print("usage: mix_stems OUT.wav STEM..."); exit(1) }
var mix: [[Float]] = [[], []]
var rate = 0.0
for path in a.dropFirst() {
    let f = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let fmt = f.processingFormat
    if rate == 0 { rate = fmt.sampleRate } else if rate != fmt.sampleRate { print("sample rate differs: \(path)"); exit(1) }
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(f.length))!
    try f.read(into: buf)
    let n = Int(buf.frameLength)
    for c in 0..<2 {
        if mix[c].count < n { mix[c] += [Float](repeating: 0, count: n - mix[c].count) }
        let src = buf.floatChannelData![min(c, Int(fmt.channelCount) - 1)]
        for i in 0..<n { mix[c][i] += src[i] }
    }
}
let peak = mix.flatMap { $0 }.reduce(Float(0)) { max($0, abs($1)) }
let g = peak > 0 ? 0.89 / peak : 1
let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(mix[0].count))!
out.frameLength = AVAudioFrameCount(mix[0].count)
for c in 0..<2 { for i in 0..<mix[c].count { out.floatChannelData![c][i] = mix[c][i] * g } }
let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                               AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
do {   // the file finishes its header when it is released, so keep it local
    let file = try AVAudioFile(forWriting: URL(fileURLWithPath: a[0]), settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: out)
}
print("wrote \(a[0]): \(a.count - 1) stems, \(String(format: "%.1f", Double(mix[0].count) / rate)) s, gain \(String(format: "%.2f", g))")
