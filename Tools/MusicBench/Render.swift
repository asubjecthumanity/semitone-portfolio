import AVFoundation
import AudioToolbox

// Offline renderer: plays a `GeneratedSong` through Apple's General MIDI bank and returns
// the mono mix plus labels for the sampler schedule and arrangement.
//
// AVAudioEngine runs in offline manual-rendering mode with one AVAudioUnitSampler per part.
// Rendering advances in 64-frame slices (1.45 ms at 44.1 kHz). Before each slice, every
// note-on/off whose time falls inside it is sent. The labels record that slice-start
// command time. Audible onset/decay also depends on the sampler, instrument envelope
// and effects; it is not measured by the scheduler.
//
// Each part is first rendered on its own. That proves it makes sound and measures its level,
// so the mix can set the parts at their intended relative levels (the GM instruments differ
// by more than 10 dB). Then the full mix is rendered (through a reverb for some songs),
// averaged to mono and normalized to -1 dBFS peak.

/// Apple's General MIDI (Roland GS) sound bank, which ships with macOS.
enum SoundBank {
    static let url = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")

    /// MIDI channel for drum notes. The sampler takes its kit from the loaded bank
    /// (percussion bank MSB 120, program 0), not from the channel: channels 0 and 9 render
    /// identically. 9 is used because it's the General MIDI drum channel.
    static let drumChannel: UInt8 = 9
    static let melodicChannel: UInt8 = 0
}

struct RenderOptions {
    var sampleRate = 44_100.0
    /// Frames per render slice; sampler commands are sent at slice starts.
    var sliceFrames = 64
    /// Peak level of the normalized mix.
    var peakDBFS = -1.0
    /// A part whose solo RMS is below this (dBFS) is treated as silent.
    var silenceDBFS = -80.0
}

struct RenderedSong {
    /// Mono mix at `RenderOptions.sampleRate`, normalized.
    var samples: [Float]
    var truth: SongTruth
    /// RMS of each part rendered alone while it plays (dBFS, before mixing), in `parts` order.
    var soloRMSdB: [Double]
    /// Mixer volume given to each part.
    var gains: [Float]
    /// Notes left out because slice quantization made them empty (expected: 0).
    var droppedNotes: Int
}

enum RenderError: Error, CustomStringConvertible {
    case soundBankMissing
    case engine(String)
    case silentPart(String)
    case silentMix
    case invalidTruth([String])

    var description: String {
        switch self {
        case .soundBankMissing: "General MIDI bank not found at \(SoundBank.url.path)"
        case .engine(let message): "audio engine: \(message)"
        case .silentPart(let message): "silent part: \(message)"
        case .silentMix: "the mix is silent"
        case .invalidTruth(let problems): "ground truth fails its checks:\n  " + problems.joined(separator: "\n  ")
        }
    }
}

final class SongRenderer {
    let options: RenderOptions
    private let stereo: AVAudioFormat

    init(options: RenderOptions = RenderOptions()) throws {
        guard FileManager.default.fileExists(atPath: SoundBank.url.path) else { throw RenderError.soundBankMissing }
        self.options = options
        stereo = AVAudioFormat(standardFormatWithSampleRate: options.sampleRate, channels: 2)!
    }

    func render(_ song: GeneratedSong) throws -> RenderedSong {
        let schedule = Schedule(song: song, options: options)
        let tailFrames = Int((SongLimits.tail * options.sampleRate).rounded())
        let frameCount = schedule.lastSlice * options.sliceFrames + tailFrames

        // Solo pass: every part must sound, and its level sets its mixer gain.
        var soloRMS: [Double] = []
        for part in song.parts.indices {
            let solo = try renderPass(song: song, schedule: schedule, parts: [part], gains: [1], reverb: nil,
                                      frameCount: frameCount)
            let (first, last) = schedule.activeFrames(of: part, options: options)
            let active = solo[min(first, solo.count)..<min(last, solo.count)]
            let rms = sqrt(active.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(active.count, 1)))
            let db = 20 * log10(max(rms, 1e-12))
            guard db > options.silenceDBFS else {
                throw RenderError.silentPart("\(song.name) \(song.parts[part].kind.rawValue) (program \(song.parts[part].program)): \(String(format: "%.1f", db)) dBFS")
            }
            soloRMS.append(rms)
        }

