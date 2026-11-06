import XCTest
@testable import Semitone

/// BassStage on synthetic takes: a bass note the engines wrote late, Basic
/// Pitch's late copy of it, a re-onset with no attack, fast repeats, a kick
/// drum, gated staccato sub-bass notes, a kick just before a bass note, and
/// bass notes written an octave high or low.
final class BassStageTests: XCTestCase {
    private let rate = BPConstants.sampleRate

    /// A tone of `pitch` with four harmonics from `start` to `end` seconds,
    /// decaying with time constant `decay`, added into `x`.
    private func addTone(_ x: inout [Float], pitch: Int, start: Double, end: Double, decay: Double = 2,
                         harmonics: Int = 4) {
        let f0 = 440 * pow(2, Double(pitch - 69) / 12)
        for i in Int(start * rate)..<min(x.count, Int(end * rate)) {
            let t = Double(i) / rate - start
            var v = 0.0
            for h in 1...harmonics { v += sin(2 * .pi * f0 * Double(h) * t) / Double(h) }
            x[i] += Float(0.3 * v * exp(-t / decay))
        }
    }

    private func bass(_ start: Double, _ end: Double, _ pitch: Int) -> NoteEvent {
        NoteEvent(startTime: start, endTime: end, pitch: pitch, amplitude: 0.6, voice: .bass)
    }

    func testLateBassOnsetMovesToTheAttackAndItsLateCopyMerges() {
        var audio = [Float](repeating: 0, count: Int(3 * rate))
        addTone(&audio, pitch: 28, start: 1.0, end: 2.5)          // E1
        addTone(&audio, pitch: 55, start: 1.0, end: 2.0)          // G3, a chord note
        let chord = NoteEvent(startTime: 1.0, endTime: 2.0, pitch: 55, amplitude: 0.5, voice: .chords)
        let notes = [bass(1.09, 2.5, 28), bass(1.13, 2.4, 28), chord]
        let out = BassStage.refine(notes, audio: audio, sampleRate: rate)
        let low = out.filter { $0.voice == .bass }
        XCTAssertEqual(low.count, 1, "The late copy merges into the corrected note.")
        XCTAssertEqual(low.first?.startTime ?? 0, 1.0, accuracy: 0.025)
        XCTAssertEqual(low.first?.endTime, 2.5)
        XCTAssertTrue(out.contains(chord), "Notes above E3 in other parts are left alone.")
    }

    func testOnTimeBassNoteStays() {
        var audio = [Float](repeating: 0, count: Int(3 * rate))
        addTone(&audio, pitch: 33, start: 1.0, end: 2.0)
        let note = bass(1.005, 2.0, 33)
        XCTAssertEqual(BassStage.refine([note], audio: audio, sampleRate: rate), [note])
    }

    func testReonsetWithoutAttackMergesIntoTheHeldNote() {
        var audio = [Float](repeating: 0, count: Int(3 * rate))
        addTone(&audio, pitch: 28, start: 0.5, end: 2.5, decay: 20)
        let out = BassStage.refine([bass(0.5, 1.2, 28), bass(1.5, 2.5, 28)], audio: audio, sampleRate: rate)
        XCTAssertEqual(out, [bass(0.5, 2.5, 28)])
    }

    /// Staccato notes 100 ms apart (16ths at 150 BPM): each one's search
    /// holds the previous note's attack, which is steeper than its own.
    func testFastRepeatedBassNotesStaySeparate() {
        var audio = [Float](repeating: 0, count: Int(3 * rate))
        var notes: [NoteEvent] = []
        for k in 0..<15 {
            let start = 1.0 + Double(k) * 0.1
            addTone(&audio, pitch: 40, start: start, end: start + 0.09, decay: 0.5)
            notes.append(bass(start, start + 0.09, 40))
        }
        XCTAssertEqual(BassStage.refine(notes, audio: audio, sampleRate: rate), notes)
    }

