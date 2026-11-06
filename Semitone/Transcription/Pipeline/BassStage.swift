import Foundation
import Accelerate

/// The bass part, checked against the audio. Runs after the voice split
/// (`PartAssigner`), so a note moved earlier cannot take the bass role from a
/// note it now shares an onset with (a kick drum read as a low G under the
/// bass guitar's E).
///
/// Both note engines put low notes late. On In The Rain's real Live export the
/// isolated sub and short basses reach half their peak level within 0-15 ms of
/// the key's onset, yet Basic Pitch and Transkun write them 60-110 ms later:
/// below about 60 Hz a model needs a few cycles of the fundamental (17-29 ms
/// each) before it commits. So each low note's onset (up to G2) is moved to
/// where the level at its own fundamental and first harmonics rises, measured
/// on the take itself (complex demodulation at each partial on a 2.76 kHz
/// copy: a few vDSP calls per note). Then the bass part is cleaned up: Basic
/// Pitch's late copies of notes Transkun wrote on time, re-onsets with no
/// attack of their own and kick drums read as low notes are removed.
///
/// Last, each bass note's octave is checked (`checkOctaves`). In most mixes a
/// bass note's second harmonic is louder than its fundamental, and where the
/// fundamental is weaker still (the lowest notes, under about 55 Hz, on a
/// recording light in sub-bass) both engines write the note an octave high:
/// on Toto's "Africa" the bass line's G#1 and F#1 come out as G#2 and F#2
/// while its A1 and B1 are right. The other way round, a bass note and a
/// chord's fifth above it make the harmonic series of the note an octave
/// down (2f, 3f, 4f of it), and the engines, piano models, write that note,
/// which nothing plays: on John Denver's "Country Roads" the bass's A2 and
/// D3 come out as A1 and D2. One note's spectrum is a noisy witness (a kick,
/// the previous note's tail, another part), so the octave is decided per
/// phrase: from the same written pitch's notes around it.
nonisolated enum BassStage {
    struct Settings: Equatable {
        /// Notes at or below this pitch get their onset checked (MIDI; 43 =
        /// G2, 98 Hz). The lag is a low-frequency effect: above 100 Hz the
        /// cycles a model waits for take about `minShift`, and a note's
        /// partials meet the chord's (a strummed guitar's A2 under its E4)
        /// more often than they show a late onset. On the dev songs 43 and 52
        /// (E3) score alike.
        var maxPitch = 43
        /// The other parts' notes up to `maxPitch` lag the same way and get the
        /// same onset check and late-copy merge (`mergeWithin`), but no
        /// re-attack or kick check.
        var otherParts = true
        /// How far before the engine's onset the attack may lie (s): the
        /// engines' lag on the sub basses reaches 110 ms.
        var maxLead = 0.15
        /// ... and how far after it (s).
        var maxLag = 0.0
        /// Smaller corrections are left alone (s): where an engine already
        /// placed a note well (Transkun on a plucked bass), the level of its
        /// partials peaks 15-20 ms after the key's onset, at the middle of
        /// the instrument's attack, so the measurement is no better.
        var minShift = 0.025
        /// Partials measured per note (the fundamental and its harmonics),
        /// up to `maxPartialHz`. A sub bass is nearly a sine; a picked or
        /// synth bass carries most of its attack in the 2nd-4th harmonics.
        var partials = 4
        var maxPartialHz = 500.0
        /// Analysis window (s). Two to three cycles of the lowest bass notes:
        /// shorter windows cannot tell a note from its neighbours, longer ones
        /// smear the attack.
        var window = 0.06
        /// Hop between level measurements (s).
        var hop = 0.004
        /// The level must at least grow by this factor across the attack for
        /// it to count; a note that only swells (a held note under a new
        /// chord) keeps its onset.
        var minRise = 2.0
        /// Two notes of the same part and pitch starting this close together
        /// (after the correction) are one note (s). Where Transkun wrote a
        /// bass note on time, the fusion added Basic Pitch's late copy of it.
        var mergeWithin = 0.06
        /// A bass note that follows a note of the same pitch by less than
        /// `reattackGap` (s, end to start) must show an attack of its own: its
        /// partials rising at least `minReattack`-fold within `maxLead` before
        /// to `reattackLag` after its onset. Otherwise it is the same note
        /// still sounding and is merged into it. Transkun, a piano model,
        /// ends a sustained bass where a piano would have decayed and starts
        /// it again; Basic Pitch re-strikes notes that pump or swell. A string
        /// plucked again while it still rings may only rise 1.5-2-fold, so
        /// the bound is low: on the dev songs 1.5 merged 46 such notes against
        /// 3 real repeats (1.8 merged 74 against 7, and cost a fingered bass
        /// and a strummed guitar their repeated notes).
        var reattackGap = 0.6
        var minReattack = 1.5
        var reattackLag = 0.03
        /// A bass note whose sound is nearly all fundamental (at least
        /// `kickMinFundamentalShare` of its partials' level over its first
        /// 150 ms) and dies away within 150 ms (the level 150-300 ms after
        /// the onset under `kickMaxDecay` of the first 100 ms) is a kick
        /// drum's thump, which Basic Pitch reads as a low G or F#. Plucked
        /// and synth basses carry harmonics or ring on. On the dev songs
        /// these bounds drop 29 bass notes, none of them real; a share of 0.5
        /// would also drop a plucky GM synth bass with a kick under it.
        var kickMaxDecay = 0.3
        var kickMinFundamentalShare = 0.6
        /// ... unless its partials hold their level through its first 100 ms
        /// (the level 50-100 ms after the onset at least `gatedMinHold` of
        /// the first 50 ms) and then fall silent (150-300 ms after it, under
        /// `gatedMaxTail` of the first 100 ms): that is a gated staccato note,
        /// a sub or synth bass cut short, which the engine wrote as short as
        /// it sounds. A drum's thump decays from its first instant or rings
        /// on: the 15 kicks the check drops on the dev songs keep 0.10-0.20
        /// of their level 150-300 ms on, and a fast synthetic kick (40 ms
        /// decay) holds a third of it. Their engine notes last 0.14-0.6 s, so
        /// the notes' own length cannot tell them from a 120 ms bass note.
        var gatedMinHold = 0.85
        var gatedMaxTail = 0.05
        /// An earlier rise is the note's attack only if the note it starts is
        /// still sounding at the engine's onset: when the partials fall under
        /// `attackHold` of their level just after the rise and then rise
        /// `minRise`-fold again by the engine's onset (or within 60 ms after
        /// it), the first rise was another sound (a kick a sixteenth before
        /// the bass note, whose thump sits on the note's fundamental) and the
        /// note's own attack is the second, where the engine put it. On Rick
        /// Astley's "Never Gonna Give You Up" 160 of the synth bass's notes
        /// sat 120-160 ms early, on the kick; this puts 115 of them back on
        /// their own attack, and moves almost no note on the other dev songs.
        /// 0.3-0.7 score alike. A second rise of 1.5-1.75-fold instead of
        /// `minRise` also undoes corrections that were right.
        var attackHold = 0.5
        /// The octave check (`checkOctaves`). Each bass note is measured once,
        /// over its first 30-300 ms: the level at half its frequency (the
        /// fundamental of the note an octave down), at its own and at twice
        /// it, as dB.
        ///
        /// Down an octave when the level at half the frequency is at most
        /// `octaveMaxSpan` dB under the level at twice it, on the note itself
        /// and on average over the bass notes of the same written pitch
        /// within `octavePhrase` s. Half and twice the frequency are the lower
        /// note's fundamental and fourth harmonic, an octave either side of
        /// the written note: under a note written an octave high both are a
        /// bass tone's own partials (0-15 dB apart on the dev songs); under a
        /// note with nothing below it the first is the mix's rumble, 20-40 dB
        /// down. Measured against the written note's own level (the lower
        /// note's second harmonic, the loudest partial of most basses, by a
        /// margin that varies from mix to mix) the two kinds of note overlap
        /// more: on Africa and Bohemian Rhapsody the area under the ROC curve
        /// is 0.86 here against 0.70 and 0.60 there. 12-20 dB, and phrases of
        /// 4-15 s, score alike.
        var octaveCheck = true
        var octaveMaxSpan = 16.0
        var octavePhrase = 8.0
        /// ... only within the bass line's own register: the lower note may
        /// not fall under the `octaveFloorShare` lowest of the other bass
        /// notes within `octaveWindow` s. Bass lines keep near where they are
        /// (the dev songs' keys: mostly within 7 semitones of the line's
        /// median over 16 s), so the floor keeps a line's real high notes
        /// where they are. Needs `octaveMinNotes` such notes. At 10% Africa
        /// gets twice the corrections, but on Viva la Vida, whose low strings
        /// sit an octave over the bass, more of their notes move into the bass
        /// and become the chord stage's bass note, and its chord accuracy
        /// loses 2.4 points (15% the same); at 20-25% it loses 1.2.
        var octaveWindow = 30.0
        var octaveFloorShare = 0.2
        var octaveMinNotes = 8
        /// Up an octave when the level at twice the frequency is at least
        /// `octaveMinGap` dB over the level at the note's own, on average over
        /// the bass notes of the same written pitch within `octavePhrase` s,
        /// and the higher note stays under the `octaveCeilingShare` highest
        /// of the other bass notes within `octaveWindow` s. A real bass tone
        /// has some fundamental: nine in ten of the dev songs' bass notes
        /// written at the right pitch average less than 13 dB under their
        /// octave; Country Roads' notes written an octave low, 24 dB (median).
        /// 16-22 score alike; at 15 the lowest notes of a line on a mix light
        /// in sub-bass (Africa's F#1 and G#1) start to move up.
        var octaveMinGap = 20.0
        var octaveCeilingShare = 0.9
    }

    /// Sample rate the stage works at: 22050 / 8, ample for partials under 1 kHz.
    static let decimation = 8

    /// The low notes' onsets corrected, and the bass part's late duplicates,
    /// attackless re-onsets and kick drums removed.
    /// `audio` is the mixed take at `sampleRate` (the 22.05 kHz copy).
    static func refine(_ notes: [NoteEvent], audio: [Float], sampleRate: Double,
                       settings: Settings = Settings()) -> [NoteEvent] {
        guard notes.contains(where: { $0.voice == .bass }), audio.count > 4096 else { return notes }
        let low = lowBand(audio, factor: decimation)
        let rate = sampleRate / Double(decimation)
        let sorted = notes.sorted { ($0.startTime, $0.pitch) < ($1.startTime, $1.pitch) }
        var out: [NoteEvent] = []
        out.reserveCapacity(sorted.count)
        // Each part's latest note of each pitch, as an index into `out`.
        var latest: [Int: Int] = [:]
        for note in sorted {
            let isBass = note.voice == .bass
            guard isBass || (settings.otherParts && note.pitch <= settings.maxPitch) else { out.append(note); continue }
            let key = Int(note.voice.rawValue) * 128 + note.pitch
            var onset = note.startTime
            // A note of this part and pitch that started up to `maxLead` +
            // `window` before has its attack inside the search, and that is
            // usually the steepest rise there: a re-strike rises from the
            // ringing level. So first look for an attack of the note's own, at
            // least `mergeWithin` after that onset and `minReattack`-fold;
            // only without one is the note a late copy, moved onto the
            // previous attack and merged. Fast repeats (16ths at 150 BPM are
            // 100 ms apart) otherwise became one note.
            var restruck = false
            if note.pitch <= settings.maxPitch {
                var found = attack(of: note.pitch, in: low, rate: rate, from: note.startTime - settings.maxLead,
                                   to: note.startTime + settings.maxLag, settings: settings)
                if let i = latest[key], note.startTime - out[i].startTime < settings.maxLead + settings.window,
                   let own = steepestRise(of: note.pitch, in: low, rate: rate,
                                          from: max(note.startTime - settings.maxLead, out[i].startTime + settings.mergeWithin),
                                          to: note.startTime + settings.reattackLag, settings: settings, peakInside: true),
                   own.ratio >= settings.minReattack {
                    restruck = true
                    found = own.ratio >= settings.minRise && own.time <= note.startTime + settings.maxLag ? own.time : nil
                }
                if let found, note.startTime - found >= settings.minShift, found < note.endTime - 0.03,
                   startsNote(note.pitch, at: found, before: note.startTime, in: low, rate: rate, settings: settings) {
                    onset = found
                }
            }
            if isBass, isKick(note.pitch, at: onset, in: low, rate: rate, settings: settings) { continue }
            // A note whose attack is the previous same-pitch note's is a late
            // copy of it; a bass note with no attack at all is that note
            // continuing.
            if let i = latest[key], !restruck,
               onset - out[i].startTime <= settings.mergeWithin
                || (isBass && onset == note.startTime && out[i].endTime >= note.startTime - settings.reattackGap
                    && !hasAttack(note, in: low, rate: rate, settings: settings)) {
                let m = out[i]
                out[i] = NoteEvent(startTime: min(m.startTime, onset), endTime: max(m.endTime, note.endTime),
                                   pitch: m.pitch, amplitude: max(m.amplitude, note.amplitude), voice: m.voice)
                continue
            }
            // A note moved earlier ends the previous one of its pitch and part.
            if let i = latest[key], out[i].endTime > onset {
                let m = out[i]
                out[i] = NoteEvent(startTime: m.startTime, endTime: onset, pitch: m.pitch,
                                   amplitude: m.amplitude, voice: m.voice)
            }
            latest[key] = out.count
            out.append(onset == note.startTime ? note
                       : NoteEvent(startTime: onset, endTime: note.endTime, pitch: note.pitch,
                                   amplitude: note.amplitude, voice: note.voice))
        }
        if settings.octaveCheck { out = checkOctaves(out, in: low, rate: rate, settings: settings) }
        return out.sorted { ($0.startTime, $0.pitch) < ($1.startTime, $1.pitch) }
    }

    /// The bass notes the engines wrote in the wrong octave, moved (see
    /// `Settings.octaveCheck`). A moved note keeps the onset and length the
    /// engine wrote, so the beat grid sees the same events. The register
    /// floor and ceiling come from the bass part before any move, so one
    /// correction cannot shift them for the next.
    ///
    /// A note moved down stays in the take as a chord note at the pitch the
    /// engine heard: the audio cannot tell the bass's own second harmonic
    /// from another instrument doubling the bass an octave up (strings over
    /// Viva la Vida's bass, a riff), and the doubling note is real. A note
    /// moved up had nothing at its written pitch, so it only moves; a note
    /// already sounding at the new pitch from the same onset is that note, and
    /// the moved one takes its place.
    ///
    /// Known weakness: a line that jumps between two octaves of one pitch
    /// while its low note rings on (an upright bass's Bb1-Bb2 ostinato) has
    /// the low octave sounding under its high notes too, and those move
    /// down. The check does not ask whether the lower note starts with the
    /// written one; on the dev songs that question cost more corrections
    /// than it saved.
    static func checkOctaves(_ notes: [NoteEvent], in x: [Float], rate: Double, settings: Settings) -> [NoteEvent] {
        let bass = notes.filter { $0.voice == .bass }.sorted { $0.startTime < $1.startTime }
        guard bass.count > settings.octaveMinNotes else { return notes }
        let starts = bass.map(\.startTime)
        // First index with a start at or after t.
        func index(_ t: Double) -> Int {
            var lo = 0, hi = starts.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if starts[mid] < t { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }
        func dB(_ v: Float) -> Double { 20 * log10(Double(max(v, 1e-12))) }
        // Per note, one Hann window over its first 30-300 ms: the level (dB)
        // at half its frequency minus the level at twice it (`span`, nil when
        // half the frequency is under 27.5 Hz), and the level at twice its
        // frequency minus the level at its own (`gap`).
        var span = [Double?](repeating: nil, count: bass.count)
        var gap = [Double?](repeating: nil, count: bass.count)
        var two = settings
        two.partials = 2
        var four = settings
        four.partials = 4
        for (i, note) in bass.enumerated() {
            let from = note.startTime + 0.03
            let to = note.startTime + min(max(note.endTime - note.startTime, 0.12), 0.3)
            let first = Int((from * rate).rounded()), length = Int(((to - from) * rate).rounded())
            guard first >= 0, length >= 16, first + length <= x.count else { continue }
            func levels(_ pitch: Int, _ s: Settings) -> [Double] {
                partialLevels(of: pitch, in: x, rate: rate, first: first, length: length, window: length, hop: length,
                              settings: s).compactMap(\.first).map { dB($0) }
            }
            if note.pitch - 12 >= 21 {
                // The lower note's partials 1-4: half, own, 1.5 and twice the frequency.
                let l = levels(note.pitch - 12, four)
                if l.count == 4 { span[i] = l[0] - l[3]; gap[i] = l[3] - l[1] }
            } else {
                let l = levels(note.pitch, two)
                if l.count == 2 { gap[i] = l[1] - l[0] }
            }
        }
        // The mean of `values` over the bass notes of this one's pitch within `octavePhrase` s.
        func phrase(_ i: Int, _ values: [Double?]) -> Double? {
            let a = index(bass[i].startTime - settings.octavePhrase)
            let b = index(bass[i].startTime + settings.octavePhrase + 1e-9)
            let same = (a..<b).filter { bass[$0].pitch == bass[i].pitch }.compactMap { values[$0] }
            return same.isEmpty ? nil : same.reduce(0, +) / Double(same.count)
        }
        var lowered: [NoteEvent: NoteEvent] = [:]
        var raised: [NoteEvent: NoteEvent] = [:]
        for (i, note) in bass.enumerated() {
            let a = index(note.startTime - settings.octaveWindow), b = index(note.startTime + settings.octaveWindow + 1e-9)
            var others = bass[a..<b].filter { $0 != note }.map(\.pitch)
            guard others.count >= settings.octaveMinNotes else { continue }
            others.sort()
            func share(_ q: Double) -> Int { others[min(others.count - 1, Int(q * Double(others.count)))] }
            if let g = phrase(i, gap), g >= settings.octaveMinGap, note.pitch + 12 <= share(settings.octaveCeilingShare) {
                raised[note] = NoteEvent(startTime: note.startTime, endTime: note.endTime, pitch: note.pitch + 12,
                                         amplitude: note.amplitude, voice: .bass)
                continue
            }
            let lower = note.pitch - 12
            guard let own = span[i], own >= -settings.octaveMaxSpan, lower >= share(settings.octaveFloorShare),
                  let mean = phrase(i, span), mean >= -settings.octaveMaxSpan else { continue }
            // Already there: a note of that pitch sounding as this one starts.
            guard !notes.contains(where: { $0.pitch == lower && $0.startTime <= note.startTime + settings.mergeWithin
                                            && $0.endTime > note.startTime }) else { continue }
            lowered[note] = NoteEvent(startTime: note.startTime, endTime: note.endTime, pitch: lower,
                                      amplitude: note.amplitude, voice: .bass)
        }
        guard !lowered.isEmpty || !raised.isEmpty else { return notes }
        // Notes the raised ones replace: the same pitch from the same onset.
        let replaced = Set(notes.filter { n in
            n.voice != .bass && raised.values.contains { $0.pitch == n.pitch && abs($0.startTime - n.startTime) <= settings.mergeWithin }
        })
        return notes.filter { !replaced.contains($0) }.map { lowered[$0] ?? raised[$0] ?? $0 }
            + lowered.keys.map { $0.with(voice: .chords) }
    }

    /// Whether the rise at `attack` starts the note the engine wrote at
    /// `onset` (see `Settings.attackHold`): its partials hold up until then,
    /// or fall back without rising `minRise`-fold again by 60 ms after it.
    /// Unknown (too close to either end of the take) counts as yes.
    static func startsNote(_ pitch: Int, at attack: Double, before onset: Double, in x: [Float], rate: Double,
                           settings: Settings) -> Bool {
        let win = max(8, Int((settings.window * rate).rounded()))
        let hop = max(1, Int((settings.hop * rate).rounded()))
        let first = Int((attack * rate).rounded())
        let extra = Int((0.06 * rate).rounded())
        let length = Int(((onset - attack) * rate).rounded()) + win + extra
        guard first >= 0, first + length <= x.count, length > win + extra else { return true }
        let level = partialLevel(of: pitch, in: x, rate: rate, first: first, length: length, window: win, hop: hop,
                                 settings: settings)
        // level[k] is centred at attack + k * hop + win / 2: the first entry is
        // half a window after the rise; the first `upToOnset` reach the onset.
        let upToOnset = min(level.count, max(1, (length - win - extra) / hop + 1))
        guard let peak = level.prefix(max(1, Int(0.03 * rate) / hop)).max(),
              let dip = level.prefix(upToOnset).min(), let at = level.prefix(upToOnset).firstIndex(of: dip),
              dip < Float(settings.attackHold) * peak else { return true }
        return (level[at...].max() ?? dip) < Float(settings.minRise) * dip
    }

    /// Whether a low note starting at `onset` sounds like a kick drum (see
    /// `kickMaxDecay` and `gatedMinHold`). False when the take ends too soon
    /// to tell.
    static func isKick(_ pitch: Int, at onset: Double, in x: [Float], rate: Double, settings: Settings) -> Bool {
        let win = max(8, Int((settings.window * rate).rounded()))
        let hop = max(1, Int((settings.hop * rate).rounded()))
        let first = Int((onset * rate).rounded()) - win / 2
        let length = Int((0.3 * rate).rounded()) + win
        guard first >= 0, first + length < x.count else { return false }
        let partials = partialLevels(of: pitch, in: x, rate: rate, first: first, length: length,
                                     window: win, hop: hop, settings: settings)
        guard let fundamental = partials.first else { return false }
        var total = fundamental
        for p in partials.dropFirst() { vDSP_vadd(total, 1, p, 1, &total, 1, vDSP_Length(total.count)) }
        // Mean over entries centred between a and b seconds after the onset.
        func mean(_ v: [Float], _ a: Double, _ b: Double) -> Double {
            let i = Int((a * rate).rounded()) / hop, j = min(v.count, Int((b * rate).rounded()) / hop)
            guard j > i else { return 0 }
            var m: Float = 0
            v.withUnsafeBufferPointer { vDSP_meanv($0.baseAddress! + i, 1, &m, vDSP_Length(j - i)) }
            return Double(m)
        }
        let attack = mean(total, 0, 0.1)
        guard attack > 0 else { return false }
        let tail = mean(total, 0.15, 0.3)
        guard tail < settings.kickMaxDecay * attack,
              mean(fundamental, 0, 0.15) >= settings.kickMinFundamentalShare * mean(total, 0, 0.15) else { return false }
        let gated = tail < settings.gatedMaxTail * attack
            && mean(total, 0.05, 0.1) >= settings.gatedMinHold * mean(total, 0, 0.05)
        return !gated
    }

    /// Whether the note's partials rise `minReattack`-fold near its onset.
    /// Unknown (too close to either end of the take) counts as yes.
    static func hasAttack(_ note: NoteEvent, in x: [Float], rate: Double, settings: Settings) -> Bool {
        guard let rise = steepestRise(of: note.pitch, in: x, rate: rate, from: note.startTime - settings.maxLead,
                                      to: note.startTime + settings.reattackLag, settings: settings) else { return true }
        return rise.ratio >= settings.minReattack
    }

    /// Time (s) of the steepest rise of the note's partials, if it lies
    /// between `from` and `to` and the level grows by `minRise` across it.
    static func attack(of pitch: Int, in x: [Float], rate: Double, from: Double, to: Double,
                       settings: Settings) -> Double? {
        guard let rise = steepestRise(of: pitch, in: x, rate: rate, from: from, to: to, settings: settings),
              rise.time >= from - settings.hop / 2, rise.time <= to + settings.hop / 2,
              rise.ratio >= settings.minRise else { return nil }
        return rise.time
    }

    /// The steepest rise of the note's partial level near `from`...`to`: its
    /// time (s) and the ratio of the level half a window after it to the level
    /// half a window before. The search runs half a window past both ends, so
    /// a rise that peaks outside the span (the previous note's attack, or this
    /// one's when the engine was on time) is not taken for one at its edge.
    /// `peakInside` instead returns the steepest rise that peaks inside the
    /// span, however steep one outside it is (a re-strike after the previous
    /// note's attack).
    static func steepestRise(of pitch: Int, in x: [Float], rate: Double, from: Double, to: Double,
                             settings: Settings, peakInside: Bool = false) -> (time: Double, ratio: Double)? {
        let win = max(8, Int((settings.window * rate).rounded()))
        let hop = max(1, Int((settings.hop * rate).rounded()))
        // Level is compared half a window either side of each candidate time.
        let half = win / 2
        let first = Int((from * rate).rounded()) - 2 * half - win / 2
        let last = Int((to * rate).rounded()) + 2 * half + win / 2
        guard first >= 0, last < x.count, last - first > win else { return nil }
        let count = (last - first - win) / hop + 1
        let lag = max(1, half / hop)
        guard count > 2 * lag + 1 else { return nil }
        let level = partialLevel(of: pitch, in: x, rate: rate, first: first, length: last - first,
                                 window: win, hop: hop, settings: settings)
        // Empty when the fundamental lies above `maxPartialHz`.
        guard level.count == count else { return nil }
        // level[k] is centred at first + k * hop + win / 2.
        func time(_ k: Int) -> Double { Double(first + k * hop + win / 2) / rate }
        func rise(_ k: Int) -> Float { level[k + lag] - level[k - lag] }
        var bestK = -1
        var bestRise: Float = 0
        for k in lag..<(count - lag) where rise(k) > bestRise {
            if peakInside {
                guard k > lag, k < count - lag - 1, rise(k) >= rise(k - 1), rise(k) >= rise(k + 1),
                      time(k) >= from - settings.hop / 2, time(k) <= to + settings.hop / 2 else { continue }
            }
            bestRise = rise(k); bestK = k
        }
        guard bestK >= 0 else { return nil }
        let after = Double(level[bestK + lag]), before = Double(level[bestK - lag])
        return (time(bestK), after / max(before, 1e-9))
    }

    /// The summed magnitude of the note's partials in Hann windows of `window`
    /// samples every `hop` samples from `first`; entry k is centred at
    /// `first + k * hop + window / 2`.
    static func partialLevel(of pitch: Int, in x: [Float], rate: Double, first: Int, length: Int,
                             window win: Int, hop: Int, settings: Settings) -> [Float] {
        let partials = partialLevels(of: pitch, in: x, rate: rate, first: first, length: length,
                                     window: win, hop: hop, settings: settings)
        guard var level = partials.first else { return [] }
        for p in partials.dropFirst() { vDSP_vadd(level, 1, p, 1, &level, 1, vDSP_Length(level.count)) }
        return level
    }

    /// `partialLevel` for each partial on its own, the fundamental first.
    static func partialLevels(of pitch: Int, in x: [Float], rate: Double, first: Int, length: Int,
                              window win: Int, hop: Int, settings: Settings) -> [[Float]] {
        let count = (length - win) / hop + 1
        var levels: [[Float]] = []
        var window = [Float](repeating: 0, count: win)
        vDSP_hann_window(&window, vDSP_Length(win), Int32(vDSP_HANN_NORM))
        var phase = [Float](repeating: 0, count: length)
        var cosine = [Float](repeating: 0, count: length), sine = [Float](repeating: 0, count: length)
        var re = [Float](repeating: 0, count: count), im = [Float](repeating: 0, count: count)
        let f0 = 440 * pow(2, Double(pitch - 69) / 12)
        for h in 1...max(1, settings.partials) {
            let hz = f0 * Double(h)
            guard hz <= settings.maxPartialHz, hz < rate / 2 else { break }
            // Demodulate: x(t) e^{-i w t}, then a Hann-weighted sum per hop.
            var start: Float = 0, step = Float(2 * Double.pi * hz / rate)
            vDSP_vramp(&start, &step, &phase, 1, vDSP_Length(length))
            var n = Int32(length)
            vvsincosf(&sine, &cosine, phase, &n)
            x.withUnsafeBufferPointer { p in
                vDSP_vmul(p.baseAddress! + first, 1, cosine, 1, &cosine, 1, vDSP_Length(length))
                vDSP_vmul(p.baseAddress! + first, 1, sine, 1, &sine, 1, vDSP_Length(length))
            }
            vDSP_desamp(cosine, hop, window, &re, vDSP_Length(count), vDSP_Length(win))
            vDSP_desamp(sine, hop, window, &im, vDSP_Length(count), vDSP_Length(win))
            var magnitude = [Float](repeating: 0, count: count)
            re.withUnsafeMutableBufferPointer { r in
                im.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    vDSP_zvabs(&split, 1, &magnitude, 1, vDSP_Length(count))
                }
            }
            levels.append(magnitude)
        }
        return levels
    }

    /// `x` low-passed and kept every `factor`-th sample: a windowed-sinc
    /// filter at 80% of the new Nyquist frequency.
    static func lowBand(_ x: [Float], factor: Int) -> [Float] {
        let taps = 16 * factor + 1
        var filter = [Float](repeating: 0, count: taps)
        let cutoff = 0.8 / Double(factor)   // of the old Nyquist
        for i in 0..<taps {
            let m = Double(i - taps / 2)
            let sinc = m == 0 ? cutoff : sin(Double.pi * cutoff * m) / (Double.pi * m)
            let hann = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(taps - 1))
            filter[i] = Float(sinc * hann)
        }
        // Centre the filter: pad half its length on both sides.
        var padded = [Float](repeating: 0, count: x.count + taps)
        padded.withUnsafeMutableBufferPointer { p in
            x.withUnsafeBufferPointer { (p.baseAddress! + taps / 2).update(from: $0.baseAddress!, count: x.count) }
        }
        let count = x.count / factor
        var out = [Float](repeating: 0, count: count)
        vDSP_desamp(padded, factor, filter, &out, vDSP_Length(count), vDSP_Length(taps))
        return out
    }
}
