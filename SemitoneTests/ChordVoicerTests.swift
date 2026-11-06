import XCTest
@testable import Semitone

/// Chord labels read back as pitch classes (`ChordSymbol`), the chords part
/// rebuilt from them (`ChordVoicer`), and the chord style a take is saved with.
final class ChordVoicerTests: XCTestCase {
    private let names = ChordAnalyzer.names

    private func chord(_ pitches: [Int], at start: Double, to end: Double, amplitude: Double = 0.6,
                       voice: Voice = .chords) -> [NoteEvent] {
        pitches.map { NoteEvent(startTime: start, endTime: end, pitch: $0, amplitude: amplitude, voice: voice) }
    }

    private func segment(_ label: String, _ start: Double, _ end: Double) -> ChordSegment {
        ChordSegment(startTime: start, endTime: end, label: label)
    }

    /// 0.5 s beats, a bar every 2 s.
    private func grid(seconds: Double = 16) -> BeatGrid {
        BeatGrid(beats: Array(stride(from: 0, to: seconds, by: 0.5)), downbeats: Array(stride(from: 0, to: seconds, by: 2)),
                 beatsPerMeasure: 4, bpm: 120)
    }

    private func chordsPart(_ notes: [NoteEvent]) -> [NoteEvent] { notes.filter { $0.voice == .chords } }

    /// The voicer striking wherever the chords part struck (`restrike`), as
    /// Simplified played before 0.79; the rhythm tests below check that mode.
    private static let restriking: ChordVoicer.Settings = {
        var settings = ChordVoicer.Settings()
        settings.restrike = true
        return settings
    }()

    private func voiceRestriking(notes: [NoteEvent], chords: [ChordSegment], grid: BeatGrid,
                                 settings: ChordVoicer.Settings = restriking) -> ChordVoicer.Result {
        ChordVoicer.voice(notes: notes, chords: chords, grid: grid, settings: settings)
    }

    /// The strikes of a voiced part: (start, end, pitches low to high).
    private func strikes(_ notes: [NoteEvent]) -> [(start: Double, end: Double, pitches: [Int])] {
        Dictionary(grouping: chordsPart(notes)) { $0.startTime }.keys.sorted().map { start in
            let struck = chordsPart(notes).filter { $0.startTime == start }
            return (start, struck[0].endTime, struck.map(\.pitch).sorted())
        }
    }

    // MARK: - Every label parses

    /// Every name `ChordAnalyzer` can write: each template on each root, in
    /// root position and over each other chord tone.
    func testEveryChordAnalyzerLabelParses() throws {
        for root in 0..<12 {
            for template in ChordAnalyzer.templates {
                let tones = template.intervals.map { (root + $0) % 12 }
                for bass in [nil] + tones.dropFirst().map(Optional.some) {
                    let label = names[root] + template.suffix + (bass.map { "/" + names[$0] } ?? "")
                    let symbol = try XCTUnwrap(ChordSymbol(label), "\(label) parses")
                    XCTAssertEqual(symbol.root, root, label)
                    XCTAssertEqual(symbol.quality, template.suffix, label)
                    XCTAssertEqual(symbol.tones, tones, label)
                    XCTAssertEqual(symbol.slashBass, bass, label)
                    XCTAssertEqual(symbol.bass, bass ?? root, label)
                }
            }
        }
    }

    /// What `ChordAnalyzer.segments` actually names, for every template on
    /// every root with each chord tone lowest: the label parses to the notes'
    /// pitch classes over the lowest one.
    func testEveryLabelChordAnalyzerFindsParsesToItsNotes() throws {
        for root in 0..<12 {
            for template in ChordAnalyzer.templates {
                let tones = template.intervals.map { (root + $0) % 12 }
                for lowest in tones.indices {
                    // Close position from the chosen tone up, around C4.
                    var pitches = [48 + tones[lowest]]
                    for step in 1..<tones.count {
                        let pc = tones[(lowest + step) % tones.count]
                        pitches.append(pitches[step - 1] + ((pc - pitches[step - 1]) % 12 + 12) % 12)
                    }
                    let notes = chord(pitches, at: 0, to: 2, voice: .none)
                    let labels = ChordAnalyzer.segments(notes).map(\.label)
                    XCTAssertEqual(labels.count, 1, "\(pitches) names one chord: \(labels)")
                    let label = try XCTUnwrap(labels.first)
                    let symbol = try XCTUnwrap(ChordSymbol(label), "\(label) parses")
                    XCTAssertEqual(Set(symbol.tones), Set(tones), "\(label) for \(pitches)")
                    XCTAssertEqual(symbol.bass, tones[lowest], "\(label) stands on the lowest note")
                }
            }
        }
    }

