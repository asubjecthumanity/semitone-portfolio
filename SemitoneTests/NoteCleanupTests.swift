import XCTest
@testable import Semitone

/// NoteCleanup on synthetic takes: a held synth note that pumps, a string that
/// is really re-struck, a note Basic Pitch heard late, a note that opens the
/// take and a fast repeat.
final class NoteCleanupTests: XCTestCase {
    private let rate = BPConstants.sampleRate

    /// A tone with six harmonics at `pitch`, gated by `envelope(t)` (seconds into the take).
    private func tone(pitch: Int, seconds: Double, envelope: (Double) -> Double) -> [Float] {
        let f0 = 440 * pow(2, Double(pitch - 69) / 12)
        return (0..<Int(seconds * rate)).map { i in
            let t = Double(i) / rate
            var v = 0.0
            for h in 1...6 { v += sin(2 * .pi * f0 * Double(h) * t) / Double(h) }
            return Float(0.2 * envelope(t) * v)
        }
    }

    private func note(_ start: Double, _ end: Double, _ pitch: Int) -> NoteEvent {
        NoteEvent(startTime: start, endTime: end, pitch: pitch, amplitude: 0.5)
    }

    /// One key held from 0.2 s to 3.2 s, ducked to a third and released every
    /// 0.36 s like a sidechained pad. The engines read every swell as a note.
    func testPumpingHeldNoteMergesIntoOneNote() {
        let audio = tone(pitch: 60, seconds: 3.6) { t in
            guard t >= 0.2, t < 3.2 else { return 0 }
            let attack = min(1, (t - 0.2) / 0.005)
            let phase = (t - 0.2).truncatingRemainder(dividingBy: 0.36)
            let duck = phase < 0.03 ? 1 - phase / 0.03 * 0.67 : 0.33 + 0.67 * min(1, (phase - 0.03) / 0.25)
            return attack * duck
        }
        var notes = [note(0.2, 0.5, 60)]
        var t = 0.2 + 0.36 + 0.15
        while t < 3.0 { notes.append(note(t, t + 0.2, 60)); t += 0.36 }
        let result = NoteCleanup.verify(notes, audio22k: audio, transkun: [], basicPitch: notes)
        XCTAssertEqual(result.notes.count, 1, "\(result.notes)")
        XCTAssertEqual(result.notes.first?.startTime ?? -1, 0.2, accuracy: 0.001)
        XCTAssertGreaterThan(result.notes.first?.endTime ?? 0, 2.9)
    }

    /// A plucked string struck at 0.3 s and again at 1.3 s, while still
    /// ringing: both onsets stay.
    func testRealRestrikeSurvives() {
        let audio = tone(pitch: 57, seconds: 2.5) { t in
            func pluck(_ at: Double) -> Double { t < at ? 0 : min(1, (t - at) / 0.002) * exp(-(t - at) / 0.8) }
            return t < 1.3 ? pluck(0.3) : 0.35 * pluck(0.3) + pluck(1.3)
        }
        let notes = [note(0.3, 1.3, 57), note(1.3, 2.3, 57)]
        let result = NoteCleanup.verify(notes, audio22k: audio, transkun: [], basicPitch: notes)
        XCTAssertEqual(result.notes.map(\.startTime), [0.3, 1.3])
    }

    /// Basic Pitch wrote a note 120 ms after its attack: it moves to the
    /// attack. A note Transkun started at the same place would stay.
    func testLateBasicPitchOnsetMovesToItsAttack() {
        let audio = tone(pitch: 45, seconds: 2) { t in t < 0.5 ? 0 : min(1, (t - 0.5) / 0.003) * exp(-(t - 0.5) / 1.5) }
        let late = note(0.62, 1.6, 45)
        let moved = NoteCleanup.verify([late], audio22k: audio, transkun: [], basicPitch: [late])
        XCTAssertEqual(moved.report.retimed, 1)
        XCTAssertEqual(moved.notes.first?.startTime ?? -1, 0.5, accuracy: 0.03)

        let struck = NoteCleanup.verify([late], audio22k: audio, transkun: [late], basicPitch: [])
        XCTAssertEqual(struck.report.retimed, 0)
    }

    /// Notes both engines started are kept as they are, attack or not.
    func testNotesBothEnginesHeardAreKept() {
        let audio = [Float](repeating: 0, count: Int(2 * rate))
        let notes = [note(0.5, 1.0, 64), note(1.1, 1.5, 64)]
        let result = NoteCleanup.verify(notes, audio22k: audio, transkun: notes, basicPitch: notes)
        XCTAssertEqual(result.notes, notes)
    }

    /// A take that opens on a note: samples before the take are silence, so
    /// the note still shows its attack (clamped to the first frame, which
    /// already held it, every note in the first 46 ms was dropped).
    func testNotesAtTheStartOfTheTakeKeepTheirAttack() {
        for start in [0.0, 0.02] {
            let audio = tone(pitch: 60, seconds: 2) { t in t < start ? 0 : min(1, (t - start) / 0.003) * exp(-(t - start)) }
            let n = note(start, 1, 60)
            XCTAssertEqual(NoteCleanup.verify([n], audio22k: audio, transkun: [], basicPitch: [n]).notes, [n])
            XCTAssertEqual(NoteCleanup.verify([n], audio22k: audio, transkun: [n], basicPitch: []).notes, [n])
        }
    }

    /// Both engines started every stroke of a fast repeat, 70 ms apart: each
    /// stroke stays a note (before, runs closer than 100 ms chained into one).
    func testFastRepeatsBothEnginesStartedStay() {
        let ioi = 0.07
        let notes = (0..<14).map { note(0.5 + Double($0) * ioi, 0.5 + Double($0) * ioi + ioi * 0.9, 64) }
        let audio = tone(pitch: 64, seconds: 2) { t in
            guard t >= 0.5, t < 0.5 + 14 * ioi else { return 0 }
            let phase = (t - 0.5).truncatingRemainder(dividingBy: ioi)
            return phase < ioi * 0.9 ? min(1, phase / 0.003) * exp(-phase / 0.3) : 0
        }
        let result = NoteCleanup.verify(notes, audio22k: audio, transkun: notes, basicPitch: notes)
        XCTAssertEqual(result.notes.map(\.startTime), notes.map(\.startTime))
        XCTAssertEqual(result.report.duplicates, 0)
    }

    func testDisabledLeavesNotesAlone() {
        let notes = [note(0.5, 1.0, 64)]
        var settings = NoteCleanup.Settings()
        settings.enabled = false
        let audio = [Float](repeating: 0, count: Int(2 * rate))
        XCTAssertEqual(NoteCleanup.verify(notes, audio22k: audio, transkun: [], basicPitch: notes, settings: settings).notes, notes)
    }
}
