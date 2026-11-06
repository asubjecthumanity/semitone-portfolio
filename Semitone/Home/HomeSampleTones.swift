#if DEBUG
import Foundation

/// -semitone-home-sample-tones: the library is a fresh folder of made-up
/// Tones of every kind (Piano, Instrument, and Songs in two, three and four
/// parts) across two months, so UI tests and screenshots of Home don't
/// depend on what's saved on the simulator. Each has a silent recording, so
/// it opens as a real Tone does (from its long-press menu too): its notes
/// come from its save, and the quick detector hears none. Some are saved as
/// older builds saved them (`Saved`): "Hummed line" before kinds and parts
/// were kept, and two by Prerelease 0.99 with drum hits.
/// -semitone-home-no-tones: the library is an empty folder instead, for
/// the empty library's sample card.
nonisolated enum HomeSampleTones {
    /// The sample library's folder, written once per launch; nil without either argument.
    static let root: URL? = {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-semitone-home-no-tones") {
            let empty = URL.temporaryDirectory.appending(path: "HomeNoTones/Saved", directoryHint: .isDirectory)
            try? FileManager.default.removeItem(at: empty)
            try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            return empty
        }
        guard arguments.contains("-semitone-home-sample-tones") else { return nil }
        let root = URL.temporaryDirectory.appending(path: "HomeSampleTones/Saved", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: root)
        let encoder = JSONEncoder()
        for sample in samples(now: .now) {
            // Written here rather than with TakeLibrary.save, whose root is this.
            // Noted with its kind and parts as a save notes them (one with
            // 0.99's drum hits as 0.99 noted it), unless saved before kinds were kept.
            let take = sample.take
            var content = sample.content
            if case .withDrums(let bpm) = sample.saved {
                content.legacyDrums = backbeat(bpm: bpm, duration: take.duration)
            }
            let entry = sample.saved == .beforeKinds ? take : take.noting(content)
            let json = (try? encoder.encode(content)) ?? Data()
            let folder = root.appending(path: take.id.uuidString, directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? json.write(to: folder.appending(path: "take.json"))
            // Silence, as a save writes it (at 22.05 kHz the encoder wrote no audio at all).
            try? TakeLibrary.writeAudio([Float](repeating: 0, count: Int(take.duration * PianoModel.sampleRate)),
                                        sampleRate: PianoModel.sampleRate,
                                        to: folder.appending(path: "audio.m4a"))
            try? encoder.encode(entry).write(to: folder.appending(path: "info.json"))
        }
        return root
    }()

    /// How a sample was saved, which decides what its files hold.
    private enum Saved: Equatable {
        /// By this build: the entry notes its kind and parts.
        case now
        /// Before kinds and parts were kept: the entry has neither.
        case beforeKinds
        /// By Prerelease 0.99, which still transcribed a drum kit: take.json
        /// holds a backbeat at this tempo, and the entry notes a song with a
        /// "drums" part. This build shows neither (`SavedTake.savedKind`).
        case withDrums(bpm: Double)
    }

    private struct Sample {
        let take: SavedTake
        let content: SavedTakeContent
        let saved: Saved
    }

    private static func samples(now: Date) -> [Sample] {
        func day(_ n: Double) -> Date { now.addingTimeInterval(-n * 86_400) }
        return [
            take("Piano sketch", .piano, day(0), piano(bars: 4, bpm: 120)),
            take("Whistled tune", .music, day(1), melody(bars: 6, bpm: 96, low: 74)),
            take("Band demo", .music, day(2), band(bars: 16, bpm: 104, parts: [.melody, .countermelody, .chords, .bass])),
            take("Canon in C – fingerpicked", .piano, day(3), piano(bars: 20, bpm: 98)),
            // Two parts now: its drums lane is gone.
            take("Guitar and drums", .music, day(4), band(bars: 12, bpm: 92, parts: [.chords, .bass]),
                 saved: .withDrums(bpm: 92)),
            take("A single note", .piano, day(5), ([NoteEvent(startTime: 0.2, endTime: 1.4, pitch: 60, amplitude: 0.7)], 2)),
            take("Trio, first pass", .music, day(33), band(bars: 10, bpm: 88, parts: [.melody, .chords, .bass])),
            take("Hummed line", .music, day(34), melody(bars: 4, bpm: 80, low: 64), saved: .beforeKinds),
            // Played low: both hands mostly below middle C. In A minor, so
            // Home's search has a minor key to find (and an accent to fold).
            take("Evening étude", .piano, day(35), piano(bars: 8, bpm: 72, tuneShift: -24, minor: true)),
            // A song of melody and drums when it was saved; one line, an Instrument tone, now.
            take("Tune over a drum loop", .music, day(36), melody(bars: 4, bpm: 100, low: 69),
                 saved: .withDrums(bpm: 100)),
        ]
    }

    private static func take(_ title: String, _ mode: TranscriptionMode, _ date: Date,
                             _ music: (notes: [NoteEvent], duration: Double), saved: Saved = .now) -> Sample {
        let take = SavedTake(id: UUID(), title: title, createdAt: date, duration: music.duration,
                             mode: mode.rawValue, noteCount: music.notes.count)
        let content = SavedTakeContent(source: mode == .piano ? "piano" : "music", notes: music.notes,
                                       sustain: [])
        return Sample(take: take, content: content, saved: saved)
    }

    /// A backbeat, the way Prerelease 0.99 saved a kit's hits (kind 0 kick,
    /// 1 snare, 2 closed hi-hat): this build writes them back as they are.
    private static func backbeat(bpm: Double, duration: Double) -> [SavedTakeContent.LegacyDrum] {
        let eighth = 30 / bpm
        var hits: [SavedTakeContent.LegacyDrum] = []
        for (i, time) in stride(from: 0.0, to: duration - 0.5, by: eighth).enumerated() {
            hits.append(.init(time: time, kind: 2, velocity: 0.5))
            if i % 4 == 0 { hits.append(.init(time: time, kind: 0, velocity: 0.8)) }
            if i % 4 == 2 { hits.append(.init(time: time, kind: 1, velocity: 0.7)) }
        }
        return hits
    }

    // MARK: Made-up music

    /// Two hands: eighths over a broken chord a bar (the tune moved by
    /// `tuneShift` semitones). In C major, or with `minor` in A minor: i, VI,
    /// iv, V under a tune that leans on A and its leading note.
    private static func piano(bars: Int, bpm: Double, tuneShift: Int = 0,
                              minor: Bool = false) -> (notes: [NoteEvent], duration: Double) {
        let beat = 60 / bpm
        let roots = minor ? [45, 41, 38, 40] : [48, 45, 41, 43]
        let tune = minor ? [69, 71, 72, 76, 74, 72, 71, 69, 68, 69, 71, 72, 71, 69, 68, 64]
            : [72, 74, 76, 79, 77, 76, 74, 72, 71, 72, 74, 76, 74, 72, 71, 67]
        var notes: [NoteEvent] = []
        for bar in 0..<bars {
            let t0 = Double(bar) * 4 * beat
            let root = roots[bar % roots.count]
            for (i, step) in [0, 7, 12, 7].enumerated() {
                notes.append(NoteEvent(startTime: t0 + Double(i) * beat, endTime: t0 + Double(i + 1) * beat * 0.95,
                                       pitch: root + step, amplitude: 0.5))
            }
            for i in 0..<8 where (i + bar) % 5 != 4 {
                let pitch = tune[(bar * 8 + i) % tune.count] + tuneShift
                notes.append(NoteEvent(startTime: t0 + Double(i) * beat / 2, endTime: t0 + Double(i + 1) * beat / 2 * 0.9,
                                       pitch: pitch, amplitude: 0.7))
            }
        }
        return (notes, Double(bars) * 4 * beat + 0.5)
    }

    /// One line, as an Instrument tone: a melody part and nothing else.
    private static func melody(bars: Int, bpm: Double, low: Int) -> (notes: [NoteEvent], duration: Double) {
        let beat = 60 / bpm
        let steps = [0, 2, 4, 7, 9, 7, 4, 5, 4, 2, 0, -1, 0, 4, 7, 12]
        let lengths = [1.0, 0.5, 0.5, 1.5, 0.5, 1, 1, 2]
        var notes: [NoteEvent] = []
        var t = 0.0, i = 0
        while t < Double(bars) * 4 * beat {
            let length = lengths[i % lengths.count] * beat
            notes.append(NoteEvent(startTime: t, endTime: t + length * 0.9, pitch: low + steps[i % steps.count],
                                   amplitude: 0.6, voice: .melody))
            t += length; i += 1
        }
        return (notes, t + 0.5)
    }

    /// A band: the given parts over a I–vi–IV–V loop. A countermelody is a
    /// line of half notes between the chords and the tune.
    private static func band(bars: Int, bpm: Double, parts: [Voice]) -> (notes: [NoteEvent], duration: Double) {
        let beat = 60 / bpm
        let roots = [48, 45, 41, 43]
        let tune = [76, 79, 81, 79, 76, 74, 72, 74, 76, 76, 74, 72]
        var notes: [NoteEvent] = []
        for bar in 0..<bars {
            let t0 = Double(bar) * 4 * beat
            let root = roots[bar % roots.count]
            if parts.contains(.chords) {
                for half in 0..<2 {
                    let start = t0 + Double(half) * 2 * beat
                    for step in root == 45 ? [12, 15, 19] : [12, 16, 19] {
                        notes.append(NoteEvent(startTime: start, endTime: start + 2 * beat * 0.92, pitch: root + step,
                                               amplitude: 0.45, voice: .chords))
                    }
                }
            }
            if parts.contains(.bass) {
                for i in 0..<4 {
                    notes.append(NoteEvent(startTime: t0 + Double(i) * beat, endTime: t0 + Double(i) * beat + beat * 0.8,
                                           pitch: root - 12 + (i == 3 ? 7 : 0), amplitude: 0.6, voice: .bass))
                }
            }
            if parts.contains(.countermelody) {
                for half in 0..<2 {
                    let start = t0 + Double(half) * 2 * beat
                    notes.append(NoteEvent(startTime: start, endTime: start + 2 * beat * 0.9,
                                           pitch: [67, 69, 71, 72, 71, 69, 67, 65][(bar * 2 + half) % 8],
                                           amplitude: 0.55, voice: .countermelody))
                }
            }
            if parts.contains(.melody), bar % 4 != 3 {
                for i in 0..<6 {
                    let start = t0 + [0, 1, 1.5, 2, 3, 3.5][i] * beat
                    notes.append(NoteEvent(startTime: start, endTime: start + [1, 0.5, 0.5, 1, 0.5, 0.5][i] * beat * 0.9,
                                           pitch: tune[(bar * 6 + i) % tune.count], amplitude: 0.7, voice: .melody))
                }
            }
        }
        return (notes, Double(bars) * 4 * beat + 0.5)
    }
}
#endif