    /// Every label `HarmonyStage.label` can write: each triad, with each of
    /// its 7th or 6th options, in root position and over its third or fifth.
    func testEveryHarmonyStageLabelParses() throws {
        var seen = Set<String>()
        for root in 0..<12 {
            for minor in [false, true] {
                let third = minor ? 3 : 4
                let options: [(Int, String)] = minor ? [(10, "m7"), (9, "m6")] : [(10, "7"), (11, "maj7"), (9, "6")]
                for added in [nil] + options.map(Optional.some) {
                    for bassInterval in [0, third, 7] {
                        var chroma = [Double](repeating: 0, count: 12)
                        for interval in [0, third, 7] { chroma[(root + interval) % 12] = 1 }
                        if let added { chroma[(root + added.0) % 12] = 1 }
                        var bass = [Double](repeating: 0, count: 12)
                        bass[(root + bassInterval) % 12] = 1
                        let label = HarmonyStage.label(root: root, minor: minor, chroma: chroma, bass: bass)
                        seen.insert(label)
                        let symbol = try XCTUnwrap(ChordSymbol(label), "\(label) parses")
                        XCTAssertEqual(symbol.root, root, label)
                        XCTAssertEqual(symbol.quality, added?.1 ?? (minor ? "m" : ""), label)
                        XCTAssertEqual(symbol.bass, (root + bassInterval) % 12, label)
                    }
                }
            }
        }
        XCTAssertEqual(seen.count, 12 * (4 + 3) * 3, "Every root, quality and bass gives its own label.")
    }

    func testLabelsThatNameNoChordDoNotParse() {
        for label in ["N", "", " ", "X", "H", "Cmaj9", "C/E/G", "C/X", "m7"] {
            XCTAssertNil(ChordSymbol(label), "\(label) is no chord")
        }
        XCTAssertEqual(ChordSymbol("Bb")?.root, 10, "Flats read too.")
        XCTAssertEqual(ChordSymbol("D#m7b5/A"), ChordSymbol("D#m7♭5/A"), "The ASCII marker spelling reads back.")
    }

    // MARK: - Voicing

    /// C to F around D4: the F that keeps C on the bottom and moves the
    /// other two voices by a step (3 semitones in all), not the F nearest the
    /// centre (A3 C4 F4, 9 semitones).
    func testVoiceLeadingPicksTheLeastMovement() throws {
        let c = try XCTUnwrap(ChordSymbol("C")), f = try XCTUnwrap(ChordSymbol("F"))
        let first = ChordVoicer.voicing(c, centre: 62, after: nil, slack: 4)
        XCTAssertEqual(first, [60, 64, 67], "With nothing before it, the voicing nearest the centre.")
        XCTAssertEqual(ChordVoicer.voicing(f, centre: 62, after: nil, slack: 4), [57, 60, 65])
        XCTAssertEqual(ChordVoicer.voicing(f, centre: 62, after: first, slack: 4), [60, 65, 69])

        // The same through the voicer: C, F, G7, C, each struck on beat 1.
        var notes: [NoteEvent] = []
        for (bar, shape) in [[55, 60, 64, 67], [57, 60, 65, 69], [55, 59, 62, 65], [55, 60, 64, 67]].enumerated() {
            notes += chord(shape, at: Double(bar) * 2, to: Double(bar) * 2 + 1.9)
        }
        let chords = ["C", "F", "G7", "C"].enumerated().map { segment($0.element, Double($0.offset) * 2, Double($0.offset) * 2 + 2) }
        let out = voiceRestriking(notes: notes, chords: chords, grid: grid())
        XCTAssertEqual(strikes(out.notes).map(\.pitches), [[60, 64, 67], [60, 65, 69], [59, 62, 65, 67], [60, 64, 67]],
                       "Each chord moves as little as it can; G7 has four notes.")
        XCTAssertEqual(out.voiced, 4)
    }

