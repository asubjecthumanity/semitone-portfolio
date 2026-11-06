import XCTest
import SwiftUI
@testable import Semitone

/// The arithmetic behind the rolls' movement: the smooth playback clock, the
/// coarse playhead it publishes, scrubbing the falling notes, their live edge
/// while recording, the beat snap, the time index the per-frame drawing
/// queries, keeping a take's range on screen, and the text colours that keep
/// labels readable.
final class RollMotionTests: XCTestCase {

    // MARK: - Playback clock

    @MainActor
    func testClockWaitsForTheSequencerThenRunsOnTheHostClock() {
        let clock = PlaybackClock()
        clock.start(at: 2.0)
        XCTAssertTrue(clock.isRunning)
        // The engine hasn't rendered yet: the time holds at the start.
        clock.sync(sequencerTime: 2.0, host: 100.0)
        XCTAssertEqual(clock.time(at: 100.05), 2.0, accuracy: 1e-9)
        // The first buffer: run from there on the host clock.
        clock.sync(sequencerTime: 2.0116, host: 100.1)
        XCTAssertEqual(clock.time(at: 100.1), 2.0116, accuracy: 1e-9)
        XCTAssertEqual(clock.time(at: 100.6), 2.5116, accuracy: 1e-9)
    }

    /// The sequencer's position only moves in 11.6 ms buffer steps; read by a
    /// 60 Hz tick it jumps 0, 11.6 or 23.2 ms between reads. The clock it
    /// steers must still advance by exactly one frame's time every frame.
    @MainActor
    func testClockSmoothsTheSequencersBufferSteps() {
        let clock = PlaybackClock()
        clock.start(at: 0)
        let buffer = 512.0 / 44_100
        var host = 50.0
        var shown: [Double] = []
        for frame in 0..<600 {
            let audio = max(0, host - 50.0 - 0.03)      // audio starts 30 ms in
            let sequencer = (audio / buffer).rounded(.down) * buffer
            clock.sync(sequencerTime: sequencer, host: host)
            if frame > 120 { shown.append(clock.time(at: host + 1.0 / 120)) }
            host += 1.0 / 60
        }
        let steps = zip(shown, shown.dropFirst()).map { $1 - $0 }
        XCTAssertGreaterThan(steps.min()!, 1.0 / 60 - PlaybackClock.maxCorrection - 1e-9, "Never stalls or steps back.")
        XCTAssertLessThan(steps.max()!, 1.0 / 60 + PlaybackClock.maxCorrection + 1e-9, "Never leaps.")
        let mean = steps.reduce(0, +) / Double(steps.count)
        let wobble = sqrt(steps.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(steps.count))
        XCTAssertLessThan(wobble, 0.0005, "Frame-to-frame motion is even (under half a millisecond of wobble).")
        // It stays on the sequencer's average, within a buffer.
        let audio = host - 1.0 / 60 - 50.0 - 0.03
        XCTAssertEqual(clock.time(at: host - 1.0 / 60), audio, accuracy: buffer)
    }

    @MainActor
    func testClockReanchorsOnAJumpAndCorrectsSmallErrorsGently() {
        let clock = PlaybackClock()
        clock.start(at: 0)
        clock.sync(sequencerTime: 0.01, host: 10)
        // 40 ms behind: one sync moves at most `maxCorrection`.
        clock.sync(sequencerTime: 1.05, host: 11)
        XCTAssertEqual(clock.time(at: 11), 1.01 + PlaybackClock.maxCorrection, accuracy: 1e-9)
        // A reload or seek: straight there.
        clock.sync(sequencerTime: 5.0, host: 11.5)
        XCTAssertEqual(clock.time(at: 11.5), 5.0, accuracy: 1e-9)
    }

    @MainActor
    func testStoppedClockHoldsItsTime() {
        let clock = PlaybackClock()
        clock.start(at: 1)
        clock.sync(sequencerTime: 1.02, host: 3)
        clock.stop(host: 3.5)
        XCTAssertFalse(clock.isRunning)
        XCTAssertEqual(clock.time(at: 99), 1.52, accuracy: 1e-9)
        clock.sync(sequencerTime: 7, host: 4)
        XCTAssertEqual(clock.time(at: 99), 1.52, accuracy: 1e-9, "A stopped clock ignores the sequencer.")
    }

