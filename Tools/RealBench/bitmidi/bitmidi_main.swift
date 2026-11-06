import Foundation

// bitmidi: turns a fan-made MIDI file into a RealBench key for a real
// recording. See README.md.

let usage = """
usage:
  bitmidi inspect FILE.mid                                   voices, programs, ranges, suggested roles
  bitmidi align AUDIO FILE.mid --out DIR [options]           alignment only (align.json, report.txt, aligned.mid)
  bitmidi truth AUDIO FILE.mid --out DIR [--roles R.json]    alignment + RealBench key (truth.json)
  bitmidi pick AUDIO A.mid B.mid ... [--out DIR]             ranks candidate MIDI files by confidently aligned time
  bitmidi song SONGDIR [--midi FILE] [--fresh-roles]         whole path for SONGDIR/audio.wav + midi-candidates/*.mid
  bitmidi validate AUDIO --midi A.mid [--midi B.mid ...] [validate options]   synthetic warp test (known answer)
  bitmidi compare KEY1.json KEY2.json                        agreement of two keys (e.g. from two MIDI candidates)

align options:
  --transpose N        fix the transposition (semitones added to the MIDI) instead of searching all 12
  --no-refine          skip the onset refinement of the time map
  --onset-weight W     weight of the onset features in the fine alignment (default 0.5)
  --band S             half-width of the fine search band in seconds (default 0.6)
  --gap G, --z0 Z      coarse gap penalty and match threshold (std units; defaults 1.0, 1.0)
validate options:
  --shift N            transpose the MIDI by N semitones before aligning (default 3)
  --rate R --amp A --period P   tempo curve: MIDI plays at R x (1 + A sin(2 pi t / P)) of the recording's time (defaults 1.12, 0.06, 37)
  --cut a:b            remove the recording's [a, b) from the MIDI (repeatable)
  --repeat a:b         play [a, b) twice in the MIDI (repeatable)
  --jitter S           random onset jitter (uniform +-S seconds) on the MIDI notes
  --no-drums           drop drum notes from the MIDI
  --keep-parts I,J     keep only these MIDI files (0-based, in --midi order), e.g. a simplified arrangement
"""

func argValue(_ args: [String], _ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func argValues(_ args: [String], _ name: String) -> [String] {
    var out: [String] = []
    for (i, a) in args.enumerated() where a == name && i + 1 < args.count { out.append(args[i + 1]) }
    return out
}
func positional(_ args: [String], flags: Set<String>) -> [String] {
    let flags = flags.union(["--no-refine", "--one-pass", "--no-drums", "--fresh-roles", "--pitched"])
    var out: [String] = []
    var i = 0
    while i < args.count {
        if args[i].hasPrefix("--") { i += flags.contains(args[i]) ? 1 : 2; continue }
        out.append(args[i]); i += 1
    }
    return out
}
func span(_ s: String) throws -> (Double, Double) {
    let v = s.split(separator: ":").compactMap { Double($0) }
    guard v.count == 2, v[0] < v[1] else { throw RBError("expected start:end, got \(s)") }
    return (v[0], v[1])
}
func params(from args: [String]) throws -> AlignParams {
    var p = AlignParams()
    if let t = argValue(args, "--transpose") { guard let v = Int(t) else { throw RBError("--transpose needs a whole number") }; p.transpose = v }
    if args.contains("--no-refine") { p.refine = false }
    if let w = argValue(args, "--onset-weight").flatMap(Float.init) { p.onsetWeight = w }
    if let b = argValue(args, "--band").flatMap(Double.init) { p.band = max(5, Int((b / bmHop).rounded())) }
    if let g = argValue(args, "--gap").flatMap(Float.init) { p.gap = g }
    if let z = argValue(args, "--z0").flatMap(Float.init) { p.z0 = z }
    if let x = argValue(args, "--offdiag").flatMap(Float.init) { p.offDiagonalPenalty = x }
    if let x = argValue(args, "--gap-open").flatMap(Float.init) { p.gapOpen = x }
    if let x = argValue(args, "--slope-penalty").flatMap(Float.init) { p.slopePenalty = x }
    if args.contains("--one-pass") { p.twoPass = false }
    if let x = argValue(args, "--coarse-window").flatMap(Double.init) { p.coarseWindow = max(10, Int((x / bmHop).rounded())) }
    return p
}
/// The command line plus roles.json's "align" settings (the command line wins: argValue takes the first).
func argsWithRoles(_ args: [String], _ r: RolesFile?) throws -> [String] {
    guard let align = r?.align, !align.isEmpty else { return args }
    let valued: Set<String> = ["onset-weight", "band", "gap", "z0", "offdiag", "gap-open", "slope-penalty", "coarse-window"]
    let flags: Set<String> = ["no-refine", "one-pass"]
    var out = args
    for (name, v) in align.sorted(by: { $0.key < $1.key }) {
        if valued.contains(name) { out += ["--" + name, String(v)] }
        else if flags.contains(name) { if v != 0 { out.append("--" + name) } }
        else { throw RBError("roles.json align: unknown setting \"\(name)\" (use \((valued.union(flags)).sorted().joined(separator: ", ")))") }
    }
    return out
}
func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
func writeJSONFile(_ object: Any, _ path: String) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try data.write(to: URL(fileURLWithPath: path))
}
func signed(_ k: Int) -> Int { let x = ((k % 12) + 12) % 12; return x <= 6 ? x : x - 12 }
func fmtSpans(_ s: [(Double, Double)]) -> String { s.isEmpty ? "none" : s.map { String(format: "%.1f-%.1f", $0.0, $0.1) }.joined(separator: ", ") }

func loadAudioFeatures(_ path: String) throws -> AudioFeatures {
    let t0 = Date()
    let x = try AudioFileLoader.loadMono(url: URL(fileURLWithPath: path), sampleRate: bmSampleRate, downmix: true)
    let af = computeAudioFeatures(x)
    log(String(format: "audio %@: %.1f s, tuning %+.0f cents, %d onset peaks (%.1f s)", (path as NSString).lastPathComponent,
               af.duration, af.tuningCents, af.peaks.count, Date().timeIntervalSince(t0)))
    return af
}

