import Foundation
import AudioToolbox

// Checks Semitone/Audio/MidiExport.swift: builds files from synthetic takes,
// reads them back with Apple's MIDI file parser (and an independent byte-level
// reader) and compares against the original times, including the chord-name
// markers and a chords part simplified by ChordVoicer. See build.sh.
//
// usage: midiexporttest [output directory for the .mid files]

// MARK: - Reporting

var failures: [String] = []
var checkCount = 0
var caseName = ""

func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
    checkCount += 1
    if !condition { failures.append("\(caseName): \(message())") }
}

func ms(_ seconds: Double) -> String { String(format: "%.2f ms", seconds * 1000) }

/// Deterministic numbers (SplitMix64).
struct Random {
    var state: UInt64

    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }

    mutating func uniform(_ range: ClosedRange<Double>) -> Double {
        range.lowerBound + next() * (range.upperBound - range.lowerBound)
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        min(range.lowerBound + Int(next() * Double(range.count)), range.upperBound)
    }
}

// MARK: - Byte-level reader (independent of AudioToolbox)

struct RawEvent {
    let tick: Int
    /// Status and data; meta events as [0xFF, type] + body.
    let bytes: [UInt8]
}

/// Strict SMF reader: chunk framing, no running status or sysex, and exactly
/// one End of Track closing each track. Nil if anything is off.
func readRaw(_ data: Data) -> (format: Int, division: Int, tracks: [[RawEvent]])? {
    let b = [UInt8](data)
    var p = 0
    func take(_ n: Int) -> [UInt8]? {
        guard n >= 0, p + n <= b.count else { return nil }
        defer { p += n }
        return Array(b[p..<p + n])
    }
    func int(_ n: Int) -> Int? { take(n).map { $0.reduce(0) { $0 << 8 | Int($1) } } }
    func vlq() -> Int? {
        var value = 0
        for _ in 0..<4 {
            guard let byte = take(1)?[0] else { return nil }
            value = value << 7 | Int(byte & 0x7F)
            if byte < 0x80 { return value }
        }
        return nil
    }

    guard take(4) == Array("MThd".utf8), int(4) == 6,
          let format = int(2), let count = int(2), let division = int(2) else { return nil }
    var tracks: [[RawEvent]] = []
    for _ in 0..<count {
        guard take(4) == Array("MTrk".utf8), let length = int(4) else { return nil }
        let end = p + length
        var tick = 0
        var events: [RawEvent] = []
        while p < end {
            guard let delta = vlq(), let status = take(1)?[0] else { return nil }
            tick += delta
            if status == 0xFF {
                guard let type = take(1)?[0], let length = vlq(), let body = take(length) else { return nil }
                events.append(RawEvent(tick: tick, bytes: [0xFF, type] + body))
            } else if (0x80..<0xF0).contains(status) {
                let size = [0xC0, 0xD0].contains(status & 0xF0) ? 1 : 2
                guard let body = take(size), body.allSatisfy({ $0 < 0x80 }) else { return nil }
                events.append(RawEvent(tick: tick, bytes: [status] + body))
            } else {
                return nil
            }
        }
        let ends = events.filter { $0.bytes == [0xFF, 0x2F] }.count
        guard p == end, ends == 1, events.last?.bytes == [0xFF, 0x2F] else { return nil }
        tracks.append(events)
    }
    guard p == b.count else { return nil }
    return (format, division, tracks)
}

// MARK: - AudioToolbox reader

struct LoadedNote {
    let beat: Double
    let duration: Double
    let key: Int
    let velocity: Int
    let channel: Int
}

struct LoadedTrack {
    var name: String?
    var programs: [(channel: Int, program: Int)] = []
    var notes: [LoadedNote] = []
    var controls: [(beat: Double, channel: Int, number: Int, value: Int)] = []
}

final class LoadedFile {
    let sequence: MusicSequence
    let tracks: [LoadedTrack]
    let tempos: [(beat: Double, bpm: Double)]
    /// Marker meta events (FF 06) wherever AudioToolbox put them: the tempo
    /// track or a regular one.
    let markers: [(beat: Double, text: String)]