    func testRestruckBassNoteStaysTwoNotes() {
        var audio = [Float](repeating: 0, count: Int(3 * rate))
        addTone(&audio, pitch: 28, start: 0.5, end: 1.3)
        addTone(&audio, pitch: 28, start: 1.5, end: 2.5)
        let notes = [bass(0.5, 1.3, 28), bass(1.5, 2.5, 28)]
        XCTAssertEqual(BassStage.refine(notes, audio: audio, sampleRate: rate), notes)
    }

    /// Short, nearly pure sub-bass notes that stop dead are kept: a kick's
    /// thump decays from its attack instead of holding its level.
    func testGatedStaccatoSubBassNotesStay() {
        var audio = [Float](repeating: 0, count: Int(3 * rate))
        var notes: [NoteEvent] = []
        for start in [0.5, 1.0, 1.5, 2.0] {
            addTone(&audio, pitch: 28, start: start, end: start + 0.12, decay: 5, harmonics: 1)
            notes.append(bass(start, start + 0.12, 28))
        }
        XCTAssertEqual(BassStage.refine(notes, audio: audio, sampleRate: rate), notes)
    }

    /// A kick a sixteenth (140 ms) before a bass note the engine wrote a
    /// little early: the kick's thump is the steepest rise at the note's
    /// fundamental in the search, but it dies away and the note attacks
    /// again, so the note keeps its onset instead of moving onto the kick.
    func testKickJustBeforeABassNoteDoesNotTakeItsOnset() {
        var audio = [Float](repeating: 0, count: Int(3 * rate))
        for _ in 0..<3 { addTone(&audio, pitch: 31, start: 1.0, end: 1.3, decay: 0.03, harmonics: 1) }   // the kick
        addTone(&audio, pitch: 31, start: 1.16, end: 2.0, decay: 1)                                    // G1
        let note = bass(1.12, 2.0, 31)
        XCTAssertEqual(BassStage.refine([note], audio: audio, sampleRate: rate), [note])
    }

    func testKickDrumThumpIsDropped() {
        var audio = [Float](repeating: 0, count: Int(3 * rate))
        addTone(&audio, pitch: 31, start: 1.0, end: 1.6, decay: 0.04, harmonics: 1)   // a 49 Hz thump
        XCTAssertEqual(BassStage.refine([bass(1.0, 1.3, 31)], audio: audio, sampleRate: rate), [])
    }

    /// A bass-part note too high for the partial analysis (C6, 1047 Hz) is
    /// left as it is, not read past the end of an empty level curve.
    func testBassNoteAboveThePartialRangeIsLeftAlone() {
        var audio = [Float](repeating: 0, count: Int(3 * rate))
        addTone(&audio, pitch: 84, start: 0.5, end: 2.5)
        let notes = [bass(0.5, 1.2, 84), bass(1.5, 2.5, 84)]
        XCTAssertEqual(BassStage.refine(notes, audio: audio, sampleRate: rate), notes)
    }

    /// A bass tone as a mix carries it: the second harmonic louder than the
    /// fundamental, a third harmonic, the fourth weaker.
    private func addMixBass(_ x: inout [Float], pitch: Int, start: Double, end: Double) {
        let f0 = 440 * pow(2, Double(pitch - 69) / 12)
        let partials: [Double] = [0.5, 1.0, 0.6, 0.3]
        for i in Int(start * rate)..<min(x.count, Int(end * rate)) {
            let t = Double(i) / rate - start
            var v = 0.0
            for (h, a) in partials.enumerated() { v += a * sin(2 * .pi * f0 * Double(h + 1) * t) }
            x[i] += Float(0.2 * v * exp(-t / 2))
        }
    }

    /// Nine bass notes on E1-B1, 0.5 s apart from 0.5 s: the line's register.
    private func lowLine(_ x: inout [Float]) -> [NoteEvent] {
        (0..<9).map { k in
            let start = 0.5 + 0.5 * Double(k), pitch = [28, 31, 33, 35][k % 4]
            addMixBass(&x, pitch: pitch, start: start, end: start + 0.4)
            return bass(start, start + 0.4, pitch)
        }
    }

