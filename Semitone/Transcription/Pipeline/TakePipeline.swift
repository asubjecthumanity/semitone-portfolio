import Foundation

/// What the refine pass needs from the app: the finished take and the quick
/// Basic Pitch preview it already shows.
nonisolated struct RefineInput {
    var mode: TranscriptionMode
    /// All channels mixed, 44.1 kHz. May be empty for a live take whose
    /// full-rate copy is missing; then `take22k` is used.
    var take44k: [Float]
    var take22k: [Float]? = nil
    /// The quick preview's notes for this take (the arbiter's reference).
    var quickNotes: [NoteEvent]
}

/// The refined take.
nonisolated struct RefineOutput {
    var notes: [NoteEvent]
    var sustain: [PedalEvent] = []
    /// The engine whose notes these are.
    var engine: NoteEngineKind
    /// The arbiter's verdict on the refine engine. Anything but `.accept`
    /// means the app should keep the quick preview instead.
    var verdict: EngineArbiter.Verdict = .accept
    var profile: SourceProfile?
    /// The audio's rhythm evidence for the beat tracker (OnsetEnvelope).
    var onsetEnvelope: AudioOnsets? = nil
    /// Notes the chord stage reads beside `notes` (`HarmonyStage.chords`'
    /// `alsoHeard`). Song mode: the preview's notes. The refine pass keeps a
    /// note only when its attack and part hold up (cleanup, the line from the
    /// preview, the bass clean-up), which is right for the notes shown but
    /// leaves out held and unattacked chord tones; the harmony needs what
    /// sounds. Notes both passes heard count twice. On the Song mode
    /// scoreboard's dev songs this gained about 3 points of chord accuracy
    /// over the refine notes alone. Written in the take's tuning like the
    /// notes shown (`TuningEstimate.corrected`), so a drifting take's chords
    /// do not hear its harmony twice, a semitone apart. Piano mode passes
    /// none, so its chords still come from the notes shown (not measured
    /// there: no piano key has chords).
    var harmonyNotes: [NoteEvent] = []
    /// Facts for logs and benchmarks.
    var info: [String: String] = [:]
}