    init?(_ data: Data) {
        var sequence: MusicSequence?
        guard NewMusicSequence(&sequence) == noErr, let sequence else { return nil }
        guard MusicSequenceFileLoadData(sequence, data as CFData, .midiType, []) == noErr else {
            DisposeMusicSequence(sequence)
            return nil
        }
        self.sequence = sequence

        var tempoTrack: MusicTrack?
        MusicSequenceGetTempoTrack(sequence, &tempoTrack)
        var tempos: [(Double, Double)] = []
        var markers: [(Double, String)] = []
        func marker(_ beat: Double, _ type: MusicEventType, _ pointer: UnsafeRawPointer) {
            guard type == kMusicEventType_Meta, pointer.load(as: UInt8.self) == 0x06 else { return }
            let length = Int(pointer.load(fromByteOffset: 4, as: UInt32.self))
            let body = (0..<length).map { pointer.load(fromByteOffset: 8 + $0, as: UInt8.self) }
            markers.append((beat, String(decoding: body, as: UTF8.self)))
        }
        if let tempoTrack {
            Self.forEach(tempoTrack) { beat, type, pointer in
                if type == kMusicEventType_ExtendedTempo { tempos.append((beat, pointer.load(as: Double.self))) }
                marker(beat, type, pointer)
            }
        }
        self.tempos = tempos

        var count: UInt32 = 0
        MusicSequenceGetTrackCount(sequence, &count)
        var tracks: [LoadedTrack] = []
        for i in 0..<count {
            var track: MusicTrack?
            MusicSequenceGetIndTrack(sequence, i, &track)
            var loaded = LoadedTrack()
            if let track {
                Self.forEach(track) { beat, type, pointer in
                    switch type {
                    case kMusicEventType_Meta:
                        let meta = pointer.load(as: UInt8.self)
                        let length = Int(pointer.load(fromByteOffset: 4, as: UInt32.self))
                        let body = (0..<length).map { pointer.load(fromByteOffset: 8 + $0, as: UInt8.self) }
                        if meta == 0x03 { loaded.name = String(decoding: body, as: UTF8.self) }
                        marker(beat, type, pointer)
                    case kMusicEventType_MIDINoteMessage:
                        let note = pointer.load(as: MIDINoteMessage.self)
                        loaded.notes.append(LoadedNote(beat: beat, duration: Double(note.duration), key: Int(note.note),
                                                       velocity: Int(note.velocity), channel: Int(note.channel)))
                    case kMusicEventType_MIDIChannelMessage:
                        let message = pointer.load(as: MIDIChannelMessage.self)
                        let channel = Int(message.status & 0x0F)
                        switch message.status & 0xF0 {
                        case 0xC0: loaded.programs.append((channel, Int(message.data1)))
                        case 0xB0: loaded.controls.append((beat, channel, Int(message.data1), Int(message.data2)))
                        default: break
                        }
                    default: break
                    }
                }
            }
            tracks.append(loaded)
        }
        self.tracks = tracks
        self.markers = markers
    }

    deinit { DisposeMusicSequence(sequence) }

    func seconds(atBeat beat: Double) -> Double {
        var seconds: Float64 = 0
        MusicSequenceGetSecondsForBeats(sequence, beat, &seconds)
        return seconds
    }

    func beat(atSeconds seconds: Double) -> Double {
        var beat: MusicTimeStamp = 0
        MusicSequenceGetBeatsForSeconds(sequence, seconds, &beat)
        return beat
    }

    /// Apple's bar / beat / tick reading of a position (1-based bar and beat).
    func barBeat(atTick tick: Int) -> (bar: Int, beat: Int, subbeat: Int) {
        var time = CABarBeatTime(bar: 0, beat: 0, subbeat: 0, subbeatDivisor: 0, reserved: 0)
        MusicSequenceBeatsToBarBeatTime(sequence, Double(tick) / 480, 480, &time)
        return (Int(time.bar), Int(time.beat), Int(time.subbeat))
    }

    private static func forEach(_ track: MusicTrack, _ body: (Double, MusicEventType, UnsafeRawPointer) -> Void) {
        var iterator: MusicEventIterator?
        guard NewMusicEventIterator(track, &iterator) == noErr, let iterator else { return }
        defer { DisposeMusicEventIterator(iterator) }
        var hasEvent: DarwinBoolean = false
        MusicEventIteratorHasCurrentEvent(iterator, &hasEvent)
        while hasEvent.boolValue {
            var beat: MusicTimeStamp = 0
            var type: MusicEventType = 0
            var pointer: UnsafeRawPointer?
            var size: UInt32 = 0
            MusicEventIteratorGetEventInfo(iterator, &beat, &type, &pointer, &size)
            if let pointer { body(beat, type, pointer) }
            MusicEventIteratorNextEvent(iterator)
            MusicEventIteratorHasCurrentEvent(iterator, &hasEvent)
        }
    }
}

// MARK: - Cases

struct Case {
    var name: String
    var grid: BeatGrid
    var notes: [NoteEvent] = []
    var sustain: [PedalEvent] = []
    /// Chord segments, written as markers on the conductor track.
    var chords: [ChordSegment] = []
    var dynamics: MidiExport.Dynamics = .detected
    /// Expected part tracks, in order.
    var parts: [(name: String, channel: Int, program: Int)]
    /// Expected time signatures.
    var signatures: [(tick: Int, numerator: Int, denominator: Int)]
    /// Ticks per detected beat, to check every beat sits on the beat grid; nil skips that.
    var beatTicks: Int? = 480
    /// The pickup was under a quarter beat: the first downbeat sits inside the first beat.
    var foldedFirstDownbeat = false
    /// Expect exactly one tempo per beat interval, plus the pickup's.
    var tempoPerInterval = true
    /// Or exactly this many tempi.
    var tempoCount: Int?
}

let meterDenominators = [1: 0, 2: 1, 4: 2, 8: 3, 16: 4, 32: 5]

func steadyGrid(first: Double, interval: Double, count: Int, meter: Int, firstDownbeat: Int) -> BeatGrid {
    let beats = (0..<count).map { first + interval * Double($0) }
    return BeatGrid(beats: beats, downbeats: stride(from: firstDownbeat, to: count, by: meter).map { beats[$0] },
                    beatsPerMeasure: meter, bpm: 60 / interval)
}

