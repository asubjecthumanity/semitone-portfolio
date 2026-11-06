import Synchronization

/// Shared only for cancellation/coalescing. Note/settings state still belongs
/// to the serial transcription queue; this counter does not publish that state.
nonisolated final class ReanalysisGeneration: Sendable {
    private let value = Atomic<Int>(0)

    @discardableResult
    func next() -> Int { value.wrappingAdd(1, ordering: .relaxed).newValue }

    func isCurrent(_ token: Int) -> Bool { value.load(ordering: .relaxed) == token }
}
