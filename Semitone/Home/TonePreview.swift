import SwiftUI
import Synchronization

/// What a Tone's row on Home shows of its notes, worked out once, off the
/// main thread, from the take's saved content: the opening bars its
/// thumbnail draws (coordinates are fractions: x across the window shown,
/// y down the roll, 0 = top), the key it's in and the chords it plays (for
/// the row's line under the title and for Home's search, `ToneSearch`).
/// Also whether its notes are the piano model's, for its long-press menu.
nonisolated struct TonePreview: Sendable {
    /// Its raw value is what a saved take notes (`SavedTake.kind`).
    enum Kind: String, Sendable {
        /// Solo piano: one roll, the left hand deeper (when it has one).
        case piano
        /// One line (an instrument or a voice): one roll.
        case instrument
        /// A whole song: a lane per part.
        case song

        /// Its name as Home shows it, on its filter chip and in its rows,
        /// and as the Transcription menu names it.
        var title: String {
            switch self {
            case .piano: "Piano"
            case .instrument: "Instrument"
            case .song: "Song"
            }
        }
    }

    /// Its raw value is what a saved take notes (`SavedTake.parts`). In the
    /// order the app lists the parts (`Voice.parts`).
    enum Part: String, Sendable, Hashable, CaseIterable {
        case melody, countermelody, chords, bass

        /// The lane's letter. The countermelody's is "Ct": "Cm" would read
        /// as C minor beside a song's chords, and it fits the letters'
        /// column (about 14 pt at 12 pt heavy, M 11 pt) with room to spare.
        var letter: String {
            switch self {
            case .melody: "M"
            case .countermelody: "Ct"
            case .chords: "C"
            case .bass: "B"
            }
        }

        var name: String {
            switch self {
            case .melody: "melody"
            case .countermelody: "countermelody"
            case .chords: "chords"
            case .bass: "bass"
            }
        }

        /// The notes' part this lane draws (unsplit notes go with the chords).
        var voice: Voice {
            switch self {
            case .melody: .melody
            case .countermelody: .countermelody
            case .chords: .chords
            case .bass: .bass
            }
        }
    }

    struct Bar: Sendable {
        var x0: Double
        var x1: Double
        var y: Double
        /// The MIDI pitch (a chord block: its lowest note's).
        var pitch: Int
        /// On a song's roll, the part the note belongs to.
        var part: Part? = nil
    }

    struct Lane: Sendable {
        let part: Part
        var bars: [Bar]
    }

    let kind: Kind
    /// The notes are the high-accuracy piano model's (a Piano take saved
    /// with them), as the piano-model switch in the Tone's long-press menu
    /// shows until the Tone is opened.
    var pianoModel = false
    /// Piano and Instrument.
    var roll: [Bar] = []
    /// How many semitones the roll spans, top to bottom.
    var rollSpan: Double = 14
    /// The pitch at the roll's top (y 0), so the keys beside it line up.
    var rollTop: Double = 74
    /// Piano: the pitch the left hand plays below, drawn deeper; nil when
    /// the take has no left hand of its own (`handSplit`), and every note is
    /// drawn alike.
    var leftHandBelow: Int?
    /// Song: every part's notes on one roll (`roll`, each bar with its
    /// part), as the thumbnail draws it, and the parts the take has, in M, Ct,
    /// C, B order, as lanes. Chords come as a
    /// block per strum (the notes struck together), at mid-lane.
    var lanes: [Lane] = []

    var parts: [Part] { lanes.map(\.part) }

    /// The key the whole take is in (`key(of:)`); nil for one with too few
    /// notes to say.
    var key: MusicalKey?
    /// The chords it plays for long enough to name (`chords(of:notes:)`),
    /// as the chord analyzer labels them, in the order they first sound.
    var chords: [String] = []

    /// A few made-up bars for the empty library's sample card: a tune over a
    /// left hand, like the start of a piano sketch.
    static let sample: TonePreview = {
        var preview = TonePreview(kind: .piano)
        preview.rollSpan = 24
        preview.rollTop = 79
        let right: [(Double, Double, Double)] = [(0, 0.15, 0.18), (0.18, 0.28, 0.39), (0.3, 0.51, 0.06),
                                                 (0.54, 0.66, 0.52), (0.69, 0.87, 0.3), (0.9, 1, 0.13)]
        let left: [(Double, Double, Double)] = [(0, 0.41, 0.9), (0.44, 0.87, 0.76), (0.9, 1, 0.95)]
        preview.roll = right.map { Bar(x0: $0.0, x1: $0.1, y: $0.2, pitch: 72) }
            + left.map { Bar(x0: $0.0, x1: $0.1, y: $0.2, pitch: 48) }
        preview.leftHandBelow = 60
        return preview
    }()

    /// How many bars a thumbnail shows: the incipit of the piece.
    static func barsShown(_ kind: Kind) -> Int { kind == .song ? 8 : 4 }
    /// Without a beat, a window of this many seconds.
    static func secondsShown(_ kind: Kind) -> Double { kind == .song ? 16 : 8 }

    /// The take's kind from its saved mode and parts: an any-instrument take
    /// that came out as a single melody line is an Instrument tone. A
    /// countermelody is a second line, so a take with one is a song.
    static func kind(mode: String, notes: [SavedTakeContent.Note]) -> Kind {
        guard mode == TranscriptionMode.music.rawValue else { return .piano }
        let lines = Set(notes.map(\.resolvedVoice)).subtracting([.none])
        if lines.isSubset(of: [.melody]) { return .instrument }
        return .song
    }

    /// A song's parts, in M, Ct, C, B order: a lane for each part it has
    /// (notes without one go with the chords). A countermelody saved as its
    /// stand-in for older builds (chords, with the part under "part") gets
    /// its own lane.
    static func parts(notes: [SavedTakeContent.Note]) -> [Part] {
        var voices = Set(notes.map(\.resolvedVoice))
        if voices.remove(.none) != nil { voices.insert(.chords) }
        return Voice.parts.compactMap { voice in
            voices.contains(voice) ? Part.allCases.first { $0.voice == voice } : nil
        }
    }

    /// Where a piano take's hands part, if they do: the pitch its left hand
    /// plays below. That's the widest gap in the pitches it plays (of two as
    /// wide, the one nearer middle C) that is at least a fourth, has a fifth
    /// of the notes or more on each side, and has notes on both sides
    /// sounding together: two hands, not one line with a leap, nor the top of
    /// a broken chord over a tune. Nil when there's none (one line, or hands
    /// that cross or keep close), and the roll draws every note in its bright
    /// shade, so a take played low, mostly below middle C, isn't sunk in the
    /// deeper one.
    static func handSplit(_ notes: [SavedTakeContent.Note]) -> Int? {
        let pitches = Set(notes.map(\.pitch)).sorted()
        let gaps = zip(pitches, pitches.dropFirst())
            .map { (width: $1 - $0, upper: $1) }
            .filter { $0.width >= 5 }
            .sorted { ($0.width, -abs($0.upper - 60)) > ($1.width, -abs($1.upper - 60)) }
        for (_, upper) in gaps {
            let low = notes.filter { $0.pitch < upper }
            let high = notes.filter { $0.pitch >= upper }
            guard min(low.count, high.count) * 5 >= notes.count else { continue }
            // At least a quarter of the left hand's notes sound with the right hand's.
            let together = low.filter { l in high.contains { $0.start < l.end && l.start < $0.end } }.count
            if together * 4 >= low.count { return upper }
        }
        return nil
    }

    /// The fewest notes, and pitch classes among them, a take needs for a
    /// key: a single note or a two-note figure has none worth showing.
    static let keyMinimumNotes = 8
    static let keyMinimumPitchClasses = 3
    /// A chord sounding for less than this in the whole take is a passing
    /// harmony, not one to search by.
    static let chordMinimumSeconds = 0.75

    /// The take's key: a duration and loudness weighted count of each pitch
    /// class over all of its notes (not just the opening bars the thumbnail
    /// shows), against the Krumhansl-Kessler profiles the chord stage
    /// weighs its chords by (`HarmonyStage.estimateKey`).
    static func key(of notes: [SavedTakeContent.Note]) -> MusicalKey? {
        func pitchClass(_ note: SavedTakeContent.Note) -> Int { ((note.pitch % 12) + 12) % 12 }
        guard notes.count >= keyMinimumNotes,
              Set(notes.map(pitchClass)).count >= keyMinimumPitchClasses else { return nil }
        var chroma = [Double](repeating: 0, count: 12)
        for note in notes {
            chroma[pitchClass(note)] += max(note.end - note.start, 0) * max(note.amplitude, 0)
        }
        return HarmonyStage.estimateKey(chroma)
    }

    /// The chords the take plays, named from its harmony as the roll names
    /// them as it's played (`ChordAnalyzer.segments`): all of a piano
    /// take's notes, a song's chords and bass (and notes in no part), but
    /// not its melody or countermelody, whose passing notes would name
    /// chords that aren't there. One line has no chords. A label stays only
    /// if it sounds for `chordMinimumSeconds` in all, so passing harmonies
    /// don't fill the search.
    ///
    /// Every harmony note is read, however long the take: the analyzer's
    /// sweep is linear, and Take Five's 2,084 chords and bass notes take it
    /// 13 ms (twice that many, 18 ms), against the 0.7 s the opening's beat
    /// tracking costs `make` on the same song.
    static func chords(of kind: Kind, notes: [SavedTakeContent.Note]) -> [String] {
        let harmony: [SavedTakeContent.Note]
        switch kind {
        case .instrument: return []
        case .piano: harmony = notes
        case .song: harmony = notes.filter { [.chords, .bass, .none].contains($0.resolvedVoice) }
        }
        let events = harmony.map {
            NoteEvent(startTime: $0.start, endTime: $0.end, pitch: $0.pitch, amplitude: $0.amplitude)
        }
        var labels: [String] = []
        var seconds: [String: Double] = [:]
        for segment in ChordAnalyzer.segments(events) {
            if seconds[segment.label] == nil { labels.append(segment.label) }
            seconds[segment.label, default: 0] += segment.endTime - segment.startTime
        }
        return labels.filter { seconds[$0, default: 0] >= chordMinimumSeconds }
    }

    // MARK: Building

    static func make(take: SavedTake, content: SavedTakeContent) -> TonePreview {
        let kind = kind(mode: take.mode, notes: content.notes)
        let pianoModel = content.source == "piano"
        let notes = content.notes.sorted { $0.start < $1.start }
        guard let first = notes.first?.start else { return TonePreview(kind: kind, pianoModel: pianoModel) }

        // Find the beat over the opening (tracking a whole long take would take seconds).
        let horizon = first + 45
        let early = notes.filter { $0.start < horizon }.map {
            NoteEvent(startTime: $0.start, endTime: min($0.end, horizon), pitch: $0.pitch, amplitude: $0.amplitude,
                      voice: $0.resolvedVoice)
        }
        let tracked = BeatTracker.track(notes: early, duration: min(take.duration, horizon), beatsPerBar: nil)
        let beatsPerBar = max(tracked.beatsPerBar, 1)
        let downbeats = zip(tracked.beats, tracked.barPositions).filter { $0.1 % beatsPerBar == 0 }.map(\.0)

        // The window: from the bar the music starts in (for a song, where its
        // melody comes in, past any intro), a few bars long.
        let melodyEntry = kind == .song ? notes.first { $0.resolvedVoice == .melody }?.start : nil
        let entry = min(melodyEntry ?? first, first + 20)
        var start = entry
        var end = entry + secondsShown(kind)
        if downbeats.count >= 2 {
            let barLength = zip(downbeats.dropFirst(), downbeats).map { $0 - $1 }.sorted()[(downbeats.count - 1) / 2]
            let opening = downbeats.lastIndex { $0 <= entry + 0.08 }
            start = opening.map { downbeats[$0] } ?? max(0, (downbeats.first ?? entry) - barLength)
            let n = barsShown(kind)
            if let opening, opening + n < downbeats.count {
                end = downbeats[opening + n]
            } else {
                end = start + Double(n) * barLength
            }
        }
        let span = max(end - start, 0.5)
        func x(_ t: Double) -> Double { (t - start) / span }

        var preview = TonePreview(kind: kind, pianoModel: pianoModel)
        preview.key = key(of: notes)
        preview.chords = chords(of: kind, notes: notes)

        let shown = notes.filter { $0.end > start && $0.start < end }
        func bars(_ notes: [SavedTakeContent.Note], minimumSpan: Int,
                  part: (SavedTakeContent.Note) -> Part? = { _ in nil }) -> (bars: [Bar], span: Double, top: Double) {
            guard let lo = notes.map(\.pitch).min(), let hi = notes.map(\.pitch).max() else { return ([], Double(minimumSpan), 74) }
            // Centre the notes in at least `minimumSpan` semitones, so a narrow line doesn't fill the roll.
            let pad = max(0, minimumSpan - (hi - lo))
            let bottom = Double(lo) - Double(pad) / 2, top = Double(hi) + Double(pad) / 2
            let bars = notes.prefix(700).map { n in
                Bar(x0: max(x(n.start), 0), x1: min(x(n.end), 1),
                    y: top > bottom ? (top - Double(n.pitch)) / (top - bottom) : 0.5,
                    pitch: n.pitch, part: part(n))
            }
            return (bars, top - bottom, top)
        }
        /// A block for each strum: from the notes struck together (within
        /// 80 ms) until the next strum, or until they've all ended.
        func strums(_ notes: [SavedTakeContent.Note]) -> [Bar] {
            var blocks: [Bar] = []
            var group: [SavedTakeContent.Note] = []
            func close(next: Double?) {
                guard let first = group.first else { return }
                let end = min(group.map(\.end).max() ?? first.end, next ?? .infinity)
                blocks.append(Bar(x0: max(x(first.start), 0), x1: min(x(end), 1), y: 0.5,
                                  pitch: group.map(\.pitch).min() ?? 60))
                group = []
            }
            for n in notes.prefix(700) {
                if let first = group.first, n.start - first.start > 0.08 { close(next: n.start) }
                group.append(n)
            }
            close(next: nil)
            return blocks
        }

        switch kind {
        case .piano, .instrument:
            (preview.roll, preview.rollSpan, preview.rollTop) = bars(shown, minimumSpan: 14)
            if kind == .piano { preview.leftHandBelow = handSplit(Array(shown.prefix(700))) }
        case .song:
            let present = parts(notes: content.notes)
            func part(of note: SavedTakeContent.Note) -> Part? {
                switch note.resolvedVoice {
                case .melody: .melody
                case .countermelody: .countermelody
                case .bass: .bass
                case .chords, .none: .chords
                }
            }
            let parted = shown.filter { part(of: $0).map(present.contains) ?? false }
            (preview.roll, preview.rollSpan, preview.rollTop) = bars(parted, minimumSpan: 14, part: part(of:))
            for part in present {
                switch part {
                case .melody, .countermelody, .bass:
                    let lane = shown.filter { $0.resolvedVoice == part.voice }
                    preview.lanes.append(Lane(part: part, bars: bars(lane, minimumSpan: 8).bars))
                case .chords:
                    let lane = shown.filter { $0.resolvedVoice == .chords || $0.resolvedVoice == .none }
                    preview.lanes.append(Lane(part: part, bars: strums(lane)))
                }
            }
        }
        return preview
    }
}

