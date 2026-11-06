import Foundation
import AVFoundation

/// One saved take as listed in the library.
nonisolated struct SavedTake: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var createdAt: Date
    var duration: Double
    /// `TranscriptionMode` raw value the take was transcribed in.
    var mode: String
    var noteCount: Int
    /// What it holds, noted when it's saved (`noting`), so Home lays its
    /// row out right before reading its notes: "piano", "instrument" or
    /// "song", and a song's parts ("melody", "countermelody", "chords",
    /// "bass"). Nil in a take
    /// saved before these were kept, until Home notes them. Prerelease 0.99
    /// also noted "drums", which Home now skips (`savedKind`, `savedParts`).
    var kind: String? = nil
    var parts: [String]? = nil
}

/// What a saved take shows: the final notes (with their parts) and pedal,
/// so reopening it needs no refine pass. Chords, melody, the beat grid and
/// the simplified chords are derived from these again; only the choice of
/// chord style is saved beside them. Takes saved before October 2026 also
/// hold the any-instrument mode's drum hits under "drums" (`legacyDrums`);
/// this build doesn't show them, but writes them back when it saves such a
/// take again, and writes an empty list in a new save, which builds from
/// before then require to open a take.
nonisolated struct SavedTakeContent: Codable {
    struct Note: Codable {
        var start: Double
        var end: Double
        var pitch: Int
        var amplitude: Double
        /// The part (`Voice` raw value). In the file it is one that builds
        /// from before the countermelody know (`forSaving`): they open a part
        /// they don't know as unsplit notes, which no chip can hide or mute.
        var voice: UInt8
        /// The part itself where `voice` holds a stand-in for it; nil (not
        /// written) otherwise.
        var part: UInt8? = nil

        /// The note's part, however it is held: `part` where `voice` is a
        /// stand-in (a save read back), else `voice` (a countermelody saved
        /// before the stand-in holds 4 there, as do notes not yet written).
        var resolvedVoice: Voice { Voice(rawValue: part ?? voice) ?? .none }

        /// The note as it is written: a part older builds don't know is
        /// saved as its stand-in, with the part itself under `part`.
        var forSaving: Note {
            let voice = resolvedVoice
            var note = self
            note.voice = voice.savedAs.rawValue
            note.part = voice.savedAs == voice ? nil : voice.rawValue
            return note
        }
    }
    struct Span: Codable {
        var start: Double
        var end: Double
    }
    /// A drum hit as Prerelease 0.99 saved it (`kind`: its `DrumKind` raw
    /// value, 0 kick, 1 snare, 2 closed hi-hat, ...).
    struct LegacyDrum: Codable, Equatable {
        var time: Double
        var kind: Int
        var velocity: Double
    }
    /// "quick", "piano" or "music": which pass produced the notes.
    var source: String
    var notes: [Note]
    var sustain: [Span]
    /// The drum hits of a take saved before the drum removal, kept as they
    /// were: opening a take saves it again (as does any edit), and a tester
    /// who goes back to Prerelease 0.99 finds its kit still there. Empty in
    /// a take saved since.
    var legacyDrums: [LegacyDrum]
    /// The chord style the take was left in (`ChordStyle` raw value). nil,
    /// and not written, as played: such a save is the same as before the
    /// style existed, and builds without it ignore the key either way.
    var chordStyle: String? = nil

    init(source: String, notes: [NoteEvent], sustain: [PedalEvent], legacyDrums: [LegacyDrum] = [],
         chordStyle: ChordStyle = .asPlayed) {
        self.source = source
        self.notes = notes.map { Note(start: $0.startTime, end: $0.endTime, pitch: $0.pitch, amplitude: $0.amplitude,
                                      voice: $0.voice.rawValue) }
        self.sustain = sustain.map { Span(start: $0.startTime, end: $0.endTime) }
        self.legacyDrums = legacyDrums
        self.chordStyle = chordStyle == .asPlayed ? nil : chordStyle.rawValue
    }

    /// The saved chord style; one this build doesn't know (from a later
    /// build) opens as played.
    var style: ChordStyle { chordStyle.flatMap(ChordStyle.init(rawValue:)) ?? .asPlayed }

    var noteEvents: [NoteEvent] {
        notes.map { NoteEvent(startTime: $0.start, endTime: $0.end, pitch: $0.pitch, amplitude: $0.amplitude,
                              voice: $0.resolvedVoice) }
    }
    var pedalEvents: [PedalEvent] { sustain.map { PedalEvent(startTime: $0.start, endTime: $0.end) } }

    private enum CodingKeys: String, CodingKey { case source, notes, sustain, drums, chordStyle }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(String.self, forKey: .source)
        notes = try container.decode([Note].self, forKey: .notes)
        sustain = try container.decode([Span].self, forKey: .sustain)
        // Hits that don't read as 0.99 wrote them are let go rather than block the take.
        legacyDrums = (try? container.decodeIfPresent([LegacyDrum].self, forKey: .drums)) ?? []
        // So is a style that isn't a string: the take opens as played (`style`).
        chordStyle = try? container.decodeIfPresent(String.self, forKey: .chordStyle)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encode(notes.map(\.forSaving), forKey: .notes)
        try container.encode(sustain, forKey: .sustain)
        try container.encode(legacyDrums, forKey: .drums)
        try container.encodeIfPresent(chordStyle, forKey: .chordStyle)
    }
}