// MARK: - One MIDI against one recording

nonisolated struct AlignedSong {
    var midi: BMMidi
    var sym: SymFeatures
    var res: AlignResult
    var sections: [SectionConfidence]
    var semitones: Int
    var confidentSeconds: Double
    var matchedSeconds: Double
}

func alignSong(af: AudioFeatures, midi: BMMidi, p: AlignParams) throws -> AlignedSong {
    let sym = computeSymbolicFeatures(midi.notes, duration: midi.duration)
    guard let res = align(af: af, sym: sym, notes: midi.notes, p: p, log: log) else {
        throw RBError("\(midi.path): no alignment found (the MIDI and the recording do not match anywhere)")
    }
    let sections = sectionConfidence(af: af, sym: sym, notes: midi.notes, midi: midi.contents, res: res)
    let matched = res.map.audioSpans.reduce(0) { $0 + $1.1 - $1.0 }
    let confident = sections.filter { !$0.low }.reduce(0) { $0 + $1.audioEnd - $1.audioStart }
    let semis = p.transpose ?? signed(res.transpose)
    return AlignedSong(midi: midi, sym: sym, res: res, sections: sections, semitones: semis,
                       confidentSeconds: confident, matchedSeconds: matched)
}

func alignmentJSON(_ s: AlignedSong, af: AudioFeatures) -> [String: Any] {
    [
        "format": "bitmidi-align-1",
        "midi": s.midi.path,
        "transposeSemitones": s.semitones,
        "coarseScoreByTransposition": s.res.scores.enumerated().map { ["semitones": signed($0.offset), "score": r3(Double($0.element))] },
        "tuningCents": r3(af.tuningCents),
        "audioDuration": r3(af.duration),
        "midiDuration": r3(s.midi.duration),
        "matchedSeconds": r3(s.matchedSeconds),
        "confidentSeconds": r3(s.confidentSeconds),
        "audioOnlySpans": s.res.audioOnly.map { [r3($0.0), r3($0.1)] },
        "midiOnlySpans": s.res.midiOnly.map { [r3($0.0), r3($0.1)] },
        "segments": s.res.map.segments.map { ["midi": $0.midi.map(r4), "audio": $0.audio.map(r4)] },
        "sections": s.sections.map { sec -> [String: Any] in
            ["label": sec.label, "midi": [sec.midiStart, sec.midiEnd], "audio": [sec.audioStart, sec.audioEnd],
             "chromaSim": sec.chromaSim, "chromaBackground": sec.chromaBackground, "onsets": sec.onsets,
             "hit50": sec.hit50, "chance50": sec.chance50, "onsetLagMs": sec.onsetLag, "onsetContrast": sec.onsetContrast,
             "drumBeatShift": sec.drumBeatShift, "drumHits": sec.drumHits, "drumPeriodic": sec.drumPeriodic,
             "chromaBeatShift": sec.chromaBeatShift, "chromaBeatGain": sec.chromaBeatGain, "slopeJitter": sec.slopeJitter, "keyMargin": sec.keyMargin,
             "midiSounding": sec.midiSounding, "low": sec.low, "reason": sec.reason]
        },
    ]
}

func alignmentReport(_ s: AlignedSong, af: AudioFeatures) -> String {
    var L: [String] = []
    let sc = s.res.scores
    let ranked = sc.indices.sorted { sc[$0] > sc[$1] }
    L.append("MIDI \(s.midi.path)")
    L.append(String(format: "transposition %+d semitones (coarse score %.0f; next %+d at %.0f)%@", s.semitones, sc[ranked[0]],
                    signed(ranked.count > 1 ? ranked[1] : ranked[0]), ranked.count > 1 ? sc[ranked[1]] : 0,
                    ranked.count > 1 && sc[ranked[1]] > 0.8 * sc[ranked[0]] ? "  CLOSE: check the key by ear" : ""))
    L.append(String(format: "recording %.1f s, tuning %+.0f cents; MIDI %.1f s; matched %.1f s of the recording, confident %.1f s (%.0f%%)",
                    af.duration, af.tuningCents, s.midi.duration, s.matchedSeconds, s.confidentSeconds, 100 * s.confidentSeconds / max(1, af.duration)))
    if abs(af.tuningCents) > 25 {
        L.append(String(format: "WARNING: the recording is tuned %+.0f cents from A440: pitches near a semitone boundary may read either way", af.tuningCents))
    }
    L.append("segments (recording s <- MIDI s): " + s.res.map.segments.map {
        String(format: "%.1f-%.1f <- %.1f-%.1f", $0.audio[0], $0.audio.last!, $0.midi[0], $0.midi.last!) }.joined(separator: "; "))
    L.append("recording only (not in the MIDI): \(fmtSpans(s.res.audioOnly))")
    L.append("MIDI only (not in the recording): \(fmtSpans(s.res.midiOnly))")
    let all = s.sections
    func mean(_ f: (SectionConfidence) -> Double) -> Double { all.isEmpty ? 0 : all.map(f).reduce(0, +) / Double(all.count) }
    L.append(String(format: "mean over sections: chroma %.2f vs background %.2f; onsets within 50 ms of a recording onset %.0f%% (chance %.0f%%); onset contrast %.2f",
                    mean(\.chromaSim), mean(\.chromaBackground), 100 * mean(\.hit50), 100 * mean(\.chance50), mean(\.onsetContrast)))
    L.append("")
    L.append("section             recording        chroma  bg     onsets hit50 ch50  lag(ms) contrast drums sounding jitter keymargin  cbeat       flag")
    for x in all {
        func pad(_ t: String, _ n: Int) -> String { t.count >= n ? t : t + String(repeating: " ", count: n - t.count) }
        L.append(pad(x.label, 20) + pad(String(format: "%6.1f-%6.1f", x.audioStart, x.audioEnd), 17)
                 + String(format: "%.2f    %.2f   %4d   %.2f  %.2f  %+5.0f   %5.2f    %@ %.2f      ", x.chromaSim, x.chromaBackground, x.onsets,
                          x.hit50, x.chance50, x.onsetLag, x.onsetContrast,
                          (x.drumPeriodic ? "=" : x.drumHits >= 8 ? String(format: "%+d", x.drumBeatShift) : "-").padding(toLength: 5, withPad: " ", startingAt: 0),
                          x.midiSounding) + String(format: "%5.2f   %5.2f      ", x.slopeJitter, x.keyMargin)
                 + (x.chromaBeatShift == 0 ? "+0" : String(format: "%+d %+.0f%%", x.chromaBeatShift, 100 * x.chromaBeatGain)).padding(toLength: 12, withPad: " ", startingAt: 0)
                 + (x.low ? "LOW: " + x.reason : x.reason.isEmpty ? "ok" : x.reason))
    }
    return L.joined(separator: "\n")
}

