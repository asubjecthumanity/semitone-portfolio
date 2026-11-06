import Foundation

/// What a take is, which decides how it's refined once it's finished.
nonisolated enum TranscriptionMode: String, CaseIterable, Identifiable {
    /// Solo piano: the high-accuracy piano model re-transcribes the take.
    case piano
    /// Any instrument or a whole band: the take is split into melody, chords
    /// and bass, and a countermelody where a second line stands out
    /// (`TakePipeline`). Drums are not transcribed.
    case music

    var id: String { rawValue }

    var label: String {
        switch self {
        case .piano: "Piano"
        case .music: "Any instrument"
        }
    }
}