    /// A slash chord's voicing holds its chord tones only: the bass note
    /// under it belongs to the bass part, which is left as it was.
    func testSlashChordKeepsChordTonesOnly() throws {
        let bass = NoteEvent(startTime: 0, endTime: 4, pitch: 40, amplitude: 0.7, voice: .bass)
        let notes = [bass] + chord([52, 55, 60, 64], at: 0, to: 1.9) + chord([47, 55, 59, 62, 65], at: 2, to: 3.9)
        let out = voiceRestriking(notes: notes, chords: [segment("C/E", 0, 2), segment("G7/B", 2, 4)], grid: grid())
        let voiced = strikes(out.notes)
        XCTAssertEqual(voiced.count, 2)
        XCTAssertEqual(Set(voiced[0].pitches.map { $0 % 12 }), [0, 4, 7])
        XCTAssertEqual(voiced[0].pitches.count, 3, "A triad, not a fourth note for the slash bass.")
        XCTAssertEqual(Set(voiced[1].pitches.map { $0 % 12 }), [7, 11, 2, 5])
        XCTAssertEqual(voiced[1].pitches.count, 4)
        XCTAssertEqual(out.notes.filter { $0.voice == .bass }, [bass])
    }

    // MARK: - One strike per chord (0.79, the default)

    /// Simplified plays each chord once, at its first strike, held to the
    /// next chord change, at the median loudness of the notes it replaces.
    func testSimplifiedStrikesEachChordOnceToTheChange() {
        var notes = [48, 52, 55].enumerated().map {
            NoteEvent(startTime: 0.02 * Double($0.offset), endTime: 1.2, pitch: $0.element + 12,
                      amplitude: [0.2, 0.4, 0.9][$0.offset], voice: .chords)
        }
        notes += chord([60, 64, 67], at: 1.5, to: 2, amplitude: 0.5)
        notes += chord([60, 64, 67], at: 2.25, to: 2.6, amplitude: 0.7)
        notes += chord([64, 67, 72], at: 3, to: 3.5, amplitude: 0.3)
        notes += chord([65, 69, 72], at: 4, to: 4.5) + chord([65, 69, 72], at: 5, to: 5.5)
        let out = ChordVoicer.voice(notes: notes, chords: [segment("C", 0, 4), segment("F", 4, 6)], grid: grid())
        let struck = strikes(out.notes)
        XCTAssertEqual(struck.map(\.start), [0, 4], "One strike per chord, where it starts.")
        XCTAssertEqual(struck.map(\.end), [4, 6], "Held to the change, the last to its chord's end.")
        let amplitudes = struck.map { strike in chordsPart(out.notes).first { $0.startTime == strike.start }!.amplitude }
        XCTAssertEqual(amplitudes[0], 0.5, accuracy: 1e-9, "The median of every note the chord replaces.")
    }

    /// A pushed chord still starts early, once, and holds to the next change.
    func testSimplifiedPushedChordIsStruckOnceEarly() {
        let notes = chord([60, 64, 67], at: 0, to: 1.8)
            + chord([65, 69, 72], at: 1.89, to: 3) + chord([65, 69], at: 3, to: 4)
        let struck = strikes(ChordVoicer.voice(notes: notes, chords: [segment("C", 0, 2), segment("F", 2, 4)],
                                               grid: grid()).notes)
        XCTAssertEqual(struck.map(\.start), [0, 1.89])
        XCTAssertEqual(struck.map(\.end), [1.89, 4])
    }

