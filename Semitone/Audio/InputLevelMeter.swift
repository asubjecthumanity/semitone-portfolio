import Foundation
import Observation

/// The microphone's input level while recording, for the record button's
/// live ring. About 30 times a second (on the main actor) it reads the
/// latest RMS from its source, maps it to 0…1 on a decibel scale and smooths
/// it (quick to rise, slower to fall). It's its own observable, so only the
/// views that draw it redraw at that rate; nothing here touches transcription.
@MainActor @Observable
final class InputLevelMeter {
    /// The smoothed level: 0 is silence (or not recording), 1 is loud.
    private(set) var level: Float = 0
    /// The last `historyCount` smoothed levels, oldest first (about two seconds).
    private(set) var history = [Float](repeating: 0, count: InputLevelMeter.historyCount)

    static let historyCount = 60
    /// Samples per second.
    static let rate: Double = 30
    /// RMS at or below this many dBFS reads as 0, at or above `ceilingDB` as 1.
    nonisolated static let floorDB: Float = -54
    nonisolated static let ceilingDB: Float = -12

    @ObservationIgnored private var sampler: Task<Void, Never>?

    /// Starts sampling `rms` (linear RMS of the latest input, any scale 0…1).
    func start(rms: @escaping @MainActor () -> Float) {
        stop()
        sampler = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1 / Self.rate))
                guard !Task.isCancelled, let self else { return }
                self.push(Self.normalized(rms: rms()))
            }
        }
    }

    /// Stops sampling and drops back to silence.
    func stop() {
        sampler?.cancel()
        sampler = nil
        level = 0
        history = [Float](repeating: 0, count: Self.historyCount)
    }

    /// Moves the level toward `target` (0…1) by one sample and records it.
    func push(_ target: Float) {
        let target = min(max(target.isFinite ? target : 0, 0), 1)
        level += (target - level) * (target > level ? 0.55 : 0.2)
        history.removeFirst()
        history.append(level)
    }

    /// Linear RMS to 0…1, linear in decibels between `floorDB` and `ceilingDB`.
    nonisolated static func normalized(rms: Float) -> Float {
        guard rms.isFinite, rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(max((db - floorDB) / (ceilingDB - floorDB), 0), 1)
    }

    #if DEBUG
    /// A made-up, music-like input for the DEBUG recording preview on Home.
    static func demoSource() -> @MainActor () -> Float {
        let start = Date()
        return {
            let t = Date().timeIntervalSince(start)
            let phrase = 0.5 + 0.5 * sin(t * 1.7) * sin(t * 0.45 + 1)
            return Float(0.0015 + 0.05 * phrase * phrase * Double.random(in: 0.4...1))
        }
    }
    #endif
}
