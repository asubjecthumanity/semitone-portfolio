import Foundation

/// Maps audio time to MIDI ticks for export, from a take's beat grid: each
/// detected beat lands on a quarter note and each downbeat on a bar line, while
/// tick 0 stays at audio time 0 so the file lines up with the original
/// recording when both start together.
///
/// - Every beat interval gets its own tempo (microseconds per quarter = the
///   interval); after the last beat the last tempo carries on.
/// - Before the first beat the grid is extrapolated at its first tempo. The
///   stretch up to the first downbeat, less any whole bars, is a pickup:
///   rounded to the nearest half beat, written as n/8 and given the tempo that
///   makes it last exactly its real duration. Under a quarter beat it is folded
///   into the first beat instead, so the first downbeat sits just after the
///   first bar line.
/// - Tempos stay within 20–400 BPM. A too-short interval (a spurious extra
///   beat) is merged with the ones after it under one tempo; a too-long one (a
///   gap) gets whole bars added, at about the grid's typical tempo. Beats keep
///   counting either way, so later downbeats stay on bar lines. A grid whose
///   typical beat is itself out of range is written in eighth-note (m/8) or
///   half-note (m/2) beats.
/// - Tempos are whole microseconds; rounding drift is caught up before it
///   reaches 20 µs, and the map gives the times the file actually plays.
/// - Bars repeat every `beatsPerMeasure` (1–16) beats from the first downbeat
///   that is one of the grid's beats (`BeatTracker` grids always are); no
///   downbeat means bars start on the first beat.
/// - Fewer than two beats, or a grid too fast to fit even when merged: 120 BPM
///   in 4/4.
nonisolated struct TempoMap {
    static let ticksPerQuarter = 480

    struct Tempo: Equatable {
        let tick: Int
        let microsecondsPerQuarter: Int

        var bpm: Double { 60_000_000 / Double(microsecondsPerQuarter) }
    }

    struct TimeSignature: Equatable {
        let tick: Int
        let numerator: Int
        /// A power of two.
        let denominator: Int
    }

    /// Sorted by tick; the first is at tick 0.
    let tempos: [Tempo]
    /// Sorted by tick; the first is at tick 0.
    let timeSignatures: [TimeSignature]
    /// When each tempo takes effect, in seconds, as the file plays.
    private let starts: [Double]

    /// Tempo limits, in seconds per quarter (400 and 20 BPM).
    private static let fastest = 0.15
    private static let slowest = 3.0
    private static let quarter = Double(ticksPerQuarter)
    /// Largest tick a MIDI delta time can reach from 0.
    private static let maxTick = 0x0FFF_FFFF

    init(grid: BeatGrid) {
        var beats: [Double] = []
        for time in grid.beats.filter({ $0.isFinite && $0 >= 0 }).sorted() where time > (beats.last ?? -1) {
            beats.append(time)
        }
        let meter = min(max(grid.beatsPerMeasure, 1), 16)
        if beats.count >= 2, let layout = Self.layout(beats: beats, downbeats: grid.downbeats, meter: meter) {
            self.init(spans: layout.spans, timeSignatures: layout.timeSignatures)
        } else {
            self.init(spans: [Span(start: 0, end: 0.5, ticks: Self.ticksPerQuarter)],
                      timeSignatures: [TimeSignature(tick: 0, numerator: 4, denominator: 4)])
        }
    }

    /// The tick at an audio time: a continuous, piecewise-linear map rounded to
    /// whole ticks, so never decreasing. Times before 0 map to tick 0.
    func tick(at seconds: Double) -> Int {
        guard seconds > 0 else { return 0 }
        let i = lastTempo { starts[$0] <= seconds }
        let exact = Double(tempos[i].tick) + (seconds - starts[i]) * 1e6 * Self.quarter / Double(tempos[i].microsecondsPerQuarter)
        return Int(min(exact, Double(Self.maxTick)).rounded())
    }

    /// The audio time at a tick (the inverse of `tick(at:)`).
    func seconds(atTick tick: Int) -> Double {
        guard tick > 0 else { return 0 }
        let i = lastTempo { tempos[$0].tick <= tick }
        return starts[i] + Double(tick - tempos[i].tick) * Double(tempos[i].microsecondsPerQuarter) / (1e6 * Self.quarter)
    }

    /// The last tempo for which `hasStarted` holds (binary search; the first always has).
    private func lastTempo(where hasStarted: (Int) -> Bool) -> Int {
        var lo = 0, hi = tempos.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if hasStarted(mid) { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    // MARK: - Layout

    /// Audio from `start` to `end` (seconds) spread over `ticks`.
    private struct Span {
        var start: Double
        var end: Double
        var ticks: Int

        var secondsPerQuarter: Double { (end - start) * TempoMap.quarter / Double(ticks) }
    }

    /// One tempo per span, in whole microseconds. Once rounding has drifted
    /// more than 20 µs from the audio, the next tempo absorbs the drift; until
    /// then tempos stay as detected (a steady 120 BPM reads 120, not 119.9998).
    private init(spans: [Span], timeSignatures: [TimeSignature]) {
        var tempos: [Tempo] = [], starts: [Double] = []
        var tick = 0, time = 0.0
        for span in spans {
            let start = abs(time - span.start) > 20e-6 ? time : span.start
            let exact = ((span.end - start) * 1e6 * Self.quarter / Double(span.ticks)).rounded()
            let micros = Int(min(max(exact, Self.fastest * 1e6), Self.slowest * 1e6))
            tempos.append(Tempo(tick: tick, microsecondsPerQuarter: micros))
            starts.append(time)
            tick += span.ticks
            time += Double(span.ticks) * Double(micros) / (1e6 * Self.quarter)
        }
        self.tempos = tempos
        self.starts = starts
        self.timeSignatures = timeSignatures
    }

    /// Spans from time 0 through the last beat, plus the meter; nil if the grid
    /// is too fast to fit the tempo range. `beats` is strictly increasing, >= 0.
    private static func layout(beats: [Double], downbeats: [Double], meter: Int)
        -> (spans: [Span], timeSignatures: [TimeSignature])? {
        let gaps = zip(beats.dropFirst(), beats).map { $0 - $1 }
        let typical = gaps.sorted()[gaps.count / 2]
        // Ticks per detected beat: a quarter note unless that tempo is out of range.
        let beat = typical < fastest ? ticksPerQuarter / 2 : typical > slowest ? ticksPerQuarter * 2 : ticksPerQuarter
        let bar = meter * beat
        let typicalQuarter = typical * quarter / Double(beat)

        // One span per beat interval. A too-short one absorbs the intervals
        // after it (the last one, those before it) until its tempo fits.
        var spans: [Span] = []
        for i in gaps.indices {
            if let last = spans.last, last.secondsPerQuarter < fastest {
                spans[spans.count - 1].end = beats[i + 1]
                spans[spans.count - 1].ticks += beat
            } else {
                spans.append(Span(start: beats[i], end: beats[i + 1], ticks: beat))
            }
        }
        while spans.count > 1, spans[spans.count - 1].secondsPerQuarter < fastest {
            let last = spans.removeLast()
            spans[spans.count - 1].end = last.end
            spans[spans.count - 1].ticks += last.ticks
        }
        guard spans[spans.count - 1].secondsPerQuarter >= fastest else { return nil }

        // A too-long one (a gap in the grid) gets whole bars of rest.
        for i in spans.indices where spans[i].secondsPerQuarter > slowest {
            addBars(to: &spans[i], bar: bar, typicalQuarter: typicalQuarter)
        }

        // Before the first beat: the first tempo carried back, rounded to half
        // beats. Under a quarter beat it joins the first span instead.
        let half = beat / 2
        let lead = beats[0]
        let halves = (lead * quarter / spans[0].secondsPerQuarter / Double(half)).rounded()
        let mostHalves = (lead * quarter / fastest / Double(half)).rounded(.down)
        var leadTicks = 0
        if halves >= 1, mostHalves >= 1 {
            let fewestHalves = max(1, (lead * quarter / slowest / Double(half)).rounded(.up))
            leadTicks = Int(min(max(halves, fewestHalves), mostHalves)) * half
            spans.insert(Span(start: 0, end: lead, ticks: leadTicks), at: 0)
        } else {
            spans[0].start = 0
            if spans[0].secondsPerQuarter > slowest {
                addBars(to: &spans[0], bar: bar, typicalQuarter: typicalQuarter)
            }
        }

        // Merged spans keep one beat's ticks per beat and added rests are whole
        // bars, so the first downbeat's place in its bar follows from its index.
        let tolerance = 0.25 * typical
        let firstDownbeat = downbeats.filter(\.isFinite).sorted().lazy.compactMap { time -> Int? in
            let i = beats.firstIndex { $0 >= time - tolerance } ?? beats.count
            return i < beats.count && abs(beats[i] - time) <= tolerance ? i : nil
        }.first ?? 0
        let pickup = (leadTicks + firstDownbeat * beat) % bar
        let denominator = 4 * ticksPerQuarter / beat
        var signatures: [TimeSignature] = []
        if pickup > 0 {
            signatures.append(TimeSignature(tick: 0, numerator: pickup / half, denominator: 2 * denominator))
        }
        signatures.append(TimeSignature(tick: pickup, numerator: meter, denominator: denominator))
        return (spans, signatures)
    }

    /// Lengthens a too-slow span by whole bars, bringing its tempo close to the
    /// typical one (seconds per quarter) and never past the limits. With at most
    /// 16 beats per bar, one bar can't overshoot: the range always has a fit.
    private static func addBars(to span: inout Span, bar: Int, typicalQuarter: Double) {
        let seconds = span.end - span.start
        func bars(atQuarter length: Double) -> Double {
            (seconds * quarter / length - Double(span.ticks)) / Double(bar)
        }
        let fewest = bars(atQuarter: slowest).rounded(.up)
        let most = bars(atQuarter: fastest).rounded(.down)
        span.ticks += Int(min(max(bars(atQuarter: typicalQuarter).rounded(), fewest), max(most, fewest))) * bar
    }
}

/// Writes a take as a Standard MIDI File (format 1, 480 ticks per quarter) on
/// the take's own tempo map (`TempoMap`), so bars and beats line up with the
/// music in a DAW while every note keeps its time in the audio.
///
/// Track 1 is the conductor: the song title, time signatures and tempi, and
/// the chord names as markers (FF 06) where each chord starts, so a DAW shows
/// the chart above the tracks. Then one track per part that has notes, each
/// named, with a General MIDI program:
/// - Piano (a piano take's `Voice.none` notes): 0 Acoustic Grand, plus the
///   sustain pedal (CC 64).
/// - Melody: 73 Flute — a plain, sustained lead that stands apart from the
///   chords on any GM player.
/// - Countermelody: 71 Clarinet — another sustained line, a reed against the
///   flute, so the two lines stay apart when they cross.
/// - Chords: 0 Acoustic Grand.
/// - Bass: 33 Electric Bass (finger).
/// Parts take channels 1, 2, 3… in that order. No drum track: the app doesn't
/// transcribe drums.
nonisolated enum MidiExport {
    /// How a note's `amplitude` maps to velocity (as in `MidiPlayer`).
    enum Dynamics {
        /// Piano model notes: amplitude is the detected velocity / 127.
        case detected
        /// Basic Pitch notes: amplitude is an activation, floored to keep quiet notes audible.
        case activation
    }

    /// The whole file. `title` names the song (the conductor track), and so
    /// do `chords`' labels its chord changes (markers on the conductor track);
    /// `sustain` goes on the Piano track, if there is one. Use `.detected`
    /// dynamics for piano model takes and `.activation` otherwise, as for playback.
    static func file(
        title: String,
        notes: [NoteEvent],
        sustain: [PedalEvent] = [],
        chords: [ChordSegment] = [],
        grid: BeatGrid,
        dynamics: Dynamics
    ) -> Data {
        let map = TempoMap(grid: grid)
        var tracks = [conductor(title: title, map: map, chords: chords)]

        var channel = 0
        for part in pitchedParts {
            let partNotes: [Note] = notes.compactMap { note in
                guard note.voice == part.voice, (0...127).contains(note.pitch),
                      note.startTime.isFinite, note.endTime.isFinite else { return nil }
                let start = map.tick(at: note.startTime)
                return Note(start: start, end: max(map.tick(at: note.endTime), start + 1), key: note.pitch,
                            velocity: velocity(amplitude: note.amplitude, dynamics: dynamics))
            }
            guard !partNotes.isEmpty else { continue }
            let pedal = part.voice == .none ? pedalSpans(sustain, map: map) : []
            tracks.append(track(name: part.name, channel: channel, program: part.program, notes: partNotes, pedal: pedal))
            channel += 1
        }

        var data = Data("MThd".utf8)
        data.append(contentsOf: bigEndian(6, bytes: 4) + bigEndian(1, bytes: 2)
                    + bigEndian(tracks.count, bytes: 2) + bigEndian(TempoMap.ticksPerQuarter, bytes: 2))
        for track in tracks {
            data.append(contentsOf: Array("MTrk".utf8) + bigEndian(track.count, bytes: 4) + track)
        }
        return data
    }

    /// A dated, unique export name, in the given time zone.
    static func fileName(for date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "Semitone %04d-%02d-%02d %02d%02d-%@.mid",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0,
                      UUID().uuidString)
    }

    // MARK: - Parts

    private static let pitchedParts: [(voice: Voice, name: String, program: Int)] = [
        (.none, "Piano", 0),
        (.melody, "Melody", 73),
        (.countermelody, "Countermelody", 71),
        (.chords, "Chords", 0),
        (.bass, "Bass", 33),
    ]

    private struct Note {
        var start: Int
        var end: Int
        let key: Int
        var velocity: Int
    }

    private static func velocity(amplitude: Double, dynamics: Dynamics) -> Int {
        let amplitude = amplitude.isFinite ? amplitude : 0
        let value: Double
        switch dynamics {
        case .detected: value = (amplitude * 127).rounded()
        case .activation: value = (amplitude * 95).rounded(.towardZero) + 38
        }
        return Int(min(max(value, 1), 127))
    }

    /// Pedal-down spans in ticks, each at least a tick long, overlaps merged.
    private static func pedalSpans(_ sustain: [PedalEvent], map: TempoMap) -> [(start: Int, end: Int)] {
        var spans: [(start: Int, end: Int)] = []
        let valid = sustain.filter { $0.startTime.isFinite && $0.endTime.isFinite }
        for pedal in valid.sorted(by: { $0.startTime < $1.startTime }) {
            let start = map.tick(at: pedal.startTime)
            let end = max(map.tick(at: pedal.endTime), start + 1)
            if let last = spans.last, start < last.end {
                spans[spans.count - 1].end = max(last.end, end)
            } else {
                spans.append((start, end))
            }
        }
        return spans
    }

    /// A channel holds one of each key at a time: notes struck on the same tick
    /// become one, and an earlier note ends a tick before the same key strikes
    /// again (as `MidiPlayer` does), never shorter than a tick.
    private static func separated(_ notes: [Note]) -> [Note] {
        var out: [Note] = []
        for note in notes.sorted(by: { ($0.key, $0.start) < ($1.key, $1.start) }) {
            if let last = out.last, last.key == note.key, note.start <= last.end {
                if note.start == last.start {
                    out[out.count - 1].end = max(last.end, note.end)
                    out[out.count - 1].velocity = max(last.velocity, note.velocity)
                    continue
                }
                out[out.count - 1].end = max(last.start + 1, note.start - 1)
            }
            out.append(note)
        }
        return out
    }

    // MARK: - Tracks

    /// A chord label as marker text: ASCII, since SMF text events are read
    /// as ASCII or Latin-1 by most DAWs ("D#m7♭5/A" is written "D#m7b5/A",
    /// which `ChordSymbol` reads back). "N" and empty labels are no chord.
    static func markerText(_ label: String) -> String? {
        let ascii = String(label.replacingOccurrences(of: "♭", with: "b").replacingOccurrences(of: "♯", with: "#")
            .unicodeScalars.filter { $0.isASCII && $0.value >= 0x20 && $0.value < 0x7F }.map(Character.init))
            .trimmingCharacters(in: .whitespaces)
        return ascii.isEmpty || ascii == "N" ? nil : ascii
    }

    private static func conductor(title: String, map: TempoMap, chords: [ChordSegment]) -> [UInt8] {
        var events: [(tick: Int, bytes: [UInt8])] = map.timeSignatures.map { signature in
            (signature.tick, [0xFF, 0x58, 0x04, UInt8(signature.numerator),
                              UInt8(signature.denominator.trailingZeroBitCount),
                              UInt8(96 / signature.denominator),   // MIDI clocks per metronome click
                              8])                                  // 32nds per quarter
        }
        events += map.tempos.map { tempo in
            let micros = tempo.microsecondsPerQuarter
            return (tempo.tick, [0xFF, 0x51, 0x03, UInt8(micros >> 16 & 0xFF), UInt8(micros >> 8 & 0xFF), UInt8(micros & 0xFF)])
        }
        events += chords.filter { $0.startTime.isFinite }.sorted { $0.startTime < $1.startTime }.compactMap { chord in
            guard let text = markerText(chord.label) else { return nil }
            return (map.tick(at: chord.startTime), [0xFF, 0x06] + variableLength(text.utf8.count) + Array(text.utf8))
        }
        var writer = TrackWriter()
        if !title.isEmpty { writer.meta(0x03, Array(title.utf8)) }
        // Stable by tick: a time signature comes before a tempo, and both
        // before a marker, on the same tick.
        for event in events.enumerated().sorted(by: { ($0.element.tick, $0.offset) < ($1.element.tick, $1.offset) }) {
            writer.add(event.element.bytes, at: event.element.tick)
        }
        return writer.finished()
    }

    private static func track(name: String, channel: Int, program: Int, notes: [Note],
                              pedal: [(start: Int, end: Int)] = []) -> [UInt8] {
        let ch = UInt8(channel)
        // Same tick: note-offs, then pedal up, pedal down, note-ons.
        var events: [(tick: Int, rank: Int, bytes: [UInt8])] = []
        for note in separated(notes) {
            events.append((note.start, 3, [0x90 | ch, UInt8(note.key), UInt8(note.velocity)]))
            events.append((note.end, 0, [0x80 | ch, UInt8(note.key), 64]))
        }
        for span in pedal {
            events.append((span.start, 2, [0xB0 | ch, 64, 127]))
            events.append((span.end, 1, [0xB0 | ch, 64, 0]))
        }
        var writer = TrackWriter()
        writer.meta(0x03, Array(name.utf8))
        writer.add([0xC0 | ch, UInt8(program)], at: 0)
        let ordered = events.enumerated().sorted {
            ($0.element.tick, $0.element.rank, $0.offset) < ($1.element.tick, $1.element.rank, $1.offset)
        }
        for event in ordered { writer.add(event.element.bytes, at: event.element.tick) }
        return writer.finished()
    }

    /// One track's events with delta times, no running status.
    private struct TrackWriter {
        private var bytes: [UInt8] = []
        private var tick = 0

        /// `tick` must not go back.
        mutating func add(_ event: [UInt8], at tick: Int) {
            bytes += variableLength(tick - self.tick) + event
            self.tick = tick
        }

        mutating func meta(_ type: UInt8, _ data: [UInt8], at tick: Int = 0) {
            add([0xFF, type] + variableLength(data.count) + data, at: tick)
        }

        /// The finished track, End of Track included, without its chunk header.
        func finished() -> [UInt8] {
            bytes + [0x00, 0xFF, 0x2F, 0x00]
        }
    }

    /// MIDI variable-length quantity: 7 bits per byte, most significant first.
    private static func variableLength(_ value: Int) -> [UInt8] {
        var value = min(max(value, 0), 0x0FFF_FFFF)
        var out = [UInt8(value & 0x7F)]
        value >>= 7
        while value > 0 {
            out.insert(UInt8(value & 0x7F) | 0x80, at: 0)
            value >>= 7
        }
        return out
    }

    private static func bigEndian(_ value: Int, bytes: Int) -> [UInt8] {
        (0..<bytes).reversed().map { UInt8(value >> ($0 * 8) & 0xFF) }
    }
}