        // Gains that put each part at its level relative to the others. AVAudioMixing
        // volume is 0...1, so the loudest-needed part gets 1 and the rest scale down.
        var gains = zip(song.parts, soloRMS).map { pow(10, $0.levelDB / 20) / $1 }
        let maxGain = gains.max()!
        gains = gains.map { $0 / maxGain }
        let floatGains = gains.map { Float($0) }

        var mix = try renderPass(song: song, schedule: schedule, parts: Array(song.parts.indices), gains: floatGains,
                                 reverb: song.reverb, frameCount: frameCount)
        let peak = mix.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 1e-4 else { throw RenderError.silentMix }
        let scale = Float(pow(10, options.peakDBFS / 20)) / peak
        for i in mix.indices { mix[i] *= scale }

        let truth = schedule.truth(for: song, duration: Double(frameCount) / options.sampleRate, options: options)
        let problems = truth.problems()
        guard problems.isEmpty else { throw RenderError.invalidTruth(problems) }
        return RenderedSong(samples: mix, truth: truth, soloRMSdB: soloRMS.map { 20 * log10($0) }, gains: floatGains,
                            droppedNotes: schedule.dropped)
    }

    /// Renders `parts` of the song (mono, `frameCount` frames).
    private func renderPass(song: GeneratedSong, schedule: Schedule, parts: [Int], gains: [Float],
                            reverb: ReverbSpec?, frameCount: Int) throws -> [Float] {
        let engine = AVAudioEngine()
        do {
            // Samplers -> submix -> [reverb] -> main mixer -> output.
            let submix = AVAudioMixerNode()
            engine.attach(submix)
            if let reverb {
                let unit = AVAudioUnitReverb()
                unit.loadFactoryPreset(reverb.room.preset)
                unit.wetDryMix = Float(reverb.wetDryMix)
                engine.attach(unit)
                try engine.connectNode(submix, to: unit, format: stereo)
                try engine.connectNode(unit, to: engine.mainMixerNode, format: stereo)
            } else {
                try engine.connectNode(submix, to: engine.mainMixerNode, format: stereo)
            }

            var samplers: [Int: AVAudioUnitSampler] = [:]
            for (part, gain) in zip(parts, gains) {
                let sampler = AVAudioUnitSampler()
                engine.attach(sampler)
                try engine.connectNode(sampler, to: submix, fromBus: 0, toBus: submix.nextAvailableInputBus, format: stereo)
                sampler.volume = gain
                samplers[part] = sampler
            }

            try engine.enableManualRenderingMode(.offline, format: stereo, maximumFrameCount: AVAudioFrameCount(options.sliceFrames))
            for (part, sampler) in samplers {
                let spec = song.parts[part]
                let drums = spec.kind == .drums
                try sampler.loadSoundBankInstrument(
                    at: SoundBank.url, program: UInt8(spec.program),
                    bankMSB: UInt8(drums ? kAUSampler_DefaultPercussionBankMSB : kAUSampler_DefaultMelodicBankMSB),
                    bankLSB: UInt8(kAUSampler_DefaultBankLSB))
            }
            try engine.start()
            defer { engine.stop() }

            guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                                frameCapacity: AVAudioFrameCount(options.sliceFrames)) else {
                throw RenderError.engine("could not allocate the render buffer")
            }
            var mono = [Float](repeating: 0, count: frameCount)
            var next = 0
            var frame = 0
            var slice = 0
            while frame < frameCount {
                // Apply this slice's events (note-offs first; see Schedule).
                while next < schedule.events.count && schedule.events[next].slice == slice {
                    let event = schedule.events[next]
                    next += 1
                    guard let sampler = samplers[event.part] else { continue }
                    let channel = song.parts[event.part].kind == .drums ? SoundBank.drumChannel : SoundBank.melodicChannel
                    if event.isOn {
                        sampler.startNote(event.pitch, withVelocity: event.velocity, onChannel: channel)
                    } else {
                        sampler.stopNote(event.pitch, onChannel: channel)
                    }
                }
                let status = try engine.renderOffline(AVAudioFrameCount(options.sliceFrames), to: buffer)
                guard status == .success else { throw RenderError.engine("renderOffline returned \(status.rawValue)") }
                let left = buffer.floatChannelData![0]
                let right = buffer.floatChannelData![1]
                let count = min(Int(buffer.frameLength), frameCount - frame)
                for i in 0..<count { mono[frame + i] = (left[i] + right[i]) * 0.5 }
                frame += Int(buffer.frameLength)
                slice += 1
            }
            return mono
        } catch let error as RenderError {
            throw error
        } catch {
            throw RenderError.engine("\(error)")
        }
    }
}

