import Foundation
import Combine
import AVFoundation
import Observation
import Synchronization
import UIKit

/// Which engine produced the notes on screen.
enum NotesSource {
    case none
    /// Basic Pitch: live preview while recording, or until the piano model finishes.
    case quick
    /// Transkun piano model, run on the finished take.
    case piano
    /// Any-instrument pass (TakePipeline): melody, countermelody, chords and bass, on the finished take.
    case music
}

/// The model's playhead, and whether the user picked it, observed on their
/// own (see `TranscriberViewModel.playhead` and `cueChosen`).
@MainActor @Observable
final class PlayheadStore {
    var time: Double = 0
    var chosen = false
}

/// Identifies one refine pass: the take it belongs to and the mode change it started after.
nonisolated struct RefinePass: Equatable {
    let take: Int
    let mode: Int
}

@MainActor
final class TranscriberViewModel: ObservableObject {
    @Published private(set) var notes: [NoteEvent] = [] {
        // Keep what you hear in step with what's on screen, e.g. when the
        // piano model replaces the quick notes mid-playback.
        didSet {
            presentVoices = Set(notes.map(\.voice))
            if isPlaying, notes != oldValue { reloadPlayback() }
        }
    }
    /// When the sustain pedal was down, per the piano model (empty for quick notes).
    @Published private(set) var sustain: [PedalEvent] = []
    @Published private(set) var melody: [NoteEvent] = []
    @Published private(set) var chordSegments: [ChordSegment] = []
    /// The take's notes with the chords part rebuilt from the chord names
    /// (`ChordVoicer`); nil while recording, when only the transcribed notes show.
    @Published private(set) var simplifiedNotes: [NoteEvent]? = nil {
        didSet {
            if chordStyle == .simplified, isPlaying, simplifiedNotes != oldValue { reloadPlayback() }
        }
    }
    /// How the chords part is shown, played and exported: as transcribed, or
    /// simplified into plain shapes from the chord names. Per take: saved
    /// with it, and every new take starts as played.
    @Published var chordStyle: ChordStyle = .asPlayed {
        didSet { if chordStyle != oldValue { chordStyleChanged() } }
    }
    @Published private(set) var chart: ChartSuggestion?
    @Published private(set) var isAnalyzingChart = false
    /// The detector's output before AI cleanup; empty when no cleanup is applied.
    @Published private(set) var rawNotes: [NoteEvent] = []
    @Published private(set) var cleanup: CleanupResult?
    @Published private(set) var isCleaningUp = false
    @Published private(set) var duration: Double = 0
    @Published private(set) var isRecording = false
    /// Between tapping Record and the microphone running (permission, model load).
    @Published private(set) var isStartingTake = false
    /// Turning a video into audio or downloading a link, before transcribing.
    @Published private(set) var isPreparingImport = false
    /// Saved takes, newest first (see `TakeLibrary`).
    @Published private(set) var savedTakes: [SavedTake] = []
    /// The saved take that's open: the Tone it was opened from, or the one a
    /// new take is saving as (in the library once its first notes are
    /// saved). Home's long-press menu acts on that Tone as it stands, hidden
    /// parts and an AI cleanup included, and opens any other first. Nil
    /// before the first take, and once the open one is deleted.
    @Published private(set) var openSavedTakeID: UUID?
    /// Experimental: accept links (shared from other apps or pasted).
    @Published var linkImportEnabled = true {
        didSet { Self.defaults.set(linkImportEnabled, forKey: "linkImportEnabled") }
    }
    @Published private(set) var isTranscribing = false
    @Published private(set) var isPlaying = false
    @Published private(set) var notesSource: NotesSource = .none
    /// 0...1 while the piano model or the any-instrument pass is refining the take, nil otherwise.
    @Published private(set) var refineProgress: Double?
    /// Piano (refined by the piano model) or any instrument (split into melody, countermelody, chords and bass).
    @Published var transcriptionMode: TranscriptionMode = .piano {
        didSet {
            guard transcriptionMode != oldValue else { return }
            Self.defaults.set(transcriptionMode.rawValue, forKey: "transcriptionMode")
            let mode = transcriptionMode
            let reactToTake = !openingTake
            refineGeneration.wrappingAdd(1, ordering: .relaxed)   // stop the other mode's pass
            refineProgress = nil
            queue.async { [weak self] in
                guard let self else { return }
                self.workerMode = mode
                self.refineGeneration.wrappingAdd(1, ordering: .relaxed)
                // Opening a saved take sets its mode; the take brings its own notes.
                guard reactToTake else { return }
                // The pass that was running is cancelled; its start and progress
                // updates were queued on the main actor ahead of this.
                Task { @MainActor in
                    self.refineProgress = nil
                    self.endRefineActivity()
                }
                guard self.takeFinalized else {
                    if self.engine != nil {
                        self.extractAndPublish(live: true)
                    } else {
                        // No take yet: just keep the UI numbers honest.
                        let resolved = self.workerModeSnapshot.mode.resolved(snapshot: self.workerModeSnapshot,
                                                                             stats: EngineStats(), for: mode)
                        self.workerConfig = resolved
                        Task { @MainActor in self.config = resolved }
                    }
                    return
                }
                self.refineOrPublish(duration: self.engine?.duration ?? 0)
            }
        }
    }
    /// Parts hidden from the roll and muted in playback (any-instrument takes).
    @Published var hiddenVoices: Set<Voice> = [] {
        didSet { if hiddenVoices != oldValue { partsVisibilityChanged() } }
    }
    /// The parts the take has notes in (for the parts bar).
    @Published private(set) var presentVoices: Set<Voice> = []
    /// Re-transcribe finished Piano takes with the high-accuracy piano model:
    /// the default for new takes (Home's Settings). Changing it never touches
    /// the take that's open, which may not be on screen at all; Transcription
    /// in a Tone's long-press menu changes that take (`setTakeUsesPianoModel`).
    @Published var usePianoModel = true {
        didSet { Self.defaults.set(usePianoModel, forKey: "usePianoModel") }
    }
    /// Whether the open take is re-transcribed with the piano model while
    /// it's a Piano take: `usePianoModel` when the take starts, the save's
    /// own choice when a Tone is reopened, and changed for this take alone
    /// under Transcription in its long-press menu. Mirrors `workerUsePiano`.
    @Published private(set) var takeUsesPianoModel = true
    /// Current playback position in seconds (also the resting position when
    /// paused). During playback it is coarse: it changes on the tick a chord
    /// changes and otherwise about four times a second (`PlayheadPublishing`).
    /// Views that move with playback read `clock` every display frame.
    ///
    /// Kept in an observable of its own (`PlayheadStore`), not @Published: a
    /// published change re-renders every view observing the model (the root,
    /// Home behind the transcription screen, the screen around the roll), and
    /// those publishes were most of the frames that ran late in playback.
    /// SwiftUI re-renders only the views whose bodies read it: the toolbar's
    /// chord and the rolls.
    private(set) var playhead: Double {
        get { playheadStore.time }
        set { playheadStore.time = newValue }
    }
    /// Whether the user has picked where play starts since the take opened
    /// or playback last ran: dragged a roll through time while stopped, or
    /// stepped a bar with VoiceOver. Until then the horizontal roll keeps its
    /// play marker behind the keys, so the notes on the play line meet them;
    /// once they have, it shows the spot against the keys. Changes a few
    /// times a take, never per frame (kept beside the playhead, observed on
    /// its own).
    private(set) var cueChosen: Bool {
        get { playheadStore.chosen }
        set { if playheadStore.chosen != newValue { playheadStore.chosen = newValue } }
    }
    private let playheadStore = PlayheadStore()
    @Published var errorMessage: String?

    /// The config actually being used (resolved from `detectionMode`).
    @Published private(set) var config = NoteExtraction.Config()

    // Detection mode + custom pad (persisted).
    @Published var detectionMode: DetectionMode = .piano {
        didSet { persistDetection(); scheduleReanalysis() }
    }
    @Published var customNoteLenMs: Double = CustomPad.defaultMinNoteLengthMs {
        didSet { persistDetection(); if detectionMode == .custom { scheduleReanalysis() } }
    }
    @Published var customFrameThreshold: Double = CustomPad.defaultFrameThreshold {
        didSet { persistDetection(); if detectionMode == .custom { scheduleReanalysis() } }
    }

    // Beat grid (persisted).
    /// Only whether the roll draws it: the grid is tracked either way (MIDI export uses it).
    @Published var showBeatGrid = true {
        didSet { persistBeatSettings() }
    }
    /// Beats per bar; 0 = detect 3, 4 or 5 automatically.
    @Published var beatsPerMeasure = 0 {
        didSet { persistBeatSettings(); scheduleReanalysis() }
    }
    /// Per-take corrections: -1 / +1 re-tracks at half / double the detected
    /// tempo; barShift moves beat 1 by that many beats.
    @Published var tempoOctave = 0 {
        didSet { if !startingTake { scheduleReanalysis() } }
    }
    @Published var barShift = 0 {
        didSet { if !startingTake { scheduleReanalysis() } }
    }
    /// Set while a new take resets per-take settings, so the reset doesn't
    /// re-run the previous take (which would flash its notes back on screen
    /// and hold up the new take's audio on the worker queue).
    private var startingTake = false
    /// MIDI pitch anchoring each measure, or nil for auto-anchoring.
    @Published var downbeatPitch: Int? = nil {
        didSet { persistBeatSettings(); scheduleReanalysis() }
    }
    @Published private(set) var beatGrid = BeatGrid.empty

    // AI (persisted). The key lives in UserDefaults for now — fine for a
    // personal build, move to Keychain before distributing.
    @Published var aiProviderRaw: String = "off" {
        didSet { Self.defaults.set(aiProviderRaw, forKey: "aiProvider") }
    }
    @Published var aiKey: String = "" {
        didSet { Self.defaults.set(aiKey, forKey: "aiKey") }
    }
    @Published var useAICleanup = true {
        didSet { Self.defaults.set(useAICleanup, forKey: "useAICleanup") }
    }

