import Foundation
import AudioToolbox

// `realbench midi2truth`: Standard MIDI files -> RealBench truth JSON, with
// the files' own tempo maps (AudioToolbox MusicSequence). Channel 10 notes
// (and files/tracks marked --drums) become drum hits.

nonisolated struct MidiSource {
    var path: String
    var part: String?
    var instrument: String?
    var transpose = 0
    var drums = false
    var offset = 0.0
}

nonisolated struct MidiNoteRaw {
    var on: Double, off: Double, pitch: Int, velocity: Int, channel: Int, track: Int, trackName: String
    /// General MIDI program in effect on the note's channel at its onset (last program change on that
    /// channel in any track); -1 when the file sets none.
    var program = -1
}

nonisolated struct MidiContents {
    var notes: [MidiNoteRaw] = []
    var beats: [Double] = []
    var downbeats: [Double] = []
    var beatsPerBar: Int?
    var hasTempo = false
    /// Time signatures (seconds, numerator, denominator) and tempo changes (seconds, BPM), for reports.
    var meters: [(seconds: Double, num: Int, den: Int)] = []
    var tempos: [(seconds: Double, bpm: Double)] = []
    /// Lyric (meta 0x05) events, or karaoke text (meta 0x01) events when there are no lyrics: (seconds, text).
    var lyrics: [(seconds: Double, text: String)] = []
}

func readMidi(_ path: String) throws -> MidiContents {
    var seqOpt: MusicSequence?
    guard NewMusicSequence(&seqOpt) == noErr, let seq = seqOpt else { throw RBError("cannot create MusicSequence") }
    defer { DisposeMusicSequence(seq) }
    let status = MusicSequenceFileLoad(seq, URL(fileURLWithPath: path) as CFURL, .midiType, MusicSequenceLoadFlags())
    guard status == noErr else { throw RBError("cannot read MIDI \(path) (OSStatus \(status))") }
    func seconds(_ beat: MusicTimeStamp) -> Double {
        var s: Float64 = 0
        MusicSequenceGetSecondsForBeats(seq, beat, &s)
        return s
    }
    var out = MidiContents()
    var trackCount: UInt32 = 0
    MusicSequenceGetTrackCount(seq, &trackCount)
    var lastBeat: MusicTimeStamp = 0
    var programChanges: [(beat: MusicTimeStamp, channel: Int, program: Int)] = []
    var lyricEvents: [(MusicTimeStamp, String)] = [], textEvents: [(MusicTimeStamp, String)] = []
    var onsetBeats: [MusicTimeStamp] = []
    for t in 0..<trackCount {
        var trackOpt: MusicTrack?
        MusicSequenceGetIndTrack(seq, t, &trackOpt)
        guard let track = trackOpt else { continue }
        var name = ""
        var pending: [MidiNoteRaw] = []
        iterate(track) { time, type, data in
            if type == kMusicEventType_Meta {
                let meta = data.assumingMemoryBound(to: MIDIMetaEvent.self)
                let metaType = meta.pointee.metaEventType
                if metaType == 0x03 || metaType == 0x05 || metaType == 0x01 {
                    let len = Int(meta.pointee.dataLength)
                    let bytes = UnsafeRawPointer(data).advanced(by: MemoryLayout<MIDIMetaEvent>.offset(of: \MIDIMetaEvent.data)!)
                    let text = String(decoding: UnsafeBufferPointer(start: bytes.assumingMemoryBound(to: UInt8.self), count: len), as: UTF8.self)
                    if metaType == 0x03, name.isEmpty { name = text }
                    if metaType == 0x05 { lyricEvents.append((time, text)) }
                    if metaType == 0x01, !text.hasPrefix("@") { textEvents.append((time, text)) }
                }
            } else if type == kMusicEventType_MIDINoteMessage {
                let n = data.assumingMemoryBound(to: MIDINoteMessage.self).pointee
                guard n.velocity > 0 else { return }
                let end = time + MusicTimeStamp(n.duration)
                lastBeat = max(lastBeat, end)
                pending.append(MidiNoteRaw(on: seconds(time), off: seconds(end), pitch: Int(n.note), velocity: Int(n.velocity),
                                           channel: Int(n.channel), track: Int(t), trackName: ""))
                onsetBeats.append(time)
            } else if type == kMusicEventType_MIDIChannelMessage {
                let m = data.assumingMemoryBound(to: MIDIChannelMessage.self).pointee
                if m.status & 0xF0 == 0xC0 { programChanges.append((time, Int(m.status & 0x0F), Int(m.data1))) }
            }
        }
        out.notes += pending.map { var x = $0; x.trackName = name; return x }
    }

    out.lyrics = (lyricEvents.count >= 20 ? lyricEvents : textEvents.count >= 20 ? textEvents : [])
        .sorted { $0.0 < $1.0 }.map { (seconds($0.0), $0.1) }
    programChanges.sort { $0.beat < $1.beat }
    for i in out.notes.indices {
        let onBeat = onsetBeats[i] + 1e-9
        if let pc = programChanges.last(where: { $0.channel == out.notes[i].channel && $0.beat <= onBeat }) {
            out.notes[i].program = pc.program
        }
    }

    // Tempo track: tempo events and time signatures -> beat grid.
    var tempoOpt: MusicTrack?
    MusicSequenceGetTempoTrack(seq, &tempoOpt)
    var signatures: [(beat: MusicTimeStamp, num: Int, den: Int)] = []
    if let tempo = tempoOpt {
        iterate(tempo) { time, type, data in
            if type == kMusicEventType_ExtendedTempo {
                out.hasTempo = true
                out.tempos.append((seconds(time), data.assumingMemoryBound(to: ExtendedTempoEvent.self).pointee.bpm))
            }
            if type == kMusicEventType_Meta {
                let meta = data.assumingMemoryBound(to: MIDIMetaEvent.self)
                if meta.pointee.metaEventType == 0x58, meta.pointee.dataLength >= 2 {
                    let bytes = UnsafeRawPointer(data).advanced(by: MemoryLayout<MIDIMetaEvent>.offset(of: \MIDIMetaEvent.data)!)
                        .assumingMemoryBound(to: UInt8.self)
                    signatures.append((time, Int(bytes[0]), 1 << Int(bytes[1])))
                }
            }
        }
    }
    if signatures.isEmpty || signatures[0].beat > 0 { signatures.insert((0, 4, 4), at: 0) }
    out.meters = signatures.map { (seconds($0.beat), $0.num, $0.den) }
    // Beat unit in quarter notes: the denominator, or a dotted quarter in compound meters (6/8, 9/8, 12/8).
    var beat: MusicTimeStamp = 0
    var bar = 0
    var sigIndex = 0
    while beat <= lastBeat + 1e-9 {
        while sigIndex + 1 < signatures.count, signatures[sigIndex + 1].beat <= beat + 1e-9 { sigIndex += 1 }
        let sig = signatures[sigIndex]
        let compound = sig.den == 8 && sig.num % 3 == 0 && sig.num > 3
        let unit = 4.0 / Double(sig.den) * (compound ? 3 : 1)
        let perBar = compound ? sig.num / 3 : sig.num
        out.beatsPerBar = out.beatsPerBar ?? perBar
        for i in 0..<perBar {
            let b = beat + Double(i) * unit
            if b > lastBeat + 1e-9 { break }
            out.beats.append(seconds(b))
            if i == 0 { out.downbeats.append(seconds(b)) }
        }
        beat += Double(perBar) * unit
        bar += 1
    }
    return out
}

