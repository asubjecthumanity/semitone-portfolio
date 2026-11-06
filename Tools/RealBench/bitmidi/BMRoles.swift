import Foundation

// A fan MIDI file split into voices (one per track and channel), with
// statistics and a suggested role for each: melody, countermelody, chords,
// bass, drums (channel 10, dropped from the key) or ignore. The per-song
// roles.json overrides the suggestions.

let gmProgramNames = [
    "Acoustic Grand Piano", "Bright Acoustic Piano", "Electric Grand Piano", "Honky-tonk Piano", "Electric Piano 1",
    "Electric Piano 2", "Harpsichord", "Clavinet", "Celesta", "Glockenspiel", "Music Box", "Vibraphone", "Marimba",
    "Xylophone", "Tubular Bells", "Dulcimer", "Drawbar Organ", "Percussive Organ", "Rock Organ", "Church Organ",
    "Reed Organ", "Accordion", "Harmonica", "Tango Accordion", "Acoustic Guitar (nylon)", "Acoustic Guitar (steel)",
    "Electric Guitar (jazz)", "Electric Guitar (clean)", "Electric Guitar (muted)", "Overdriven Guitar",
    "Distortion Guitar", "Guitar Harmonics", "Acoustic Bass", "Electric Bass (finger)", "Electric Bass (pick)",
    "Fretless Bass", "Slap Bass 1", "Slap Bass 2", "Synth Bass 1", "Synth Bass 2", "Violin", "Viola", "Cello",
    "Contrabass", "Tremolo Strings", "Pizzicato Strings", "Orchestral Harp", "Timpani", "String Ensemble 1",
    "String Ensemble 2", "Synth Strings 1", "Synth Strings 2", "Choir Aahs", "Voice Oohs", "Synth Voice",
    "Orchestra Hit", "Trumpet", "Trombone", "Tuba", "Muted Trumpet", "French Horn", "Brass Section", "Synth Brass 1",
    "Synth Brass 2", "Soprano Sax", "Alto Sax", "Tenor Sax", "Baritone Sax", "Oboe", "English Horn", "Bassoon",
    "Clarinet", "Piccolo", "Flute", "Recorder", "Pan Flute", "Blown Bottle", "Shakuhachi", "Whistle", "Ocarina",
    "Lead 1 (square)", "Lead 2 (sawtooth)", "Lead 3 (calliope)", "Lead 4 (chiff)", "Lead 5 (charang)",
    "Lead 6 (voice)", "Lead 7 (fifths)", "Lead 8 (bass + lead)", "Pad 1 (new age)", "Pad 2 (warm)",
    "Pad 3 (polysynth)", "Pad 4 (choir)", "Pad 5 (bowed)", "Pad 6 (metallic)", "Pad 7 (halo)", "Pad 8 (sweep)",
    "FX 1 (rain)", "FX 2 (soundtrack)", "FX 3 (crystal)", "FX 4 (atmosphere)", "FX 5 (brightness)",
    "FX 6 (goblins)", "FX 7 (echoes)", "FX 8 (sci-fi)", "Sitar", "Banjo", "Shamisen", "Koto", "Kalimba", "Bagpipe",
    "Fiddle", "Shanai", "Tinkle Bell", "Agogo", "Steel Drums", "Woodblock", "Taiko Drum", "Melodic Tom",
    "Synth Drum", "Reverse Cymbal", "Guitar Fret Noise", "Breath Noise", "Seashore", "Bird Tweet",
    "Telephone Ring", "Helicopter", "Applause", "Gunshot",
]

func programName(_ p: Int) -> String { p >= 0 && p < 128 ? gmProgramNames[p] : "(no program)" }

let validRoles: Set<String> = ["melody", "countermelody", "chords", "bass", "drums", "ignore", "melody+chords",
                                "melody+countermelody", "chords+bass"]

nonisolated struct BMVoice: Codable {
    var id: String
    var track: Int
    /// 1-16 (10 = General MIDI drums).
    var channel: Int
    var name: String
    var program: Int
    var programName: String
    var notes: Int
    var lowest: Int
    var highest: Int
    var medianPitch: Int
    /// Mean number of this voice's notes sounding while any sounds.
    var polyphony: Double
    /// Share of onsets that start together with 2+ other notes (within 30 ms).
    var chordOnsets: Double
    /// Seconds during which the voice sounds.
    var soundingSeconds: Double
    var medianDuration: Double
    var drum: Bool
    /// Share of the file's lyric events that fall on one of this voice's onsets (within 40 ms); nil without lyrics.
    var lyricShare: Double? = nil
    var suggested: String = ""
    var why: String = ""
    var role: String = ""
    /// Semitones added to this voice on top of the song transposition (octave fixes).
    var addTranspose: Int = 0
}