extension ReverbRoom {
    var preset: AVAudioUnitReverbPreset {
        switch self {
        case .smallRoom: .smallRoom
        case .mediumRoom: .mediumRoom
        case .largeRoom: .largeRoom
        }
    }
}

// MARK: - Event schedule

/// The song's notes quantized to render slices: each command is sent at the start of the
/// slice its time falls in.
private struct Schedule {
    struct Event {
        var slice: Int
        var part: Int
        var pitch: UInt8
        var velocity: UInt8
        var isOn: Bool
    }

    /// Sorted by slice; within a slice note-offs come first, so a key that is released and
    /// struck again in the same slice ends up sounding.
    var events: [Event] = []
    var onSlice: [Int]
    var offSlice: [Int]
    var kept: [Bool]
    /// Slice of the last event (the tail starts there).
    var lastSlice = 0
    var dropped = 0

    init(song: GeneratedSong, options: RenderOptions) {
        let slicesPerSecond = options.sampleRate / Double(options.sliceFrames)
        let notes = song.notes
        onSlice = notes.map { Int(($0.on * slicesPerSecond).rounded(.down)) }
        offSlice = notes.indices.map { i in max(Int((notes[i].off * slicesPerSecond).rounded(.down)), 0) }
        kept = Array(repeating: true, count: notes.count)

        // One key of one sampler never holds two notes: the earlier ends where the next
        // starts. (The generator already guarantees this; quantization must not undo it.)
        var byKey: [Int: [Int]] = [:]
        for (i, note) in notes.enumerated() { byKey[note.part * 128 + note.pitch, default: []].append(i) }
        for indices in byKey.values {
            let sorted = indices.sorted { (onSlice[$0], $0) < (onSlice[$1], $1) }
            for (a, b) in zip(sorted, sorted.dropFirst()) { offSlice[a] = min(offSlice[a], onSlice[b]) }
        }
        // A note must last at least one slice to sound. (Notes are >= 25 ms, so this only
        // happens if two notes of one key start in the same slice; the earlier is dropped.)
        for i in notes.indices where offSlice[i] <= onSlice[i] {
            kept[i] = false
            dropped += 1
        }

        for (i, note) in notes.enumerated() where kept[i] {
            events.append(Event(slice: onSlice[i], part: note.part, pitch: UInt8(note.pitch), velocity: UInt8(note.velocity), isOn: true))
            events.append(Event(slice: offSlice[i], part: note.part, pitch: UInt8(note.pitch), velocity: 0, isOn: false))
        }
        events.sort { ($0.slice, $0.isOn ? 1 : 0, $0.part, $0.pitch) < ($1.slice, $1.isOn ? 1 : 0, $1.part, $1.pitch) }
        lastSlice = events.last?.slice ?? 0
    }

    /// Frames from the part's first note-on to 0.25 s after its last note-off.
    func activeFrames(of part: Int, options: RenderOptions) -> (Int, Int) {
        var first = Int.max, last = 0
        for event in events where event.part == part {
            first = min(first, event.slice)
            last = max(last, event.slice)
        }
        return (first * options.sliceFrames, last * options.sliceFrames + Int(options.sampleRate / 4))
    }