    /// A chord the part rings into without striking is one block at its
    /// start, held over its bar lines rather than struck on each.
    func testSimplifiedBlockIsStruckOnceOverItsBars() {
        let notes = chord([60, 64, 67], at: 0, to: 2.4)
        let struck = strikes(ChordVoicer.voice(notes: notes, chords: [segment("C", 0, 2), segment("G", 2, 7)],
                                               grid: grid()).notes)
        XCTAssertEqual(struck.map(\.start), [0, 2])
        XCTAssertEqual(struck.map(\.end), [2, 7])
    }

    // MARK: - Restriking where the part struck (`restrike`)

    /// The voicing is struck where the chords part was struck, a strum being
    /// one strike, and held to the next strike, at the median loudness of the
    /// notes each strike replaces.
    func testRhythmFollowsTheTranscribedStrikes() {
        var notes = [48, 52, 55].enumerated().map {   // a strum: onsets 20 ms apart
            NoteEvent(startTime: 0.02 * Double($0.offset), endTime: 1.2, pitch: $0.element + 12,
                      amplitude: [0.2, 0.4, 0.9][$0.offset], voice: .chords)
        }
        notes += chord([60, 64, 67], at: 1.5, to: 2, amplitude: 0.5)
        notes += chord([60, 64, 67], at: 2.25, to: 2.6, amplitude: 0.7)
        notes += chord([64, 67, 72], at: 3, to: 3.5, amplitude: 0.3)
        let out = voiceRestriking(notes: notes, chords: [segment("C", 0, 4)], grid: grid())
        let struck = strikes(out.notes)
        XCTAssertEqual(struck.map(\.start), [0, 1.5, 2.25, 3])
        XCTAssertEqual(struck.map(\.end), [1.5, 2.25, 3, 4], "Each strike rings to the next, the last to the chord's end.")
        XCTAssertEqual(Set(struck.map(\.pitches)).count, 1, "One voicing per chord.")
        let amplitudes = struck.map { strike in chordsPart(out.notes).first { $0.startTime == strike.start }!.amplitude }
        XCTAssertEqual(amplitudes, [0.4, 0.5, 0.7, 0.3], "The strum's median, then each strike's own.")
        XCTAssertEqual(out.voiced, 1)
        XCTAssertEqual(out.blocks, 0)
    }

    /// A strike just before a chord that fits it belongs to it and keeps its
    /// early time; one that fits the chord it sounds in better stays there.
    func testPushedStrikeStartsItsChordEarly() {
        let notes = chord([60, 64, 67], at: 0, to: 1.9) + chord([60, 65, 69], at: 1.92, to: 3.9)
            + chord([60, 65, 69], at: 3.9, to: 4, amplitude: 0.3)   // an F stab 0.1 s before G: stays F
            + chord([59, 62, 67], at: 4, to: 5.9)
        let out = voiceRestriking(notes: notes, chords: [segment("C", 0, 2), segment("F", 2, 4), segment("G", 4, 6)],
                                    grid: grid())
        let struck = strikes(out.notes)
        XCTAssertEqual(struck.map(\.start), [0, 1.92, 3.9, 4])
        XCTAssertEqual(struck.map(\.end), [1.92, 3.9, 4, 6])
        XCTAssertEqual(struck.map { Set($0.pitches.map { $0 % 12 }) }, [[0, 4, 7], [5, 9, 0], [5, 9, 0], [7, 11, 2]],
                       "The early strike plays F; the stab before G fits F, not G, so it plays F too.")
    }

