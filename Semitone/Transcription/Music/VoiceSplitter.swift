import Foundation

/// Splits instrument-agnostic notes into the parts most arrangements have: a
/// bass line, a melody on top, and the chords in between, plus a
/// countermelody where a second line holds under the moving melody. No model:
/// the bass is the lowest sounding line, the melody the highest, each allowed
/// to rest, and everything else is accompaniment.
///
/// Works on onset clusters (notes starting within `clusterWindow` of each
/// other are one event), sweeping left to right so a note is judged against
/// everything already sounding when it starts, not just its onset-mates: a
/// chord struck under a held melody note stays in the chords.
nonisolated enum VoiceSplitter {
    struct Settings: Equatable {
        /// Notes starting this close together form one event (s).
        var clusterWindow = 0.035
        /// Highest pitch the bass may use (MIDI; 52 = E3).
        var bassCeiling = 52
        /// Lowest pitch the melody may use (MIDI; 57 = A3).
        var melodyFloor = 57
        /// A sounding note that ends within this long after an onset no longer
        /// blocks it (release tails overlapping the next note) (s).
        var releaseGrace = 0.08
        /// The melody must sit at least this far above the chord notes struck
        /// with it (semitones); a lone top note of a block chord doesn't count.
        var melodyGapOverChord = 3
        /// A chord of at least this many notes with nothing held above it only
        /// yields a melody note if the melody sang within `melodyMemory` seconds.
        var chordSizeForDoubt = 3
        var melodyMemory = 1.5
        /// A take is one line (a solo voice, horn, cello…) when at least
        /// `soloShare` of its onsets are single notes over nothing but release
        /// tails (`soloTail` s): then it's all melody, not split by register.
        /// Needs `soloMinOnsets` onsets, so a band take isn't judged on its first bars.
        var soloTail = 0.25
        var soloShare = 0.8
        var soloMinOnsets = 8
        /// Lone onsets alone don't make one line: an engine that hears a band
        /// only in fragments (a bass line, a riff, the tune and the bass in
        /// turn) writes them too, and a bass riff called melody is the worst
        /// split there is. So a take with a drum kit is never one line: the
        /// source profile's percussive share at the app's drum-heavy mark
        /// (`OnsetEnvelope.drumHeavyShare`) or more. A solo voice, horn, bowed
        /// string or bass guitar stays under it (General MIDI renders of the
        /// dev songs' single parts: 0.003-0.13). nil (no profile, as in the
        /// live preview) skips the test.
        var soloMaxPercussiveShare = OnsetEnvelope.drumHeavyShare
        /// The share measures attacks, not a kit: a pitched instrument with
        /// hard attacks reaches it alone (General MIDI solo lines: slap bass
        /// 0.22, steel drum 0.29, pizzicato strings 0.32, xylophone 0.74). So
        /// where the profile measured them, the kit must also play hits where
        /// no note starts: at least `soloMinHitsWithoutNotes` of the
        /// percussive part's attacks (`SourceProfile.hitsWithoutNotes`; those
        /// solo lines 0-6%, the dev songs with a kit 58-97%).
        var soloMinHitsWithoutNotes = 0.4
        /// ... nor is a take whose lone onsets leap more than `soloMaxLeap`
        /// semitones from the lone onset before (within `soloLeapWindow` s)
        /// more than `soloLeapShare` of the time. One player moves by step and
        /// small leap: the single parts of the RealBench bitmidi keys (sung
        /// and played melodies, bass lines, riffs) leap more than an octave on
        /// 0-2.4% of their onsets, and the engines' notes of their GM renders
        /// on 0-1.2%. A bass and a tune heard in turn jump between registers:
        /// 15-42% of the lone onsets of those songs' previews. Needs no
        /// profile, so it also guards the live preview.
        var soloMaxLeap = 12
        var soloLeapWindow = 1.0
        var soloLeapShare = 0.1
        /// A take that is one line is the melody, unless the line sits in the
        /// bass register (its median pitch at or below this, MIDI; 45 = A2,
        /// 110 Hz): then it is a bass line, and its notes up to `bassCeiling`
        /// are the bass (the few above, the melody). No voice or lead instrument centres that low (a bass
        /// singer's melody sits around D3, a cello's around G3), while a bass
        /// guitar's lines centre on A1-E2. A take whose transcription holds
        /// little but its bass (a hip-hop beat where the engine heard the bass
        /// and a few stabs) is such a line.
        var soloBassMedian = 45
        /// A melody note still ringing for longer than max(`heldLineMin` s,
        /// `heldLineShare` of its length) when the next melody note starts was
        /// held under the line, not sung: the top of a strummed or arpeggiated
        /// chord that rings on, a pad, an early ghost of the next note. It goes
        /// back to the chords, or may start a countermelody (`counterMinNotes`).
        /// A sung line lets go of a note as the next one comes (legato overlap
        /// and release tails stay under the limit).
        var heldLineMin = 0.15
        var heldLineShare = 0.5
        /// The melody is the take's most present line. Its level is the
        /// `levelPercentile` amplitude of its notes (once there are
        /// `levelMinNotes`); a melody note more than `weakBelowLevel` under it
        /// is the top of the accompaniment heard while the melody rests, and
        /// goes back to the chords. A take without a lead is not touched: its
        /// level is the accompaniment's own.
        var levelPercentile = 0.75
        var levelMinNotes = 8
        var weakBelowLevel = 0.15
        /// ... unless it moves at most `lineStep` semitones from a melody note
        /// at the level within `lineGap` seconds: a soft passing note inside a
        /// phrase.
        var lineGap = 0.5
        var lineStep = 4
        /// A countermelody: notes held under the moving melody (see
        /// `heldLineMin`) that were struck alone, not as the top of a chord,
        /// at the melody's level, one after another (each starting as the last
        /// ends, within `melodyMemory`): at least `counterMinNotes` of them,
        /// not all one pitch, make a second line sustained against the melody.
        /// Fewer, or weaker, are held chord tones.
        var counterMinNotes = 3
        /// How Song mode's refine pass picks the melody (`chooseLine`).
        var line = LineChoice()
    }

    /// The melody as a listener follows it, chosen among the notes of a split
    /// take (`chooseLine`). The sweep above calls the top note the melody,
    /// which is right for a lead over its accompaniment, but in a band a
    /// singer often sits under a pad, a guitar or a piano's right hand, and a
    /// man's verse goes well under `melodyFloor`. So the line is the path
    /// through the take's notes, one note at a time, that collects the most
    /// points. Each note is worth `base`, plus its level, plus a bonus when
    /// only this engine heard it and another when the sweep had it on a line,
    /// minus a cost for straying from the line's register and one for being
    /// struck inside a chord; each step costs the leap from the note before.
    /// A note must be worth its place, so the line rests where nothing is.
    ///
    /// Weights from the bitmidi dev songs (real band recordings, sung
    /// melodies: melody F1 up on every one, by 0.035 on average), checked on
    /// MusicBench's dev songs and the Ableton renders, whose instrumental
    /// leads sit high over the chords where the sweep's top line is right
    /// (+0.013 and -0.014 on average). Scored on the bitmidi songs alone, a
    /// fixed sung range (centre D4) with no `sweepBonus` did as well there but
    /// cost those leads 0.2-0.8.
    struct LineChoice: Equatable {
        /// Lowest melody pitch (MIDI; 48 = C3).
        var lowest = 48
        /// Points a note is worth on the line before its evidence.
        var base = 0.1
        /// Points per unit of amplitude above 0.5 (Basic Pitch's mean frame
        /// activation): the most present line is the melody.
        var levelWeight = 2.0
        /// Points for a note the other engine has nothing for (same pitch,
        /// onset within `unheardTolerance` s). Transkun learned the piano: it
        /// hears struck and plucked accompaniment and misses most of a voice,
        /// a horn or a bowed line, which Basic Pitch hears. On the bitmidi dev
        /// songs a preview note Transkun missed was 2.5 to 6 times as likely
        /// to be a note of the sung line as one it heard.
        var unheardBonus = 0.1
        var unheardTolerance = 0.05
        /// Points for a note the sweep put on a line (melody or
        /// countermelody): the top line is still the best single guess.
        var sweepBonus = 0.25
        /// Register prior: `registerWeight` x (distance from the line's
        /// register in octaves)², at most `registerWeight`. The register is
        /// the median pitch of the sweep's line notes less `registerBelowTop`
        /// semitones, since the sweep reaches up to the top of the band; with
        /// no line notes, `defaultRegister` (D4, between the middles of the
        /// usual male and female lead ranges).
        var registerWeight = 0.2
        var registerBelowTop = 2.0
        var defaultRegister = 62.0
        /// Points lost per other note starting with it (within
        /// `clusterWindow`, two at most): a sung note is rarely struck as part
        /// of a chord.
        var crowdPenalty = 0.1
        /// Continuity: a step from the previous line note started within
        /// `phraseGap` s costs `leapWeight` per octave beyond `freeStep`
        /// semitones. After a longer gap the line starts afresh.
        var leapWeight = 0.6
        var freeStep = 2
        var phraseGap = 1.5
    }

    /// `settleLine: false` stops after the note-by-note sweep and leaves the
    /// decisions that need the whole line (the melody's level, the
    /// countermelody) to `settleLine(_:settings:)`, for a take put together
    /// from two splits.
    /// `percussiveShare` and `hitsWithoutNotes` are the source profile's (nil
    /// when the take has none, as for the live preview); see
    /// `Settings.soloMaxPercussiveShare`.
    static func assign(_ notes: [NoteEvent], settings: Settings = Settings(), settleLine: Bool = true,
                       percussiveShare: Double? = nil, hitsWithoutNotes: Double? = nil) -> [NoteEvent] {
        guard !notes.isEmpty else { return [] }
        let sorted = notes.sorted { ($0.startTime, $0.pitch) < ($1.startTime, $1.pitch) }
        var voices = [Voice](repeating: .chords, count: sorted.count)

        // Onset clusters, as index ranges into `sorted`.
        var clusters: [Range<Int>] = []
        var lo = 0
        for i in 1...sorted.count {
            if i == sorted.count || sorted[i].startTime - sorted[lo].startTime > settings.clusterWindow {
                clusters.append(lo..<i)
                lo = i
            }
        }

        if isSoloLine(sorted, clusters: clusters, settings: settings, percussiveShare: percussiveShare,
                      hitsWithoutNotes: hitsWithoutNotes) {
            let pitches = sorted.map(\.pitch).sorted()
            guard pitches[pitches.count / 2] <= settings.soloBassMedian else { return sorted.map { $0.with(voice: .melody) } }
            return sorted.map { $0.with(voice: $0.pitch <= settings.bassCeiling ? .bass : .melody) }
        }

        // Notes sounding across an onset, found with a sweep: `active` holds
        // indices of notes started earlier, pruned as they end.
        var active: [Int] = []
        var lastMelodyEnd = -Double.infinity
        var lastMelody: Int?
        var struckAlone = Set<Int>()

        for cluster in clusters {
            let t = sorted[cluster.lowerBound].startTime
            active.removeAll { sorted[$0].endTime <= t + settings.releaseGrace }
            let held = active.filter { !cluster.contains($0) }

            // Bass: the cluster's lowest note, if nothing held lies below it.
            let lowest = cluster.min { sorted[$0].pitch < sorted[$1].pitch }!
            let lowestPitch = sorted[lowest].pitch
            let heldBelow = held.contains { sorted[$0].pitch < lowestPitch && voices[$0] != .melody }
            if lowestPitch <= settings.bassCeiling, !heldBelow {
                voices[lowest] = .bass
            }

            // Melody: the cluster's highest note, if it clears everything still
            // sounding (an earlier melody note included; release tails were
            // pruned above) and its own chord.
            let highest = cluster.max { sorted[$0].pitch < sorted[$1].pitch }!
            let top = sorted[highest]
            if top.pitch >= settings.melodyFloor, voices[highest] != .bass {
                let heldAbove = held.contains { sorted[$0].pitch >= top.pitch }
                let others = cluster.filter { $0 != highest && voices[$0] != .bass }.map { sorted[$0].pitch }
                let clearsChord = others.allSatisfy { top.pitch - $0 >= settings.melodyGapOverChord }
                let isBlockChord = others.count + 1 >= settings.chordSizeForDoubt
                let melodyRecent = t - lastMelodyEnd <= settings.melodyMemory
                if !heldAbove, clearsChord || !isBlockChord || melodyRecent {
                    if let previous = lastMelody, voices[previous] == .melody {
                        let note = sorted[previous]
                        let left = note.endTime - t
                        if left > max(settings.heldLineMin, settings.heldLineShare * (note.endTime - note.startTime)) {
                            // Held under the line. Struck alone, it may be a
                            // second line (settled with the whole line).
                            voices[previous] = struckAlone.contains(previous) ? .countermelody : .chords
                        }
                    }
                    voices[highest] = .melody
                    lastMelodyEnd = max(lastMelodyEnd, top.endTime)
                    lastMelody = highest
                    if others.isEmpty { struckAlone.insert(highest) }
                }
            }
            active.append(contentsOf: cluster)
        }

        if settleLine { settle(sorted, &voices, settings: settings) }
        return zip(sorted, voices).map { $0.with(voice: $1) }
    }

    /// The decisions that need the whole line, on a take already split
    /// (`assign(_:settings:settleLine: false)`, possibly merged from two
    /// splits): melody notes well under the melody's level go back to the
    /// chords, and countermelody notes that don't make a line join them.
    static func settleLine(_ notes: [NoteEvent], settings: Settings = Settings()) -> [NoteEvent] {
        let sorted = notes.sorted { ($0.startTime, $0.pitch) < ($1.startTime, $1.pitch) }
        var voices = sorted.map(\.voice)
        settle(sorted, &voices, settings: settings)
        return zip(sorted, voices).map { $0.with(voice: $1) }
    }

    /// Song mode's line (see `LineChoice`), on a take split by `assign`
    /// (settled or not): the chosen notes become the melody; the notes the
    /// sweep had on a line and the choice passed over become countermelody,
    /// for `settleLine` to keep as a second line or return to the chords.
    /// Bass notes stay. `otherEngine` holds the notes a second engine heard
    /// in the same take (see `LineChoice.unheardBonus`). A solo line (all
    /// melody) is returned as it is.
    static func chooseLine(_ notes: [NoteEvent], otherEngine: [NoteEvent], settings: Settings = Settings()) -> [NoteEvent] {
        let sorted = notes.sorted { ($0.startTime, $0.pitch) < ($1.startTime, $1.pitch) }
        guard sorted.contains(where: { $0.voice != .melody }) else { return sorted }
        let line = settings.line
        let starts = sorted.map(\.startTime)
        func firstIndex(atOrAfter t: Double, in xs: [Double]) -> Int {
            var lo = 0, hi = xs.count
            while lo < hi { let m = (lo + hi) / 2; if xs[m] < t { lo = m + 1 } else { hi = m } }
            return lo
        }
        var heard: [Int: [Double]] = [:]
        for n in otherEngine { heard[n.pitch, default: []].append(n.startTime) }
        for k in heard.keys { heard[k]!.sort() }
        func otherHeard(_ n: NoteEvent) -> Bool {
            guard let xs = heard[n.pitch] else { return false }
            let i = firstIndex(atOrAfter: n.startTime - line.unheardTolerance, in: xs)
            return i < xs.count && xs[i] <= n.startTime + line.unheardTolerance
        }

        let candidates = sorted.indices.filter { sorted[$0].voice != .bass && sorted[$0].pitch >= line.lowest }
        guard !candidates.isEmpty else { return sorted }
        let swept = sorted.filter { $0.voice == .melody || $0.voice == .countermelody }.map(\.pitch).sorted()
        let register = swept.isEmpty ? line.defaultRegister
            : Double(swept[(swept.count - 1) / 2] + swept[swept.count / 2]) / 2 - line.registerBelowTop
        let worth: [Double] = candidates.map { i in
            let n = sorted[i]
            let crowd = firstIndex(atOrAfter: n.startTime + settings.clusterWindow + 1e-9, in: starts)
                - firstIndex(atOrAfter: n.startTime - settings.clusterWindow, in: starts) - 1
            let octaves = (Double(n.pitch) - register) / 12
            let onLine = n.voice == .melody || n.voice == .countermelody
            return line.base + line.levelWeight * (n.amplitude - 0.5)
                + (otherHeard(n) ? 0 : line.unheardBonus)
                + (onLine ? line.sweepBonus : 0)
                - line.registerWeight * min(1, octaves * octaves)
                - line.crowdPenalty * Double(min(crowd, 2))
        }

        // Best line ending on each candidate: its worth plus the best line
        // before it, less the step. Lines that ended more than `phraseGap`
        // before it join for free (`farBest`); an empty line is worth 0.
        let count = candidates.count
        var best = [Double](repeating: 0, count: count)
        var back = [Int](repeating: -1, count: count)
        var farBest = 0.0, farIndex = -1, far = 0
        for i in 0..<count {
            let t = sorted[candidates[i]].startTime
            let pitch = sorted[candidates[i]].pitch
            while far < i, sorted[candidates[far]].startTime < t - line.phraseGap {
                if best[far] > farBest { (farBest, farIndex) = (best[far], far) }
                far += 1
            }
            var value = farBest, from = farIndex
            var j = i - 1
            while j >= far {
                if sorted[candidates[j]].startTime <= t - settings.clusterWindow {
                    let step = abs(pitch - sorted[candidates[j]].pitch)
                    let cost = step > line.freeStep ? line.leapWeight * Double(step - line.freeStep) / 12 : 0
                    if best[j] - cost > value { (value, from) = (best[j] - cost, j) }
                }
                j -= 1
            }
            best[i] = worth[i] + value
            back[i] = from
        }
        var voices = sorted.map { $0.voice == .melody ? Voice.countermelody : $0.voice }
        guard var i = best.indices.max(by: { best[$0] < best[$1] }), best[i] > 0 else {
            return zip(sorted, voices).map { $0.with(voice: $1) }
        }
        while i >= 0 {
            voices[candidates[i]] = .melody
            i = back[i]
        }
        return zip(sorted, voices).map { $0.with(voice: $1) }
    }

    /// Returns the melody notes well under the melody's level to the chords,
    /// except soft notes inside a phrase (see `Settings.weakBelowLevel`), then
    /// settles the countermelody. A take that is nothing but melody (a solo
    /// line) keeps every note.
    private static func settle(_ sorted: [NoteEvent], _ voices: inout [Voice], settings: Settings) {
        guard voices.contains(where: { $0 != .melody }) else { return }
        let melody = voices.indices.filter { voices[$0] == .melody }
        var floor = -Double.infinity
        if melody.count >= settings.levelMinNotes {
            let levels = melody.map { sorted[$0].amplitude }.sorted()
            let level = levels[min(levels.count - 1, Int(settings.levelPercentile * Double(levels.count)))]
            floor = level - settings.weakBelowLevel
            dropWeakMelody(sorted, &voices, melody: melody, floor: floor, settings: settings)
        }
        settleCountermelody(sorted, &voices, floor: floor, settings: settings)
    }

    private static func dropWeakMelody(_ sorted: [NoteEvent], _ voices: inout [Voice], melody: [Int],
                                       floor: Double, settings: Settings) {
        // Indices ascend with start time, so `strong` is in time order.
        let strong = melody.filter { sorted[$0].amplitude >= floor }
        for i in melody where sorted[i].amplitude < floor {
            let note = sorted[i]
            // The strong notes just before and after this one.
            var lo = 0, hi = strong.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if sorted[strong[mid]].startTime < note.startTime { lo = mid + 1 } else { hi = mid }
            }
            let inLine = [lo - 1, lo].contains { k in
                guard strong.indices.contains(k) else { return false }
                let neighbour = sorted[strong[k]]
                return abs(neighbour.startTime - note.startTime) <= settings.lineGap
                    && abs(neighbour.pitch - note.pitch) <= settings.lineStep
            }
            if !inLine { voices[i] = .chords }
        }
    }

    /// Keeps the countermelody notes that make a line at the melody's level
    /// (see `Settings.counterMinNotes`); the rest go to the chords.
    private static func settleCountermelody(_ sorted: [NoteEvent], _ voices: inout [Voice], floor: Double,
                                            settings: Settings) {
        var chain: [Int] = []
        func close() {
            if chain.count < settings.counterMinNotes || Set(chain.map { sorted[$0].pitch }).count < 2 {
                for i in chain { voices[i] = .chords }
            }
            chain = []
        }
        for i in voices.indices where voices[i] == .countermelody {
            guard sorted[i].amplitude >= floor else {
                voices[i] = .chords
                continue
            }
            if let last = chain.last {
                let gap = sorted[i].startTime - sorted[last].endTime
                if gap < -settings.releaseGrace || gap > settings.melodyMemory { close() }
            }
            chain.append(i)
        }
        close()
    }

    private static func isSoloLine(_ sorted: [NoteEvent], clusters: [Range<Int>], settings: Settings,
                                   percussiveShare: Double?, hitsWithoutNotes: Double?) -> Bool {
        guard clusters.count >= settings.soloMinOnsets else { return false }
        if let percussiveShare, percussiveShare >= settings.soloMaxPercussiveShare,
           (hitsWithoutNotes ?? 1) >= settings.soloMinHitsWithoutNotes { return false }
        var sounding: [Int] = []
        var lone = 0
        // Leaps between lone onsets (see `Settings.soloMaxLeap`).
        var previous: NoteEvent?
        var steps = 0, leaps = 0
        for cluster in clusters {
            let t = sorted[cluster.lowerBound].startTime
            sounding.removeAll { sorted[$0].endTime <= t + settings.releaseGrace }
            if cluster.count == 1, sounding.allSatisfy({ sorted[$0].endTime <= t + settings.soloTail }) {
                lone += 1
                let note = sorted[cluster.lowerBound]
                if let previous, t - previous.startTime <= settings.soloLeapWindow {
                    steps += 1
                    if abs(note.pitch - previous.pitch) > settings.soloMaxLeap { leaps += 1 }
                }
                previous = note
            }
            sounding.append(contentsOf: cluster)
        }
        guard Double(lone) >= settings.soloShare * Double(clusters.count) else { return false }
        return Double(leaps) <= settings.soloLeapShare * Double(steps)
    }
}
