import Foundation
@preconcurrency import AVFoundation

var checks = 0
var failures: [String] = []
func expect(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { failures.append(message) }
}
func expectError(_ message: String, _ body: () throws -> Void) {
    do { try body(); expect(false, message) }
    catch { expect(true, message) }
}

let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                          channels: 1, interleaved: false)!
let readFailure = NSError(domain: "InjectedAudioRead", code: 17)
var reads = 0
do {
    _ = try AudioFileLoader.convertMono(from: format, to: 22_050) { buffer in
        reads += 1
        if reads == 2 { throw readFailure }
        buffer.floatChannelData![0].initialize(repeating: 0.25, count: Int(buffer.frameCapacity))
        buffer.frameLength = buffer.frameCapacity
    }
    expect(false, "A late read failure returned a successful audio prefix")
} catch {
    expect((error as NSError).domain == readFailure.domain && (error as NSError).code == readFailure.code,
           "The converter lost the original read error")
}
expect(reads == 2, "The fault injection did not exercise a read after real audio")
let empty = try AudioFileLoader.convertMono(from: format, to: 22_050) { $0.frameLength = 0 }
expect(empty.isEmpty, "A legitimate empty stream was treated as an error/nonempty stream")
expectError("An error status without NSError was accepted") {
    try AudioFileLoader.checkConversion(.error, error: nil)
}
do {
    try AudioFileLoader.checkConversion(.inputRanDry, error: readFailure)
    expect(false, "A supplied converter NSError was ignored")
} catch {
    expect((error as NSError).domain == readFailure.domain, "A converter NSError was replaced")
}
try AudioFileLoader.checkConversion(.inputRanDry, error: nil)
try AudioFileLoader.checkConversion(.endOfStream, error: nil)
for rate in [0.0, -1.0, Double.nan, Double.infinity] {
    expectError("Accepted an invalid input rate") { _ = try AudioFileLoader.resampleMono([0.1], from: rate, to: 22_050) }
    expectError("Accepted an invalid output rate") { _ = try AudioFileLoader.resampleMono([0.1], from: 44_100, to: rate) }
}
let identity: [Float] = [0, 0.3, -0.2, 0]
expect(try AudioFileLoader.resampleMono(identity, from: 44_100, to: 44_100) == identity,
       "Same-rate conversion changed samples")
let sine = (0..<132_300).map { Float(sin(Double($0) * 2 * .pi * 440 / 44_100)) }
let resampled = try AudioFileLoader.resampleMono(sine, from: 44_100, to: 22_050)
expect(abs(resampled.count - 66_150) <= 256, "Resampling silently truncated a multi-chunk stream")
expect(resampled.contains { abs($0) > 0.1 }, "Resampling returned silence for a sine wave")
let corrupt = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
try Data("not an audio file".utf8).write(to: corrupt)
defer { try? FileManager.default.removeItem(at: corrupt) }
expectError("Corrupt input was accepted") { _ = try AudioFileLoader.loadMono(url: corrupt, sampleRate: 22_050) }
expectError("Corrupt input passed channel analysis") { _ = try AudioFileLoader.firstChannelIsQuiet(url: corrupt) }

// Real files must read to the end: AVAudioFile fails a read at the end of a
// file (eofErr -39 on macOS, an error without an NSError on iOS) instead of
// returning nothing, which must not fail the import. Mono and stereo; shorter
// than, exactly, just over and well over the loader's 65536-frame buffer.
for channels: AVAudioChannelCount in [1, 2] {
    for frames: AVAudioFrameCount in [1, 11_025, 65_536, 65_537, 100_003] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let fileFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                       channels: channels, interleaved: false)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: fileFormat.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: frames)!
            buffer.frameLength = frames
            for c in 0..<Int(channels) {
                for i in 0..<Int(frames) { buffer.floatChannelData![c][i] = Float(sin(Double(i) * 0.06)) * 0.5 }
            }
            try file.write(from: buffer)
        }
        do {
            let samples = try AudioFileLoader.loadMono(url: url, sampleRate: 44_100)
            expect(samples.count == Int(frames), "A \(frames)-frame \(channels)-channel WAV lost samples (\(samples.count))")
            _ = try AudioFileLoader.loadMono22k(url: url)
            _ = try AudioFileLoader.firstChannelIsQuiet(url: url)
        } catch {
            expect(false, "A valid \(frames)-frame \(channels)-channel WAV failed to load: \(error)")
        }
    }
}

// A saved take: AAC .m4a written like TakeLibrary.writeAudio, read back like
// openSavedTake. Cutting the file short must throw, not return a prefix.
do {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
    let cut = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
    defer { for file in [url, cut] { try? FileManager.default.removeItem(at: file) } }
    let frames = 441_000
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                                   AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000]
    do {
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        for i in 0..<frames { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.05)) * 0.4 }
        buffer.frameLength = AVAudioFrameCount(frames)
        try file.write(from: buffer)
    }
    let samples = try AudioFileLoader.loadMono(url: url, sampleRate: 44_100)
    expect(abs(samples.count - frames) <= 2, "A saved-take .m4a lost samples (\(samples.count) of \(frames))")
    expect(samples.contains { abs($0) > 0.2 }, "A saved-take .m4a read back as silence")
    let data = try Data(contentsOf: url)
    try data.prefix(data.count * 6 / 10).write(to: cut)
    expectError("A truncated .m4a returned a prefix") { _ = try AudioFileLoader.loadMono(url: cut, sampleRate: 22_050) }
} catch {
    expect(false, "The saved-take .m4a round trip failed: \(error)")
}

if failures.isEmpty { print("All \(checks) audio error/resampling checks passed.") }
else { for failure in failures { print("FAIL: \(failure)") }; exit(1) }