nonisolated struct BMMidi {
    var path: String
    var contents: MidiContents
    var voices: [BMVoice]
    /// Notes with their voice index.
    var notes: [SymNote]
    var duration: Double
}

func loadBMMidi(_ path: String) throws -> BMMidi {
    if path.lowercased().hasSuffix(".json") { return try loadTruthAsMidi(path, extra: false) }
    return buildBMMidi(path: path, contents: try readMidi(path))
}

func buildBMMidi(path: String, contents raw: MidiContents) -> BMMidi {
    var m = raw
    // Drum lengths mean nothing (and an unclosed drum note can run to the end of the file); a pitched note held
    // over 30 s is a stuck note.
    for i in m.notes.indices {
        if m.notes[i].channel == 9 { m.notes[i].off = m.notes[i].on + 0.1 }
        else if m.notes[i].off - m.notes[i].on > 30 { m.notes[i].off = m.notes[i].on + 30 }
    }
    // The beat grid stops a bar after the last note.
    if let end = m.notes.map(\.off).max() {
        let gap = m.beats.count > 1 ? (m.beats[1] - m.beats[0]) * Double(m.beatsPerBar ?? 4) : 2
        m.beats = m.beats.filter { $0 <= end + gap }
        m.downbeats = m.downbeats.filter { $0 <= end + gap }
    }
    var keyIndex: [String: Int] = [:]
    var groups: [[MidiNoteRaw]] = []
    for n in m.notes {
        let key = "t\(n.track)c\(n.channel + 1)"
        if keyIndex[key] == nil { keyIndex[key] = groups.count; groups.append([]) }
        groups[keyIndex[key]!].append(n)
    }
    var voices: [BMVoice] = []
    var notes: [SymNote] = []
    for g in groups {
        let first = g[0]
        let drum = first.channel == 9
        let pitches = g.map(\.pitch).sorted()
        var progCount: [Int: Int] = [:]
        for n in g { progCount[n.program, default: 0] += 1 }
        let program = progCount.max { $0.value < $1.value }?.key ?? -1
        // Polyphony: sweep over on/off events.
        var events: [(Double, Int)] = []
        for n in g { events.append((n.on, 1)); events.append((max(n.off, n.on + 0.01), -1)) }
        events.sort { $0.0 < $1.0 || ($0.0 == $1.0 && $0.1 < $1.1) }
        var active = 0, last = 0.0, sounding = 0.0, weighted = 0.0
        for (t, d) in events {
            if active > 0 { sounding += t - last; weighted += Double(active) * (t - last) }
            active += d; last = t
        }
        let ons = g.map(\.on).sorted()
        var chordStarts = 0
        var a = 0
        for (k, t) in ons.enumerated() {
            while ons[a] < t - 0.03 { a += 1 }
            var b = k
            while b + 1 < ons.count && ons[b + 1] <= t + 0.03 { b += 1 }
            if b - a + 1 >= 3 { chordStarts += 1 }
        }
        let durs = g.map { $0.off - $0.on }.sorted()
        var lyricShare: Double? = nil
        if m.lyrics.count >= 20 {
            var hit = 0
            for l in m.lyrics {
                var lo = 0, hi = ons.count
                while lo < hi { let mid = (lo + hi) / 2; if ons[mid] < l.seconds - 0.04 { lo = mid + 1 } else { hi = mid } }
                if lo < ons.count && ons[lo] <= l.seconds + 0.04 { hit += 1 }
            }
            lyricShare = Double(hit) / Double(m.lyrics.count)
        }
        let vi = voices.count
        voices.append(BMVoice(id: "t\(first.track)c\(first.channel + 1)", track: first.track, channel: first.channel + 1,
                              name: first.trackName.trimmingCharacters(in: .whitespacesAndNewlines), program: program,
                              programName: drum ? "Drums (channel 10)" : programName(program), notes: g.count,
                              lowest: pitches.first ?? 0, highest: pitches.last ?? 0, medianPitch: pitches[pitches.count / 2],
                              polyphony: sounding > 0 ? weighted / sounding : 0,
                              chordOnsets: Double(chordStarts) / Double(max(1, g.count)),
                              soundingSeconds: sounding, medianDuration: durs[durs.count / 2], drum: drum, lyricShare: lyricShare))
        for n in g {
            notes.append(SymNote(on: n.on, off: max(n.off, n.on + 0.01), pitch: n.pitch, velocity: n.velocity, drum: drum, voice: vi))
        }
    }
    notes.sort { $0.on < $1.on || ($0.on == $1.on && $0.pitch < $1.pitch) }
    let duration = max(notes.map(\.off).max() ?? 0, m.beats.last ?? 0)
    var out = BMMidi(path: path, contents: m, voices: voices, notes: notes, duration: duration)
    suggestRoles(&out)
    return out
}