// MARK: - Commands

func inspectCommand(_ args: [String]) throws {
    guard let path = args.first else { throw RBError(usage) }
    let m = try loadBMMidi(path)
    let mc = m.contents
    print("\(path): \(m.voices.count) voices, \(m.notes.count) notes, \(String(format: "%.1f", m.duration)) s")
    print("tempo: " + (mc.tempos.isEmpty ? "none (120 BPM assumed)" : mc.tempos.prefix(8).map { String(format: "%.1f BPM at %.1f s", $0.bpm, $0.seconds) }.joined(separator: ", ")
          + (mc.tempos.count > 8 ? " ... (\(mc.tempos.count) changes)" : "")))
    print("meter: " + mc.meters.map { String(format: "%d/%d at %.1f s", $0.num, $0.den, $0.seconds) }.joined(separator: ", ")
          + "; \(mc.beats.count) beats, \(mc.downbeats.count) bars")
    print(roleReport(m))
}

func alignCommand(_ args: [String], withTruth: Bool) throws {
    let pos = positional(args, flags: ["--no-refine", "--fresh-roles"])
    guard pos.count == 2, let out = argValue(args, "--out") else { throw RBError(usage) }
    try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    let af = try loadAudioFeatures(pos[0])
    var m = try loadBMMidi(pos[1])
    var p = try params(from: args)
    var options = KeyOptions()
    if withTruth, let rp = argValue(args, "--roles") {
        let r = try JSONDecoder().decode(RolesFile.self, from: Data(contentsOf: URL(fileURLWithPath: rp)))
        for line in try applyRoles(r, to: &m) { log(line) }
        p = try params(from: argsWithRoles(args, r))
        if r.transpose != "auto" { guard let v = Int(r.transpose) else { throw RBError("roles.json transpose must be \"auto\" or a whole number") }; p.transpose = v }
        options = KeyOptions(r)
    }
    try runKey(af: af, audioPath: pos[0], midi: m, p: p, out: out, withTruth: withTruth, options: options,
               name: (pos[0] as NSString).deletingPathExtension.components(separatedBy: "/").suffix(2).joined(separator: "/"))
}

@discardableResult
func runKey(af: AudioFeatures, audioPath: String, midi: BMMidi, p: AlignParams, out: String, withTruth: Bool,
            options: KeyOptions, name: String, preamble: [String] = []) throws -> AlignedSong {
    var s = try alignSong(af: af, midi: midi, p: p)
    let autoConfident = s.confidentSeconds
    var trustLines: [String] = []
    if !options.trust.isEmpty {
        for k in s.sections.indices where s.sections[k].low {
            let a = s.sections[k].audioStart, b = s.sections[k].audioEnd
            let inside = options.trust.reduce(0.0) { $0 + max(0, min(b, $1.1) - max(a, $1.0)) }
            guard inside >= 0.5 * (b - a) else { continue }
            trustLines.append("  \(s.sections[k].label) (\(String(format: "%.1f-%.1f s", a, b))): \(s.sections[k].reason)")
            s.sections[k].low = false
            s.sections[k].reason = "trusted in roles.json (flag was: \(s.sections[k].reason))"
        }
        s.confidentSeconds = s.sections.filter { !$0.low }.reduce(0) { $0 + $1.audioEnd - $1.audioStart }
        trustLines.insert(String(format: "roles.json trust spans %@ keep %d flagged sections: confident %.1f s automatically, %.1f s (%.0f%%) with them",
                                 fmtSpans(options.trust), trustLines.count, autoConfident, s.confidentSeconds,
                                 100 * s.confidentSeconds / max(1, af.duration)), at: 0)
    }
    var aj = alignmentJSON(s, af: af)
    aj["confidentSecondsAutomatic"] = r3(autoConfident)
    try writeJSONFile(aj, out + "/align.json")
    try writeAlignedMidi(m: s.midi, res: s.res, semitones: s.semitones, to: out + "/aligned.mid")
    var report = preamble + [alignmentReport(s, af: af)] + trustLines + ["", "VOICES", roleReport(s.midi)]
    if withTruth {
        let key = buildKey(m: s.midi, res: s.res, semitones: s.semitones, sections: s.sections, audioDuration: af.duration,
                           options: options, name: name,
                           source: "bitmidi: \((midi.path as NSString).lastPathComponent) aligned to \((audioPath as NSString).lastPathComponent), transposed \(s.semitones >= 0 ? "+" : "")\(s.semitones)")
        var truth = key.truth
        truth["bitmidi"] = ["midi": midi.path, "transposeSemitones": s.semitones, "tuningCents": r3(af.tuningCents),
                            "confidentSeconds": r3(s.confidentSeconds), "confidentSecondsAutomatic": r3(autoConfident),
                            "matchedSeconds": r3(s.matchedSeconds), "alignSettings": p.summary,
                            "estimatedKey": key.keyName, "keyOptions": options.summary, "bpm": r3(key.bpm)] as [String: Any]
        try writeJSONFile(truth, out + "/truth.json")
        var byPart: [String: Int] = [:]
        for n in key.notes { byPart[n.part, default: 0] += 1 }
        let scored = af.duration - key.ignore.reduce(0) { $0 + $1.1 - $1.0 }
        report += ["", "KEY \(out)/truth.json",
                   String(format: "notes %d (%@); beats %d (%.0f BPM), downbeats %d, %d per bar; chords %d spans; key of the MIDI harmony %@",
                          key.notes.count, ["melody", "countermelody", "chords", "bass"].map { "\($0) \(byPart[$0] ?? 0)" }.joined(separator: ", "),
                          (truth["beats"] as? [Double])?.count ?? 0, key.bpm, (truth["downbeats"] as? [Double])?.count ?? 0,
                          truth["beatsPerBar"] as? Int ?? 0, key.chords.count, key.keyName),
                   String(format: "ignored: %@ (%.1f s scored of %.1f s)", fmtSpans(key.ignore), scored, af.duration)]
        report += key.warnings.map { "warning: " + $0 }
        var labels: [String: Double] = [:]
        for c in key.chords { labels[c.label, default: 0] += c.end - c.start }
        report.append("chord labels by time: " + labels.sorted { $0.value > $1.value }.prefix(14).map { String(format: "%@ %.0fs", $0.key, $0.value) }.joined(separator: ", "))
        report += ["", "OCTAVE CHECK (recording energy at the key's pitches shifted by -24...+24 semitones: level while the notes sound,",
                   "and rise at their onsets; a hint only, other parts on the same pitch classes blur it)"]
        report += octaveCheck(m: s.midi, res: s.res, af: af, semitones: s.semitones, ignore: key.ignore)
    }
    let text = report.joined(separator: "\n") + "\n"
    try text.write(toFile: out + "/report.txt", atomically: true, encoding: .utf8)
    print(text)
    return s
}