    /// Once a strike pushes a chord, the chord before does not come back
    /// before the change: the two chords never alternate, which left the
    /// pushed chord silent until its next strike.
    func testAPushedChordStaysPushedUpToTheChange() {
        let chords = [segment("C", 0, 2), segment("F", 2, 4)]
        let notes = chord([60, 64, 67], at: 0, to: 1.8)
            + chord([65, 69, 72], at: 1.89, to: 3)     // pushes F
            + chord([60, 64, 67], at: 1.96, to: 3)     // fits C, but F has already come
            + chord([65, 69], at: 3, to: 4)
        let struck = strikes(voiceRestriking(notes: notes, chords: chords, grid: grid()).notes)
        XCTAssertEqual(struck.map(\.start), [0, 1.89, 1.96, 3])
        XCTAssertEqual(struck.map(\.end), [1.89, 1.96, 3, 4], "F sounds from its early strike on, with no gap.")
        XCTAssertEqual(struck.map { Set($0.pitches.map { $0 % 12 }) }, [[0, 4, 7], [5, 9, 0], [5, 9, 0], [5, 9, 0]])

        // A block over a chord with no strikes of its own stops at the next
        // chord's early strike, even with a bar line after it.
        let ringing = chord([55, 59, 62], at: 0, to: 1.95) + chord([65, 69, 72], at: 1.9, to: 4)
        let lateBar = BeatGrid(beats: [0, 0.5, 1, 1.5, 1.92, 2.42, 2.92, 3.42], downbeats: [0, 1.92],
                               beatsPerMeasure: 4, bpm: 120)
        let blocked = strikes(voiceRestriking(notes: ringing, chords: [segment("G", 0, 1), segment("C", 1, 2),
                                                                          segment("F", 2, 4)], grid: lateBar).notes)
        XCTAssertEqual(blocked.map(\.start), [0, 1, 1.9])
        XCTAssertEqual(blocked.map(\.end), [1, 1.9, 4])
        XCTAssertEqual(blocked.map { Set($0.pitches.map { $0 % 12 }) }, [[7, 11, 2], [0, 4, 7], [5, 9, 0]])
    }

    /// A stray note just before a change that fits neither chord does not
    /// start the next chord early: it restrikes the chord it sounds in.
    func testAStrayNoteFittingNeitherChordPushesNothing() {
        let notes = chord([60, 64, 67], at: 0, to: 2) + chord([61], at: 1.89, to: 1.95)   // C#
            + chord([65, 69, 72], at: 2, to: 4)
        let struck = strikes(voiceRestriking(notes: notes, chords: [segment("C", 0, 2), segment("F", 2, 4)],
                                               grid: grid()).notes)
        XCTAssertEqual(struck.map(\.start), [0, 1.89, 2])
        XCTAssertEqual(struck.map(\.end), [1.89, 2, 4])
        XCTAssertEqual(struck.map { Set($0.pitches.map { $0 % 12 }) }, [[0, 4, 7], [0, 4, 7], [5, 9, 0]],
                       "F starts on its own strike, struck once.")
    }

    /// A chord with no strikes of its own, into which the chords part still
    /// rings, gets a block at its start, struck again on each bar line inside
    /// it, at the default loudness (it replaces no notes). Where the part is
    /// silent it stays silent, unless filling is asked for.
    func testChordWithoutStrikesGetsABlockPerBar() {
        let notes = chord([60, 64, 67], at: 0, to: 2.4)                 // C rings into G
        let chords = [segment("C", 0, 2), segment("G", 2, 7)]
        let out = voiceRestriking(notes: notes, chords: chords, grid: grid())
        let struck = strikes(out.notes)
        XCTAssertEqual(struck.map(\.start), [0, 2, 4, 6])
        XCTAssertEqual(struck.map(\.end), [2, 4, 6, 7])
        XCTAssertEqual(chordsPart(out.notes).filter { $0.startTime >= 2 }.map(\.amplitude),
                       Array(repeating: ChordVoicer.Settings().defaultAmplitude, count: 9))
        XCTAssertEqual(out.blocks, 1)

        let silent = chord([60, 64, 67], at: 0, to: 1.9)                // C stops before G
        XCTAssertEqual(strikes(voiceRestriking(notes: silent, chords: chords, grid: grid()).notes).map(\.start), [0],
                       "A silent chords part stays silent.")
        var filling = Self.restriking
        filling.fillEmptySegments = true
        XCTAssertEqual(strikes(voiceRestriking(notes: silent, chords: chords, grid: grid(), settings: filling).notes)
            .map(\.start), [0, 2, 4, 6], "Filling gives it blocks anyway.")
    }

