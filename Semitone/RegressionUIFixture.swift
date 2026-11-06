// Deterministic events for hosted simulator UI regressions. Never used by release builds.
#if DEBUG
import Foundation

enum RegressionUIFixture: String {
    case pianoRange = "piano-range"
    /// An unsplit (piano) take on black and white keys, loud and quiet, for
    /// the falling notes' two shades (`Voice.blackKeyNote`).
    case pianoKeys = "piano-keys"
    case chords
    case parts
    case sustain
    /// Four bars with every part of a split take, for Song-mode screenshots.
    case song
    /// The same bars with the chords part as the engines tend to write it,
    /// for the chord styles (As played / Simplified).
    case songTranscribed = "song-transcribed"
    /// The song's bars sixteen times over (128 s) with a sixteenth-note
    /// arpeggio added, 1,920 notes: a long, dense take for checking
    /// that playback and scrolling stay smooth however much there is to draw.
    case songLong = "song-long"

    static var selected: Self? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-semitone-ui-fixture"),
              arguments.indices.contains(index + 1) else { return nil }
        return Self(rawValue: arguments[index + 1])
    }

    /// The roll layout a fixture opens with: horizontal unless
    /// `-semitone-fixture-layout falling` asks for the falling notes.
    static var layout: String {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-semitone-fixture-layout"),
              arguments.indices.contains(index + 1) else { return "horizontal" }
        return arguments[index + 1]
    }

    /// A roll frozen part-way through flipping from the horizontal roll to
    /// the falling notes (`-semitone-fixture-flip 0.33`), for screenshots of
    /// the turn; 0 is the keyboard lifted, with its hint.
    static var flipProgress: Double? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-semitone-fixture-flip"),
              arguments.indices.contains(index + 1),
              let progress = Double(arguments[index + 1]), progress.isFinite else { return nil }
        return min(max(progress, 0), 1)
    }

    /// `-semitone-fixture-cleanup`: the take as an AI cleanup left it (its
    /// first note removed), for the cleanup items in its Transcription menu.
    static var appliesCleanup: Bool {
        ProcessInfo.processInfo.arguments.contains("-semitone-fixture-cleanup")
    }

    /// `-semitone-fixture-recording 6`: the take shown as if it were being
    /// recorded, the live edge at 6 s and moving on as the microphone's
    /// buffers would (the simulator can't record). Stop ends it, keeping the take.
    static var recordingEdge: Double? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-semitone-fixture-recording"),
              arguments.indices.contains(index + 1),
              let edge = Double(arguments[index + 1]), edge.isFinite else { return nil }
        return max(edge, 0)
    }

    var initialPlayhead: Double {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-semitone-fixture-cue"),
              arguments.indices.contains(index + 1),
              let time = Double(arguments[index + 1]), time.isFinite else { return 0 }
        return min(max(time, 0), duration)
    }

    var notes: [NoteEvent] {
        switch self {
        case .pianoRange:
            return [21, 60, 108].map {
                NoteEvent(startTime: 0, endTime: 1.5, pitch: $0, amplitude: 0.8)
            }
        case .pianoKeys:
            // A chromatic run up from middle C in eighths, alternately loud
            // and quiet, over held E-flat and D-flat major chords.
            let run = (0..<12).map { k in
                NoteEvent(startTime: 0.25 * Double(k), endTime: 0.25 * Double(k) + 0.24, pitch: 60 + k,
                          amplitude: k.isMultiple(of: 2) ? 0.8 : 0.3)
            }
            return (triad([51, 55, 58], start: 0, end: 1.5) + triad([49, 53, 56], start: 1.5, end: 3) + run)
                .sorted { $0.startTime < $1.startTime }
        case .chords:
            return triad([60, 64, 67], start: 1, end: 2)
                + triad([55, 59, 62], start: 5, end: 6)
                + triad([60, 64, 67], start: 7, end: 7.4)
                + triad([60, 64, 67], start: 8.2, end: 8.6)
        case .parts:
            return [
                NoteEvent(startTime: 0, endTime: 45, pitch: 72, amplitude: 0.8, voice: .melody),
                NoteEvent(startTime: 0, endTime: 45, pitch: 67, amplitude: 0.75, voice: .countermelody),
                NoteEvent(startTime: 0, endTime: 45, pitch: 60, amplitude: 0.7, voice: .chords),
                NoteEvent(startTime: 0, endTime: 45, pitch: 36, amplitude: 0.8, voice: .bass)
            ]
        case .sustain:
            return [NoteEvent(startTime: 0, endTime: 1, pitch: 60, amplitude: 0.8)]
        case .song:
            return Self.songBars
        case .songTranscribed:
            return Self.transcribedSongBars
        case .songLong:
            let arpeggios = [[60, 64, 67, 72], [57, 60, 64, 69], [53, 57, 60, 65], [55, 59, 62, 67]]
            var notes: [NoteEvent] = []
            for repeat_ in 0..<16 {
                let offset = Double(repeat_) * 8
                notes += Self.songBars.map {
                    NoteEvent(startTime: $0.startTime + offset, endTime: $0.endTime + offset, pitch: $0.pitch,
                              amplitude: $0.amplitude, voice: $0.voice)
                }
                for bar in 0..<4 {
                    for k in 0..<16 {
                        let start = offset + Double(bar) * 2 + Double(k) * 0.125
                        notes.append(NoteEvent(startTime: start, endTime: start + 0.12, pitch: arpeggios[bar][k % 4],
                                               amplitude: 0.5, voice: .chords))
                    }
                }
            }
            return notes.sorted { $0.startTime < $1.startTime }
        }
    }

    /// C, Am, F, G at 120 BPM: the bass on beat 1, a sustained countermelody
    /// note struck on beat 1, the melody moving above it in eighths from beat
    /// 2, chords on beats 2 and 4.
    private static var songBars: [NoteEvent] {
        let bass = [48, 45, 41, 43]
        let counter = [67, 64, 65, 67]
        let chords = [[52, 55, 60], [52, 57, 60], [53, 57, 60], [55, 59, 62]]
        let melody = [[72, 74, 76, 77, 76, 74], [76, 74, 72, 71, 72, 74], [77, 76, 74, 72, 74, 77], [79, 77, 76, 74, 71, 72]]
        var notes: [NoteEvent] = []
        for bar in 0..<4 {
            let t = Double(bar) * 2
            notes.append(NoteEvent(startTime: t, endTime: t + 1.9, pitch: bass[bar], amplitude: 0.8, voice: .bass))
            notes.append(NoteEvent(startTime: t, endTime: t + 1.9, pitch: counter[bar], amplitude: 0.75, voice: .countermelody))
            for beat in [0.5, 1.5] {
                notes += chords[bar].map { NoteEvent(startTime: t + beat, endTime: t + beat + 0.4, pitch: $0, amplitude: 0.6, voice: .chords) }
            }
            for (k, pitch) in melody[bar].enumerated() {
                let start = t + 0.5 + Double(k) * 0.25
                notes.append(NoteEvent(startTime: start, endTime: start + 0.24, pitch: pitch, amplitude: 0.8, voice: .melody))
            }
        }
        return notes
    }

    /// `songBars` with a chords part as transcribed: open, doubled shapes on
    /// beat 2, rolled 12 ms per note, and thinner ones on beat 4, one without
    /// its root (C), one with a stray passing tone (F over Am). Still C, Am,
    /// F, G.
    private static var transcribedSongBars: [NoteEvent] {
        let shapes = [[[48, 55, 64, 67, 72], [55, 64, 67]], [[45, 57, 64, 69, 72], [57, 60, 64, 65]],
                      [[41, 53, 60, 65, 69], [57, 65, 72]], [[43, 55, 62, 67, 71], [59, 62, 67, 74]]]
        var notes = songBars.filter { $0.voice != .chords }
        for bar in 0..<4 {
            for (k, beat) in [0.5, 1.5].enumerated() {
                let t = Double(bar) * 2 + beat
                notes += shapes[bar][k].enumerated().map {
                    NoteEvent(startTime: t + 0.012 * Double($0.offset), endTime: t + (k == 0 ? 0.42 : 0.3), pitch: $0.element,
                              amplitude: [0.55, 0.7, 0.6, 0.65, 0.5][$0.offset], voice: .chords)
                }
            }
        }
        return notes
    }

    /// The chord names the app would show: a Song-mode take's come from
    /// `HarmonyStage` on its beat grid (as `TakeAnalysis.derive` finds them),
    /// the chords fixture's from the note-boundary analyzer.
    var chords: [ChordSegment] {
        switch self {
        case .chords: ChordAnalyzer.segments(notes)
        case .song, .songTranscribed, .songLong: HarmonyStage.chords(notes: notes, grid: beatGrid)
        default: []
        }
    }

    var sustain: [PedalEvent] {
        self == .sustain ? [PedalEvent(startTime: 0, endTime: 3)] : []
    }

    var duration: Double {
        switch self {
        case .pianoRange, .pianoKeys: 4
        case .chords: 10
        case .parts: 45
        case .sustain: 3
        case .song, .songTranscribed: 8
        case .songLong: 128
        }
    }

    var isSplit: Bool { [.parts, .song, .songTranscribed, .songLong].contains(self) }
    var mode: TranscriptionMode { isSplit ? .music : .piano }
    var source: NotesSource { isSplit ? .music : .piano }

    var beatGrid: BeatGrid {
        BeatGrid(beats: stride(from: 0.0, through: duration, by: 0.5).map { $0 },
                 downbeats: stride(from: 0.0, through: duration, by: 2.0).map { $0 },
                 beatsPerMeasure: 4, bpm: 120)
    }

    private func triad(_ pitches: [Int], start: Double, end: Double) -> [NoteEvent] {
        pitches.map { NoteEvent(startTime: start, endTime: end, pitch: $0, amplitude: 0.8) }
    }
}
#endif