func pickCommand(_ args: [String]) throws {
    let pos = positional(args, flags: ["--no-refine"])
    guard pos.count >= 2 else { throw RBError(usage) }
    let af = try loadAudioFeatures(pos[0])
    let p = try params(from: args)
    let ranked = try pickCandidates(af: af, paths: Array(pos.dropFirst()), p: p)
    let text = ranked.text
    print(text)
    if let out = argValue(args, "--out") {
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        try text.write(toFile: out + "/pick.txt", atomically: true, encoding: .utf8)
    }
}

func pickCandidates(af: AudioFeatures, paths: [String], p: AlignParams) throws -> (best: String?, text: String) {
    var rows: [(String, AlignedSong?, String)] = []
    for path in paths {
        do {
            let m = try loadBMMidi(path)
            let s = try alignSong(af: af, midi: m, p: p)
            rows.append((path, s, ""))
        } catch {
            rows.append((path, nil, "\(error)"))
        }
    }
    rows.sort { ($0.1?.confidentSeconds ?? -1) > ($1.1?.confidentSeconds ?? -1) }
    var L = ["candidate                         transpose  matched  confident  low sections  melody/bass/chords voices"]
    for (path, s, err) in rows {
        let name = (path as NSString).lastPathComponent.padding(toLength: 34, withPad: " ", startingAt: 0)
        guard let s else { L.append(name + "failed: " + err); continue }
        let roles = ["melody", "bass", "chords"].map { r in s.midi.voices.filter { $0.role == r }.count }
        L.append(name + String(format: "%+3d        %5.1f s  %5.1f s    %3d of %-3d     %d/%d/%d", s.semitones, s.matchedSeconds, s.confidentSeconds,
                               s.sections.filter(\.low).count, s.sections.count, roles[0], roles[1], roles[2]))
    }
    L.append("ranked by confidently aligned recording time; the first is picked unless roles.json names a MIDI")
    return (rows.first?.1 != nil ? rows.first!.0 : nil, L.joined(separator: "\n"))
}

func songCommand(_ args: [String]) throws {
    let pos = positional(args, flags: ["--fresh-roles", "--no-refine"])
    guard let dir = pos.first else { throw RBError(usage) }
    let audio = dir + "/audio.wav"
    guard FileManager.default.fileExists(atPath: audio) else { throw RBError("no \(audio): convert the mp3 first (afconvert -f WAVE -d LEI16@44100 song.mp3 \(audio))") }
    let out = dir + "/key"
    try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    let rolesPath = dir + "/roles.json"
    var roles: RolesFile? = nil
    if !args.contains("--fresh-roles"), FileManager.default.fileExists(atPath: rolesPath) {
        roles = try JSONDecoder().decode(RolesFile.self, from: Data(contentsOf: URL(fileURLWithPath: rolesPath)))
    }
    let af = try loadAudioFeatures(audio)
    var p = try params(from: args)
    var preamble: [String] = []
    var midiRel: String
    if let forced = argValue(args, "--midi") {
        midiRel = forced.hasPrefix(dir + "/") ? String(forced.dropFirst(dir.count + 1)) : forced
    } else if let r = roles {
        midiRel = r.midi
    } else {
        let cdir = dir + "/midi-candidates"
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: cdir)) ?? []).filter { $0.lowercased().hasSuffix(".mid") || $0.lowercased().hasSuffix(".midi") }.sorted()
        guard !files.isEmpty else { throw RBError("no MIDI files in \(cdir)") }
        let picked = try pickCandidates(af: af, paths: files.map { cdir + "/" + $0 }, p: p)
        try picked.text.write(toFile: out + "/pick.txt", atomically: true, encoding: .utf8)
        preamble += ["CANDIDATES", picked.text, ""]
        guard let best = picked.best else { throw RBError("no candidate aligned") }
        midiRel = "midi-candidates/" + (best as NSString).lastPathComponent
    }
    let midiPath = midiRel.hasPrefix("/") ? midiRel : dir + "/" + midiRel
    var m = try loadBMMidi(midiPath)
    try writeJSONFile(try JSONSerialization.jsonObject(with: JSONEncoder().encode(rolesFile(for: m, midiRelative: midiRel))), out + "/roles.suggested.json")
    var options = KeyOptions()
    if let r = roles, r.midi == midiRel {
        let notes = try applyRoles(r, to: &m)
        preamble += ["roles.json applied" + (notes.isEmpty ? " (no changes from the suggestions)" : ":")] + notes.map { "  " + $0 } + [""]
        p = try params(from: argsWithRoles(args, r))
        if let al = r.align, !al.isEmpty {
            preamble += ["alignment settings from roles.json: " + al.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "), ""]
        }
        if r.transpose != "auto" { guard let v = Int(r.transpose) else { throw RBError("roles.json transpose must be \"auto\" or a whole number") }; p.transpose = v }
        options = KeyOptions(r)
    } else {
        if let r = roles { preamble.append("roles.json is for \(r.midi), not \(midiRel): using suggested roles (run with --fresh-roles to rewrite it)") }
        else {
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try enc.encode(rolesFile(for: m, midiRelative: midiRel)).write(to: URL(fileURLWithPath: rolesPath))
            preamble.append("wrote \(rolesPath) with the suggested roles: review it, edit role/addTranspose/transpose/ignore, and run again")
        }
    }
    if args.contains("--fresh-roles") {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(rolesFile(for: m, midiRelative: midiRel)).write(to: URL(fileURLWithPath: rolesPath))
        preamble.append("rewrote \(rolesPath) with fresh suggestions")
    }
    try runKey(af: af, audioPath: audio, midi: m, p: p, out: out, withTruth: true, options: options,
               name: (dir as NSString).lastPathComponent, preamble: preamble)
}

