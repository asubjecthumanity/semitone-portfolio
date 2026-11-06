import Foundation

/// Combines what two engines heard about the same take.
nonisolated enum NoteFusion {
    /// Extends each note's end to that of the reference note of the same pitch
    /// starting within `onsetTolerance` of it, when that one rings longer, but
    /// never past the next note of the same pitch. Transkun learned piano
    /// decay, so it ends a bowed, blown or sustained guitar note early; Basic
    /// Pitch's frame activations follow the sound for as long as it lasts.
    static func extendOffsets(_ notes: [NoteEvent], using reference: [NoteEvent],
                              onsetTolerance: Double = 0.08) -> [NoteEvent] {
        guard !notes.isEmpty, !reference.isEmpty else { return notes }
        var byPitch: [Int: [NoteEvent]] = [:]
        for r in reference { byPitch[r.pitch, default: []].append(r) }
        for k in byPitch.keys { byPitch[k]!.sort { $0.startTime < $1.startTime } }
        var nextStart: [Int: [Double]] = [:]
        for n in notes { nextStart[n.pitch, default: []].append(n.startTime) }
        for k in nextStart.keys { nextStart[k]!.sort() }

        return notes.map { note in
            guard let candidates = byPitch[note.pitch] else { return note }
            // First reference note starting at or after start - tolerance.
            var lo = 0, hi = candidates.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if candidates[mid].startTime < note.startTime - onsetTolerance { lo = mid + 1 } else { hi = mid }
            }
            var end = note.endTime
            var i = lo
            while i < candidates.count, candidates[i].startTime <= note.startTime + onsetTolerance {
                end = max(end, candidates[i].endTime)
                i += 1
            }
            guard end > note.endTime else { return note }
            let starts = nextStart[note.pitch]!
            if let next = starts.first(where: { $0 > note.startTime + 1e-6 }) { end = min(end, next) }
            guard end > note.endTime else { return note }
            return NoteEvent(startTime: note.startTime, endTime: end, pitch: note.pitch,
                             amplitude: note.amplitude, voice: note.voice)
        }
    }
}

nonisolated extension NoteFusion {
    /// Adds the reference notes the primary engine has nothing for: no
    /// primary note of the same pitch starting within `onsetTolerance`, and
    /// not an octave, twelfth or double octave above a primary note sounding
    /// at that moment (Basic Pitch's harmonic ghosts). Transkun is precise but
    /// misses sustained, breathy or synthetic leads; Basic Pitch hears them.
    static func union(_ primary: [NoteEvent], adding reference: [NoteEvent], onsetTolerance: Double = 0.05,
                      minReferenceDuration: Double = 0) -> [NoteEvent] {
        guard !reference.isEmpty else { return primary }
        let sorted = primary.sorted { $0.startTime < $1.startTime }
        var byPitch: [Int: [Double]] = [:]
        for n in sorted { byPitch[n.pitch, default: []].append(n.startTime) }
        func hasOnset(_ pitch: Int, near t: Double) -> Bool {
            guard let starts = byPitch[pitch] else { return false }
            var lo = 0, hi = starts.count
            while lo < hi { let m = (lo + hi) / 2; if starts[m] < t - onsetTolerance { lo = m + 1 } else { hi = m } }
            return lo < starts.count && starts[lo] <= t + onsetTolerance
        }
        // Primary notes sounding at time t (sweep over sorted starts; notes are short, so scan back a few seconds).
        func sounding(at t: Double) -> [NoteEvent] {
            var lo = 0, hi = sorted.count
            while lo < hi { let m = (lo + hi) / 2; if sorted[m].startTime <= t + onsetTolerance { lo = m + 1 } else { hi = m } }
            var out: [NoteEvent] = []
            var i = lo - 1
            while i >= 0, sorted[i].startTime > t - 8 {
                if sorted[i].endTime > t - onsetTolerance { out.append(sorted[i]) }
                i -= 1
            }
            return out
        }
        // Reference onsets by pitch, to tell a confirmed primary note from a
        // primary octave error.
        var refByPitch: [Int: [Double]] = [:]
        for r in reference { refByPitch[r.pitch, default: []].append(r.startTime) }
        for k in refByPitch.keys { refByPitch[k]!.sort() }
        func confirmed(_ n: NoteEvent) -> Bool {
            guard let starts = refByPitch[n.pitch] else { return false }
            var lo = 0, hi = starts.count
            while lo < hi { let m = (lo + hi) / 2; if starts[m] < n.startTime - onsetTolerance { lo = m + 1 } else { hi = m } }
            return lo < starts.count && starts[lo] <= n.startTime + onsetTolerance
        }
        var added: [NoteEvent] = []
        var dropped = Set<NoteEvent>()
        for r in reference where r.endTime - r.startTime >= minReferenceDuration {
            if hasOnset(r.pitch, near: r.startTime) { continue }
            let under = sounding(at: r.startTime).filter { [12, 19, 24].contains(r.pitch - $0.pitch) }
            if !under.isEmpty {
                // Basic Pitch's own octave-leak check already removed its
                // harmonic ghosts, so a note over a lower one both engines
                // heard is a doubling (a melody over its chord). Over a lower
                // note only the primary engine heard, at the same onset, the
                // primary engine put this onset an octave (or two) low: keep
                // the reference's octave instead.
                let wrong = under.filter {
                    !confirmed($0) && abs($0.startTime - r.startTime) <= onsetTolerance && (r.pitch - $0.pitch) % 12 == 0
                }
                dropped.formUnion(wrong)
            }
            added.append(r)
        }
        let kept = dropped.isEmpty ? primary : primary.filter { !dropped.contains($0) }
        return (kept + added).sorted { ($0.startTime, $0.pitch) < ($1.startTime, $1.pitch) }
    }
}

