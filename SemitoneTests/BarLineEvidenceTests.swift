import XCTest
@testable import Semitone

/// What the beat tracker reads as evidence for beat 1.
final class BarLineEvidenceTests: XCTestCase {
    /// One chord a second (sine tones, MIDI pitches), each faded in and out
    /// over 10 ms so a change makes no click.
    private func chords(_ chords: [[Int]], rate: Double) -> [Float] {
        let per = Int(rate), fade = Int(0.01 * rate)
        var out = [Float](repeating: 0, count: per * chords.count)
        for (k, pitches) in chords.enumerated() {
            for i in 0..<per {
                let t = Double(k * per + i) / rate
                let gain = Double(min(i, per - i, fade)) / Double(fade)
                out[k * per + i] = Float(gain * pitches.reduce(0) {
                    $0 + 0.2 * sin(2 * .pi * 440 * pow(2, Double($1 - 69) / 12) * t)
                })
            }
        }
        return out
    }

    private let c = [48, 60, 64, 67], f = [53, 57, 60, 65], g = [55, 59, 62, 67]

    /// The chord changes heard in the tonal part peak where the chord changes,
    /// and stay near zero while it holds.
    func testHarmonyChangePeaksWhereTheChordChanges() {
        let rate = BPConstants.sampleRate
        let change = OnsetEnvelope.harmonyChange(chords([c, f, g, c], rate: rate), sampleRate: rate)
        XCTAssertEqual(Double(change.count), 4 * BeatTracker.fps, accuracy: 30)

        func peak(near seconds: Double) -> Float {
            let frame = Int(seconds * BeatTracker.fps)
            return change[(frame - 10)...(frame + 10)].max() ?? 0
        }
        func held(around seconds: Double) -> Float {
            let frame = Int(seconds * BeatTracker.fps)
            return change[(frame - 10)...(frame + 10)].max() ?? 1
        }
        for t in [1.0, 2.0, 3.0] {
            XCTAssertGreaterThan(peak(near: t), 0.4, "a new chord at \(t) s")
        }
        for t in [1.5, 2.5, 3.5] {
            XCTAssertLessThan(held(around: t), 0.05, "the chord holds at \(t) s")
        }
    }

    /// Silence on either side of a frame says nothing about a chord change.
    func testHarmonyChangeIsZeroInSilence() {
        let rate = BPConstants.sampleRate
        let audio = [Float](repeating: 0, count: Int(rate)) + chords([c], rate: rate)
        let change = OnsetEnvelope.harmonyChange(audio, sampleRate: rate)
        XCTAssertEqual(change[..<Int(0.5 * BeatTracker.fps)].max() ?? 1, 0)
    }

    /// An any-instrument take's onsets carry its tonal part's chord changes,
    /// with or without the percussive cue.
    func testAnyInstrumentOnsetsCarryTheChordChanges() {
        let rate = BPConstants.sampleRate
        let harmonic = chords([c, f], rate: rate)
        let parts = HarmonicPercussive.Output(harmonic: harmonic, percussive: [Float](repeating: 0, count: harmonic.count))
        let expected = OnsetEnvelope.harmonyChange(harmonic, sampleRate: rate)
        let light = OnsetEnvelope.music(parts, percussiveShare: 0, sampleRate: rate)
        XCTAssertEqual(light.harmony, expected)
        XCTAssertNil(light.percussion)
        let heavy = OnsetEnvelope.music(parts, percussiveShare: OnsetEnvelope.drumHeavyShare, sampleRate: rate)
        XCTAssertEqual(heavy.harmony, expected)
        XCTAssertNotNil(heavy.percussion)
    }

