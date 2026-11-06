import Foundation

/// Pulls a single lead line (melody) out of polyphonic note detections.
/// No ML and no network: at every note boundary it picks the one sounding
/// note that best continues the last chosen pitch — loudness up, big jumps
/// down — so chord accompaniment and octave doubles fall away naturally.
/// The most salient stream becomes a playable melody.
nonisolated enum LeadLine {
    struct Settings: Equatable {
        /// Notes at or below this MIDI pitch are never chosen (drops the bass).
        var floorPitch: Int = 40
        /// Loudness weight in the selection score.
        var amplitudeWeight: Double = 1.0
        /// Score penalty per semitone of jump away from the running pitch.
        var stepPenalty: Double = 0.06
        /// Small upward preference, per octave, to untie near-equal loudness
        /// picks (the melody usually sits on top of the accompaniment).
        var highBias: Double = 0.02
        /// A chosen note shorter than this (s) is dropped as flicker.
        var minNoteSeconds: Double = 0.04
        /// Score bonus for a note struck right now (within `freshSeconds`)
        /// while an older note is still ringing. Held chord tones, pedalled
        /// notes and long decays pay no step penalty, so without it a melody
        /// moving over them was never chosen.
        var onsetBonus: Double = 0.5
        /// How recent a start counts as "struck right now" (s).
        var freshSeconds: Double = 0.03
        /// A note counts as ringing (older) once it has sounded this long (s).
        var ringingAfter: Double = 0.1
        /// New notes more than this many semitones below the line's pitch get
        /// no bonus, so an inner voice moving under a held melody note stays out.
        var onsetBonusReach: Int = 2
    }

    static func melody(from notes: [NoteEvent], settings: Settings = Settings()) -> [NoteEvent] {
        guard !notes.isEmpty else { return [] }
        let usable = notes.filter { $0.pitch >= settings.floorPitch }
        guard !usable.isEmpty else { return [] }

        // Harmony only changes at a note start or end, so those are the
        // boundaries — same trick ChordAnalyzer uses. A sweep line keeps the
        // notes sounding at each midpoint (filtering every note per boundary
        // was O(n²): seconds at -Onone on a long take).
        let bounds = Set(usable.flatMap { [$0.startTime, $0.endTime] }).sorted()
        let byStart = usable.indices.sorted { usable[$0].startTime < usable[$1].startTime }
        var admitted = 0
        var sounding: [Int] = []   // indices into `usable`, kept ascending
        // `source`: the note (index into `usable`) the entry currently follows.
        var line: [(start: Double, end: Double, pitch: Int, amplitude: Double, source: Int)] = []

        for i in 0..<(bounds.count - 1) {
            let a = bounds[i], b = bounds[i + 1]
            guard b - a > 1e-4 else { continue }
            let mid = (a + b) / 2
            var added = false
            while admitted < byStart.count, usable[byStart[admitted]].startTime <= mid {
                sounding.append(byStart[admitted])
                admitted += 1
                added = true
            }
            sounding.removeAll { usable[$0].endTime <= mid }
            // Input order, so score ties resolve to the earlier note.
            if added { sounding.sort() }
            guard !sounding.isEmpty else { continue }

            let last = line.last
            let continuing = last.map { a - $0.end < 1e-3 } ?? false
            // New notes near or above the line's pitch get the onset bonus
            // while something older is still ringing (also just after a short
            // rest, so the next melody note beats a held chord tone).
            let recent = last.map { a - $0.end < 0.3 } ?? false
            var bonusFloor: Int?
            if let last, recent, sounding.contains(where: { usable[$0].startTime < a - settings.ringingAfter }) {
                bonusFloor = last.pitch - settings.onsetBonusReach
            }
            var chosen = sounding[0]
            var bestScore = -Double.infinity
            for index in sounding {
                let note = usable[index]
                var value = score(note, continuing: last?.pitch, settings: settings)
                if let bonusFloor, note.startTime >= a - settings.freshSeconds, note.pitch >= bonusFloor {
                    value += settings.onsetBonus
                }
                if value > bestScore {
                    bestScore = value
                    chosen = index
                }
            }
            let then = usable[chosen]

            // Same pitch carries on unless there was a gap or that pitch was
            // just struck again: repeated notes stay separate notes, and a
            // rest doesn't get filled in.
            if let last, continuing, last.pitch == then.pitch,
               !sounding.contains(where: { $0 != last.source && usable[$0].pitch == then.pitch && usable[$0].startTime >= a }) {
                let n = line.count - 1
                line[n].end = b
                line[n].amplitude = max(line[n].amplitude, then.amplitude)
                line[n].source = chosen
            } else {
                // A note already sounding when the current line note began was
                // passed over then (a held chord tone, an older pedalled note):
                // leave a rest rather than re-enter it.
                if let last, chosen != last.source, then.startTime < last.start - settings.freshSeconds { continue }
                line.append((start: a, end: b, pitch: then.pitch, amplitude: then.amplitude, source: chosen))
            }
        }

        return line
            .filter { $0.end - $0.start >= settings.minNoteSeconds }
            .map { NoteEvent(startTime: $0.start, endTime: $0.end, pitch: $0.pitch, amplitude: $0.amplitude) }
    }

    private static func score(_ note: NoteEvent, continuing previous: Int?, settings: Settings) -> Double {
        var value = settings.amplitudeWeight * note.amplitude
        value += settings.highBias * Double(note.pitch) / 12.0
        if let previous {
            value -= settings.stepPenalty * Double(abs(note.pitch - previous))
        }
        return value
    }
}
