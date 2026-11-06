import Foundation

/// Accumulates 22050 Hz mono samples, runs the model on overlapping windows,
/// and stitches posteriors so notes can be extracted incrementally (live) or
/// after finalize() (whole file). Not thread-safe: confine to one queue.
nonisolated final class TranscriptionEngine {
    private let model: BasicPitchModel

    /// Audio stream with basic_pitch's half-overlap zero padding prepended.
    private var padded: [Float]
    private var nextWindowStart = 0
    private var originalSampleCount = 0

    /// Stitched posteriors, row-major [frameCount x 88].
    private var onsets: [Float] = []
    private var frames: [Float] = []
    private(set) var frameCount = 0
    private var finalized = false

    /// Running sums behind stats() over rows 0..<totals.rows, so a live take
    /// doesn't rescan every frame after each window.
    private var totals = StatsTotals()
    /// `totals` as they stood before each window's rows, so finalize()'s trim
    /// can rewind exactly.
    private var totalsBeforeWindow: [StatsTotals] = []

    init(model: BasicPitchModel) {
        self.model = model
        padded = [Float](repeating: 0, count: BPConstants.overlapSamples / 2)
    }

    var duration: Double { Double(originalSampleCount) / BPConstants.sampleRate }

    /// Everything appended so far (22050 Hz mono), without the leading padding.
    var recordedAudio: ArraySlice<Float> { padded[(BPConstants.overlapSamples / 2)...] }

    /// Feed samples; runs the model whenever a full window is available.
    /// Returns true if new output frames were produced.
    @discardableResult
    func append(_ samples: [Float]) throws -> Bool {
        precondition(!finalized, "append after finalize")
        padded.append(contentsOf: samples)
        originalSampleCount += samples.count
        return try processWindows(includePartial: false)
    }

    /// Process the trailing partial window and trim to the true audio length.
    func finalize() throws {
        guard !finalized else { return }
        finalized = true
        try processWindows(includePartial: true)
        // Trim by time: each window advances hopSamples (36,164) but keeps 142
        // frames (36,352 samples), so frames drift 188 samples a window and
        // samples / 256 would drop the last ~0.5% of the take (1.3 s of 4 min).
        // frameToTime models that drift and only ever increases.
        let end = duration
        var target = frameCount
        while target > 0, BPConstants.frameToTime(target - 1) >= end { target -= 1 }
        if frameCount > target {
            frameCount = target
            onsets.removeLast(onsets.count - target * BPConstants.pitchCount)
            frames.removeLast(frames.count - target * BPConstants.pitchCount)
            while let last = totalsBeforeWindow.last, last.rows > target { totalsBeforeWindow.removeLast() }
            totals = totalsBeforeWindow.last ?? StatsTotals()
            accumulateStats(through: target)
        }
    }

    func extractNotes(config: NoteExtraction.Config) -> [NoteEvent] {
        let notes = NoteExtraction.notes(onsets: onsets, frames: frames, frameCount: frameCount, config: config)
        return config.suppressOctaveLeak ? NoteExtraction.suppressOctaveLeak(notes) : notes
    }

    /// Clip statistics for the `auto` detection preset, over the stitched
    /// posteriors so far (so it also works mid-recording). O(1): the sums are
    /// kept up to date as windows arrive.
    func stats() -> EngineStats {
        let nf = BPConstants.pitchCount
        guard frameCount > 1 else { return EngineStats() }
        let total = Float(frameCount)
        let soundingFrames = frameCount - totals.silentFrames
        return EngineStats(
            onsetMean: totals.onsetSum / (total * Float(nf)),
            onsetPeak: totals.onsetPeak,
            polyphony: Float(totals.sounding) / total,
            silenceRatio: Float(totals.silentFrames) / total,
            sustainedPolyphony: soundingFrames > 0 ? Float(totals.strongInSounding) / Float(soundingFrames) : 0
        )
    }

    @discardableResult
    private func processWindows(includePartial: Bool) throws -> Bool {
        let trim = BPConstants.overlappingFrames / 2
        let keptFrames = BPConstants.framesPerWindow - 2 * trim
        let nf = BPConstants.pitchCount
        var produced = false

        while true {
            let start = nextWindowStart
            let end = start + BPConstants.windowSamples
            let full = end <= padded.count
            guard full || (includePartial && start < padded.count) else { break }

            let window = Array(padded[start..<min(end, padded.count)])
            let out = try model.predict(window: window)
            guard out.onsets.count == BPConstants.framesPerWindow * nf,
                  out.frames.count == BPConstants.framesPerWindow * nf else {
                throw NSError(
                    domain: "Semitone", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Unexpected model output size"]
                )
            }
            onsets.append(contentsOf: out.onsets[(trim * nf)..<((trim + keptFrames) * nf)])
            frames.append(contentsOf: out.frames[(trim * nf)..<((trim + keptFrames) * nf)])
            frameCount += keptFrames
            totalsBeforeWindow.append(totals)
            accumulateStats(through: frameCount)
            nextWindowStart += BPConstants.hopSamples
            produced = true
        }
        return produced
    }

    /// Adds rows totals.rows..<end to the running sums, cell by cell in the
    /// same order as a full scan, so the float sums come out bit-identical.
    private func accumulateStats(through end: Int) {
        onsets.withUnsafeBufferPointer { onsetBuffer in
            frames.withUnsafeBufferPointer { frameBuffer in
                Self.accumulate(&totals, onsets: onsetBuffer.baseAddress!, frames: frameBuffer.baseAddress!, through: end)
            }
        }
    }

    /// Raw pointers, locals and while loops: this runs on ~12k cells per window
    /// in Debug builds, where Array subscripts and for-in cost ~10x more.
    private static func accumulate(_ totals: inout StatsTotals, onsets o: UnsafePointer<Float>,
                                   frames v: UnsafePointer<Float>, through end: Int) {
        let nf = BPConstants.pitchCount
        let silentEnergy = 0.1 * Float(nf)
        var onsetSum = totals.onsetSum
        var onsetPeak = totals.onsetPeak
        var sounding = totals.sounding
        var silentFrames = totals.silentFrames
        var strongInSounding = totals.strongInSounding
        var row = totals.rows
        while row < end {
            var frameOnset: Float = 0
            var frameEnergy: Float = 0
            var active = 0
            var strong = 0
            var cell = row * nf
            let rowEnd = cell + nf
            while cell < rowEnd {
                let onset = o[cell]
                let value = v[cell]
                if onset >= frameOnset { frameOnset = onset }   // max(frameOnset, onset)
                onsetSum += onset
                frameEnergy += value
                if value > 0.35 { active += 1 }
                if value >= 0.5 { strong += 1 }
                cell += 1
            }
            if frameOnset >= onsetPeak { onsetPeak = frameOnset }
            sounding += active
            if frameEnergy < silentEnergy {
                silentFrames += 1
            } else {
                strongInSounding += strong
            }
            row += 1
        }
        totals = StatsTotals(rows: row, onsetSum: onsetSum, onsetPeak: onsetPeak, sounding: sounding,
                             silentFrames: silentFrames, strongInSounding: strongInSounding)
    }

    private struct StatsTotals {
        var rows = 0
        var onsetSum: Float = 0
        var onsetPeak: Float = 0
        /// Cells above 0.35 note activation.
        var sounding = 0
        var silentFrames = 0
        /// Cells at or above 0.5 note activation, in non-silent frames only.
        var strongInSounding = 0
    }
}
