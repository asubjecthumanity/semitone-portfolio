import XCTest
import Foundation
import AudioToolbox
import AVFoundation
import QuartzCore
@testable import Semitone

/// Hosted tests exercise the app's real coordinator and Apple's iOS audio/MIDI
/// implementations. Synthetic notes are deliberate: these tests make no claim
/// about transcription accuracy or what an external speaker/microphone hears.
final class RegressionTests: XCTestCase {
    private var savedDefaults: [String: Any] = [:]
    private let settingKeys = ["aiProvider", "aiKey", "useAICleanup", "detectionMode", "beatsPerMeasure",
                               "downbeatPitch", "usePianoModel", "transcriptionMode", "customNoteLenMs",
                               "customFrameThreshold", "showBeatGrid"]

    override func setUpWithError() throws {
        for key in settingKeys {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDownWithError() throws {
        for key in settingKeys {
            if let value = savedDefaults[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        savedDefaults.removeAll()
    }
    @MainActor
    private func makeViewModel() async -> TranscriberViewModel {
        let model = TranscriberViewModel()
        model.aiProviderRaw = "off"
        model.useAICleanup = false
        model.detectionMode = .piano
        model.beatsPerMeasure = 4
        model.downbeatPitch = nil
        model.usePianoModel = true
        await model.regressionFlushWorker()
        return model
    }

    private func note(_ start: Double, _ end: Double, _ pitch: Int,
                      amplitude: Double = 0.7, voice: Voice = .none) -> NoteEvent {
        NoteEvent(startTime: start, endTime: end, pitch: pitch, amplitude: amplitude, voice: voice)
    }

    private func triad(_ start: Double, _ end: Double) -> [NoteEvent] {
        [60, 64, 67].map { note(start, end, $0) }
    }

    private func rhythmicNotes() -> [NoteEvent] {
        (0..<16).map { index in
            let start = Double(index) * 0.5
            return note(start, start + 0.3, index.isMultiple(of: 4) ? 48 : 60)
        }
    }

    @MainActor
    func testSEM057CurrentChordUsesHalfOpenBoundariesAndLongSilence() async throws {
        let model = await makeViewModel()
        try await model.regressionInstallTake(notes: triad(1, 2) + triad(6, 7), duration: 8)
        XCTAssertEqual(model.chordSegments.count, 2, "The long rest must remain a gap.")
        for (time, expected) in [(0.0, nil), (1.0, "C"), (1.999, "C"),
                                  (2.0, nil), (4.0, nil), (6.0, "C"), (7.0, nil)] {
            model.cue(at: time, settled: true)
            XCTAssertEqual(model.currentChord, expected, "Incorrect chord at \(time) seconds.")
        }
        model.regressionSetRecordingEdge(at: 1.5)
        XCTAssertEqual(model.currentChord, "C", "A live take follows its recorded edge.")
        model.regressionSetRecordingEdge(at: 2)
        XCTAssertNil(model.currentChord, "The live edge also excludes the exact chord end.")
    }

    @MainActor
    func testSEM057ShortEqualChordRestStillBridges() async throws {
        let model = await makeViewModel()
        try await model.regressionInstallTake(notes: triad(1, 2) + triad(3, 4), duration: 5)
        model.cue(at: 2.5, settled: true)
        XCTAssertEqual(model.currentChord, "C", "The existing short-rest bridge must survive.")
        model.cue(at: 4, settled: true)
        XCTAssertNil(model.currentChord)
    }

    @MainActor
    func testSEM056CleanupSurvivesEachBeatSettingAndRevertUsesOriginalNotes() async throws {
        let model = await makeViewModel()
        let raw = rhythmicNotes()
        let pedal = [PedalEvent(startTime: 0, endTime: 7.8)]
        try await model.regressionInstallTake(notes: raw, source: .piano, sustain: pedal, duration: 8)
        let cleaned = Array(raw.dropFirst())
        let result = CleanupResult(notes: cleaned, removed: 1, shifted: 0, merged: 0,
                                   confidence: 0.95, summary: "Removed one fixture note")
        await model.regressionApplyCleanup(result)
        XCTAssertEqual(model.notes, cleaned)
        XCTAssertEqual(model.rawNotes, raw)

        model.beatsPerMeasure = 3
        await model.regressionFlushWorker()
        XCTAssertEqual(model.beatGrid.beatsPerMeasure, 3)
        assertPreserved(model, notes: cleaned, raw: raw, cleanup: result, pedal: pedal)

        model.downbeatPitch = 60
        await model.regressionFlushWorker()
        assertPreserved(model, notes: cleaned, raw: raw, cleanup: result, pedal: pedal)

        model.tempoOctave = 1
        await model.regressionFlushWorker()
        assertPreserved(model, notes: cleaned, raw: raw, cleanup: result, pedal: pedal)

        let beatsBeforeShift = model.beatGrid.beats
        let downbeatsBeforeShift = model.beatGrid.downbeats
        model.barShift = 1
        await model.regressionFlushWorker()
        XCTAssertEqual(model.beatGrid.beats, beatsBeforeShift)
        XCTAssertNotEqual(model.beatGrid.downbeats, downbeatsBeforeShift,
                          "Bar shift should update derived bar lines.")
        assertPreserved(model, notes: cleaned, raw: raw, cleanup: result, pedal: pedal)

        model.revertCleanup()
        await model.regressionFlushWorker()
        XCTAssertEqual(model.notes, raw)
        XCTAssertTrue(model.rawNotes.isEmpty)
        XCTAssertNil(model.cleanup)
        XCTAssertEqual(model.sustain, pedal)

        // A second metadata change catches a stale cleaned worker cache after revert.
        model.beatsPerMeasure = 5
        await model.regressionFlushWorker()
        XCTAssertEqual(model.notes, raw)
        XCTAssertEqual(model.beatGrid.beatsPerMeasure, 5)
    }

    @MainActor
    func testSEM056MusicCleanupPreservesPartsAndSourceThroughBeatChanges() async throws {
        let model = await makeViewModel()
        let raw = rhythmicNotes().map { $0.with(voice: $0.pitch < 55 ? .bass : .melody) }
        try await model.regressionInstallTake(notes: raw, source: .music, duration: 8)
        let result = CleanupResult(notes: Array(raw.dropFirst()), removed: 1, shifted: 0, merged: 0,
                                   confidence: 1, summary: nil)
        await model.regressionApplyCleanup(result)
        let reviewed = model.notes
        let version = model.regressionShownVersion
        for index in 0..<20 {
            model.beatsPerMeasure = index.isMultiple(of: 2) ? 3 : 4
            model.downbeatPitch = index.isMultiple(of: 2) ? 48 : 60
            model.tempoOctave = index.isMultiple(of: 2) ? -1 : 1
            model.barShift = index % 3
        }
        await model.regressionFlushWorker()
        XCTAssertEqual(model.notes, reviewed)
        XCTAssertEqual(model.regressionShownVersion, version)
        XCTAssertEqual(model.rawNotes, raw)
        XCTAssertEqual(model.cleanup, result)
        XCTAssertEqual(model.presentVoices, Set(reviewed.map(\.voice)))
        XCTAssertTrue(model.hasParts, "Cleaned any-instrument notes keep their parts.")
        XCTAssertTrue(model.notesSource == .music)
        model.revertCleanup()
        await model.regressionFlushWorker()
        XCTAssertEqual(model.notes, raw)
        XCTAssertEqual(model.presentVoices, [.melody, .bass])
    }

    @MainActor
    func testSEM056AllRemovedAndNoChangeCleanupSurviveBeatChanges() async throws {
        let model = await makeViewModel()
        let raw = rhythmicNotes()
        try await model.regressionInstallTake(notes: raw, duration: 8)
        let emptyResult = CleanupResult(notes: [], removed: raw.count, shifted: 0, merged: 0,
                                        confidence: 1, summary: "All fixture notes removed")
        await model.regressionApplyCleanup(emptyResult)
        model.beatsPerMeasure = 3
        model.downbeatPitch = 48
        model.barShift = 1
        await model.regressionFlushWorker()
        XCTAssertTrue(model.notes.isEmpty, "An empty accepted cleanup is still reviewed content.")
        XCTAssertEqual(model.cleanup, emptyResult)
        XCTAssertEqual(model.rawNotes, raw)
        model.revertCleanup()
        await model.regressionFlushWorker()
        XCTAssertEqual(model.notes, raw)

        let unchanged = CleanupResult(notes: raw, removed: 0, shifted: 0, merged: 0,
                                      confidence: 1, summary: "No changes")
        await model.regressionApplyCleanup(unchanged)
        model.beatsPerMeasure = 4
        model.tempoOctave = -1
        await model.regressionFlushWorker()
        XCTAssertEqual(model.notes, raw)
        XCTAssertEqual(model.cleanup, unchanged)
        XCTAssertTrue(model.rawNotes.isEmpty)
    }

    @MainActor
    func testSEM056BeatChangesDoNotReloadOrInterruptActivePlayback() async throws {
        let model = await makeViewModel()
        let raw = [note(0, 12, 60), note(0.5, 1, 72)]
        try await model.regressionInstallTake(notes: raw, duration: 12)
        let result = CleanupResult(notes: [raw[0]], removed: 1, shifted: 0, merged: 0,
                                   confidence: 1, summary: nil)
        await model.regressionApplyCleanup(result)
        model.togglePlayback()
        defer { model.stopPlayback() }
        try await waitUntil(timeout: 2) { model.isPlaying && model.playhead > 0.05 }
        let loads = model.regressionPlaybackLoadCount
        let before = model.playhead
        model.beatsPerMeasure = 3
        model.downbeatPitch = 60
        model.tempoOctave = 1
        model.barShift = 1
        await model.regressionFlushWorker()
        XCTAssertEqual(model.regressionPlaybackLoadCount, loads)
        XCTAssertEqual(model.notes, [raw[0]])
        XCTAssertEqual(model.cleanup, result)
        XCTAssertTrue(model.isPlaying)
        try await waitUntil(timeout: 2) { model.playhead > before + 0.1 }
        XCTAssertEqual(model.regressionPlaybackLoadCount, loads)
    }

    @MainActor
    func testSEM056EffectiveDetectorChangeStillReplacesCleanup() async throws {
        let model = await makeViewModel()
        let raw = rhythmicNotes()
        try await model.regressionInstallTake(notes: raw, duration: 8)
        let result = CleanupResult(notes: Array(raw.dropFirst()), removed: 1, shifted: 0, merged: 0,
                                   confidence: 1, summary: nil)
        await model.regressionApplyCleanup(result)
        model.detectionMode = .gentle
        await model.regressionFlushWorker()
        XCTAssertEqual(model.notes, raw, "The installed piano result is the detector take.")
        XCTAssertNil(model.cleanup)
        XCTAssertTrue(model.rawNotes.isEmpty)
    }

    /// Home's Settings set the piano model for new takes only: the take
    /// that's open (often not on screen) keeps its notes. A Tone's own
    /// switch (Transcription, in its menu) changes it for that take alone,
    /// and the next take starts from Home's choice again.
    @MainActor
    func testPianoModelDefaultLeavesTheOpenTakeAloneAndTheToneSwitchActsOnIt() async throws {
        let model = await makeViewModel()
        try await model.regressionInstallTake(notes: [note(0.25, 1, 60)], source: .piano, duration: 2)
        XCTAssertEqual(model.notesSource, .piano)
        XCTAssertTrue(model.takeUsesPianoModel)

        model.usePianoModel = false   // Home's Settings
        await model.regressionFlushWorker()
        XCTAssertEqual(model.notesSource, .piano, "Home's switch doesn't re-run the open take.")
        XCTAssertEqual(model.notes.map(\.pitch), [60])
        XCTAssertTrue(model.takeUsesPianoModel)
        var worker = await model.regressionWorkerSnapshot()
        XCTAssertTrue(worker.usesPianoModel, "The open take still uses the piano model.")

        model.setTakeUsesPianoModel(false)   // Transcription, in the Tone's long-press menu
        await model.regressionFlushWorker()
        XCTAssertEqual(model.notesSource, .quick, "The Tone's switch goes back to the quick detector's notes.")
        XCTAssertFalse(model.usePianoModel)
        model.setTakeUsesPianoModel(true)
        await model.regressionFlushWorker()
        XCTAssertEqual(model.notesSource, .piano, "And back to the piano model's.")
        XCTAssertFalse(model.usePianoModel, "A Tone's switch leaves the default for new takes alone.")

        model.regressionBeginEmptyTake()
        await model.regressionFlushWorker()
        XCTAssertFalse(model.takeUsesPianoModel, "A new take starts from Home's choice.")
        worker = await model.regressionWorkerSnapshot()
        XCTAssertFalse(worker.usesPianoModel)
    }

    /// A Piano Tone reopens with its own piano-model choice, whatever the
    /// default for new takes is now: one saved with the model's notes shows
    /// them (0.97 showed the quick detector's notes once the default was
    /// off, and saved over them), and one saved with the quick detector's
    /// opens with its switch off.
    @MainActor
    func testReopenedPianoToneKeepsItsOwnPianoModelChoice() async throws {
        let model = await makeViewModel()
        for (source, usesModel) in [("piano", true), ("quick", false)] {
            model.usePianoModel = !usesModel   // Home's default says otherwise
            let id = UUID()
            let take = SavedTake(id: id, title: "Saved \(source)", createdAt: Date(), duration: 2,
                                 mode: TranscriptionMode.piano.rawValue, noteCount: 1)
            try TakeLibrary.save(take, content: SavedTakeContent(source: source, notes: [note(0.25, 1, 60)], sustain: []),
                                 audio: [Float](repeating: 0, count: 88200), sampleRate: 44100)
            defer { try? TakeLibrary.delete(id) }
            model.openSavedTake(take)
            try await waitUntil(timeout: 20) { !model.isTranscribing }
            await model.regressionFlushWorker()
            XCTAssertNil(model.errorMessage)
            XCTAssertEqual(model.takeUsesPianoModel, usesModel, source)
            let worker = await model.regressionWorkerSnapshot()
            XCTAssertEqual(worker.usesPianoModel, usesModel, source)
            XCTAssertEqual(model.usePianoModel, !usesModel, "Opening a Tone leaves the default alone.")
            if usesModel {
                XCTAssertEqual(model.notesSource, .piano)
                XCTAssertEqual(model.notes.map(\.pitch), [60])
            } else {
                XCTAssertEqual(model.notesSource, .quick)
            }
        }
    }

    /// A Tone's piano-model switch does nothing while the Tone is still
    /// opening: the open sets the switch from the save once the audio is
    /// read, after a flip would have queued its own pass, so the switch
    /// would show the saved choice while the roll showed the other one.
    @MainActor
    func testTonePianoModelSwitchWaitsUntilATakeHasOpened() async throws {
        let model = await makeViewModel()
        model.usePianoModel = true
        let id = UUID()
        let take = SavedTake(id: id, title: "Saved piano", createdAt: Date(), duration: 2,
                             mode: TranscriptionMode.piano.rawValue, noteCount: 1)
        try TakeLibrary.save(take, content: SavedTakeContent(source: "piano", notes: [note(0.25, 1, 60)], sustain: []),
                             audio: [Float](repeating: 0, count: 88200), sampleRate: 44100)
        defer { try? TakeLibrary.delete(id) }
        model.openSavedTake(take)
        XCTAssertTrue(model.isTranscribing, "The Tone is still opening.")
        model.setTakeUsesPianoModel(false)
        XCTAssertTrue(model.takeUsesPianoModel, "The switch doesn't move while the Tone opens.")
        try await waitUntil(timeout: 20) { !model.isTranscribing }
        await model.regressionFlushWorker()
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.takeUsesPianoModel)
        let worker = await model.regressionWorkerSnapshot()
        XCTAssertTrue(worker.usesPianoModel, "The worker agrees with the switch.")
        XCTAssertEqual(model.notesSource, .piano, "And the roll shows the piano model's notes, as saved.")
        XCTAssertTrue(model.usePianoModel)
    }

    /// With no take open, a Tone's switch is the choice for the next take.
    @MainActor
    func testTonePianoModelSwitchWithoutATakeSetsTheNextTakes() async {
        let model = await makeViewModel()
        XCTAssertFalse(model.hasContent)
        model.setTakeUsesPianoModel(false)
        XCTAssertFalse(model.usePianoModel)
        model.regressionBeginEmptyTake()
        await model.regressionFlushWorker()
        XCTAssertFalse(model.takeUsesPianoModel)
        let worker = await model.regressionWorkerSnapshot()
        XCTAssertFalse(worker.usesPianoModel)
    }

    /// Home's long-press menu opens a Tone that isn't open, then acts on it:
    /// the action runs once the Tone is on screen (its notes, chords and
    /// beat grid published, nothing transcribing), so a MIDI file exported
    /// from Home is the one the transcription screen made.
    @MainActor
    func testOpeningAToneRunsItsActionOnceItIsOnScreen() async throws {
        let model = await makeViewModel()
        let id = UUID()
        let take = SavedTake(id: id, title: "Saved triad", createdAt: Date(), duration: 2,
                             mode: TranscriptionMode.piano.rawValue, noteCount: 3)
        try TakeLibrary.save(take, content: SavedTakeContent(source: "piano", notes: triad(0.25, 1.5), sustain: []),
                             audio: [Float](repeating: 0, count: 88200), sampleRate: 44100)
        defer { try? TakeLibrary.delete(id) }
        var seen: (transcribing: Bool, pitches: [Int], chords: Int, canExport: Bool)?
        var exported: URL?
        model.openSavedTake(take) {
            seen = (model.isTranscribing, model.notes.map(\.pitch).sorted(), model.chordSegments.count, model.canExport)
            exported = model.exportMIDI()
        }
        XCTAssertNil(seen, "Not before the Tone has opened.")
        XCTAssertEqual(model.openSavedTakeID, id)
        try await waitUntil(timeout: 20) { seen != nil }
        let opened = try XCTUnwrap(seen)
        XCTAssertFalse(opened.transcribing)
        XCTAssertEqual(opened.pitches, [60, 64, 67], "The Tone's saved notes are on screen.")
        XCTAssertGreaterThan(opened.chords, 0, "Its chord is named.")
        XCTAssertTrue(opened.canExport)
        let url = try XCTUnwrap(exported)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try readMIDI(Data(contentsOf: url)).notes.map(\.pitch).sorted(), [60, 64, 67])
        XCTAssertNil(model.errorMessage)

        model.deleteSavedTake(take)
        XCTAssertNil(model.openSavedTakeID, "A deleted Tone isn't the open one any more.")
    }

    /// The action is dropped when the Tone can't be opened (no audio), or
    /// another take starts before it has.
    @MainActor
    func testAToneActionIsDroppedWhenItCannotOpenOrAnotherTakeStarts() async throws {
        let model = await makeViewModel()
        let id = UUID()
        let take = SavedTake(id: id, title: "No audio", createdAt: Date(), duration: 2,
                             mode: TranscriptionMode.piano.rawValue, noteCount: 1)
        try TakeLibrary.save(take, content: SavedTakeContent(source: "piano", notes: [note(0.25, 1, 60)], sustain: []),
                             audio: nil, sampleRate: 44100)
        defer { try? TakeLibrary.delete(id) }
        var ran = false
        model.openSavedTake(take) { ran = true }
        try await waitUntil(timeout: 20) { !model.isTranscribing }
        await model.regressionFlushWorker()
        XCTAssertNotNil(model.errorMessage, "Without its audio the Tone can't open.")
        XCTAssertFalse(ran)
        model.errorMessage = nil

        let other = UUID()
        let saved = SavedTake(id: other, title: "Saved", createdAt: Date(), duration: 2,
                              mode: TranscriptionMode.piano.rawValue, noteCount: 1)
        try TakeLibrary.save(saved, content: SavedTakeContent(source: "piano", notes: [note(0.25, 1, 60)], sustain: []),
                             audio: [Float](repeating: 0, count: 88200), sampleRate: 44100)
        defer { try? TakeLibrary.delete(other) }
        model.openSavedTake(saved) { ran = true }
        model.regressionBeginEmptyTake()
        try await waitUntil(timeout: 20) { !model.isTranscribing }
        await model.regressionFlushWorker()
        XCTAssertFalse(ran, "Another take started first.")
        XCTAssertNotEqual(model.openSavedTakeID, other)
    }

    /// The open Tone's Transcription menu reads from the model, and its
    /// items act on the take: an AI cleanup to revert, the piano model off
    /// and on. A Tone that isn't open reads from its save, which keeps no
    /// cleanup.
    @MainActor
    func testToneTranscriptionMenuReadsAndActsOnTheOpenTone() async throws {
        let model = await makeViewModel()
        let raw = triad(0.25, 1) + [note(1.5, 2, 72)]
        try await model.regressionInstallTake(notes: raw, source: .piano, duration: 3)
        await model.regressionApplyCleanup(CleanupResult(notes: Array(raw.dropLast()), removed: 1, shifted: 0,
                                                         merged: 0, confidence: 0.9, summary: "Removed a phantom note."))
        var tone = ToneTranscriptionMenu.Tone(open: model)
        XCTAssertEqual(tone.mode, .piano)
        XCTAssertEqual(tone.kindName, "Piano")
        XCTAssertTrue(tone.usesPianoModel)
        XCTAssertTrue(tone.canSwitchPianoModel)
        XCTAssertTrue(tone.canRevert, "The cleaned-up Tone can go back to its raw notes.")
        XCTAssertNotNil(tone.cleanup)
        XCTAssertTrue(tone.showsAI)
        XCTAssertFalse(tone.canCleanUp, "No AI provider is chosen.")
        XCTAssertFalse(tone.isLocked)

        model.perform(.revertCleanup)
        await model.regressionFlushWorker()
        XCTAssertEqual(model.notes.count, raw.count, "Revert brings the raw notes back.")
        tone = ToneTranscriptionMenu.Tone(open: model)
        XCTAssertFalse(tone.canRevert)
        XCTAssertFalse(tone.showsAI, "No provider, nothing to revert: no AI items.")

        model.perform(.switchPianoModel)
        await model.regressionFlushWorker()
        XCTAssertEqual(model.notesSource, .quick)
        XCTAssertFalse(ToneTranscriptionMenu.Tone(open: model).usesPianoModel)
        model.perform(.switchPianoModel)
        await model.regressionFlushWorker()
        XCTAssertEqual(model.notesSource, .piano)

        let saved = SavedTake(id: UUID(), title: "Whistled", createdAt: Date(), duration: 4,
                              mode: TranscriptionMode.music.rawValue, noteCount: 12)
        let other = ToneTranscriptionMenu.Tone(saved: saved, kind: .instrument, usesPianoModel: false,
                                               hasAIProvider: true, isLocked: false)
        XCTAssertEqual(other.mode, .music)
        XCTAssertEqual(other.kindName, "Instrument")
        XCTAssertTrue(other.canCleanUp)
        XCTAssertFalse(other.canRevert)
        XCTAssertNil(other.cleanup)
    }

    /// The Detection presets' pictures come from the take's own activations,
    /// one list per preset, without changing what's shown; nothing before a
    /// take is finished.
    @MainActor
    func testPresetNotesExtractEachPresetWithoutTouchingTheTake() async throws {
        let model = await makeViewModel()
        let modes: [DetectionMode] = [.auto, .gentle, .piano, .dense, .custom]
        let none = await model.presetNotes(for: modes, customLengthMs: 150, customThreshold: 0.4, from: 0, to: 4)
        XCTAssertNil(none, "No take, no pictures.")

        model.usePianoModel = false
        try await model.regressionInstallTake(notes: [note(0.25, 1, 60)], source: .quick, duration: 2)
        let shown = model.notes
        let versionBefore = model.regressionShownVersion
        let extracted = await model.presetNotes(for: modes, customLengthMs: 150, customThreshold: 0.4, from: 0, to: 4)
        let byMode = try XCTUnwrap(extracted)
        XCTAssertEqual(Set(byMode.keys), Set(modes))
        // The fixture's audio is silence: the quick detector keeps nothing under any preset.
        XCTAssertTrue(byMode.values.allSatisfy(\.isEmpty))
        await model.regressionFlushWorker()
        XCTAssertEqual(model.notes, shown, "Drawing the presets doesn't change the take.")
        XCTAssertEqual(model.regressionShownVersion, versionBefore)
        XCTAssertEqual(model.detectionMode, .piano)
    }

    @MainActor
    func testSEM043OnlyLatestQueuedCustomAndBeatSettingsWin() async throws {
        let model = await makeViewModel()
        model.regressionSuspendWorker()
        model.detectionMode = .custom
        for index in 0..<100 {
            model.customNoteLenMs = 60 + Double(index)
            model.customFrameThreshold = 0.20 + Double(index) / 1000
            model.beatsPerMeasure = index.isMultiple(of: 2) ? 3 : 4
        }
        model.customNoteLenMs = 237
        model.customFrameThreshold = 0.53
        model.beatsPerMeasure = 7
        model.downbeatPitch = 61
        model.tempoOctave = -1
        model.barShift = 2
        model.regressionResumeWorker()
        await model.regressionFlushWorker()
        XCTAssertEqual(model.config.minNoteLengthMs, 237)
        XCTAssertEqual(model.config.frameThreshold, Float(0.53), accuracy: 0.00001)
        let state = await model.regressionWorkerSnapshot()
        XCTAssertEqual(state.snapshot.mode, .custom)
        XCTAssertEqual(state.snapshot.customMinNoteLengthMs, 237)
        XCTAssertEqual(state.snapshot.customFrameThreshold, 0.53)
        XCTAssertEqual(state.beatsPerMeasure, 7)
        XCTAssertEqual(state.downbeatPitch, 61)
        XCTAssertEqual(state.tempoOctave, -1)
        XCTAssertEqual(state.barShift, 2)
    }

    @MainActor
    func testSEM086ViewModelExportsTwoUniqueReadableMIDIFilesWithDisplayedParts() async throws {
        let model = await makeViewModel()
        let notes = [note(0.25, 1, 72, amplitude: 0.5, voice: .melody),
                     note(0.25, 1, 36, amplitude: 0.5, voice: .bass)]
        try await model.regressionInstallTake(notes: notes, source: .music, duration: 2)
        model.hiddenVoices = [.bass]
        XCTAssertTrue(model.canExport)
        let first = try XCTUnwrap(model.exportMIDI())
        let second = try XCTUnwrap(model.exportMIDI())
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        XCTAssertNotEqual(first, second, "Same-minute exports must not overwrite each other.")
        for url in [first, second] {
            XCTAssertEqual(url.pathExtension, "mid")
            XCTAssertNotNil(UUID(uuidString: String(url.deletingPathExtension().lastPathComponent.suffix(36))))
            let file = try readMIDI(Data(contentsOf: url))
            XCTAssertEqual(file.notes.count, 1)
            let exported = try XCTUnwrap(file.notes.first)
            XCTAssertEqual(exported.pitch, 72)
            XCTAssertEqual(exported.velocity, 85, "Quick/music exports use activation dynamics.")
            XCTAssertEqual(exported.start, 0.25, accuracy: 0.003)
            XCTAssertEqual(exported.end, 1, accuracy: 0.003)
        }
        model.hiddenVoices = [.melody, .bass]
        XCTAssertFalse(model.canExport)
        model.hiddenVoices = [.melody]
        XCTAssertTrue(model.canExport, "A bass-only visible take is exportable.")
        let bassURL = try XCTUnwrap(model.exportMIDI())
        defer { try? FileManager.default.removeItem(at: bassURL) }
        let bassFile = try readMIDI(Data(contentsOf: bassURL))
        XCTAssertEqual(bassFile.notes.count, 1)
        XCTAssertEqual(bassFile.notes.first?.pitch, 36)
        XCTAssertEqual(bassFile.notes.first?.channel, 0, "The only part takes the first channel.")
        XCTAssertFalse(bassFile.notes.contains { $0.channel == 9 }, "Exports carry no drum channel.")
    }

    @MainActor
    func testSEM043QueuedOldTakeMetadataCannotPublishIntoReplacementTake() async throws {
        let model = await makeViewModel()
        try await model.regressionInstallTake(notes: rhythmicNotes(), duration: 8)
        model.regressionSuspendWorker()
        model.beatsPerMeasure = 3
        model.downbeatPitch = 48
        model.regressionBeginEmptyTake()
        model.regressionResumeWorker()
        await model.regressionFlushWorker()
        XCTAssertTrue(model.notes.isEmpty)
        XCTAssertTrue(model.chordSegments.isEmpty)
        XCTAssertTrue(model.beatGrid.beats.isEmpty)
        XCTAssertTrue(model.notesSource == .none)
        XCTAssertEqual(model.duration, 0)
        XCTAssertEqual(model.playhead, 0)
    }

    @MainActor
    func testSEM086PianoExportRetainsDetectedVelocityAndPedal() async throws {
        let model = await makeViewModel()
        try await model.regressionInstallTake(notes: [note(0.25, 1, 60, amplitude: 0.5)], source: .piano,
                                              sustain: [PedalEvent(startTime: 0.1, endTime: 1.5)], duration: 2)
        let url = try XCTUnwrap(model.exportMIDI())
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try readMIDI(Data(contentsOf: url))
        XCTAssertEqual(file.notes.first?.velocity, 64)
        let pedal = file.controls.filter { $0.number == 64 }
        XCTAssertEqual(pedal.map(\.value), [127, 0])
        XCTAssertEqual(try XCTUnwrap(pedal.first).time, 0.1, accuracy: 0.003)
        XCTAssertEqual(try XCTUnwrap(pedal.last).time, 1.5, accuracy: 0.003)
    }

    @MainActor
    func testSEM015CorruptFileShowsErrorAndNextValidImportRecovers() async throws {
        let model = await makeViewModel()
        model.usePianoModel = false
        await model.regressionFlushWorker()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let corrupt = directory.appending(path: "corrupt.wav")
        try Data("This is not a WAV file".utf8).write(to: corrupt)
        model.transcribeFile(url: corrupt, isSecurityScoped: false)
        XCTAssertTrue(model.isTranscribing)
        try await waitUntil(timeout: 30) { !model.isTranscribing }
        XCTAssertTrue(model.errorMessage?.hasPrefix("Could not transcribe file:") == true)
        XCTAssertFalse(model.isRecording)
        XCTAssertTrue(model.notes.isEmpty)

        let valid = directory.appending(path: "valid-silence.wav")
        try writeSilenceWAV(to: valid, duration: 0.25)
        XCTAssertEqual(try AVAudioFile(forReading: valid).length, 11025,
                       "The generated WAV must have a finalized, readable header.")
        model.transcribeFile(url: valid, isSecurityScoped: false)
        XCTAssertTrue(model.isTranscribing, "A new import must be accepted after failure.")
        try await waitUntil(timeout: 30) { !model.isTranscribing }
        await model.regressionFlushWorker()
        XCTAssertNil(model.errorMessage, "A replacement import must clear the previous failure.")
        XCTAssertEqual(model.duration, 0.25, accuracy: 1 / BPConstants.sampleRate,
                       model.errorMessage ?? "Import completed without a duration.")
        XCTAssertTrue(model.notes.isEmpty, "A legitimate silent file succeeds without phantom notes.")
    }

    @MainActor
    func testSEM015IOSFileLoaderReadsShortExactAndMultiChunkWAVs() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for frames in [11025, 65536, 88200] {
            let duration = Double(frames) / 44100
            let mono = directory.appending(path: "mono-\(frames).wav")
            try writeSilenceWAV(to: mono, duration: duration)
            XCTAssertEqual(try AudioFileLoader.loadMono(url: mono, sampleRate: 44100).count, frames)
            XCTAssertEqual(Double(try AudioFileLoader.loadMono22k(url: mono).count),
                           duration * BPConstants.sampleRate, accuracy: 1)

            let stereo = directory.appending(path: "stereo-\(frames).wav")
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                    sampleRate: 44100, channels: 2, interleaved: false))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
            let data = try XCTUnwrap(buffer.floatChannelData)
            data[0].update(repeating: 0, count: frames)
            data[1].update(repeating: 0.25, count: frames)
            buffer.frameLength = AVAudioFrameCount(frames)
            let file = try AVAudioFile(forWriting: stereo, settings: format.settings)
            try file.write(from: buffer)
            file.close()
            XCTAssertTrue(try AudioFileLoader.firstChannelIsQuiet(url: stereo))
            let mixed = try AudioFileLoader.loadMono22k(url: stereo)
            XCTAssertEqual(Double(mixed.count), duration * BPConstants.sampleRate, accuracy: 1)
            XCTAssertTrue(mixed.contains { abs($0) > 0.1 }, "The active second channel must survive downmix.")
        }
    }

    @MainActor
    func testSEM015IOSConverterThrowsLateReadErrorInsteadOfAcceptingPrefix() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: 44100, channels: 1, interleaved: false))
        let expected = NSError(domain: "SemitoneRegressionRead", code: 57)
        var reads = 0
        XCTAssertThrowsError(try AudioFileLoader.convertMono(from: format, to: 22050) { buffer in
            reads += 1
            if reads > 1 { throw expected }
            let data = try XCTUnwrap(buffer.floatChannelData)
            data[0].update(repeating: 0.125, count: Int(buffer.frameCapacity))
            buffer.frameLength = buffer.frameCapacity
        }) { error in
            XCTAssertEqual((error as NSError).domain, expected.domain)
            XCTAssertEqual((error as NSError).code, expected.code)
        }
        XCTAssertGreaterThanOrEqual(reads, 2, "The failure must follow a successfully consumed prefix.")
    }

    @MainActor
    func testSEM043RestoredPreferencesInitializeWorkerOnItsQueue() async {
        for index in 0..<30 {
            let piano = index.isMultiple(of: 2)
            let mode: TranscriptionMode = piano ? .piano : .music
            UserDefaults.standard.set(piano, forKey: "usePianoModel")
            UserDefaults.standard.set(mode.rawValue, forKey: "transcriptionMode")
            UserDefaults.standard.set("custom", forKey: "detectionMode")
            UserDefaults.standard.set(237.0, forKey: "customNoteLenMs")
            UserDefaults.standard.set(0.37, forKey: "customFrameThreshold")
            UserDefaults.standard.set(false, forKey: "showBeatGrid")
            UserDefaults.standard.set(3, forKey: "beatsPerMeasure")
            UserDefaults.standard.set(48, forKey: "downbeatPitch")
            let model = TranscriberViewModel()
            await model.regressionFlushWorker()
            let state = await model.regressionWorkerSnapshot()
            XCTAssertEqual(model.usePianoModel, piano)
            XCTAssertEqual(model.transcriptionMode, mode)
            XCTAssertEqual(state.usesPianoModel, piano)
            XCTAssertEqual(state.transcriptionMode, mode)
            XCTAssertEqual(model.detectionMode, .custom)
            XCTAssertEqual(model.customNoteLenMs, 237)
            XCTAssertEqual(model.customFrameThreshold, 0.37)
            XCTAssertFalse(model.showBeatGrid)
            XCTAssertEqual(model.beatsPerMeasure, 3)
            XCTAssertEqual(model.downbeatPitch, 48)
            XCTAssertEqual(state.snapshot.customMinNoteLengthMs, 237)
            XCTAssertEqual(state.snapshot.customFrameThreshold, 0.37)
            XCTAssertEqual(state.beatsPerMeasure, 3)
            XCTAssertEqual(state.downbeatPitch, 48)
            XCTAssertEqual(UserDefaults.standard.double(forKey: "customNoteLenMs"), 237)
            XCTAssertEqual(UserDefaults.standard.double(forKey: "customFrameThreshold"), 0.37)
            XCTAssertEqual(UserDefaults.standard.integer(forKey: "beatsPerMeasure"), 3)
            XCTAssertEqual(UserDefaults.standard.integer(forKey: "downbeatPitch"), 48)
        }
    }

    @MainActor
    func testSEM043InterleavedSettingsKeepLatestWorkerState() async throws {
        let model = await makeViewModel()
        let raw = rhythmicNotes()
        try await model.regressionInstallTake(notes: raw, duration: 8)
        for index in 0..<50 {
            model.detectionMode = .custom
            model.customNoteLenMs = 60 + Double(index)
            model.customFrameThreshold = 0.2 + Double(index) / 1000
            model.beatsPerMeasure = index.isMultiple(of: 2) ? 3 : 4
            model.downbeatPitch = index.isMultiple(of: 2) ? 48 : 60
            await Task.yield() // Let the worker and MainActor publications overlap.
        }
        model.customNoteLenMs = 237
        model.customFrameThreshold = 0.53
        model.beatsPerMeasure = 7
        await model.regressionFlushWorker()
        XCTAssertEqual(model.config.minNoteLengthMs, 237)
        XCTAssertEqual(model.beatGrid.beatsPerMeasure, 7)
        let state = await model.regressionWorkerSnapshot()
        XCTAssertEqual(state.snapshot.customMinNoteLengthMs, 237)
        XCTAssertEqual(state.snapshot.customFrameThreshold, 0.53)
        XCTAssertEqual(state.beatsPerMeasure, 7)
        XCTAssertEqual(model.notes, raw)
    }

    @MainActor
    func testSEM078ActualIOSPlayerIncludesPedalReleaseTailAndNoteEnds() throws {
        let player = MidiPlayer()
        defer { player.stop() }
        player.load(notes: [note(0, 1, 60)], sustain: [PedalEvent(startTime: 0, endTime: 3)], dynamics: .detected)
        XCTAssertEqual(player.duration, 4.5, accuracy: 0.00001)
        player.load(notes: [note(0, 1, 60)])
        XCTAssertEqual(player.duration, 2.5, accuracy: 0.00001)
        player.load(notes: [note(0, 1, 72, voice: .melody), note(0.5, 2, 36, voice: .bass)])
        XCTAssertEqual(player.duration, 3.5, accuracy: 0.00001,
                       "The real bundled piano instrument and an iOS sequence with one track per part must load.")
        XCTAssertTrue(player.play(from: 0))
        XCTAssertTrue(player.isPlaying)
        player.stop()
        XCTAssertFalse(player.isPlaying, "Manual stop must stop the sequencer synchronously.")
        player.load(notes: [])
        XCTAssertEqual(player.duration, 0)
        XCTAssertFalse(player.play(from: 0))
    }

    @MainActor
    func testSEM078ViewModelNaturalCompletionWaitsForPedalAndManualStopIsImmediate() async throws {
        let model = await makeViewModel()
        try await model.regressionInstallTake(notes: [note(0, 1, 60)], source: .piano,
                                              sustain: [PedalEvent(startTime: 0, endTime: 3)], duration: 4)
        defer { model.stopPlayback() }
        model.togglePlayback()
        XCTAssertTrue(model.isPlaying, model.errorMessage ?? "The iOS audio engine should start.")
        try await waitUntil(timeout: 5) { model.playhead >= 3.1 || !model.isPlaying }
        XCTAssertTrue(model.isPlaying, "Natural completion must not stop at note-off or pedal-up.")
        XCTAssertGreaterThanOrEqual(model.playhead, 3.1)
        try await waitUntil(timeout: 3) { !model.isPlaying }
        XCTAssertEqual(model.playhead, 4.5, accuracy: 0.02)

        model.togglePlayback()
        XCTAssertTrue(model.isPlaying)
        try await waitUntil(timeout: 1) { model.playhead > 0.05 && model.playhead < 1 }
        model.stopPlayback()
        XCTAssertFalse(model.isPlaying)
        XCTAssertLessThan(model.playhead, 1, "Manual Stop must not wait for the decay tail.")
    }

    /// A falling-notes drag during playback holds the sound (the clock stops
    /// with it), and playback carries on from wherever the drag lets go.
    /// Stopping during the hold makes the let-go spot the cue instead.
    @MainActor
    func testFallingNotesScrubHoldsPlaybackThenPlaysOnFromTheHitLine() async throws {
        let model = await makeViewModel()
        try await model.regressionInstallTake(notes: rhythmicNotes(), duration: 8)
        defer { model.stopPlayback() }
        func now() -> Double { model.clock.time(at: CACurrentMediaTime()) }
        model.togglePlayback()
        XCTAssertTrue(model.isPlaying, model.errorMessage ?? "The iOS audio engine should start.")
        try await waitUntil(timeout: 2) { now() > 0.2 }

        model.holdPlayback()
        XCTAssertTrue(model.isPlaying, "A held drag is still playback as far as the screen goes.")
        XCTAssertTrue(model.isHeld)
        let held = now()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(now(), held, accuracy: 1e-9, "The held clock doesn't move.")
        XCTAssertTrue(model.isPlaying, "The model's tick doesn't mistake the hold for audio stopping.")

        model.resumePlayback(from: 4)
        XCTAssertFalse(model.isHeld)
        XCTAssertEqual(model.playhead, 4)
        try await waitUntil(timeout: 2) { now() > 4.1 }
        XCTAssertTrue(model.isPlaying)
        XCTAssertLessThan(now(), 5, "Plays on from the let-go spot, not from where the drag began.")

        model.holdPlayback()
        model.stopPlayback()
        XCTAssertFalse(model.isPlaying)
        model.resumePlayback(from: 6)
        XCTAssertFalse(model.isPlaying, "Stopped during the drag: letting go only cues.")
        XCTAssertEqual(model.playhead, 6)

        // VoiceOver's bar steps move playback at once.
        model.togglePlayback()
        XCTAssertTrue(model.isPlaying)
        model.seek(to: 2)
        XCTAssertTrue(model.isPlaying)
        XCTAssertFalse(model.isHeld)
        XCTAssertEqual(model.playhead, 2)
        try await waitUntil(timeout: 2) { now() > 2.1 }
    }

    /// The horizontal roll's play marker waits behind the keys until the
    /// user picks where play starts while stopped (a drag through either
    /// roll, a VoiceOver bar step), and goes back there once playback runs
    /// or a new take opens. A cue from anywhere else (a take opening on its
    /// spot) picks nothing.
    @MainActor
    func testTheUsersPickedCueLastsUntilPlaybackRunsOrANewTakeOpens() async throws {
        let model = await makeViewModel()
        try await model.regressionInstallTake(notes: rhythmicNotes(), duration: 8)
        defer { model.stopPlayback() }
        XCTAssertFalse(model.cueChosen, "A take opens with the marker behind the keys.")
        model.cue(at: 2, settled: true)
        XCTAssertFalse(model.cueChosen, "Cued from elsewhere, nothing is picked.")

        model.cue(at: 3, settled: false)
        model.userChoseCue()
        XCTAssertTrue(model.cueChosen, "A drag through the roll while stopped picks the spot.")
        model.togglePlayback()
        XCTAssertTrue(model.isPlaying, model.errorMessage ?? "The iOS audio engine should start.")
        XCTAssertFalse(model.cueChosen, "Playing, the marker is the playing one.")
        model.userChoseCue()
        XCTAssertFalse(model.cueChosen, "A drag during playback scrubs; it picks nothing.")
        model.togglePlayback()
        XCTAssertFalse(model.isPlaying)
        XCTAssertFalse(model.cueChosen, "Stopped, the marker tucks back behind the keys.")

        model.seek(to: 4)
        XCTAssertEqual(model.playhead, 4)
        XCTAssertTrue(model.cueChosen, "A VoiceOver bar step while stopped picks the spot.")
        model.togglePlayback()
        XCTAssertTrue(model.isPlaying)
        model.seek(to: 6)
        XCTAssertFalse(model.cueChosen, "A bar step during playback moves playback, not the cue.")
        model.togglePlayback()

        model.userChoseCue()
        XCTAssertTrue(model.cueChosen)
        model.regressionBeginEmptyTake()
        XCTAssertFalse(model.cueChosen, "A new take opens with the marker behind the keys.")
    }

    // MARK: - Saved takes from before drums were dropped

    /// A take.json written while the any-instrument mode still transcribed
    /// drums: two parts, plus drum hits (one of an unknown kind).
    private let legacyMusicTakeJSON = """
        {"source":"music","sustain":[],
         "notes":[{"start":0.25,"end":1.0,"pitch":72,"amplitude":0.6,"voice":1},
                  {"start":0.25,"end":1.5,"pitch":36,"amplitude":0.7,"voice":3}],
         "drums":[{"time":0.5,"kind":0,"velocity":0.8},{"time":1.0,"kind":1,"velocity":0.9},
                  {"time":1.25,"kind":99,"velocity":0.5}]}
        """

    /// Opening a take saves it again, so a take saved with drum hits keeps
    /// them in its file (and its entry lists them, as 0.99 noted it): a
    /// tester who goes back to Prerelease 0.99 still finds the kit.
    func testSavedTakeWithDrumsKeepsThemWhenSavedAgain() throws {
        let content = try JSONDecoder().decode(SavedTakeContent.self, from: Data(legacyMusicTakeJSON.utf8))
        XCTAssertEqual(content.source, "music")
        XCTAssertEqual(content.noteEvents, [note(0.25, 1, 72, amplitude: 0.6, voice: .melody),
                                            note(0.25, 1.5, 36, amplitude: 0.7, voice: .bass)])
        XCTAssertTrue(content.pedalEvents.isEmpty)
        XCTAssertEqual(content.legacyDrums.map(\.kind), [0, 1, 99], "Hits of a kind this build never knew are kept too.")
        let data = try JSONEncoder().encode(content)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((saved["notes"] as? [Any])?.count, 2)
        let reread = try JSONDecoder().decode(SavedTakeContent.self, from: data)
        XCTAssertEqual(reread.noteEvents, content.noteEvents)
        XCTAssertEqual(reread.source, "music")
        XCTAssertEqual(reread.legacyDrums, content.legacyDrums, "Saving again writes the drum hits back unchanged.")

        // Its entry, noted on saving, lists the drums as 0.99 did; this build skips them.
        let take = SavedTake(id: UUID(), title: "Saved with drums", createdAt: Date(), duration: 2,
                             mode: TranscriptionMode.music.rawValue, noteCount: 2)
        XCTAssertEqual(take.noting(content).kind, "song")
        XCTAssertEqual(take.noting(content).parts, ["melody", "bass", "drums"])
        XCTAssertEqual(take.noting(content).savedParts, [.melody, .bass])

        // A take saved since has none, but still writes the key older builds require.
        let fresh = SavedTakeContent(source: "music", notes: content.noteEvents, sustain: [])
        let freshSaved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(fresh)) as? [String: Any])
        XCTAssertEqual((freshSaved["drums"] as? [Any])?.count, 0)
        XCTAssertEqual(take.noting(fresh).parts, ["melody", "bass"])

        // Hits that don't read as 0.99 wrote them don't keep the take from opening.
        let odd = legacyMusicTakeJSON.replacingOccurrences(of: #""velocity":0.5"#, with: #""velocity":"loud""#)
        let oddContent = try JSONDecoder().decode(SavedTakeContent.self, from: Data(odd.utf8))
        XCTAssertEqual(oddContent.noteEvents, content.noteEvents)
        XCTAssertTrue(oddContent.legacyDrums.isEmpty)
    }

    @MainActor
    func testSavedAnyInstrumentTakeWithDrumsOpensWithItsPartsOnly() async throws {
        let model = await makeViewModel()
        let id = UUID()
        let take = SavedTake(id: id, title: "Saved with drums", createdAt: Date(), duration: 2,
                             mode: TranscriptionMode.music.rawValue, noteCount: 2)
        try TakeLibrary.save(take, content: SavedTakeContent(source: "music", notes: [], sustain: []),
                             audio: [Float](repeating: 0, count: 88200), sampleRate: 44100)
        defer { try? TakeLibrary.delete(id) }
        try Data(legacyMusicTakeJSON.utf8).write(to: TakeLibrary.folder(id).appending(path: "take.json"))

        model.openSavedTake(take)
        try await waitUntil(timeout: 20) { !model.isTranscribing }
        await model.regressionFlushWorker()
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.transcriptionMode == .music)
        XCTAssertTrue(model.notesSource == .music)
        XCTAssertEqual(model.notes.sorted { $0.pitch < $1.pitch },
                       [note(0.25, 1.5, 36, amplitude: 0.7, voice: .bass),
                        note(0.25, 1, 72, amplitude: 0.6, voice: .melody)])
        XCTAssertEqual(model.presentVoices, [.melody, .bass])
        XCTAssertTrue(model.canExport)
        let url = try XCTUnwrap(model.exportMIDI())
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try readMIDI(Data(contentsOf: url))
        XCTAssertEqual(file.notes.map(\.pitch).sorted(), [36, 72])
        XCTAssertFalse(file.notes.contains { $0.channel == 9 }, "The old drum hits are not exported.")
    }

    /// Drums are not transcribed, but a drum-heavy take's percussive onsets
    /// still place the beat when every note is syncopated (MusicBench funk).
    func testDrumHeavyTakeFindsTheBeatFromItsPercussiveOnsets() {
        // 100 BPM: a chord stab on each off-beat and a bass note a sixteenth
        // before the next beat; the kit on the beats (kick on one and three,
        // snare on two and four), hats on the eighths. The eighths are as
        // loud as the beats, so the decoder counts them (200 BPM); in Song
        // mode (the take's evidence carries the audio's chroma) the kick and
        // snare, only on every other grid beat, halve it back
        // (`TempoChoice.countsSubdivisions`). (In round 2 of the Song mode
        // tuning this test ran at 110 BPM, out of reach of the eighths.)
        let period = 60.0 / 100
        let beats = (0..<50).map { 0.5 + Double($0) * period }
        var notes: [NoteEvent] = []
        for (k, t) in beats.enumerated() {
            notes.append(note(t + period / 2, t + 0.7 * period, 64 + k % 3, amplitude: 0.6, voice: .chords))
            notes.append(note(t + 0.75 * period, t + 0.97 * period, 40 + (k / 4) % 3, amplitude: 0.6, voice: .bass))
        }
        let duration = beats.last! + 1
        func spikes(_ times: [Double], _ height: Float) -> [Float] {
            var x = [Float](repeating: 0, count: Int(duration * BeatTracker.fps) + 2)
            for t in times {
                let frame = Int((t * BeatTracker.fps).rounded())
                x[frame] = max(x[frame], height)
            }
            return x
        }
        let tonal = spikes(notes.map(\.startTime), 1)
        let kit = zip(spikes(beats, 1), spikes(beats.map { $0 + period / 2 }, 0.4)).map { max($0, $1) }
        let kick = spikes(beats.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element), 1)
        let snare = spikes(beats.enumerated().filter { !$0.offset.isMultiple(of: 2) }.map(\.element), 1)
        func onBeat(_ result: BeatTracker.Result) -> Double {
            let hits = result.beats.filter { b in beats.contains { abs($0 - b) <= 0.07 } }.count
            return Double(hits) / Double(max(result.beats.count, 1))
        }

        let tonalOnly = BeatTracker.track(notes: notes, duration: duration, beatsPerBar: nil,
                                          audioOnsets: AudioOnsets(onsets: tonal))
        let drumHeavy = AudioOnsets(onsets: tonal, percussion: .init(onsets: kit, low: kick, mid: snare),
                                    chroma: [Float](repeating: 0, count: 12 * Int(duration * OnsetEnvelope.chromaFPS)))
        let withKit = BeatTracker.track(notes: notes, duration: duration, beatsPerBar: nil, audioOnsets: drumHeavy)
        XCTAssertLessThan(onBeat(tonalOnly), 0.2, "The syncopated notes alone put the grid off the beat.")
        XCTAssertGreaterThan(onBeat(withKit), 0.95)
        XCTAssertGreaterThan(withKit.beats.count, 45)
        XCTAssertEqual(withKit.medianBPM, 100, accuracy: 1.5)
    }

    /// A take without a kit (percussive share up to 0.1) gets no percussive
    /// cue, a lighter kit gets it at part weight and a drum-heavy take (0.2 or
    /// more) in full; its tonal onsets are the same either way.
    func testPercussionCueGradedByPercussiveShare() throws {
        let rate = BPConstants.sampleRate
        let harmonic = (0..<Int(2 * rate)).map { i -> Float in
            let t = Double(i) / rate
            return Float(sin(2 * .pi * 220 * t) * (t.truncatingRemainder(dividingBy: 0.5) < 0.25 ? 0.5 : 0.1))
        }
        let percussive = (0..<Int(2 * rate)).map { i -> Float in
            let since = Double(i).truncatingRemainder(dividingBy: 0.3 * rate)
            return since < 200 ? Float(sin(Double(i) * 0.7)) * Float(1 - since / 200) : 0
        }
        let parts = HarmonicPercussive.Output(harmonic: harmonic, percussive: percussive)
        let tonal = OnsetEnvelope.compute(harmonic, sampleRate: rate, bandsPerOctave: OnsetEnvelope.tonalBandsPerOctave)
        XCTAssertFalse(tonal.isEmpty)

        let none = OnsetEnvelope.music(parts, percussiveShare: OnsetEnvelope.kitShare, sampleRate: rate)
        XCTAssertEqual(none, AudioOnsets(onsets: tonal, harmony: OnsetEnvelope.harmonyChange(harmonic, sampleRate: rate)))

        let light = OnsetEnvelope.music(parts, percussiveShare: 0.15, sampleRate: rate)
        XCTAssertEqual(light.onsets, tonal)
        XCTAssertEqual(try XCTUnwrap(light.percussion).weight, 0.5, accuracy: 1e-6)

        let heavy = OnsetEnvelope.music(parts, percussiveShare: OnsetEnvelope.drumHeavyShare, sampleRate: rate)
        XCTAssertEqual(heavy.onsets, tonal)
        let percussion = try XCTUnwrap(heavy.percussion)
        XCTAssertEqual(percussion.weight, 1)
        XCTAssertEqual(OnsetEnvelope.music(parts, percussiveShare: 0.4, sampleRate: rate).percussion?.weight, 1)
        XCTAssertEqual(light.percussion?.onsets, percussion.onsets)
        XCTAssertEqual(percussion.onsets, OnsetEnvelope.compute(percussive, sampleRate: rate))
        XCTAssertEqual(percussion.low, OnsetEnvelope.compute(percussive, sampleRate: rate, bandsPerOctave: 3,
                                                             low: 30, high: 150))
        XCTAssertGreaterThan(percussion.onsets.max() ?? 0, 0)
        XCTAssertGreaterThan(percussion.low.max() ?? 0, 0)
    }

    // MARK: - Countermelody

    func testCountermelodyIsAppendedSoSavedVoicesKeepTheirMeaning() {
        XCTAssertEqual(Voice.allCases.map(\.rawValue), [0, 1, 2, 3, 4])
        XCTAssertEqual(Voice.allCases, [.none, .melody, .chords, .bass, .countermelody])
        XCTAssertEqual(Voice.parts, [.melody, .countermelody, .chords, .bass])
        XCTAssertEqual(Voice.countermelody.label, "Countermelody")
    }

    /// Four 2 s bars: the bass and a sustained note struck on beat 1 (alone,
    /// or as the top of a held chord), the melody moving above it in eighths
    /// from beat 2, a short chord on beats 2 and 4 below everything.
    private func twoLineBars(sustainedAsChordTop: Bool = false) -> [NoteEvent] {
        let sustained = [64, 65, 67, 65]
        let melody = [[72, 74, 76, 77, 76, 74], [74, 76, 77, 79, 77, 76], [76, 77, 79, 81, 79, 77], [74, 72, 71, 72, 74, 72]]
        var notes: [NoteEvent] = []
        for bar in 0..<4 {
            let t = Double(bar) * 2
            notes.append(note(t, t + 1.9, 40 + bar, amplitude: 0.7))
            notes.append(note(t, t + 1.9, sustained[bar], amplitude: 0.75))
            if sustainedAsChordTop {
                notes += [sustained[bar] - 4, sustained[bar] - 7].map { note(t, t + 1.9, $0, amplitude: 0.7) }
            }
            for (k, pitch) in melody[bar].enumerated() {
                let start = t + 0.5 + Double(k) * 0.25
                notes.append(note(start, start + 0.24, pitch, amplitude: 0.8))
            }
            for beat in [0.5, 1.5] { notes += [55, 59].map { note(t + beat, t + beat + 0.2, $0, amplitude: 0.6) } }
        }
        return notes
    }

    func testSustainedLineUnderTheMovingMelodyIsTheCountermelody() {
        let split = VoiceSplitter.assign(twoLineBars())
        XCTAssertEqual(split.filter { $0.voice == .countermelody }.map(\.pitch), [64, 65, 67, 65])
        XCTAssertEqual(split.filter { $0.voice == .melody }.count, 24)
        XCTAssertEqual(split.filter { $0.voice == .bass }.map(\.pitch), [40, 41, 42, 43])
        XCTAssertEqual(Set(split.filter { $0.voice == .chords }.map(\.pitch)), [55, 59])

        // The same notes held as the top of a chord are chord tones.
        let chordal = VoiceSplitter.assign(twoLineBars(sustainedAsChordTop: true))
        XCTAssertFalse(chordal.contains { $0.voice == .countermelody })
        XCTAssertEqual(chordal.filter { $0.voice == .melody }.count, 24)

        // A take merged from two unsettled splits is settled the same way.
        let heard = VoiceSplitter.assign(twoLineBars(), settleLine: false)
        XCTAssertEqual(VoiceSplitter.settleLine(heard).filter { $0.voice == .countermelody }.map(\.pitch),
                       [64, 65, 67, 65])
    }

    func testQuietChordTopsWhileTheMelodyRestsAreChords() {
        // A loud phrase over block chords, then four bars of the chords alone,
        // their top note far under the melody's level.
        let phrase = [72, 74, 76, 77, 79, 77, 76, 74]
        var notes = phrase.enumerated().map { note(Double($0.offset) * 0.5, Double($0.offset) * 0.5 + 0.5, $0.element, amplitude: 0.8) }
        for beat in 0..<8 { notes += [55, 59, 62].map { note(Double(beat), Double(beat) + 0.9, $0, amplitude: 0.5) } }
        for beat in 4..<8 { notes.append(note(Double(beat), Double(beat) + 0.9, 64, amplitude: 0.45)) }
        let split = VoiceSplitter.assign(notes)
        XCTAssertEqual(split.filter { $0.voice == .melody }.map(\.pitch), phrase)
        XCTAssertEqual(split.filter { $0.voice == .chords && $0.pitch == 64 }.count, 4)

        // A solo line keeps its soft notes.
        let solo = (0..<12).map { note(Double($0) * 0.4, Double($0) * 0.4 + 0.35, 67 + $0 % 5, amplitude: $0.isMultiple(of: 2) ? 0.8 : 0.4) }
        XCTAssertTrue(VoiceSplitter.assign(solo).allSatisfy { $0.voice == .melody })

        // A single line in the bass register is the bass, not the melody; a
        // note of it above the bass's range is not.
        let bassLine = (0..<12).map { note(Double($0) * 0.4, Double($0) * 0.4 + 0.35, $0 == 5 ? 67 : [28, 31, 33, 35][$0 % 4]) }
        XCTAssertEqual(VoiceSplitter.assign(bassLine).map(\.voice), (0..<12).map { $0 == 5 ? Voice.melody : .bass })
    }

    func testABandHeardInFragmentsIsNotOneLine() {
        // A bass riff and a tune heard one note at a time, never together:
        // every onset is lone, but the line keeps leaping between registers.
        var band: [NoteEvent] = []
        for k in 0..<16 {
            let t = Double(k) * 0.5
            band.append(k.isMultiple(of: 2) ? note(t, t + 0.2, 40 + k % 3) : note(t, t + 0.2, 67 + k % 4))
        }
        let split = VoiceSplitter.assign(band)
        XCTAssertEqual(split.filter { $0.voice == .bass }.count, 8)
        XCTAssertEqual(split.filter { $0.voice == .melody }.count, 8)

        // A line alone, one note at a time, is one line: the melody ...
        let line = (0..<16).map { note(Double($0) * 0.5, Double($0) * 0.5 + 0.3, [45, 50, 47, 52][$0 % 4]) }
        XCTAssertTrue(VoiceSplitter.assign(line).allSatisfy { $0.voice == .melody })
        XCTAssertTrue(VoiceSplitter.assign(line, percussiveShare: 0.05).allSatisfy { $0.voice == .melody })
        // ... unless a drum kit plays with it: then it is the bass of a band.
        XCTAssertTrue(VoiceSplitter.assign(line, percussiveShare: 0.3).allSatisfy { $0.voice == .bass })
        // A bass riff is the bass either way: alone by its register
        // (`Settings.soloBassMedian`), with a kit as the band's lowest line.
        let riff = (0..<16).map { note(Double($0) * 0.5, Double($0) * 0.5 + 0.3, [28, 35, 33, 40][$0 % 4]) }
        XCTAssertTrue(VoiceSplitter.assign(riff).allSatisfy { $0.voice == .bass })
        XCTAssertTrue(VoiceSplitter.assign(riff, percussiveShare: 0.3).allSatisfy { $0.voice == .bass })
        XCTAssertTrue(VoiceSplitter.assign(riff, percussiveShare: 0.3, hitsWithoutNotes: 0.7).allSatisfy { $0.voice == .bass })
    }

    func testASoloInstrumentWithHardAttacksStaysOneLine() {
        // Slap bass, a marimba, pizzicato strings: the attacks alone push the
        // percussive share over the drum-heavy mark, but every attack starts
        // a note, where a drum kit plays hits between the notes. Each stays one
        // line: the slap bass, in the bass register, all bass
        // (`Settings.soloBassMedian`), the marimba all melody.
        let slap = (0..<16).map { note(Double($0) * 0.25, Double($0) * 0.25 + 0.2, [28, 35, 33, 40][$0 % 4]) }
        XCTAssertTrue(VoiceSplitter.assign(slap, percussiveShare: 0.3, hitsWithoutNotes: 0.05).allSatisfy { $0.voice == .bass })
        let marimba = (0..<16).map { note(Double($0) * 0.25, Double($0) * 0.25 + 0.15, [72, 74, 76, 79, 77, 76, 74, 71][$0 % 8]) }
        XCTAssertTrue(VoiceSplitter.assign(marimba, percussiveShare: 0.74, hitsWithoutNotes: 0.06).allSatisfy { $0.voice == .melody })

        // The measure: attacks in the percussive part's onset envelope with no
        // note starting within 50 ms.
        let fps = BeatTracker.fps
        var envelope = [Float](repeating: 0.05, count: 450)
        let struck = stride(from: 25, to: 400, by: 50).map { $0 }
        for i in struck { envelope[i] = 1; envelope[i - 1] = 0.5; envelope[i + 1] = 0.5 }
        let starts = struck.map { Double($0) / fps + 0.02 }
        XCTAssertEqual(SourceProfiler.hitsWithoutNotes(envelope, fps: fps, noteStarts: starts), 0)
        // A kit's hats between the notes.
        for i in struck { envelope[i + 25] = 0.8 }
        XCTAssertEqual(SourceProfiler.hitsWithoutNotes(envelope, fps: fps, noteStarts: starts) ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertNil(SourceProfiler.hitsWithoutNotes([Float](repeating: 0, count: 100), fps: fps, noteStarts: starts))
    }

    func testRefineMergeTakesBothLinesFromThePreview() {
        let engine = [note(0, 1, 60, voice: .chords), note(0, 2, 64, voice: .countermelody),
                      note(0.5, 1, 72, voice: .melody), note(2, 4, 67, voice: .countermelody),
                      note(3, 3.5, 62, voice: .melody)]
        let preview = [note(0.01, 2, 64, voice: .countermelody), note(0.5, 1, 74, voice: .melody),
                       note(3.02, 3.5, 74, voice: .melody)]
        let merged = NoteFusion.melodyFromReference(engine, reference: preview)
        XCTAssertEqual(merged, [note(0, 1, 60, voice: .chords), note(0, 2, 64, voice: .countermelody),
                                note(0.5, 1, 72, voice: .chords), note(0.5, 1, 74, voice: .melody),
                                note(2, 4, 67, voice: .chords), note(3.02, 3.5, 74, voice: .melody)],
                       """
                       The preview's lines replace the engine's: a line note both heard keeps the engine's onset, \
                       and the engine's line note an octave under the preview's leaves. The engine's other line \
                       notes stay as chord tones.
                       """)
    }

    func testTheLineFollowsTheSingerUnderTheBand() {
        // A band strums a chord on every beat, its top note well above a voice
        // that sings between the strums, partly under A3. The sweep calls the
        // chord tops the melody (the voice sounds under held chord notes);
        // the line choice follows the voice: louder, struck alone, moving by
        // step, and heard only by the preview engine.
        var take: [NoteEvent] = []
        var band: [NoteEvent] = []
        let tune = [55, 57, 59, 60, 59, 57, 55, 53, 55, 57, 59, 62, 60, 59, 57, 55]
        for k in 0..<16 {
            let t = Double(k) * 0.5
            band += [64, 67, 72].map { note(t, t + 0.45, $0, amplitude: 0.6) }
            take.append(note(t + 0.25, t + 0.45, tune[k], amplitude: 0.8))
        }
        take += band
        let swept = VoiceSplitter.assign(take, settleLine: false)
        XCTAssertEqual(Set(swept.filter { $0.voice == .melody }.map(\.pitch)), [72])
        let line = VoiceSplitter.chooseLine(swept, otherEngine: band)
        XCTAssertEqual(line.filter { $0.voice == .melody }.map(\.pitch), tune)
        XCTAssertFalse(line.contains { $0.voice == .melody && $0.pitch == 72 })

        // An instrumental lead over its chords, which both engines hear, stays
        // the sweep's top line.
        var arrangement: [NoteEvent] = []
        let lead = [72, 74, 76, 79, 77, 76, 74, 72, 71, 72, 74, 76, 74, 72, 71, 72]
        for k in 0..<16 {
            let t = Double(k) * 0.5
            arrangement += [60, 64, 67].map { note(t, t + 0.45, $0, amplitude: 0.6) }
            arrangement.append(note(t, t + 0.45, lead[k], amplitude: 0.8))
        }
        let split = VoiceSplitter.assign(arrangement, settleLine: false)
        XCTAssertEqual(VoiceSplitter.chooseLine(split, otherEngine: arrangement).filter { $0.voice == .melody }.map(\.pitch),
                       lead)
    }

    @MainActor
    func testCountermelodyReopensFromASavedTakeAndExportsAsItsOwnTrack() async throws {
        let json = """
            {"source":"music","sustain":[],
             "notes":[{"start":0.25,"end":1.0,"pitch":72,"amplitude":0.6,"voice":1},
                      {"start":0.25,"end":1.5,"pitch":67,"amplitude":0.6,"voice":4},
                      {"start":0.25,"end":1.5,"pitch":60,"amplitude":0.6,"voice":2},
                      {"start":0.25,"end":1.5,"pitch":36,"amplitude":0.7,"voice":3}]}
            """
        let content = try JSONDecoder().decode(SavedTakeContent.self, from: Data(json.utf8))
        XCTAssertEqual(content.noteEvents.map(\.voice), [.melody, .countermelody, .chords, .bass])
        let data = try JSONEncoder().encode(content)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let notes = try XCTUnwrap(saved["notes"] as? [[String: Any]])
        XCTAssertEqual(notes.compactMap { $0["voice"] as? Int }, [1, 2, 2, 3],
                       "Builds without the countermelody read it as chords.")
        XCTAssertEqual(notes.map { $0["part"] as? Int }, [nil, 4, nil, nil])
        XCTAssertEqual(try JSONDecoder().decode(SavedTakeContent.self, from: data).noteEvents, content.noteEvents)

        let model = await makeViewModel()
        try await model.regressionInstallTake(notes: content.noteEvents, source: .music, duration: 2)
        XCTAssertEqual(model.presentVoices, [.melody, .countermelody, .chords, .bass])
        let url = try XCTUnwrap(model.exportMIDI())
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try readMIDI(Data(contentsOf: url))
        XCTAssertEqual(file.notes.sorted { $0.channel < $1.channel }.map(\.pitch), [72, 67, 60, 36],
                       "Melody, countermelody, chords and bass take channels 1-4 in that order.")

        model.hiddenVoices = [.countermelody]
        XCTAssertFalse(model.visibleNotes.contains { $0.voice == .countermelody })
        let withoutCounter = try XCTUnwrap(model.exportMIDI())
        defer { try? FileManager.default.removeItem(at: withoutCounter) }
        let shown = try readMIDI(Data(contentsOf: withoutCounter))
        XCTAssertEqual(shown.notes.map(\.pitch).sorted(), [36, 60, 72], "A hidden countermelody is not exported.")
    }

    // MARK: - Chord style

    /// Simplified swaps the chords part, and only it, for ChordVoicer's
    /// voicings on the roll, in playback and in the MIDI file; the take keeps
    /// its transcribed notes, and a new take starts as played.
    @MainActor
    func testSimplifiedChordStyleChangesOnlyTheChordsPartShownPlayedAndExported() async throws {
        let model = await makeViewModel()
        var notes: [NoteEvent] = []
        for (bar, shape) in [[48, 55, 64, 67, 72], [45, 57, 60, 64, 69], [41, 57, 60, 65, 72], [43, 55, 59, 62, 67]].enumerated() {
            let t = Double(bar) * 2
            for beat in [0.0, 1.0] { notes += shape.map { note(t + beat, t + beat + 0.9, $0, amplitude: 0.5, voice: .chords) } }
            notes.append(note(t, t + 1.9, 36 + bar, amplitude: 0.7, voice: .bass))
            notes.append(note(t + 0.5, t + 1.5, 76 + bar, amplitude: 0.8, voice: .melody))
        }
        try await model.regressionInstallTake(notes: notes, source: .music, duration: 8)
        XCTAssertEqual(model.chordStyle, .asPlayed)
        XCTAssertEqual(model.visibleNotes, notes)
        XCTAssertTrue(model.canChooseChordStyle)
        let simplified = try XCTUnwrap(model.simplifiedNotes)
        XCTAssertEqual(simplified, ChordVoicer.voice(notes: notes, chords: model.chordSegments, grid: model.beatGrid).notes)
        XCTAssertNotEqual(simplified.filter { $0.voice == .chords }.count, notes.filter { $0.voice == .chords }.count,
                          "Five- and four-note shapes become three-note voicings.")

        model.chordStyle = .simplified
        XCTAssertEqual(model.notes, notes, "The take keeps its transcribed notes.")
        XCTAssertEqual(model.visibleNotes, simplified)
        XCTAssertEqual(model.visibleNotes.filter { $0.voice != .chords }, notes.filter { $0.voice != .chords })
        model.togglePlayback()
        XCTAssertTrue(model.isPlaying, "Playback plays the simplified chords.")
        let loads = model.regressionPlaybackLoadCount
        model.chordStyle = .asPlayed
        try await waitUntil(timeout: 5) { model.regressionPlaybackLoadCount > loads }
        XCTAssertTrue(model.isPlaying, "Switching style reloads the notes and keeps playing.")
        model.chordStyle = .simplified
        try await waitUntil(timeout: 5) { model.regressionPlaybackLoadCount > loads + 1 }
        model.stopPlayback()

        let url = try XCTUnwrap(model.exportMIDI())
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try readMIDI(Data(contentsOf: url))
        // Melody, chords and bass take channels 1-3.
        XCTAssertEqual(file.notes.filter { $0.channel == 1 }.map(\.pitch).sorted(),
                       simplified.filter { $0.voice == .chords }.map(\.pitch).sorted())
        XCTAssertEqual(file.notes.filter { $0.channel != 1 }.map(\.pitch).sorted(),
                       notes.filter { $0.voice != .chords }.map(\.pitch).sorted())

        model.hiddenVoices = [.chords]
        XCTAssertFalse(model.visibleNotes.contains { $0.voice == .chords })
        model.hiddenVoices = []

        try await model.regressionInstallTake(notes: notes, source: .music, duration: 8)
        XCTAssertEqual(model.chordStyle, .asPlayed, "A new take starts as played.")
        XCTAssertEqual(model.visibleNotes, notes)
    }

    @MainActor
    func testInputLevelMeterMapsRMSOnADecibelScaleAndSmooths() {
        XCTAssertEqual(InputLevelMeter.normalized(rms: 0), 0)
        XCTAssertEqual(InputLevelMeter.normalized(rms: .nan), 0)
        XCTAssertEqual(InputLevelMeter.normalized(rms: 1), 1)
        XCTAssertEqual(InputLevelMeter.normalized(rms: pow(10, -60 / 20)), 0, "Below the floor reads as silence.")
        XCTAssertEqual(InputLevelMeter.normalized(rms: pow(10, -33 / 20)), 0.5, accuracy: 0.001,
                       "Linear in decibels between the floor and the ceiling.")

        let meter = InputLevelMeter()
        meter.push(1)
        XCTAssertGreaterThan(meter.level, 0.4, "Rises quickly…")
        XCTAssertLessThan(meter.level, 1, "…but not in one jump.")
        for _ in 0..<20 { meter.push(1) }
        XCTAssertEqual(meter.level, 1, accuracy: 0.01)
        meter.push(0)
        XCTAssertGreaterThan(meter.level, 0.7, "Falls more slowly than it rises.")
        XCTAssertEqual(meter.history.count, InputLevelMeter.historyCount)
        XCTAssertEqual(meter.history.last, meter.level)
        meter.stop()
        XCTAssertEqual(meter.level, 0)
        XCTAssertTrue(meter.history.allSatisfy { $0 == 0 })
    }

    /// A take's list entry notes its kind and a song's parts, so Home lays its
    /// row out right before reading its notes; an entry saved before these
    /// were kept still reads, and falls back to its mode.
    @MainActor
    func testSavedTakesNoteTheirKindAndParts() throws {
        let old = #"{"id":"\#(UUID().uuidString)","title":"Old","createdAt":0,"duration":2,"mode":"music","noteCount":2}"#
        let take = try JSONDecoder().decode(SavedTake.self, from: Data(old.utf8))
        XCTAssertNil(take.kind)
        XCTAssertNil(take.savedParts)
        XCTAssertEqual(ToneRow.provisionalKind(take), .song, "An older any-instrument take is a song until it's read.")

        func content(_ voices: [Voice]) -> SavedTakeContent {
            let notes = voices.enumerated().map { i, voice in
                NoteEvent(startTime: Double(i), endTime: Double(i) + 0.5, pitch: 60 + i, amplitude: 0.5, voice: voice)
            }
            return SavedTakeContent(source: "music", notes: notes, sustain: [])
        }
        let line = take.noting(content([.melody, .melody]))
        XCTAssertEqual(line.kind, "instrument")
        XCTAssertNil(line.parts)
        XCTAssertEqual(ToneRow.provisionalKind(line), .instrument, "One line is an Instrument row at once.")

        let band = take.noting(content([.none, .bass, .chords]))
        XCTAssertEqual(band.kind, "song")
        XCTAssertEqual(band.parts, ["chords", "bass"])
        XCTAssertEqual(band.savedParts, [.chords, .bass])
        XCTAssertEqual(try JSONDecoder().decode(SavedTake.self, from: JSONEncoder().encode(band)), band)

        var piano = take
        piano.mode = TranscriptionMode.piano.rawValue
        XCTAssertEqual(piano.noting(content([.none])).savedKind, .piano)
        XCTAssertNil(piano.noting(content([.none])).parts)
    }

    /// A countermelody gets its own lane in a song's preview, between the melody
    /// and the chords, however the take holds it: as notes not yet written,
    /// as saved (chords for older builds, the part under "part"), or as a
    /// save from before that stand-in (raw value 4).
    @MainActor
    func testHomeSongPreviewsGiveTheCountermelodyItsOwnLane() throws {
        XCTAssertEqual(TonePreview.Part.allCases.map(\.voice), Voice.parts, "Lanes follow the app's part order.")
        XCTAssertEqual(TonePreview.Part.countermelody.letter, "Ct")
        XCTAssertEqual(TonePreview.Part.countermelody.name, "countermelody")

        // Two bars of each part: a 4 s song at 120 BPM.
        var notes: [NoteEvent] = []
        for beat in 0..<8 {
            let t = Double(beat) * 0.5
            notes.append(NoteEvent(startTime: t, endTime: t + 0.45, pitch: 76 + beat % 3, amplitude: 0.7, voice: .melody))
            notes.append(NoteEvent(startTime: t, endTime: t + 0.45, pitch: 36, amplitude: 0.6, voice: .bass))
            if beat % 2 == 0 {
                notes.append(NoteEvent(startTime: t, endTime: t + 0.9, pitch: 67 + beat / 2, amplitude: 0.5, voice: .countermelody))
                notes += [48, 52, 55].map { NoteEvent(startTime: t, endTime: t + 0.9, pitch: $0, amplitude: 0.4, voice: .chords) }
            }
        }
        let content = SavedTakeContent(source: "music", notes: notes, sustain: [])
        let take = SavedTake(id: UUID(), title: "Duet", createdAt: Date(), duration: 4.5,
                             mode: TranscriptionMode.music.rawValue, noteCount: notes.count)
        let all: [TonePreview.Part] = [.melody, .countermelody, .chords, .bass]

        let saved = try JSONDecoder().decode(SavedTakeContent.self, from: JSONEncoder().encode(content))
        XCTAssertEqual(Set(saved.notes.map(\.voice)), [1, 2, 3], "On file the countermelody is chords…")
        var beforeStandIn = saved
        for i in beforeStandIn.notes.indices where beforeStandIn.notes[i].part != nil {
            beforeStandIn.notes[i].voice = beforeStandIn.notes[i].part!
            beforeStandIn.notes[i].part = nil
        }
        for (held, how) in [(content, "unsaved"), (saved, "saved"), (beforeStandIn, "saved before the stand-in")] {
            let noted = take.noting(held)
            XCTAssertEqual(noted.kind, "song", how)
            XCTAssertEqual(noted.parts, all.map(\.rawValue), how)
            XCTAssertEqual(noted.savedParts, all, how)
            let preview = TonePreview.make(take: take, content: held)
            XCTAssertEqual(preview.parts, all, how)
            XCTAssertFalse(preview.lanes[1].bars.isEmpty, "…but its notes land in their own lane (\(how)).")
            XCTAssertEqual(preview.lanes[1].bars.count, 4, how)
            XCTAssertEqual(preview.lanes[2].bars.count, 4, "The chords keep one block a strum, without it (\(how)).")
        }

        // A melody and a countermelody alone are two lines: a song, not an Instrument tone.
        let duet = SavedTakeContent(source: "music", notes: notes.filter { $0.voice == .melody || $0.voice == .countermelody },
                                    sustain: [])
        XCTAssertEqual(take.noting(duet).savedKind, .song)
        XCTAssertEqual(take.noting(duet).savedParts, [.melody, .countermelody])
    }

    /// Prerelease 0.99 noted a take with drums as a song with a "drums" part.
    /// Home skips the name it no longer shows, and a song that was a melody
    /// over drums is one line now: an Instrument tone, before and after its
    /// notes are read.
    @MainActor
    func testOlderEntriesThatListDrumsAreLaidOutWithoutThem() throws {
        /// An entry as 0.99 saved it, its parts given as JSON.
        func entry(_ parts: String, notes: Int = 8) throws -> SavedTake {
            let json = #"{"id":"\#(UUID().uuidString)","title":"0.99","createdAt":0,"duration":4,"mode":"music","#
                + #""noteCount":\#(notes),"kind":"song","parts":\#(parts)}"#
            return try JSONDecoder().decode(SavedTake.self, from: Data(json.utf8))
        }
        let band = try entry(#"["melody","chords","bass","drums"]"#)
        XCTAssertEqual(band.savedParts, [.melody, .chords, .bass], "Unknown part names are skipped.")
        XCTAssertEqual(band.savedKind, .song)
        let groove = try entry(#"["chords","drums"]"#)
        XCTAssertEqual(groove.savedParts, [.chords])
        XCTAssertEqual(groove.savedKind, .song)
        let tune = try entry(#"["melody","drums"]"#)
        XCTAssertEqual(tune.savedParts, [.melody])
        XCTAssertEqual(tune.savedKind, .instrument, "A melody over drums is one line now.")
        XCTAssertEqual(ToneRow.provisionalKind(tune), .instrument)
        let drumsAlone = try entry(#"["drums"]"#, notes: 0)
        XCTAssertEqual(drumsAlone.savedKind, .instrument, "Drums alone leave no part to show.")
        // VoiceOver doesn't call a take without notes a line.
        XCTAssertTrue(ToneRow(take: drumsAlone, preview: nil).accessibilityText.hasPrefix("0.99. Instrument. 0:04, 0 notes."))
        XCTAssertTrue(ToneRow(take: tune, preview: nil).accessibilityText.hasPrefix("0.99. Instrument, one line. 0:04, 8 notes."))

        // Its take.json, with the drum hits that build saved: read the same way.
        let take = """
            {"source":"music","sustain":[],
             "notes":[{"start":0.0,"end":0.4,"pitch":72,"amplitude":0.6,"voice":1},
                      {"start":0.5,"end":0.9,"pitch":74,"amplitude":0.6,"voice":1},
                      {"start":1.0,"end":1.4,"pitch":76,"amplitude":0.6,"voice":1},
                      {"start":1.5,"end":1.9,"pitch":77,"amplitude":0.6,"voice":1}],
             "drums":[{"time":0.0,"kind":0,"velocity":0.8},{"time":0.5,"kind":1,"velocity":0.7}]}
            """
        let content = try JSONDecoder().decode(SavedTakeContent.self, from: Data(take.utf8))
        let preview = TonePreview.make(take: tune, content: content)
        XCTAssertEqual(preview.kind, .instrument)
        XCTAssertEqual(preview.roll.count, 4)
        // Saved again (opened), it keeps its hits and is noted as 0.99 noted
        // it, and this build still lays it out as one line.
        let resaved = tune.noting(content)
        XCTAssertEqual(resaved.kind, "song")
        XCTAssertEqual(resaved.parts, ["melody", "drums"])
        XCTAssertEqual(resaved.savedKind, .instrument)
        // Without the hits it is noted as what it is now.
        var withoutDrums = content
        withoutDrums.legacyDrums = []
        XCTAssertEqual(tune.noting(withoutDrums).kind, "instrument")
        XCTAssertNil(tune.noting(withoutDrums).parts)
    }

    /// A Tone's row: under its title its kind, its key once that's known
    /// and its length; at the trailing edge its day, with the year for
    /// another year's; and to VoiceOver its key last, after the day.
    @MainActor
    func testHomeRowsSayKindKeyLengthAndDay() {
        let line = SavedTake(id: UUID(), title: "Hummed", createdAt: .now, duration: 16,
                             mode: TranscriptionMode.music.rawValue, noteCount: 12, kind: "instrument")
        XCTAssertEqual(ToneRow(take: line, preview: nil).metaText, "Instrument · 0:16", "No key until the notes are read.")

        let song = SavedTake(id: UUID(), title: "Take Five", createdAt: .now, duration: 330,
                             mode: TranscriptionMode.music.rawValue, noteCount: 2_400, kind: "song")
        var preview = TonePreview(kind: .song)
        preview.key = MusicalKey(tonic: 3, minor: true)
        let row = ToneRow(take: song, preview: preview)
        XCTAssertEqual(row.metaText, "Song · E♭ minor · 5:30")
        XCTAssertEqual(row.accessibilityText, "Take Five. Song. 5:30, 2,400 notes. Today. In E♭ minor.")
        XCTAssertFalse(ToneRow(take: song, preview: nil).accessibilityText.contains(" In "))

        XCTAssertEqual(ToneRow.dayLabel(.now), "Today")
        XCTAssertEqual(ToneRow.dayLabel(.now.addingTimeInterval(-86_400)), "Yesterday")
        let calendar = Calendar.current
        let thisYear = calendar.component(.year, from: .now)
        let lastYear = calendar.date(byAdding: .year, value: -1, to: .now)!
        XCTAssertTrue(ToneRow.dayLabel(lastYear).contains(String(thisYear - 1)), ToneRow.dayLabel(lastYear))
        let earlierThisYear = calendar.date(from: DateComponents(year: thisYear, month: 1, day: 1))!
        if !calendar.isDateInToday(earlierThisYear) && !calendar.isDateInYesterday(earlierThisYear) {
            XCTAssertFalse(ToneRow.dayLabel(earlierThisYear).contains(String(thisYear)), "This year's go without it.")
        }
    }

    /// A piano thumbnail draws a left hand deeper only where the take's
    /// hands part.
    func testHomePianoRollLightensOnlyARealLeftHand() {
        func n(_ start: Double, _ end: Double, _ pitch: Int) -> SavedTakeContent.Note {
            SavedTakeContent.Note(start: start, end: end, pitch: pitch, amplitude: 0.6, voice: 0)
        }
        // Two hands: a broken chord a beat under a tune in eighths, a fifth above it.
        var hands: [SavedTakeContent.Note] = []
        for beat in 0..<16 {
            let t = Double(beat) * 0.5
            hands.append(n(t, t + 0.45, [48, 55, 60, 55][beat % 4]))
            hands.append(n(t, t + 0.2, [72, 76, 79, 67][beat % 4]))
            hands.append(n(t + 0.25, t + 0.45, [74, 77, 71, 72][beat % 4]))
        }
        XCTAssertEqual(TonePreview.handSplit(hands), 67, "The left hand is below the tune's lowest note.")

        // Both hands low, mostly below middle C and overlapping: no left hand of its own.
        let low = hands.map { n($0.start, $0.end, $0.pitch >= 67 ? $0.pitch - 24 : $0.pitch - 7) }
        XCTAssertNil(TonePreview.handSplit(low), "A take played low is drawn in the deep shade, not the light one.")

        // Both hands low, a broken chord around a tune: the chord's top notes sit
        // a minor third over the tune, but they're the left hand's too.
        var lowTune: [SavedTakeContent.Note] = []
        for beat in 0..<16 {
            let t = Double(beat) * 0.5
            lowTune.append(n(t, t + 0.45, [48, 55, 60, 55, 45, 52, 57, 52][beat % 8]))
            lowTune.append(n(t, t + 0.4, [48, 50, 52, 50, 47, 48, 43, 47][beat % 8]))
        }
        XCTAssertNil(TonePreview.handSplit(lowTune))

        // One line with a leap: the notes never sound together.
        let line = [60, 62, 64, 67, 69, 72, 69, 67, 64, 62, 60, 67].enumerated().map { i, pitch in
            n(Double(i) * 0.5, Double(i) * 0.5 + 0.4, pitch)
        }
        XCTAssertNil(TonePreview.handSplit(line))
        XCTAssertNil(TonePreview.handSplit([n(0, 1, 60)]))
        XCTAssertNil(TonePreview.handSplit([]))
    }

    func testMicRecorderRMSReadsTheLoudestChannel() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: 48000, channels: 2, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        buffer.frameLength = 4800
        let data = try XCTUnwrap(buffer.floatChannelData)
        // Channel 0 silent, channel 1 a whole number of 440 Hz cycles at 0.5.
        for i in 0..<4800 {
            data[0][i] = 0
            data[1][i] = 0.5 * sin(2 * .pi * 440 * Float(i) / 48000)
        }
        XCTAssertEqual(MicRecorder.rms(of: buffer), Float(0.5) / Float(2).squareRoot(), accuracy: 0.002)
        buffer.frameLength = 0
        XCTAssertEqual(MicRecorder.rms(of: buffer), 0)
    }

    @MainActor
    private func assertPreserved(_ model: TranscriberViewModel, notes: [NoteEvent], raw: [NoteEvent],
                                 cleanup: CleanupResult, pedal: [PedalEvent],
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(model.notes, notes, file: file, line: line)
        XCTAssertEqual(model.rawNotes, raw, file: file, line: line)
        XCTAssertEqual(model.cleanup, cleanup, file: file, line: line)
        XCTAssertEqual(model.sustain, pedal, file: file, line: line)
        XCTAssertTrue(model.notesSource == .piano, file: file, line: line)
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval, _ predicate: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            guard Date() < deadline else {
                XCTFail("Timed out after \(timeout) seconds waiting for the app condition.")
                throw TestFailure.timeout
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor
    private func writeSilenceWAV(to url: URL, duration: Double) throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: 44100, channels: 1, interleaved: false))
        let frames = AVAudioFrameCount((duration * format.sampleRate).rounded())
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        let data = try XCTUnwrap(buffer.floatChannelData)
        data[0].update(repeating: 0, count: Int(frames))
        buffer.frameLength = frames
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        file.close() // Flush the test file's header before the app opens it.
    }

    private enum TestFailure: Error { case timeout, midi(OSStatus) }

    private struct ParsedMIDI {
        struct Note {
            var pitch: Int
            var velocity: Int
            var channel: Int
            var start: Double
            var end: Double
        }
        struct Control { var number: Int; var value: Int; var time: Double }
        var notes: [Note] = []
        var controls: [Control] = []
    }

    /// Use Apple's independent SMF parser to read the files exported through
    /// TranscriberViewModel. This verifies the saved artifact, not just its URL.
    private func readMIDI(_ data: Data) throws -> ParsedMIDI {
        var optionalSequence: MusicSequence?
        let created = NewMusicSequence(&optionalSequence)
        guard created == noErr, let sequence = optionalSequence else { throw TestFailure.midi(created) }
        defer { DisposeMusicSequence(sequence) }
        let loaded = MusicSequenceFileLoadData(sequence, data as CFData, .midiType, [])
        guard loaded == noErr else { throw TestFailure.midi(loaded) }
        func seconds(_ beat: Double) -> Double {
            var seconds: Float64 = 0
            MusicSequenceGetSecondsForBeats(sequence, beat, &seconds)
            return seconds
        }
        var result = ParsedMIDI()
        var count: UInt32 = 0
        MusicSequenceGetTrackCount(sequence, &count)
        for index in 0..<count {
            var optionalTrack: MusicTrack?
            MusicSequenceGetIndTrack(sequence, index, &optionalTrack)
            guard let track = optionalTrack else { continue }
            var optionalIterator: MusicEventIterator?
            let status = NewMusicEventIterator(track, &optionalIterator)
            guard status == noErr, let iterator = optionalIterator else { throw TestFailure.midi(status) }
            defer { DisposeMusicEventIterator(iterator) }
            var hasEvent: DarwinBoolean = false
            MusicEventIteratorHasCurrentEvent(iterator, &hasEvent)
            while hasEvent.boolValue {
                var beat: MusicTimeStamp = 0
                var type: MusicEventType = 0
                var pointer: UnsafeRawPointer?
                var size: UInt32 = 0
                MusicEventIteratorGetEventInfo(iterator, &beat, &type, &pointer, &size)
                if let pointer {
                    if type == kMusicEventType_MIDINoteMessage {
                        let note = pointer.load(as: MIDINoteMessage.self)
                        result.notes.append(.init(pitch: Int(note.note), velocity: Int(note.velocity),
                                                  channel: Int(note.channel), start: seconds(beat),
                                                  end: seconds(beat + Double(note.duration))))
                    } else if type == kMusicEventType_MIDIChannelMessage {
                        let control = pointer.load(as: MIDIChannelMessage.self)
                        if control.status & 0xF0 == 0xB0 {
                            result.controls.append(.init(number: Int(control.data1), value: Int(control.data2),
                                                         time: seconds(beat)))
                        }
                    }
                }
                MusicEventIteratorNextEvent(iterator)
                MusicEventIteratorHasCurrentEvent(iterator, &hasEvent)
            }
        }
        return result
    }
}
