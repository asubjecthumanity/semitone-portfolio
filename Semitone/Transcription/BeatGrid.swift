import Foundation
import Synchronization

/// The beat grid for one take: beat times plus which ones start a bar.
/// Computed by `BeatTracker` (a bar-pointer model over the transcribed notes),
/// so beats stay evenly spaced and only drift gradually with the performance.
nonisolated struct BeatGrid: Equatable {
    /// Every beat time, in seconds, including downbeats.
    var beats: [Double] = []
    /// The first beat of each measure.
    var downbeats: [Double] = []
    var beatsPerMeasure: Int = 4
    /// Typical tempo of the take, for display.
    var bpm: Double = 0

    static let empty = BeatGrid()

    /// - Parameters:
    ///   - beatsPerMeasure: nil to detect 3, 4 or 5 automatically.
    ///   - downbeatPitchClass: optional hint — a note the player puts on beat 1.
    ///   - tempoOctave: -1 / +1 to re-track at half / double the detected tempo.
    ///   - barShift: move beat 1 by this many beats.
    static func compute(
        notes: [NoteEvent],
        downbeatPitchClass: Int?,
        beatsPerMeasure: Int?,
        maxTime: Double,
        tempoOctave: Int = 0,
        barShift: Int = 0,
        audioOnsets: AudioOnsets? = nil
    ) -> BeatGrid {
        // Nudging bar lines only relabels beats, so reuse the last tracking
        // result when nothing else changed (the tracker takes ~0.5-3 s).
        let key = CacheKey(notes: notes, duration: maxTime, beatsPerBar: beatsPerMeasure,
                           downbeatPitchClass: downbeatPitchClass, tempoOctave: tempoOctave,
                           audioOnsets: audioOnsets)
        let result: BeatTracker.Result
        if let cached = cache.withLock({ $0 }), cached.key == key {
            result = cached.result
        } else {
            // Track outside the lock: it takes seconds, and a concurrent caller
            // with another key only costs a cache miss.
            result = BeatTracker.track(
                notes: notes,
                duration: maxTime,
                beatsPerBar: beatsPerMeasure,
                downbeatPitchClass: downbeatPitchClass,
                tempoOctave: tempoOctave,
                audioOnsets: audioOnsets
            )
            cache.withLock { $0 = (key, result) }
        }
        let m = max(result.beatsPerBar, 1)
        let positions = result.barPositions.map { (($0 - barShift) % m + m) % m }
        return BeatGrid(
            beats: result.beats,
            downbeats: zip(result.beats, positions).filter { $0.1 == 0 }.map(\.0),
            beatsPerMeasure: result.beatsPerBar,
            bpm: result.medianBPM
        )
    }

    private struct CacheKey: Equatable {
        let notes: [NoteEvent]
        let duration: Double
        let beatsPerBar: Int?
        let downbeatPitchClass: Int?
        let tempoOctave: Int
        let audioOnsets: AudioOnsets?
    }

    /// Locked: `compute` runs on the view model's worker queue but also from
    /// other threads (e.g. after an AI cleanup finishes), and an unsynchronized
    /// multi-word read could pair one key with another take's result.
    private static let cache = Mutex<(key: CacheKey, result: BeatTracker.Result)?>(nil)
}

/// Free-text key signature: parses the tonic out of anything the user types
/// ("C", "Am", "F# minor", "Bbmaj", "E♭") into a MIDI pitch class (0...11).
/// The tonic then anchors the downbeat of each measure in the beat grid.
nonisolated enum KeySignature {
    static func pitchClass(from text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return nil }

        let letter: Int
        switch first.uppercased() {
        case "C": letter = 0
        case "D": letter = 2
        case "E": letter = 4
        case "F": letter = 5
        case "G": letter = 7
        case "A": letter = 9
        case "B": letter = 11
        default: return nil
        }

        var pitchClass = letter
        var index = trimmed.index(after: trimmed.startIndex)
        while index < trimmed.endIndex {
            switch trimmed[index] {
            case "#", "♯": pitchClass += 1
            case "b", "♭": pitchClass -= 1
            default: break
            }
            index = trimmed.index(after: index)
        }
        return ((pitchClass % 12) + 12) % 12
    }
}