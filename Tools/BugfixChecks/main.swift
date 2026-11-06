import Foundation

// Calls the app's real cleanup/parser/payload code. No model, key, or network.
var checks = 0
var failures: [String] = []
func expect(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { failures.append(message) }
}

let notes = [
    NoteEvent(startTime: 0, endTime: 0.1, pitch: 60, amplitude: 0.8, voice: .chords),
    NoteEvent(startTime: 0.12, endTime: 0.22, pitch: 60, amplitude: 0.8, voice: .chords),
    NoteEvent(startTime: 1, endTime: 1.1, pitch: 60, amplitude: 0.8, voice: .chords),
]
func cleanup(_ object: [String: Any]) throws -> CleanupResult {
    try AIChartInterpreter.Client.applyCleanup(
        from: JSONSerialization.data(withJSONObject: object), to: notes, melody: [])
}
func expectConflict(_ object: [String: Any], _ message: String) {
    do {
        _ = try cleanup(object)
        expect(false, message)
    } catch AIChartInterpreter.Failure.invalidCleanup(_) {
        expect(true, message)
    } catch {
        expect(false, "Unexpected cleanup error: \(error)")
    }
}

let duplicateShift = try cleanup(["shift": [["id": 0, "semitones": 24], ["id": 0, "semitones": 24]]])
expect(duplicateShift.notes.first?.pitch == 84 && duplicateShift.shifted == 1,
       "Duplicate shifts compounded or inflated the change count")
expect(duplicateShift.notes.first?.voice == .chords, "Shift discarded the note's voice")
expectConflict(["shift": [["id": 0, "semitones": 24], ["id": 0, "semitones": -12]]],
               "Conflicting shifts were accepted")
expectConflict(["remove": [0], "shift": [["id": 0, "semitones": 12]]],
               "The same original ID was used for remove and shift")
expectConflict(["merge": [[0, 1], [1, 2]]], "Overlapping merge groups were accepted")
expectConflict(["shift": [["id": 0, "semitones": 12]], "merge": [[0, 1]]],
               "The same original ID was used for shift and merge")
let fakeMerge = try cleanup(["merge": [[0, 0]]])
expect(fakeMerge.changeCount == 0 && fakeMerge.notes == notes,
       "A repeated ID fabricated a merge")
let repeatedMerge = try cleanup(["merge": [[0, 1, 1], [1, 0]]])
expect(repeatedMerge.merged == 1 && repeatedMerge.notes.count == 2,
       "Equivalent merge groups were counted more than once")
let invalidIDs = try cleanup(["remove": [-1, 999], "shift": [["id": 999, "semitones": 24]]])
expect(invalidIDs.changeCount == 0 && invalidIDs.notes == notes, "Unknown IDs edited notes")

let quiet = [NoteEvent(startTime: 0, endTime: 1, pitch: 60, amplitude: 0.1)]
let duplicateRemove = try AIChartInterpreter.Client.applyCleanup(
    from: JSONSerialization.data(withJSONObject: ["remove": [0, 0]]), to: quiet, melody: [])
expect(duplicateRemove.removed == 1 && duplicateRemove.notes.isEmpty, "Duplicate removals inflated counts")

func flags(_ payload: String) throws -> [Int] {
    let rows = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as! [[Any]]
    return rows.map { $0.last as! Int }
}
let melody = [notes[0]]
expect(try flags(AIChartInterpreter.Client.cleanupPayload(notes: notes, melody: melody)) == [1, 0, 0],
       "Cleanup marked accompaniment as lead solely by pitch")
expect(try flags(AIChartInterpreter.Client.detectionPayload(notes: Array(notes.reversed()), melody: melody)) == [1, 0, 0],
       "Chart payload marked accompaniment as lead solely by pitch")
let laterLead = [NoteEvent(startTime: 0.05, endTime: 0.08, pitch: 60, amplitude: 0.8)]
expect(try flags(AIChartInterpreter.Client.cleanupPayload(notes: notes, melody: laterLead)) == [1, 0, 0],
       "An overlapping melody segment was not recognized")

for set in ["test", "all"] {
    for sweep in ["notes", "voices", "all"] {
        do {
            _ = try parseOptions(["songs", "--set", set, "--sweep", sweep])
            expect(false, "Accepted held-out sweep: \(set) / \(sweep)")
        } catch { expect(true, "Rejected held-out sweep") }
    }
}
for sweep in ["notes", "voices", "all"] {
    expect(try parseOptions(["songs", "--set", "dev", "--sweep", sweep]).sweep == sweep,
           "Rejected a development sweep")
}
expect(try parseOptions(["songs", "--set", "test"]).evaluationKind == "held_out", "Rejected a normal test evaluation")
expect(try parseOptions(["songs", "--set", "all"]).evaluationKind == "exploratory", "All-set report was not exploratory")
for arguments in [["songs", "--set"], ["songs", "--set", "unknown"], ["songs", "--sweep", "unknown"]] {
    do { _ = try parseOptions(arguments); expect(false, "Accepted invalid CLI arguments") }
    catch { expect(true, "Rejected invalid CLI arguments") }
}

if failures.isEmpty {
    print("All \(checks) cleanup, payload, and benchmark-option checks passed.")
} else {
    for failure in failures { print("FAIL: \(failure)") }
    exit(1)
}