    /// A chord whose first strike comes late is struck at its start too when
    /// the chords part still rings there; after a rest it waits for its strike.
    func testLateFirstStrikeRestrikesOnlyOverARingingChord() {
        let notes = chord([60, 64, 67], at: 0, to: 2.8)      // C rings on into Am
            + chord([57, 60, 64], at: 3, to: 3.5)            // Am's first strike
            + chord([60, 65, 69], at: 5, to: 5.5)            // F after a rest
        let out = voiceRestriking(notes: notes, chords: [segment("C", 0, 2), segment("Am", 2, 4), segment("F", 4, 6)],
                                    grid: grid())
        XCTAssertEqual(strikes(out.notes).map(\.start), [0, 2, 3, 5])
        XCTAssertEqual(strikes(out.notes).map(\.end), [2, 3, 4, 6])
    }

    /// A segment whose notes mostly lie outside its chord, or whose label
    /// names no chord, keeps its transcribed notes; the others are voiced.
    func testSegmentsKeepTheirNotesWhenTheNameDoesNotFit() {
        let misfit = chord([61, 66, 70], at: 0, to: 1.9)            // C#, F#, A# under "C"
        let unnamed = chord([60, 64, 67], at: 2, to: 3.9)            // under "N"
        let mostly = chord([60, 64, 69], at: 4, to: 5.9)              // C, E fit C; A does not
        let melody = NoteEvent(startTime: 0, endTime: 6, pitch: 76, amplitude: 0.8, voice: .melody)
        let notes = misfit + unnamed + mostly + [melody]
        let out = voiceRestriking(notes: notes, chords: [segment("C", 0, 2), segment("N", 2, 4), segment("C", 4, 6)],
                                    grid: grid())
        XCTAssertEqual(out.misfits, 1)
        XCTAssertEqual(out.unnamed, 1)
        XCTAssertEqual(out.voiced, 1)
        for kept in misfit + unnamed { XCTAssertTrue(out.notes.contains(kept), "\(kept.pitch) at \(kept.startTime) is kept") }
        XCTAssertFalse(out.notes.contains { mostly.contains($0) }, "Two of three notes fit: the segment is voiced.")
        XCTAssertEqual(Set(chordsPart(out.notes).filter { $0.startTime == 4 }.map { $0.pitch % 12 }), [0, 4, 7])
        XCTAssertEqual(out.notes.filter { $0.voice == .melody }, [melody])
    }

    /// A stray note is too little evidence to overrule a chord's name. In a
    /// chord the part only rings through, a stray that fits neither it nor
    /// the next chord was its only note: judged on that note alone the chord
    /// kept it as played, and while the voicing before was cut at the change,
    /// the stray was all that sounded for the whole chord.
    func testAStrayNoteDoesNotSilenceAChordThePartRingsThrough() {
        let ringing = chord([55, 59, 62], at: 0, to: 4.95)     // G, ringing on through C
        let stray = chord([63], at: 4.9, to: 4.98)             // D#: neither C nor F
        let notes = ringing + stray + chord([65, 69, 72], at: 5, to: 7)
        let out = voiceRestriking(notes: notes, chords: [segment("G", 0, 1), segment("C", 1, 5), segment("F", 5, 7)],
                                    grid: grid())
        XCTAssertEqual(out.misfits, 0)
        XCTAssertEqual(out.voiced, 3)
        XCTAssertFalse(out.notes.contains(stray[0]), "The stray is replaced like the chord's other notes.")
        let struck = strikes(out.notes)
        XCTAssertEqual(struck.map(\.start), [0, 1, 4.9, 5])
        XCTAssertEqual(struck.map(\.end), [1, 4.9, 5, 7])
        XCTAssertEqual(struck.map { Set($0.pitches.map { $0 % 12 }) }, [[7, 11, 2], [0, 4, 7], [0, 4, 7], [5, 9, 0]])
        let silent = stride(from: 0.0, to: 7, by: 0.1).filter { t in
            !chordsPart(out.notes).contains { $0.startTime <= t && t < $0.endTime }
        }
        XCTAssertEqual(silent, [], "Where the part sounded as played, Simplified sounds too.")
    }