    /// Serial queue owning the engine, model, and workerConfig.
    private let queue = DispatchQueue(label: "com.semitone.transcription", qos: .userInitiated)
    private let recorder = MicRecorder()
    /// The microphone's input level while recording (RMS to 0…1, smoothed,
    /// about 30 Hz), for Home's record button. Its own observable rather than
    /// @Published, so its updates redraw only the ring that draws it, never
    /// the screens observing this model.
    let inputLevel = InputLevelMeter()
    private let midiPlayer = MidiPlayer()
    /// Smooth playback time for the rolls, read once per display frame.
    let clock = PlaybackClock()
    /// When `playhead` was last published during playback.
    private var lastPlayheadPublish: CFTimeInterval = 0
    /// A drag through either roll is holding the sound: still playing as far
    /// as the screen is concerned, but the sequencer is stopped until the
    /// drag lets go (`resumePlayback(from:)`).
    private(set) var isHeld = false
    private var playbackTimer: Timer?
    private var reloadScheduled = false
    nonisolated(unsafe) private var engine: TranscriptionEngine?
    /// The take at 44.1 kHz for the piano model (queue-owned).
    nonisolated(unsafe) private var takeAudio44k: [Float] = []
    /// Piano-model notes for the current take, once computed (queue-owned).
    nonisolated(unsafe) private var pianoNotes: [NoteEvent]?
    nonisolated(unsafe) private var pianoSustain: [PedalEvent] = []
    /// The piano pass's audio onset envelope, for the beat tracker.
    nonisolated(unsafe) private var pianoOnsets: AudioOnsets?
    nonisolated(unsafe) private var takeFinalized = false
    nonisolated(unsafe) private var workerUsePiano = true
    nonisolated(unsafe) private var workerMode = TranscriptionMode.piano
    /// Where the current take is saved, and whether its audio is written yet (queue-owned).
    nonisolated(unsafe) private var workerSaved: (id: UUID, title: String, createdAt: Date, audioWritten: Bool)?
    /// The drum hits of a take opened from the library that Prerelease 0.99
    /// saved, written back with it each time it's saved (queue-owned).
    nonisolated(unsafe) private var workerLegacyDrums: [SavedTakeContent.LegacyDrum] = []
    /// What the last publish showed besides notes, for saving after an AI cleanup (queue-owned).
    nonisolated(unsafe) private var workerShown: (source: NotesSource, sustain: [PedalEvent]) = (.none, [])
    /// The take's chord style, saved with it (queue-owned).
    nonisolated(unsafe) private var workerChordStyle = ChordStyle.asPlayed
    /// What the last save wrote, so a new chord style re-saves the same take
    /// even if a preview has been shown since (queue-owned).
    nonisolated(unsafe) private var workerLastSave: (notes: [NoteEvent], shown: (source: NotesSource, sustain: [PedalEvent]))?
    /// Writes saved takes off the worker queue (audio encoding takes a moment).
    private let libraryQueue = DispatchQueue(label: "com.semitone.library", qos: .utility)
    /// Set while opening a saved take switches the mode, so the switch
    /// doesn't refine the previous take.
    private var openingTake = false
    /// The take on screen; bumped the moment a new take starts, so late work
    /// from the previous one can't publish over it (see `publish(for:)`).
    private var takeID = 0
    /// What to do once the Tone being opened (take `take`) is on screen: an
    /// action chosen for it in Home's long-press menu (`openSavedTake(_:then:)`).
    /// Dropped when another take starts first.
    private var afterOpening: (take: Int, action: () -> Void)?
    /// The take the worker queue's state belongs to (queue-owned).
    nonisolated(unsafe) private var workerTakeID = 0
    /// A live extraction is queued and will pick up any newer window (queue-owned).
    nonisolated(unsafe) private var livePending = false
    /// Bumped whenever the published notes change, so a late AI cleanup of
    /// older notes is dropped (queue-owned).
    nonisolated(unsafe) private var notesVersion = 0
    /// Latest extracted/accepted/reverted note list, owned by `queue`. Beat
    /// changes derive from these notes instead of replacing an accepted cleanup.
    nonisolated(unsafe) private var workerReviewedNotes: [NoteEvent]?
    /// The `notesVersion` on screen, so cleanup and revert (started from what's
    /// shown) are dropped if newer notes are already on their way.
    private var shownVersion = 0

    /// The any-instrument pass's result for the current take (queue-owned).
    nonisolated(unsafe) private var musicResult: MusicTranscription?
    /// The notes an applied AI cleanup started from (queue-owned), so the
    /// chords stop reading the preview's copies of the notes it took out
    /// (`TakeAnalysis.harmonyNotes`); nil while no cleanup is applied.
    nonisolated(unsafe) private var workerCleanupBefore: [NoteEvent]?
    /// Runs the piano model and the any-instrument pass, one at a time.
    private let refineQueue = DispatchQueue(label: "com.semitone.refine", qos: .userInitiated)
    #if DEBUG
    nonisolated private let regressionPendingPublications = Atomic<Int>(0)
    private(set) var regressionPlaybackLoadCount = 0
    @Published private(set) var regressionUIReady = false
    /// Where TakeCapture saved the current take, and where it came from (queue-owned).
    nonisolated(unsafe) private var captureFolder: URL?
    nonisolated(unsafe) private var takeSource = "mic"
    #endif
    /// Keep-alive for the running refine pass (see `beginRefineActivity`).
    private var refineActivity: (pass: RefinePass, task: UIBackgroundTaskIdentifier)?
    /// Bumped at the start of every take so a stale refine pass stops early.
    nonisolated private let takeGeneration = Atomic<Int>(0)
    /// Bumped when the transcription mode changes, which also stops a running refine pass.
    nonisolated private let refineGeneration = Atomic<Int>(0)
    nonisolated(unsafe) private var workerConfig = NoteExtraction.Config()
    /// Mode + custom-pad values copied onto the worker when they change.
    nonisolated(unsafe) private var workerModeSnapshot = DetectionSnapshot(
        mode: .piano, customMinNoteLengthMs: CustomPad.defaultMinNoteLengthMs, customFrameThreshold: CustomPad.defaultFrameThreshold
    )
    nonisolated(unsafe) private var workerBeatsPerMeasure = 4
    nonisolated(unsafe) private var workerDownbeatPitch: Int?
    nonisolated(unsafe) private var workerTempoOctave = 0
    nonisolated(unsafe) private var workerBarShift = 0
    /// Bumped on every chart request so stale in-flight answers are dropped.
    nonisolated(unsafe) private var chartGen = 0
    /// Bumped on every settings change so a burst (e.g. dragging the custom
    /// pad) only runs the latest re-analysis instead of every intermediate one.
    nonisolated private let reanalysisGeneration = ReanalysisGeneration()
    /// Throttle the live chart pass to one request per ~3s of audio.
    nonisolated(unsafe) private var lastLiveAnalysisAt = -Double.greatestFiniteMagnitude
    /// Live AI requests left for this clip; keeps the pass gentle on quota.
    nonisolated(unsafe) private var liveChartCalls = 0
    private let maxLiveChartCalls = 3

    /// The AI client for right now: in-app settings, else the Xcode scheme's
    /// SEMITONE_AI_* environment, else Semitone's own AI service ("Off" in
    /// Settings is the offline mock).
    nonisolated static func ai() -> AIChartInterpreter.Client { .configured() }
    /// True when a real AI provider is configured (the ✨ badge only means
    /// something when the chart didn't come from the offline mock).
    var hasAIProvider: Bool { Self.ai().provider.kind != .mock }
    /// Whether the scheme environment supplies a key (shown in Settings so
    /// it's clear why the AI works without a key typed in).
    var hasEnvironmentKey: Bool {
        !(ProcessInfo.processInfo.environment["SEMITONE_AI_KEY"] ?? "").isEmpty
    }

    private static let defaults = UserDefaults.standard

    init() {
        let d = Self.defaults
        // Observers persist related fields together. Read the complete saved
        // detection/beat snapshot before restoring any @Published property.
        let savedDetectionMode = d.string(forKey: "detectionMode")
        let savedCustomLength = d.object(forKey: "customNoteLenMs") == nil ? nil : d.double(forKey: "customNoteLenMs")
        let savedCustomThreshold = d.object(forKey: "customFrameThreshold") == nil ? nil : d.double(forKey: "customFrameThreshold")
        let savedShowBeatGrid = d.object(forKey: "showBeatGrid") == nil ? nil : d.bool(forKey: "showBeatGrid")
        let savedBeatsPerMeasure = d.integer(forKey: "beatsPerMeasure")
        let savedDownbeatPitch = d.integer(forKey: "downbeatPitch")
        if let raw = savedDetectionMode, let mode = DetectionMode(rawValue: raw) {
            detectionMode = mode
        }
        if let savedCustomLength {
            customNoteLenMs = savedCustomLength
        }
        if let savedCustomThreshold {
            customFrameThreshold = savedCustomThreshold
        }
        if let savedShowBeatGrid {
            showBeatGrid = savedShowBeatGrid
        }
        let bpm = savedBeatsPerMeasure
        if bpm == 0 || (2...7).contains(bpm) { beatsPerMeasure = bpm }
        let downbeat = savedDownbeatPitch
        downbeatPitch = downbeat > 0 ? downbeat : nil
        // "env" = no in-app choice yet, but the Xcode scheme supplies a key.
        // Nothing chosen yet: the scheme's key in Xcode, else Semitone's own
        // AI service, so a fresh TestFlight install has AI cleanup at once.
        aiProviderRaw = d.string(forKey: "aiProvider") ?? (hasEnvironmentKey ? "env" : "semitone")
        aiKey = d.string(forKey: "aiKey") ?? ""
        if d.object(forKey: "useAICleanup") != nil {
            useAICleanup = d.bool(forKey: "useAICleanup")
        }
        if d.object(forKey: "usePianoModel") != nil {
            usePianoModel = d.bool(forKey: "usePianoModel")
        }
        if let raw = d.string(forKey: "transcriptionMode"), let mode = TranscriptionMode(rawValue: raw) {
            transcriptionMode = mode
        }
        if d.object(forKey: "linkImportEnabled") != nil {
            linkImportEnabled = d.bool(forKey: "linkImportEnabled")
        }
        takeUsesPianoModel = usePianoModel
        savedTakes = TakeLibrary.list()
        // Restoring @Published properties can enqueue their observers. Keep
        // every worker-field write on the queue, including initial settings.
        let initialUsePiano = usePianoModel
        let initialMode = transcriptionMode
        queue.async {
            self.workerUsePiano = initialUsePiano
            self.workerMode = initialMode
        }

        scheduleReanalysis()
    }

    private func persistDetection() {
        let d = Self.defaults
        d.set(detectionMode.rawValue, forKey: "detectionMode")
        d.set(customNoteLenMs, forKey: "customNoteLenMs")
        d.set(customFrameThreshold, forKey: "customFrameThreshold")
    }

    private func persistBeatSettings() {
        let d = Self.defaults
        d.set(showBeatGrid, forKey: "showBeatGrid")
        d.set(beatsPerMeasure, forKey: "beatsPerMeasure")
        d.set(downbeatPitch ?? -1, forKey: "downbeatPitch")
    }