private func iterate(_ track: MusicTrack, _ body: (MusicTimeStamp, MusicEventType, UnsafeRawPointer) -> Void) {
    var itOpt: MusicEventIterator?
    guard NewMusicEventIterator(track, &itOpt) == noErr, let it = itOpt else { return }
    defer { DisposeMusicEventIterator(it) }
    var has: DarwinBoolean = false
    MusicEventIteratorHasCurrentEvent(it, &has)
    while has.boolValue {
        var time: MusicTimeStamp = 0
        var type: MusicEventType = 0
        var data: UnsafeRawPointer?
        var size: UInt32 = 0
        if MusicEventIteratorGetEventInfo(it, &time, &type, &data, &size) == noErr, let data { body(time, type, data) }
        MusicEventIteratorNextEvent(it)
        MusicEventIteratorHasCurrentEvent(it, &has)
    }
}

/// realbench midi2truth <out.json> [--name N] [--grid-from FILE.mid] [--ignore a:b ...]
///     --midi FILE.mid [--part P] [--instrument I] [--transpose N] [--offset S] [--drums] ...
func midiToTruthCommand(_ args: [String]) throws {
    guard let outPath = args.first, !outPath.hasPrefix("--") else { throw RBError(midiUsage) }
    var name: String?
    var gridFrom: String?
    var ignore: [[Double]] = []
    var sources: [MidiSource] = []
    var i = 1
    func value() throws -> String {
        guard i + 1 < args.count else { throw RBError("\(args[i]) needs a value") }
        i += 1
        return args[i]
    }
    while i < args.count {
        let a = args[i]
        switch a {
        case "--name": name = try value()
        case "--grid-from": gridFrom = try value()
        case "--ignore":
            let v = try value().split(separator: ":").compactMap { Double($0) }
            guard v.count == 2 else { throw RBError("--ignore takes start:end") }
            ignore.append(v)
        case "--midi": sources.append(MidiSource(path: try value()))
        case "--part", "--instrument", "--transpose", "--offset", "--drums":
            guard !sources.isEmpty else { throw RBError("\(a) must follow a --midi FILE") }
            switch a {
            case "--part": sources[sources.count - 1].part = try value()
            case "--instrument": sources[sources.count - 1].instrument = try value()
            case "--transpose": sources[sources.count - 1].transpose = Int(try value()) ?? 0
            case "--offset": sources[sources.count - 1].offset = Double(try value()) ?? 0
            default: sources[sources.count - 1].drums = true
            }
        default: throw RBError("unknown option \(a)\n" + midiUsage)
        }
        i += 1
    }
    guard !sources.isEmpty else { throw RBError(midiUsage) }
    var notes: [[String: Any]] = []
    var drums: [[String: Any]] = []
    var report: [String] = []
    for s in sources {
        let m = try readMidi(s.path)
        var n = 0, d = 0
        for x in m.notes {
            if s.drums || x.channel == 9 {
                var hit: [String: Any] = ["time": r4(x.on + s.offset), "gmNote": x.pitch, "velocity": x.velocity]
                if let cls = DrumClass.of(gmNote: x.pitch) { hit["class"] = cls.rawValue }
                drums.append(hit)
                d += 1
            } else {
                var note: [String: Any] = ["on": r4(x.on + s.offset), "off": r4(x.off + s.offset), "pitch": x.pitch + s.transpose,
                                           "velocity": x.velocity]
                note["part"] = s.part ?? (x.trackName.isEmpty ? URL(fileURLWithPath: s.path).deletingPathExtension().lastPathComponent : x.trackName)
                note["instrument"] = s.instrument ?? (x.trackName.isEmpty ? URL(fileURLWithPath: s.path).deletingPathExtension().lastPathComponent : x.trackName)
                notes.append(note)
                n += 1
            }
        }
        report.append("\(s.path): \(n) notes, \(d) drum hits\(m.hasTempo ? "" : " (no tempo event: 120 BPM assumed)")")
    }
    notes.sort { ($0["on"] as! Double, $0["pitch"] as! Int) < ($1["on"] as! Double, $1["pitch"] as! Int) }
    drums.sort { ($0["time"] as! Double) < ($1["time"] as! Double) }
    var truth: [String: Any] = ["format": "realbench-truth-1", "name": name ?? URL(fileURLWithPath: outPath).deletingPathExtension().lastPathComponent,
                                "notes": notes, "source": "midi2truth: " + sources.map(\.path).joined(separator: ", ")]
    if sources.contains(where: { $0.drums }) || !drums.isEmpty { truth["drums"] = drums }
    if !ignore.isEmpty { truth["ignore"] = ignore }
    if let g = gridFrom {
        let m = try readMidi(g)
        let o = sources.first { $0.path == g }?.offset ?? 0
        truth["beats"] = m.beats.map { r4($0 + o) }
        truth["downbeats"] = m.downbeats.map { r4($0 + o) }
        if let b = m.beatsPerBar { truth["beatsPerBar"] = b }
        report.append("grid from \(g): \(m.beats.count) beats, \(m.downbeats.count) bars\(m.hasTempo ? "" : " (no tempo event!)")")
    }
    let data = try JSONSerialization.data(withJSONObject: truth, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: outPath))
    for line in report { print(line) }
    print("wrote \(outPath): \(notes.count) notes, \(drums.count) drum hits")
}

let midiUsage = """
usage: realbench midi2truth <out.json> [--name N] [--grid-from FILE.mid] [--ignore start:end ...]
         --midi FILE.mid [--part P] [--instrument I] [--transpose SEMITONES] [--offset SECONDS] [--drums]
         [--midi FILE2.mid ...]
  Options after a --midi apply to that file. Without --part/--instrument the MIDI track name (or file
  name) is used. Channel-10 notes always become drum hits; --drums makes every note of that file one.
  --grid-from writes beats/downbeats from that file's tempo map and time signatures.
"""