    /// Auto meter: bars of 3, 4 and 5 beats (a long bass note on beat 1, the
    /// bar's chord struck on every beat, 120 BPM) are each found as such, with
    /// beat 1 on the bass note.
    func testAutoMeterFindsThreeFourAndFiveBeatBars() {
        let chords = [[60, 64, 67], [65, 69, 72], [67, 71, 74], [57, 60, 64]]
        for meter in [3, 4, 5] {
            var notes: [NoteEvent] = []
            var barStarts: [Double] = []
            for bar in 0..<16 {
                let start = 0.5 + Double(bar * meter) * 0.5
                let chord = chords[bar % chords.count]
                barStarts.append(start)
                notes.append(NoteEvent(startTime: start, endTime: start + 0.5 * Double(meter) - 0.05,
                                       pitch: chord[0] - 24, amplitude: 0.8))
                for beat in 0..<meter {
                    let t = start + Double(beat) * 0.5
                    for pitch in chord {
                        notes.append(NoteEvent(startTime: t, endTime: t + 0.4, pitch: pitch, amplitude: beat == 0 ? 0.7 : 0.5))
                    }
                }
            }
            let result = BeatTracker.track(notes: notes, duration: barStarts.last! + 0.5 * Double(meter) + 1,
                                           beatsPerBar: nil)
            XCTAssertEqual(result.beatsPerBar, meter)
            XCTAssertEqual(result.medianBPM, 120, accuracy: 2)
            let downbeats = zip(result.beats, result.barPositions).filter { $0.1 == 0 }.map(\.0)
            let onBarStarts = downbeats.filter { d in barStarts.contains { abs($0 - d) <= 0.07 } }
            XCTAssertGreaterThanOrEqual(onBarStarts.count, 15, "\(meter) beats: beat 1 on the bass notes")
        }
    }

    /// A 4/4 song that drops half a bar once (a 2/4 bar, as Africa does six
    /// times): the bar lines move with it instead of sitting on beat 3 for the
    /// rest of the song.
    func testABarCutShortMovesTheBarLines() {
        let chords = [[60, 64, 67], [65, 69, 72], [67, 71, 74], [57, 60, 64]]
        var notes: [NoteEvent] = []
        var barStarts: [Double] = []
        var start = 0.5
        for bar in 0..<25 {
            let beats = bar == 12 ? 2 : 4
            let chord = chords[bar % chords.count]
            barStarts.append(start)
            notes.append(NoteEvent(startTime: start, endTime: start + 0.5 * Double(beats) - 0.05,
                                   pitch: chord[0] - 24, amplitude: 0.8))
            for beat in 0..<beats {
                let t = start + Double(beat) * 0.5
                for pitch in chord {
                    notes.append(NoteEvent(startTime: t, endTime: t + 0.4, pitch: pitch, amplitude: beat == 0 ? 0.7 : 0.5))
                }
            }
            start += 0.5 * Double(beats)
        }
        let result = BeatTracker.track(notes: notes, duration: start + 1, beatsPerBar: nil)
        XCTAssertEqual(result.beatsPerBar, 4)
        XCTAssertEqual(result.medianBPM, 120, accuracy: 2)
        let downbeats = zip(result.beats, result.barPositions).filter { $0.1 == 0 }.map(\.0)
        let found = barStarts.filter { b in downbeats.contains { abs($0 - b) <= 0.07 } }
        XCTAssertEqual(found.count, barStarts.count, "beat 1 on every bass note, after the 2/4 bar too")
        let inside = downbeats.filter { $0 < start - 0.25 }   // the grid runs on past the music
        XCTAssertEqual(inside.count, barStarts.count, "no other bar lines")
    }

    /// A pulse whose attacks ring for a few frames, every other beat weaker
    /// (bowed or sustained parts): tracked at its own tempo at 137 and
    /// 145 BPM, as at 120. While the beat region was rounded down to whole
    /// frames its share of the beat shrank at these tempi, and the grid fell to
    /// half tempo (Viva la Vida, 137 BPM, tracked at 69 for most of the song).
    func testRoundingDoesNotHalveAFastPulse() {
        for bpm in [120.0, 137.6, 145.0] {
            let beat = 60 / bpm, frames = Int(60 * BeatTracker.fps)
            var activation = [Float](repeating: 0.02, count: frames), down = [Float](repeating: 0.01, count: frames)
            var i = 0
            while true {
                let frame = Int(((0.3 + Double(i) * beat) * BeatTracker.fps).rounded())
                if frame + 6 >= frames { break }
                let height: Float = i.isMultiple(of: 2) ? 0.45 : 0.27
                for q in -1...5 { activation[frame + q] = max(activation[frame + q], height * (1 - 0.1 * Float(max(q, 0)))) }
                if i.isMultiple(of: 4) {
                    for q in -1...1 { down[frame + q] = 0.3; activation[frame + q] = 0.15 }
                }
                i += 1
            }
            let result = BeatTracker.decode(BeatTracker.Activations(beat: activation, down: down), beatsPerBar: 4)
            XCTAssertEqual(result.medianBPM, bpm, accuracy: 0.03 * bpm, "\(bpm) BPM")
        }
    }