/// A RealBench key read as if it were a MIDI file (for validation): one voice per part/instrument,
/// beats and downbeats from the key. `extra` also reads the key's `unreliableNotes` (als2truth).
func loadTruthAsMidi(_ path: String, extra: Bool) throws -> BMMidi {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RBError("\(path): not a JSON object") }
    var raw = (obj["notes"] as? [[String: Any]]) ?? []
    if extra { raw += (obj["unreliableNotes"] as? [[String: Any]]) ?? [] }
    var mc = MidiContents()
    var track: [String: Int] = [:]
    for n in raw {
        guard let on = (n["on"] as? NSNumber)?.doubleValue, let pitch = (n["pitch"] as? NSNumber)?.doubleValue else { continue }
        let off = (n["off"] as? NSNumber)?.doubleValue ?? on + 0.2
        let name = (n["instrument"] as? String) ?? (n["part"] as? String) ?? "notes"
        if track[name] == nil { track[name] = track.count }
        mc.notes.append(MidiNoteRaw(on: on, off: off, pitch: Int(pitch.rounded()), velocity: (n["velocity"] as? NSNumber)?.intValue ?? 90,
                                    channel: track[name]! % 9, track: track[name]!, trackName: name))
    }
    for d in (obj["drums"] as? [[String: Any]]) ?? [] {
        guard let t = (d["time"] as? NSNumber)?.doubleValue else { continue }
        mc.notes.append(MidiNoteRaw(on: t, off: t + 0.1, pitch: (d["gmNote"] as? NSNumber)?.intValue ?? 38, velocity: 90, channel: 9, track: 999, trackName: "drums"))
    }
    mc.beats = (obj["beats"] as? [NSNumber])?.map(\.doubleValue) ?? []
    mc.downbeats = (obj["downbeats"] as? [NSNumber])?.map(\.doubleValue) ?? []
    mc.beatsPerBar = (obj["beatsPerBar"] as? NSNumber)?.intValue
    mc.meters = [(0, mc.beatsPerBar ?? 4, 4)]
    mc.hasTempo = true
    var m = buildBMMidi(path: path, contents: mc)
    // A key's parts are its roles.
    var partOf: [String: String] = [:]
    for n in raw { if let i = n["instrument"] as? String ?? n["part"] as? String, let p = n["part"] as? String { partOf[i] = p } }
    for i in m.voices.indices where !m.voices[i].drum {
        if let p = partOf[m.voices[i].name], ["melody", "countermelody", "chords", "bass"].contains(p) { m.voices[i].role = p; m.voices[i].suggested = p; m.voices[i].why = "part in the key" }
    }
    return m
}

private func has(_ name: String, _ words: [String]) -> Bool {
    let n = name.lowercased()
    return words.contains { n.contains($0) }
}

