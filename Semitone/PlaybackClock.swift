import QuartzCore

/// Playback time on the display's clock. The sequencer's own position
/// (`AVAudioSequencer.currentPositionInSeconds`) only moves when an audio
/// buffer renders, in steps of about 11.6 ms, so a roll that followed it would
/// stutter at any frame rate. This clock runs on the host clock
/// (`CACurrentMediaTime`, the clock CADisplayLink timestamps use) and is
/// nudged toward the sequencer a little on each model tick, so a display
/// frame can ask what the time will be at the moment it reaches the screen.
/// Nothing here is published: the views that move with playback read it once
/// per frame, and the rest of the screen never redraws for it.
@MainActor
final class PlaybackClock {
    private enum State {
        case stopped(Double)
        /// Playback asked to start here, but the sequencer hasn't rendered
        /// its first buffer yet: the time holds until the audio really moves,
        /// so the roll never runs ahead of the sound and then has to slow down.
        case waiting(Double)
        case running(anchorHost: CFTimeInterval, anchorTime: Double)
    }

    private var state = State.stopped(0)

    /// A sequencer this far off is a real jump (a reload, a seek), not buffer
    /// jitter: re-anchor at once.
    static let jumpThreshold = 0.1
    /// Share of the remaining error taken per sync (the model ticks about 60
    /// times a second), so the clock settles on the sequencer's average in
    /// about a third of a second and its 11.6 ms steps never show.
    static let correctionGain = 0.05
    /// The most one sync may move the clock. A frame is 8 to 17 ms, so even
    /// a large correction never stops or reverses the roll.
    static let maxCorrection = 0.002

    var isRunning: Bool {
        switch state {
        case .stopped: false
        case .waiting, .running: true
        }
    }

    /// Starts (or restarts, after a seek) at `time`. The clock waits for the
    /// sequencer's first step before it runs (see `sync`).
    func start(at time: Double) {
        state = .waiting(time)
    }

    /// Freezes the clock where it is at `host`.
    func stop(host: CFTimeInterval = CACurrentMediaTime()) {
        state = .stopped(time(at: host))
    }

    /// Playback time at host time `host` (pass a display link's
    /// `targetTimestamp` for the time a frame will show).
    func time(at host: CFTimeInterval) -> Double {
        switch state {
        case .stopped(let t), .waiting(let t): t
        case .running(let anchorHost, let anchorTime): anchorTime + (host - anchorHost)
        }
    }

    /// Moves gently toward the sequencer's position, read at `host`.
    func sync(sequencerTime: Double, host: CFTimeInterval) {
        switch state {
        case .stopped:
            return
        case .waiting(let start):
            // The first buffer has played: run from here.
            if abs(sequencerTime - start) > 0.0005 {
                state = .running(anchorHost: host, anchorTime: sequencerTime)
            }
        case .running(let anchorHost, let anchorTime):
            let error = sequencerTime - (anchorTime + (host - anchorHost))
            if abs(error) > Self.jumpThreshold {
                state = .running(anchorHost: host, anchorTime: sequencerTime)
            } else {
                let step = min(max(error * Self.correctionGain, -Self.maxCorrection), Self.maxCorrection)
                state = .running(anchorHost: anchorHost, anchorTime: anchorTime + step)
            }
        }
    }
}

/// When the model republishes its coarse `playhead` during playback. The
/// views that move with playback read `PlaybackClock` every frame; everything
/// else on screen (the toolbar's chord name, Home behind the transcription
/// screen) observes the model, so it hears only about chord changes, on the
/// tick they happen, and otherwise about four times a second.
enum PlayheadPublishing {
    static let interval: CFTimeInterval = 0.25

    static func shouldPublish(sinceLast elapsed: CFTimeInterval, chordChanged: Bool) -> Bool {
        chordChanged || elapsed >= interval
    }
}
