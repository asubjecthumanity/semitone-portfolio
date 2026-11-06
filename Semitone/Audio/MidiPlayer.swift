import Foundation
import AudioToolbox
import AVFoundation

/// Plays a take through a sampled grand piano (GrandPiano.sf2: YDP Grand
/// Piano from FreePats, CC BY 3.0, slimmed by Tools/PianoSound/slim_sf2.py),
/// including the sustain pedal the piano model detected.
@MainActor
final class MidiPlayer {
    /// How a note's `amplitude` maps to MIDI velocity.
    enum Dynamics {
        /// Piano model notes: amplitude is the detected velocity / 127.
        case detected
        /// Quick-detector notes: amplitude is an activation, so floor it to keep quiet notes audible.
        case activation
    }

    private let engine = AVAudioEngine()
    private let sampler = AVAudioUnitSampler()
    private var sequencer: AVAudioSequencer?
    private var pianoLoaded = false
    /// The loaded take's pedal, to put the pedal down when playback starts inside a press.
    private var sustain: [PedalEvent] = []
    /// Sequencer track per part: parts are muted in place, because
    /// restarting the sequence would cut every held note.
    private var voiceTracks: [Voice: Int] = [:]
    /// When each loaded note sounds (after the re-strike clamp), to release a
    /// part's held notes the moment it's muted.
    private var spans: [(start: Double, end: Double, pitch: Int, voice: Voice)] = []
    private var hiddenVoices: Set<Voice> = []
    private var idleStop: DispatchWorkItem?
    private(set) var duration: Double = 0

    /// Times are converted to beats at 120 BPM (2 beats per second), and that
    /// tempo is written into the sequence.
    private let beatsPerSecond = 2.0

    init() {
        engine.attach(sampler)
        engine.connect(sampler, to: engine.mainMixerNode, format: nil)
        sampler.overallGain = 6   // the samples are recorded quiet
    }

    func load(notes: [NoteEvent], sustain: [PedalEvent] = [], dynamics: Dynamics = .activation) {
        unload()
        guard !notes.isEmpty else { return }
        loadPianoIfNeeded()
        guard let built = midiData(notes: notes, sustain: sustain, dynamics: dynamics) else { return }
        let sequencer = AVAudioSequencer(audioEngine: engine)
        do {
            try sequencer.load(from: built.data, options: [])
        } catch {
            NSLog("Semitone: couldn't load playback: %@", error.localizedDescription)
            return
        }
        for track in sequencer.tracks { track.destinationAudioUnit = sampler }
        voiceTracks = built.voiceTracks
        spans = built.spans
        sequencer.prepareToPlay()
        self.sequencer = sequencer
        self.sustain = sustain
        applyMutes()
        let noteEnd = notes.map(\.endTime).max() ?? 0
        let pedalEnd = sustain.map(\.endTime).max() ?? 0
        duration = max(noteEnd, pedalEnd) + Self.releaseTail
    }

