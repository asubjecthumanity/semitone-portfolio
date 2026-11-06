import XCTest
@testable import Semitone

/// The beat-synchronous chord decoder on synthetic notes and a fixed grid
/// (0.5 s beats, bars of four), so no beat tracking is involved.
final class HarmonyStageTests: XCTestCase {
    private func grid(beats count: Int = 16) -> BeatGrid {
        let beats = (0..<count).map { Double($0) * 0.5 }
        return BeatGrid(beats: beats, downbeats: stride(from: 0, to: count, by: 4).map { beats[$0] },
                        beatsPerMeasure: 4, bpm: 120)
    }

    private func held(_ pitches: [Int], from start: Double, to end: Double, amplitude: Double = 0.8,
                      voice: Voice = .none) -> [NoteEvent] {
        pitches.map { NoteEvent(startTime: start, endTime: end, pitch: $0, amplitude: amplitude, voice: voice) }
    }

    /// The bass only favours the chord it is the root of: a major triad over
    /// its third stays that triad, written as a slash chord.
    func testTriadOverItsThirdKeepsItsRoot() {
        let notes = held([39], from: 0, to: 4, amplitude: 0.6, voice: .bass)
            + held([59, 63, 66], from: 0, to: 4, voice: .chords)
        XCTAssertEqual(HarmonyStage.chords(notes: notes, grid: grid()).map(\.label), ["B/D#"])
    }

    /// Plain triads, a bar each, come out as triads and change on the bar lines.
    func testTriadProgressionChangesOnTheBars() {
        let notes = held([48, 60, 64, 67], from: 0, to: 2) + held([45, 60, 64, 69], from: 2, to: 4)
            + held([41, 60, 65, 69], from: 4, to: 6) + held([43, 62, 67, 71], from: 6, to: 8)
        let chords = HarmonyStage.chords(notes: notes, grid: grid())
        XCTAssertEqual(chords.map(\.label), ["C", "Am", "F", "G"])
        XCTAssertEqual(chords.map(\.startTime), [0, 2, 4, 6])
    }

    /// A quiet note is still a chord tone: a soft third held under a loud,
    /// re-struck root and fifth decides major or minor. (It is under 15% of
    /// the notes, the share the chroma used to leave out.)
    func testQuietThirdDecidesTheQuality() {
        let notes = (0..<8).flatMap { k in
            held([45, 64, 69], from: Double(k) * 0.5, to: Double(k) * 0.5 + 0.45, amplitude: 0.9)
        } + held([60], from: 0, to: 4, amplitude: 0.15)
        XCTAssertEqual(HarmonyStage.chords(notes: notes, grid: grid()).map(\.label), ["Am"])
    }

    /// A minor seventh holds its relative major triad (Fm7 = F + Ab-C-Eb);
    /// a root in the bass, even a quiet one, names the chord from it rather
    /// than as Ab6.
    func testQuietRootUnderMinorSeventhNamesIt() {
        let notes = held([41], from: 0, to: 4, amplitude: 0.3, voice: .bass)
            + held([56, 60, 63], from: 0, to: 4, voice: .chords)
        XCTAssertEqual(HarmonyStage.chords(notes: notes, grid: grid()).map(\.label), ["Fm7"])
    }

    /// Notes heard but not shown (Song mode's preview notes) count toward
    /// the chord: here they hold the third that decides major or minor.
    func testAlsoHeardNotesCountTowardTheChord() {
        let shown = held([45, 52, 57], from: 0, to: 4)
        XCTAssertEqual(HarmonyStage.chords(notes: shown, grid: grid()).map(\.label), ["A"])
        let chords = HarmonyStage.chords(notes: shown, grid: grid(), alsoHeard: held([60], from: 0, to: 4, amplitude: 0.5))
        XCTAssertEqual(chords.map(\.label), ["Am"])
        XCTAssertEqual(chords.map(\.endTime), [4])
    }

    /// A first inversion keeps its root: C over E is C/E, not E minor, even
    /// with the bass bonus that tells a minor seventh from its relative
    /// major, and with a passing B (the fifth of E minor) on one beat.
    func testFirstInversionKeepsItsRoot() {
        let notes = held([40], from: 0, to: 4, amplitude: 0.6, voice: .bass)
            + held([60, 64, 67], from: 0, to: 4, voice: .chords)
        XCTAssertEqual(HarmonyStage.chords(notes: notes, grid: grid()).map(\.label), ["C/E"])
        let passing = notes + held([71], from: 1, to: 1.5, voice: .melody)
        XCTAssertEqual(HarmonyStage.chords(notes: passing, grid: grid()).map(\.label), ["C/E"])
    }

    /// A pitch-class chroma at `OnsetEnvelope.chromaFPS` holding `classes`
    /// equally from `start` to `end` seconds, and nothing elsewhere.
    private func audio(_ classes: [Int], from start: Double, to end: Double, seconds: Double = 8) -> AudioOnsets {
        let fps = OnsetEnvelope.chromaFPS
        var chroma = [Float](repeating: 0, count: Int(seconds * fps) * 12)
        for f in Int(start * fps)..<Int(end * fps) { for pc in classes { chroma[f * 12 + pc] = 1 } }
        return AudioOnsets(onsets: [], chroma: chroma)
    }