    var hasContent: Bool { !notes.isEmpty || duration > 0 }

    /// Recording, starting a take, importing or transcribing: no other take
    /// can start or open until it's done.
    var isBusy: Bool { isRecording || isStartingTake || isTranscribing || isPreparingImport }

    /// Sets the mode for the next take (the home screen's mode segments)
    /// without re-running the take that's loaded in it, as opening a saved
    /// take does. The next recording or import then uses `mode`.
    func prepareNewTake(mode: TranscriptionMode) {
        guard mode != transcriptionMode, !isBusy else { return }
        openingTake = true
        transcriptionMode = mode
        openingTake = false
    }

    /// Turns the piano model on or off for the open take (Transcription in
    /// its long-press menu): the take is re-transcribed with the model, or
    /// goes back to the quick detector's notes. The default for new takes
    /// stays as it is, unless no take is open yet: then this is the choice
    /// for the next one.
    ///
    /// Not while a take is transcribing: a Tone being opened sets its own
    /// choice from its save once its audio is read, after this would have
    /// queued, so the switch would show one thing and the worker hold the
    /// other. (The menu is disabled then too.)
    func setTakeUsesPianoModel(_ use: Bool) {
        guard use != takeUsesPianoModel, !isTranscribing else { return }
        takeUsesPianoModel = use
        if !hasContent { usePianoModel = use }
        if !use, transcriptionMode == .piano {
            refineGeneration.wrappingAdd(1, ordering: .relaxed)
            refineProgress = nil
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.workerUsePiano = use
            guard self.workerMode == .piano else { return }
            if !use {
                // Also stops a pass a file import started after the tap.
                self.refineGeneration.wrappingAdd(1, ordering: .relaxed)
                Task { @MainActor in
                    self.refineProgress = nil
                    self.endRefineActivity()
                }
            }
            guard self.takeFinalized else { return }
            self.refineOrPublish(duration: self.engine?.duration ?? 0)
        }
    }

