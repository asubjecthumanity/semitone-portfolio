import Foundation
import Synchronization

nonisolated final class TokenCollector: Sendable {
    private let values = Mutex<[Int]>([])
    func append(_ token: Int) { values.withLock { $0.append(token) } }
    func sorted() -> [Int] { values.withLock { $0.sorted() } }
}

let generation = ReanalysisGeneration()
let collected = TokenCollector()
DispatchQueue.concurrentPerform(iterations: 10_000) { [generation, collected] _ in
    collected.append(generation.next())
}
let tokens = collected.sorted()
guard tokens == Array(1...10_000), generation.isCurrent(10_000),
      tokens.dropLast().allSatisfy({ !generation.isCurrent($0) }) else {
    print("FAIL: concurrent generations were lost, duplicated, or failed to supersede old work")
    exit(1)
}
let replacement = generation.next()
guard replacement == 10_001, !generation.isCurrent(10_000), generation.isCurrent(replacement) else {
    print("FAIL: a replacement request did not retire the previous generation")
    exit(1)
}
print("Concurrent generation checks passed (10,000 increments plus request replacement).")
