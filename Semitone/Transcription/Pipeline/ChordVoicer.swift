import Foundation

/// How a take's chords part is shown, played and exported. Chosen per take
/// (saved with it, see `SavedTakeContent.chordStyle`); new takes start as played.
nonisolated enum ChordStyle: String, CaseIterable, Hashable {
    /// The transcribed chord notes.
    case asPlayed
    /// Plain voicings built from the chord names (`ChordVoicer`).
    case simplified

    var label: String {
        switch self {
        case .asPlayed: "As played"
        case .simplified: "Simplified"
        }
    }
}

/// Stage 8: the chords part rebuilt from the chord names. The names come
/// first (stage 7, `HarmonyStage`, or `ChordAnalyzer` on a take too short for
/// a beat grid); each name then becomes a plain close-position voicing,
/// struck once where the chord starts and held to the next chord change
/// (0.79: simple and clean, as the owner asked; `restrike` brings back a
/// strike wherever the comping struck). Transcribed chord
/// shapes carry the engines' misses, doublings and stray tones; this swaps
/// them for the shape the name stands for, struck when the song's comping
/// strikes. How long each strike lasts is not kept: it is held on
/// (`restGap`), so the voicings also sound where the comping had stopped.
/// Against the bench keys both the holding and the fuller shapes cost
/// pitch-class precision: holding about two fifths of the loss on
/// MusicBench dev, and a third to a half on the Ableton dev songs depending
/// on how it is counted (the frames where only a voicing sounds, or what
/// ending each strike with its notes gives back); the shapes the rest.
///
/// - Rhythm: the chords part's onsets are grouped into strikes (a strum or a
///   rolled chord is one), and the voicing is struck at each strike inside a
///   segment, held to the next strike or the segment's end. A strike just
///   before a chord's start that fits that chord (some of its notes are its
///   tones) at least as well as the one before belongs to it (a pushed
///   chord), keeping its time, and so does every strike after it up to the
///   change. Where the chords part still rings from the chord before, the
///   segment is struck at its start too, and with no strikes of its own it
///   gets a block there, re-struck on each bar line inside it. Where the
///   chords part is silent, it stays silent (`fillEmptySegments`); where it
///   still sounds past a chord's end and no voiced strike comes there (the
///   next chord keeps its notes as played, names no chord, or waits for its
///   first strike), the voicing rings on while the chord notes it and the
///   voicings before it replaced still sound, so it does not fall silent
///   where they sounded.
/// - Voicing: close position, three notes (four for the 7th and 6th chords),
///   chord tones only: a slash chord's bass note is the bass part's job. It is
///   centred on the median pitch of the notes it replaces; the inversion that
///   moves least from the previous voicing wins, within a few semitones of
///   that centre so the register cannot drift.
/// - Velocity: each strike takes the median amplitude of the notes it
///   replaces.
/// - Only where the name fits what was heard: a segment whose chords-part
///   notes mostly lie outside the chord's tones keeps its notes, when they
///   are long enough to judge it by (`minFitEvidence`), and so does a
///   segment whose label names no chord.
/// - Only the chords part changes: melody, countermelody and bass notes come
///   back untouched and in their order; the voiced notes follow them. A take
///   with no chords part comes back unchanged.
///
/// Costs a sort and a few sweeps over the chords part (no per-segment scans),
/// so it can re-run with every beat setting change.
nonisolated enum ChordVoicer {
    struct Settings: Equatable {
        /// Chords-part onsets within this many seconds of a strike's first
        /// onset belong to that strike: a strum or a rolled chord. The strike
        /// sounds at its first onset.
        var strumWindow = 0.06
        /// A strike up to this many seconds before a chord's start can belong
        /// to that chord (anticipated by up to a 16th at 125 BPM), when some
        /// of its notes fit it, at least as many as fit the chord before.
        var pushWindow = 0.12
        /// Below this share of a segment's chords-part note-time on chord
        /// tones (and the slash bass), the name does not fit what was heard
        /// and the segment keeps its transcribed notes. Note-time is each
        /// note's length within the segment; half means "mostly". A stricter
        /// 0.8 matched the keys better on the dev songs (pitch-class F1
        /// +0.030 on MusicBench, +0.022 on Ableton) only by leaving more
        /// chords as played (14 of 138; 36 of 158 on the Ableton songs).
        var minFit = 0.5
        /// The fit test needs this much evidence: the segment's own
        /// chords-part note-time (summed over its notes, so a triad weighs
        /// three times a single line) at least this share of the segment's
        /// length, else the name, which all the take's notes chose, stands
        /// and the segment is voiced. It weighs length, not strikes: a stray
        /// note or a short stab is too little, and so is a chord the part
        /// only touches in short notes, however many strikes disagree with
        /// the name. On the bench it voices 31 chords the fit test alone
        /// would keep. 19 of them have 2 to 7 strikes, though 14 of those
        /// nearly fit (40% or more of their note-time on the chord's tones),
        /// and 21 of the 31 are on the jazz quintet and the string quartet,
        /// whose keys have no chords part to score them against. Counting
        /// two strikes as enough instead judged a 10.8 s chord on three
        /// 0.1 s notes and scored lower on the Ableton dev songs
        /// (pitch-class F1 0.577 against 0.580). The value rests on few
        /// chords: on the Ableton dev songs 0.5 left 1 chord as played
        /// instead of 5 and took F1 from 0.573 to 0.580 (0.25: 0.580; 1,
        /// keeping none: 0.579), and MusicBench dev keeps none either way.
        /// 0: any note can overrule the name.
        var minFitEvidence = 0.5
        /// Voicings are centred within this register (MIDI E3...C5): close
        /// triads below it turn muddy, above it they crowd the melody. A
        /// segment without notes of its own takes the previous voicing's
        /// centre, else the whole chords part's median.
        var lowestCentre = 52.0
        var highestCentre = 72.0
        /// How far (semitones) a voicing's mean pitch may sit from its centre
        /// so that it can move less from the voicing before.
        var registerSlack = 4.0
        /// A strike with no notes to replace (a block): velocity 80 under the
        /// activation dynamics split takes play and export with
        /// (0.45 × 95 + 38).
        var defaultAmplitude = 0.45
        /// Whether a segment where the chords part neither strikes nor rings
        /// gets blocks anyway (the name says a chord sounds there). Off: the
        /// names also come from the melody and bass, so this adds chords the
        /// song does not play there. On the Ableton dev songs filling raised
        /// the chords part's pitch-class recall against the key from 0.488 to
        /// 0.520 but cut its precision from 0.715 to 0.597 (MusicBench dev:
        /// F1 0.745 to 0.743).
        var fillEmptySegments = false
        /// Strikes shorter than this (seconds) are dropped and the strike
        /// before them in the segment rings on.
        var shortestStrike = 0.05
        /// A strike needs this many onsets together to restrike the voicing.
        /// Fewer (a lone note: an arpeggio, or a melody or bass note the
        /// split left in the chords part) are replaced but strike nothing,
        /// except to start the block when they come first. 1: every strike
        /// counts. With 2, the share of the key's chord strikes matched fell
        /// from 0.460 to 0.230 on the Ableton dev songs, whose transcribed
        /// chords often survive as one note.
        var minStrikeNotes = 1
        /// A strike whose notes (and the lone notes after it) all stop more
        /// than this many seconds before the next strike or the segment's
        /// end stops with them, keeping the rest; otherwise it rings on.
        /// Infinite: the engines cut held chords short, and 0.25 s cost the
        /// Ableton dev songs 0.12 pitch-class recall for 0.08 precision
        /// (F1 0.580 to 0.506).
        var restGap = Double.infinity
        /// Whether a chord is struck again inside its segment, wherever the
        /// chords part struck (and on each bar line of a block). Off (0.79):
        /// each chord is struck once, at its first strike, and held to the
        /// next chord change, at the median loudness of the notes it
        /// replaces, so Simplified plays one plain chord per chord name.
        var restrike = false
        /// 7th and 6th chords leave out their perfect fifth (three notes).
        /// Off: it fit MusicBench's generated comping (F1 +0.017) but not the
        /// Ableton songs' full chords (-0.023).
        var shellVoicings = false
    }

    /// The voiced take and what happened to its chord segments.
    struct Result: Equatable {
        /// Every note it keeps (the other parts, and chord notes left as
        /// played) unchanged and in order, then the voicings.
        var notes: [NoteEvent]
        /// Segments written as voicings.
        var voiced = 0
        /// Of those, segments without strikes of their own (blocks only).
        var blocks = 0
        /// Segments that kept their notes: the name does not fit them.
        var misfits = 0
        /// Segments that kept their notes: the label names no chord.
        var unnamed = 0
    }

    static func voice(notes: [NoteEvent], chords: [ChordSegment], grid: BeatGrid,
                      settings: Settings = Settings()) -> Result {
        let part = notes.indices.filter {
            notes[$0].voice == .chords && notes[$0].startTime.isFinite && notes[$0].endTime.isFinite
        }
        let segments = chords.filter { $0.startTime.isFinite && $0.endTime.isFinite && $0.endTime > $0.startTime }
            .sorted { $0.startTime < $1.startTime }
        guard !part.isEmpty, !segments.isEmpty else { return Result(notes: notes) }
        let symbols = segments.map { ChordSymbol($0.label) }

        // Strikes: onsets within `strumWindow` of a strike's first onset.
        let byStart = part.sorted { notes[$0].startTime < notes[$1].startTime }
        var strikes: [[Int]] = []
        for i in byStart {
            if let first = strikes.last?.first, notes[i].startTime - notes[first].startTime <= settings.strumWindow {
                strikes[strikes.count - 1].append(i)
            } else {
                strikes.append([i])
            }
        }
        func time(_ strike: [Int]) -> Double { notes[strike[0]].startTime }
        /// Share of a strike's notes on the chord's tones or bass.
        func share(_ strike: [Int], _ symbol: ChordSymbol?) -> Double {
            guard let symbol else { return -1 }
            let mask = symbol.toneMask | 1 << symbol.bass
            return Double(strike.filter { mask & 1 << pitchClass(notes[$0].pitch) != 0 }.count) / Double(strike.count)
        }

        // Each strike to the segment it sounds in, or to the next one when
        // it pushes that chord: some of its notes fit that chord, at least as
        // many as fit the one before (a stray note that fits neither pushes
        // nothing). Once a strike pushes a chord, the strikes after it up to
        // the change go with it: judged one by one, a later strike could take
        // the chord before back, and the two would alternate.
        var owned = [[Int]](repeating: [], count: segments.count)   // strike indices
        var s = 0
        var pushed: Int?
        for (k, strike) in strikes.enumerated() {
            let t = time(strike)
            while s < segments.count, segments[s].endTime <= t { s += 1 }
            let inside = s < segments.count && segments[s].startTime <= t ? s : nil
            let next = (inside ?? s - 1) + 1
            var owner = inside
            if next < segments.count, segments[next].startTime > t, segments[next].startTime - t <= settings.pushWindow {
                let fit = share(strike, symbols[next])
                if pushed == next || fit > 0 && (inside == nil || fit >= share(strike, symbols[inside!])) {
                    owner = next
                    pushed = next
                }
            }
            if let owner { owned[owner].append(k) }
        }

        // The latest end among chords-part notes struck before each time,
        // to tell whether the part still rings at a segment's start.
        let starts = byStart.map { notes[$0].startTime }
        var ringsUntil: [Double] = []
        for i in byStart { ringsUntil.append(max(ringsUntil.last ?? -.infinity, notes[i].endTime)) }
        func ringing(at t: Double) -> Bool {
            var lo = 0, hi = starts.count   // first onset at or after t
            while lo < hi { let mid = (lo + hi) / 2; if starts[mid] < t { lo = mid + 1 } else { hi = mid } }
            return lo > 0 && ringsUntil[lo - 1] > t + settings.strumWindow
        }

        func median(_ values: [Double]) -> Double? {
            guard !values.isEmpty else { return nil }
            let v = values.sorted(), m = v.count / 2
            return v.count % 2 == 1 ? v[m] : (v[m - 1] + v[m]) / 2
        }
        func clampCentre(_ c: Double) -> Double { min(max(c, settings.lowestCentre), settings.highestCentre) }
        let partCentre = median(part.map { Double(notes[$0].pitch) })
            ?? (settings.lowestCentre + settings.highestCentre) / 2
        let downbeats = grid.downbeats.filter(\.isFinite).sorted()

        var result = Result(notes: [])
        var replaced = Set<Int>()
        /// `heard`: the segment's notes, for the rest rule; empty for a block,
        /// which always rings on.
        var plan: [(time: Double, segment: Int, pitches: [Int], amplitude: Double, heard: [(Double, Double)])] = []
        var previous: (pitches: [Int], centre: Double)?
        /// Per segment, the latest end among the notes replaced up to it: how
        /// long the part it voices rang as played.
        var replacedRing = [Double](repeating: -.infinity, count: segments.count)
        var latestReplaced = -Double.infinity
        for (j, segment) in segments.enumerated() {
            guard let symbol = symbols[j] else {
                result.unnamed += 1
                continue
            }
            let own = owned[j].map { strikes[$0] }
            let members = own.flatMap { $0 }
            if !members.isEmpty {
                var on = 0.0, total = 0.0
                let mask = symbol.toneMask | 1 << symbol.bass
                for i in members {
                    let w = max(min(notes[i].endTime, segment.endTime) - notes[i].startTime, 0.01)
                    total += w
                    if mask & 1 << pitchClass(notes[i].pitch) != 0 { on += w }
                }
                if total >= settings.minFitEvidence * (segment.endTime - segment.startTime), on / total < settings.minFit {
                    result.misfits += 1
                    continue
                }
            }

            var times = own.filter { $0.count >= settings.minStrikeNotes }.map(time)
            // Where the chords part already sounds before the first strike:
            // still ringing from the chord before, or lone notes first.
            var lead: Double?
            var holds = Set<Double>()
            if ringing(at: segment.startTime) {
                lead = segment.startTime
                holds.insert(segment.startTime)
            } else if let first = own.first.map(time), first < (times.first ?? .infinity) - settings.strumWindow {
                lead = first
            }
            if times.isEmpty {
                guard let start = lead ?? (settings.fillEmptySegments ? segment.startTime : nil) else { continue }
                // A block at the start, re-struck on each bar line inside,
                // up to the next chord's first strike (it may come early).
                let pushedAt = j + 1 < segments.count ? owned[j + 1].first.map { time(strikes[$0]) } : nil
                let stop = min(segment.endTime, pushedAt ?? .infinity)
                times = [start] + downbeats.filter {
                    $0 > start + settings.strumWindow && $0 < stop - settings.shortestStrike
                }
                holds.formUnion(times)
                result.blocks += 1
            } else if let lead, times[0] > lead + settings.strumWindow {
                times.insert(lead, at: 0)
            }
            // One strike per chord: its first, held to the change.
            if !settings.restrike, let first = times.first { times = [first] }

            let centre = clampCentre(median(members.map { Double(notes[$0].pitch) }) ?? previous?.centre ?? partCentre)
            let pitches = voicing(symbol, centre: centre, after: previous?.pitches, slack: settings.registerSlack,
                                  shell: settings.shellVoicings)
            previous = (pitches, centre)
            let fallbackAmplitude = median(members.map { notes[$0].amplitude }) ?? settings.defaultAmplitude
            let heard = members.map { (notes[$0].startTime, notes[$0].endTime) }
            for t in times {
                let strike = own.first { time($0) == t }
                let amplitude = settings.restrike
                    ? strike.flatMap { s in median(s.map { notes[$0].amplitude }) } ?? fallbackAmplitude
                    : fallbackAmplitude
                plan.append((t, j, pitches, amplitude, holds.contains(t) ? [] : heard))
            }
            replaced.formUnion(members)
            latestReplaced = members.reduce(latestReplaced) { max($0, notes[$1].endTime) }
            replacedRing[j] = latestReplaced
            result.voiced += 1
        }
        let kept = byStart.filter { !replaced.contains($0) }.map { notes[$0] }

        // Each strike rings to the next one or its segment's end, unless what
        // it replaces stopped well before (`restGap`). Where no voiced strike
        // follows at the change (the next chord keeps its notes as played,
        // names no chord, or waits for its first strike), the voicing rings
        // on past it while the replaced notes still sound, as they did as
        // played; a pitch of it that a note kept as played strikes after the
        // voicing's strike stops there (a kept note struck before it and still
        // held is not checked, so that pitch can sound twice). Too short a
        // strike is dropped; the one before it in its segment rings on.
        plan.sort { $0.time < $1.time }
        /// `ends`: each pitch's own end where one stops early, else empty.
        var spans: [(time: Double, end: Double, segment: Int, pitches: [Int], ends: [Double], amplitude: Double)] = []
        var keptCursor = 0
        for (k, strike) in plan.enumerated() {
            let segmentEnd = segments[strike.segment].endTime
            let next = k + 1 < plan.count ? plan[k + 1].time : .infinity
            var end = min(segmentEnd, next)
            var ends: [Double] = []
            if next > segmentEnd, replacedRing[strike.segment] > segmentEnd {
                end = min(replacedRing[strike.segment], next)
                while keptCursor < kept.count, kept[keptCursor].startTime <= strike.time { keptCursor += 1 }
                for note in kept[keptCursor...] {
                    if note.startTime >= end { break }
                    if note.endTime > segmentEnd, let v = strike.pitches.firstIndex(of: note.pitch) {
                        if ends.isEmpty { ends = strike.pitches.map { _ in end } }
                        ends[v] = min(ends[v], max(note.startTime, segmentEnd))
                    }
                }
                end = ends.max() ?? end
            }
            if settings.restGap.isFinite, !strike.heard.isEmpty {
                let stops = strike.heard.filter { $0.0 >= strike.time - settings.strumWindow && $0.0 < end }.map(\.1).max()
                if let stops, stops < end - settings.restGap {
                    end = max(stops, strike.time + settings.shortestStrike)
                    ends = ends.map { min($0, end) }
                }
            }
            if end - strike.time < settings.shortestStrike {
                if let last = spans.last, last.segment == strike.segment, abs(last.end - strike.time) < 1e-9 {
                    spans[spans.count - 1].end = end
                    spans[spans.count - 1].ends = last.ends.map { $0 == last.end ? end : $0 }
                }
                continue
            }
            spans.append((strike.time, end, strike.segment, strike.pitches, ends, strike.amplitude))
        }

        result.notes = notes.indices.filter { !replaced.contains($0) }.map { notes[$0] }
        for span in spans {
            for (v, pitch) in span.pitches.enumerated() {
                result.notes.append(NoteEvent(startTime: span.time, endTime: span.ends.isEmpty ? span.end : span.ends[v],
                                              pitch: pitch, amplitude: span.amplitude, voice: .chords))
            }
        }
        return result
    }

    /// The close-position voicing of `symbol` (chord tones only, root
    /// position or an inversion) whose mean pitch lies within `slack` of
    /// `centre` and moves least from `previous`; with no previous voicing, the
    /// one nearest the centre. Ties go to the one nearer the centre, then to
    /// the lower inversion.
    static func voicing(_ symbol: ChordSymbol, centre: Double, after previous: [Int]?, slack: Double,
                        shell: Bool = false) -> [Int] {
        var tones = symbol.tones
        if shell, tones.count == 4, let fifth = symbol.intervals.firstIndex(of: 7) { tones.remove(at: fifth) }
        var candidates: [(pitches: [Int], distance: Double, inversion: Int)] = []
        for k in tones.indices {
            // Stack the tones upward from the k-th, each the next one above.
            var shape = [0]
            for step in 1..<tones.count {
                let gap = ((tones[(k + step) % tones.count] - tones[(k + step - 1) % tones.count]) % 12 + 12) % 12
                shape.append(shape[step - 1] + (gap == 0 ? 12 : gap))
            }
            let mean = Double(shape.reduce(0, +)) / Double(shape.count)
            let octave = ((centre - mean - Double(tones[k])) / 12).rounded()
            for shift in -1...1 {
                let bottom = tones[k] + 12 * (Int(octave) + shift)
                let pitches = shape.map { bottom + $0 }
                guard pitches.allSatisfy({ (0...127).contains($0) }) else { continue }
                candidates.append((pitches, abs(Double(bottom) + mean - centre), k))
            }
        }
        let near = candidates.filter { $0.distance <= slack }
        let pool = near.isEmpty ? candidates : near
        let best = pool.min { a, b in
            if let previous {
                let ma = movement(a.pitches, previous), mb = movement(b.pitches, previous)
                if ma != mb { return ma < mb }
            }
            return (a.distance, a.inversion) < (b.distance, b.inversion)
        }
        return best?.pitches ?? []
    }

    private static func pitchClass(_ pitch: Int) -> Int { (pitch % 12 + 12) % 12 }

    /// Semitones moved from `old` to `new` (both sorted low to high): voice by
    /// voice when both have as many notes; otherwise each note to the nearest
    /// note of the other chord, both ways.
    static func movement(_ new: [Int], _ old: [Int]) -> Int {
        if new.count == old.count { return zip(new, old).reduce(0) { $0 + abs($1.0 - $1.1) } }
        func nearest(_ p: Int, _ chord: [Int]) -> Int { chord.map { abs($0 - p) }.min() ?? 0 }
        return new.reduce(0) { $0 + nearest($1, old) } + old.reduce(0) { $0 + nearest($1, new) }
    }
}