/// Stages 1-5 for a finished take (see PipelineStages.swift). The engines are
/// injected, so the app loads its bundled models and the benchmarks load
/// compiled ones from disk.
nonisolated struct TakePipeline {
    var basicPitch: BasicPitchNoteEngine
    var transkun: TranskunNoteEngine
    var arbiter = EngineArbiter()
    var parts: any PartAssigner = VoiceSplitterAssigner()
    var profiler = SourceProfiler.Settings()
    /// Any-instrument mode tries Transkun before Basic Pitch.
    var preferTranskun = true
    /// ... and adds the preview notes it missed (see NoteFusion.union).
    /// ... and takes the melody and countermelody from the preview's split,
    /// which hears leads (synth, winds, voice) Transkun misses or puts an
    /// octave low.
    var melodyFromPreview = true
    /// ... choosing that melody by level, continuity, register and the notes
    /// only the preview heard (`VoiceSplitter.chooseLine`), not only as the
    /// top note: a singer often sits under the band.
    var chooseLine = true
    var fuseQuickNotes = true
    /// Notes without an attack at their own pitch are merged or dropped, and
    /// late Basic Pitch onsets moved to their attack (NoteCleanup).
    var cleanup = NoteCleanup.Settings()
    /// Low notes' onsets checked against the audio and the bass part cleaned
    /// up (BassStage); nil skips it.
    var bass: BassStage.Settings? = BassStage.Settings()

    /// Returns nil if cancelled. `progress` gets 0...1.
    func refine(_ input: RefineInput, progress: (Double) -> Void = { _ in },
                isCancelled: () -> Bool = { false }) throws -> RefineOutput? {
        switch input.mode {
        case .piano: try refinePiano(input, progress: progress, isCancelled: isCancelled)
        case .music: try refineMusic(input, progress: progress, isCancelled: isCancelled)
        }
    }

    /// Piano mode: Transkun, checked against the preview.
    private func refinePiano(_ input: RefineInput, progress: (Double) -> Void,
                             isCancelled: () -> Bool) throws -> RefineOutput? {
        // Piano mode needs no 22 kHz copy or profile: Transkun reads the 44.1 kHz take.
        let take = ConditionedTake(audio44k: input.take44k, audio22k: [], tuning: TuningEstimate())
        guard let result = try transkun.transcribe(take, profile: SourceProfile(), progress: progress,
                                                   isCancelled: isCancelled) else { return nil }
        let seconds = Double(input.take44k.count) / PianoModel.sampleRate
        var output = RefineOutput(notes: result.notes, sustain: result.sustain, engine: .transkun, info: result.info)
        output.verdict = arbiter.judge(result, reference: input.quickNotes, seconds: seconds)
        output.onsetEnvelope = AudioOnsets(onsets: OnsetEnvelope.compute(input.take44k,
                                                                         sampleRate: PianoModel.sampleRate))
        return output
    }

    /// Any-instrument mode: profile the take, transcribe it and split it into
    /// melody, countermelody, chords and bass. Drums are not transcribed: the profile's
    /// harmonic/percussive split only keeps them out of the pitched notes.
    private func refineMusic(_ input: RefineInput, progress: (Double) -> Void,
                             isCancelled: () -> Bool) throws -> RefineOutput? {
        var take = try InputConditioner.condition(take44k: input.take44k,
                                                  take22k: input.take44k.isEmpty ? input.take22k ?? [] : nil)
        progress(0.05)
        guard let (profile, separated) = SourceProfiler.profile(take, quickNotes: input.quickNotes, settings: profiler,
                                                                isCancelled: isCancelled) else { return nil }
        take.harmonic22k = separated.harmonic
        progress(0.2)

        // Transkun first: on struck and plucked sources it is the most accurate
        // engine by far. The arbiter falls back to Basic Pitch where it
        // disagrees with the preview (voices, winds, bowed legato).
        var engineNotes: EngineNotes?
        var verdict = EngineArbiter.Verdict.accept
        var transkunNotes: [NoteEvent] = []
        if preferTranskun, !take.audio44k.isEmpty {
            guard let candidate = try transkun.transcribe(take, profile: profile, progress: { progress(0.2 + 0.6 * $0) },
                                                          isCancelled: isCancelled) else { return nil }
            verdict = arbiter.judge(candidate, reference: input.quickNotes, seconds: take.seconds)
            if verdict == .accept {
                var accepted = candidate
                // Piano decay cuts sustained notes short: hold each note as long
                // as the preview heard it ringing. Pedal spans mean nothing here.
                accepted.notes = NoteFusion.extendOffsets(candidate.notes, using: input.quickNotes)
                if fuseQuickNotes { accepted.notes = NoteFusion.union(accepted.notes, adding: input.quickNotes) }
                accepted.sustain = []
                engineNotes = accepted
                transkunNotes = candidate.notes
            }
        }
        if engineNotes == nil {
            let start = preferTranskun ? 0.8 : 0.2, span = preferTranskun ? 0.05 : 0.6
            guard let fallback = try basicPitch.transcribe(take, profile: profile, progress: { progress(start + span * $0) },
                                                           isCancelled: isCancelled) else { return nil }
            engineNotes = fallback
        }
        guard var engineNotes else { return nil }
        // Swells of held synth notes and echoes of other notes have no attack
        // at their own pitch. Checked on the pitches as heard, before the drift
        // correction below; the preview's notes too where they supply the melody.
        let previewMelody = engineNotes.engine == .transkun && melodyFromPreview
        var previewNotes = input.quickNotes
        var cleanupReport = NoteCleanup.Report()
        if cleanup.enabled {
            let checked = NoteCleanup.verify(engineNotes.notes, audio22k: take.audio22k, tonal22k: take.harmonic22k,
                                             transkun: transkunNotes, basicPitch: input.quickNotes,
                                             tuningCents: take.tuning.cents, settings: cleanup)
            engineNotes.notes = checked.notes
            cleanupReport = checked.report
            if previewMelody {
                previewNotes = NoteCleanup.verify(input.quickNotes, audio22k: take.audio22k, tonal22k: take.harmonic22k,
                                                  transkun: transkunNotes, basicPitch: input.quickNotes,
                                                  tuningCents: take.tuning.cents, settings: cleanup).notes
            }
        }
        if isCancelled() { return nil }
        // Unfretted sources drift (a cappella choirs sag); write them in the
        // tuning they started in. Equal-tempered takes stay within the threshold.
        engineNotes.notes = take.tuning.corrected(engineNotes.notes)
        // With the line from the preview, the preview's split chooses its line
        // (`chooseLine`), both splits are merged as heard and the line is
        // settled once on the merged take: this split's line notes give way to
        // the preview's line where it has them (or their octave) and otherwise
        // stay as chords (NoteFusion.melodyFromReference), and the preview's
        // weak line notes stay as chords.
        var notes = parts.assign(engineNotes.notes, profile: profile, settleLine: !previewMelody)
        if previewMelody {
            var preview = parts.assign(previewNotes, profile: profile, settleLine: false)
            if chooseLine { preview = parts.chooseLine(preview, otherEngine: transkunNotes) }
            notes = parts.settleLine(NoteFusion.melodyFromReference(notes, reference: preview))
        }
        if let bass { notes = BassStage.refine(notes, audio: take.audio22k, sampleRate: BPConstants.sampleRate, settings: bass) }
        if isCancelled() { return nil }
        progress(1)
        var info = engineNotes.info
        if cleanup.enabled { info["cleanup"] = cleanupReport.summary }
        info["percussiveShare"] = String(format: "%.3f", profile.percussiveShare)
        if let hits = profile.hitsWithoutNotes { info["hitsWithoutNotes"] = String(format: "%.2f", hits) }
        info["tuningCents"] = String(format: "%.1f", profile.tuning.cents)
        info["driftCents"] = profile.tuning.drift.map { String(format: "%.0f", $0.cents) }.joined(separator: ",")
        info["quickMedianDuration"] = String(format: "%.3f", profile.quickMedianDuration)
        info["verdict"] = "\(verdict)"
        info["quickNotes"] = String(input.quickNotes.count)
        // The audio's evidence: for the beat tracker the tonal part's onsets
        // and chord changes, and the percussive part's onsets on a take with a
        // kit (percussionCue: "on" in full, else its weight); for the chords
        // the tonal part's pitch classes (audioEvidence).
        let onsets = Self.audioEvidence(separated, percussiveShare: profile.percussiveShare, tuning: take.tuning)
        info["percussionCue"] = onsets.percussion.map { $0.weight < 1 ? String(format: "%.2f", $0.weight) : "on" } ?? "off"
        return RefineOutput(notes: notes, engine: engineNotes.engine, verdict: verdict, profile: profile,
                            onsetEnvelope: onsets, harmonyNotes: take.tuning.corrected(input.quickNotes), info: info)
    }

    /// What the any-instrument take's audio tells the later stages: for the
    /// beat tracker, the tonal part's onsets and chord changes, and the
    /// percussive part's onsets on a take with a kit, weighted by its
    /// percussive share (OnsetEnvelope.music); for the chord stage, the tonal
    /// part's pitch classes in the take's tuning (OnsetEnvelope.tonalChroma).
    static func audioEvidence(_ parts: HarmonicPercussive.Output, percussiveShare: Double,
                              tuning: TuningEstimate) -> AudioOnsets {
        var onsets = OnsetEnvelope.music(parts, percussiveShare: percussiveShare, sampleRate: BPConstants.sampleRate)
        onsets.chroma = OnsetEnvelope.tonalChroma(parts.harmonic, sampleRate: BPConstants.sampleRate,
                                                  tuningCents: tuning.namingOffset(at:))
        return onsets
    }

    /// The any-instrument evidence for a take reopened from disk, whose save
    /// holds the notes shown but nothing else: the audio's (`audioEvidence`)
    /// and the notes the chords read beside them (`RefineOutput.harmonyNotes`),
    /// from `preview`, the quick notes extracted again, written in the take's
    /// tuning as the refine pass writes them. `onsets` is nil if the
    /// separation fails.
    static func reopened(music take22k: [Float], preview: [NoteEvent],
                         isCancelled: () -> Bool = { false }) -> (onsets: AudioOnsets?, harmonyNotes: [NoteEvent]) {
        let tuning = InputConditioner.estimateTuning(take22k, sampleRate: BPConstants.sampleRate)
        let harmony = tuning.corrected(preview)
        guard let parts = HarmonicPercussive.separate(take22k, settings: SourceProfiler.Settings().separation,
                                                      isCancelled: isCancelled) else { return (nil, harmony) }
        let share = SourceProfiler.percussiveShare(mix: take22k, percussive: parts.percussive)
        return (audioEvidence(parts, percussiveShare: share, tuning: tuning), harmony)
    }
}