nonisolated private extension Voice {
    /// The part older builds read in a save: they know melody, chords and
    /// bass. A countermelody is saved as chords, where this build puts held
    /// notes that form no line, so an older build still colors, mutes and
    /// exports it as a part.
    var savedAs: Voice { self == .countermelody ? .chords : self }
}

/// Takes saved on the device: Documents/Saved/<id>/ holds `info.json`
/// (the list entry), `take.json` (the transcription) and `audio.m4a` (the
/// take's mono audio, AAC), so a take can be reopened, re-analyzed or refined.
nonisolated enum TakeLibrary {
    static var root: URL {
        #if DEBUG
        if let samples = HomeSampleTones.root { return samples }
        #endif
        return URL.documentsDirectory.appending(path: "Saved", directoryHint: .isDirectory)
    }

    static func folder(_ id: UUID) -> URL { root.appending(path: id.uuidString, directoryHint: .isDirectory) }
    static func audioURL(_ id: UUID) -> URL { folder(id).appending(path: "audio.m4a") }

    /// Every saved take, newest first. Unreadable entries are skipped.
    static func list() -> [SavedTake] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appending(path: "info.json")) else { return nil }
            return try? decoder.decode(SavedTake.self, from: data)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    /// Writes (or updates) a take. `audio` (mono at `sampleRate`) is written
    /// only when given, so later updates of the notes don't re-encode it.
    static func save(_ take: SavedTake, content: SavedTakeContent, audio: [Float]?, sampleRate: Double) throws {
        let folder = folder(take.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let audio, !audio.isEmpty {
            try writeAudio(audio, sampleRate: sampleRate, to: audioURL(take.id))
        }
        let encoder = JSONEncoder()
        try encoder.encode(content).write(to: folder.appending(path: "take.json"), options: .atomic)
        // The list entry last: a take shows up only once it's complete. With
        // its kind and parts, from the content saved with it.
        try encoder.encode(take.noting(content)).write(to: folder.appending(path: "info.json"), options: .atomic)
    }

    static func content(of id: UUID) throws -> SavedTakeContent {
        try JSONDecoder().decode(SavedTakeContent.self, from: Data(contentsOf: folder(id).appending(path: "take.json")))
    }

    static func rename(_ id: UUID, to title: String) throws {
        let url = folder(id).appending(path: "info.json")
        var take = try JSONDecoder().decode(SavedTake.self, from: Data(contentsOf: url))
        take.title = title
        try JSONEncoder().encode(take).write(to: url, options: .atomic)
    }

    /// Notes an older take's kind and parts (as `take` has them) in its list
    /// entry, if the entry has none yet. Nothing else in it changes.
    static func noteKind(_ take: SavedTake) throws {
        let url = folder(take.id).appending(path: "info.json")
        var entry = try JSONDecoder().decode(SavedTake.self, from: Data(contentsOf: url))
        guard entry.kind == nil, take.kind != nil else { return }
        entry.kind = take.kind
        entry.parts = take.parts
        try JSONEncoder().encode(entry).write(to: url, options: .atomic)
    }

    static func delete(_ id: UUID) throws {
        try FileManager.default.removeItem(at: folder(id))
    }

    /// AAC in an .m4a, about 0.7 MB per minute.
    static func writeAudio(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1,
                                         interleaved: false) else { return }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ]
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 65536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)) else { return }
        var offset = 0
        while offset < samples.count {
            let count = min(chunk, samples.count - offset)
            samples.withUnsafeBufferPointer { src in
                buffer.floatChannelData![0].update(from: src.baseAddress! + offset, count: count)
            }
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
            offset += count
        }
    }
}
