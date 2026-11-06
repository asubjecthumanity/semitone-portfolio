import Foundation
import CoreML
import Accelerate

/// Thin wrapper around the Basic Pitch Core ML model (NMP.mlpackage).
nonisolated final class BasicPitchModel {
    struct WindowOutput {
        /// [framesPerWindow x 88] onset posteriors.
        let onsets: [Float]
        /// [framesPerWindow x 88] note (frame) posteriors.
        let frames: [Float]
    }

    private let model: MLModel
    private let input: MLMultiArray

    init(modelURL: URL) throws {
        model = try MLModel(contentsOf: modelURL, configuration: MLModelConfiguration())
        input = try MLMultiArray(
            shape: [1, NSNumber(value: BPConstants.windowSamples), 1],
            dataType: .float32
        )
    }

    convenience init() throws {
        guard let url = Bundle.main.url(forResource: "NMP", withExtension: "mlmodelc") else {
            throw NSError(
                domain: "Semitone", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "NMP.mlmodelc missing from app bundle"]
            )
        }
        try self.init(modelURL: url)
    }

    /// Runs one window. Shorter input is zero-padded to windowSamples.
    func predict(window: [Float]) throws -> WindowOutput {
        let count = min(window.count, BPConstants.windowSamples)
        var peak: Float = 0
        if count > 0 {
            window.withUnsafeBufferPointer { vDSP_maxmgv($0.baseAddress!, 1, &peak, vDSP_Length(count)) }
        }
        // Digital silence: on the default (GPU, fp16) compute units an all-zero
        // window comes back as ~0.65 onset / ~0.84 note activation on every key,
        // which the melodia sweep turns into keyboard-wide phantom notes. The CPU
        // path gives ~0 there, and so do these zeros. Noise at 1e-9 still trips
        // the GPU, 1e-8 does not; 1e-7 is under one 24-bit step, so real audio
        // always runs the model.
        if peak < Self.silenceFloor {
            let zeros = [Float](repeating: 0, count: BPConstants.framesPerWindow * BPConstants.pitchCount)
            return WindowOutput(onsets: zeros, frames: zeros)
        }
        input.withUnsafeMutableBytes { raw, _ in
            let dst = raw.bindMemory(to: Float.self)
            window.withUnsafeBufferPointer { src in
                dst.baseAddress!.update(from: src.baseAddress!, count: count)
            }
            if count < BPConstants.windowSamples {
                dst.baseAddress!.advanced(by: count)
                    .update(repeating: 0, count: BPConstants.windowSamples - count)
            }
        }
        let out = try model.prediction(
            from: MLDictionaryFeatureProvider(dictionary: ["input_2": input])
        )
        return WindowOutput(
            onsets: floats(out.featureValue(for: "Identity_2")?.multiArrayValue),
            frames: floats(out.featureValue(for: "Identity_1")?.multiArrayValue)
        )
    }

    /// Peak magnitude below which a window counts as digital silence (-140 dBFS).
    static let silenceFloor: Float = 1e-7

    /// Copies a [1, frames, pitches] float32 multiarray honoring its strides.
    /// GPU/ANE outputs pad each row (stride 96 for 88 keys), so this is one
    /// strided 2-D vDSP_mmov; a per-element loop cost ~6 ms a window in Debug.
    private func floats(_ array: MLMultiArray?) -> [Float] {
        guard let array, array.dataType == .float32, array.shape.count == 3 else { return [] }
        let frames = array.shape[1].intValue
        let pitches = array.shape[2].intValue
        let frameStride = array.strides[1].intValue
        let pitchStride = array.strides[2].intValue
        var result = [Float](repeating: 0, count: frames * pitches)
        array.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Float.self)
            result.withUnsafeMutableBufferPointer { dst in
                if pitchStride == 1 {
                    vDSP_mmov(src.baseAddress!, dst.baseAddress!, vDSP_Length(pitches), vDSP_Length(frames),
                              vDSP_Length(frameStride), vDSP_Length(pitches))
                } else {
                    for t in 0..<frames {
                        for p in 0..<pitches {
                            dst[t * pitches + p] = src[t * frameStride + p * pitchStride]
                        }
                    }
                }
            }
        }
        return result
    }
}
