import XCTest
@testable import Semitone

/// Home's search (`ToneSearch`): titles without case or accents, kinds,
/// keys however they're spelled and chords by name, every word of a query
/// finding something. Then what it searches: a key's name as the rows show
/// it (`MusicalKey.displayName`), and the key and chords a Tone's preview
/// reads from its notes (`TonePreview.key(of:)`, `TonePreview.chords`).
final class ToneSearchTests: XCTestCase {
    private typealias Tone = ToneSearch.Tone

    private static let takeFive = Tone(title: "Take Five", kind: .song, key: MusicalKey(tonic: 3, minor: true),
                                       chords: ["D#m", "A#m7"])
    /// In A minor, with no Am chord of its own: "Am" finds it by its key.
    private static let etude = Tone(title: "Evening étude", kind: .piano, key: MusicalKey(tonic: 9, minor: true),
                                    chords: ["Dm", "E"])
    private static let waltz = Tone(title: "Waltz", kind: .piano, key: MusicalKey(tonic: 3, minor: false),
                                    chords: ["D#", "G#"])
    private static let ballad = Tone(title: "Ballad", kind: .song, key: MusicalKey(tonic: 4, minor: true),
                                     chords: ["Em", "C"])
    private static let band = Tone(title: "Band demo", kind: .song, key: MusicalKey(tonic: 0, minor: false),
                                   chords: ["C", "Am", "F", "G"])
    private static let folk = Tone(title: "Folk song", kind: .piano, key: MusicalKey(tonic: 7, minor: false),
                                   chords: ["G", "C/E", "D"])
    private static let blues = Tone(title: "Blues", kind: .piano, key: MusicalKey(tonic: 7, minor: false),
                                    chords: ["G7", "C7"])
    private static let bossa = Tone(title: "Bossa", kind: .song, key: MusicalKey(tonic: 5, minor: false),
                                    chords: ["F", "A#"])
    private static let rain = Tone(title: "Piano in the rain", kind: .song)
    /// Its notes not read yet: no key, no chords.
    private static let hummed = Tone(title: "Hummed line", kind: .instrument)

    private static let all = [takeFive, etude, waltz, ballad, band, folk, blues, bossa, rain, hummed]

    /// The titles of the Tones the query finds, in library order.
    private func found(_ query: String) -> [String] {
        let search = ToneSearch(query)
        return Self.all.filter(search.matches).map(\.title)
    }

    func testAnEmptyQueryFindsEverything() {
        for query in ["", "   ", "\n\t "] {
            XCTAssertTrue(ToneSearch(query).isEmpty, "“\(query)”")
            XCTAssertEqual(found(query).count, Self.all.count, "“\(query)”")
        }
    }

    func testTitlesAreFoundWithoutCaseOrAccents() {
        XCTAssertEqual(found("take"), ["Take Five"])
        XCTAssertEqual(found("TAKE five"), ["Take Five"])
        XCTAssertEqual(found("  take   five "), ["Take Five"], "Spaces don't count.")
        XCTAssertEqual(found("etude"), ["Evening étude"])
        XCTAssertEqual(found("Étude"), ["Evening étude"])
        XCTAssertEqual(found("evening etude"), ["Evening étude"])
        XCTAssertEqual(found("hum"), ["Hummed line"], "A Tone not read yet is found by its title.")
        XCTAssertEqual(found("zzqx"), [], "Nothing matches nonsense.")
        XCTAssertEqual(found("five take"), ["Take Five"], "Every word begins a word of the title.")
        XCTAssertEqual(found("take fi"), ["Take Five"], "The whole query, from the start of a word of the title.")
        XCTAssertEqual(found("evening et"), ["Evening étude"])
        XCTAssertEqual(found("ke fi"), [], "Not from the middle of one.")
        XCTAssertEqual(found("ive take"), [], "Otherwise each word begins a word of the title.")
    }