    func testCoarsePlayheadPublishesOnChordChangesAndFourTimesASecond() {
        XCTAssertTrue(PlayheadPublishing.shouldPublish(sinceLast: 0.01, chordChanged: true))
        XCTAssertFalse(PlayheadPublishing.shouldPublish(sinceLast: 0.1, chordChanged: false))
        XCTAssertTrue(PlayheadPublishing.shouldPublish(sinceLast: 0.25, chordChanged: false))
    }

    // MARK: - Falling-notes scrubbing

    func testScrubbingMovesTheNotesWithTheFinger() {
        let scrub = FallingScrub(duration: 8)
        XCTAssertEqual(scrub.maxOffset, 960)
        XCTAssertEqual(scrub.offset(forTime: 0), 960, "0:00 is at the bottom of the scroll.")
        XCTAssertEqual(scrub.offset(forTime: 8), 0, "The end is at the top.")
        // A finger moving up pulls the content up: the offset grows, and the
        // time on the hit line goes back (earlier notes rise out of the keys).
        let cued = scrub.offset(forTime: 4)
        XCTAssertEqual(scrub.time(forOffset: cued + 120), 3, accuracy: 1e-9)
        XCTAssertEqual(scrub.time(forOffset: cued - 120), 5, accuracy: 1e-9)
        // Past either end (the rubber band) the cue stays inside the take.
        XCTAssertEqual(scrub.cueTime(forOffset: -40), 8)
        XCTAssertEqual(scrub.cueTime(forOffset: 1000), 0)
        XCTAssertEqual(scrub.contentHeight(viewport: 500), 1460)
    }

    @MainActor
    func testScrubLetGoSettlesOnTheHorizontalRollsCatchZones() {
        let scrub = FallingScrub(duration: 8)
        let beats = stride(from: 0.0, through: 8, by: 0.5).map { $0 }
        let bars = stride(from: 0.0, through: 8, by: 2).map { $0 }
        // The snap the scrubber's scroll view uses, where it lets a drag come
        // to rest (clamped to the scroll, as the scroll view does), and the cue there.
        func settle(_ t: Double, grid: Bool = true) -> Double {
            let snap = scrub.beatSnap(beatTimes: grid ? beats : [], downbeatTimes: grid ? bars : [])
            let y = scrub.offset(forTime: t)
            let rest = BeatSnapBehavior.snapped(y, beatOffsets: snap.beatOffsets, measureOffsets: snap.measureOffsets) ?? y
            return scrub.cueTime(forOffset: min(max(rest, 0), scrub.maxOffset))
        }
        // A beat is 60 pt here: bars catch within 39 pt (0.325 s), beats within 18 pt (0.15 s).
        XCTAssertEqual(settle(2.3), 2, accuracy: 1e-9, "Near a bar: onto the bar.")
        XCTAssertEqual(settle(1.7), 2, accuracy: 1e-9)
        XCTAssertEqual(settle(2.6), 2.5, accuracy: 1e-9, "Near a beat: onto the beat.")
        XCTAssertEqual(settle(2.75), 2.75, accuracy: 1e-9, "Between beats it stays put.")
        XCTAssertEqual(settle(-0.2), 0, accuracy: 1e-9)
        // Without a beat grid nothing snaps.
        XCTAssertEqual(settle(2.3, grid: false), 2.3, accuracy: 1e-9)
    }

    func testVoiceOverMovesABarAtATimeAndReadsThePosition() {
        let bars = [0.0, 2, 4, 6, 8]
        XCTAssertEqual(FallingScrub.adjacentBar(from: 2, downbeats: bars, forward: true, duration: 8), 4)
        XCTAssertEqual(FallingScrub.adjacentBar(from: 2.7, downbeats: bars, forward: false, duration: 8), 2)
        XCTAssertEqual(FallingScrub.adjacentBar(from: 8, downbeats: bars, forward: true, duration: 8), 8)
        XCTAssertEqual(FallingScrub.adjacentBar(from: 0, downbeats: bars, forward: false, duration: 8), 0)
        XCTAssertEqual(FallingScrub.adjacentBar(from: 3, downbeats: [], forward: true, duration: 8), 5)
        let chords = [ChordSegment(startTime: 4, endTime: 6, label: "F")]
        XCTAssertEqual(FallingScrub.spokenPosition(at: 4, downbeats: bars, chords: chords, duration: 8), "Bar 3 of 4, F, 0:04")
        XCTAssertEqual(FallingScrub.spokenPosition(at: 8, downbeats: bars, chords: chords, duration: 8), "Bar 4 of 4, 0:08")
        XCTAssertEqual(FallingScrub.spokenPosition(at: 75, downbeats: [], chords: [], duration: 80), "1:15")
    }