func randomNotes(_ random: inout Random, count: Int, until end: Double, voices: [Voice] = [.none]) -> [NoteEvent] {
    (0..<count).map { _ in
        let start = random.uniform(0...end)
        return NoteEvent(startTime: start, endTime: start + random.uniform(0.04...1.6), pitch: random.int(28...100),
                         amplitude: random.uniform(0.02...1), voice: voices[random.int(0...voices.count - 1)])
    }
}

var random = Random(state: 20260927)
var cases: [Case] = []

do { // Steady 4/4 at 120 BPM from 0.73 s: 1.46 beats before the first downbeat -> 3/8 pickup.
    let grid = steadyGrid(first: 0.73, interval: 0.5, count: 40, meter: 4, firstDownbeat: 0)
    var notes = randomNotes(&random, count: 120, until: 21)
    notes.append(NoteEvent(startTime: 0, endTime: 0.4, pitch: 48, amplitude: 0.7))   // at time zero
    notes += grid.downbeats.map { NoteEvent(startTime: $0, endTime: $0 + 0.3, pitch: 36, amplitude: 0.9) }
    cases.append(Case(name: "steady 4/4 from 0.73 s", grid: grid, notes: notes,
                      parts: [("Piano", 0, 0)], signatures: [(0, 3, 8), (720, 4, 4)]))
}

do { // 3/4 around 100 BPM drifting +-5%, first beat 0.21 s, downbeat on the third beat -> 2.5-beat pickup.
    var beats = [0.21]
    for k in 0..<44 { beats.append(beats.last! + 0.6 * (1 + 0.05 * sin(2 * .pi * Double(k) / 17))) }
    let grid = BeatGrid(beats: beats, downbeats: stride(from: 2, to: beats.count, by: 3).map { beats[$0] },
                        beatsPerMeasure: 3, bpm: 100)
    cases.append(Case(name: "3/4 drifting with pickup", grid: grid,
                      notes: randomNotes(&random, count: 100, until: 28), dynamics: .activation,
                      parts: [("Piano", 0, 0)], signatures: [(0, 5, 8), (1200, 3, 4)]))
}

do { // 4/4 with a spurious beat 3 ms after another and a 9 s hole.
    var beats = (0..<12).map { 0.4 + 0.5 * Double($0) }
    beats.insert(beats[5] + 0.003, at: 6)
    let resume = beats.last! + 9
    beats += (0..<12).map { resume + 0.5 * Double($0) }
    let grid = BeatGrid(beats: beats, downbeats: stride(from: 1, to: beats.count, by: 4).map { beats[$0] },
                        beatsPerMeasure: 4, bpm: 120)
    var notes = randomNotes(&random, count: 90, until: 23)
    notes += grid.downbeats.map { NoteEvent(startTime: $0, endTime: $0 + 0.2, pitch: 40, amplitude: 0.8) }
    // 24 intervals, the 3 ms one merged with the next, plus the pickup.
    cases.append(Case(name: "absurd intervals", grid: grid, notes: notes, parts: [("Piano", 0, 0)],
                      signatures: [(0, 4, 8), (960, 4, 4)], beatTicks: nil, tempoPerInterval: false, tempoCount: 24))
}

do { // No grid: 120 BPM, 4/4, no pickup.
    cases.append(Case(name: "empty grid", grid: .empty, notes: randomNotes(&random, count: 40, until: 10),
                      parts: [("Piano", 0, 0)], signatures: [(0, 4, 4)], beatTicks: nil, tempoPerInterval: false))
}

do { // Piano with pedal; the first downbeat 0.1 s in (a sixth of a beat) folds into the first beat.
    let grid = steadyGrid(first: 0.1, interval: 0.6, count: 30, meter: 4, firstDownbeat: 0)
    var notes = randomNotes(&random, count: 80, until: 18)
    notes += [
        NoteEvent(startTime: 1.0, endTime: 2.0, pitch: 60, amplitude: 0.5),    // overlaps the next C4
        NoteEvent(startTime: 1.5, endTime: 2.5, pitch: 60, amplitude: 0.6),
        NoteEvent(startTime: 3.0, endTime: 3.5, pitch: 62, amplitude: 0.5),    // ends where the next D4 starts
        NoteEvent(startTime: 3.5, endTime: 4.0, pitch: 62, amplitude: 0.5),
        NoteEvent(startTime: 5.0, endTime: 5.4, pitch: 64, amplitude: 0.3),    // same key, same time: one note
        NoteEvent(startTime: 5.0, endTime: 5.9, pitch: 64, amplitude: 0.8),
        NoteEvent(startTime: 6.0, endTime: 6.0, pitch: 65, amplitude: 0.5),    // zero length
        NoteEvent(startTime: 7.0, endTime: 7.3, pitch: 67, amplitude: 0),      // silent
        NoteEvent(startTime: 7.2, endTime: 7.4, pitch: 69, amplitude: 1.2),    // too loud
    ]
    let sustain = [PedalEvent(startTime: 0.02, endTime: 1.4), PedalEvent(startTime: 1.4, endTime: 3.1),
                   PedalEvent(startTime: 4.0, endTime: 4.0), PedalEvent(startTime: 6.2, endTime: 9.75),
                   PedalEvent(startTime: 12, endTime: 17.5)]
    cases.append(Case(name: "piano with pedal, folded pickup", grid: grid, notes: notes, sustain: sustain,
                      parts: [("Piano", 0, 0)], signatures: [(0, 4, 4)], foldedFirstDownbeat: true))
}