    /// A kick on every beat leans toward beat 1 without making the other beats
    /// less likely: the grid stays on the beat when the notes are syncopated and
    /// the hats on the off-beats are nearly as loud as the kit on the beat. (When
    /// the kick was bar-line evidence, which takes weight from the other beats,
    /// this grid sat on the off-beats, as Superstition's did.) At 100 BPM the
    /// eighths, as loud as the beats here, would be counted as beats; in Song
    /// mode the snare on two and four, on every other grid beat with the kick
    /// on all of them, halves the grid back (see
    /// `testDrumHeavyTakeFindsTheBeatFromItsPercussiveOnsets`).
    func testAKickOnEveryBeatKeepsTheGridOnTheBeat() {
        let period = 60.0 / 100
        let beats = (0..<50).map { 0.5 + Double($0) * period }
        var notes: [NoteEvent] = []
        for (k, t) in beats.enumerated() {
            notes.append(NoteEvent(startTime: t + period / 2, endTime: t + 0.7 * period, pitch: 64 + k % 3,
                                   amplitude: 0.6, voice: .chords))
            notes.append(NoteEvent(startTime: t + 0.75 * period, endTime: t + 0.97 * period, pitch: 40 + (k / 4) % 3,
                                   amplitude: 0.6, voice: .bass))
        }
        let duration = beats.last! + 1
        func spikes(_ times: [Double], _ height: Float) -> [Float] {
            var x = [Float](repeating: 0, count: Int(duration * BeatTracker.fps) + 2)
            for t in times {
                let frame = Int((t * BeatTracker.fps).rounded())
                x[frame] = max(x[frame], height)
            }
            return x
        }
        let kit = zip(spikes(beats, 1), spikes(beats.map { $0 + period / 2 }, 0.7)).map { max($0, $1) }
        let snare = spikes(beats.enumerated().filter { !$0.offset.isMultiple(of: 2) }.map(\.element), 1)
        let onsets = AudioOnsets(onsets: spikes(notes.map(\.startTime), 1),
                                 percussion: .init(onsets: kit, low: spikes(beats, 1), mid: snare),
                                 chroma: chroma(of: notes, duration: duration))
        let result = BeatTracker.track(notes: notes, duration: duration, beatsPerBar: nil, audioOnsets: onsets)
        let onBeat = result.beats.filter { b in beats.contains { abs($0 - b) <= 0.07 } }.count
        XCTAssertGreaterThan(Double(onBeat) / Double(max(result.beats.count, 1)), 0.95)
        XCTAssertEqual(result.medianBPM, 100, accuracy: 1.5)
    }

    // MARK: - Tempo octave

    /// Onset spikes at `BeatTracker.fps`.
    private func spikes(_ times: [Double], _ height: Float, duration: Double) -> [Float] {
        var x = [Float](repeating: 0, count: Int(duration * BeatTracker.fps) + 2)
        for t in times {
            let frame = Int((t * BeatTracker.fps).rounded())
            if frame < x.count { x[frame] = max(x[frame], height) }
        }
        return x
    }

    /// Beats on `truth` (within 70 ms), as a share of the grid.
    private func onBeat(_ result: BeatTracker.Result, _ truth: [Double]) -> Double {
        let hits = result.beats.filter { b in truth.contains { abs($0 - b) <= 0.07 } }.count
        return Double(hits) / Double(max(result.beats.count, 1))
    }

    /// The tonal part's chroma (`AudioOnsets.chroma`, Song mode's evidence)
    /// of `notes`: each sounding note adds 1 to its pitch class.
    private func chroma(of notes: [NoteEvent], duration: Double) -> [Float] {
        let fps = OnsetEnvelope.chromaFPS
        let frames = Int(duration * fps) + 1
        var c = [Float](repeating: 0.02, count: frames * 12)
        for n in notes {
            let a = Int((n.startTime * fps).rounded()), b = min(frames, Int((n.endTime * fps).rounded()))
            guard a < b else { continue }
            for f in a..<b { c[f * 12 + ((n.pitch % 12) + 12) % 12] += 1 }
        }
        return c
    }