    // MARK: - Falling notes while recording

    /// Where the falling notes draw moment `t`: `hitLineTime` on the hit
    /// line at the bottom of `height` points of notes, later moments higher.
    private func fallingY(_ t: Double, hitLineTime: Double, height: CGFloat, pxPerSecond: CGFloat) -> CGFloat {
        height - CGFloat(t - hitLineTime) * pxPerSecond
    }

    /// While recording, the top of the notes is the live edge less the live
    /// transcription's lag: what was just played comes in there once the
    /// transcription has it and falls down to the keys, reaching them the
    /// falling height's worth of seconds later (upright, 500 pt at 120 pt a
    /// second is about 4.2 s; on its side, 220 pt at 70 pt a second about
    /// 3.1 s).
    func testWhileRecordingTheNotesComeInAtTheTop() {
        let edge = 30.0
        let top = FallingLive.topTime(edge: edge)
        XCTAssertEqual(edge - top, FallingLive.transcriptionLag, accuracy: 1e-9)
        XCTAssertEqual(FallingLive.transcriptionLag, 1.96, accuracy: 0.01, "About 2 s behind what's played.")
        for (height, pps) in [(CGFloat(500), FallingGeometry.pxPerSecond),
                              (CGFloat(220), FallingGeometry.landscapePxPerSecond)] {
            let hit = FallingLive.hitLineTime(edge: edge, height: height, pxPerSecond: pps)
            func y(_ t: Double) -> CGFloat { fallingY(t, hitLineTime: hit, height: height, pxPerSecond: pps) }
            XCTAssertEqual(y(top), 0, accuracy: 1e-9, "The top is the live edge less the lag.")
            XCTAssertEqual(y(top - 1), pps, accuracy: 1e-9, "A second before is a second's fall down.")
            XCTAssertEqual(y(hit), height, accuracy: 1e-9, "The hit line is at the keys.")
            XCTAssertEqual(top - hit, Double(height / pps), accuracy: 1e-9)
        }
        // A note still sounding ends where the transcription has got to,
        // past the top: it runs off the top, growing down from there.
        let hit = FallingLive.hitLineTime(edge: edge, height: 500, pxPerSecond: 120)
        XCTAssertLessThan(fallingY(top + 0.2, hitLineTime: hit, height: 500, pxPerSecond: 120), 0)
        XCTAssertEqual(fallingY(top - 0.5, hitLineTime: hit, height: 500, pxPerSecond: 120), 60, accuracy: 1e-9)
    }

    /// The live transcription runs the model on a window of the audio (the
    /// first padded with half the overlap) each time one fills, and has the
    /// notes up to the end of the frames it keeps from them. At every
    /// microphone buffer of a four-minute take, that is past the top of the
    /// notes, with time over for the model and the note pass to run: so the
    /// notes come in at the top, not partway down. And the top is no
    /// further behind than that needs.
    func testTheTopOfTheNotesIsWhatTheLiveTranscriptionHas() {
        let padding = BPConstants.overlapSamples / 2
        let keptFrames = BPConstants.framesPerWindow - BPConstants.overlappingFrames
        // 4096 samples at 44.1 kHz, 48 kHz and a headset's 16 kHz, at the model's 22.05 kHz.
        for buffer in [2048, 1882, 5645] {
            var samples = 0, closest = Double.infinity
            while samples < 240 * Int(BPConstants.sampleRate) {
                samples += buffer
                let windows = samples + padding < BPConstants.windowSamples ? 0
                    : (samples + padding - BPConstants.windowSamples) / BPConstants.hopSamples + 1
                let transcribed = windows == 0 ? 0 : BPConstants.frameToTime(windows * keptFrames)
                closest = min(closest, transcribed - FallingLive.topTime(edge: Double(samples) / BPConstants.sampleRate))
            }
            XCTAssertGreaterThan(closest, 0.12, "The top is always behind what's transcribed, with time over: \(buffer)")
            XCTAssertLessThan(closest, 0.2, "No further behind than that needs: \(buffer)")
        }
    }