    /// A recording is titled with the moment it was made, whose "recording"
    /// holds c, d, e and g: a chord or a key doesn't find it by its title.
    func testAChordOrKeyDoesNotFindLettersInsideATitlesWords() {
        let recording = Tone(title: "Recording Oct 14, 2026 at 9:41 AM", kind: .piano,
                             key: MusicalKey(tonic: 2, minor: false), chords: ["D", "G"])
        for query in ["C", "c", "E", "Eb", "e minor", "Am F", "g7", "c/e"] {
            XCTAssertFalse(ToneSearch(query).matches(recording), "“\(query)”")
        }
        XCTAssertTrue(ToneSearch("D").matches(recording), "Its own key and chords still find it.")
        XCTAssertTrue(ToneSearch("G").matches(recording))
        XCTAssertTrue(ToneSearch("rec").matches(recording), "And its title, from the start of a word.")
        XCTAssertTrue(ToneSearch("recording 9").matches(recording))
        XCTAssertTrue(ToneSearch("oct 14").matches(recording))

        let pebble = Tone(title: "Pebble", kind: .instrument)
        XCTAssertFalse(ToneSearch("eb").matches(pebble))
        XCTAssertTrue(ToneSearch("peb").matches(pebble))
    }

    /// A title that names its key is found by it, whatever key its notes
    /// read as (a minor piece often reads as its relative major).
    func testAKeyFindsATitleThatNamesIt() {
        let nocturne = Tone(title: "Nocturne in E minor", kind: .piano, key: MusicalKey(tonic: 7, minor: false))
        XCTAssertTrue(ToneSearch("nocturne e minor").matches(nocturne))
        XCTAssertTrue(ToneSearch("E minor").matches(nocturne))
        XCTAssertTrue(ToneSearch("G major").matches(nocturne), "And by the key its notes are in.")
        XCTAssertFalse(ToneSearch("nocturne c minor").matches(nocturne))
        let flat = Tone(title: "Prelude in E-flat minor", kind: .piano)
        XCTAssertTrue(ToneSearch("prelude eb minor").matches(flat), "However the title spells it.")
        XCTAssertFalse(ToneSearch("D# minor").matches(flat), "A title is matched by its words, not by pitch.")
        let evening = Tone(title: "Evening", kind: .piano, key: MusicalKey(tonic: 0, minor: true))
        XCTAssertFalse(ToneSearch("e minor").matches(evening), "Not the e of \"Evening\".")
    }

    func testKindsAreFoundByName() {
        XCTAssertEqual(found("piano"), ["Evening étude", "Waltz", "Folk song", "Blues", "Piano in the rain"],
                       "Piano Tones, and a title with the word.")
        XCTAssertEqual(found("Instrument"), ["Hummed line"], "A Tone not read yet is found by its kind.")
        XCTAssertEqual(found("song"), ["Take Five", "Ballad", "Band demo", "Folk song", "Bossa", "Piano in the rain"])
        XCTAssertEqual(found("pia"), found("piano"), "As much of the name as is typed.")
    }

    func testAKeyIsFoundHoweverItIsSpelled() {
        for query in ["E♭ minor", "eb minor", "Ebm", "e flat minor", "E-flat minor", "D# minor", "d#m", "D♯ min",
                      "eb min", "ebminor"] {
            XCTAssertEqual(found(query), ["Take Five"], "“\(query)” finds E♭ minor, not E♭ major or E minor.")
        }
        XCTAssertEqual(found("E♭ major"), ["Waltz"])
        XCTAssertEqual(found("eb"), ["Take Five", "Waltz"], "A note name alone: either key on it.")
        XCTAssertEqual(found("e minor"), ["Ballad"])
        XCTAssertEqual(found("e major"), [])
        XCTAssertEqual(found("minor"), ["Take Five", "Evening étude", "Ballad"], "Every minor key.")
        XCTAssertEqual(found("major"), ["Waltz", "Band demo", "Folk song", "Blues", "Bossa"])
        XCTAssertEqual(found("minor ballad"), ["Ballad"])
        XCTAssertEqual(found("hummed minor"), [], "A Tone whose key isn't known has none.")
    }

    func testChordsAreFoundByName() {
        XCTAssertEqual(found("Am"), ["Evening étude", "Band demo"], "An Am chord, or the key of A minor.")
        XCTAssertEqual(found("am"), found("AM"))
        XCTAssertEqual(found("Am F"), ["Band demo"], "Every word must find something.")
        XCTAssertEqual(found("G7"), ["Blues"], "G7, not G.")
        XCTAssertEqual(found("Bb"), ["Bossa"], "B♭ is the analyzer's A#.")
        XCTAssertEqual(found("B♭"), ["Bossa"])
        XCTAssertEqual(found("C/E"), ["Folk song"])
        XCTAssertEqual(found("C"), ["Ballad", "Band demo", "Folk song"],
                       "C finds C over E too, and the key of C major, but not C7.")
        XCTAssertEqual(found("D#m"), ["Take Five"])
        XCTAssertEqual(found("A#m7"), ["Take Five"])
        XCTAssertEqual(found("Bbm7"), ["Take Five"], "Enharmonics, with a quality.")
        XCTAssertEqual(found("Dm"), ["Evening étude"])
        XCTAssertEqual(found("Cmaj7"), [])
    }