// MARK: - Synthetic validation

func validateCommand(_ args: [String]) throws {
    let pos = positional(args, flags: ["--no-drums", "--no-refine"])
    guard let audio = pos.first else { throw RBError(usage) }
    let midiPaths = argValues(args, "--midi")
    guard !midiPaths.isEmpty else { throw RBError("validate needs --midi FILE (the exact MIDI of the recording)") }
    let shift = Int(argValue(args, "--shift") ?? "3") ?? 3
    let rate = Double(argValue(args, "--rate") ?? "1.12") ?? 1.12
    let amp = Double(argValue(args, "--amp") ?? "0.06") ?? 0.06
    let period = Double(argValue(args, "--period") ?? "37") ?? 37
    let jitter = Double(argValue(args, "--jitter") ?? "0") ?? 0
    let cuts = try argValues(args, "--cut").map(span)
    let repeats = try argValues(args, "--repeat").map(span)
    let keep = argValue(args, "--keep-parts").map { Set($0.split(separator: ",").compactMap { Int($0) }) }
    let p = try params(from: args)

    // Combine the files: each file's voices keep their own index range.
    var voices: [BMVoice] = []
    var orig: [SymNote] = []
    var beats: [Double] = [], downs: [Double] = []
    var contents: MidiContents? = nil
    for (fi, path) in midiPaths.enumerated() {
        let m = try loadBMMidi(path)
        if contents == nil { contents = m.contents; beats = m.contents.beats; downs = m.contents.downbeats }
        if let keep, !keep.contains(fi) { continue }
        let base = voices.count
        voices += m.voices
        orig += m.notes.map { var n = $0; n.voice += base; return n }
    }
    if args.contains("--no-drums") { orig = orig.filter { !$0.drum } }
    let end = max(orig.map(\.off).max() ?? 0, beats.last ?? 0) + 1
    // Pieces of the recording's timeline, in MIDI order.
    var pieces: [(Double, Double, Bool)] = [(0, end, false)]   // (start, end, isRepeat)
    for (a, b) in cuts {
        pieces = pieces.flatMap { pc -> [(Double, Double, Bool)] in
            if b <= pc.0 || a >= pc.1 { return [pc] }
            return [(pc.0, max(pc.0, a), pc.2), (min(pc.1, b), pc.1, pc.2)].filter { $0.1 - $0.0 > 1e-6 }
        }
    }
    for (a, b) in repeats {
        if let k = pieces.firstIndex(where: { $0.0 <= a && $0.1 >= b }) {
            let pc = pieces[k]
            pieces.replaceSubrange(k...k, with: [(pc.0, b, pc.2), (a, b, true), (b, pc.1, pc.2)].filter { $0.1 - $0.0 > 1e-6 })
        }
    }
    // Tempo curve: MIDI time advances at rate(t) per second of recording time.
    func g(_ t: Double) -> Double { rate * (t + amp * period / (2 * .pi) * (1 - cos(2 * .pi * t / period))) }
    var offsets: [Double] = []
    var acc = 0.0
    for pc in pieces { offsets.append(acc); acc += g(pc.1) - g(pc.0) }
    func toMidi(_ t: Double, _ k: Int) -> Double { offsets[k] + g(t) - g(pieces[k].0) }
    var lcg: UInt64 = 0x9E3779B97F4A7C15   // fixed seed: runs repeat exactly
    func rand() -> Double { lcg = lcg &* 6364136223846793005 &+ 1442695040888963407; return Double(lcg >> 11) / Double(1 << 53) }
    var warped: [SymNote] = []
    var truthOf: [(midi: Double, audio: Double, piece: Int, drum: Bool)] = []
    // Jitter per onset (notes struck together move together, as in a quantised MIDI against a played take).
    var jitterOf: [Int: Double] = [:]
    for n in orig { let key = Int((n.on * 1000).rounded()); if jitterOf[key] == nil { jitterOf[key] = jitter > 0 ? (rand() * 2 - 1) * jitter : 0 } }
    for (k, pc) in pieces.enumerated() {
        for n in orig where n.on >= pc.0 && n.on < pc.1 {
            var w = n
            let j = jitterOf[Int((n.on * 1000).rounded())] ?? 0
            w.on = toMidi(n.on, k) + j
            w.off = toMidi(min(n.off, pc.1), k) + j
            if !n.drum { w.pitch += shift }
            warped.append(w)
            truthOf.append((toMidi(n.on, k), n.on, k, n.drum))
        }
    }
    warped.sort { $0.on < $1.on }
    var mc = contents!
    func warpBeats(_ xs: [Double]) -> [Double] {
        var out: [Double] = []
        for (k, pc) in pieces.enumerated() { out += xs.filter { $0 >= pc.0 && $0 < pc.1 }.map { toMidi($0, k) } }
        return out
    }
    mc.beats = warpBeats(beats); mc.downbeats = warpBeats(downs)
    let midi = BMMidi(path: "synthetic(" + midiPaths.map { ($0 as NSString).lastPathComponent }.joined(separator: "+") + ")",
                      contents: mc, voices: voices, notes: warped, duration: acc)

    let af = try loadAudioFeatures(audio)
    let t0 = Date()
    let s = try alignSong(af: af, midi: midi, p: p)
    let secs = Date().timeIntervalSince(t0)
    // Errors on note onsets (pieces that are not repeats) and on beats.
    func stats(_ errs: [Double]) -> String {
        guard !errs.isEmpty else { return "none" }
        let a = errs.map(abs).sorted()
        let signedMean = errs.reduce(0, +) / Double(errs.count)
        return String(format: "n %d, median %.1f ms, p90 %.1f ms, mean signed %+.1f ms, within 50 ms %.1f%%, within 100 ms %.1f%%",
                      a.count, 1000 * a[a.count / 2], 1000 * a[min(a.count - 1, Int(Double(a.count) * 0.9))], 1000 * signedMean,
                      100 * Double(a.filter { $0 <= 0.05 }.count) / Double(a.count), 100 * Double(a.filter { $0 <= 0.1 }.count) / Double(a.count))
    }
    var errs: [Double] = [], unmapped = 0, inRepeats = 0
    var seen = Set<Double>()
    var dump = "audio_time,error_ms,drum\n"
    for x in truthOf where !pieces[x.piece].2 {
        let key = (x.midi * 1000).rounded()
        if seen.contains(key) { continue }
        seen.insert(key)
        if let a = s.res.map.audio(x.midi) {
            errs.append(a - x.audio)
            dump += String(format: "%.3f,%.1f,%d\n", x.audio, 1000 * (a - x.audio), x.drum ? 1 : 0)
        } else { unmapped += 1 }
    }
    if let path = argValue(args, "--dump") {
        try dump.write(toFile: path, atomically: true, encoding: .utf8)
        var pd = "i,j\n"
        for (i, j) in s.res.finePath { pd += "\(i),\(j)\n" }
        try pd.write(toFile: path + ".path.csv", atomically: true, encoding: .utf8)
    }
    for x in truthOf where pieces[x.piece].2 { if s.res.map.audio(x.midi) != nil { inRepeats += 1 } }
    var beatErrs: [Double] = []
    for (k, pc) in pieces.enumerated() where !pc.2 {
        for b in beats where b >= pc.0 && b < pc.1 { if let a = s.res.map.audio(toMidi(b, k)) { beatErrs.append(a - b) } }
    }
    // Errors inside confident sections only.
    let lowSpans = s.sections.filter(\.low).map { ($0.audioStart, $0.audioEnd) }
    var confErrs: [Double] = []
    seen = []
    for x in truthOf where !pieces[x.piece].2 {
        let key = (x.midi * 1000).rounded()
        if seen.contains(key) { continue }
        seen.insert(key)
        if let a = s.res.map.audio(x.midi), !lowSpans.contains(where: { a >= $0.0 && a < $0.1 }) { confErrs.append(a - x.audio) }
    }
    // Per section: the true error of the notes in it, next to the confidence flag (to calibrate the flags).
    var secLines: [String] = []
    var flagStats = (lowBad: 0, lowGood: 0, okBad: 0, okGood: 0)
    for sec in s.sections {
        var e: [Double] = []
        for x in truthOf where !pieces[x.piece].2 && x.midi >= sec.midiStart && x.midi < sec.midiEnd {
            if let a = s.res.map.audio(x.midi) { e.append(abs(a - x.audio)) }
        }
        e.sort()
        let med = e.isEmpty ? 0 : e[e.count / 2]
        let bad = !e.isEmpty && Double(e.filter { $0 > 0.05 }.count) > 0.3 * Double(e.count)
        switch (sec.low, bad) {
        case (true, true): flagStats.lowBad += 1
        case (true, false): flagStats.lowGood += 1
        case (false, true): flagStats.okBad += 1
        case (false, false): flagStats.okGood += 1
        }
        secLines.append(String(format: "  %@ %6.1f-%6.1f  notes %3d  median error %6.0f ms  %@  %@", sec.label.padding(toLength: 16, withPad: " ", startingAt: 0),
                               sec.audioStart, sec.audioEnd, e.count, 1000 * med, bad ? "MISALIGNED" : "aligned   ", sec.low ? "flagged LOW (\(sec.reason))" : "ok"))
    }
    let expected = ((-shift % 12) + 12) % 12
    var L: [String] = []
    L.append("VALIDATE \(midi.path) vs \((audio as NSString).lastPathComponent)")
    L.append(String(format: "warp: MIDI runs at %.2f x (1 + %.2f sin(2 pi t / %.0f s)) of the recording; transposed %+d; jitter %.0f ms%@%@%@%@",
                    rate, amp, period, shift, 1000 * jitter, cuts.isEmpty ? "" : "; cut " + fmtSpans(cuts),
                    repeats.isEmpty ? "" : "; repeated " + fmtSpans(repeats), args.contains("--no-drums") ? "; no drums" : "",
                    keep.map { "; parts " + $0.sorted().map(String.init).joined(separator: ",") } ?? ""))
    L.append("transposition found: \(signed(s.res.transpose)) (expected \(signed(expected))) -> \(s.res.transpose == expected ? "OK" : "WRONG")")
    L.append("onset error, all mapped notes: " + stats(errs) + (unmapped > 0 ? "; \(unmapped) onsets not mapped" : ""))
    L.append("onset error, confident sections: " + stats(confErrs))
    L.append("beat error: " + stats(beatErrs))
    L.append("recording-only spans found: \(fmtSpans(s.res.audioOnly)) (expected \(fmtSpans(cuts)))")
    L.append("MIDI-only spans found: \(fmtSpans(s.res.midiOnly))" + (repeats.isEmpty ? "" : "; repeated-copy notes still mapped: \(inRepeats)"))
    L.append(String(format: "matched %.1f s, confident %.1f s, %d of %d sections low; alignment took %.1f s",
                    s.matchedSeconds, s.confidentSeconds, s.sections.filter(\.low).count, s.sections.count, secs))
    L.append("flags vs truth (misaligned = over 30% of its notes off by more than 50 ms): misaligned and flagged \(flagStats.lowBad), misaligned but not flagged \(flagStats.okBad), aligned but flagged \(flagStats.lowGood), aligned and not flagged \(flagStats.okGood)")
    if args.contains("--sections") { L += secLines }
    if let out = argValue(args, "--out") {
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        try (L.joined(separator: "\n") + "\n\n" + alignmentReport(s, af: af) + "\n").write(toFile: out + "/validate.txt", atomically: true, encoding: .utf8)
    }
    print(L.joined(separator: "\n"))
}