do { // Any instrument at 128 BPM, first beat 0.2 s, downbeat on the fourth beat -> 3.5-beat pickup.
    let grid = steadyGrid(first: 0.2, interval: 60.0 / 128, count: 48, meter: 4, firstDownbeat: 3)
    var notes = randomNotes(&random, count: 160, until: 23, voices: [.melody, .chords, .bass])
    notes += grid.downbeats.map { NoteEvent(startTime: $0, endTime: $0 + 0.4, pitch: 40, amplitude: 1, voice: .bass) }
    cases.append(Case(name: "any instrument, three parts", grid: grid, notes: notes, dynamics: .activation,
                      parts: [("Melody", 0, 73), ("Chords", 1, 0), ("Bass", 2, 33)],
                      signatures: [(0, 7, 8), (1680, 4, 4)]))
}

do { // All four parts: the countermelody gets its own track between melody and chords.
    let grid = steadyGrid(first: 0.5, interval: 0.5, count: 40, meter: 4, firstDownbeat: 0)
    cases.append(Case(name: "any instrument, four parts", grid: grid,
                      notes: randomNotes(&random, count: 120, until: 19, voices: [.melody, .countermelody, .chords, .bass]),
                      dynamics: .activation,
                      parts: [("Melody", 0, 73), ("Countermelody", 1, 71), ("Chords", 2, 0), ("Bass", 3, 33)],
                      signatures: [(0, 2, 8), (480, 4, 4)]))
}

do { // Only chords and bass: missing parts are skipped, channels stay compact.
    let grid = steadyGrid(first: 0.5, interval: 0.5, count: 20, meter: 4, firstDownbeat: 0)
    cases.append(Case(name: "any instrument, two parts", grid: grid,
                      notes: randomNotes(&random, count: 80, until: 10, voices: [.chords, .bass]), dynamics: .activation,
                      parts: [("Chords", 0, 0), ("Bass", 1, 33)], signatures: [(0, 2, 8), (480, 4, 4)]))
}

do { // Tracked at 460 BPM (double time): written in eighth-note beats, 4/8 bars.
    let grid = steadyGrid(first: 0.5, interval: 60.0 / 460, count: 120, meter: 4, firstDownbeat: 2)
    cases.append(Case(name: "460 BPM grid in eighths", grid: grid, notes: randomNotes(&random, count: 60, until: 16),
                      parts: [("Piano", 0, 0)], signatures: [(0, 4, 16), (480, 4, 8)], beatTicks: 240))
}

do { // 5 s before the first beat: whole bars of lead-in, then a 2.5-beat pickup.
    let grid = steadyGrid(first: 5.0, interval: 60.0 / 90, count: 30, meter: 3, firstDownbeat: 1)
    cases.append(Case(name: "long lead-in", grid: grid, notes: randomNotes(&random, count: 60, until: 25),
                      parts: [("Piano", 0, 0)], signatures: [(0, 5, 8), (1200, 3, 4)]))
}

do { // Chord names as markers: every label the app writes, plus ones that name no chord.
    let grid = steadyGrid(first: 0.5, interval: 0.5, count: 40, meter: 4, firstDownbeat: 0)
    let labels = ["C", "Am7", "D#m7♭5/A", "", "Gsus4", "N", "F/A", "Bbmaj7", "E7/G#", "Caug"]
    let chords = labels.enumerated().map { ChordSegment(startTime: 0.5 + 2 * Double($0.offset),
                                                        endTime: 2.5 + 2 * Double($0.offset), label: $0.element) }
        + [ChordSegment(startTime: .nan, endTime: 1, label: "D")]   // not a time: no marker
    cases.append(Case(name: "chord markers", grid: grid,
                      notes: randomNotes(&random, count: 80, until: 19, voices: [.melody, .chords, .bass]),
                      chords: chords, dynamics: .activation,
                      parts: [("Melody", 0, 73), ("Chords", 1, 0), ("Bass", 2, 33)], signatures: [(0, 2, 8), (480, 4, 4)]))
}