    /// The edge the falling notes show at each display frame (120 Hz) for
    /// ten seconds, with the live edge published once per microphone buffer
    /// of `buffer` seconds, each reaching the notes `delays` seconds late
    /// (in turn), and the publish each frame had.
    private func glidedEdges(buffer: Double, delays: [Double]) -> [(shown: Double, published: Double, step: Double)] {
        let frame = 1.0 / 120
        var published = 0.0, publishedAt = 0.0, step = FallingLive.firstStep, shown = 0.0, next = 1
        var frames: [(shown: Double, published: Double, step: Double)] = []
        for f in 1..<1200 {
            let host = Double(f) * frame
            while Double(next) * buffer + delays[next % delays.count] <= host {
                let edge = Double(next) * buffer
                step = edge - published
                published = edge
                publishedAt = edge + delays[next % delays.count]
                next += 1
            }
            shown = FallingLive.glide(shown: shown, published: published, sincePublished: host + frame - publishedAt,
                                      step: step, frame: frame)
            frames.append((shown, published, step))
        }
        return frames
    }

    /// Between the microphone's buffers (85 or 100 ms, 10 to 12 pt of fall)
    /// the edge runs on with the display, a frame's worth each frame, and
    /// publishes arriving up to 30 ms unevenly only nudge its speed, by under
    /// a tenth: it never stops, steps back or leaps, and never runs more than
    /// about a buffer past the last edge published.
    func testTheLiveEdgeGlidesEvenlyBetweenTheMicrophonesBuffers() {
        let frame = 1.0 / 120
        let cases: [(buffer: Double, delays: [Double])] = [
            (0.1, [0.004]),
            (0.1, [0, 0.018, 0.004, 0.03, 0.011, 0.025, 0.002, 0.016]),
            (4096.0 / 48_000, [0.003]),
            (4096.0 / 48_000, [0, 0.012, 0.004, 0.02, 0.007]),
        ]
        for (buffer, delays) in cases {
            let frames = glidedEdges(buffer: buffer, delays: delays)
            // After the first half second, as the first publishes come in.
            let steps = zip(frames, frames.dropFirst()).map { $1.shown - $0.shown }.dropFirst(60)
            XCTAssertGreaterThan(steps.min()!, frame * 0.9, "Never slows much, let alone stops: \(buffer) \(delays)")
            XCTAssertLessThan(steps.max()!, frame * 1.1, "Never hurries much, let alone leaps: \(buffer) \(delays)")
            XCTAssertEqual(steps.reduce(0, +) / Double(steps.count), frame, accuracy: frame * 0.01,
                           "Keeps up with the recording.")
            for f in frames {
                XCTAssertLessThanOrEqual(f.shown, f.published + FallingLive.lead(step: f.step) + 1e-9,
                                         "At most about a buffer ahead of what's published.")
            }
            XCTAssertGreaterThan(frames.dropFirst(60).map { $0.shown - $0.published }.min()!, -0.01,
                                 "Never more than a frame or so behind what's published.")
        }
    }