/// Debug: signed offset of the recording's onset peaks from the exact MIDI's onsets (no warp).
func peakCheckCommand(_ args: [String]) throws {
    let af = try loadAudioFeatures(args[0])
    var notes: [SymNote] = []
    for p in args.dropFirst() { notes += try loadBMMidi(p).notes }
    let cl = onsetClusters(notes)
    var d: [Double] = []
    for c in cl {
        if let near = af.peaks.min(by: { abs($0 - c.t) < abs($1 - c.t) }), abs(near - c.t) < 0.08 { d.append(near - c.t) }
    }
    d.sort()
    print(String(format: "%d of %d onset clusters have a peak within 80 ms; signed offset median %+.1f ms, p10 %+.1f, p90 %+.1f",
                 d.count, cl.count, 1000 * d[d.count / 2], 1000 * d[d.count / 10], 1000 * d[d.count * 9 / 10]))
    // Same for the pitched onset channels' frame maxima (sum over 12) and the rhythm channel.
    for (name, range) in [("pitched onset", 0..<12), ("rhythm", 12..<13)] {
        var e: [Double] = []
        for c in cl {
            let f = Int((c.t / bmHop).rounded())
            var bestF = -1; var bestV: Float = 0
            for g in max(1, f - 4)...min(af.frames - 1, f + 4) {
                var v: Float = 0, pv: Float = 0
                for k in range { v += af.onset[g * onsetDims + k]; pv += af.onset[(g - 1) * onsetDims + k] }
                let rise = v - pv
                if rise > bestV { bestV = rise; bestF = g }
            }
            if bestF >= 0 { e.append(Double(bestF) * bmHop - c.t) }
        }
        e.sort()
        print(String(format: "%@ feature rise: median %+.1f ms, p10 %+.1f, p90 %+.1f (n %d)", name, 1000 * e[e.count / 2], 1000 * e[e.count / 10], 1000 * e[e.count * 9 / 10], e.count))
    }
}