    /// Scheduled labels, with command times at their slice starts. Acoustic
    /// onset/release boundaries are not measured here.
    func truth(for song: GeneratedSong, duration: Double, options: RenderOptions) -> SongTruth {
        func seconds(_ slice: Int) -> Double { Double(slice * options.sliceFrames) / options.sampleRate }
        var notes: [TruthNote] = []
        var drums: [TruthDrum] = []
        for (i, note) in song.notes.enumerated() where kept[i] {
            let part = song.parts[note.part]
            if let role = part.kind.role {
                notes.append(TruthNote(pitch: note.pitch, on: seconds(onSlice[i]), off: seconds(offSlice[i]),
                                       velocity: note.velocity, role: role, program: part.program))
            } else {
                drums.append(TruthDrum(time: seconds(onSlice[i]), gmNote: note.pitch, velocity: note.velocity))
            }
        }
        notes.sort { ($0.on, $0.pitch) < ($1.on, $1.pitch) }
        drums.sort { ($0.time, $0.gmNote) < ($1.time, $1.gmNote) }
        return SongTruth(
            name: song.name, style: song.style.rawValue, bpm: song.bpm, beatsPerBar: song.beatsPerBar,
            duration: duration, keyRoot: song.key.tonic, keyMode: song.key.mode, notes: notes, drums: drums,
            beats: song.beats, downbeats: song.downbeats, chords: song.chords, reverb: song.reverb != nil)
    }
}

// MARK: - Checks

extension SongTruth {
    /// Checks the ground-truth contract; returns one line per violation (empty when valid).
    func problems() -> [String] {
        var problems: [String] = []
        if !SongLimits.duration.contains(duration) {
            problems.append(String(format: "duration %.2f s outside %.0f-%.0f s", duration,
                                   SongLimits.duration.lowerBound, SongLimits.duration.upperBound))
        }
        for note in notes {
            let range = switch note.role {
            case .melody: SongLimits.melody
            case .chords: SongLimits.chords
            case .bass: SongLimits.bass
            }
            if !range.contains(note.pitch) { problems.append("\(note.role.rawValue) pitch \(note.pitch) at \(note.on) out of range") }
            if !(note.on >= 0 && note.off > note.on && note.off <= duration) {
                problems.append("\(note.role.rawValue) note \(note.pitch) has bad times \(note.on)-\(note.off)")
            }
            if !(1...127).contains(note.velocity) { problems.append("velocity \(note.velocity) at \(note.on)") }
        }

        // The melody is strictly monophonic with a clear gap between notes.
        let melody = notes.filter { $0.role == .melody }.sorted { $0.on < $1.on }
        for (a, b) in zip(melody, melody.dropFirst()) where b.on - a.off < SongLimits.melodyGap - 1e-9 {
            problems.append(String(format: "melody gap %.1f ms at %.3f s", (b.on - a.off) * 1000, b.on))
        }
        // No key of one instrument holds two notes at once.
        var byKey: [String: [TruthNote]] = [:]
        for note in notes { byKey["\(note.role.rawValue)/\(note.pitch)", default: []].append(note) }
        for (key, group) in byKey {
            let sorted = group.sorted { $0.on < $1.on }
            for (a, b) in zip(sorted, sorted.dropFirst()) where b.on < a.off - 1e-9 {
                problems.append("overlapping \(key) at \(b.on)")
            }
        }

        for drum in drums where !(35...81).contains(drum.gmNote) || drum.time < 0 || drum.time > duration {
            problems.append("bad drum hit \(drum.gmNote) at \(drum.time)")
        }
        if zip(beats, beats.dropFirst()).contains(where: { $1 <= $0 }) { problems.append("beats not increasing") }
        if !Set(downbeats).isSubset(of: Set(beats)) || downbeats.first != beats.first {
            problems.append("downbeats are not bar starts")
        }
        let qualities: Set<String> = ["maj", "min", "7", "maj7", "min7", "dim", "m7b5", "sus4", "sus2", "6", "min6", "aug"]
        for (a, b) in zip(chords, chords.dropFirst()) where abs(b.start - a.end) > 1e-9 {
            problems.append("chord spans not contiguous at \(a.end)")
        }
        for chord in chords where !qualities.contains(chord.quality) || !(0...11).contains(chord.root) || chord.end <= chord.start {
            problems.append("bad chord \(chord.label) at \(chord.start)")
        }
        return problems
    }
}

// MARK: - Output

enum AudioWriter {
    /// Writes mono float samples as a 16-bit PCM WAV file.
    static func writeWAV(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 1 << 15
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(chunk)) else {
            throw RenderError.engine("could not allocate the file buffer")
        }
        var offset = 0
        while offset < samples.count {
            let count = min(chunk, samples.count - offset)
            samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress! + offset, count: count)
            }
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
            offset += count
        }
        file.close()
    }
}
