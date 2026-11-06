import Foundation

/// How the detection thresholds are chosen. Three fixed presets plus:
/// `.auto` picks the preset from the recording's own statistics, and `.custom`
/// maps a 2-D pad (note-length sensitivity x, quiet-note sensitivity y) onto
/// the extraction config.
nonisolated enum DetectionMode: String, CaseIterable, Identifiable {
    case auto
    case gentle
    case dense
    case piano
    case custom

    var id: String { rawValue }

    var label: String { label(for: .piano) }

    /// The balanced preset is named for what it's tuned on.
    func label(for transcription: TranscriptionMode) -> String {
        switch self {
        case .auto: "Auto"
        case .gentle: "Gentle"
        case .dense: "Dense"
        case .piano: transcription == .music ? "Balanced" : "Piano"
        case .custom: "Custom"
        }
    }

    var detail: String { detail(for: .piano) }

    func detail(for transcription: TranscriptionMode) -> String {
        if self == .piano, transcription == .music {
            return "Balanced for mixed instruments — the thresholds that scored best on the band test songs."
        }
        return switch self {
        case .auto: "Picks Dense when the take holds many notes at once (thick chords, busy mixes), otherwise the balanced preset."
        case .gentle: "For soft, fast runs and quiet passages — more sensitive than \(DetectionMode.piano.label(for: transcription)), short notes allowed."
        case .dense: "For chord-heavy or busy mixes — rejects weak onsets hard and holds notes longer."
        case .piano: "Balanced for solo piano — the thresholds (0.70/0.30) that scored best against the reference clip."
        case .custom: "Drag on the pad: horizontal is note length sensitivity, vertical is how eagerly quiet notes are kept."
        }
    }

    var config: NoteExtraction.Config {
        switch self {
        case .piano: NoteExtraction.Config()
        case .gentle: NoteExtraction.Config(onsetThreshold: 0.45, frameThreshold: 0.32, minNoteLengthMs: 80)
        case .dense: NoteExtraction.Config(onsetThreshold: 0.68, frameThreshold: 0.48, minNoteLengthMs: 220)
        case .auto, .custom: NoteExtraction.Config()
        }
    }
}

/// Defaults for the 2-D custom pad, on the same scale as `DetectionMode.config`.
nonisolated enum CustomPad {
    static let defaultMinNoteLengthMs = 150.0
    static let defaultFrameThreshold = 0.40
    static let minX = 60.0
    static let maxX = 280.0
    static let minY = 0.20
    static let maxY = 0.60
}

/// Single-parameter snapshot the worker carries (copied, no @Published on the queue).
nonisolated struct DetectionSnapshot: Equatable {
    var mode: DetectionMode
    var customMinNoteLengthMs: Double
    var customFrameThreshold: Double

    /// Beat-only changes can reuse reviewed notes. Values on an inactive
    /// custom pad do not change the effective detector settings.
    func hasSameNoteSettings(as other: DetectionSnapshot) -> Bool {
        mode == other.mode && (mode != .custom ||
            (customMinNoteLengthMs == other.customMinNoteLengthMs &&
             customFrameThreshold == other.customFrameThreshold))
    }
}

/// Cheap statistics gathered from the stitched model output, for the `auto`
/// preset (which reads `sustainedPolyphony`). All values are means/peaks over
/// the whole clip so far.
nonisolated struct EngineStats {
    /// Mean onset activation across all frames (loud, well-attacked playing → high).
    var onsetMean: Float = 0
    /// Peak onset activation in the clip.
    var onsetPeak: Float = 0
    /// Average number of simultaneously sounding notes per frame (polyphony).
    var polyphony: Float = 0
    /// Fraction of frames that are silent (near-zero activation).
    var silenceRatio: Float = 0
    /// Keys held at 0.5+ note activation per non-silent frame: how many notes
    /// ring at once, clear of the model's ~0.1 activation floor and of silence.
    var sustainedPolyphony: Float = 0
}

extension DetectionMode {
    /// The config to actually extract with for a given mode + custom values.
    /// `.auto` resolves against the recording's stats. For any-instrument takes
    /// the balanced preset uses thresholds tuned on mixed instruments.
    /// Nonisolated: called on the transcription queue. `stats` is only
    /// evaluated for `.auto`, so other modes skip gathering it.
    nonisolated func resolved(snapshot: DetectionSnapshot, stats: @autoclosure () -> EngineStats,
                              for transcription: TranscriptionMode = .piano) -> NoteExtraction.Config {
        switch self {
        case .piano: return transcription == .music ? .music : config
        case .gentle: return config
        case .dense: return config
        case .custom:
            return NoteExtraction.Config(
                frameThreshold: Float(snapshot.customFrameThreshold),
                minNoteLengthMs: snapshot.customMinNoteLengthMs
            )
        case .auto:
            return stats().sustainedPolyphony >= Self.denseSustainedPolyphony
                ? DetectionMode.dense.config
                : DetectionMode.piano.resolved(snapshot: snapshot, stats: EngineStats(), for: transcription)
        }
    }

    /// Auto picks Dense at or above this many keys held per sounding frame,
    /// otherwise the balanced preset for the take's mode. Scored against
    /// reference MIDI (onset F1, ±50 ms, same pitch) on the two piano clips in
    /// "semitone training" and 16 MusicBench band songs: Dense lost to Balanced
    /// on every take below 3.0 (the piano clips sit at 2.4-2.6), split around
    /// 3.1 (-0.10 and +0.04 F1) and won on both songs above 3.3 (+0.02, +0.06).
    /// The old rule (polyphony >= 2 and onset mean >= 0.06) chose Dense for
    /// every take, because the model's ~0.1 activation floor alone clears both.
    /// Its Gentle branch could never fire, and no statistic separated the few
    /// takes Gentle helped from the ones it hurt, so Auto doesn't pick it.
    nonisolated static let denseSustainedPolyphony: Float = 3.2
}