do { // Simplified: the Chords track holds ChordVoicer's voicings, the other parts as played.
    let grid = steadyGrid(first: 0, interval: 0.5, count: 33, meter: 4, firstDownbeat: 0)
    var notes: [NoteEvent] = []
    let shapes = [[48, 52, 55, 60, 64], [45, 52, 57, 60], [41, 53, 57, 60, 65], [43, 50, 55, 59, 62]]
    for (bar, shape) in shapes.enumerated() {
        let t = Double(bar) * 4
        for beat in [0.0, 1.0, 2.5] {
            notes += shape.map { NoteEvent(startTime: t + beat + 0.01 * Double($0 % 3), endTime: t + beat + 0.6,
                                           pitch: $0, amplitude: 0.5, voice: .chords) }
        }
        notes.append(NoteEvent(startTime: t, endTime: t + 3.8, pitch: shape[0] - 12, amplitude: 0.7, voice: .bass))
        notes.append(NoteEvent(startTime: t + 0.5, endTime: t + 1.5, pitch: 72 + bar, amplitude: 0.8, voice: .melody))
    }
    let chords = ["C", "Am", "F", "G"].enumerated().map {
        ChordSegment(startTime: Double($0.offset) * 4, endTime: Double($0.offset) * 4 + 4, label: $0.element)
    }
    let voiced = ChordVoicer.voice(notes: notes, chords: chords, grid: grid)
    caseName = "simplified chords"
    expect(voiced.voiced == 4 && voiced.misfits == 0, "voiced \(voiced.voiced), misfits \(voiced.misfits)")
    expect(voiced.notes.filter { $0.voice != .chords } == notes.filter { $0.voice != .chords }, "other parts changed")
    expect(voiced.notes.filter { $0.voice == .chords }.count == 4 * 3 * 3, "three-note voicings, three strikes a bar")
    cases.append(Case(name: "simplified chords", grid: grid, notes: voiced.notes, chords: chords, dynamics: .activation,
                      parts: [("Melody", 0, 73), ("Chords", 1, 0), ("Bass", 2, 33)], signatures: [(0, 4, 4)]))
}

// MARK: - Checks per case

let outputDirectory = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
if let outputDirectory {
    try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
}

func expectedVelocity(_ amplitude: Double, _ dynamics: MidiExport.Dynamics) -> Int {
    let raw = dynamics == .detected ? Int((amplitude * 127).rounded()) : Int(amplitude * 95) + 38
    return max(1, min(127, raw))
}

/// Compares a part's notes with the loaded track: start and length within
/// 2 ms, except a note cut short because the same key strikes again.
func checkPitched(_ originals: [NoteEvent], _ track: LoadedTrack, file: LoadedFile, channel: Int,
                  dynamics: MidiExport.Dynamics, label: String) {
    // Same key struck at the same moment is one MIDI note (longest, loudest).
    var merged: [(start: Double, end: Double, key: Int, velocity: Int)] = []
    for note in originals.sorted(by: { ($0.pitch, $0.startTime) < ($1.pitch, $1.startTime) }) {
        let velocity = expectedVelocity(note.amplitude, dynamics)
        if let last = merged.last, last.key == note.pitch, last.start == note.startTime {
            merged[merged.count - 1].end = max(last.end, note.endTime)
            merged[merged.count - 1].velocity = max(last.velocity, velocity)
        } else {
            merged.append((note.startTime, note.endTime, note.pitch, velocity))
        }
    }
    let loaded = track.notes.sorted { ($0.key, $0.beat) < ($1.key, $1.beat) }
    expect(loaded.count == merged.count, "\(label): \(loaded.count) notes, expected \(merged.count)")
    guard loaded.count == merged.count else { return }
    for (i, (want, got)) in zip(merged, loaded).enumerated() {
        let start = file.seconds(atBeat: got.beat)
        let end = file.seconds(atBeat: got.beat + got.duration)
        expect(got.key == want.key, "\(label): key \(got.key) vs \(want.key)")
        expect(got.channel == channel, "\(label): note on channel \(got.channel)")
        expect(got.velocity == want.velocity, "\(label): velocity \(got.velocity) vs \(want.velocity)")
        expect(abs(start - want.start) < 0.002, "\(label): key \(want.key) at \(want.start) s starts \(ms(start - want.start)) off")
        let next = i + 1 < merged.count && merged[i + 1].key == want.key ? merged[i + 1].start : nil
        if let next, want.end > next - 0.003 {
            expect(end <= next + 0.0005 && end >= min(want.end, next) - 0.004,
                   "\(label): key \(want.key) at \(want.start) s ends at \(end), next strike \(next)")
        } else {
            let error = (end - start) - (want.end - want.start)
            expect(abs(error) < 0.002, "\(label): key \(want.key) at \(want.start) s lasts \(ms(error)) off")
        }
    }
}