    /// When the model runs it can hold a publish up (70 ms here, and the
    /// next 30 ms): the edge waits a buffer past the last one published
    /// rather than run on with nothing behind it, then eases back on. If
    /// the publishes stop, so does the edge; back from far behind, it jumps.
    func testTheLiveEdgeWaitsForALatePublishAndJumpsWhenFarBehind() {
        let frame = 1.0 / 120
        let frames = glidedEdges(buffer: 0.1, delays: Array(repeating: 0.003, count: 15) + [0.07, 0.03])
        let steps = zip(frames, frames.dropFirst()).map { $1.shown - $0.shown }.dropFirst(60)
        XCTAssertGreaterThanOrEqual(steps.min()!, 0, "Never steps back.")
        XCTAssertLessThan(steps.max()!, frame * 1.25, "Eases back on rather than leaping.")
        for f in frames {
            XCTAssertLessThanOrEqual(f.shown, f.published + FallingLive.lead(step: f.step) + 1e-9)
        }

        // The publishes stop: the edge stops a buffer and a quarter on.
        var shown = 5.0
        for f in 1...60 {
            shown = FallingLive.glide(shown: shown, published: 5, sincePublished: Double(f) * frame, step: 0.1, frame: frame)
        }
        XCTAssertEqual(shown, 5.125, accuracy: 1e-9)
        // A publish behind what's shown (the edge ran on ahead of it) never takes it back.
        XCTAssertGreaterThanOrEqual(FallingLive.glide(shown: 5.1, published: 5, sincePublished: 0, step: 0.1, frame: frame), 5.1)
        // Far behind (the app was away a minute): straight there.
        XCTAssertEqual(FallingLive.glide(shown: 5, published: 65, sincePublished: 0.01, step: 0.1, frame: frame), 65.01,
                       accuracy: 1e-9)

        // A publish behind what's shown never takes it back, however far: it waits.
        XCTAssertEqual(FallingLive.glide(shown: 5.4, published: 5, sincePublished: 0.2, step: 0.1, frame: frame), 5.4)
        XCTAssertEqual(FallingLive.glide(shown: 5.4, published: 4, sincePublished: 0.2, step: 0.1, frame: frame), 5.4)

        XCTAssertEqual(FallingLive.lead(step: 0.1), 0.125, accuracy: 1e-9)
        XCTAssertEqual(FallingLive.lead(step: 4096.0 / 16_000), 0.32, accuracy: 1e-9,
                       "A headset's 16 kHz microphone hands over a quarter second at a time.")
        XCTAssertEqual(FallingLive.lead(step: 2), 0.375, accuracy: 1e-9, "Two seconds at once (the app was away) don't widen it.")
    }

    /// The edge the falling notes show at each display frame (120 Hz) for
    /// five seconds, given each publish of the live edge as `(at, edge)`:
    /// when it reaches the notes, and the edge it carries. The step is
    /// worked out as `FallingFollower.record(upTo:)` does.
    private func glidedEdges(publishes: [(at: Double, edge: Double)]) -> [(shown: Double, published: Double, step: Double)] {
        let frame = 1.0 / 120
        var published = 0.0, publishedAt = 0.0, step = FallingLive.firstStep, shown = 0.0, next = 0
        var frames: [(shown: Double, published: Double, step: Double)] = []
        for f in 1..<600 {
            let host = Double(f) * frame
            while next < publishes.count, publishes[next].at <= host {
                if publishes[next].edge > published { step = publishes[next].edge - published }
                (published, publishedAt) = (publishes[next].edge, publishes[next].at)
                next += 1
            }
            shown = FallingLive.glide(shown: shown, published: published, sincePublished: host + frame - publishedAt,
                                      step: step, frame: frame)
            frames.append((shown, published, step))
        }
        return frames
    }

    /// While the model runs, the microphone's buffers wait on the worker
    /// and can then reach the notes together, as one publish of two or
    /// three buffers: a long step, so the edge runs further past it while
    /// the next is held up. When that next one is a single buffer, its
    /// limit is nearer than where the edge already is: the edge waits for
    /// the publishes to catch up, never stepping back, and then runs on.
    func testTheLiveEdgeNeverStepsBackAfterBuffersComeInTogether() {
        let frame = 1.0 / 120
        let buffer = 4096.0 / 44_100
        // Ten buffers as they come, then `together` at once `firstHold` late,
        // then one more `secondHold` after that, then as they come again.
        for (together, firstHold, secondHold) in [(2, 0.15, 0.3), (3, 0.28, 0.4), (3, 0.1, 0.4), (2, 0, 0.25)] {
            var publishes: [(at: Double, edge: Double)] = (1...10).map { (Double($0) * buffer + 0.004, Double($0) * buffer) }
            var edge = 10 * buffer + Double(together) * buffer
            var at = edge + firstHold
            publishes.append((at, edge))
            at += secondHold
            while at < 6 {
                edge += buffer
                publishes.append((at, edge))
                at += buffer
            }
            let frames = glidedEdges(publishes: publishes)
            let label = "\(together) buffers \(firstHold) s late, then \(secondHold) s"
            for (before, after) in zip(frames, frames.dropFirst()) {
                XCTAssertGreaterThanOrEqual(after.shown, before.shown, "Never steps back: \(label)")
                XCTAssertTrue(after.shown == before.shown
                              || after.shown <= after.published + FallingLive.lead(step: after.step) + 1e-9,
                              "Only moves on within about a buffer of what's published: \(label)")
            }
            // The last second, the publishes coming evenly again.
            let last = frames.suffix(120)
            XCTAssertGreaterThan(last.map { $0.shown - $0.published }.min()!, -0.01, "Caught up: \(label)")
            let steps = zip(last, last.dropFirst()).map { $1.shown - $0.shown }
            XCTAssertEqual(steps.reduce(0, +) / Double(steps.count), frame, accuracy: frame * 0.02,
                           "Running with the recording again: \(label)")
        }
    }