nonisolated extension NoteFusion {
    /// Keeps `split`'s chords and bass, replaces its lines with the reference
    /// split's melody and countermelody, and drops notes that duplicate a line
    /// note (same pitch, onset within `onsetTolerance`); a line note that
    /// duplicates one takes its onset, as this engine (Transkun) times an
    /// attack more precisely than the reference (Basic Pitch). The split's own
    /// melody notes leave where the reference has a line note an octave or
    /// two away at the same onset (this engine put the lead in the wrong
    /// octave); the rest are notes this engine heard that the reference's
    /// line passes over (the top of the band under or over the voice) and
    /// stay, as chords, like the split's own countermelody notes.
    static func melodyFromReference(_ split: [NoteEvent], reference: [NoteEvent],
                                    onsetTolerance: Double = 0.05) -> [NoteEvent] {
        let lines = reference.filter { $0.voice == .melody || $0.voice == .countermelody }
        guard !lines.isEmpty else { return split }
        var starts: [Int: [Double]] = [:]
        for m in lines { starts[m.pitch, default: []].append(m.startTime) }
        func lineStarts(_ pitch: Int, near t: Double) -> Bool {
            starts[pitch]?.contains { abs($0 - t) <= onsetTolerance } ?? false
        }
        let rest: [NoteEvent] = split.compactMap { n in
            guard !lineStarts(n.pitch, near: n.startTime) else { return nil }
            switch n.voice {
            case .melody:
                let octaveOff = [-24, -12, 12, 24].contains { lineStarts(n.pitch + $0, near: n.startTime) }
                return octaveOff ? nil : n.with(voice: .chords)
            case .countermelody: return n.with(voice: .chords)
            default: return n
            }
        }
        var splitStarts: [Int: [Double]] = [:]
        for n in split { splitStarts[n.pitch, default: []].append(n.startTime) }
        let timed: [NoteEvent] = lines.map { m in
            guard let onset = splitStarts[m.pitch]?.filter({ abs($0 - m.startTime) <= onsetTolerance })
                    .min(by: { abs($0 - m.startTime) < abs($1 - m.startTime) }),
                  onset != m.startTime, onset < m.endTime else { return m }
            return NoteEvent(startTime: onset, endTime: m.endTime, pitch: m.pitch, amplitude: m.amplitude, voice: m.voice)
        }
        return (rest + timed).sorted { ($0.startTime, $0.pitch) < ($1.startTime, $1.pitch) }
    }
}
