#if DEBUG
import Foundation
import AVFoundation

/// Debug-only tuning aid: saves every take to Documents/Takes/<time>/ so the
/// live detector can be tuned offline against the piano model's notes.
///   audio22k.wav  exactly what the live detector heard (mic takes only)
///   live.csv      the quick detector's notes (start,end,pitch,velocity)
///   piano.csv     the piano model's notes, once its pass finishes
///   info.txt      source, duration and detector settings
nonisolated enum TakeCapture {
    /// Returns the take's folder, or nil if it couldn't be created.
    static func save(
        audio22k: ArraySlice<Float>,
        liveNotes: [NoteEvent],
        config: NoteExtraction.Config,
        mode: DetectionMode,
        source: String,
        duration: Double
    ) -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let folder = URL.documentsDirectory.appending(path: "Takes/\(formatter.string(from: Date()))")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if source == "mic" {
                try writeWAV(audio22k, sampleRate: BPConstants.sampleRate, to: folder.appending(path: "audio22k.wav"))
            }
            try csv(liveNotes).write(to: folder.appending(path: "live.csv"), atomically: true, encoding: .utf8)
            let info = """
                source: \(source)
                duration: \(String(format: "%.2f", duration)) s
                mode: \(mode.rawValue)
                onsetThreshold: \(config.onsetThreshold)
                frameThreshold: \(config.frameThreshold)
                minNoteLengthMs: \(config.minNoteLengthMs)
                inferOnsets: \(config.inferOnsets)
                melodiaTrick: \(config.melodiaTrick)
                energyTolerance: \(config.energyTolerance)
                suppressOctaveLeak: \(config.suppressOctaveLeak)

                """
            try info.write(to: folder.appending(path: "info.txt"), atomically: true, encoding: .utf8)
            return folder
        } catch {
            NSLog("Semitone: couldn't save take for tuning: %@", error.localizedDescription)
            return nil
        }
    }

    static func savePiano(_ notes: [NoteEvent], summary: String, in folder: URL) {
        try? csv(notes).write(to: folder.appending(path: "piano.csv"), atomically: true, encoding: .utf8)
        try? summary.write(to: folder.appending(path: "piano.txt"), atomically: true, encoding: .utf8)
    }

    private static func csv(_ notes: [NoteEvent]) -> String {
        notes.map { "\($0.startTime),\($0.endTime),\($0.pitch),\(Int(($0.amplitude * 127).rounded()))" }
            .joined(separator: "\n")
    }

    /// Mono float32 WAV.
    private static func writeWAV(_ samples: ArraySlice<Float>, sampleRate: Double, to url: URL) throws {
        guard !samples.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}
#endif