    func testHorizontalBeatSnapIsUnchanged() {
        let beats: [CGFloat] = [0, 55, 110, 165, 220]
        let bars: [CGFloat] = [0, 220]
        XCTAssertEqual(BeatSnapBehavior.snapped(200, beatOffsets: beats, measureOffsets: bars), 220)
        XCTAssertEqual(BeatSnapBehavior.snapped(60, beatOffsets: beats, measureOffsets: bars), 55)
        XCTAssertNil(BeatSnapBehavior.snapped(82, beatOffsets: beats, measureOffsets: bars))
        XCTAssertNil(BeatSnapBehavior.snapped(82, beatOffsets: [0], measureOffsets: []))
    }

    // MARK: - Time index

    func testTimeIndexFindsEachSoundingNoteOnce() {
        var generator = SystemRandomNumberGenerator()
        let notes = (0..<400).map { _ -> NoteEvent in
            let start = Double.random(in: 0..<60, using: &generator)
            let length = [0.05, 0.3, 1.2, 7.5].randomElement(using: &generator)!
            return NoteEvent(startTime: start, endTime: start + length, pitch: Int.random(in: 21...108, using: &generator), amplitude: 0.5)
        }
        let index = NoteTimeIndex(notes)
        for range in [0.0...0.0, 3.2...3.2, 10.5...14.25, 59.9...70, -5...0.01, 0...80] {
            let expected = notes.filter { $0.startTime <= range.upperBound && $0.endTime >= range.lowerBound }
            let found = index.notes(overlapping: range)
            XCTAssertEqual(found.count, expected.count, "\(range)")
            XCTAssertEqual(Set(found.map(\.startTime)), Set(expected.map(\.startTime)), "\(range)")
        }
        XCTAssertTrue(NoteTimeIndex([]).notes(overlapping: 0...10).isEmpty)
    }

    // MARK: - The play line

    /// The play line is the keyboard's edge: the offset that parks a moment
    /// on it is that moment's place in the roll, so a note's start reaches
    /// the keys just as it plays (the take's start sits against them, not
    /// 8 pt off), and the cue, the beat snap and the follow all read the
    /// same mapping. The marker on it is 3 pt wide, twice the old line.
    func testThePlayLineIsTheKeyboardsEdge() {
        let g = RollGeometry()
        XCTAssertEqual(g.playLineInset, 0)
        XCTAssertEqual(g.offsetX(forTime: 0), 0)
        XCTAssertEqual(g.offsetX(forTime: 2.5), 2.5 * g.pxPerSecond)
        XCTAssertEqual(g.time(atOffsetX: g.offsetX(forTime: 7.25)), 7.25, accuracy: 1e-9)
        XCTAssertEqual(RollFollower.Config(geometry: g, maxScrollX: 10_000).goalX(at: 4), 4 * g.pxPerSecond)
        XCTAssertEqual(RollGeometry.markerWidth, 3)
        XCTAssertEqual(RollGeometry.markerOpacity, 0.7, accuracy: 1e-9, "Notes show through it.")
    }

