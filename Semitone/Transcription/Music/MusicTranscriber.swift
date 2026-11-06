import Foundation

/// The any-instrument mode's reading of a take: pitched notes split into
/// melody / countermelody / chords / bass. Drums are not transcribed.
nonisolated struct MusicTranscription {
    var notes: [NoteEvent]
    /// The audio's evidence for the beat tracker and the chords
    /// (`TakePipeline.audioEvidence`; recomputed for takes reopened from
    /// disk, see `TakePipeline.reopened(music:preview:)`).
    var onsets: AudioOnsets? = nil
    /// Further notes the chords read (`RefineOutput.harmonyNotes`: the
    /// preview's notes in the take's tuning, extracted again from the audio
    /// for a reopened take).
    var harmonyNotes: [NoteEvent] = []
}

/// The any-instrument mode's settings, gathered in one place for the
/// benchmarks. The pass itself is `TakePipeline.refine` (Transcription/Pipeline):
/// HPSS profiling, a note engine and `VoiceSplitter`.
nonisolated enum MusicTranscriber {
    struct Settings {
        var extraction = BasicPitchNoteEngine.Settings().extraction
        var tonalExtraction = BasicPitchNoteEngine.Settings().tonalExtraction
        var separation = SourceProfiler.Settings().separation
        var tonalPartAbove = BasicPitchNoteEngine.Settings().tonalPartAbove
        var voices = VoiceSplitter.Settings()
    }

    /// Fraction of the take's energy in its percussive part.
    static func percussiveShare(mix: [Float], percussive: [Float]) -> Double {
        SourceProfiler.percussiveShare(mix: mix, percussive: percussive)
    }
}