    /// The note moves down; the pitch the engine heard stays as a chord note
    /// (the audio cannot tell the bass's second harmonic from a doubling).
    func testBassNoteWrittenAnOctaveHighMovesDown() {
        var audio = [Float](repeating: 0, count: Int(8 * rate))
        let line = lowLine(&audio)
        addMixBass(&audio, pitch: 28, start: 6.0, end: 6.4)         // E1, written as E2
        let out = BassStage.refine(line + [bass(6.0, 6.4, 40)], audio: audio, sampleRate: rate)
        XCTAssertEqual(out.filter { $0.startTime == 6.0 },
                       [bass(6.0, 6.4, 28), bass(6.0, 6.4, 40).with(voice: .chords)])
        XCTAssertEqual(out.filter { $0.startTime < 6.0 }, line, "The line's own notes keep their octave.")
    }

    /// The phrase decides together: an E2 with E1 sounding under it stays
    /// when the E2s around it have nothing below (a kick or another part
    /// under one note is no evidence for the line's octave).
    func testOctaveIsDecidedOverThePhrase() {
        var audio = [Float](repeating: 0, count: Int(10 * rate))
        let line = lowLine(&audio)
        addTone(&audio, pitch: 40, start: 5.0, end: 5.4)            // real E2s: nothing at E1
        addTone(&audio, pitch: 40, start: 5.5, end: 5.9)
        addMixBass(&audio, pitch: 28, start: 6.0, end: 6.4)         // E1 under this one
        let written = [bass(5.0, 5.4, 40), bass(5.5, 5.9, 40), bass(6.0, 6.4, 40)]
        let out = BassStage.refine(line + written, audio: audio, sampleRate: rate)
        XCTAssertEqual(out.filter { $0.startTime >= 5 }, written)
    }

    /// A note written an octave low where nothing sounds at its own pitch
    /// (the engines hear the missing fundamental of a bass note and a fifth
    /// above it) moves up into the line's register.
    func testBassNoteWrittenAnOctaveLowMovesUp() {
        var audio = [Float](repeating: 0, count: Int(8 * rate))
        let line = (0..<9).map { k in
            let start = 0.5 + 0.5 * Double(k), pitch = [40, 43, 45, 47][k % 4]
            addMixBass(&audio, pitch: pitch, start: start, end: start + 0.4)
            return bass(start, start + 0.4, pitch)
        }
        addTone(&audio, pitch: 45, start: 6.0, end: 6.4)            // A2 (and a fifth above), written as A1
        addTone(&audio, pitch: 52, start: 6.0, end: 6.4)
        let out = BassStage.refine(line + [bass(6.0, 6.4, 33)], audio: audio, sampleRate: rate)
        XCTAssertEqual(out.filter { $0.startTime == 6.0 }, [bass(6.0, 6.4, 45)])
        XCTAssertEqual(out.filter { $0.startTime < 6.0 }, line, "The line's own notes keep their octave.")
    }

    func testBassNoteWithNothingBelowStays() {
        var audio = [Float](repeating: 0, count: Int(8 * rate))
        let line = lowLine(&audio)
        addTone(&audio, pitch: 40, start: 6.0, end: 6.4)            // a real E2: nothing at E1
        let out = BassStage.refine(line + [bass(6.0, 6.4, 40)], audio: audio, sampleRate: rate)
        XCTAssertEqual(out.filter { $0.startTime == 6.0 }, [bass(6.0, 6.4, 40)])
    }

    /// A line that keeps to E2-B2: an octave under one of its notes would
    /// fall below everything it plays, so the note stays.
    func testOctaveCheckKeepsToTheLinesRegister() {
        var audio = [Float](repeating: 0, count: Int(8 * rate))
        let line = (0..<9).map { k in
            let start = 0.5 + 0.5 * Double(k), pitch = [40, 43, 45, 47][k % 4]
            addMixBass(&audio, pitch: pitch, start: start, end: start + 0.4)
            return bass(start, start + 0.4, pitch)
        }
        addMixBass(&audio, pitch: 38, start: 6.0, end: 6.4)         // D2, written as D3
        let out = BassStage.refine(line + [bass(6.0, 6.4, 50)], audio: audio, sampleRate: rate)
        XCTAssertEqual(out.filter { $0.startTime == 6.0 }, [bass(6.0, 6.4, 50)])
    }
}