    /// Returns false if audio couldn't start (e.g. no output device).
    @discardableResult
    func play(from time: Double) -> Bool {
        guard let sequencer else { return false }
        idleStop?.cancel()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback)
        try? session.setActive(true)
        do {
            // A running engine may still be ringing from the last play. A cold one
            // has nothing to reset, and messages sent right after starting it land
            // after the sequencer's first ~20 ms of events, cancelling them.
            if engine.isRunning { silence() } else { try engine.start() }
            // The sequencer doesn't replay controller state on a seek, so starting
            // inside a pedal press would play dry until the next press. (The margin
            // keeps this from overriding a release right after the start point.)
            if sustain.contains(where: { $0.startTime < time && $0.endTime > time + 0.05 }) {
                sampler.sendController(64, withValue: 127, onChannel: 0)
            }
            sequencer.currentPositionInSeconds = time
            try sequencer.start()
            return true
        } catch {
            NSLog("Semitone: couldn't start playback: %@", error.localizedDescription)
            return false
        }
    }

    func stop() {
        guard let sequencer else { return }
        sequencer.stop()
        silence()
        // Let released notes ring out, then stop the audio engine to save power.
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.sequencer?.isPlaying != true else { return }
            self.engine.pause()
        }
        idleStop?.cancel()
        idleStop = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.releaseTail, execute: item)
    }

    /// Silences parts without stopping the others.
    func setHidden(_ voices: Set<Voice>) {
        let newlyHidden = voices.subtracting(hiddenVoices)
        hiddenVoices = voices
        applyMutes()
        // A muted track drops its note-offs too, so release what's held now
        // (unless a part still playing holds the same key).
        guard let sequencer, sequencer.isPlaying else { return }
        let now = sequencer.currentPositionInSeconds
        let sounding = spans.filter { $0.start <= now && $0.end > now }
        let stillHeld = Set(sounding.filter { !voices.contains($0.voice) }.map(\.pitch))
        for span in sounding where newlyHidden.contains(span.voice) && !stillHeld.contains(span.pitch) {
            sampler.stopNote(UInt8(span.pitch), onChannel: 0)
        }
    }

    private func applyMutes() {
        guard let sequencer else { return }
        let tracks = sequencer.tracks
        for (voice, index) in voiceTracks where index < tracks.count {
            tracks[index].isMuted = hiddenVoices.contains(voice)
        }
    }

    var isPlaying: Bool { sequencer?.isPlaying ?? false }

    var currentTime: Double { sequencer?.currentPositionInSeconds ?? 0 }

    /// Pedal up and all notes off; held notes release naturally rather than cut.
    private func silence() {
        sampler.sendController(64, withValue: 0, onChannel: 0)
        sampler.sendController(123, withValue: 0, onChannel: 0)
    }

    private func loadPianoIfNeeded() {
        guard !pianoLoaded else { return }
        guard let url = Bundle.main.url(forResource: "GrandPiano", withExtension: "sf2") else {
            NSLog("Semitone: GrandPiano.sf2 is missing from the app bundle")
            return
        }
        do {
            try sampler.loadSoundBankInstrument(at: url, program: 0,
                                                bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB),
                                                bankLSB: UInt8(kAUSampler_DefaultBankLSB))
            pianoLoaded = true
        } catch {
            NSLog("Semitone: couldn't load the piano sound: %@", error.localizedDescription)
        }
    }

    /// Keep the sequence running through final pedal-up, then let samples decay.
    /// Manual Stop still releases immediately; only natural completion waits.
    private static let releaseTail = 1.5

    /// A standard MIDI file: tempo, then one track per part present (channel
    /// volume, the sustain pedal on the piano part, notes).
    private func midiData(notes: [NoteEvent], sustain: [PedalEvent], dynamics: Dynamics)
        -> (data: Data, voiceTracks: [Voice: Int], spans: [(start: Double, end: Double, pitch: Int, voice: Voice)])? {
        var seq: MusicSequence?
        guard NewMusicSequence(&seq) == noErr, let seq else { return nil }
        defer { DisposeMusicSequence(seq) }

        var tempoTrack: MusicTrack?
        if MusicSequenceGetTempoTrack(seq, &tempoTrack) == noErr, let tempoTrack {
            MusicTrackNewExtendedTempoEvent(tempoTrack, 0, beatsPerSecond * 60)
        }

        func controller(_ track: MusicTrack, _ number: UInt8, _ value: UInt8, at seconds: Double) {
            var message = MIDIChannelMessage(status: 0xB0, data1: number, data2: value, reserved: 0)
            _ = withUnsafePointer(to: &message) { MusicTrackNewMIDIChannelEvent(track, seconds * beatsPerSecond, $0) }
        }

        let present = Voice.allCases.filter { voice in notes.contains { $0.voice == voice } }
        var tracks: [Voice: MusicTrack] = [:]
        var voiceTracks: [Voice: Int] = [:]
        for (i, voice) in present.enumerated() {
            var track: MusicTrack?
            guard MusicSequenceNewTrack(seq, &track) == noErr, let track else { return nil }
            controller(track, 7, 127, at: 0)   // channel volume
            tracks[voice] = track
            voiceTracks[voice] = i
        }
        if let pedalTrack = tracks[.none] ?? present.first.flatMap({ tracks[$0] }) {
            for pedal in sustain {
                controller(pedalTrack, 64, 127, at: pedal.startTime)
                controller(pedalTrack, 64, 0, at: pedal.endTime)
            }
        }

        // Notes get at least 30 ms, but a note must end before the same key
        // strikes again (in any part: they share the piano), or its note-off
        // would release the new note. (Clamp after the minimum; a blip right
        // before a re-strike is dropped.)
        var spans: [(start: Double, end: Double, pitch: Int, voice: Voice)] = []
        let sorted = notes.sorted { ($0.pitch, $0.startTime) < ($1.pitch, $1.startTime) }
        for (i, note) in sorted.enumerated() where (0...127).contains(note.pitch) {
            var length = max(0.03, note.endTime - note.startTime)
            if i + 1 < sorted.count, sorted[i + 1].pitch == note.pitch {
                length = min(length, sorted[i + 1].startTime - 0.002 - note.startTime)
            }
            guard length > 0.001, let track = tracks[note.voice] else { continue }
            let velocity: Int
            switch dynamics {
            case .detected: velocity = Int((note.amplitude * 127).rounded())
            case .activation: velocity = Int(note.amplitude * 95) + 38
            }
            var message = MIDINoteMessage(
                channel: 0,
                note: UInt8(clamping: note.pitch),
                velocity: UInt8(clamping: max(1, min(127, velocity))),
                releaseVelocity: 0,
                duration: Float(length * beatsPerSecond)
            )
            MusicTrackNewMIDINoteEvent(track, note.startTime * beatsPerSecond, &message)
            spans.append((note.startTime, note.startTime + length, note.pitch, note.voice))
        }

        var data: Unmanaged<CFData>?
        guard MusicSequenceFileCreateData(seq, .midiType, .eraseFile, 480, &data) == noErr, let data else { return nil }
        return (data.takeRetainedValue() as Data, voiceTracks, spans)
    }

    private func unload() {
        sequencer?.stop()
        sequencer = nil
        sustain = []
        voiceTracks = [:]
        spans = []
        duration = 0
    }
}
