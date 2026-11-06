import Foundation

/// Fixed geometry of the Transkun v2 piano model (Yujia Yan, MIT license):
/// 44.1 kHz mono, 4096-sample frames every 1024 samples, 16 s segments
/// processed every 8 s, 90 output symbols (2 pedals + 88 keys).
nonisolated enum PianoModel {
    static let sampleRate = 44100.0
    static let hop = 1024
    static let window = 4096
    static let bins = window / 2 + 1                 // 2049
    static let mels = 229
    static let windowCount = 6                       // Hann + 5 learned Gaussian windows
    static let segmentSamples = 705_600              // ceil(16 s * fs)
    static let stepSamples = 353_280                 // ceil(8 s * fs / hop) * hop
    static let padSamples = 352_800                  // ceil(8 s * fs)
    static let padSeconds = 8.0
    static let frames = 691                          // ceil(segmentSamples / hop) + 1
    static let lastFrameIdx = 689                    // round(segmentSamples / hop)
    static let startFrameIdx = 344                   // floor(8 s * fs / hop)
    static let stepFrames = 345                      // stepSamples / hop
    static let symbols = 90
    static let firstKeySymbol = 2                    // symbols 0, 1 are the pedals
    /// Symbols 0 and 1 decode as events on these negative "pitches": sustain (CC 64) and soft (CC 67) pedal.
    static let pedalPitches = [-64, -67]
    static let sustainPitch = -64
    static let keys = 88
    static let lowestKey = 21
    static let ctxDim = 256
    static let scorerOut = 2 * ctxDim + 1            // q | k | diagonal
    static let headHidden = 512
    static let frameDuration = Double(hop) / sampleRate

    /// MIDI pitch for a key symbol, or the pedal's negative pitch.
    static func pitch(symbol: Int) -> Int {
        symbol < firstKeySymbol ? pedalPitches[symbol] : lowestKey + symbol - firstKeySymbol
    }
}

/// The model's non-network constants, exported from the PyTorch checkpoint
/// in a fixed order as little-endian float32 (TranskunWeights.bin).
nonisolated struct PianoWeights {
    let windows: [Float]        // [6][4096]
    let melFilterbank: [Float]  // [2049][229]
    let scorerW: [Float]        // [513][256]
    let scorerB: [Float]        // [513]
    let velW1: [Float]          // [512][768]
    let velB1: [Float]
    let velW2: [Float]          // [128][512]
    let velB2: [Float]
    let ofW1: [Float]           // [512][768]
    let ofB1: [Float]
    let ofW2: [Float]           // [4][512]
    let ofB2: [Float]

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        let floats: [Float] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let m = PianoModel.self
        let sizes = [
            m.windowCount * m.window, m.bins * m.mels,
            m.scorerOut * m.ctxDim, m.scorerOut,
            m.headHidden * 3 * m.ctxDim, m.headHidden, 128 * m.headHidden, 128,
            m.headHidden * 3 * m.ctxDim, m.headHidden, 4 * m.headHidden, 4,
        ]
        guard floats.count == sizes.reduce(0, +) else {
            throw NSError(domain: "Semitone", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "TranskunWeights.bin has \(floats.count) values, expected \(sizes.reduce(0, +))",
            ])
        }
        var offset = 0
        func next(_ n: Int) -> [Float] {
            defer { offset += n }
            return Array(floats[offset..<(offset + n)])
        }
        windows = next(sizes[0]); melFilterbank = next(sizes[1])
        scorerW = next(sizes[2]); scorerB = next(sizes[3])
        velW1 = next(sizes[4]); velB1 = next(sizes[5]); velW2 = next(sizes[6]); velB2 = next(sizes[7])
        ofW1 = next(sizes[8]); ofB1 = next(sizes[9]); ofW2 = next(sizes[10]); ofB2 = next(sizes[11])
    }
}