func run(_ test: Case) {
    caseName = test.name
    let failuresBefore = failures.count, checksBefore = checkCount
    let data = MidiExport.file(title: "Test – \(test.name)", notes: test.notes, sustain: test.sustain,
                               chords: test.chords, grid: test.grid, dynamics: test.dynamics)
    if let outputDirectory {
        try? data.write(to: outputDirectory.appendingPathComponent("\(test.name).mid"))
    }
    let map = TempoMap(grid: test.grid)

    // Bytes: framing, ordering, tempo range, time signatures.
    guard let raw = readRaw(data) else {
        expect(false, "malformed file")
        return
    }
    expect(raw.format == 1 && raw.division == 480, "format \(raw.format), division \(raw.division)")
    expect(raw.tracks.count == test.parts.count + 1, "\(raw.tracks.count) tracks, expected \(test.parts.count + 1)")
    let conductor = raw.tracks[0]
    let tempos = conductor.filter { $0.bytes.starts(with: [0xFF, 0x51]) }.map {
        (tick: $0.tick, micros: Int($0.bytes[2]) << 16 | Int($0.bytes[3]) << 8 | Int($0.bytes[4]))
    }
    let signatures = conductor.filter { $0.bytes.starts(with: [0xFF, 0x58]) }.map {
        (tick: $0.tick, numerator: Int($0.bytes[2]), denominator: 1 << Int($0.bytes[3]))
    }
    expect(tempos.first?.tick == 0, "no tempo at tick 0")
    for tempo in tempos {
        expect((150_000...3_000_000).contains(tempo.micros),
               "tempo \(60_000_000 / Double(tempo.micros)) BPM at tick \(tempo.tick) is outside 20-400")
    }
    expect(zip(tempos, tempos.dropFirst()).allSatisfy { $0.tick < $1.tick }, "tempo ticks not increasing")
    expect(tempos.map(\.tick) == map.tempos.map(\.tick) && tempos.map(\.micros) == map.tempos.map(\.microsecondsPerQuarter),
           "file tempos differ from TempoMap.tempos")
    expect(signatures.map { [$0.tick, $0.numerator, $0.denominator] } == test.signatures.map { [$0.tick, $0.numerator, $0.denominator] },
           "time signatures \(signatures), expected \(test.signatures)")
    if test.tempoPerInterval {
        let beats = test.grid.beats
        let hasLead = beats[0] >= 0.25 * (beats[1] - beats[0])
        expect(tempos.count == beats.count - 1 + (hasLead ? 1 : 0),
               "\(tempos.count) tempo events for \(beats.count) beats")
    }
    if let count = test.tempoCount {
        expect(tempos.count == count, "\(tempos.count) tempo events, expected \(count)")
    }
    if test.grid.beats.count < 2 {
        expect(tempos.count == 1 && tempos[0].micros == 500_000, "empty grid should be a single 120 BPM")
    }

    // Markers: one per chord that names a chord, at its start, ASCII, read
    // back by ChordSymbol as the same chord; only on the conductor track.
    let markers = conductor.filter { $0.bytes.starts(with: [0xFF, 0x06]) }
    let wantMarkers = test.chords.filter { $0.startTime.isFinite }.sorted { $0.startTime < $1.startTime }
        .compactMap { chord in MidiExport.markerText(chord.label).map { (chord, $0) } }
    expect(markers.map(\.tick) == wantMarkers.map { map.tick(at: $0.0.startTime) },
           "marker ticks \(markers.map(\.tick)), expected \(wantMarkers.map { map.tick(at: $0.0.startTime) })")
    expect(markers.map { String(decoding: $0.bytes.dropFirst(2), as: UTF8.self) } == wantMarkers.map(\.1),
           "marker texts differ from the labels")
    for (chord, text) in wantMarkers {
        expect(text.unicodeScalars.allSatisfy(\.isASCII), "marker \(text) is not ASCII")
        expect(ChordSymbol(text) == ChordSymbol(chord.label), "marker \(text) reads back as another chord than \(chord.label)")
    }
    expect(raw.tracks.dropFirst().allSatisfy { !$0.contains { $0.bytes.starts(with: [0xFF, 0x06]) } },
           "a marker outside the conductor track")
    if !test.chords.isEmpty, let plain = readRaw(MidiExport.file(
        title: "Test – \(test.name)", notes: test.notes, sustain: test.sustain, grid: test.grid, dynamics: test.dynamics)) {
        // Without chords: the same file but for the markers.
        func bytes(_ events: [RawEvent]) -> [[Int]] { events.map { [$0.tick] + $0.bytes.map(Int.init) } }
        expect(bytes(conductor.filter { !$0.bytes.starts(with: [0xFF, 0x06]) }) == bytes(plain.tracks[0]),
               "the conductor track changed beyond its markers")
        expect(plain.tracks.count == raw.tracks.count
               && zip(plain.tracks, raw.tracks).dropFirst().allSatisfy { bytes($0.0) == bytes($0.1) },
               "part tracks changed with the markers")
    }
    for (i, track) in raw.tracks.enumerated().dropFirst() {
        var sounding = Set<[UInt8]>(), onTick: [[UInt8]: Int] = [:]
        var lastTick = -1, noteOnAtTick = false, pedalDown = false
        for event in track where event.bytes[0] < 0xF0 {
            expect(event.bytes[0] & 0x0F != 9, "track \(i): event on MIDI channel 10 (drums)")
            if event.tick != lastTick { lastTick = event.tick; noteOnAtTick = false }
            let kind = event.bytes[0] & 0xF0, key = [event.bytes[0] & 0x0F, event.bytes[1]]
            if kind == 0x90 {
                expect(event.bytes[2] > 0, "track \(i): note-on with velocity 0")
                expect(!sounding.contains(key), "track \(i): key \(key[1]) struck while still sounding")
                sounding.insert(key)
                onTick[key] = event.tick
                noteOnAtTick = true
            } else if kind == 0x80 {
                expect(!noteOnAtTick, "track \(i): note-off after a note-on on tick \(event.tick)")
                expect(sounding.remove(key) != nil, "track \(i): note-off for a silent key")
                expect(onTick[key] != event.tick, "track \(i): zero-length note at tick \(event.tick)")
            } else if kind == 0xB0, event.bytes[1] == 64 {
                expect((event.bytes[2] == 127) != pedalDown, "track \(i): pedal \(event.bytes[2]) twice in a row")
                pedalDown = event.bytes[2] == 127
            }
        }
        expect(sounding.isEmpty && !pedalDown, "track \(i): notes or pedal left on")
    }

    // Apple's parser: tracks, names, channels, programs.
    guard let file = LoadedFile(data) else {
        expect(false, "AudioToolbox couldn't load the file")
        return
    }
    expect(file.tracks.count == test.parts.count + 1, "AudioToolbox sees \(file.tracks.count) tracks")
    guard file.tracks.count == test.parts.count + 1 else { return }
    expect(file.tracks[0].name == "Test – \(test.name)", "conductor named \(file.tracks[0].name ?? "nil")")
    for tempo in file.tempos {
        expect((20...400).contains(tempo.bpm.rounded()), "AudioToolbox tempo \(tempo.bpm) at beat \(tempo.beat)")
    }
    expect(file.markers.map(\.text) == wantMarkers.map(\.1), "AudioToolbox markers \(file.markers.map(\.text))")
    for (got, want) in zip(file.markers, wantMarkers) {
        let time = file.seconds(atBeat: got.beat)
        expect(abs(time - want.0.startTime) < 0.002, "marker \(got.text) at \(time) s, chord starts at \(want.0.startTime) s")
    }
    for (part, track) in zip(test.parts, file.tracks.dropFirst()) {
        expect(track.name == part.name, "track named \(track.name ?? "nil"), expected \(part.name)")
        expect(track.programs.count == 1 && track.programs.first?.channel == part.channel
               && track.programs.first?.program == part.program,
               "\(part.name): programs \(track.programs), expected \(part.program) on channel \(part.channel)")
        let voice: Voice = ["Piano": Voice.none, "Melody": .melody, "Countermelody": .countermelody,
                            "Chords": .chords, "Bass": .bass][part.name]!
        checkPitched(test.notes.filter { $0.voice == voice }, track, file: file, channel: part.channel,
                     dynamics: test.dynamics, label: part.name)
        if voice == .none {
            // Pedal: down at each span's start, up at its end (touching spans stay separate).
            let pedal = track.controls.filter { $0.number == 64 }
            let wanted = test.sustain.sorted { $0.startTime < $1.startTime }
                .flatMap { [($0.startTime, 127), ($0.endTime, 0)] }
            expect(pedal.count == wanted.count, "pedal: \(pedal.count) events, expected \(wanted.count)")
            for (got, want) in zip(pedal, wanted) {
                let time = file.seconds(atBeat: got.beat)
                // A zero-length span still lasts one tick.
                expect(got.value == want.1 && got.channel == part.channel && abs(time - want.0) < 0.002,
                       "pedal \(got.value) at \(time) s, expected \(want.1) at \(want.0) s")
            }
        } else {
            expect(track.controls.isEmpty, "\(part.name): unexpected controllers")
        }
    }

    // Bar lines: every downbeat on one, per the file's time signatures and per AudioToolbox.
    func barLine(atTick tick: Int) -> Bool {
        guard let signature = signatures.last(where: { $0.tick <= tick }) else { return false }
        return (tick - signature.tick) % (signature.numerator * 1920 / signature.denominator) == 0
    }
    for (previous, next) in zip(signatures, signatures.dropFirst()) {
        let bar = previous.numerator * 1920 / previous.denominator
        expect((next.tick - previous.tick) % bar == 0, "time signature at \(next.tick) is not on a bar line")
    }
    let downbeats = test.grid.downbeats
    for (i, downbeat) in downbeats.enumerated() {
        let exact = file.beat(atSeconds: downbeat) * 480
        let tick = Int(exact.rounded())
        if i == 0 && test.foldedFirstDownbeat {
            expect(tick > 0 && tick < 120 && !barLine(atTick: tick), "folded first downbeat at tick \(exact)")
            continue
        }
        let apple = file.barBeat(atTick: tick)
        expect(abs(exact - Double(tick)) < 0.05 && barLine(atTick: tick) && apple.beat == 1 && apple.subbeat == 0,
               "downbeat \(downbeat) s at tick \(exact) (bar \(apple.bar) beat \(apple.beat).\(apple.subbeat))")
    }
    if let beatTicks = test.beatTicks, let meterStart = signatures.last?.tick {
        for (i, beat) in test.grid.beats.enumerated() where !(i == 0 && test.foldedFirstDownbeat) {
            let exact = file.beat(atSeconds: beat) * 480
            let offset = (exact - Double(meterStart)).truncatingRemainder(dividingBy: Double(beatTicks))
            let distance = min(abs(offset), Double(beatTicks) - abs(offset))
            expect(distance < 0.05, "beat \(beat) s at tick \(exact) is off the \(beatTicks)-tick grid")
        }
    }

    // TempoMap agrees with what AudioToolbox plays, never decreases, starts at 0.
    expect(map.tick(at: 0) == 0 && map.tick(at: -1) == 0, "tick at time 0 is \(map.tick(at: 0))")
    // Sampled every 0.5 ms past the last beat: steps of at most 4 ticks (400 BPM is 1.6 per step).
    let horizon = (test.grid.beats.last ?? 10) + 5
    var previous = 0, worst = 0.0
    var jump: String?, notInverse: String?
    for step in 0...Int(horizon * 2000) {
        let seconds = Double(step) / 2000
        let tick = map.tick(at: seconds)
        if jump == nil, tick < previous || tick - previous > 4 { jump = "\(previous) -> \(tick) at \(seconds) s" }
        previous = tick
        if step % 7 == 0 {
            worst = max(worst, abs(Double(tick) - file.beat(atSeconds: seconds) * 480))
            let back = map.seconds(atTick: tick)
            let tickSeconds = map.seconds(atTick: tick + 1) - back
            if notInverse == nil, abs(back - seconds) > tickSeconds / 2 + 1e-9 { notInverse = "at \(seconds) s" }
        }
    }
    expect(jump == nil, "tick(at:) not monotonic and continuous: \(jump ?? "")")
    expect(notInverse == nil, "seconds(atTick:) doesn't invert tick(at:) \(notInverse ?? "")")
    expect(worst <= 0.5 + 1e-6, "TempoMap is \(worst) ticks from AudioToolbox")

    let passed = failures.count == failuresBefore
    print("\(passed ? "PASS" : "FAIL")  \(test.name)  (\(checkCount - checksBefore) checks, \(tempos.count) tempi, "
          + "signatures \(signatures.map { "\($0.numerator)/\($0.denominator)@\($0.tick)" }.joined(separator: " ")), "
          + "BPM \(Int(tempos.map { 60_000_000 / Double($0.micros) }.min()!.rounded()))-"
          + "\(Int(tempos.map { 60_000_000 / Double($0.micros) }.max()!.rounded())))")
}

