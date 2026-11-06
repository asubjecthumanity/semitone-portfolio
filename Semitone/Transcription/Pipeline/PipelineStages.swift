import Foundation

// MARK: - The refine pipeline, stage by stage
//
// A finished take is refined in explicit stages. Each stage is a small type
// behind a protocol, so the app, the command-line benchmarks (Tools/RealBench,
// Tools/MusicBench) and a future server or engine package all run the same
// code. Nothing in Transcription/Pipeline may import SwiftUI or touch the view
// model: the view model hands a `RefineInput` to `TakePipeline.refine` and
// shows the `RefineOutput` it gets back.
//
//  1. Input conditioning (`InputConditioner`): one mixed 44.1 kHz take, its
//     22.05 kHz copy for Basic Pitch, and a tuning / drift estimate in cents.
//  2. Source profiling (`SourceProfiler`): what kind of recording this is —
//     how much of it is percussive (drums are separated out so they don't read
//     as pitched onsets), how sustained the notes are. Later stages read the
//     profile instead of re-deriving it.
//  3. Note engines (`NoteEngine`: `BasicPitchNoteEngine`, `TranskunNoteEngine`)
//     each turn the take into notes. Basic Pitch is also the live preview.
//  4. The arbiter (`EngineArbiter`) compares an engine's notes with the quick
//     Basic Pitch preview of the same take and decides which to keep. It
//     replaces the one-engine validity check, which remains as its broken-output
//     test (`PianoTranscriber.looksValid`). In the any-instrument mode the kept
//     notes (Transkun's completed by the preview's, `NoteFusion`) then go
//     through `NoteCleanup`: a note the two engines did not both start must
//     show an attack at its own pitch in the audio, so swells of held notes
//     and echoes are merged or dropped, and a long Basic Pitch note that
//     started late moves to its attack.
//  5. Voicing (`PartAssigner`, `VoiceSplitter`): melody / countermelody /
//     chords / bass. In the any-instrument mode `BassStage` then moves the
//     low notes' onsets to their attack in the audio, cleans up the bass
//     part and puts bass notes written in the wrong octave right, phrase by
//     phrase (after the split, so a moved note cannot take the bass role).
//  6. Rhythm (`RhythmStage`): beats, bar lines and meter (BeatTracker), from
//     the notes and the audio's onsets (`AudioOnsets`: the tonal part's, and
//     on a drum-heavy take the percussive part's too).
//  7. Harmony (`HarmonyStage`): chords (and the key), on the beat grid. In
//     the any-instrument mode the chords also read the preview's notes
//     (`RefineOutput.harmonyNotes`), which hold chord tones the refine pass
//     leaves out of the notes it shows, and the tonal part's pitch classes
//     in the take's tuning (`AudioOnsets.chroma`), which name the chord
//     where the notes are thin or silent.
//  8. Simplified chords (`ChordVoicer`): the chords part rebuilt from the
//     chord names, as plain voicings struck in the part's own rhythm, for the
//     Simplified chord style. The transcribed part stays the take's notes.
//
// Drums are not transcribed: the any-instrument mode writes the melody,
// countermelody, chords and bass.
//
// Stages 1-5 run once per take, after recording (`TakePipeline.refine`).
// Stages 6-8 are cheap and re-run whenever the notes or the user's beat
// settings change (`TakeAnalysis.derive`).

/// Which note engine produced a take's notes.
nonisolated enum NoteEngineKind: String, Equatable, Sendable {
    /// Basic Pitch (Spotify's NMP model): instrument-agnostic, light, live.
    case basicPitch
    /// Transkun v2 (the piano model): far more accurate on struck and plucked
    /// strings, blind to voices.
    case transkun
}

/// Stage 1's output: the take as every later stage reads it.
nonisolated struct ConditionedTake {
    /// All channels mixed, 44.1 kHz (Transkun's rate).
    var audio44k: [Float]
    /// The same take at 22.05 kHz (Basic Pitch's rate).
    var audio22k: [Float]
    var tuning: TuningEstimate
    /// The take's harmonic part (drums removed) at 22.05 kHz, once source
    /// profiling has separated it.
    var harmonic22k: [Float]? = nil

    var seconds: Double { Double(audio22k.count) / BPConstants.sampleRate }
}

/// How far the take sits from A440 equal temperament, in cents (-50...50),
/// overall and per window (a choir drifting flat, a tape running slow).
nonisolated struct TuningEstimate: Equatable {
    var cents: Double = 0
    /// Window start times (s) and their unwrapped offsets (cents), so a slow
    /// drift past a quarter tone keeps counting instead of wrapping around.
    var drift: [(time: Double, cents: Double)] = []
    /// Share of frames with a clear enough spectral peak to judge tuning.
    var confidence: Double = 0

    static func == (a: TuningEstimate, b: TuningEstimate) -> Bool {
        a.cents == b.cents && a.confidence == b.confidence
            && a.drift.map(\.time) == b.drift.map(\.time) && a.drift.map(\.cents) == b.drift.map(\.cents)
    }
}

/// Stage 3: a note engine. `transcribe` returns nil if cancelled.
nonisolated protocol NoteEngine {
    var kind: NoteEngineKind { get }
    func transcribe(_ take: ConditionedTake, profile: SourceProfile,
                    progress: (Double) -> Void, isCancelled: () -> Bool) throws -> EngineNotes?
}

/// One engine's reading of a take.
nonisolated struct EngineNotes {
    var engine: NoteEngineKind
    var notes: [NoteEvent]
    /// Sustain pedal spans (Transkun only).
    var sustain: [PedalEvent] = []
    /// Free-form facts for logs and benchmarks ("input": "tonal part", ...).
    var info: [String: String] = [:]
}

/// Stage 5: sorts notes into parts.
nonisolated protocol PartAssigner {
    /// `settleLine: false` leaves the line as heard note by note, before the
    /// decisions that need the whole line; `settleLine(_:)` then makes them on
    /// a take merged from two splits (TakePipeline).
    func assign(_ notes: [NoteEvent], profile: SourceProfile, settleLine: Bool) -> [NoteEvent]
    func settleLine(_ notes: [NoteEvent]) -> [NoteEvent]
    /// Re-chooses the melody of a split take as a listener follows it, using
    /// the notes a second engine heard in the same take (TakePipeline: the
    /// preview's split, against Transkun's notes).
    func chooseLine(_ notes: [NoteEvent], otherEngine: [NoteEvent]) -> [NoteEvent]
}

/// The register-based melody / countermelody / chords / bass split.
nonisolated struct VoiceSplitterAssigner: PartAssigner {
    var settings = VoiceSplitter.Settings()
    func assign(_ notes: [NoteEvent], profile: SourceProfile, settleLine: Bool) -> [NoteEvent] {
        VoiceSplitter.assign(notes, settings: settings, settleLine: settleLine,
                             percussiveShare: profile.percussiveShare, hitsWithoutNotes: profile.hitsWithoutNotes)
    }
    func settleLine(_ notes: [NoteEvent]) -> [NoteEvent] {
        VoiceSplitter.settleLine(notes, settings: settings)
    }
    func chooseLine(_ notes: [NoteEvent], otherEngine: [NoteEvent]) -> [NoteEvent] {
        VoiceSplitter.chooseLine(notes, otherEngine: otherEngine, settings: settings)
    }
}