    /// A drumless song counted in eighths, as Country Roads is (82 BPM,
    /// tracked at 162): a bass note on every beat, chords in even eighths, a
    /// new chord every two beats, at 78-88 BPM. The onsets alone fit the
    /// eighths as well as the beats, and the decoder counts them (156-176
    /// BPM); in Song mode the bass, on every other grid beat, halves the
    /// grid. Piano mode's passes and the Home preview (notes only, or the
    /// audio's onsets without its chroma) keep the decoder's grid.
    func testAFastDrumlessGridIsHalvedInSongModeOnly() {
        for bpm in [78.0, 82, 88] {
            let period = 60.0 / bpm
            let chords = [[60, 64, 67], [55, 59, 62], [57, 60, 64], [53, 57, 60]]
            var notes: [NoteEvent] = []
            var beats: [Double] = []
            for k in 0..<64 {
                let t = 0.5 + Double(k) * period
                beats.append(t)
                let chord = chords[(k / 2) % chords.count]
                notes.append(NoteEvent(startTime: t, endTime: t + 0.95 * period, pitch: chord[0] - 24, amplitude: 0.6))
                for eighth in 0..<2 {
                    let s = t + Double(eighth) * period / 2
                    for pitch in chord {
                        notes.append(NoteEvent(startTime: s, endTime: s + 0.45 * period, pitch: pitch, amplitude: 0.5))
                    }
                }
            }
            let duration = beats.last! + 1
            let piano = AudioOnsets(onsets: spikes(notes.map(\.startTime), 1, duration: duration))
            var song = piano
            song.chroma = chroma(of: notes, duration: duration)
            let halved = BeatTracker.track(notes: notes, duration: duration, beatsPerBar: nil, audioOnsets: song)
            XCTAssertEqual(halved.medianBPM, bpm, accuracy: 1.5, "Song mode, \(bpm) BPM")
            XCTAssertEqual(halved.beatsPerBar, 4)
            XCTAssertGreaterThan(onBeat(halved, beats), 0.95, "on the bass notes, not the off-beats")
            for onsets in [nil, piano] {
                let kept = BeatTracker.track(notes: notes, duration: duration, beatsPerBar: nil, audioOnsets: onsets)
                XCTAssertEqual(kept.medianBPM, 2 * bpm, accuracy: 4, "Piano mode keeps the grid, \(bpm) BPM")
            }
        }
    }

    /// A drumless solo piano in 4/4 at a pop tempo, its left hand in half
    /// notes (bass on beats 1 and 3, below E3) under chords on two and four
    /// or on every beat, a melody on top: the bass marks only every other
    /// beat, but the grid (120-150 BPM) is the music's count and stays, in
    /// every mode, with its bar lines. (With a floor of 120 BPM these were
    /// halved: beat F1 0.99 -> 0.66 on such pieces rendered with the GM piano.)
    func testAHalfNoteBassAtAPopTempoKeepsItsTempo() {
        let progression = [[0, 4, 7], [7, 11, 2], [9, 0, 4], [5, 9, 0]]
        for (bpm, onEveryBeat) in [(132.0, false), (132.0, true), (120.0, true), (150.0, false)] {
            let period = 60.0 / bpm
            var notes: [NoteEvent] = []
            var beats: [Double] = []
            var downbeats: [Double] = []
            for bar in 0..<32 {
                let chord = progression[bar % 4]
                let t0 = 0.5 + Double(bar * 4) * period
                downbeats.append(t0)
                beats += (0..<4).map { t0 + Double($0) * period }
                let hold = (onEveryBeat ? 1.8 : 0.9) * period
                notes.append(NoteEvent(startTime: t0, endTime: t0 + hold, pitch: 36 + chord[0], amplitude: 0.7))
                notes.append(NoteEvent(startTime: t0 + 2 * period, endTime: t0 + 2 * period + hold,
                                       pitch: 36 + chord[2], amplitude: 0.65))
                for beat in onEveryBeat ? [0, 1, 2, 3] : [1, 3] {
                    let s = t0 + Double(beat) * period
                    for pc in chord {
                        notes.append(NoteEvent(startTime: s, endTime: s + (onEveryBeat ? 0.9 : 0.45) * period,
                                               pitch: 60 + pc, amplitude: 0.5))
                    }
                }
                notes.append(NoteEvent(startTime: t0, endTime: t0 + 1.9 * period, pitch: 72 + chord[1], amplitude: 0.8))
                notes.append(NoteEvent(startTime: t0 + 2 * period, endTime: t0 + 3.9 * period, pitch: 72 + chord[0],
                                       amplitude: 0.8))
            }
            let duration = beats.last! + 1.5
            let piano = AudioOnsets(onsets: spikes(notes.map(\.startTime), 1, duration: duration))
            var song = piano
            song.chroma = chroma(of: notes, duration: duration)
            for (mode, onsets) in [("notes only", nil), ("Piano mode", piano), ("Song mode", song)] as [(String, AudioOnsets?)] {
                let result = BeatTracker.track(notes: notes, duration: duration, beatsPerBar: nil, audioOnsets: onsets)
                XCTAssertEqual(result.medianBPM, bpm, accuracy: 2, "\(mode), \(bpm) BPM")
                XCTAssertEqual(result.beatsPerBar, 4, "\(mode), \(bpm) BPM")
                XCTAssertGreaterThan(onBeat(result, beats), 0.95, "\(mode), \(bpm) BPM")
                let found = zip(result.beats, result.barPositions).filter { $0.1 == 0 }.map(\.0)
                let right = found.filter { t in downbeats.contains { abs($0 - t) <= 0.07 } }.count
                XCTAssertGreaterThan(Double(right), 0.95 * Double(found.count), "\(mode), \(bpm) BPM: bar lines")
            }
        }
    }