/// Suggested roles from names, GM programs, channel 10, register and polyphony.
func suggestRoles(_ m: inout BMMidi) {
    let song = max(1, m.duration)
    var melodic: [Int] = []
    for (i, v) in m.voices.enumerated() {
        var role = "", why = ""
        let name = v.name, p = v.program
        let chordal = v.polyphony >= 1.4 || v.chordOnsets >= 0.2
        if v.drum {
            role = "drums"; why = "channel 10"
        } else if has(name, ["drum", "perc", "kit", "cymbal", "hihat", "hi-hat", "snare", "kick", "conga", "bongo", "shaker", "tamb"]) {
            role = "ignore"; why = "percussion name on a pitched channel"
        } else if (112...127).contains(p) {
            role = "ignore"; why = "GM percussive or sound-effect program"
        } else if v.notes < 8 {
            role = "ignore"; why = "fewer than 8 notes"
        } else if (has(name, ["bass"]) && !has(name, ["bassoon"])) || (32...39).contains(p) {
            role = "bass"; why = (32...39).contains(p) ? "GM bass program" : "bass in the name"
        } else if v.medianPitch < 48 && !chordal && !has(name, ["vocal", "voice", "melod", "lead", "vox", "sing"]) {
            role = "bass"; why = "low (median \(noteName(v.medianPitch))) and mostly one note at a time"
        } else if chordal {
            role = "chords"; why = String(format: "polyphonic (%.1f notes sounding, %.0f%% chord onsets)", v.polyphony, v.chordOnsets * 100)
        } else {
            melodic.append(i)
            role = "countermelody"; why = "a single line"
        }
        m.voices[i].suggested = role; m.voices[i].why = why
    }
    // Melody: the most melody-like single line.
    func melodyScore(_ v: BMVoice) -> Double {
        var s = 0.0
        if has(v.name, ["vocal", "voice", "vox", "sing", "lyric", "melod", "melodie", "melodia", "tune"]) { s += 3 }
        if has(v.name, ["lead", "solo", "main"]) { s += 2 }
        if has(v.name, ["harm", "back", "bgv", "2nd", "second", "echo", "counter", "bridge", "intro", "outro", "fill"]) { s -= 2 }
        if (52...54).contains(v.program) || v.program == 85 { s += 1.5 }
        if let l = v.lyricShare { s += 5 * l }
        if (56...87).contains(v.program) { s += 0.5 }
        s += 2 * min(1, v.soundingSeconds / song)
        if (55...84).contains(v.medianPitch) { s += 0.5 }
        s -= v.chordOnsets * 2
        return s
    }
    // Name-marked vocal/melody tracks may be slightly polyphonic (doubled notes): let them compete too.
    let named = m.voices.indices.filter { i in
        !m.voices[i].drum && m.voices[i].suggested != "ignore" && m.voices[i].suggested != "bass"
            && (has(m.voices[i].name, ["vocal", "voice", "vox", "melod", "lead", "sing"]) || (m.voices[i].lyricShare ?? 0) >= 0.5)
            && m.voices[i].chordOnsets < 0.6
    }
    let pool = Array(Set(melodic + named))
    if let best = pool.max(by: { melodyScore(m.voices[$0]) < melodyScore(m.voices[$1]) }) {
        let v = m.voices[best]
        let poly = v.polyphony >= 1.3 || v.chordOnsets >= 0.1
        m.voices[best].suggested = poly ? "melody+countermelody" : "melody"
        m.voices[best].why = String(format: "the most melody-like line (score %.1f: name, program, %@%.0f%% of the song, median %@)%@",
                                    melodyScore(v), v.lyricShare.map { String(format: "%.0f%% of the lyrics on its notes, ", 100 * $0) } ?? "",
                                    100 * min(1, v.soundingSeconds / song), noteName(v.medianPitch),
                                    poly ? String(format: "; %.0f%% chord onsets, so its top line is the melody and the rest countermelody: check the top line is the lead", v.chordOnsets * 100) : "")
    }
    for i in m.voices.indices { m.voices[i].role = m.voices[i].suggested }
}

// MARK: - roles.json

nonisolated struct RolesFile: Codable {
    var format = "bitmidi-roles-1"
    /// The MIDI file (relative to the song folder) these roles are for.
    var midi: String
    /// "auto" or a whole number of semitones added to every pitched voice (a number is accepted too).
    var transpose: String = "auto"
    /// Extra [start, end] recording spans to leave out of the key.
    var ignore: [[Double]] = []
    /// Beats to move the bar lines by (when the MIDI's bar 1 is not the song's).
    var barShift: Int? = 0
    /// 0.5 when the MIDI counts twice the song's beats (keeps every other beat), 2 when half.
    var tempoScale: Double? = 1
    /// Beats per bar for the key, replacing the MIDI's time signatures.
    var beatsPerBar: Int? = nil
    /// Alignment settings for this song, by their command-line names without "--" (for example
    /// {"slope-penalty": 2, "band": 0.2, "offdiag": 2}); options given on the command line win.
    var align: [String: Double]? = nil
    /// [start, end] recording spans whose sections are kept in the key even when a confidence check flags
    /// them: for flags shown to be false alarms by other evidence (say why in `comment`).
    var trust: [[Double]]? = nil
    /// Free notes for the reviewer.
    var comment: String = ""
    var voices: [RoleEntry]

    init(midi: String, voices: [RoleEntry]) { self.midi = midi; self.voices = voices }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? "bitmidi-roles-1"
        midi = try c.decode(String.self, forKey: .midi)
        if let n = try? c.decode(Int.self, forKey: .transpose) { transpose = String(n) }
        else { transpose = try c.decodeIfPresent(String.self, forKey: .transpose) ?? "auto" }
        ignore = try c.decodeIfPresent([[Double]].self, forKey: .ignore) ?? []
        barShift = try c.decodeIfPresent(Int.self, forKey: .barShift) ?? 0
        tempoScale = try c.decodeIfPresent(Double.self, forKey: .tempoScale) ?? 1
        beatsPerBar = try c.decodeIfPresent(Int.self, forKey: .beatsPerBar)
        align = try c.decodeIfPresent([String: Double].self, forKey: .align)
        trust = try c.decodeIfPresent([[Double]].self, forKey: .trust)
        comment = try c.decodeIfPresent(String.self, forKey: .comment) ?? ""
        voices = try c.decode([RoleEntry].self, forKey: .voices)
    }
}