    /// Where the next chord keeps its notes as played or names no chord, the
    /// voicing before rings on into it as long as the notes it replaced did:
    /// cut at the change, it left silent what had sounded as played. A pitch
    /// that a kept note strikes stops there; the others ring on.
    func testAVoicingRingsOnIntoAChordKeptAsPlayed() {
        func silent(_ out: [NoteEvent], where played: [NoteEvent]) -> [Double] {
            stride(from: 0.0, to: 8, by: 0.05).filter { t in
                chordsPart(played).contains { $0.startTime <= t && t < $0.endTime }
                    && !chordsPart(out).contains { $0.startTime <= t && t < $0.endTime }
            }
        }

        // C rings a second into F, whose own notes (D#, F#, A#) don't fit it.
        let ringing = chord([60, 64, 67], at: 0, to: 3)
        let misfit = chord([63, 66, 70], at: 2.5, to: 4)
        var out = voiceRestriking(notes: ringing + misfit, chords: [segment("C", 0, 2), segment("F", 2, 4)],
                                    grid: grid())
        XCTAssertEqual(out.misfits, 1)
        for kept in misfit { XCTAssertTrue(out.notes.contains(kept)) }
        let voiced = chordsPart(out.notes).filter { !misfit.contains($0) }
        XCTAssertEqual(voiced.map(\.startTime), [0, 0, 0])
        XCTAssertEqual(voiced.map(\.endTime), [3, 3, 3], "C rings on to where its notes stopped, not to the change.")
        XCTAssertEqual(silent(out.notes, where: ringing + misfit), [])

        // The kept chord strikes G, a pitch of the C voicing: G stops there.
        let clashing = chord([63, 67, 70], at: 2.5, to: 4)
        out = voiceRestriking(notes: ringing + clashing, chords: [segment("C", 0, 2), segment("F", 2, 4)],
                                grid: grid())
        let rung = chordsPart(out.notes).filter { !clashing.contains($0) }
        XCTAssertEqual(Set(rung.map(\.pitch)), [60, 64, 67])
        XCTAssertEqual(rung.first { $0.pitch == 67 }?.endTime, 2.5, "G doesn't sound twice at once.")
        XCTAssertEqual(rung.filter { $0.pitch != 67 }.map(\.endTime), [3, 3])
        XCTAssertEqual(silent(out.notes, where: ringing + clashing), [])

        // A strike just before an "N" chord, ringing on through it.
        let g = chord([55, 59, 62], at: 0, to: 1.9)
        let late = chord([61, 63], at: 3.9, to: 5.5)
        out = voiceRestriking(notes: g + late, chords: [segment("G", 0, 2), segment("C", 2, 4), segment("N", 4, 6)],
                                grid: grid())
        XCTAssertEqual(out.unnamed, 1)
        let struck = strikes(out.notes)
        XCTAssertEqual(struck.map(\.start), [0, 3.9])
        XCTAssertEqual(struck.map(\.end), [2, 5.5], "G ends at the change (nothing rang past it); C rings into N.")
        XCTAssertEqual(struck.map { Set($0.pitches.map { $0 % 12 }) }, [[7, 11, 2], [0, 4, 7]])
        XCTAssertEqual(silent(out.notes, where: g + late), [])
    }

    /// No notes, no chords part, or no chords: nothing to do. The other
    /// parts are never touched.
    func testEmptyInputComesBackUnchanged() {
        XCTAssertEqual(voiceRestriking(notes: [], chords: [segment("C", 0, 2)], grid: grid()), .init(notes: []))
        let lines = [NoteEvent(startTime: 0, endTime: 1, pitch: 72, amplitude: 0.8, voice: .melody),
                     NoteEvent(startTime: 0, endTime: 1, pitch: 67, amplitude: 0.7, voice: .countermelody),
                     NoteEvent(startTime: 0, endTime: 1, pitch: 36, amplitude: 0.7, voice: .bass)]
        XCTAssertEqual(voiceRestriking(notes: lines, chords: [segment("C", 0, 2)], grid: grid()), .init(notes: lines),
                       "No chords part: no chords are added.")
        let withChords = lines + chord([60, 64, 67], at: 0, to: 1)
        XCTAssertEqual(voiceRestriking(notes: withChords, chords: [], grid: grid()), .init(notes: withChords))
        XCTAssertEqual(voiceRestriking(notes: withChords, chords: [segment("C", 0, 2)], grid: .empty).notes
            .filter { $0.voice != .chords }, lines)
    }

