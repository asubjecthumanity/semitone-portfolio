import Foundation

/// The user's beat settings, as the rhythm stage reads them.
nonisolated struct RhythmSettings: Equatable {
    /// nil detects the meter.
    var beatsPerMeasure: Int?
    /// A pitch class the player puts on beat 1.
    var downbeatPitchClass: Int?
    /// -1 / +1 re-track at half / double the detected tempo.
    var tempoOctave = 0
    /// Moves beat 1 by this many beats.
    var barShift = 0
}

/// Stage 6: beats, bar lines and meter (BeatTracker, a bar-pointer model).
nonisolated enum RhythmStage {
    static func grid(notes: [NoteEvent], duration: Double, settings: RhythmSettings,
                     audioOnsets: AudioOnsets? = nil) -> BeatGrid {
        BeatGrid.compute(notes: notes, downbeatPitchClass: settings.downbeatPitchClass,
                         beatsPerMeasure: settings.beatsPerMeasure, maxTime: duration,
                         tempoOctave: settings.tempoOctave, barShift: settings.barShift, audioOnsets: audioOnsets)
    }
}

/// Everything shown next to a note list: the melody, the beat grid and the
/// chords. Re-runs whenever the notes or the beat settings change.
nonisolated struct TakeAnalysis {
    var melody: [NoteEvent]
    var chords: [ChordSegment]
    var grid: BeatGrid
    /// The notes with the chords part rebuilt from the chord names (stage 8,
    /// `ChordVoicer`), for the Simplified chord style; nil when not asked for.
    var simplified: [NoteEvent]? = nil

    /// `grid: false` skips the beat tracker (live updates, or a preview a
    /// refine pass will replace). `simplifyChords` also voices the chord
    /// names (`ChordVoicer`); the live view skips it, since a new take always
    /// starts as played. `harmonyNotes` are further notes the chords read
    /// (`RefineOutput.harmonyNotes`); the chords also read `audioOnsets`'
    /// chroma when it has one (Song mode).
    static func derive(notes: [NoteEvent], duration: Double,
                       rhythm: RhythmSettings, audioOnsets: AudioOnsets? = nil, harmonyNotes: [NoteEvent] = [],
                       grid withGrid: Bool = true, simplifyChords: Bool = false) -> TakeAnalysis {
        // A take split into parts already knows its melody.
        let split = notes.contains { $0.voice != .none }
        let melody = split ? notes.filter { $0.voice == .melody } : LeadLine.melody(from: notes)
        let grid = withGrid ? RhythmStage.grid(notes: notes, duration: duration, settings: rhythm,
                                               audioOnsets: audioOnsets) : .empty
        let chords = HarmonyStage.chords(notes: notes, grid: grid, alsoHeard: harmonyNotes, audio: audioOnsets)
        let simplified = simplifyChords ? ChordVoicer.voice(notes: notes, chords: chords, grid: grid).notes : nil
        return TakeAnalysis(melody: melody, chords: chords, grid: grid, simplified: simplified)
    }

    /// `heard` (`RefineOutput.harmonyNotes`) without the copies of notes an
    /// edit took out of the take, so the chords respect the edit (an AI
    /// cleanup's removed ghost or overtone, an octave it moved): a heard note
    /// goes when it overlaps, at its pitch, a note of `before` that `after`
    /// no longer holds, and no note of `after` at that pitch.
    static func harmonyNotes(_ heard: [NoteEvent], before: [NoteEvent], after: [NoteEvent]) -> [NoteEvent] {
        struct Key: Hashable { let pitch: Int, start: Double, end: Double }
        let kept = Set(after.map { Key(pitch: $0.pitch, start: $0.startTime, end: $0.endTime) })
        let removed = Dictionary(grouping: before.filter { !kept.contains(Key(pitch: $0.pitch, start: $0.startTime, end: $0.endTime)) },
                                 by: \.pitch)
        guard !removed.isEmpty else { return heard }
        let remaining = Dictionary(grouping: after, by: \.pitch)
        func overlaps(_ n: NoteEvent, _ list: [NoteEvent]?) -> Bool {
            list?.contains { $0.startTime < n.endTime && n.startTime < $0.endTime } ?? false
        }
        return heard.filter { !overlaps($0, removed[$0.pitch]) || overlaps($0, remaining[$0.pitch]) }
    }
}
