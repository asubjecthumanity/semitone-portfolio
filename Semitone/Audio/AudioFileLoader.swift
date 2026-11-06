import Foundation
import Accelerate
@preconcurrency import AVFoundation

/// Loads any audio file AVFoundation can read as mono Float32.
nonisolated enum AudioFileLoader {
    /// 22050 Hz, for the Basic Pitch live/preview engine. Keeps the first
    /// channel only: on the stereo piano reference a true mix raised Basic
    /// Pitch's overtone ghosts (onset F1 0.845 -> 0.815). Mixes instead when
    /// the first channel is (nearly) empty, e.g. a mic on input 2 or a part
    /// panned hard right, which channel 0 alone would hear as silence.
    static func loadMono22k(url: URL) throws -> [Float] {
        let mix = try firstChannelIsQuiet(url: url)
        return try loadMono(url: url, sampleRate: BPConstants.sampleRate, downmix: mix)
    }

    /// True when a multichannel file's first channel holds under 1/1000
    /// (-30 dB) of its loudest channel's energy, over the whole file.
    static func firstChannelIsQuiet(url: URL) throws -> Bool {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        guard channels > 1 else { return false }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65536) else {
            throw audioError("Could not allocate channel analysis buffer")
        }
        var energy = [Double](repeating: 0, count: channels)
        while true {
            try readChunk(from: file, into: buffer)
            if buffer.frameLength == 0 { break }
            addChannelEnergy(of: buffer, to: &energy)
        }
        return firstChannelIsQuiet(energy: energy)
    }

    /// The -30 dB test on accumulated per-channel energies (also used live by MicRecorder).
    static func firstChannelIsQuiet(energy: [Double]) -> Bool {
        guard energy.count > 1, let loudest = energy.max(), loudest > 0 else { return false }
        return energy[0] * 1000 < loudest
    }

    /// Adds each channel's sum of squares in a float buffer to `energy`.
    static func addChannelEnergy(of buffer: AVAudioPCMBuffer, to energy: inout [Double]) {
        guard let data = buffer.floatChannelData, energy.count == Int(buffer.format.channelCount) else { return }
        let interleaved = buffer.format.isInterleaved
        for channel in energy.indices {
            var sum: Float = 0
            vDSP_svesq(interleaved ? data[0] + channel : data[channel], buffer.stride, &sum, vDSP_Length(buffer.frameLength))
            energy[channel] += Double(sum)
        }
    }

    /// `downmix` mixes all channels; otherwise AVAudioConverter keeps the first.
    static func loadMono(url: URL, sampleRate: Double, downmix: Bool = true) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        return try convertMono(from: file.processingFormat, to: sampleRate, downmix: downmix,
                               estimatedInputFrames: Double(file.length)) { buffer in
            try readChunk(from: file, into: buffer)
        }
    }

    /// One chunk of a file; frameLength 0 at the end. Never asks past the
    /// declared length: at the end AVAudioFile fails instead of returning an
    /// empty read (eofErr -39 on macOS, an error without an NSError on iOS).
    /// A read inside the declared range that fails or comes back empty
    /// throws, so a truncated or unreadable file is an error, not a prefix.
    private static func readChunk(from file: AVAudioFile, into buffer: AVAudioPCMBuffer) throws {
        let remaining = file.length - file.framePosition
        guard remaining > 0 else {
            buffer.frameLength = 0
            return
        }
        let count = AVAudioFrameCount(min(remaining, AVAudioFramePosition(buffer.frameCapacity)))
        try file.read(into: buffer, frameCount: count)
        guard buffer.frameLength > 0 else {
            throw audioError("Audio file ended before its declared frame count")
        }
    }

    /// Shared file/in-memory conversion. A zero-length read is EOF; a failed
    /// read must throw. The input block cannot throw, so it records the error
    /// and the caller rethrows it before accepting that conversion's output.
    static func convertMono(from inFormat: AVAudioFormat, to sampleRate: Double,
                            downmix: Bool = true, estimatedInputFrames: Double = 0,
                            readInput: @escaping (AVAudioPCMBuffer) throws -> Void) throws -> [Float] {
        guard inFormat.sampleRate.isFinite, inFormat.sampleRate > 0,
              sampleRate.isFinite, sampleRate > 0 else {
            throw audioError("Invalid audio sample rate")
        }
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw audioError("Unsupported audio format")
        }
        converter.downmix = downmix

        let inCapacity: AVAudioFrameCount = 65536
        let outputCapacity = ceil(Double(inCapacity) * sampleRate / inFormat.sampleRate) + 1024
        guard outputCapacity.isFinite, outputCapacity <= Double(AVAudioFrameCount.max) else {
            throw audioError("Unsupported audio conversion ratio")
        }
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: inCapacity),
              let outBuffer = AVAudioPCMBuffer(
                pcmFormat: outFormat,
                frameCapacity: AVAudioFrameCount(outputCapacity)
              ) else {
            throw audioError("Could not allocate audio buffers")
        }

        var samples: [Float] = []
        // Reserve a bounded prefix; a long file should not cause an enormous
        // up-front allocation solely because of its reported frame count.
        let estimate = estimatedInputFrames * sampleRate / inFormat.sampleRate
        if estimate.isFinite, estimate > 0 { samples.reserveCapacity(Int(min(estimate, 1_000_000))) }
        var reachedEnd = false
        var inputError: Error?
        var inputFrames = 0
        var stalledConversions = 0

        while true {
            let previousInputFrames = inputFrames
            outBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
                if reachedEnd {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                inBuffer.frameLength = 0
                do {
                    try readInput(inBuffer)
                } catch {
                    inputError = error
                    reachedEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if inBuffer.frameLength == 0 {
                    reachedEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                inputFrames += Int(inBuffer.frameLength)
                outStatus.pointee = .haveData
                return inBuffer
            }
            if let inputError { throw inputError }
            try checkConversion(status, error: conversionError)
            if outBuffer.frameLength > 0 {
                guard let data = outBuffer.floatChannelData else {
                    throw audioError("Audio converter returned an unsupported buffer")
                }
                samples.append(contentsOf: UnsafeBufferPointer(
                    start: data[0],
                    count: Int(outBuffer.frameLength)
                ))
            }
            if status == .endOfStream { break }
            // A buffered converter may consume input without emitting samples.
            // Do not mistake that for EOF, but also do not spin indefinitely.
            if inputFrames == previousInputFrames, outBuffer.frameLength == 0 {
                stalledConversions += 1
                if stalledConversions >= 8 { throw audioError("Audio conversion stopped making progress") }
            } else {
                stalledConversions = 0
            }
        }
        return samples
    }
    /// Mono audio at another sample rate (e.g. a 44.1 kHz take to the 22050 Hz
    /// Basic Pitch rate), with the same converter the file loader uses.
    static func resampleMono(_ samples: [Float], from inRate: Double, to outRate: Double) throws -> [Float] {
        guard inRate.isFinite, inRate > 0, outRate.isFinite, outRate > 0 else {
            throw audioError("Invalid audio sample rate")
        }
        guard !samples.isEmpty, inRate != outRate else { return samples }
        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inRate,
                                          channels: 1, interleaved: false) else {
            throw audioError("Unsupported audio format")
        }
        var offset = 0
        return try convertMono(from: inFormat, to: outRate, estimatedInputFrames: Double(samples.count)) { buffer in
            let count = min(Int(buffer.frameCapacity), samples.count - offset)
            guard let data = buffer.floatChannelData else {
                throw audioError("Could not access resampling buffer")
            }
            if count > 0 {
                samples.withUnsafeBufferPointer { src in
                    data[0].update(from: src.baseAddress! + offset, count: count)
                }
            }
            buffer.frameLength = AVAudioFrameCount(count)
            offset += count
        }
    }

    /// AVAudioConverter can report .error without filling its NSError pointer.
    static func checkConversion(_ status: AVAudioConverterOutputStatus, error: NSError?) throws {
        if let error { throw error }
        if status == .error { throw audioError("Audio conversion failed") }
    }

    static func audioError(_ message: String) -> NSError {
        NSError(domain: "Semitone", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