    /// The open take's notes between `start` and `end` seconds as each of
    /// `modes` would keep them, for the pictures on a Tone's Detection
    /// presets. Extracted on the worker queue from the take's cached
    /// activations, as a re-analysis would, without changing what's shown;
    /// presets that come to the same thresholds share one extraction. These
    /// are the quick detector's notes: what the roll shows only while the
    /// take's notes are the quick detector's (`notesSource == .quick`). Nil
    /// until a take is finished.
    func presetNotes(for modes: [DetectionMode], customLengthMs: Double, customThreshold: Double,
                     from start: Double, to end: Double) async -> [DetectionMode: [NoteEvent]]? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let engine = self.engine, self.takeFinalized else {
                    return continuation.resume(returning: nil)
                }
                var byMode: [DetectionMode: [NoteEvent]] = [:]
                var extracted: [(config: NoteExtraction.Config, notes: [NoteEvent])] = []
                for mode in modes {
                    let snapshot = DetectionSnapshot(mode: mode, customMinNoteLengthMs: customLengthMs,
                                                     customFrameThreshold: customThreshold)
                    let config = mode.resolved(snapshot: snapshot, stats: engine.stats(), for: self.workerMode)
                    if let same = extracted.first(where: { $0.config == config }) {
                        byMode[mode] = same.notes
                    } else {
                        let notes = engine.extractNotes(config: config).filter { $0.endTime > start && $0.startTime < end }
                        extracted.append((config, notes))
                        byMode[mode] = notes
                    }
                }
                continuation.resume(returning: byMode)
            }
        }
    }

    /// Whether the take is split into parts (any-instrument mode).
    var hasParts: Bool { notes.contains { $0.voice != .none } }

    /// The notes in the chosen chord style: the take's own, or with the
    /// chords part simplified. The roll, playback and MIDI export use these
    /// (less hidden parts); the take itself (saves, AI cleanup) keeps `notes`.
    var displayNotes: [NoteEvent] {
        chordStyle == .simplified ? simplifiedNotes ?? notes : notes
    }

    /// The notes of the parts that aren't hidden.
    var visibleNotes: [NoteEvent] {
        hiddenVoices.isEmpty ? displayNotes : displayNotes.filter { !hiddenVoices.contains($0.voice) }
    }

    /// Something would sound (and export) with the parts shown now. Cheap:
    /// the view body asks on every playback tick.
    var hasAudibleParts: Bool {
        displayNotes.contains { !hiddenVoices.contains($0.voice) }
    }

    /// The chord style can be chosen: a finished take with a chords part.
    var canChooseChordStyle: Bool {
        presentVoices.contains(.chords) && !isRecording
    }

    /// Key from the AI chart, shown only when the model is confident enough.
    var chartKey: String? {
        guard let chart, chart.confidence >= 0.35, !chart.key.isEmpty else { return nil }
        return chart.key
    }

    /// Chord at the moment the views are showing at the keys: the live edge
    /// while recording, otherwise the playhead. Silence outside a chord
    /// segment has no current chord; short bridges belong to ChordAnalyzer.
    var currentChord: String? {
        let t = isRecording ? duration : playhead
        return chordSegments.last { $0.startTime <= t && t < $0.endTime }?.label
    }

    /// Debug hook: transcribe a bundled clip on launch when
    /// SEMITONE_AUTOLOAD_SAMPLE=1, so the piano roll can be verified in the
    /// simulator without the Files picker.
    /// SEMITONE_AUTOLOAD_FILE=<path> loads an arbitrary file instead: a host path
    /// in the simulator, or a name relative to the app's Documents folder on a device.
    /// Returns whether it started something, so the caller can show the
    /// transcription screen.
    @discardableResult
    func autoloadSampleIfRequested() -> Bool {
        #if DEBUG
        if let fixture = RegressionUIFixture.selected {
            // Set a persistent starting preference once. A -rollLayout launch
            // argument would override the Roll style cards and the pull for the whole run.
            Self.defaults.set(RegressionUIFixture.layout, forKey: RollLayout.storageKey)
            regressionUIReady = false
            Task {
                do {
                    try await regressionInstallTake(notes: fixture.notes, source: fixture.source,
                                                    sustain: fixture.sustain, duration: fixture.duration)
                    if RegressionUIFixture.appliesCleanup {
                        await regressionApplyCleanup(CleanupResult(
                            notes: Array(notes.dropFirst()), removed: 1, shifted: 0, merged: 0, confidence: 0.9,
                            summary: "Removed a phantom note."))
                    }
                    chordSegments = fixture.chords
                    beatGrid = fixture.beatGrid
                    simplifiedNotes = ChordVoicer.voice(notes: notes, chords: fixture.chords, grid: fixture.beatGrid).notes
                    cue(at: fixture.initialPlayhead, settled: true)
                    if let edge = RegressionUIFixture.recordingEdge {
                        regressionRecord(from: edge, to: fixture.duration)
                    }
                    regressionUIReady = true
                } catch {
                    errorMessage = "Regression fixture failed: \(error.localizedDescription)"
                }
            }
            return true
        }
        #endif
        let env = ProcessInfo.processInfo.environment
        #if DEBUG
        // SEMITONE_OPEN_LATEST_SAVED=1 reopens the newest saved take (for checking the library).
        if env["SEMITONE_OPEN_LATEST_SAVED"] == "1", let latest = savedTakes.first {
            openSavedTake(latest)
            return true
        }
        #endif
        if let path = env["SEMITONE_AUTOLOAD_FILE"] {
            let url = path.hasPrefix("/")
                ? URL(fileURLWithPath: path)
                : URL.documentsDirectory.appending(path: path)
            if FileManager.default.fileExists(atPath: url.path) {
                importMedia(url: url, isSecurityScoped: false)
                return true
            }
        }
        guard env["SEMITONE_AUTOLOAD_SAMPLE"] == "1",
              let url = Bundle.main.url(forResource: "SampleClip", withExtension: "wav") else { return false }
        transcribeFile(url: url, isSecurityScoped: false)
        return true
    }

    #if DEBUG
    /// Debug hook: SEMITONE_DUMP_NOTES=1 writes the piano model's notes to
    /// Documents/piano_notes.csv (start,end,pitch,velocity) and its timing to
    /// Documents/piano_timing.txt, for checking a device run.
    nonisolated private static func dumpNotesIfRequested(_ notes: [NoteEvent], summary: String) {
        guard ProcessInfo.processInfo.environment["SEMITONE_DUMP_NOTES"] == "1" else { return }
        let csv = notes.map { "\($0.startTime),\($0.endTime),\($0.pitch),\(Int(($0.amplitude * 127).rounded()))" }
            .joined(separator: "\n")
        try? csv.write(to: URL.documentsDirectory.appending(path: "piano_notes.csv"), atomically: true, encoding: .utf8)
        try? summary.write(to: URL.documentsDirectory.appending(path: "piano_timing.txt"), atomically: true, encoding: .utf8)
    }
    #endif

    // MARK: - Playback

    func togglePlayback() {
        isPlaying ? stopPlayback() : startPlayback()
    }

    /// Where play starts while the roll is still moving. Kept out of `playhead`
    /// so scrolling doesn't redraw everything each frame.
    private var pendingCue: Double?

    /// Where playback will start: the time at the roll's play line as the user
    /// scrolls. Once the roll comes to rest (`settled`), the playhead (and the
    /// chord shown) moves there. Ignored while playing or recording.
    func cue(at time: Double, settled: Bool) {
        guard !isPlaying, !isRecording else { return }
        let t = min(max(time, 0), duration)
        if settled {
            pendingCue = nil
            playhead = t
        } else {
            pendingCue = t
        }
    }

    /// The user has picked where play starts: a drag through either roll
    /// while stopped (`cueChosen`). The cue itself comes through `cue(at:settled:)`.
    func userChoseCue() {
        guard !isPlaying, !isRecording else { return }
        cueChosen = true
    }

    private func startPlayback() {
        guard !isRecording, hasAudibleParts else { return }
        if let pendingCue {
            playhead = pendingCue
            self.pendingCue = nil
        }
        loadPlayer()
        if midiPlayer.duration > 0, playhead >= midiPlayer.duration - 0.01 { playhead = 0 }
        guard playSequencer(from: playhead) else {
            errorMessage = "Playback couldn't start. Check your audio output and try again."
            return
        }
        isHeld = false
        isPlaying = true
        // The spot is playing now; once stopped, the marker waits behind the keys again.
        cueChosen = false

        // Scheduled on the main run loop, so it fires on the main actor.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickPlayback() }
        }
        RunLoop.main.add(timer, forMode: .common)
        playbackTimer = timer
    }

    /// Restarts playback with what's on screen once the current update is
    /// done: notes, pedal and part visibility often change together.
    private func reloadPlayback() {
        guard isPlaying, !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reloadScheduled = false
            guard self.isPlaying else { return }
            let resume = self.clock.time(at: CACurrentMediaTime())
            self.midiPlayer.stop()
            self.loadPlayer()
            // A held drag resumes with the new notes when it lets go.
            guard !self.isHeld else { return }
            // Nothing left to play from here: stop where we are.
            guard resume < self.midiPlayer.duration, self.midiPlayer.play(from: resume) else {
                self.stopPlayback()
                return
            }
            self.clock.start(at: resume)
        }
    }

    /// Starts the sequencer a touch before `time` (it skips notes that begin
    /// before the start point, and a cue lands right on, or just after, a
    /// note's onset) and the clock with it. The rolls hold still until the
    /// clock reaches the spot they show, rather than step back those 60 ms.
    private func playSequencer(from time: Double) -> Bool {
        guard midiPlayer.play(from: max(0, time - 0.06)) else { return false }
        clock.start(at: midiPlayer.currentTime)
        lastPlayheadPublish = CACurrentMediaTime()
        return true
    }

    /// A drag during playback (through time, on either roll) holds the sound
    /// where it is, so the drag scrubs; `resumePlayback(from:)` plays on from
    /// wherever it comes to rest.
    func holdPlayback() {
        guard isPlaying, !isHeld else { return }
        isHeld = true
        clock.stop()
        midiPlayer.stop()
    }

    /// Plays on from `time` after `holdPlayback()`. If playback was stopped
    /// meanwhile, `time` becomes the cue instead.
    func resumePlayback(from time: Double) {
        guard isPlaying, isHeld else {
            cue(at: time, settled: true)
            return
        }
        isHeld = false
        let t = min(max(time, 0), duration)
        playhead = t
        guard t < midiPlayer.duration - 0.01, playSequencer(from: t) else {
            stopPlayback(at: t)
            return
        }
    }

    /// Moves playback (or the cue, when stopped) to `time` at once: the
    /// falling notes' VoiceOver adjustment, a bar at a time. Stopped, that
    /// is the user picking where play starts.
    func seek(to time: Double) {
        guard isPlaying else {
            cue(at: time, settled: true)
            userChoseCue()
            return
        }
        holdPlayback()
        resumePlayback(from: time)
    }

    /// Plays the chords part in the new style and saves the choice with the
    /// take. Resetting it for a new take, or taking a saved take's own style
    /// (`startingTake`), saves nothing.
    private func chordStyleChanged() {
        reloadPlayback()
        guard !startingTake else { return }
        let style = chordStyle
        queue.async { [weak self] in
            guard let self else { return }
            self.workerChordStyle = style
            // Re-save what was last saved: a preview shown since is not the take.
            if let last = self.workerLastSave { self.save(notes: last.notes, shown: last.shown) }
        }
    }

    /// Hidden parts are muted in place, so the others keep ringing.
    private func partsVisibilityChanged() {
        guard isPlaying else { return }
        midiPlayer.setHidden(hiddenVoices)
        if !hasAudibleParts { stopPlayback() }
    }

    /// Piano model notes carry real velocities and pedal; quick notes don't.
    /// Hidden parts are loaded muted, so they can come back mid-play.
    private func loadPlayer() {
        #if DEBUG
        regressionPlaybackLoadCount += 1
        #endif
        let piano = notesSource == .piano
        midiPlayer.load(notes: displayNotes, sustain: piano ? sustain : [], dynamics: piano ? .detected : .activation)
        midiPlayer.setHidden(hiddenVoices)
    }

    private func tickPlayback() {
        guard !isHeld else { return }
        let now = CACurrentMediaTime()
        let sequencerTime = midiPlayer.currentTime
        clock.sync(sequencerTime: sequencerTime, host: now)
        if sequencerTime >= midiPlayer.duration - 0.005 {
            stopPlayback(at: midiPlayer.duration)
        } else if !midiPlayer.isPlaying {
            // Audio stopped underneath us (e.g. the output route changed):
            // stop where we are, so play resumes from the spot on screen.
            stopPlayback()
        } else {
            let t = clock.time(at: now)
            if PlayheadPublishing.shouldPublish(sinceLast: now - lastPlayheadPublish,
                                                chordChanged: chordLabel(at: t) != chordLabel(at: playhead)) {
                playhead = t
                lastPlayheadPublish = now
            }
        }
    }

    private func chordLabel(at t: Double) -> String? {
        chordSegments.last { $0.startTime <= t && t < $0.endTime }?.label
    }

    /// Stops where the rolls show playback (the clock), so play resumes from the spot on screen.
    func stopPlayback() {
        stopPlayback(at: clock.time(at: CACurrentMediaTime()))
    }

    private func stopPlayback(at time: Double) {
        guard isPlaying else { return }
        clock.stop()
        playhead = min(max(time, 0), max(duration, midiPlayer.duration))
        if !isHeld { midiPlayer.stop() }
        isHeld = false
        playbackTimer?.invalidate()
        playbackTimer = nil
        isPlaying = false
        cueChosen = false
    }

    // MARK: - Export

    /// Not mid-refine: the preview then has no beat grid.
    var canExport: Bool { hasAudibleParts && !isRecording && !isTranscribing && refineProgress == nil }

    /// Writes what's showing (hidden parts left out, the chords part in the
    /// chosen style) as a multi-track MIDI file whose bars follow the beat
    /// grid, with the chord names as markers, in the temporary folder, for sharing.
    func exportMIDI() -> URL? {
        let piano = notesSource == .piano
        let name = MidiExport.fileName(for: Date())
        let data = MidiExport.file(
            title: String(name.dropLast(4)),
            notes: visibleNotes,
            sustain: piano ? sustain : [],
            chords: chordSegments,
            grid: beatGrid,
            dynamics: piano ? .detected : .activation
        )
        let url = FileManager.default.temporaryDirectory.appending(path: name)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            errorMessage = "Couldn't write the MIDI file: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Saved takes

    /// Saves the finished take as shown (on `queue`): the notes and pedal,
    /// plus its audio the first time. Writing happens on `libraryQueue`.
    nonisolated private func autosave(notes: [NoteEvent]) {
        save(notes: notes, shown: workerShown)
    }

    /// `autosave` with what was shown given, plus the take's chord style.
    nonisolated private func save(notes: [NoteEvent], shown: (source: NotesSource, sustain: [PedalEvent])) {
        #if DEBUG
        // Hosted tests and UI fixtures run inside the real app container.
        guard !Self.regressionRunSkipsLibrary else { return }
        #endif
        guard takeFinalized, let saved = workerSaved, let engine else { return }
        guard !notes.isEmpty else { return }
        workerLastSave = (notes, shown)
        let source = switch shown.source {
        case .piano: "piano"
        case .music: "music"
        case .quick, .none: "quick"
        }
        let take = SavedTake(id: saved.id, title: saved.title, createdAt: saved.createdAt, duration: engine.duration,
                             mode: workerMode.rawValue, noteCount: notes.count)
        let content = SavedTakeContent(source: source, notes: notes, sustain: shown.sustain,
                                       legacyDrums: workerLegacyDrums, chordStyle: workerChordStyle)
        let audio = saved.audioWritten || takeAudio44k.isEmpty ? nil : takeAudio44k
        workerSaved?.audioWritten = true
        libraryQueue.async { [weak self] in
            do {
                try TakeLibrary.save(take, content: content, audio: audio, sampleRate: PianoModel.sampleRate)
            } catch {
                NSLog("Semitone: couldn't save the take: %@", error.localizedDescription)
            }
            let list = TakeLibrary.list()
            Task { @MainActor [weak self] in self?.savedTakes = list }
        }
    }

    /// Reopens a saved take as it was: its notes, parts and pedal come from
    /// the save (no refine pass), and its audio is loaded so settings,
    /// playback and the other mode still work. Drum hits that takes saved
    /// before October 2026 hold are not shown, played or exported, but stay
    /// in the save (opening a take saves it again).
    ///
    /// `opened` runs once the Tone is on screen: its notes, parts, chords
    /// and beat grid published and nothing transcribing, so it sees the
    /// take as tapping its row shows it (Home's long-press menu exports
    /// it, or transcribes it again, from there). It doesn't run if the Tone
    /// can't be opened, or another take starts first.
    func openSavedTake(_ take: SavedTake, then opened: (() -> Void)? = nil) {
        guard !isRecording, !isStartingTake, !isTranscribing, !isPreparingImport else { return }
        let content: SavedTakeContent
        do {
            content = try TakeLibrary.content(of: take.id)
        } catch {
            errorMessage = "Couldn't open “\(take.title)”: \(error.localizedDescription)"
            return
        }
        if let mode = TranscriptionMode(rawValue: take.mode), mode != transcriptionMode {
            openingTake = true
            transcriptionMode = mode
            openingTake = false
        }
        let id = resetForNewTake()
        openSavedTakeID = take.id
        afterOpening = opened.map { (id, $0) }
        // The take's own chord style, without saving it again.
        let style = content.style
        startingTake = true
        chordStyle = style
        startingTake = false
        isTranscribing = true
        let url = TakeLibrary.audioURL(take.id)
        queue.async { [weak self] in
            guard let self else { return }
            var shown = false
            defer {
                let shown = shown
                // After the take's publishes, which were queued first.
                Task { @MainActor in
                    self.isTranscribing = false
                    if let after = self.afterOpening, after.take == id {
                        self.afterOpening = nil
                        if shown { after.action() }
                    }
                }
            }
            self.resetWorker(for: id, source: "saved", title: take.title, saved: (take.id, take.createdAt))
            self.workerLegacyDrums = content.legacyDrums
            self.workerChordStyle = style
            do {
                let engine = TranscriptionEngine(model: try BasicPitchModel())
                self.engine = engine
                try engine.append(try AudioFileLoader.loadMono(url: url, sampleRate: BPConstants.sampleRate))
                self.takeFinalized = true
                try engine.finalize()
                self.takeAudio44k = try AudioFileLoader.loadMono(url: url, sampleRate: PianoModel.sampleRate)
                switch content.source {
                case "piano":
                    self.pianoNotes = content.noteEvents
                    self.pianoSustain = content.pedalEvents
                case "music":
                    // The beat tracker reads the take's onsets next to the notes,
                    // and the chords its tonal part's pitch classes, as when the
                    // take was made (saves hold notes only).
                    let take22k = try AudioFileLoader.resampleMono(self.takeAudio44k, from: PianoModel.sampleRate,
                                                                   to: BPConstants.sampleRate)
                    // The chords also read the preview's notes (RefineOutput.harmonyNotes),
                    // which come back from the audio like any quick notes.
                    let preview = engine.extractNotes(config: self.workerModeSnapshot.mode.resolved(
                        snapshot: self.workerModeSnapshot, stats: engine.stats(), for: .music))
                    let evidence = TakePipeline.reopened(music: take22k, preview: preview)
                    self.musicResult = MusicTranscription(notes: content.noteEvents, onsets: evidence.onsets,
                                                          harmonyNotes: evidence.harmonyNotes)
                default:
                    break   // quick notes come back from the audio with the current settings
                }
                // A Piano Tone opens as it was saved: with its piano model's
                // notes whatever the default for new takes is now, or with
                // the quick detector's when it was saved without them.
                if self.workerMode == .piano {
                    let usesPiano = content.source == "piano"
                    self.workerUsePiano = usesPiano
                    self.publish(for: id) { self.takeUsesPianoModel = usesPiano }
                }
                let duration = engine.duration
                self.publish(for: id) { self.duration = duration }
                if let extracted = self.extractAndPublish(live: false) {
                    self.finishTake(notes: extracted.notes, melody: extracted.melody, duration: duration, allowCleanup: false)
                    shown = true
                }
            } catch {
                self.publishError("Couldn't open “\(take.title)”: \(error.localizedDescription)")
            }
        }
    }

    func renameSavedTake(_ take: SavedTake, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        libraryQueue.async { [weak self] in
            try? TakeLibrary.rename(take.id, to: title)
            let list = TakeLibrary.list()
            Task { @MainActor [weak self] in self?.savedTakes = list }
        }
        // The open take keeps saving under the new name.
        queue.async { [weak self] in
            guard let self, self.workerSaved?.id == take.id else { return }
            self.workerSaved?.title = title
        }
    }

    /// Notes an older take's kind and parts in the library once Home has
    /// read its notes (`take` has them noted), so from the next launch its
    /// row is laid out right at once. Takes saved since are noted as saved.
    func noteKind(_ take: SavedTake) {
        #if DEBUG
        guard !Self.regressionRunSkipsLibrary else { return }
        #endif
        libraryQueue.async { try? TakeLibrary.noteKind(take) }
    }

    func deleteSavedTake(_ take: SavedTake) {
        savedTakes.removeAll { $0.id == take.id }
        libraryQueue.async { try? TakeLibrary.delete(take.id) }
        if openSavedTakeID == take.id { openSavedTakeID = nil }
        // If it's the take on screen, stop saving it (it would come back).
        queue.async { [weak self] in
            guard let self, self.workerSaved?.id == take.id else { return }
            self.workerSaved = nil
        }
    }

    // MARK: - Importing videos, shared files and links

    /// Audio or video from the file picker, Photos, "Open in" or a download:
    /// a video's soundtrack is pulled out first.
    func importMedia(url: URL, isSecurityScoped: Bool, title: String? = nil) {
        guard !isRecording, !isStartingTake, !isTranscribing, !isPreparingImport else { return }
        let title = title ?? url.deletingPathExtension().lastPathComponent
        isPreparingImport = true
        Task {
            let scoped = isSecurityScoped && url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let audio = try await MediaImport.audioFile(for: url)
                isPreparingImport = false
                // The original file is read on the worker queue, so it keeps its own access.
                transcribeFile(url: audio, isSecurityScoped: audio == url && isSecurityScoped, title: title)
            } catch {
                isPreparingImport = false
                errorMessage = "Couldn't import that file: \(error.localizedDescription)"
            }
        }
    }

    /// Experimental: downloads a link to an audio or video file and transcribes it.
    func importLink(_ link: URL) {
        guard linkImportEnabled else {
            errorMessage = "Importing from links is turned off. Turn it on in Settings on Home, under Import."
            return
        }
        guard !isRecording, !isStartingTake, !isTranscribing, !isPreparingImport else { return }
        isPreparingImport = true
        Task {
            do {
                let file = try await MediaImport.download(link)
                isPreparingImport = false
                importMedia(url: file, isSecurityScoped: false, title: file.deletingPathExtension().lastPathComponent)
            } catch {
                isPreparingImport = false
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Something another app handed over: a file ("Open in Semitone") or a
    /// `semitone://import?url=…` link from the share extension.
    func handleIncoming(_ url: URL) {
        guard !isRecording else {
            errorMessage = "Stop recording first, then share it to Semitone again."
            return
        }
        if url.isFileURL {
            importMedia(url: url, isSecurityScoped: true)
        } else if url.scheme == "semitone", url.host() == "import",
                  let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                      .queryItems?.first(where: { $0.name == "url" })?.value,
                  let link = URL(string: value) {
            importLink(link)
        }
    }

    // MARK: - Recording

    func toggleRecording() {
        #if DEBUG
        if RecordTransition.isDemo { return demoToggleRecording() }
        #endif
        if isRecording {
            stopRecording()
        } else {
            // Starting takes a moment (permission, model load): ignore taps meanwhile,
            // or a second start would install a second microphone tap.
            guard !isStartingTake, !isTranscribing else { return }
            isStartingTake = true
            Task {
                await startRecording()
                isStartingTake = false
            }
        }
    }

    /// Clears everything the previous take showed and returns the new take's token.
    private func resetForNewTake() -> Int {
        stopPlayback()
        takeID += 1
        // The worker names the new take's save (`resetWorker`).
        openSavedTakeID = nil
        afterOpening = nil
        playhead = 0
        pendingCue = nil
        cueChosen = false
        notes = []
        sustain = []
        melody = []
        chordSegments = []
        simplifiedNotes = nil
        chart = nil
        isAnalyzingChart = false
        rawNotes = []
        cleanup = nil
        isCleaningUp = false
        beatGrid = .empty
        duration = 0
        errorMessage = nil
        refineProgress = nil
        notesSource = .none
        hiddenVoices = []
        startingTake = true
        tempoOctave = 0
        barShift = 0
        chordStyle = .asPlayed
        startingTake = false
        // A new take starts with the default for new takes (Home's
        // Settings); a reopened Tone then takes its save's own choice.
        takeUsesPianoModel = usePianoModel
        let usePiano = usePianoModel
        queue.async { self.workerUsePiano = usePiano }
        return takeID
    }

    /// The worker's half of starting take `id` (on `queue`).
    nonisolated private func resetWorker(for id: Int, source: String, title: String,
                                         saved: (id: UUID, createdAt: Date)? = nil) {
        workerTakeID = id
        let savedID = saved?.id ?? UUID()
        workerSaved = (savedID, title, saved?.createdAt ?? Date(), saved != nil)
        publish(for: id) { self.openSavedTakeID = savedID }
        workerLegacyDrums = []
        workerShown = (.none, [])
        workerChordStyle = .asPlayed
        workerLastSave = nil
        chartGen += 1
        notesVersion += 1
        workerReviewedNotes = nil
        liveChartCalls = 0
        lastLiveAnalysisAt = -Double.greatestFiniteMagnitude
        livePending = false
        resetTakeForRefine()
        workerTempoOctave = 0
        workerBarShift = 0
        #if DEBUG
        takeSource = source
        #endif
    }

    private func startRecording() async {
        guard await AVAudioApplication.requestRecordPermission() else {
            errorMessage = "Semitone needs microphone access. Enable it in Settings."
            return
        }
        let id = resetForNewTake()
        let engine: TranscriptionEngine? = await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { return continuation.resume(returning: nil) }
                self.resetWorker(for: id, source: "mic", title: "Recording " + Date().formatted(date: .abbreviated, time: .shortened))
                do {
                    let engine = TranscriptionEngine(model: try BasicPitchModel())
                    self.engine = engine
                    continuation.resume(returning: engine)
                } catch {
                    self.publishError("Could not load model: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                }
            }
        }
        guard let engine, id == takeID else { return }
        let engineID = ObjectIdentifier(engine)

        recorder.onSamples = { [weak self] samples, full in
            guard let self else { return }
            self.queue.async {
                // Only this take's engine, and never once it's finalized.
                guard let engine = self.engine, ObjectIdentifier(engine) == engineID, !self.takeFinalized else { return }
                self.takeAudio44k.append(contentsOf: full)
                do {
                    let newFrames = try engine.append(samples)
                    let duration = engine.duration
                    self.publish(for: id) { self.duration = duration }
                    // Coalesce: while a live pass is already queued, new windows just
                    // join it, so a long take never falls behind the microphone.
                    if newFrames, !self.livePending {
                        self.livePending = true
                        self.queue.async {
                            self.livePending = false
                            guard let current = self.engine, ObjectIdentifier(current) == engineID,
                                  !self.takeFinalized else { return }
                            self.extractAndPublish(live: true)
                        }
                    }
                } catch {
                    self.publishError("Transcription failed: \(error.localizedDescription)")
                }
            }
        }
        recorder.onStopped = { [weak self] reason in
            Task { @MainActor in
                guard let self, self.isRecording, id == self.takeID else { return }
                // Keep what was captured before the interruption.
                self.stopRecording()
                self.errorMessage = "Recording stopped: \(reason). The part before that was kept."
            }
        }

        do {
            // A band's instruments can sit on either side of a stereo input.
            try recorder.start(downmixPreview: transcriptionMode == .music)
            isRecording = true
            inputLevel.start { [recorder] in recorder.inputRMS }
        } catch {
            recorder.stop()
            recorder.onSamples = nil
            recorder.onStopped = nil
            errorMessage = "Could not start recording: \(error.localizedDescription)"
        }
    }

    private func stopRecording() {
        inputLevel.stop()
        recorder.stop()
        recorder.onSamples = nil
        recorder.onStopped = nil
        isRecording = false
        isTranscribing = true
        let id = takeID
        queue.async { [weak self] in
            guard let self else { return }
            defer { Task { @MainActor in self.isTranscribing = false } }
            guard id == self.workerTakeID, let engine = self.engine, !self.takeFinalized else { return }
            // Final from here on: late microphone buffers are dropped.
            self.takeFinalized = true
            do {
                try engine.finalize()
                self.completeTake(duration: engine.duration)
            } catch {
                self.publishError("Transcription failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - File import

    func transcribeFile(url: URL, isSecurityScoped: Bool = true, title: String? = nil) {
        guard !isRecording, !isStartingTake, !isTranscribing else { return }
        let title = title ?? url.deletingPathExtension().lastPathComponent
        let id = resetForNewTake()
        isTranscribing = true

        let scoped = isSecurityScoped && url.startAccessingSecurityScopedResource()
        queue.async { [weak self] in
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let self else { return }
            defer { Task { @MainActor in self.isTranscribing = false } }
            self.resetWorker(for: id, source: "file " + url.lastPathComponent, title: title)
            do {
                let engine = TranscriptionEngine(model: try BasicPitchModel())
                self.engine = engine
                // Solo piano reads best from one channel; a band mix needs them all
                // (instruments are often panned to one side).
                let music = self.workerMode == .music
                let samples = music
                    ? try AudioFileLoader.loadMono(url: url, sampleRate: BPConstants.sampleRate, downmix: true)
                    : try AudioFileLoader.loadMono22k(url: url)
                try engine.append(samples)
                self.takeFinalized = true
                try engine.finalize()
                self.takeAudio44k = try AudioFileLoader.loadMono(url: url, sampleRate: PianoModel.sampleRate)
                let duration = engine.duration
                self.publish(for: id) { self.duration = duration }
                self.completeTake(duration: duration)
            } catch {
                self.publishError("Could not transcribe file: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Worker-side helpers (run on queue)

    /// Runs `update` on the main actor if take `id` is still the one on screen,
    /// so work finishing after a new take started can't paint over it.
    nonisolated private func publish(for id: Int, _ update: @escaping @MainActor () -> Void) {
        #if DEBUG
        regressionPendingPublications.wrappingAdd(1, ordering: .relaxed)
        #endif
        Task { @MainActor in
            #if DEBUG
            defer { self.regressionPendingPublications.wrappingAdd(-1, ordering: .relaxed) }
            #endif
            guard id == self.takeID else { return }
            update()
        }
    }

    /// Copy the current mode/beat settings to the worker and re-analyze.
    /// Called whenever any setting that affects detection or the beat grid
    /// changes; changes show up immediately on the existing take.
    func scheduleReanalysis() {
        let mode = detectionMode
        let snapshot = DetectionSnapshot(
            mode: mode,
            customMinNoteLengthMs: customNoteLenMs,
            customFrameThreshold: customFrameThreshold
        )
        let bpm = beatsPerMeasure
        let downbeat = downbeatPitch
        let octave = tempoOctave
        let shift = barShift
        let token = reanalysisGeneration.next()
        queue.async { [weak self] in
            guard let self else { return }
            // A newer settings change is already queued; skip the stale snapshot
            // before it can overwrite worker settings. The token is atomic.
            guard self.reanalysisGeneration.isCurrent(token) else { return }
            let noteSettingsChanged = !self.workerModeSnapshot.hasSameNoteSettings(as: snapshot)
            self.workerModeSnapshot = snapshot
            self.workerBeatsPerMeasure = bpm
            self.workerDownbeatPitch = downbeat
            self.workerTempoOctave = octave
            self.workerBarShift = shift
            if self.engine != nil {
                // While recording, the next live window picks the settings up.
                guard self.takeFinalized else { return }
                if !noteSettingsChanged, let reviewed = self.workerReviewedNotes {
                    self.publishDerivedMetadata(from: reviewed, token: token)
                } else {
                    self.extractAndPublish(live: false)
                }
            } else {
                // No take yet: just keep the UI numbers honest.
                let resolved = mode.resolved(snapshot: snapshot, stats: EngineStats(), for: self.workerMode)
                self.workerConfig = resolved
                #if DEBUG
                self.regressionPendingPublications.wrappingAdd(1, ordering: .relaxed)
                #endif
                Task { @MainActor in
                    #if DEBUG
                    defer { self.regressionPendingPublications.wrappingAdd(-1, ordering: .relaxed) }
                    #endif
                    guard self.reanalysisGeneration.isCurrent(token) else { return }
                    self.config = resolved
                }
            }
        }
    }

    /// Beat/meter/downbeat changes preserve note identity, cleanup/revert
    /// state, source and pedal. Only note-derived metadata is rebuilt.
    nonisolated private func publishDerivedMetadata(from reviewed: [NoteEvent], token: Int) {
        guard let engine else { return }
        let version = notesVersion
        let derived = derive(from: reviewed, duration: engine.duration)
        let resolved = workerConfig
        publish(for: workerTakeID) {
            guard self.reanalysisGeneration.isCurrent(token) else { return }
            // A note replacement/cleanup may be queued for the main actor.
            // Wait for that version by requesting metadata from the latest
            // worker notes; never attach an old grid to a newer note list.
            guard self.shownVersion == version else {
                self.scheduleReanalysis()
                return
            }
            self.melody = derived.melody
            self.chordSegments = derived.chords
            self.simplifiedNotes = derived.simplified
            self.beatGrid = derived.grid
            self.config = resolved
        }
    }

    /// Re-extracts from the current engine, publishes, and hands back the
    /// take so callers don't repeat the (expensive) extraction. `grid: false`
    /// skips the beat tracker (for a preview a refine pass will replace).
    @discardableResult
    nonisolated private func extractAndPublish(live: Bool, grid: Bool = true) -> (notes: [NoteEvent], melody: [NoteEvent])? {
        guard let engine else { return nil }
        let resolved = workerModeSnapshot.mode.resolved(snapshot: workerModeSnapshot, stats: engine.stats(), for: workerMode)
        workerConfig = resolved
        // Once a refine pass has run, its notes are the take; the Basic Pitch
        // settings only shape the live preview.
        let extracted: [NoteEvent]
        let source: NotesSource
        let sustain: [PedalEvent]
        if !live, workerMode == .music, let music = musicResult {
            (extracted, source, sustain) = (music.notes, .music, [])
        } else if !live, workerMode == .piano, workerUsePiano, let piano = pianoNotes {
            (extracted, source, sustain) = (piano, .piano, pianoSustain)
        } else {
            let quick = engine.extractNotes(config: resolved)
            // Any-instrument takes show their parts from the first note on.
            (extracted, source, sustain) = (workerMode == .music ? VoiceSplitter.assign(quick) : quick, .quick, [])
        }
        let duration = engine.duration
        // A fresh extraction replaces any AI cleanup that was applied.
        workerCleanupBefore = nil
        let derived = derive(from: extracted, duration: duration, live: live, grid: grid)
        workerReviewedNotes = extracted
        workerShown = (source, sustain)
        // A finished take's final notes (not a preview a refine pass will replace).
        if !live, grid { autosave(notes: extracted) }
        notesVersion += 1
        let version = notesVersion
        publish(for: workerTakeID) {
            self.shownVersion = version
            // A fresh extraction replaces any AI cleanup that was applied.
            self.rawNotes = []
            self.cleanup = nil
            self.notesSource = source
            self.sustain = sustain
            self.notes = extracted
            self.melody = derived.melody
            self.chordSegments = derived.chords
            self.simplifiedNotes = derived.simplified
            self.beatGrid = derived.grid
            self.config = resolved
        }
        if live {
            analyzeChartTrailing(notes: extracted, melody: derived.melody, until: duration)
        }
        return (extracted, derived.melody)
    }

    /// Everything the views show that is computed from a note list. Runs on
    /// the worker queue (reads the refine pass's onset envelope).
    nonisolated private func derive(
        from notes: [NoteEvent],
        duration: Double,
        live: Bool = false,
        grid withGrid: Bool = true
    ) -> (melody: [NoteEvent], chords: [ChordSegment], grid: BeatGrid, simplified: [NoteEvent]?) {
        // The beat tracker looks at the whole take (~0.5 s per 4 minutes), so
        // it runs when a take is finished rather than on every live update.
        // Computed even when hidden: MIDI export's bars follow it.
        let rhythm = RhythmSettings(
            beatsPerMeasure: workerBeatsPerMeasure == 0 ? nil : workerBeatsPerMeasure,
            // Any octave of the chosen note anchors a measure.
            downbeatPitchClass: workerDownbeatPitch.map { (($0 % 12) + 12) % 12 },
            tempoOctave: workerTempoOctave,
            barShift: workerBarShift
        )
        // The refine pass's audio onset envelope, when its notes are the ones shown.
        let onsets: AudioOnsets? = live ? nil
            : workerMode == .music ? musicResult?.onsets
            : (workerUsePiano && pianoNotes != nil ? pianoOnsets : nil)
        // ... and the further notes its chords read (the preview's, in Song
        // mode), less those an applied AI cleanup took out.
        var harmony = !live && workerMode == .music ? musicResult?.harmonyNotes ?? [] : []
        if let before = workerCleanupBefore, !harmony.isEmpty {
            harmony = TakeAnalysis.harmonyNotes(harmony, before: before, after: notes)
        }
        let analysis = TakeAnalysis.derive(notes: notes, duration: duration, rhythm: rhythm,
                                           audioOnsets: onsets, harmonyNotes: harmony,
                                           grid: !live && withGrid, simplifyChords: !live)
        return (analysis.melody, analysis.chords, analysis.grid, analysis.simplified)
    }

    // MARK: - Refine passes (piano model, any-instrument)

    nonisolated private func resetTakeForRefine() {
        takeGeneration.wrappingAdd(1, ordering: .relaxed)
        takeAudio44k = []
        pianoNotes = nil
        pianoSustain = []
        pianoOnsets = nil
        musicResult = nil
        workerCleanupBefore = nil
        takeFinalized = false
        #if DEBUG
        captureFolder = nil
        #endif
    }

    /// The take is final: start the current mode's refine pass, and meanwhile
    /// show the quick transcription (or chart it directly if nothing refines it).
    nonisolated private func completeTake(duration: Double) {
        takeFinalized = true
        let refining: Bool
        switch workerMode {
        case .music:
            startMusicPass(duration: duration)
            refining = true
        case .piano where workerUsePiano && !takeAudio44k.isEmpty:
            startPianoPass(duration: duration)
            refining = true
        case .piano:
            refining = false
        }
        // While a pass runs, the quick notes are a preview: skip their beat grid
        // (seconds of work at the end of a long take); the refined notes get one.
        guard let take = extractAndPublish(live: false, grid: !refining) else { return }
        #if DEBUG
        if let engine {
            captureFolder = TakeCapture.save(audio22k: engine.recordedAudio, liveNotes: take.notes, config: workerConfig,
                                             mode: workerModeSnapshot.mode, source: takeSource, duration: duration)
        }
        #endif
        if !refining {
            finishTake(notes: take.notes, melody: take.melody, duration: duration)
        }
    }

    /// After a settings change on a finished take: run the current mode's
    /// refine pass if its result is missing, else publish and chart what's there.
    nonisolated private func refineOrPublish(duration: Double) {
        switch workerMode {
        case .music where musicResult == nil && engine != nil:
            startMusicPass(duration: duration)
            extractAndPublish(live: false, grid: false)
        case .piano where workerUsePiano && pianoNotes == nil && !takeAudio44k.isEmpty:
            startPianoPass(duration: duration)
            extractAndPublish(live: false, grid: false)
        default:
            if let take = extractAndPublish(live: false) {
                analyzeChartFull(notes: take.notes, melody: take.melody)
            }
        }
    }

    /// The refine pipeline with the app's bundled models (Transcription/Pipeline).
    nonisolated private static func pipeline() -> TakePipeline {
        TakePipeline(basicPitch: BasicPitchNoteEngine(model: { try BasicPitchModel() }),
                     transkun: TranskunNoteEngine(transcriber: { try PianoTranscriber() }))
    }

    /// The quick preview's notes for the current take: the arbiter's reference.
    nonisolated private func quickNotesForRefine() -> [NoteEvent] {
        engine?.extractNotes(config: workerConfig) ?? []
    }

    nonisolated private func startPianoPass(duration: Double) {
        let input = RefineInput(mode: .piano, take44k: takeAudio44k, quickNotes: quickNotesForRefine())
        runRefinePass(name: "Piano model", duration: duration,
                      failureMessage: "The piano model couldn't run, so the quick transcription is shown.") { progress, isCancelled in
            guard let output = try Self.pipeline().refine(input, progress: progress, isCancelled: isCancelled) else {
                return nil
            }
            let summary = output.info["summary"] ?? ""
            NSLog("Semitone: %@", summary)
            #if DEBUG
            Self.dumpNotesIfRequested(output.notes, summary: summary)
            #endif
            if output.verdict == .broken {
                throw NSError(domain: "Semitone", code: 24, userInfo: [
                    NSLocalizedDescriptionKey: "Its output looked wrong on this device.",
                ])
            }
            return output
        } apply: { (output: RefineOutput) in
            #if DEBUG
            if let folder = self.captureFolder { TakeCapture.savePiano(output.notes, summary: output.info["summary"] ?? "", in: folder) }
            #endif
            switch output.verdict {
            case .accept, .broken:
                break
            case .heardNothing:
                // Nothing heard (e.g. not a piano) while the quick detector heard
                // notes: keep those rather than an empty roll.
                self.publishError("The piano model didn't hear any piano, so the quick transcription is shown. For other instruments, on Home, touch and hold this Tone, then choose Transcription and Transcribe again as Song.")
                return false
            case .disagrees:
                // Far fewer or far shorter notes than the quick detector heard:
                // voices, winds or bowed strings, which a piano model misses.
                self.publishError("The piano model heard little of this take, so the quick transcription is shown. For voices and other instruments, on Home, touch and hold this Tone, then choose Transcription and Transcribe again as Song.")
                return false
            }
            self.pianoNotes = output.notes
            self.pianoSustain = output.sustain
            self.pianoOnsets = output.onsetEnvelope
            return true
        }
    }

    nonisolated private func startMusicPass(duration: Double) {
        guard let engine else { return }
        // The 44.1 kHz take mixes every input channel, whichever mode it was
        // made in (the live stream may have read just channel 0).
        let input = RefineInput(mode: .music, take44k: takeAudio44k,
                                take22k: takeAudio44k.isEmpty ? Array(engine.recordedAudio) : nil,
                                quickNotes: quickNotesForRefine())
        runRefinePass(name: "Any-instrument pass", duration: duration,
                      failureMessage: "The any-instrument pass couldn't run, so the quick transcription is shown.") { progress, isCancelled in
            let started = Date()
            guard let output = try Self.pipeline().refine(input, progress: progress, isCancelled: isCancelled) else {
                return nil
            }
            NSLog("Semitone: any-instrument pass took %.1f s for %.1f s of audio (%ld notes by %@; %@)",
                  Date().timeIntervalSince(started), output.profile?.seconds ?? 0, output.notes.count,
                  output.engine.rawValue,
                  output.info.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
            return MusicTranscription(notes: output.notes, onsets: output.onsetEnvelope,
                                      harmonyNotes: output.harmonyNotes)
        } apply: { (result: MusicTranscription) in
            self.musicResult = result
            return true
        }
    }

    /// Runs a refine pass over the current take on `refineQueue`, with progress,
    /// keep-alive and cancellation (a new take or a mode change stops it). On
    /// success `apply` stores the result on the worker queue and the take is
    /// republished; if `apply` declines it or the pass fails, the quick
    /// transcription stays (with the reason, on failure).
    nonisolated private func runRefinePass<Output>(
        name: String,
        duration: Double,
        failureMessage: String,
        work: @escaping (_ progress: @escaping (Double) -> Void, _ isCancelled: @escaping () -> Bool) throws -> Output?,
        apply: @escaping (Output) -> Bool
    ) {
        let pass = RefinePass(take: takeGeneration.load(ordering: .relaxed), mode: refineGeneration.load(ordering: .relaxed))
        let id = workerTakeID
        let current = {
            self.takeGeneration.load(ordering: .relaxed) == pass.take
                && self.refineGeneration.load(ordering: .relaxed) == pass.mode
        }
        publish(for: id) {
            self.refineProgress = 0
            self.beginRefineActivity(pass, name: name)
        }
        refineQueue.async { [weak self] in
            guard let self else { return }
            defer { Task { @MainActor in self.endRefineActivity(pass) } }
            guard current() else { return }
            /// Back on the worker queue: publish the quick notes (and chart them).
            func fallBack(_ message: String?) {
                if let message { self.publishError(message) }
                if let take = self.extractAndPublish(live: false) {
                    self.finishTake(notes: take.notes, melody: take.melody, duration: duration)
                }
            }
            do {
                let result = try work({ p in
                    self.publish(for: id) {
                        if current(), self.refineProgress != nil { self.refineProgress = p }
                    }
                }, { !current() })
                self.queue.async {
                    guard current() else { return }
                    self.publish(for: id) { self.refineProgress = nil }
                    guard let result else { return }
                    guard apply(result) else { return fallBack(nil) }
                    if let take = self.extractAndPublish(live: false) {
                        // Cleanup's guard rails target the quick detector's error patterns.
                        self.finishTake(notes: take.notes, melody: take.melody, duration: duration, allowCleanup: false)
                    }
                }
            } catch {
                self.queue.async {
                    guard current() else { return }
                    self.publish(for: id) { self.refineProgress = nil }
                    fallBack("\(failureMessage) \(error.localizedDescription)")
                }
            }
        }
    }

    /// While a refine pass runs, the screen doesn't auto-lock, and if the phone
    /// is locked or another app comes to the front anyway, iOS grants its usual
    /// extra time (about 30 s) to finish. Past that the pass just pauses with
    /// the app and resumes when it's reopened.
    private func beginRefineActivity(_ pass: RefinePass, name: String) {
        endRefineActivity()
        let task = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.endRefineActivity()
        }
        UIApplication.shared.isIdleTimerDisabled = true
        refineActivity = (pass, task)
    }

    /// Ends the keep-alive; with `pass`, only if it still belongs to that pass.
    private func endRefineActivity(_ pass: RefinePass? = nil) {
        guard let activity = refineActivity, pass == nil || activity.pass == pass else { return }
        UIApplication.shared.endBackgroundTask(activity.task)
        UIApplication.shared.isIdleTimerDisabled = false
        refineActivity = nil
    }

    // MARK: - AI cleanup

    nonisolated private static func cleanupEnabled() -> Bool {
        let d = UserDefaults.standard
        return d.object(forKey: "useAICleanup") == nil ? true : d.bool(forKey: "useAICleanup")
    }

    /// After a take is finalized: optionally let the AI clean it, then chart
    /// whatever the views end up showing. Runs on the worker queue.
    nonisolated private func finishTake(
        notes: [NoteEvent],
        melody: [NoteEvent],
        duration: Double,
        allowCleanup: Bool = true
    ) {
        guard !notes.isEmpty else { return }
        let client = Self.ai()
        guard allowCleanup, Self.cleanupEnabled(), client.provider.kind != .mock else {
            analyzeChartFull(notes: notes, melody: melody)
            return
        }
        chartGen += 1
        let gen = chartGen
        let version = notesVersion
        let id = workerTakeID
        publish(for: id) { self.isCleaningUp = true }
        Task {
            let outcome: Result<CleanupResult, Error>
            do {
                outcome = .success(try await client.cleanup(notes: notes, melody: melody))
            } catch {
                outcome = .failure(error)
            }
            // Back on the worker queue, which owns the take and the beat grid cache.
            self.queue.async {
                defer { self.publish(for: id) { self.isCleaningUp = false } }
                // Drop the answer if anything replaced these notes meanwhile
                // (a new take, a settings change, another run).
                guard gen == self.chartGen, version == self.notesVersion else { return }
                switch outcome {
                case .success(let result):
                    let cleaned = self.applyCleanupResult(result, raw: notes, duration: duration)
                    self.analyzeChartFull(notes: cleaned.notes, melody: cleaned.melody)
                case .failure(let error):
                    self.publishError("AI cleanup failed: \(error.localizedDescription)")
                    self.analyzeChartFull(notes: notes, melody: melody)
                }
            }
        }
    }

    /// Publishes cleaned notes (keeping the raw take for revert) and returns
    /// the set the chart pass should see. On the worker queue.
    nonisolated private func applyCleanupResult(
        _ result: CleanupResult,
        raw: [NoteEvent],
        duration: Double
    ) -> (notes: [NoteEvent], melody: [NoteEvent]) {
        let id = workerTakeID
        guard result.changeCount > 0 else {
            workerCleanupBefore = nil
            publish(for: id) { self.cleanup = result }
            return (raw, derive(from: raw, duration: duration).melody)
        }
        // Cleanup hands back plain notes; any-instrument takes get their parts back.
        let cleaned = raw.contains { $0.voice != .none } ? VoiceSplitter.assign(result.notes) : result.notes
        workerCleanupBefore = raw
        let derived = derive(from: cleaned, duration: duration)
        workerReviewedNotes = cleaned
        autosave(notes: cleaned)
        notesVersion += 1
        let version = notesVersion
        publish(for: id) {
            self.shownVersion = version
            self.rawNotes = raw
            self.cleanup = result
            self.notes = cleaned
            self.melody = derived.melody
            self.chordSegments = derived.chords
            self.simplifiedNotes = derived.simplified
            self.beatGrid = derived.grid
        }
        return (cleaned, derived.melody)
    }

    /// Run (or re-run) the AI cleanup on the current take, from the raw
    /// detection so repeated runs don't compound.
    func runCleanup() {
        guard !isRecording, !isTranscribing, !isCleaningUp, refineProgress == nil else { return }
        let source = rawNotes.isEmpty ? notes : rawNotes
        guard !source.isEmpty else { return }
        let lead = source.contains { $0.voice != .none }
            ? source.filter { $0.voice == .melody }
            : LeadLine.melody(from: source)
        let duration = self.duration
        let expected = shownVersion
        queue.async { [weak self] in
            guard let self, expected == self.notesVersion else { return }
            self.finishTake(notes: source, melody: lead, duration: duration)
        }
    }

    /// Put the detector's original notes back.
    func revertCleanup() {
        guard !rawNotes.isEmpty else { return }
        let raw = rawNotes
        let duration = self.duration
        let expected = shownVersion
        rawNotes = []
        cleanup = nil
        queue.async { [weak self] in
            // Newer notes already replaced these (and reset the cleanup state).
            guard let self, expected == self.notesVersion else { return }
            self.workerCleanupBefore = nil
            let derived = self.derive(from: raw, duration: duration)
            self.workerReviewedNotes = raw
            self.autosave(notes: raw)
            self.notesVersion += 1
            let version = self.notesVersion
            self.publish(for: self.workerTakeID) {
                self.shownVersion = version
                self.notes = raw
                self.melody = derived.melody
                self.chordSegments = derived.chords
                self.simplifiedNotes = derived.simplified
                self.beatGrid = derived.grid
            }
        }
    }

    /// While recording: chart only the recent tail so the header refreshes
    /// as you play, a few times per clip, then let the on-device chart take
    /// over. Requests are capped and superseded by newer runs.
    nonisolated private func analyzeChartTrailing(notes: [NoteEvent], melody: [NoteEvent], until: Double) {
        guard until - lastLiveAnalysisAt >= 3, liveChartCalls < maxLiveChartCalls else { return }
        lastLiveAnalysisAt = until
        liveChartCalls += 1
        let start = max(0, until - AIChartInterpreter.trailingWindow)
        let slice = notes.filter { $0.startTime >= start }
        let melodySlice = melody.filter { $0.startTime >= start }
        guard !slice.isEmpty else { return }

        chartGen += 1
        let gen = chartGen
        let id = workerTakeID
        let client = Self.ai()
        Task {
            let result = (try? await client.chart(notes: slice, melody: melodySlice))
                ?? AIChartInterpreter.Client.mockChart(notes: slice)
            self.queue.async {
                guard gen == self.chartGen else { return }
                self.publish(for: id) { self.chart = result }
            }
        }
    }

    /// On stop/import: chart the whole take — one call, best effort. If the
    /// AI can't answer (quota, network) we still hand back the on-device chart.
    nonisolated private func analyzeChartFull(notes extracted: [NoteEvent], melody lead: [NoteEvent]) {
        guard !extracted.isEmpty else { return }

        chartGen += 1
        let gen = chartGen
        let id = workerTakeID
        publish(for: id) { self.isAnalyzingChart = true }
        let client = Self.ai()
        Task {
            let result = (try? await client.chart(notes: extracted, melody: lead))
                ?? AIChartInterpreter.Client.mockChart(notes: extracted)
            self.queue.async {
                let latest = gen == self.chartGen
                self.publish(for: id) {
                    if latest { self.chart = result }
                    self.isAnalyzingChart = false
                }
            }
        }
    }

    nonisolated private func publishError(_ message: String) {
        Task { @MainActor in self.errorMessage = message }
    }
}

#if DEBUG
/// Worker state observed by hosted tests; mutation stays on the transcription queue.
nonisolated struct RegressionWorkerSnapshot {
    let snapshot: DetectionSnapshot
    let usesPianoModel: Bool
    let transcriptionMode: TranscriptionMode
    let beatsPerMeasure: Int
    let downbeatPitch: Int?
    let tempoOctave: Int
    let barShift: Int
    let notesVersion: Int
    let reviewedNotes: [NoteEvent]?
}

extension TranscriberViewModel {
    /// Hosted unit tests (XCTest loaded into the app) and `-semitone-ui-fixture`
    /// launches never autosave, so they can't add takes to the real library.
    nonisolated static let regressionRunSkipsLibrary: Bool = {
        let info = ProcessInfo.processInfo
        let hostedTest = ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
            .contains { info.environment[$0] != nil }
        return hostedTest || info.arguments.contains("-semitone-ui-fixture")
    }()

    var regressionShownVersion: Int { shownVersion }

    /// Seed deterministic accepted events on a real, finalized silent engine.
    /// This bypasses acoustic prediction only; subsequent settings, cleanup,
    /// publication, playback, and export use the production coordinator.
    func regressionInstallTake(notes fixture: [NoteEvent], source: NotesSource = .piano,
                               sustain pedals: [PedalEvent] = [], duration seconds: Double) async throws {
        await regressionFlushWorker()
        let mode: TranscriptionMode = source == .music ? .music : .piano
        if transcriptionMode != mode { transcriptionMode = mode }
        // The fixture's own piano-model choice, leaving the default for new
        // takes (Home's Settings, saved) as the tester left it.
        let id = resetForNewTake()
        takeUsesPianoModel = source == .piano
        duration = seconds
        let settings = DetectionSnapshot(mode: detectionMode, customMinNoteLengthMs: customNoteLenMs,
                                         customFrameThreshold: customFrameThreshold)
        let bpm = beatsPerMeasure, downbeat = downbeatPitch, octave = tempoOctave, shift = barShift
        // Compared here: NotesSource's Equatable conformance is main-actor isolated.
        let isPiano = source == .piano, isMusic = source == .music
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    self.resetWorker(for: id, source: "regression fixture", title: "Regression fixture")
                    self.workerSaved = nil   // fixtures never write into the saved-takes library
                    let engine = TranscriptionEngine(model: try BasicPitchModel())
                    try engine.append(Array(repeating: Float.zero,
                                            count: Int(max(0, seconds) * BPConstants.sampleRate)))
                    try engine.finalize()
                    self.engine = engine
                    self.takeFinalized = true
                    self.workerMode = mode
                    self.workerUsePiano = isPiano
                    self.workerModeSnapshot = settings
                    self.workerBeatsPerMeasure = bpm
                    self.workerDownbeatPitch = downbeat
                    self.workerTempoOctave = octave
                    self.workerBarShift = shift
                    if isPiano {
                        self.pianoNotes = fixture
                        self.pianoSustain = pedals
                    } else if isMusic {
                        self.musicResult = MusicTranscription(notes: fixture)
                    }
                    if isPiano || isMusic {
                        self.extractAndPublish(live: false)
                    } else {
                        self.workerReviewedNotes = fixture
                        self.notesVersion += 1
                        let version = self.notesVersion
                        let derived = self.derive(from: fixture, duration: seconds)
                        self.publish(for: id) {
                            self.shownVersion = version
                            self.notes = fixture
                            self.notesSource = source
                            self.sustain = pedals
                            self.melody = derived.melody
                            self.chordSegments = derived.chords
                            self.simplifiedNotes = derived.simplified
                            self.beatGrid = derived.grid
                        }
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
        await regressionFlushWorker()
    }

    func regressionApplyCleanup(_ result: CleanupResult) async {
        let raw = rawNotes.isEmpty ? notes : rawNotes
        let seconds = duration
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                _ = self.applyCleanupResult(result, raw: raw, duration: seconds)
                continuation.resume()
            }
        }
        await regressionFlushWorker()
    }

    func regressionFlushWorker() async {
        // A queue fence alone does not drain publish(for:)'s MainActor Tasks.
        // Two idle fences also catch a publication that queues a version retry.
        var idleFences = 0
        for _ in 0..<500 {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async { DispatchQueue.main.async { continuation.resume() } }
            }
            await Task.yield()
            if regressionPendingPublications.load(ordering: .relaxed) == 0 {
                idleFences += 1
                if idleFences == 2 { return }
            } else {
                idleFences = 0
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        preconditionFailure("Regression publication fence did not become idle")
    }

    func regressionSuspendWorker() { queue.suspend() }
    func regressionResumeWorker() { queue.resume() }

    func regressionBeginEmptyTake() {
        let id = resetForNewTake()
        queue.async {
            self.resetWorker(for: id, source: "replacement regression take", title: "Regression take")
            self.workerSaved = nil
            self.engine = nil
        }
    }

    func regressionWorkerSnapshot() async -> RegressionWorkerSnapshot {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: RegressionWorkerSnapshot(
                    snapshot: self.workerModeSnapshot, usesPianoModel: self.workerUsePiano,
                    transcriptionMode: self.workerMode, beatsPerMeasure: self.workerBeatsPerMeasure,
                    downbeatPitch: self.workerDownbeatPitch, tempoOctave: self.workerTempoOctave,
                    barShift: self.workerBarShift, notesVersion: self.notesVersion,
                    reviewedNotes: self.workerReviewedNotes))
            }
        }
    }

    /// -semitone-record-transition-demo: a take that records nothing, for
    /// the record transition in the simulator. It starts as a real one does
    /// (the previous take cleared at once, as soon as the microphone is
    /// allowed; recording a moment later, once the model has loaded) and
    /// its live edge moves on as the microphone's buffers would move it;
    /// stopping keeps it, empty, and saves nothing. With
    /// -semitone-record-transition-deny it fails to start instead, as a
    /// take does with the microphone refused.
    func demoToggleRecording() {
        if isRecording {
            isRecording = false
            return
        }
        guard !isStartingTake, !isTranscribing else { return }
        isStartingTake = true
        Task {
            if RecordTransition.deniesMicrophone {
                // As `startRecording` fails with the microphone refused: the
                // error, then done starting, with nothing recording.
                errorMessage = "Semitone needs microphone access. Enable it in Settings."
                isStartingTake = false
                return
            }
            regressionBeginEmptyTake()
            try? await Task.sleep(for: .milliseconds(250))
            regressionRecord(from: 0, to: 600)
            isStartingTake = false
        }
    }

    func regressionSetRecordingEdge(at seconds: Double) {
        isRecording = true
        duration = seconds
    }

    /// The installed take as if it were being recorded: the live edge from
    /// `start`, published every 0.1 s as the microphone's buffers are, until
    /// `end`. Stop then ends it like a recording, leaving the take as it was.
    func regressionRecord(from start: Double, to end: Double) {
        regressionSetRecordingEdge(at: start)
        Task {
            while isRecording, duration < end {
                try? await Task.sleep(for: .milliseconds(100))
                guard isRecording else { return }
                duration = min(duration + 0.1, end)
            }
        }
    }
}
#endif