    func testNormalising() {
        XCTAssertEqual(ToneSearch.normalise("  E♭   Minor "), "eb minor")
        XCTAssertEqual(ToneSearch.normalise("F-sharp major"), "f# major")
        XCTAssertEqual(ToneSearch.normalise("B flat"), "bb")
        XCTAssertEqual(ToneSearch.normalise("C♯m7♭5"), "c#m7b5")
        XCTAssertEqual(ToneSearch.normalise("ÉVENING étude"), "evening etude")
        XCTAssertEqual(ToneSearch.normalise("Deflated flat tyre"), "deflated flat tyre",
                       "Only a note letter takes \"flat\".")
    }

    // MARK: Keys

    func testKeysAreNamedAsMusiciansWriteThem() {
        let majors = ["C major", "D♭ major", "D major", "E♭ major", "E major", "F major",
                      "F♯ major", "G major", "A♭ major", "A major", "B♭ major", "B major"]
        let minors = ["C minor", "C♯ minor", "D minor", "E♭ minor", "E minor", "F minor",
                      "F♯ minor", "G minor", "G♯ minor", "A minor", "B♭ minor", "B minor"]
        for tonic in 0..<12 {
            XCTAssertEqual(MusicalKey(tonic: tonic, minor: false).displayName, majors[tonic])
            XCTAssertEqual(MusicalKey(tonic: tonic, minor: true).displayName, minors[tonic])
        }
    }

    /// A take of `notes`, its kind found from them as a save finds it.
    private func preview(_ notes: [NoteEvent], mode: TranscriptionMode = .piano) -> TonePreview {
        let duration = (notes.map(\.endTime).max() ?? 0) + 0.5
        let take = SavedTake(id: UUID(), title: "Test", createdAt: Date(), duration: duration,
                             mode: mode.rawValue, noteCount: notes.count)
        return TonePreview.make(take: take, content: SavedTakeContent(source: mode.rawValue, notes: notes, sustain: []))
    }

    /// Chords of the given pitches, `seconds` each, one after another from `start`.
    private func blocks(_ chords: [[Int]], from start: Double = 0, seconds: Double = 2,
                        voice: Voice = .none) -> [NoteEvent] {
        chords.enumerated().flatMap { i, pitches in
            pitches.map {
                NoteEvent(startTime: start + Double(i) * seconds, endTime: start + Double(i + 1) * seconds - 0.05,
                          pitch: $0, amplitude: 0.6, voice: voice)
            }
        }
    }

    func testACMajorScaleAndItsPrimaryChordsAreInCMajor() {
        // The scale up, then I–IV–V–I.
        let scale = [60, 62, 64, 65, 67, 69, 71, 72].enumerated().map { i, pitch in
            NoteEvent(startTime: Double(i) * 0.25, endTime: Double(i) * 0.25 + 0.22, pitch: pitch, amplitude: 0.7)
        }
        let chords = blocks([[48, 52, 55], [53, 57, 60], [55, 59, 62], [48, 52, 55]], from: 2.5)
        let built = preview(scale + chords)
        XCTAssertEqual(built.kind, .piano)
        XCTAssertEqual(built.key, MusicalKey(tonic: 0, minor: false))
        XCTAssertEqual(built.chords, ["C", "F", "G"], "Each once, in the order they first sound.")
    }

    func testAnAMinorProgressionIsInAMinor() {
        let built = preview(blocks([[57, 60, 64], [50, 53, 57], [52, 56, 59], [57, 60, 64]]))
        XCTAssertEqual(built.key, MusicalKey(tonic: 9, minor: true))
        XCTAssertEqual(built.key?.displayName, "A minor")
        XCTAssertEqual(built.chords, ["Am", "Dm", "E"])
    }

    /// The key and chords are the whole take's, not the opening bars' the
    /// thumbnail shows: eight seconds of C major, then half a minute of A
    /// minor, is in A minor, with the chords only heard after the opening.
    func testKeyAndChordsComeFromTheWholeTake() {
        let opening = blocks([[48, 52, 55], [53, 57, 60], [55, 59, 62], [48, 52, 55]])
        let rest = blocks(Array(repeating: [[57, 60, 64], [50, 53, 57], [52, 56, 59]], count: 5).flatMap { $0 }, from: 8)
        let built = preview(opening + rest)
        XCTAssertGreaterThan(built.roll.count, 0)
        XCTAssertLessThan(built.roll.count, (opening + rest).count / 2, "The thumbnail shows the opening alone.")
        XCTAssertEqual(built.key, MusicalKey(tonic: 9, minor: true))
        XCTAssertTrue(built.chords.contains("Dm"), "\(built.chords)")
        XCTAssertTrue(built.chords.contains("E"), "\(built.chords)")
    }