nonisolated extension SavedTake {
    /// The take with what its content holds noted: its kind, and a song's
    /// parts. A take that keeps Prerelease 0.99's drum hits is noted as that
    /// build noted it, a song with a "drums" part, so its tile there keeps
    /// the kit's lane; this build skips the name (`savedKind`, `savedParts`).
    func noting(_ content: SavedTakeContent) -> SavedTake {
        var take = noting(TonePreview.kind(mode: mode, notes: content.notes), parts: TonePreview.parts(notes: content.notes))
        if !content.legacyDrums.isEmpty, mode == TranscriptionMode.music.rawValue {
            take.kind = TonePreview.Kind.song.rawValue
            take.parts = TonePreview.parts(notes: content.notes).map(\.rawValue) + ["drums"]
        }
        return take
    }

    /// The take with its kind noted, and its parts if it's a song.
    func noting(_ kind: TonePreview.Kind, parts: [TonePreview.Part]) -> SavedTake {
        var take = self
        take.kind = kind.rawValue
        take.parts = kind == .song ? parts.map(\.rawValue) : nil
        return take
    }

    /// Its kind as saved; nil for a take saved before kinds were kept.
    /// Prerelease 0.99 noted a take with drums as a song with a "drums" part,
    /// and this build no longer shows drums: a song whose other parts are at
    /// most a melody is one line now, an Instrument tone, as `TonePreview.kind`
    /// finds from its notes (so its row doesn't change once they're read).
    var savedKind: TonePreview.Kind? {
        guard let saved = kind.flatMap(TonePreview.Kind.init(rawValue:)) else { return nil }
        if saved == .song, let parts = savedParts, parts.allSatisfy({ $0 == .melody }) { return .instrument }
        return saved
    }

    /// A song's parts as saved, leaving out names this build doesn't show
    /// ("drums", from Prerelease 0.99); nil if they weren't saved (an older
    /// take, or not a song).
    var savedParts: [TonePreview.Part]? { parts.map { $0.compactMap(TonePreview.Part.init(rawValue:)) } }
}