    /// A kit counted in eighths: notes and hats in even eighths as loud as
    /// the beats, the kick on one and three, the snare on two and four. The
    /// decoder takes the eighths (160-200 BPM); in Song mode (the only one
    /// with a kit cue and the audio's chroma) the kick and snare, only on
    /// every other grid beat, halve the grid onto them.
    func testAKitCountedInEighthsIsHalvedOntoItsKickAndSnare() {
        for bpm in [80.0, 100.0] {
            let period = 60.0 / bpm
            var notes: [NoteEvent] = []
            var beats: [Double] = []
            for k in 0..<64 {
                let t = 0.5 + Double(k) * period
                beats.append(t)
                for eighth in 0..<2 {
                    let s = t + Double(eighth) * period / 2
                    for pitch in [64, 67, 71] {
                        notes.append(NoteEvent(startTime: s, endTime: s + 0.45 * period, pitch: pitch, amplitude: 0.5))
                    }
                }
            }
            let duration = beats.last! + 1
            let kicks = beats.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
            let snares = beats.enumerated().filter { !$0.offset.isMultiple(of: 2) }.map(\.element)
            let hats = beats.flatMap { [$0, $0 + period / 2] }
            let onsets = AudioOnsets(onsets: spikes(notes.map(\.startTime), 1, duration: duration),
                                     percussion: .init(onsets: spikes(hats, 1, duration: duration),
                                                       low: spikes(kicks, 1, duration: duration),
                                                       mid: spikes(snares, 1, duration: duration)),
                                     chroma: chroma(of: notes, duration: duration))
            let result = BeatTracker.track(notes: notes, duration: duration, beatsPerBar: nil, audioOnsets: onsets)
            XCTAssertEqual(result.medianBPM, bpm, accuracy: 1.5)
            XCTAssertGreaterThan(onBeat(result, beats), 0.95)
        }
    }

    /// A grid that is right stays: a kit alternating kick and snare (or a
    /// kick on every beat under a snare on two and four) hits every grid beat,
    /// so a bass in half notes under it does not halve the grid; and a
    /// waltz's bass, once a bar, falls on both alternate grid beats.
    func testARightGridIsNotHalved() {
        for (bpm, fourOnTheFloor) in [(120.0, false), (140.0, false), (124.0, true)] {
            let period = 60.0 / bpm
            var notes: [NoteEvent] = []
            var beats: [Double] = []
            for k in 0..<64 {
                let t = 0.5 + Double(k) * period
                beats.append(t)
                if k.isMultiple(of: 2) {
                    notes.append(NoteEvent(startTime: t, endTime: t + 1.9 * period, pitch: 40 + (k / 8) % 3, amplitude: 0.6))
                }
                for eighth in 0..<2 {
                    let s = t + Double(eighth) * period / 2
                    for pitch in [64, 67, 71] {
                        notes.append(NoteEvent(startTime: s, endTime: s + 0.45 * period, pitch: pitch, amplitude: 0.5))
                    }
                }
            }
            let duration = beats.last! + 1
            let kicks = fourOnTheFloor ? beats : beats.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
            let snares = beats.enumerated().filter { !$0.offset.isMultiple(of: 2) }.map(\.element)
            let hats = beats.flatMap { [$0, $0 + period / 2] }
            let onsets = AudioOnsets(onsets: spikes(notes.map(\.startTime), 1, duration: duration),
                                     percussion: .init(onsets: spikes(hats, 1, duration: duration),
                                                       low: spikes(kicks, 1, duration: duration),
                                                       mid: spikes(snares, 1, duration: duration)))
            let result = BeatTracker.track(notes: notes, duration: duration, beatsPerBar: nil, audioOnsets: onsets)
            XCTAssertEqual(result.medianBPM, bpm, accuracy: 1.5, "\(bpm) BPM")
            XCTAssertGreaterThan(onBeat(result, beats), 0.95)
        }

        let period = 60.0 / 150
        var notes: [NoteEvent] = []
        var beats: [Double] = []
        for k in 0..<96 {
            let t = 0.5 + Double(k) * period
            beats.append(t)
            if k.isMultiple(of: 3) {
                notes.append(NoteEvent(startTime: t, endTime: t + 0.9 * period, pitch: 43 + (k / 12) % 2 * 5, amplitude: 0.7))
            } else {
                for pitch in [59, 62, 67] {
                    notes.append(NoteEvent(startTime: t, endTime: t + 0.8 * period, pitch: pitch, amplitude: 0.5))
                }
            }
        }
        let waltz = BeatTracker.track(notes: notes, duration: beats.last! + 1, beatsPerBar: nil)
        XCTAssertEqual(waltz.medianBPM, 150, accuracy: 1.5)
        XCTAssertEqual(waltz.beatsPerBar, 3)
    }