nonisolated struct RoleEntry: Codable {
    var id: String
    var name: String = ""
    var program: String = ""
    var notes: Int = 0
    var range: String = ""
    var suggested: String = ""
    var why: String = ""
    /// melody | countermelody | chords | bass | ignore | drums | melody+chords (top line melody, rest chords) |
    /// melody+countermelody (top line melody, rest countermelody) | chords+bass (lowest line bass, rest chords)
    var role: String
    var addTranspose: Int = 0

    init(id: String, name: String, program: String, notes: Int, range: String, suggested: String, why: String, role: String, addTranspose: Int) {
        self.id = id; self.name = name; self.program = program; self.notes = notes; self.range = range
        self.suggested = suggested; self.why = why; self.role = role; self.addTranspose = addTranspose
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        program = try c.decodeIfPresent(String.self, forKey: .program) ?? ""
        notes = try c.decodeIfPresent(Int.self, forKey: .notes) ?? 0
        range = try c.decodeIfPresent(String.self, forKey: .range) ?? ""
        suggested = try c.decodeIfPresent(String.self, forKey: .suggested) ?? ""
        why = try c.decodeIfPresent(String.self, forKey: .why) ?? ""
        role = try c.decode(String.self, forKey: .role)
        addTranspose = try c.decodeIfPresent(Int.self, forKey: .addTranspose) ?? 0
    }
}

func rolesFile(for m: BMMidi, midiRelative: String) -> RolesFile {
    RolesFile(midi: midiRelative, voices: m.voices.map {
        RoleEntry(id: $0.id, name: $0.name, program: $0.programName, notes: $0.notes,
                  range: "\(noteName($0.lowest))-\(noteName($0.highest))", suggested: $0.suggested, why: $0.why,
                  role: $0.role, addTranspose: $0.addTranspose)
    })
}

/// Applies a roles file's choices (matched by voice id, then by name) to the voices.
func applyRoles(_ r: RolesFile, to m: inout BMMidi) throws -> [String] {
    var notes: [String] = []
    for e in r.voices {
        guard validRoles.contains(e.role) else { throw RBError("roles.json: voice \(e.id) has unknown role \(e.role) (use \(validRoles.sorted().joined(separator: ", ")))") }
        if let i = m.voices.firstIndex(where: { $0.id == e.id }) ?? m.voices.firstIndex(where: { !e.name.isEmpty && $0.name == e.name }) {
            if m.voices[i].role != e.role { notes.append("\(e.id) \(e.name.isEmpty ? "" : "'\(e.name)' ")role \(m.voices[i].suggested) -> \(e.role) (roles.json)") }
            if e.addTranspose != 0 { notes.append("\(e.id) \(e.name.isEmpty ? m.voices[i].programName : e.name) addTranspose \(e.addTranspose > 0 ? "+" : "")\(e.addTranspose)") }
            m.voices[i].role = e.role
            m.voices[i].addTranspose = e.addTranspose
        } else {
            notes.append("roles.json voice \(e.id) '\(e.name)' is not in this MIDI file")
        }
    }
    return notes
}

func noteName(_ p: Int) -> String {
    let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    return "\(names[((p % 12) + 12) % 12])\(p / 12 - 1)"
}

/// Plain-text table of every voice.
func roleReport(_ m: BMMidi) -> String {
    func pad(_ s: String, _ n: Int) -> String { s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count) }
    var lines = ["id      name                      program                     notes  range      median poly  chord%  sounding  lyrics  role                  suggested             why"]
    for v in m.voices {
        lines.append(pad(v.id, 8) + pad(v.name.isEmpty ? "-" : v.name, 26) + pad(v.programName, 28)
                     + pad(String(v.notes), 7) + pad("\(noteName(v.lowest))-\(noteName(v.highest))", 11)
                     + pad(noteName(v.medianPitch), 7) + pad(String(format: "%.1f", v.polyphony), 6)
                     + pad(String(format: "%.0f", v.chordOnsets * 100), 8) + pad(String(format: "%.0f s", v.soundingSeconds), 10)
                     + pad(v.lyricShare.map { String(format: "%.0f%%", 100 * $0) } ?? "-", 8)
                     + pad(v.role, 22) + pad(v.suggested, 22) + v.why)
    }
    return lines.joined(separator: "\n")
}
