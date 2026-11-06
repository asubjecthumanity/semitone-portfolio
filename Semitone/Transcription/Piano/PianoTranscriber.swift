import Foundation
import CoreML
import Accelerate

/// The piano model's reading of a take: notes, plus when the sustain pedal was down.
nonisolated struct PianoTranscription {
    let notes: [NoteEvent]
    let sustain: [PedalEvent]
}

/// High-accuracy piano transcription (Transkun v2) for finished takes.
/// Feature extraction, interval decoding and segment stitching run in Swift;
/// the transformer backbone runs in Core ML. Expects 44.1 kHz mono audio.
nonisolated final class PianoTranscriber {
    private let model: MLModel
    private let features: PianoFeatureExtractor
    private let decoder: PianoDecoder
    private let input: MLMultiArray
    /// Features in fp32, converted into `input` when the model takes fp16.
    private var featureBuffer = [Float]()
    /// One symbol's embeddings in fp32 when Core ML doesn't hand back dense fp32.
    private var keyBuffer = [Float](repeating: 0, count: PianoModel.frames * PianoModel.ctxDim)

    /// Neural Engine (plus CPU) by default, never the GPU: on iOS 27 Core ML's
    /// GPU path (MPSGraph) aborts the app while compiling this model. The
    /// bundled model is fp16 apart from its last layer, which stays fp32 on the
    /// CPU; fully fp16 that layer costs real accuracy on the Neural Engine.
    init(modelURL: URL, weightsURL: URL, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        model = try MLModel(contentsOf: modelURL, configuration: configuration)
        let weights = try PianoWeights(url: weightsURL)
        features = PianoFeatureExtractor(weights: weights)
        decoder = PianoDecoder(weights: weights)
        let m = PianoModel.self
        let inputType = model.modelDescription.inputDescriptionsByName["features"]?.multiArrayConstraint?.dataType
        input = try MLMultiArray(shape: [1, NSNumber(value: m.frames), NSNumber(value: m.mels), NSNumber(value: m.windowCount)],
                                 dataType: inputType == .float16 ? .float16 : .float32)
        if input.dataType == .float16 { featureBuffer = [Float](repeating: 0, count: input.count) }
    }

    convenience init() throws {
        var name = "TranskunBackbone"
        var units = MLComputeUnits.cpuAndNeuralEngine
        #if DEBUG
        // Device experiments: SEMITONE_PIANO_MODEL=<bundled model>, SEMITONE_PIANO_UNITS=cpu|gpu|ane|all.
        let env = ProcessInfo.processInfo.environment
        if let model = env["SEMITONE_PIANO_MODEL"] { name = model }
        if let choice = env["SEMITONE_PIANO_UNITS"] {
            units = ["cpu": .cpuOnly, "gpu": .cpuAndGPU, "all": .all][choice] ?? .cpuAndNeuralEngine
        }
        #endif
        guard let modelURL = Bundle.main.url(forResource: name, withExtension: "mlmodelc"),
              let weightsURL = Bundle.main.url(forResource: "TranskunWeights", withExtension: "bin") else {
            throw NSError(domain: "Semitone", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "Piano model files are missing from the app bundle",
            ])
        }
        try self.init(modelURL: modelURL, weightsURL: weightsURL, computeUnits: units)
        label = "\(name), units \(units.rawValue)"
    }

    /// Which model and compute units this instance runs, for logs.
    private(set) var label = ""

    /// Returns nil if cancelled. `progress` receives 0...1 after each segment.
    /// Notes and pedal spans are clipped to the length of `samples`.
    func transcribe(
        samples: [Float],
        progress: ((Double) -> Void)? = nil,
        isCancelled: (() -> Bool)? = nil
    ) throws -> PianoTranscription? {
        let m = PianoModel.self
        // Only segments that start inside the audio. Upstream Transkun also runs
        // one that starts in the trailing padding (on almost every take). It is
        // all zeros and, with the shipping model, decodes to no intervals from any
        // forced start, so skipping it saves a backbone pass and changes nothing.
        // Empty audio still runs segment 0 (padSamples > 0).
        let starts = Array(stride(from: 0, to: m.padSamples + samples.count, by: m.stepSamples))
        var stitcher = PianoStitcher()
        var segment = [Float](repeating: 0, count: m.segmentSamples)

        for (index, i) in starts.enumerated() {
            if isCancelled?() == true { return nil }

            // Slice of the zero-padded signal [pad | samples | pad].
            segment.withUnsafeMutableBufferPointer { seg in
                seg.update(repeating: 0)
                let from = max(i, m.padSamples), to = min(i + m.segmentSamples, m.padSamples + samples.count)
                if from < to {
                    samples.withUnsafeBufferPointer { s in
                        (seg.baseAddress! + (from - i)).update(from: s.baseAddress! + (from - m.padSamples), count: to - from)
                    }
                }
            }
            fillInput(segment: segment)

            // Drain Core ML's autoreleased objects (the output alone is ~32 MB)
            // every segment rather than once at the end of a long take.
            let decoded = try autoreleasepool {
                let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["features": input]))
                guard let ctx = output.featureValue(for: "ctx")?.multiArrayValue else {
                    throw NSError(domain: "Semitone", code: 22, userInfo: [NSLocalizedDescriptionKey: "Piano model returned no output"])
                }
                return try decode(ctx, forcedStart: stitcher.forcedStart)
            }
            stitcher.add(segmentNotes: decoded.notes, lastP: decoded.lastP,
                         beginTime: Double(i) / m.sampleRate - m.padSeconds)
            progress?(Double(index + 1) / Double(starts.count))
        }

        // A note still sounding at a hard stop can decode up to ~0.4 s into the
        // trailing padding. Clip to the take so the piano roll, playback and
        // chords end with the audio. Upstream doesn't clip, so a PyTorch parity
        // check (Tools/PianoModel) has to clip its reference the same way.
        let audioEnd = Double(samples.count) / m.sampleRate
        let events = stitcher.finish().compactMap { event -> PianoSegmentNote? in
            guard event.start < audioEnd else { return nil }
            var clipped = event
            clipped.end = min(event.end, audioEnd)
            return clipped
        }
        return PianoTranscription(
            notes: events.filter { $0.pitch >= 0 }.map {
                NoteEvent(startTime: $0.start, endTime: $0.end, pitch: $0.pitch, amplitude: Double($0.velocity) / 127)
            },
            sustain: events.filter { $0.pitch == PianoModel.sustainPitch }.map {
                PedalEvent(startTime: $0.start, endTime: $0.end)
            }
        )
    }

    /// Guards against a broken compute path: fp16 on the iPhone 17's CPU turns
    /// the output into a wall of one-frame notes on every key (~170 a second).
    /// Real takes have well under 1% one-frame notes and a few notes a second.
    /// This only catches broken output; `EngineArbiter` also judges whether
    /// the take suits the model at all.
    static func looksValid(_ notes: [NoteEvent], seconds: Double,
                           maxBlipShare: Double = 0.3, maxNotesPerSecond: Double = 60) -> Bool {
        guard notes.count >= 50 else { return true }
        let blips = notes.filter { $0.endTime - $0.startTime < 1.5 * PianoModel.frameDuration }.count
        return Double(blips) < maxBlipShare * Double(notes.count) && Double(notes.count) < maxNotesPerSecond * max(seconds, 1)
    }

    private func fillInput(segment: [Float]) {
        segment.withUnsafeBufferPointer { seg in
            if input.dataType == .float32 {
                input.withUnsafeMutableBytes { raw, _ in
                    features.features(segment: seg, into: raw.bindMemory(to: Float.self).baseAddress!)
                }
                return
            }
            featureBuffer.withUnsafeMutableBufferPointer { f in
                features.features(segment: seg, into: f.baseAddress!)
                input.withUnsafeMutableBytes { raw, _ in
                    Self.convert(float: f.baseAddress!, toHalf: raw.baseAddress!,
                                 rows: PianoModel.frames, columns: PianoModel.mels * PianoModel.windowCount)
                }
            }
        }
    }

    /// Runs the decoder over the backbone output [1][90][T][256], handing it
    /// each symbol's embeddings as dense fp32 (in place when possible, otherwise
    /// converted one symbol at a time rather than copying the whole ~64 MB).
    private func decode(_ array: MLMultiArray, forcedStart: [Int]) throws -> (notes: [PianoSegmentNote], lastP: [Int]) {
        let m = PianoModel.self
        let shape = array.shape.map(\.intValue)
        let isFloat = array.dataType == .float32
        guard shape == [1, m.symbols, m.frames, m.ctxDim], isFloat || array.dataType == .float16 else {
            throw NSError(domain: "Semitone", code: 23, userInfo: [
                NSLocalizedDescriptionKey: "Unexpected piano model output \(shape) of type \(array.dataType.rawValue)",
            ])
        }
        let strides = array.strides.map(\.intValue)
        let frameStride = strides[2], dimStride = strides[3]
        return array.withUnsafeBytes { raw in
            keyBuffer.withUnsafeMutableBufferPointer { buffer in
                let dst = buffer.baseAddress!
                return decoder.decode(symbolContext: { symbol in
                    let offset = symbol * strides[1]
                    if isFloat {
                        let src = raw.baseAddress!.assumingMemoryBound(to: Float.self) + offset
                        if dimStride == 1 && frameStride == m.ctxDim { return UnsafePointer(src) }
                        for t in 0..<m.frames {
                            for d in 0..<m.ctxDim { dst[t * m.ctxDim + d] = src[t * frameStride + d * dimStride] }
                        }
                    } else {
                        let src = raw.baseAddress!.assumingMemoryBound(to: Float16.self) + offset
                        if dimStride == 1 {
                            Self.convert(half: src, rowStride: frameStride, toFloat: dst, rows: m.frames, columns: m.ctxDim)
                        } else {
                            for t in 0..<m.frames {
                                for d in 0..<m.ctxDim { dst[t * m.ctxDim + d] = Float(src[t * frameStride + d * dimStride]) }
                            }
                        }
                    }
                    return UnsafePointer(dst)
                }, forcedStart: forcedStart)
            }
        }
    }

    private static func convert(float: UnsafePointer<Float>, toHalf half: UnsafeMutableRawPointer, rows: Int, columns: Int) {
        var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: float), height: vImagePixelCount(rows),
                                width: vImagePixelCount(columns), rowBytes: columns * MemoryLayout<Float>.stride)
        var dst = vImage_Buffer(data: half, height: vImagePixelCount(rows),
                                width: vImagePixelCount(columns), rowBytes: columns * MemoryLayout<Float16>.stride)
        vImageConvert_PlanarFtoPlanar16F(&src, &dst, vImage_Flags(kvImageNoFlags))
    }

    /// fp16 rows (`rowStride` elements apart) to dense fp32 rows.
    private static func convert(half: UnsafePointer<Float16>, rowStride: Int, toFloat float: UnsafeMutablePointer<Float>,
                                rows: Int, columns: Int) {
        var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: half), height: vImagePixelCount(rows),
                                width: vImagePixelCount(columns), rowBytes: rowStride * MemoryLayout<Float16>.stride)
        var dst = vImage_Buffer(data: float, height: vImagePixelCount(rows),
                                width: vImagePixelCount(columns), rowBytes: columns * MemoryLayout<Float>.stride)
        vImageConvert_Planar16FtoPlanarF(&src, &dst, vImage_Flags(kvImageNoFlags))
    }
}