    /// During playback the register follows the notes from the play line on.
    /// With the line against the keys, notes that have just ended are already
    /// under them: they no longer hold the roll down at their pitches (with
    /// them it centred the bass that had just ended and lost the high note
    /// starting on the line).
    func testTheRegisterFollowsTheNotesFromThePlayLineOn() {
        let g = RollGeometry()
        let height: CGFloat = 300
        let notes = [36, 38, 40].map { NoteEvent(startTime: 0, endTime: 0.9, pitch: $0, amplitude: 0.7) }
            + [NoteEvent(startTime: 1, endTime: 2, pitch: 80, amplitude: 0.7)]
        let config = RollFollower.Config(geometry: g, index: NoteTimeIndex(notes), maxScrollX: 1000,
                                         maxScrollY: g.rollHeight - height, viewportHeight: height)
        let y = config.registerTarget(at: 1, from: g.yFor(pitch: 38) - height / 2)
        XCTAssertNotNil(y)
        if let y {
            XCTAssertLessThanOrEqual(y, g.yFor(pitch: 80), "The note on the play line is on screen.")
            XCTAssertGreaterThanOrEqual(y + height, g.yFor(pitch: 80) + g.rowHeight)
        }
    }

    // MARK: - Keeping the notes on screen

    /// The Song fixture's take runs F2 to G5 (39 rows, 585 pt at 15 pt rows);
    /// the roll beside the two-row parts bar on an iPhone 17 Pro is 602 pt
    /// tall. It doesn't fit with a row's margin each side, so the range is
    /// centred rather than the median, which cut off the bass.
    func testSongRangeFitsOnScreenDuringPlayback() {
        let g = RollGeometry()
        let pitches = [41, 43, 48, 52, 55, 60, 64, 67, 72, 74, 76, 77, 79]
        let height: CGFloat = 602
        let maxY = g.rollHeight - height
        let target = RollGeometry.registerTarget(pitches: pitches, from: 0, viewportHeight: height,
                                                 maxScrollY: maxY, geometry: g)
        let y = try? XCTUnwrap(target)
        XCTAssertNotNil(y)
        if let y {
            XCTAssertLessThanOrEqual(y, g.yFor(pitch: 79), "G5 is on screen.")
            XCTAssertGreaterThanOrEqual(y + height, g.yFor(pitch: 41) + g.rowHeight, "F2 is on screen.")
            // Once there it stays put.
            XCTAssertNil(RollGeometry.registerTarget(pitches: pitches, from: y, viewportHeight: height,
                                                     maxScrollY: maxY, geometry: g))
        }
        // A narrower range already on screen with its margins: no move.
        XCTAssertNil(RollGeometry.registerTarget(pitches: [60, 64, 67], from: g.yFor(pitch: 80), viewportHeight: height,
                                                 maxScrollY: maxY, geometry: g))
        XCTAssertEqual(g.labelSize, 15 * 8 / 14, accuracy: 1e-9, "Labels grow with the rows.")
    }

    // MARK: - Readable labels

    /// The parts' colours (`Voice.fill(for:)`: the calm fills, and with
    /// Increase Contrast the deeper outline colours; and the falling notes'
    /// black-key violet) as drawn: 35-95 % over the roll's white and shaded
    /// rows (the app is light only). The note names are navy where it reads
    /// and black or white otherwise; whichever the rolls pick must read at
    /// 4.5:1.
    @MainActor
    func testNoteNamesReadOnEveryPartColour() {
        var increased = EnvironmentValues()
        increased._colorSchemeContrast = .increased
        let rows: [RollInk.RGB] = [.white, RollTheme.shadedRowRGB]
        var navy = 0
        for environment in [EnvironmentValues(), increased] {
            let palette = PartPalette(environment)
            let colours = ([Voice.none] + Voice.parts).map { palette.rgb($0) }
                + [palette.rgb(Voice.blackKeyNote), palette.rgb(Voice.blackKeyNoteOutline)]
            for colour in colours {
                for row in rows {
                    for amplitude in stride(from: 0.0, through: 1.0, by: 0.1) {
                        let fill = row.under(colour, opacity: 0.35 + 0.6 * amplitude)
                        let ink = RollInk.text(on: fill, preferred: RollInk.navyRGB)
                        XCTAssertGreaterThanOrEqual(RollInk.contrast(ink, fill), 4.5, "\(colour) over \(row)")
                        if ink == RollInk.navyRGB { navy += 1 }
                    }
                }
            }
        }
        XCTAssertGreaterThan(navy, 0, "Navy names where they read.")
        // With Increase Contrast the parts fill with their outline colours.
        XCTAssertEqual(PartPalette(increased).rgb(.melody), PartPalette(increased).rgb(Voice.melody.outline))
        XCTAssertNotEqual(PartPalette(increased).rgb(.melody), PartPalette(EnvironmentValues()).rgb(.melody))
        let palette = PartPalette(EnvironmentValues())
        // White was what the roll drew once: 1.9 to 3.4:1 on the light fills.
        let melody = RollInk.RGB.white.under(palette.rgb(.melody), opacity: 0.83)
        XCTAssertLessThan(RollInk.contrast(.white, melody), 4.5)
        XCTAssertEqual(RollInk.text(on: melody, preferred: RollInk.navyRGB), RollInk.navyRGB)
        // The plum bass is too deep for navy once it's loud: black at 0.8
        // loudness, white at the loudest (`BarStyle.name`).
        let bass = RollInk.RGB.white.under(palette.rgb(.bass), opacity: 0.83)
        XCTAssertEqual(RollInk.text(on: bass, preferred: RollInk.navyRGB), .black)
        let loudestBass = RollInk.RGB.white.under(palette.rgb(.bass), opacity: 0.95)
        XCTAssertEqual(RollInk.text(on: loudestBass, preferred: RollInk.navyRGB), .white)
    }