for test in cases { run(test) }

// Malformed input must still give a valid file: non-finite, negative and
// duplicate beats, no meter, NaN amplitudes, out-of-range pitches.
caseName = "malformed input"
do {
    let grid = BeatGrid(beats: [.nan, -1, 0.5, 0.5, 1.0, 1.0001, 1.5, .infinity, 2.0], downbeats: [.nan, 0.5],
                        beatsPerMeasure: 0, bpm: 0)
    let notes = [NoteEvent(startTime: .nan, endTime: 1, pitch: 60, amplitude: 0.5),
                 NoteEvent(startTime: 0.5, endTime: 1, pitch: 200, amplitude: 0.5),
                 NoteEvent(startTime: 0.5, endTime: .infinity, pitch: 61, amplitude: 0.5),
                 NoteEvent(startTime: -0.5, endTime: 0.2, pitch: 62, amplitude: .nan),
                 NoteEvent(startTime: 1.2, endTime: 1.1, pitch: 63, amplitude: 1e300)]
    // Chords that name nothing or have no time leave no marker, so the
    // untitled conductor still holds only tempo events.
    let chords = [ChordSegment(startTime: .nan, endTime: 1, label: "C"), ChordSegment(startTime: 0.5, endTime: 1, label: "N"),
                  ChordSegment(startTime: 1, endTime: 2, label: ""), ChordSegment(startTime: 1.5, endTime: 2, label: " ♪ ")]
    let data = MidiExport.file(title: "", notes: notes, sustain: [PedalEvent(startTime: .nan, endTime: 1)],
                               chords: chords, grid: grid, dynamics: .detected)
    let raw = readRaw(data), file = LoadedFile(data)
    let micros = raw?.tracks[0].filter { $0.bytes.starts(with: [0xFF, 0x51]) }
        .map { Int($0.bytes[2]) << 16 | Int($0.bytes[3]) << 8 | Int($0.bytes[4]) } ?? []
    expect(raw != nil && file != nil, "file unreadable")
    expect(!micros.isEmpty && micros.allSatisfy { (150_000...3_000_000).contains($0) }, "tempi \(micros)")
    // Untitled, the conductor holds only tempo events, which AudioToolbox moves to its tempo track.
    expect(raw?.tracks.count == 2 && file?.tracks.map(\.name) == ["Piano"], "expected conductor, Piano")
    expect(file?.tracks.first { $0.name == "Piano" }?.notes.map(\.velocity) == [1, 127], "Piano notes / velocities")
    print("\(failures.contains { $0.hasPrefix(caseName) } ? "FAIL" : "PASS")  malformed input")
}