    /// The user's ½× and 2× re-track from the tempo shown: after a Song mode
    /// grid is halved, 2× gives back the eighths.
    func testDoubleTempoAfterHalvingGivesTheEighthsBack() {
        let period = 60.0 / 82
        var notes: [NoteEvent] = []
        for k in 0..<64 {
            let t = 0.5 + Double(k) * period
            notes.append(NoteEvent(startTime: t, endTime: t + 0.95 * period, pitch: 43 + (k / 4) % 2 * 5, amplitude: 0.6))
            for eighth in 0..<2 {
                let s = t + Double(eighth) * period / 2
                for pitch in [60, 64, 67] {
                    notes.append(NoteEvent(startTime: s, endTime: s + 0.45 * period, pitch: pitch, amplitude: 0.5))
                }
            }
        }
        let duration = 0.5 + 64 * period + 1
        let song = AudioOnsets(onsets: spikes(notes.map(\.startTime), 1, duration: duration),
                               chroma: chroma(of: notes, duration: duration))
        XCTAssertEqual(BeatTracker.track(notes: notes, duration: duration, beatsPerBar: nil, audioOnsets: song).medianBPM,
                       82, accuracy: 1.5)
        XCTAssertEqual(BeatTracker.track(notes: notes, duration: duration, beatsPerBar: nil, tempoOctave: 1,
                                         audioOnsets: song).medianBPM, 164, accuracy: 4)
    }

    // MARK: - BarPhase (Song mode's bar lines from the audio's chord changes)

    /// Beats at 120 BPM and the tonal part's chroma (`OnsetEnvelope.chromaFPS`)
    /// with a new chord on each of `changes` (beat indices), the chords cycling
    /// through C, F, G and A minor.
    private func barPhaseTake(beats count: Int, changes: [Int]) -> (beats: [Double], chroma: [Float]) {
        let beats = (0..<count).map { 0.5 + Double($0) * 0.5 }
        let fps = OnsetEnvelope.chromaFPS
        let frames = Int((beats.last! + 1) * fps)
        let pitchClasses = [[0, 4, 7], [5, 9, 0], [7, 11, 2], [9, 0, 4]]
        var chroma = [Float](repeating: 0.05, count: frames * 12)
        for f in 0..<frames {
            let t = Double(f) / fps
            let k = changes.filter { beats[$0] <= t }.count
            for pc in pitchClasses[k % pitchClasses.count] { chroma[f * 12 + pc] = 1 }
        }
        return (beats, chroma)
    }

    private func downbeats(_ positions: [Int]) -> [Int] { positions.indices.filter { positions[$0] == 0 } }

    /// The chord changes on every bar line put beat 1 there, though the bass
    /// comes in a beat early and holds over the bar line (Still D.R.E.) and the
    /// bar-pointer model put beat 1 on the bass; with or without those bass
    /// notes.
    func testBarPhaseFollowsTheChordsOverAnAnticipatingBass() {
        let bars = 24
        let (beats, chroma) = barPhaseTake(beats: bars * 4, changes: Array(stride(from: 4, to: bars * 4, by: 4)))
        let bass = stride(from: 3, to: bars * 4, by: 4).map {
            NoteEvent(startTime: beats[$0], endTime: beats[$0] + 0.9, pitch: 36, amplitude: 0.8, voice: .bass)
        }
        let onTheBass = beats.indices.map { ($0 + 1) % 4 }   // beat 1 on the bass notes
        for notes in [bass, []] {
            let positions = BarPhase.positions(beats: beats, beatsPerBar: 4, notes: notes, chroma: chroma, decoded: onTheBass)
            XCTAssertEqual(downbeats(positions), Array(stride(from: 0, to: bars * 4, by: 4)), "\(notes.count) bass notes")
        }
    }