    func testChordAndGreyInksReadOnTheirBackgrounds() {
        let navy = RollInk.navyRGB
        let ground = rgb(0xF2, 0xF2, 0xF7)
        // Chord names and bar numbers are navy: on white, the shaded rows and the toolbar's ground.
        XCTAssertGreaterThanOrEqual(RollInk.contrast(navy, .white), 16.5)
        XCTAssertGreaterThanOrEqual(RollInk.contrast(navy, RollTheme.shadedRowRGB), 14.5)
        XCTAssertGreaterThanOrEqual(RollInk.contrast(navy, ground), 14.5)
        XCTAssertLessThan(RollInk.contrast(rgb(0x00, 0x88, 0xFF), .white), 4.5, "The system blue it replaces.")
        // The toolbar's secondary text, on the ground it sits on.
        XCTAssertGreaterThanOrEqual(RollInk.contrast(rgb(0x63, 0x63, 0x66), ground), 5.3)
        XCTAssertGreaterThanOrEqual(RollInk.contrast(RollInk.keyLabel, .white), 6)
        XCTAssertLessThan(RollInk.contrast(rgb(0x8E, 0x8E, 0x93), .white), 4.5, "The system grey it replaces.")
        // A lit key: grey while it reads, then black or white.
        XCTAssertEqual(RollInk.text(on: .white, preferred: RollInk.keyLabel), RollInk.keyLabel)
        let lit = RollInk.RGB.white.under(rgb(0x97, 0x43, 0x91), opacity: 0.9)
        let ink = RollInk.text(on: lit, preferred: RollInk.keyLabel)
        XCTAssertNotEqual(ink, RollInk.keyLabel)
        XCTAssertGreaterThanOrEqual(RollInk.contrast(ink, lit), 4.5)
    }

    /// Colours are compared as Core Graphics blends them: gamma-encoded sRGB.
    @MainActor
    func testResolvedColoursAreGammaEncodedSRGB() {
        let environment = EnvironmentValues()
        let mid = RollInk.rgb(Color(.sRGB, red: 0.5, green: 0.25, blue: 0.75), in: environment)
        XCTAssertEqual(mid.r, 0.5, accuracy: 0.01)
        XCTAssertEqual(mid.g, 0.25, accuracy: 0.01)
        XCTAssertEqual(mid.b, 0.75, accuracy: 0.01)
        let palette = PartPalette(environment)
        XCTAssertEqual(palette.rgb(.melody).r, Double(0xF8) / 255, accuracy: 0.005, "The melody's apricot, #F8AA6D.")
        XCTAssertEqual(palette.rgb(.melody).b, Double(0x6D) / 255, accuracy: 0.005)
    }

    private func rgb(_ r: Int, _ g: Int, _ b: Int) -> RollInk.RGB {
        RollInk.RGB(Double(r) / 255, Double(g) / 255, Double(b) / 255)
    }
}