/// Builds Tone previews on demand and keeps them for the session. Loads run
/// one at a time on a utility queue, and a row scrolled away before its
/// turn costs nothing. A Tone asked for twice before its preview is built
/// (its row, and the search reading the whole library) is built once: the
/// second asker waits for the first build.
@MainActor @Observable
final class TonePreviewStore {
    private(set) var previews: [UUID: TonePreview] = [:]
    /// What each preview was built from, so an updated take (refined, renamed) is rebuilt.
    @ObservationIgnored private var stamps: [UUID: Stamp] = [:]
    /// The builds queued or running, by take.
    @ObservationIgnored private var building: [UUID: Build] = [:]
    @ObservationIgnored private let queue = DispatchQueue(label: "Semitone.TonePreviews", qos: .utility)

    nonisolated fileprivate struct Stamp: Equatable, Sendable {
        let noteCount: Int
        let duration: Double
        let mode: String
    }

    func preview(for take: SavedTake) -> TonePreview? { previews[take.id] }

    /// Builds the take's preview unless it's built already; returns it when
    /// it's newly built (to one asker only, should two wait on one build).
    @discardableResult
    func load(_ take: SavedTake) async -> TonePreview? {
        let stamp = Stamp(noteCount: take.noteCount, duration: take.duration, mode: take.mode)
        guard stamps[take.id] != stamp else { return nil }
        let build: Build
        if let queued = building[take.id], queued.stamp == stamp, queued.join() {
            build = queued
        } else {
            build = Build(stamp: stamp)
            _ = build.join()
            building[take.id] = build
            build.task = Task { [queue] in
                await withCheckedContinuation { continuation in
                    queue.async {
                        // Every asker went away while it waited: skip it, it
                        // loads again when it's asked for again.
                        guard !build.isSkipped else { return continuation.resume(returning: nil) }
                        let content = try? TakeLibrary.content(of: take.id)
                        continuation.resume(returning: content.map { TonePreview.make(take: take, content: $0) })
                    }
                }
            }
        }
        let built = await withTaskCancellationHandler {
            await build.task?.value
        } onCancel: {
            build.leave()
        }
        if building[take.id] === build { building[take.id] = nil }
        guard let built, stamps[take.id] != stamp else { return nil }
        stamps[take.id] = stamp
        previews[take.id] = built
        return built
    }