    /// Song mode: where the notes stop but the tonal part still sounds (a
    /// pad, a sampled loop the engines missed), the chord comes from the
    /// sound; where both are silent there is none.
    func testAudioNamesTheChordWhereTheNotesAreSilent() {
        let notes = held([48, 60, 64, 67], from: 0, to: 2)
        let am = audio([9, 0, 4], from: 2, to: 6)
        XCTAssertEqual(HarmonyStage.chords(notes: notes, grid: grid()).map(\.label), ["C"])
        let chords = HarmonyStage.chords(notes: notes, grid: grid(), audio: am)
        XCTAssertEqual(chords.map(\.label), ["C", "Am"])
        XCTAssertEqual(chords.map(\.startTime), [0, 2])
        XCTAssertEqual(chords.last?.endTime ?? 0, 6, accuracy: 1e-9)
    }

    /// The sound counts as half a typical beat of notes: a thin beat (a lone
    /// bass note) takes its quality from it, a full chord keeps its own.
    func testAudioWeighsLessThanAFullChord() {
        let full = (0..<8).flatMap { k in held([48, 60, 64, 67], from: Double(k) * 0.5, to: Double(k) * 0.5 + 0.5) }
        XCTAssertEqual(HarmonyStage.chords(notes: full, grid: grid(), audio: audio([0, 3, 7], from: 0, to: 4)).map(\.label), ["C"])
        let minorSound = audio([0, 3, 7], from: 0, to: 8)
        let thin = full + (8..<16).flatMap { k in held([48], from: Double(k) * 0.5, to: Double(k) * 0.5 + 0.5, amplitude: 0.3) }
        XCTAssertEqual(HarmonyStage.chords(notes: thin, grid: grid(), audio: minorSound).map(\.label), ["C", "Cm"])
    }

    /// Without an audio chroma (Piano mode) the chords are the notes' alone.
    func testNoAudioChromaKeepsTheNotesChords() {
        let notes = held([48, 60, 64, 67], from: 0, to: 2)
        XCTAssertEqual(HarmonyStage.chords(notes: notes, grid: grid(), audio: AudioOnsets(onsets: [])),
                       HarmonyStage.chords(notes: notes, grid: grid()))
    }

    /// The tonal chroma reads each semitone in the take's tuning: a tone 45
    /// cents sharp of A4 is all A when the take is 45 cents sharp, while on
    /// the A440 grid it also lights up A#, whose band starts 5 cents above it
    /// (about 0.96 / 0.01 against 0.69 / 0.29).
    func testTonalChromaFollowsTheTuning() {
        let rate = BPConstants.sampleRate
        let f = 440 * pow(2, 45.0 / 1200)
        let tone = (0..<Int(2 * rate)).map { Float(0.3 * sin(2 * .pi * f * Double($0) / rate)) }
        func share(_ chroma: [Float], _ pc: Int) -> Float {
            let frames = chroma.count / 12
            let total = (0..<frames).reduce(Float(0)) { s, i in s + (0..<12).reduce(0) { $0 + chroma[i * 12 + $1] } }
            return (0..<frames).reduce(0) { $0 + chroma[$1 * 12 + pc] } / total
        }
        let tuned = OnsetEnvelope.tonalChroma(tone, sampleRate: rate, tuningCents: TuningEstimate(cents: 45).namingOffset(at:))
        XCTAssertEqual(tuned.count, Int(2 * OnsetEnvelope.chromaFPS) * 12)
        XCTAssertGreaterThan(share(tuned, 9), 0.6)
        XCTAssertGreaterThan(share(tuned, 9), 4 * share(tuned, 10))
        let plain = OnsetEnvelope.tonalChroma(tone, sampleRate: rate)
        XCTAssertGreaterThan(share(plain, 10), 0.2)
    }
}

/// The notes Song mode's chords read beside the notes shown, after an edit.
final class HarmonyNotesEditTests: XCTestCase {
    private func note(_ pitch: Int, _ start: Double, _ end: Double) -> NoteEvent {
        NoteEvent(startTime: start, endTime: end, pitch: pitch, amplitude: 0.5)
    }

    /// An AI cleanup's removed ghost no longer counts through its preview
    /// copy; notes it kept or merged still do.
    func testRemovedNotesLeaveTheHarmony() {
        let ghost = note(76, 0, 1), root = note(48, 0, 2), a = note(60, 0, 1), b = note(60, 1.05, 2)
        let before = [ghost, root, a, b]
        let after = [root, note(60, 0, 2)]   // ghost removed, a and b merged
        let heard = [note(76, 0.02, 0.9), note(48, 0, 2), note(60, 0, 2), note(67, 0, 2)]
        XCTAssertEqual(TakeAnalysis.harmonyNotes(heard, before: before, after: after).map(\.pitch), [48, 60, 67])
        XCTAssertEqual(TakeAnalysis.harmonyNotes(heard, before: before, after: before), heard)
    }
}