/// Debug: mean recording novelty at warped MIDI onsets shifted by -250...+250 ms, per 30 s of recording.
func lagProfileCommand(_ args: [String]) throws {
    let af = try loadAudioFeatures(args[0])
    let m = try loadBMMidi(args[1])
    let p = try params(from: Array(args.dropFirst(2)))
    let s = try alignSong(af: af, midi: m, p: p)
    let nov = gaussianSmooth(af.novelty, sigma: 0.5)
    let cl = onsetClusters(m.notes, includeDrums: !args.contains("--pitched"))
    func at(_ t: Double) -> Double { let i = Int((t / bmHop).rounded()); return i >= 0 && i < nov.count ? Double(nov[i]) : 0 }
    let lags = Array(stride(from: -250, through: 250, by: 10))
    var rows: [Double: [Double]] = [:]
    for c in cl {
        guard let a = s.res.map.audio(c.t) else { continue }
        let key = floor(a / 30) * 30
        var r = rows[key] ?? [Double](repeating: 0, count: lags.count)
        for (k, l) in lags.enumerated() { r[k] += at(a + Double(l) / 1000) }
        rows[key] = r
    }
    print("lag(ms) " + lags.filter { $0 % 50 == 0 }.map { String(format: "%6d", $0) }.joined())
    for key in rows.keys.sorted() {
        let r = rows[key]!
        let mx = r.max()!
        let best = lags[r.firstIndex(of: mx)!]
        print(String(format: "%5.0fs  ", key) + lags.enumerated().filter { $0.element % 50 == 0 }.map { String(format: "%6.2f", r[$0.offset] / mx) }.joined() + "   best \(best) ms")
    }
}

/// Check of the symbolic chord labeller: chords from a RealBench key's own notes (its parts as roles, its
/// beats as the grid) against the key's chords (e.g. als2truth's, which this code ports).
func chordCheckCommand(_ args: [String]) throws {
    guard let path = args.first else { throw RBError("chordcheck KEY.json") }
    let m = try loadTruthAsMidi(path, extra: args.contains("--with-unreliable"))
    let rn = roleNotes(m)
    var pcw = [Double](repeating: 0, count: 12)
    for (n, part) in rn where part != "melody" { pcw[((n.pitch % 12) + 12) % 12] += n.off - n.on }
    let key = estimateKey(pcw)
    var harmony = rn.filter { $0.1 == "chords" }.map { ($0.0.on, $0.0.off, $0.0.pitch, 1.0) }
    if args.contains("--counter") { harmony += rn.filter { $0.1 == "countermelody" }.map { ($0.0.on, $0.0.off, $0.0.pitch, 0.33) } }
    let bass = rn.filter { $0.1 == "bass" }.map { ($0.0.on, $0.0.off, $0.0.pitch) }
    let ours = deriveChords(harmony: harmony, bass: bass, beats: m.contents.beats, names: key.names)
    let truth = try RBTruth.load(path).chords ?? []
    func label(_ list: [(Double, Double, String)], _ t: Double) -> String? { list.first { t >= $0.0 && t < $0.1 }?.2 }
    let o = ours.map { ($0.start, $0.end, $0.label) }, tr = truth.map { ($0.start, $0.end, $0.label ?? "N") }
    var n = 0.0, same = 0.0, root = 0.0
    var t = tr.first?.0 ?? 0
    while t < (tr.last?.1 ?? 0) {
        if let a = label(tr, t) {
            n += 1
            let b = label(o, t) ?? "N"
            if a == b { same += 1 }
            let pa = parseAnyChordLabel(a), pb = parseAnyChordLabel(b)
            if pa?.root == pb?.root && (pa == nil) == (pb == nil) { root += 1 }
        }
        t += 0.05
    }
    print(String(format: "%@: %d chord spans from the notes vs %d in the key; same label %.1f%% of the time, same root %.1f%%",
                 (path as NSString).lastPathComponent, ours.count, truth.count, 100 * same / max(1, n), 100 * root / max(1, n)))
}