    /// A 2/4 bar after twelve bars moves the bar lines with it; one bar whose
    /// chord changes on beat 3 does not, because one bar's evidence does not
    /// pay for two half-bar moves.
    func testBarPhaseMovesWithAHalfBarOnlyWhenSeveralBarsSaySo() {
        let cut = Array(stride(from: 4, through: 48, by: 4)) + Array(stride(from: 50, to: 98, by: 4))
        let (beats, chroma) = barPhaseTake(beats: 98, changes: cut)
        let positions = BarPhase.positions(beats: beats, beatsPerBar: 4, notes: [], chroma: chroma,
                                           decoded: beats.indices.map { $0 % 4 })
        XCTAssertEqual(downbeats(positions), [0] + cut)

        let once = Array(stride(from: 4, to: 96, by: 4)).map { $0 == 48 ? 50 : $0 }
        let (beats2, chroma2) = barPhaseTake(beats: 96, changes: once)
        let kept = BarPhase.positions(beats: beats2, beatsPerBar: 4, notes: [], chroma: chroma2,
                                      decoded: beats2.indices.map { $0 % 4 })
        XCTAssertEqual(downbeats(kept), Array(stride(from: 0, to: 96, by: 4)))
    }

    /// Where the evidence for the bar lines is strong the section margin is
    /// large, and the runner-up is named; with nothing that varies (a held
    /// chord, no bass) the bar-pointer model's bar lines stay.
    func testBarPhaseSectionsAndNoEvidence() {
        let (beats, chroma) = barPhaseTake(beats: 64, changes: Array(stride(from: 4, to: 64, by: 4)))
        let positions = beats.indices.map { $0 % 4 }
        let ev = BarPhase.evidence(beats: beats, notes: [], chroma: chroma)!
        let sections = BarPhase.sections(evidence: ev, positions: positions, beatsPerBar: 4)
        XCTAssertEqual(sections.count, 2)
        XCTAssertGreaterThan(sections[0].margin, 10)
        let shifted = BarPhase.sections(evidence: ev, positions: beats.indices.map { ($0 + 2) % 4 }, beatsPerBar: 4)
        XCTAssertLessThan(shifted[0].margin, -10)
        XCTAssertEqual(shifted[0].runnerUpShift, 2)

        let (flatBeats, flat) = barPhaseTake(beats: 64, changes: [])
        let decoded = flatBeats.indices.map { ($0 + 1) % 4 }
        XCTAssertNil(BarPhase.evidence(beats: flatBeats, notes: [], chroma: flat))
        XCTAssertEqual(BarPhase.positions(beats: flatBeats, beatsPerBar: 4, notes: [], chroma: flat, decoded: decoded), decoded)
    }

    /// The tracker reads the chroma for the bar lines only in 4/4 and only
    /// when it has one (Song mode): Piano mode's grid is the bar-pointer
    /// model's, as is a waltz's.
    func testTrackUsesBarPhaseOnlyWithChromaInFourFour() {
        let chords = [[60, 64, 67], [65, 69, 72], [67, 71, 74], [57, 60, 64]]
        for meter in [3, 4] {
            var notes: [NoteEvent] = []
            for bar in 0..<16 {
                let start = 0.5 + Double(bar * meter) * 0.5
                let chord = chords[bar % chords.count]
                notes.append(NoteEvent(startTime: start, endTime: start + 0.5 * Double(meter) - 0.05, pitch: chord[0] - 24, amplitude: 0.8))
                for beat in 0..<meter {
                    for pitch in chord {
                        notes.append(NoteEvent(startTime: start + Double(beat) * 0.5, endTime: start + Double(beat) * 0.5 + 0.4,
                                               pitch: pitch, amplitude: 0.6))
                    }
                }
            }
            let duration = 0.5 + Double(16 * meter) * 0.5 + 1
            let plain = BeatTracker.track(notes: notes, duration: duration, beatsPerBar: meter)
            let off = BeatTracker.track(notes: notes, duration: duration, beatsPerBar: meter,
                                        audioOnsets: AudioOnsets(onsets: [], chroma: nil), barPhase: true)
            XCTAssertEqual(plain.barPositions, off.barPositions, "no chroma, \(meter)/4")
            // A chroma whose chords change a beat after the bar lines.
            let (_, late) = barPhaseTake(beats: 16 * meter + 2, changes: Array(stride(from: 1, to: 16 * meter, by: meter)))
            let withChroma = BeatTracker.track(notes: notes, duration: duration, beatsPerBar: meter,
                                               audioOnsets: AudioOnsets(onsets: [], chroma: late))
            if meter == 3 {
                XCTAssertEqual(withChroma.barPositions, plain.barPositions, "3/4 keeps the bar-pointer bar lines")
            } else {
                XCTAssertNotEqual(withChroma.barPositions, plain.barPositions, "4/4 reads the chroma")
            }
        }
    }

