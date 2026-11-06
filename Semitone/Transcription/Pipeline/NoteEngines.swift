import Foundation

/// Basic Pitch over the whole take, as the any-instrument refine pass has run
/// it since the start: the harmonic part when drums are prominent (their hits
/// no longer read as pitched onsets), else the mix itself (separation also
/// softens plucked and struck attacks), with thresholds tuned on the
/// mixed-instrument MusicBench songs.
nonisolated struct BasicPitchNoteEngine: NoteEngine {
    struct Settings: Equatable {
        var extraction = NoteExtraction.Config.music
        var tonalExtraction = NoteExtraction.Config.musicTonal
        /// Transcribe the harmonic part when at least this share of the take's
        /// energy is percussive. On the benchmark songs a drum kit put 11-24%
        /// there (separating helped by up to 0.07 F1) and drum-less or lightly
        /// played songs 1-8% (separating cost up to 0.08).
        var tonalPartAbove = 0.1
    }

    var kind: NoteEngineKind { .basicPitch }
    let model: () throws -> BasicPitchModel
    var settings = Settings()

    func usesTonalPart(_ profile: SourceProfile) -> Bool { profile.percussiveShare >= settings.tonalPartAbove }

    func transcribe(_ take: ConditionedTake, profile: SourceProfile,
                    progress: (Double) -> Void, isCancelled: () -> Bool) throws -> EngineNotes? {
        let useTonal = usesTonalPart(profile) && take.harmonic22k != nil
        let input = useTonal ? take.harmonic22k! : take.audio22k
        let engine = TranscriptionEngine(model: try model())
        // Feed in slices so cancellation and progress stay responsive.
        let slice = BPConstants.hopSamples * 8
        var offset = 0
        while offset < input.count {
            if isCancelled() { return nil }
            let end = min(offset + slice, input.count)
            try engine.append(Array(input[offset..<end]))
            offset = end
            progress(Double(offset) / Double(max(input.count, 1)))
        }
        try engine.finalize()
        let config = useTonal ? settings.tonalExtraction : settings.extraction
        return EngineNotes(engine: .basicPitch, notes: engine.extractNotes(config: config),
                           info: ["input": useTonal ? "harmonic part" : "mix"])
    }
}

/// Transkun v2, the piano model, on the 44.1 kHz take. Built for piano, but
/// the most accurate engine Semitone has for any struck or plucked string
/// (guitar, a band's piano, bass and guitars, a string quartet's attacks).
nonisolated struct TranskunNoteEngine: NoteEngine {
    var kind: NoteEngineKind { .transkun }
    /// Loaded per take and released after it, so the model's working memory
    /// isn't held between takes.
    let transcriber: () throws -> PianoTranscriber

    func transcribe(_ take: ConditionedTake, profile: SourceProfile,
                    progress: (Double) -> Void, isCancelled: () -> Bool) throws -> EngineNotes? {
        let started = Date()
        let model = try transcriber()
        let loaded = Date()
        let transcribed = try withoutActuallyEscaping(progress) { progress in
            try withoutActuallyEscaping(isCancelled) { isCancelled in
                try model.transcribe(samples: take.audio44k, progress: progress, isCancelled: isCancelled)
            }
        }
        guard let result = transcribed else { return nil }
        let summary = String(format: "piano model (%@) took %.1f s (load %.1f s) for %.1f s of audio (%ld notes, %ld pedal presses)",
                             model.label, Date().timeIntervalSince(started), loaded.timeIntervalSince(started),
                             Double(take.audio44k.count) / PianoModel.sampleRate, result.notes.count, result.sustain.count)
        return EngineNotes(engine: .transkun, notes: result.notes, sustain: result.sustain, info: ["summary": summary])
    }
}
