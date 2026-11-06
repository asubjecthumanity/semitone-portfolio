import Foundation
import Synchronization
import Accelerate
@preconcurrency import AVFoundation

/// Captures microphone audio as mono Float32 at two rates: 22050 Hz for the
/// live Basic Pitch preview and 44100 Hz for the piano model's final pass.
/// onSamples is called on the audio render thread.
nonisolated final class MicRecorder {
    /// Replaced after a media-services reset, which orphans the old engine.
    private var engine = AVAudioEngine()
    private var needsNewEngine = false
    private var resetObserver: NSObjectProtocol?
    private var previewConverter: AVAudioConverter?
    private var fullConverter: AVAudioConverter?
    private let previewFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: BPConstants.sampleRate, channels: 1, interleaved: false
    )!
    private let fullFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: PianoModel.sampleRate, channels: 1, interleaved: false
    )!
    private var downmixPreview = false
    /// Per-channel energy so far while the preview reads channel 0 of a
    /// multichannel input; empty once that's settled (or for mono input).
    private var channelEnergy: [Double] = []
    private var observers: [NSObjectProtocol] = []
    /// Between a successful start() and stop(). Main thread only.
    private var capturing = false
    /// One failure notification per tap. Captured by the render callback so a
    /// delayed failure from an old tap cannot stop a replacement tap/new take.
    private nonisolated final class TapState: Sendable {
        let failed = Atomic<Bool>(false)
    }
    private var tapState: TapState?
    /// The latest input buffer's RMS, as Float bits (written on the render thread).
    private let rmsBits = Atomic<UInt32>(0)

    /// The RMS of the latest input buffer (its loudest channel, linear, 0 when
    /// not capturing), for the record button's level meter. Any thread; reading
    /// it never touches the audio path.
    var inputRMS: Float { Float(bitPattern: rmsBits.load(ordering: .relaxed)) }

    /// (22050 Hz chunk, 44100 Hz chunk) of the same stretch of audio.
    var onSamples: ((_ preview: [Float], _ full: [Float]) -> Void)?

    /// Capture ended by itself (an interruption, a lost input, a media-services
    /// reset). Called on any thread, with a short lowercase reason that reads
    /// after "Recording stopped: ". The owner should call stop().
    var onStopped: ((String) -> Void)?

    init() {
        // For the recorder's lifetime: a reset between takes must still retire the engine.
        nonisolated(unsafe) weak let recorder = self
        resetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { _ in
            guard let recorder else { return }
            recorder.needsNewEngine = true
            if recorder.capturing { recorder.onStopped?("the audio system was reset") }
        }
    }

    deinit {
        if let resetObserver { NotificationCenter.default.removeObserver(resetObserver) }
    }

    /// `downmixPreview` mixes all input channels into the preview (any-instrument
    /// takes, like their file import); otherwise it reads channel 0, like a piano
    /// file import, falling back to a mix if channel 0 turns out to be silent.
    func start(downmixPreview: Bool = false) throws {
        // A second tap on the same bus is an uncaught AVAudioEngine exception.
        guard !engine.isRunning else { return }
        if needsNewEngine {
            engine = AVAudioEngine()
            needsNewEngine = false
        }
        let session = AVAudioSession.sharedInstance()
        #if targetEnvironment(simulator)
        // The simulator's audio input server aborts with an RPC timeout under
        // .measurement mode; keep the plain category there.
        try session.setCategory(.playAndRecord)
        #else
        // .measurement disables voice processing (AGC etc.) that distorts music.
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        #endif
        try session.setActive(true)

        self.downmixPreview = downmixPreview
        rmsBits.store(0, ordering: .relaxed)
        do {
            try installTap()
            engine.prepare()
            try engine.start()
        } catch {
            // Leave nothing installed, so the next start() begins clean.
            teardown()
            throw error
        }
        capturing = true
        observeSession()
    }

    func stop() {
        capturing = false
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        teardown()
    }

    private func teardown() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        previewConverter = nil
        fullConverter = nil
        tapState = nil
        rmsBits.store(0, ordering: .relaxed)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Builds the converters for the input's current format and (re)installs
    /// the tap. Only called while the engine is stopped.
    private func installTap() throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let inFormat = input.outputFormat(forBus: 0)
        guard let preview = AVAudioConverter(from: inFormat, to: previewFormat),
              let full = AVAudioConverter(from: inFormat, to: fullFormat) else {
            throw NSError(
                domain: "Semitone", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported microphone format"]
            )
        }
        preview.downmix = downmixPreview   // match file import (see AudioFileLoader.loadMono22k)
        full.downmix = true
        previewConverter = preview
        fullConverter = full
        let state = TapState()
        tapState = state
        channelEnergy = inFormat.channelCount > 1 && !downmixPreview
            ? [Double](repeating: 0, count: Int(inFormat.channelCount)) : []
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.handle(buffer, state: state)
        }
    }

    /// An interruption (call, alarm, Siri) or a hardware format change stops
    /// the engine, and the tap goes quiet while the UI still shows REC.
    private func observeSession() {
        let center = NotificationCenter.default
        // Posted on arbitrary threads. The recorder is already shared with the
        // tap thread; these only call onStopped or hop to the main queue.
        nonisolated(unsafe) weak let recorder = self
        for observer in observers { center.removeObserver(observer) }
        observers = [
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(), queue: nil
            ) { note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
                // On main, where start()/stop() run, so a late notice can't end the next take.
                DispatchQueue.main.async {
                    guard let recorder, recorder.capturing else { return }
                    recorder.onStopped?("the audio was interrupted")
                }
            },
            // Hop to main without blocking the engine's internal queue that posts it.
            center.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine, queue: nil
            ) { _ in
                DispatchQueue.main.async { recorder?.restartAfterConfigurationChange() }
            },
        ]
    }

    /// The input's sample rate or channel count changed (headset or interface
    /// plugged in or out) and the engine stopped itself. Carry on with
    /// converters for the new format, or end the take if that fails.
    private func restartAfterConfigurationChange() {
        guard capturing, !engine.isRunning else { return }
        do {
            try installTap()
            engine.prepare()
            try engine.start()
        } catch {
            onStopped?("the audio input changed")
        }
    }

    private func handle(_ buffer: AVAudioPCMBuffer, state: TapState) {
        guard !state.failed.load(ordering: .relaxed) else { return }
        // One vDSP pass and an atomic store; the meter samples it from the main actor.
        rmsBits.store(Self.rms(of: buffer).bitPattern, ordering: .relaxed)
        do {
            if !channelEnergy.isEmpty { try checkFirstChannel(buffer) }
            guard let previewConverter, let fullConverter, let onSamples else { return }
            let preview = try convert(buffer, with: previewConverter)
            let full = try convert(buffer, with: fullConverter)
            onSamples(preview, full)
        } catch {
            guard !state.failed.exchange(true, ordering: .relaxed) else { return }
            let reason = "audio conversion failed (\(error.localizedDescription))"
            nonisolated(unsafe) weak let recorder = self
            DispatchQueue.main.async {
                guard let recorder, recorder.capturing, recorder.tapState === state else { return }
                recorder.onStopped?(reason)
            }
        }
    }

    /// The RMS of the buffer's loudest channel (linear; 0 for an empty buffer).
    static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        // Interleaved audio has one pointer; read its first channel at the frame stride.
        let channels = buffer.format.isInterleaved ? 1 : Int(buffer.format.channelCount)
        var loudest: Float = 0
        for channel in 0..<channels {
            var rms: Float = 0
            vDSP_rmsqv(data[channel], vDSP_Stride(buffer.stride), &rms, vDSP_Length(buffer.frameLength))
            if rms.isFinite { loudest = max(loudest, rms) }
        }
        return loudest
    }

    /// Channel 0 more than 30 dB below another channel so far (the mic on
    /// input 2 of an interface): mix the preview from here on, or the take
    /// would transcribe as silence.
    private func checkFirstChannel(_ buffer: AVAudioPCMBuffer) throws {
        AudioFileLoader.addChannelEnergy(of: buffer, to: &channelEnergy)
        guard AudioFileLoader.firstChannelIsQuiet(energy: channelEnergy) else { return }
        guard let mixed = AVAudioConverter(from: buffer.format, to: previewFormat) else {
            throw AudioFileLoader.audioError("Could not configure microphone channel mixing")
        }
        mixed.downmix = true
        previewConverter = mixed
        channelEnergy = []
    }

    private func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) throws -> [Float] {
        let format = converter.outputFormat
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacityEstimate = ceil(Double(buffer.frameLength) * ratio) + 64
        guard ratio.isFinite, ratio > 0, capacityEstimate <= Double(AVAudioFrameCount.max) else {
            throw AudioFileLoader.audioError("Unsupported microphone conversion ratio")
        }
        let capacity = AVAudioFrameCount(capacityEstimate)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw AudioFileLoader.audioError("Could not allocate microphone conversion buffer")
        }

        var served = false
        var conversionError: NSError?
        let status = converter.convert(to: out, error: &conversionError) { _, outStatus in
            if served {
                outStatus.pointee = .noDataNow
                return nil
            }
            served = true
            outStatus.pointee = .haveData
            return buffer
        }
        try AudioFileLoader.checkConversion(status, error: conversionError)
        guard status != .endOfStream else {
            throw AudioFileLoader.audioError("Microphone converter ended unexpectedly")
        }
        // .inputRanDry with no output is legitimate converter buffering, not
        // a failure. The next tap buffer supplies more data.
        guard out.frameLength > 0 else { return [] }
        guard let data = out.floatChannelData else {
            throw AudioFileLoader.audioError("Microphone converter returned an unsupported buffer")
        }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }
}