    /// The user's note on beat 1 (the Downbeat note setting) is evidence for
    /// BarPhase too, and outweighs the chord changes: chords changing on
    /// every other bar line's beat 1 and a D on every beat 3 put the bar
    /// lines on the D once the D is the hint. A hinted note never played on a
    /// beat changes nothing.
    func testBarPhaseHonoursTheDownbeatNote() {
        let bars = 24
        let (beats, chroma) = barPhaseTake(beats: bars * 4, changes: Array(stride(from: 4, to: bars * 4, by: 4)))
        let notes = beats.indices.map {
            NoteEvent(startTime: beats[$0], endTime: beats[$0] + 0.45, pitch: $0 % 4 == 2 ? 74 : 76, amplitude: 0.7,
                      voice: .melody)
        }
        let decoded = beats.indices.map { $0 % 4 }
        func firstBeats(hint: Int?) -> [Int] {
            downbeats(BarPhase.positions(beats: beats, beatsPerBar: 4, notes: notes, chroma: chroma, decoded: decoded,
                                         downbeatPitchClass: hint))
        }
        XCTAssertEqual(firstBeats(hint: nil), Array(stride(from: 0, to: bars * 4, by: 4)), "the chords decide")
        XCTAssertEqual(firstBeats(hint: 2), Array(stride(from: 2, to: bars * 4, by: 4)), "the D is beat 1")
        XCTAssertEqual(firstBeats(hint: 1), firstBeats(hint: nil), "a note never played")
    }

    /// The tracker passes the hint to BarPhase in a Song mode 4/4 take: a
    /// low A struck on every beat 1 under chords whose sound changes a beat
    /// later. Without the hint the bar lines follow the chords; with A as the
    /// downbeat note they are on the A, as the bar-pointer model has them.
    func testSongModeBarLinesFollowTheDownbeatNote() {
        let chords = [[60, 64, 67], [65, 69, 72], [67, 71, 74], [57, 60, 64]]
        var notes: [NoteEvent] = []
        var onA: [Double] = []
        for bar in 0..<16 {
            let start = 0.5 + Double(bar * 4) * 0.5
            onA.append(start)
            notes.append(NoteEvent(startTime: start, endTime: start + 1.9, pitch: 33, amplitude: 0.8))
            for beat in 0..<4 {
                for pitch in chords[bar % chords.count] {
                    notes.append(NoteEvent(startTime: start + Double(beat) * 0.5, endTime: start + Double(beat) * 0.5 + 0.4,
                                           pitch: pitch, amplitude: 0.6))
                }
            }
        }
        let duration = 0.5 + 64 * 0.5 + 1
        let (_, late) = barPhaseTake(beats: 66, changes: Array(stride(from: 1, to: 64, by: 4)))
        func barLines(hint: Int?, barPhase: Bool = true) -> [Double] {
            let r = BeatTracker.track(notes: notes, duration: duration, beatsPerBar: 4, downbeatPitchClass: hint,
                                      audioOnsets: AudioOnsets(onsets: [], chroma: late), barPhase: barPhase)
            return zip(r.beats, r.barPositions).filter { $0.1 == 0 }.map(\.0)
        }
        func onTheA(_ lines: [Double]) -> Int { lines.filter { t in onA.contains { abs($0 - t) <= 0.07 } }.count }
        XCTAssertEqual(onTheA(barLines(hint: nil)), 0, "the chords' bar lines, a beat after the A")
        let hinted = barLines(hint: 9)
        let played = hinted.filter { $0 < onA.last! + 1 }   // the grid runs on past the last bar
        XCTAssertEqual(onTheA(played), played.count)
        XCTAssertGreaterThanOrEqual(played.count, 15)
        XCTAssertEqual(hinted, barLines(hint: 9, barPhase: false), "as the bar-pointer model has them")
    }
}