    func testTooFewNotesHaveNoKey() {
        let seven = (0..<7).map { NoteEvent(startTime: Double($0), endTime: Double($0) + 0.9, pitch: [60, 64, 67][$0 % 3], amplitude: 0.6) }
        XCTAssertNil(preview(seven).key, "Seven notes are too few.")
        let two = (0..<12).map { NoteEvent(startTime: Double($0), endTime: Double($0) + 0.9, pitch: $0 % 2 == 0 ? 60 : 67, amplitude: 0.6) }
        XCTAssertNil(preview(two).key, "A two-note figure has no key worth showing.")
        XCTAssertNil(preview([]).key)
        XCTAssertEqual(preview([]).chords, [])
    }

    func testOneLineHasNoChords() {
        // An arpeggiated C major line: its notes alone would name C.
        let line = (0..<16).map { i in
            NoteEvent(startTime: Double(i) * 0.3, endTime: Double(i) * 0.3 + 0.28, pitch: [60, 64, 67, 72][i % 4],
                      amplitude: 0.6, voice: .melody)
        }
        let built = preview(line, mode: .music)
        XCTAssertEqual(built.kind, .instrument)
        XCTAssertEqual(built.chords, [])
        XCTAssertEqual(built.key, MusicalKey(tonic: 0, minor: false), "One line still has a key.")
    }

    /// A song's chords are its chords and bass: a melody's notes against
    /// them would name other chords.
    func testASongsChordsComeFromItsChordsAndBassAlone() {
        let chords = blocks([[60, 64, 67], [65, 69, 72], [67, 71, 74]], voice: .chords)
        let bass = blocks([[36], [41], [43]], voice: .bass)
        // A melody a second above each chord's notes, all the way through.
        let melody = blocks([[74, 78], [79, 83], [81, 85]], voice: .melody)
        let built = preview(chords + bass + melody, mode: .music)
        XCTAssertEqual(built.kind, .song)
        XCTAssertEqual(built.chords, ["C", "F", "G"])
    }

    /// A chord heard for a moment is passing, not one to search by.
    func testPassingChordsAreLeftOut() {
        let held = blocks([[60, 64, 67]], seconds: 3)
        let passing = blocks([[62, 65, 69]], from: 3, seconds: 0.5)
        let back = blocks([[60, 64, 67]], from: 3.5, seconds: 3)
        XCTAssertEqual(preview(held + passing + back).chords, ["C"])
    }

    /// Take Five as the song scoreboard has it (2,530 notes, 5:30), when the
    /// benchmark songs are on this Mac (they aren't in the repository):
    /// its key is the one it's written in, and reading it stays quick
    /// enough for the utility queue Home's rows load on.
    func testTakeFiveIsInEFlatMinorAndQuickToRead() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "bench/songs/bitmidi/take-five/truth.json")
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("The benchmark songs aren't here.") }
        struct Truth: Decodable {
            struct Note: Decodable { let on: Double, off: Double, pitch: Int, velocity: Double, part: String? }
            let notes: [Note]
        }
        let truth = try JSONDecoder().decode(Truth.self, from: data)
        let notes = truth.notes.map { n in
            NoteEvent(startTime: n.on, endTime: max(n.off, n.on + 0.05), pitch: n.pitch, amplitude: n.velocity / 127,
                      voice: ["melody": .melody, "chords": .chords, "bass": .bass,
                              "countermelody": .countermelody][n.part ?? ""] ?? .none)
        }
        let start = Date()
        let built = preview(notes, mode: .music)
        let seconds = Date().timeIntervalSince(start)
        print("Take Five: \(notes.count) notes, make() \(String(format: "%.2f", seconds)) s, key \(built.key?.displayName ?? "none"), chords \(built.chords)")
        XCTAssertEqual(built.key, MusicalKey(tonic: 3, minor: true))
        XCTAssertTrue(built.chords.contains("D#m"), "\(built.chords)")
        XCTAssertLessThan(seconds, 3)
    }
}
