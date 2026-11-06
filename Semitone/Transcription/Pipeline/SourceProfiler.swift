import Foundation
import Accelerate

/// Stage 2's output: what kind of recording a take is. Scalars only, so it is
/// cheap to log, test and send across a process or network boundary.
nonisolated struct SourceProfile: Equatable {
    /// Share of the take's energy in its percussive part (HPSS). Drum kits put
    /// 5-28% there, drumless takes 1-9% (strummed guitar reaches 9%).
    var percussiveShare = 0.0
    /// On a drum-heavy take (`OnsetEnvelope.drumHeavyShare`), the share of
    /// its percussive part's attacks where no preview note starts
    /// (`SourceProfiler.hitsWithoutNotes`): a drum kit's hits fall between
    /// the notes, a pitched instrument's hard attacks start notes. nil when
    /// not measured.
    var hitsWithoutNotes: Double? = nil
    /// The quick (Basic Pitch) preview's notes per second and median length.
    var quickNoteRate = 0.0
    var quickMedianDuration = 0.0
    var seconds = 0.0
    var tuning = TuningEstimate()

    /// Long, legato notes with few percussive attacks: voices, bowed strings,
    /// winds. Transkun (a piano model) hears little of these.
    var isSustained: Bool { quickMedianDuration >= 0.35 && percussiveShare < 0.06 }
}

nonisolated enum SourceProfiler {
    struct Settings: Equatable {
        var separation = HarmonicPercussive.Settings()
    }

    /// Returns the profile and the harmonic/percussive split it measured (the
    /// Basic Pitch engine transcribes the harmonic part of drum-heavy takes),
    /// or nil if cancelled.
    static func profile(_ take: ConditionedTake, quickNotes: [NoteEvent], settings: Settings = Settings(),
                        isCancelled: () -> Bool = { false }) -> (SourceProfile, HarmonicPercussive.Output)? {
        guard let parts = HarmonicPercussive.separate(take.audio22k, settings: settings.separation, isCancelled: isCancelled) else {
            return nil
        }
        var profile = SourceProfile()
        profile.seconds = take.seconds
        profile.tuning = take.tuning
        profile.percussiveShare = percussiveShare(mix: take.audio22k, percussive: parts.percussive)
        if profile.percussiveShare >= OnsetEnvelope.drumHeavyShare, !quickNotes.isEmpty {
            let hits = OnsetEnvelope.compute(parts.percussive, sampleRate: BPConstants.sampleRate)
            profile.hitsWithoutNotes = hitsWithoutNotes(hits, fps: BeatTracker.fps, noteStarts: quickNotes.map(\.startTime))
        }
        if !quickNotes.isEmpty, take.seconds > 0 {
            profile.quickNoteRate = Double(quickNotes.count) / take.seconds
            profile.quickMedianDuration = median(quickNotes.map { $0.endTime - $0.startTime })
        }
        return (profile, parts)
    }

    /// Fraction of the take's energy in its percussive part.
    static func percussiveShare(mix: [Float], percussive: [Float]) -> Double {
        var mixEnergy: Float = 0, hitEnergy: Float = 0
        vDSP_svesq(mix, 1, &mixEnergy, vDSP_Length(mix.count))
        vDSP_svesq(percussive, 1, &hitEnergy, vDSP_Length(percussive.count))
        return mixEnergy > 0 ? Double(hitEnergy / mixEnergy) : 0
    }

    /// The share of the attacks in an onset envelope (`OnsetEnvelope.compute`
    /// of the percussive part, `fps` frames a second) that no note starts
    /// within `tolerance` s of; nil when the envelope has none. An attack is
    /// a frame that is the largest within `tolerance` on either side and at
    /// least `minLevel` of the envelope's 95th percentile. A drum kit plays
    /// hits between the notes: 58-97% of the attacks on the bitmidi dev songs
    /// with a kit (percussive share 0.25-0.41), even where the preview heard
    /// most of the band. A pitched instrument with hard attacks starts a note
    /// at almost every one: 0-6% on General MIDI solo lines of xylophone,
    /// steel drum, pizzicato strings and slap bass (share 0.22-0.74), at most
    /// 16% on 15 solo instruments.
    static func hitsWithoutNotes(_ envelope: [Float], fps: Double, noteStarts: [Double],
                                 tolerance: Double = 0.05, minLevel: Float = 0.3) -> Double? {
        guard !envelope.isEmpty else { return nil }
        let ranked = envelope.sorted()
        let floor = minLevel * ranked[Int(0.95 * Double(ranked.count - 1))]
        guard floor > 0 else { return nil }
        let starts = noteStarts.sorted()
        let reach = max(1, Int((tolerance * fps).rounded()))
        var hits = 0, unexplained = 0
        for i in envelope.indices where envelope[i] >= floor {
            let window = envelope[max(0, i - reach)...min(envelope.count - 1, i + reach)]
            guard envelope[i] == window.max(), i == 0 || envelope[i - 1] < envelope[i] else { continue }
            hits += 1
            let t = Double(i) / fps
            var lo = 0, hi = starts.count
            while lo < hi { let m = (lo + hi) / 2; if starts[m] < t - tolerance { lo = m + 1 } else { hi = m } }
            if !(lo < starts.count && starts[lo] <= t + tolerance) { unexplained += 1 }
        }
        return hits == 0 ? nil : Double(unexplained) / Double(hits)
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