    // MARK: - Saved takes

    /// The style is saved only when it isn't the default, under a key older
    /// builds ignore; an unknown style opens as played.
    func testChordStyleIsSavedUnderAKeyOlderBuildsIgnore() throws {
        let notes = [NoteEvent(startTime: 0, endTime: 1, pitch: 60, amplitude: 0.6, voice: .chords)]
        let plain = try JSONEncoder().encode(SavedTakeContent(source: "music", notes: notes, sustain: []))
        let plainObject = try XCTUnwrap(JSONSerialization.jsonObject(with: plain) as? [String: Any])
        XCTAssertNil(plainObject["chordStyle"], "As played writes nothing new.")
        XCTAssertEqual(try JSONDecoder().decode(SavedTakeContent.self, from: plain).style, .asPlayed)

        let simple = try JSONEncoder().encode(SavedTakeContent(source: "music", notes: notes, sustain: [], chordStyle: .simplified))
        let simpleObject = try XCTUnwrap(JSONSerialization.jsonObject(with: simple) as? [String: Any])
        XCTAssertEqual(simpleObject["chordStyle"] as? String, "simplified")
        let reread = try JSONDecoder().decode(SavedTakeContent.self, from: simple)
        XCTAssertEqual(reread.style, .simplified)
        XCTAssertEqual(reread.noteEvents, notes)

        // How a build from before the style reads it (Prerelease 0.99, which
        // also reads the drum hits): the same keys as before.
        struct OlderBuildContent: Decodable {
            struct Note: Decodable { var start: Double; var end: Double; var pitch: Int; var amplitude: Double; var voice: UInt8 }
            struct Drum: Decodable { var time: Double; var kind: Int; var velocity: Double }
            var source: String
            var notes: [Note]
            var sustain: [SavedTakeContent.Span]
            var drums: [Drum]
        }
        let older = try JSONDecoder().decode(OlderBuildContent.self, from: simple)
        XCTAssertEqual(older.notes.map(\.pitch), [60])
        XCTAssertEqual(older.notes.map(\.voice), [Voice.chords.rawValue])
        XCTAssertTrue(older.drums.isEmpty)

        // A take 0.99 saved with drum hits, left simplified: both are written
        // back, read back, and the older build still finds its kit.
        let hits = [SavedTakeContent.LegacyDrum(time: 0.5, kind: 0, velocity: 0.8),
                    SavedTakeContent.LegacyDrum(time: 1, kind: 1, velocity: 0.9)]
        let both = try JSONEncoder().encode(SavedTakeContent(source: "music", notes: notes, sustain: [],
                                                             legacyDrums: hits, chordStyle: .simplified))
        let bothReread = try JSONDecoder().decode(SavedTakeContent.self, from: both)
        XCTAssertEqual(bothReread.style, .simplified)
        XCTAssertEqual(bothReread.legacyDrums, hits)
        XCTAssertEqual(bothReread.noteEvents, notes)
        let olderBoth = try JSONDecoder().decode(OlderBuildContent.self, from: both)
        XCTAssertEqual(olderBoth.drums.map(\.kind), [0, 1])
        XCTAssertEqual(olderBoth.notes.map(\.pitch), [60])

        let future = Data(#"{"source":"music","sustain":[],"notes":[],"chordStyle":"jazz"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(SavedTakeContent.self, from: future).style, .asPlayed)
        let odd = Data(#"{"source":"music","sustain":[],"notes":[],"chordStyle":7}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(SavedTakeContent.self, from: odd).style, .asPlayed,
                       "A style that isn't a string doesn't keep the take from opening.")
    }
}