caseName = "file name"
var components = DateComponents(year: 2026, month: 9, day: 27, hour: 14, minute: 3)
components.timeZone = TimeZone(identifier: "America/Los_Angeles")
let date = Calendar(identifier: .gregorian).date(from: components)!
let name = MidiExport.fileName(for: date, timeZone: TimeZone(identifier: "America/Los_Angeles")!)
let prefix = "Semitone 2026-09-27 1403-"
expect(name.hasPrefix(prefix) && name.hasSuffix(".mid"), "file name \(name)")
let suffix = String(name.dropFirst(prefix.count).dropLast(4))
expect(UUID(uuidString: suffix) != nil, "missing export UUID: \(name)")
let anotherName = MidiExport.fileName(for: date, timeZone: TimeZone(identifier: "America/Los_Angeles")!)
expect(name != anotherName, "two exports at the same time reused a filename")
print("\(failures.contains { $0.hasPrefix("file name") } ? "FAIL" : "PASS")  file name  (\(name))")

print("")
if failures.isEmpty {
    print("All \(cases.count + 2) cases passed (\(checkCount) checks).")
} else {
    for failure in failures.prefix(40) { print("  " + failure) }
    if failures.count > 40 { print("  … \(failures.count - 40) more") }
    print("\(failures.count) of \(checkCount) checks failed.")
    exit(1)
}