/// Agreement of two keys of the same recording, over the time neither ignores: beats and downbeats
/// (F1, +-70 ms), chords (same root / root and major-minor, per 50 ms), notes per role (F1, exact pitch, +-50 ms).
func compareCommand(_ args: [String]) throws {
    guard args.count >= 2 else { throw RBError("compare KEY1.json KEY2.json") }
    let a = try RBTruth.load(args[0]), b = try RBTruth.load(args[1])
    let spans = ((a.ignore ?? []) + (b.ignore ?? [])).map { ($0[0], $0[1]) }
    func ok(_ t: Double) -> Bool { !spans.contains { t >= $0.0 && t < $0.1 } }
    func f1(_ x: [Double], _ y: [Double], _ tol: Double) -> (Double, Int, Int) {
        let xs = x.filter(ok).sorted(), ys = y.filter(ok).sorted()
        var used = Set<Int>(), tp = 0, j = 0
        for t in xs {
            while j < ys.count && ys[j] < t - tol { j += 1 }
            var k = j
            while k < ys.count && ys[k] <= t + tol { if !used.contains(k) { used.insert(k); tp += 1; break }; k += 1 }
        }
        let p = xs.isEmpty ? 0 : Double(tp) / Double(xs.count), r = ys.isEmpty ? 0 : Double(tp) / Double(ys.count)
        return (p + r > 0 ? 2 * p * r / (p + r) : 0, xs.count, ys.count)
    }
    let bt = f1(a.beats ?? [], b.beats ?? [], 0.07), db = f1(a.downbeats ?? [], b.downbeats ?? [], 0.07)
    print(String(format: "beats F1 %.3f (%d vs %d), downbeats F1 %.3f (%d vs %d)", bt.0, bt.1, bt.2, db.0, db.1, db.2))
    func chordAt(_ c: [RBTruthChord], _ t: Double) -> (root: Int, quality: String)?? {
        guard let x = c.first(where: { t >= $0.start && t < $0.end }) else { return nil }
        return .some(truthChordRootQuality(x))
    }
    var n = 0.0, root = 0.0, mm = 0.0
    let ca = a.chords ?? [], cb = b.chords ?? []
    var t = max(ca.first?.start ?? 0, cb.first?.start ?? 0)
    let end = min(ca.last?.end ?? 0, cb.last?.end ?? 0)
    while t < end {
        if ok(t), let x = chordAt(ca, t), let y = chordAt(cb, t) {
            n += 1
            if x?.root == y?.root { root += 1 }
            if x?.root == y?.root && (x.map { majMinClass($0.quality) } ?? nil) == (y.map { majMinClass($0.quality) } ?? nil) { mm += 1 }
        }
        t += 0.05
    }
    print(String(format: "chords over %.0f s: same root %.1f%%, same root and maj/min %.1f%%", n * 0.05, 100 * root / max(1, n), 100 * mm / max(1, n)))
    for role in ["melody", "countermelody", "chords", "bass"] {
        let x = (a.notes ?? []).filter { $0.part == role && ok($0.on) }, y = (b.notes ?? []).filter { $0.part == role && ok($0.on) }
        guard !x.isEmpty || !y.isEmpty else { continue }
        var tp = 0
        var byPitch: [Int: [Double]] = [:]
        for nn in y { byPitch[nn.pitch, default: []].append(nn.on) }
        var octTp = 0
        for nn in x {
            if var list = byPitch[nn.pitch], let k = list.firstIndex(where: { abs($0 - nn.on) <= 0.05 }) { list.remove(at: k); byPitch[nn.pitch] = list; tp += 1 }
            else if y.contains(where: { abs($0.on - nn.on) <= 0.05 && ($0.pitch - nn.pitch) % 12 == 0 }) { octTp += 1 }
        }
        let p = x.isEmpty ? 0 : Double(tp) / Double(x.count), r = y.isEmpty ? 0 : Double(tp) / Double(y.count)
        print(String(format: "%@ notes: F1 %.3f (%d vs %d; %d more match an octave off)", role, p + r > 0 ? 2 * p * r / (p + r) : 0, x.count, y.count, octTp))
    }
}

func majMinClass(_ q: String) -> String? {
    switch q {
    case "maj", "7", "maj7", "6": return "maj"
    case "min", "min7", "min6": return "min"
    default: return nil
    }
}

// MARK: - Main

let argv = Array(CommandLine.arguments.dropFirst())
do {
    switch argv.first {
    case "inspect": try inspectCommand(Array(argv.dropFirst()))
    case "align": try alignCommand(Array(argv.dropFirst()), withTruth: false)
    case "truth": try alignCommand(Array(argv.dropFirst()), withTruth: true)
    case "pick": try pickCommand(Array(argv.dropFirst()))
    case "song": try songCommand(Array(argv.dropFirst()))
    case "validate": try validateCommand(Array(argv.dropFirst()))
    case "peakcheck": try peakCheckCommand(Array(argv.dropFirst()))
    case "lagprofile": try lagProfileCommand(Array(argv.dropFirst()))
    case "chordcheck": try chordCheckCommand(Array(argv.dropFirst()))
    case "compare": try compareCommand(Array(argv.dropFirst()))
    case "octave":
        // Debug: octave check for a MIDI (or a key) against a recording, every voice with its suggested role.
        let a = Array(argv.dropFirst())
        let af = try loadAudioFeatures(a[0])
        let m = try loadBMMidi(a[1])
        let s = try alignSong(af: af, midi: m, p: try params(from: Array(a.dropFirst(2))))
        for l in octaveCheck(m: s.midi, res: s.res, af: af, semitones: s.semitones, ignore: []) { print(l) }
    default: print(usage); exit(argv.isEmpty || argv.first == "help" || argv.first == "-h" ? 0 : 2)
    }
} catch {
    log("bitmidi: \(error)")
    exit(1)
}
