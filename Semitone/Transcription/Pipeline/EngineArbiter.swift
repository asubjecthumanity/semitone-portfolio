import Foundation

/// Stage 4: decides whether a refine engine's notes replace the quick Basic
/// Pitch preview of the same take. The preview is always there (it is what the
/// app shows while recording), so the arbiter can compare the two engines
/// instead of judging one in isolation.
nonisolated struct EngineArbiter {
    struct Settings: Equatable {
        /// A broken compute path (fp16 on the iPhone 17's CPU) turns Transkun's
        /// output into a wall of one-frame notes on every key (~170 a second).
        /// Real takes have well under 1% one-frame notes and a few notes a second.
        var maxBlipShare = 0.3
        var maxNotesPerSecond = 60.0
        /// Cross-engine check: the refine engine must find at least this share
        /// of the preview's note count. On voices Transkun, a piano model,
        /// hears a fraction of what Basic Pitch does (the Dagstuhl choir: 92
        /// notes against about 400); on piano, guitar, band and strings it
        /// finds 0.6-1.2x as many.
        var minCountRatio = 0.4
        /// ... and its notes must not be far shorter than the preview's: a
        /// median under `minMedianDuration` seconds while the preview's is
        /// over `sustainedMedian` means it is chopping sustained notes into blips.
        /// Only together with a count under `shortNotesCountRatio` of the
        /// preview's: on the Haydn quartet Transkun's notes are short (piano
        /// decay) but it finds more of them than the preview, and it is right.
        var minMedianDuration = 0.08
        var sustainedMedian = 0.3
        var shortNotesCountRatio = 0.8
        /// Previews with fewer notes than this are too thin to compare against.
        var minReferenceNotes = 40
    }

    enum Verdict: Equatable {
        case accept
        /// The output is broken (a bad compute path), not just a poor reading.
        case broken
        /// The engine heard nothing where the preview heard notes.
        case heardNothing
        /// The engine heard far less, or far shorter notes, than the preview:
        /// the take is not the kind of sound it was trained on.
        case disagrees
    }

    var settings = Settings()

    func judge(_ candidate: EngineNotes, reference: [NoteEvent], seconds: Double) -> Verdict {
        let notes = candidate.notes
        if notes.isEmpty { return reference.isEmpty ? .accept : .heardNothing }
        if !PianoTranscriber.looksValid(notes, seconds: seconds, maxBlipShare: settings.maxBlipShare,
                                        maxNotesPerSecond: settings.maxNotesPerSecond) {
            return .broken
        }
        if reference.count >= settings.minReferenceNotes {
            if Double(notes.count) < settings.minCountRatio * Double(reference.count) { return .disagrees }
            let candidateMedian = SourceProfiler.median(notes.map { $0.endTime - $0.startTime })
            let referenceMedian = SourceProfiler.median(reference.map { $0.endTime - $0.startTime })
            if candidateMedian < settings.minMedianDuration && referenceMedian > settings.sustainedMedian
                && Double(notes.count) < settings.shortNotesCountRatio * Double(reference.count) { return .disagrees }
        }
        return .accept
    }
}