    /// Forget takes that are gone.
    func retain(_ takes: [SavedTake]) {
        let ids = Set(takes.map(\.id))
        for id in previews.keys where !ids.contains(id) {
            previews[id] = nil
            stamps[id] = nil
        }
    }
}

/// One preview being built, and how many are waiting for it. When the last
/// of them goes away (its row scrolled off, the search cleared) before the
/// queue reaches it, it's skipped; one that joins after that starts a new
/// build rather than wait for a skipped one.
nonisolated private final class Build: @unchecked Sendable {
    let stamp: TonePreviewStore.Stamp
    /// Set once, on the main actor, before anything awaits it.
    var task: Task<TonePreview?, Never>?
    private let state = Mutex((waiting: 0, skipped: false))

    init(stamp: TonePreviewStore.Stamp) { self.stamp = stamp }

    var isSkipped: Bool { state.withLock { $0.skipped } }

    /// Waits for it too, unless it's been skipped.
    func join() -> Bool {
        state.withLock { state in
            guard !state.skipped else { return false }
            state.waiting += 1
            return true
        }
    }

    /// An asker was cancelled: with none left, it's skipped.
    func leave() {
        state.withLock { state in
            state.waiting -= 1
            if state.waiting <= 0 { state.skipped = true }
        }
    }
}

nonisolated extension MusicalKey {
    /// "E♭ minor", "F♯ major": the tonic spelled as musicians write the key
    /// (the side of the circle of fifths with fewer accidentals: D♭ major
    /// rather than C♯, but C♯ minor rather than D♭), with real flats and
    /// sharps, which VoiceOver reads as "flat" and "sharp". For the row's
    /// line under its title (the chord stage's `label` names it the way
    /// the analyzer names chords, with sharps).
    var displayName: String {
        let majors = ["C", "D♭", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
        let minors = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "G♯", "A", "B♭", "B"]
        let tonic = ((tonic % 12) + 12) % 12
        return minor ? minors[tonic] + " minor" : majors[tonic] + " major"
    }
}
