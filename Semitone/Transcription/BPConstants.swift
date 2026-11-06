import Foundation

/// Constants matching Spotify's Basic Pitch model (ICASSP 2022).
nonisolated enum BPConstants {
    static let sampleRate = 22050.0
    static let fftHop = 256
    /// Model input length in samples (~2 s at 22050 Hz).
    static let windowSamples = 43844
    /// Model output frames per window.
    static let framesPerWindow = 172
    /// Frames shared between consecutive windows; half is trimmed from each side.
    static let overlappingFrames = 30
    static let overlapSamples = overlappingFrames * fftHop
    static let hopSamples = windowSamples - overlapSamples
    static let pitchCount = 88
    static let midiOffset = 21
    /// Output frames per second.
    static let fps = sampleRate / Double(fftHop)

    /// Convert an unwrapped output frame index to seconds.
    /// Ported from basic_pitch's model_frames_to_time, including its
    /// per-window alignment offset.
    static func frameToTime(_ frame: Int) -> Double {
        let windowOffset = (Double(fftHop) / sampleRate)
            * (Double(framesPerWindow) - Double(windowSamples) / Double(fftHop))
            + 0.0018
        return Double(frame) * Double(fftHop) / sampleRate
            - windowOffset * Double(frame / framesPerWindow)
    }
}
